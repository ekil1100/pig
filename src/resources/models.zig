const std = @import("std");
const common = @import("common.zig");
const json = @import("../util/json.zig");

pub const ModelScope = enum { builtin, global, project, transient };

pub const ModelEntry = struct {
    id: []const u8,
    provider_id: []const u8,
    display_name: []const u8,
    model: []const u8,
    base_url: ?[]const u8 = null,
    enabled: bool = true,
    scope: ModelScope = .builtin,
    source: common.ResourceSourceInfo,

    pub fn clone(allocator: std.mem.Allocator, entry: ModelEntry) !ModelEntry {
        const id = try allocator.dupe(u8, entry.id);
        errdefer allocator.free(id);
        const provider_id = try allocator.dupe(u8, entry.provider_id);
        errdefer allocator.free(provider_id);
        const display_name = try allocator.dupe(u8, entry.display_name);
        errdefer allocator.free(display_name);
        const model = try allocator.dupe(u8, entry.model);
        errdefer allocator.free(model);
        const base_url = if (entry.base_url) |url| try allocator.dupe(u8, url) else null;
        errdefer if (base_url) |url| allocator.free(url);
        var source = try common.ResourceSourceInfo.clone(allocator, entry.source.source, entry.source.path, entry.source.priority);
        errdefer source.deinit(allocator);
        return .{ .id = id, .provider_id = provider_id, .display_name = display_name, .model = model, .base_url = base_url, .enabled = entry.enabled, .scope = entry.scope, .source = source };
    }

    pub fn deinit(self: *ModelEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.provider_id);
        allocator.free(self.display_name);
        allocator.free(self.model);
        if (self.base_url) |url| allocator.free(url);
        self.source.deinit(allocator);
        self.* = undefined;
    }
};

pub const Registry = struct {
    entries: std.ArrayList(ModelEntry) = .empty,
    default_model: ?[]const u8 = null,
    warnings: std.ArrayList(common.ResourceWarning) = .empty,

    pub fn deinit(self: *Registry, allocator: std.mem.Allocator) void {
        for (self.entries.items) |*entry| entry.deinit(allocator);
        self.entries.deinit(allocator);
        if (self.default_model) |model| allocator.free(model);
        for (self.warnings.items) |*warning| warning.deinit(allocator);
        self.warnings.deinit(allocator);
        self.* = undefined;
    }

    pub fn find(self: *const Registry, id: []const u8) ?*const ModelEntry {
        for (self.entries.items) |*entry| if (std.mem.eql(u8, entry.id, id)) return entry;
        return null;
    }

    pub fn findDefaultForProvider(self: *const Registry, provider_id: []const u8) ?*const ModelEntry {
        for (self.entries.items) |*entry| {
            if (entry.enabled and std.mem.eql(u8, entry.provider_id, provider_id)) return entry;
        }
        return null;
    }
};

pub fn loadRegistry(allocator: std.mem.Allocator, io: std.Io, global_path: []const u8, project_path: []const u8) !Registry {
    var registry = Registry{};
    errdefer registry.deinit(allocator);
    try addBuiltin(allocator, &registry);
    try applyFile(allocator, io, &registry, global_path, .global, .global, 10);
    try applyFile(allocator, io, &registry, project_path, .project, .project, 20);
    return registry;
}

fn addBuiltin(allocator: std.mem.Allocator, registry: *Registry) !void {
    try addBuiltinEntry(allocator, registry, .{
        .id = "gpt-4.1-mini",
        .provider_id = "openai_compatible",
        .display_name = "GPT-4.1 Mini",
        .model = "gpt-4.1-mini",
        .base_url = "https://api.openai.com/v1",
    });
    try addBuiltinEntry(allocator, registry, .{
        .id = "deepseek-v4-flash",
        .provider_id = "deepseek",
        .display_name = "DeepSeek V4 Flash",
        .model = "deepseek-v4-flash",
        .base_url = "https://api.deepseek.com",
    });
    try addBuiltinEntry(allocator, registry, .{
        .id = "deepseek-v4-pro",
        .provider_id = "deepseek",
        .display_name = "DeepSeek V4 Pro",
        .model = "deepseek-v4-pro",
        .base_url = "https://api.deepseek.com",
    });
    registry.default_model = try allocator.dupe(u8, "gpt-4.1-mini");
}

const BuiltinEntry = struct {
    id: []const u8,
    provider_id: []const u8,
    display_name: []const u8,
    model: []const u8,
    base_url: []const u8,
};

fn addBuiltinEntry(allocator: std.mem.Allocator, registry: *Registry, builtin: BuiltinEntry) !void {
    var source = try common.ResourceSourceInfo.clone(allocator, .builtin, "builtin", 0);
    errdefer source.deinit(allocator);
    const id = try allocator.dupe(u8, builtin.id);
    errdefer allocator.free(id);
    const provider_id = try allocator.dupe(u8, builtin.provider_id);
    errdefer allocator.free(provider_id);
    const display_name = try allocator.dupe(u8, builtin.display_name);
    errdefer allocator.free(display_name);
    const model = try allocator.dupe(u8, builtin.model);
    errdefer allocator.free(model);
    const base_url = try allocator.dupe(u8, builtin.base_url);
    errdefer allocator.free(base_url);
    const entry = ModelEntry{
        .id = id,
        .provider_id = provider_id,
        .display_name = display_name,
        .model = model,
        .base_url = base_url,
        .enabled = true,
        .scope = .builtin,
        .source = source,
    };
    errdefer {
        var mutable = entry;
        mutable.deinit(allocator);
    }
    try registry.entries.append(allocator, entry);
}

