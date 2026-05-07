const std = @import("std");
const common = @import("common.zig");
const json = @import("../util/json.zig");

pub const ToolSettings = struct {
    enabled: ?bool = null,
    include_p1: ?bool = null,
};

pub const ContextSettings = struct {
    include: ?[]const []const u8 = null,
    max_bytes: ?usize = null,
};

pub const ResolvedSettings = struct {
    provider: ?[]const u8,
    model: ?[]const u8,
    thinking: []const u8,
    tools_enabled: bool,
    include_p1_tools: bool,
    context_include: []const []const u8,
    context_max_bytes: usize,

    pub fn initDefaults(allocator: std.mem.Allocator) !ResolvedSettings {
        const include_defaults = [_][]const u8{ "AGENTS.md", "CLAUDE.md", "SYSTEM.md", "APPEND_SYSTEM.md" };
        const include = try allocator.alloc([]const u8, include_defaults.len);
        var include_count: usize = 0;
        errdefer {
            for (include[0..include_count]) |item| allocator.free(item);
            allocator.free(include);
        }
        for (&include_defaults, 0..) |name, i| {
            include[i] = try allocator.dupe(u8, name);
            include_count += 1;
        }
        const thinking = try allocator.dupe(u8, "off");
        errdefer allocator.free(thinking);
        return .{
            .provider = null,
            .model = null,
            .thinking = thinking,
            .tools_enabled = true,
            .include_p1_tools = false,
            .context_include = include,
            .context_max_bytes = 64 * 1024,
        };
    }

    pub fn deinit(self: *ResolvedSettings, allocator: std.mem.Allocator) void {
        if (self.provider) |provider| allocator.free(provider);
        if (self.model) |model| allocator.free(model);
        allocator.free(self.thinking);
        for (self.context_include) |item| allocator.free(item);
        allocator.free(self.context_include);
        self.* = undefined;
    }

    fn replaceOptionalString(allocator: std.mem.Allocator, slot: *?[]const u8, value: []const u8) !void {
        const owned = try allocator.dupe(u8, value);
        if (slot.*) |old| allocator.free(old);
        slot.* = owned;
    }

    fn replaceString(allocator: std.mem.Allocator, slot: *[]const u8, value: []const u8) !void {
        const owned = try allocator.dupe(u8, value);
        allocator.free(slot.*);
        slot.* = owned;
    }

    fn replaceInclude(self: *ResolvedSettings, allocator: std.mem.Allocator, values: []const []const u8) !void {
        const owned = try allocator.alloc([]const u8, values.len);
        var owned_count: usize = 0;
        errdefer {
            for (owned[0..owned_count]) |item| allocator.free(item);
            allocator.free(owned);
        }
        for (values, 0..) |value, i| {
            owned[i] = try allocator.dupe(u8, value);
            owned_count += 1;
        }
        for (self.context_include) |item| allocator.free(item);
        allocator.free(self.context_include);
        self.context_include = owned;
    }
};

pub const LoadResult = struct {
    settings: ResolvedSettings,
    warnings: std.ArrayList(common.ResourceWarning) = .empty,

    pub fn deinit(self: *LoadResult, allocator: std.mem.Allocator) void {
        self.settings.deinit(allocator);
        for (self.warnings.items) |*warning| warning.deinit(allocator);
        self.warnings.deinit(allocator);
        self.* = undefined;
    }
};

pub const CliOverrides = struct {
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    thinking: ?[]const u8 = null,
    tools_enabled: ?bool = null,
    include_p1_tools: ?bool = null,
};

pub fn load(allocator: std.mem.Allocator, io: std.Io, global_path: []const u8, project_path: []const u8, overrides: CliOverrides) !LoadResult {
    var result = LoadResult{ .settings = try ResolvedSettings.initDefaults(allocator) };
    errdefer result.deinit(allocator);
    try applyFile(allocator, io, &result, global_path);
    try applyFile(allocator, io, &result, project_path);
    try applyOverrides(allocator, &result.settings, overrides);
    return result;
}

fn applyFile(allocator: std.mem.Allocator, io: std.Io, result: *LoadResult, path: []const u8) !void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => {
            try common.appendWarning(allocator, &result.warnings, .missing, path, "settings file missing");
            return;
        },
        else => return err,
    };
    defer allocator.free(bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch {
        try common.appendWarning(allocator, &result.warnings, .invalid_json, path, "settings JSON is invalid");
        return error.InvalidSettingsJson;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        try common.appendWarning(allocator, &result.warnings, .invalid_json, path, "settings JSON must be an object");
        return error.InvalidSettingsJson;
    }
    try applyObject(allocator, &result.settings, &result.warnings, path, parsed.value.object);
}

fn applyObject(allocator: std.mem.Allocator, settings: *ResolvedSettings, warnings: *std.ArrayList(common.ResourceWarning), path: []const u8, object: std.json.ObjectMap) !void {
    if (json.optionalStringField(object, "provider")) |provider| try ResolvedSettings.replaceOptionalString(allocator, &settings.provider, provider);
    if (json.optionalStringField(object, "model")) |model| try ResolvedSettings.replaceOptionalString(allocator, &settings.model, model);
    if (json.optionalStringField(object, "thinking")) |thinking| try ResolvedSettings.replaceString(allocator, &settings.thinking, thinking);
    if (object.get("api_key") != null) try common.appendWarning(allocator, warnings, .secret_in_config, path, "settings must not contain API keys");
    if (object.get("tools")) |tools_value| {
        if (tools_value == .object) {
            if (tools_value.object.get("enabled")) |enabled| {
                if (enabled == .bool) settings.tools_enabled = enabled.bool;
            }
            if (tools_value.object.get("include_p1")) |include| {
                if (include == .bool) settings.include_p1_tools = include.bool;
            }
        }
    }
    if (object.get("context")) |context_value| {
        if (context_value == .object) {
            if (context_value.object.get("max_bytes")) |max_value| {
                if (intFromValue(max_value)) |value| settings.context_max_bytes = value;
            }
            if (context_value.object.get("include")) |include_value| {
                if (include_value == .array) {
                    var includes: std.ArrayList([]const u8) = .empty;
                    defer includes.deinit(allocator);
                    for (include_value.array.items) |item| if (item == .string) try includes.append(allocator, item.string);
                    try settings.replaceInclude(allocator, includes.items);
                }
            }
        }
    }
}

fn intFromValue(value: std.json.Value) ?usize {
    return switch (value) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        .number_string => |s| std.fmt.parseUnsigned(usize, s, 10) catch null,
        else => null,
    };
}

pub fn applyOverrides(allocator: std.mem.Allocator, settings: *ResolvedSettings, overrides: CliOverrides) !void {
    if (overrides.provider) |provider| try ResolvedSettings.replaceOptionalString(allocator, &settings.provider, provider);
    if (overrides.model) |model| try ResolvedSettings.replaceOptionalString(allocator, &settings.model, model);
    if (overrides.thinking) |thinking| try ResolvedSettings.replaceString(allocator, &settings.thinking, thinking);
    if (overrides.tools_enabled) |enabled| settings.tools_enabled = enabled;
    if (overrides.include_p1_tools) |include| settings.include_p1_tools = include;
}