fn applyFile(allocator: std.mem.Allocator, io: std.Io, registry: *Registry, path: []const u8, source: common.ResourceSource, scope: ModelScope, priority: u8) !void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer allocator.free(bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch {
        try common.appendWarning(allocator, &registry.warnings, .invalid_json, path, "models JSON is invalid");
        return error.InvalidModelsJson;
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidModelsJson;
    if (json.optionalStringField(parsed.value.object, "default_model")) |default_model| {
        if (registry.default_model) |old| allocator.free(old);
        registry.default_model = try allocator.dupe(u8, default_model);
    }
    const models_value = parsed.value.object.get("models") orelse return;
    if (models_value != .array) return error.InvalidModelsJson;
    for (models_value.array.items) |item| {
        if (item != .object) continue;
        var entry = try parseEntry(allocator, item.object, path, source, scope, priority);
        errdefer entry.deinit(allocator);
        try upsert(allocator, registry, entry);
    }
}

fn parseEntry(allocator: std.mem.Allocator, object: std.json.ObjectMap, path: []const u8, source: common.ResourceSource, scope: ModelScope, priority: u8) !ModelEntry {
    const id = json.stringField(object, "id") orelse return error.InvalidModelsJson;
    const provider_id = json.stringField(object, "provider_id") orelse json.stringField(object, "provider") orelse return error.InvalidModelsJson;
    const model = json.stringField(object, "model") orelse return error.InvalidModelsJson;
    const display_name = json.optionalStringField(object, "display_name") orelse id;
    const base_url = json.optionalStringField(object, "base_url");
    var source_info = try common.ResourceSourceInfo.clone(allocator, source, path, priority);
    errdefer source_info.deinit(allocator);
    const owned_id = try allocator.dupe(u8, id);
    errdefer allocator.free(owned_id);
    const owned_provider_id = try allocator.dupe(u8, provider_id);
    errdefer allocator.free(owned_provider_id);
    const owned_display_name = try allocator.dupe(u8, display_name);
    errdefer allocator.free(owned_display_name);
    const owned_model = try allocator.dupe(u8, model);
    errdefer allocator.free(owned_model);
    const owned_base_url = if (base_url) |url| try allocator.dupe(u8, url) else null;
    errdefer if (owned_base_url) |url| allocator.free(url);
    return .{
        .id = owned_id,
        .provider_id = owned_provider_id,
        .display_name = owned_display_name,
        .model = owned_model,
        .base_url = owned_base_url,
        .enabled = json.boolField(object, "enabled", true),
        .scope = scope,
        .source = source_info,
    };
}

fn upsert(allocator: std.mem.Allocator, registry: *Registry, entry: ModelEntry) !void {
    for (registry.entries.items, 0..) |*existing, i| {
        if (std.mem.eql(u8, existing.id, entry.id)) {
            try common.appendWarning(allocator, &registry.warnings, .collision, entry.source.path, "model id overrides an existing entry");
            existing.deinit(allocator);
            registry.entries.items[i] = entry;
            return;
        }
    }
    try registry.entries.append(allocator, entry);
}

pub const SelectOptions = struct {
    provider_override: ?[]const u8 = null,
    model_override: ?[]const u8 = null,
    settings_provider: ?[]const u8 = null,
    settings_model: ?[]const u8 = null,
};

pub fn selectModel(allocator: std.mem.Allocator, registry: *const Registry, options: SelectOptions) !ModelEntry {
    if (options.provider_override orelse options.settings_provider) |provider_id| {
        const model_override = options.model_override orelse if (options.provider_override == null) options.settings_model else null;
        if (model_override == null) {
            if (registry.findDefaultForProvider(provider_id)) |entry| return try ModelEntry.clone(allocator, entry.*);
        }
        const model_name = model_override orelse return error.UnknownModel;
        if (registry.find(model_name)) |entry| {
            if (std.mem.eql(u8, entry.provider_id, provider_id)) {
                if (!entry.enabled) return error.DisabledModel;
                return try ModelEntry.clone(allocator, entry.*);
            }
        }
        return try transientModel(allocator, provider_id, model_name);
    }
    const wanted = options.model_override orelse options.settings_model orelse registry.default_model orelse return error.UnknownModel;
    const entry = registry.find(wanted) orelse return error.UnknownModel;
    if (!entry.enabled) return error.DisabledModel;
    return try ModelEntry.clone(allocator, entry.*);
}

fn transientModel(allocator: std.mem.Allocator, provider_id: []const u8, model_name: []const u8) !ModelEntry {
    var source = try common.ResourceSourceInfo.clone(allocator, .project, "config", 255);
    errdefer source.deinit(allocator);
    const id = try allocator.dupe(u8, model_name);
    errdefer allocator.free(id);
    const owned_provider_id = try allocator.dupe(u8, provider_id);
    errdefer allocator.free(owned_provider_id);
    const display_name = try allocator.dupe(u8, model_name);
    errdefer allocator.free(display_name);
    const model = try allocator.dupe(u8, model_name);
    errdefer allocator.free(model);
    return .{
        .id = id,
        .provider_id = owned_provider_id,
        .display_name = display_name,
        .model = model,
        .base_url = null,
        .enabled = true,
        .scope = .transient,
        .source = source,
    };
}
