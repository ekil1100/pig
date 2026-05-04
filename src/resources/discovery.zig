const std = @import("std");
const common = @import("common.zig");
const settings_mod = @import("settings.zig");
const models_mod = @import("models.zig");
const context_mod = @import("context_files.zig");

pub const ResourceCounters = struct {
    skills: usize = 0,
    prompts: usize = 0,
    themes: usize = 0,
    packages: usize = 0,
};

pub const ResourceSnapshot = struct {
    settings: settings_mod.ResolvedSettings,
    models: models_mod.Registry,
    context: context_mod.ContextSnapshot,
    counters: ResourceCounters = .{},
    warnings: std.ArrayList(common.ResourceWarning) = .empty,

    pub fn deinit(self: *ResourceSnapshot, allocator: std.mem.Allocator) void {
        self.settings.deinit(allocator);
        self.models.deinit(allocator);
        self.context.deinit(allocator);
        for (self.warnings.items) |*warning| warning.deinit(allocator);
        self.warnings.deinit(allocator);
        self.* = undefined;
    }
};

pub const LoadOptions = struct {
    cwd: []const u8,
    global_config: []const u8,
    project_config: []const u8,
    global_models: []const u8,
    project_models: []const u8,
    global_resources: []const u8,
    project_resources: []const u8,
    overrides: settings_mod.CliOverrides = .{},
};

pub fn loadSnapshot(allocator: std.mem.Allocator, io: std.Io, options: LoadOptions) !ResourceSnapshot {
    var loaded_settings = try settings_mod.load(allocator, io, options.global_config, options.project_config, options.overrides);
    defer loaded_settings.warnings.deinit(allocator);
    errdefer loaded_settings.settings.deinit(allocator);

    var registry = try models_mod.loadRegistry(allocator, io, options.global_models, options.project_models);
    errdefer registry.deinit(allocator);

    var context = try context_mod.load(allocator, io, .{
        .cwd = options.cwd,
        .include = loaded_settings.settings.context_include,
        .max_bytes = loaded_settings.settings.context_max_bytes,
    });
    errdefer context.deinit(allocator);

    var snapshot = ResourceSnapshot{
        .settings = loaded_settings.settings,
        .models = registry,
        .context = context,
    };
    errdefer snapshot.deinit(allocator);
    try moveWarnings(allocator, &snapshot.warnings, &loaded_settings.warnings);
    try moveWarnings(allocator, &snapshot.warnings, &snapshot.models.warnings);
    try moveWarnings(allocator, &snapshot.warnings, &snapshot.context.warnings);
    try scanMetadata(allocator, io, &snapshot, options.global_resources, options.project_resources);
    return snapshot;
}

fn moveWarnings(allocator: std.mem.Allocator, dest: *std.ArrayList(common.ResourceWarning), source: *std.ArrayList(common.ResourceWarning)) !void {
    while (source.items.len > 0) {
        const warning = source.items[0];
        try dest.append(allocator, warning);
        _ = source.orderedRemove(0);
    }
}

fn scanMetadata(allocator: std.mem.Allocator, io: std.Io, snapshot: *ResourceSnapshot, global_root: []const u8, project_root: []const u8) !void {
    var skills = MetadataIndex.init(allocator);
    defer skills.deinit();
    try scanKind(allocator, io, snapshot, global_root, "skills", .skill, .global, &skills);
    try scanKind(allocator, io, snapshot, project_root, "skills", .skill, .project, &skills);

    var prompts = MetadataIndex.init(allocator);
    defer prompts.deinit();
    try scanKind(allocator, io, snapshot, global_root, "prompts", .prompt_template, .global, &prompts);
    try scanKind(allocator, io, snapshot, project_root, "prompts", .prompt_template, .project, &prompts);

    var themes = MetadataIndex.init(allocator);
    defer themes.deinit();
    try scanKind(allocator, io, snapshot, global_root, "themes", .theme, .global, &themes);
    try scanKind(allocator, io, snapshot, project_root, "themes", .theme, .project, &themes);

    var packages = MetadataIndex.init(allocator);
    defer packages.deinit();
    try scanKind(allocator, io, snapshot, global_root, "packages", .package, .global, &packages);
    try scanKind(allocator, io, snapshot, project_root, "packages", .package, .project, &packages);
}

const MetadataIndex = struct {
    allocator: std.mem.Allocator,
    names: std.StringHashMap(void),

    fn init(allocator: std.mem.Allocator) MetadataIndex {
        return .{ .allocator = allocator, .names = std.StringHashMap(void).init(allocator) };
    }

    fn deinit(self: *MetadataIndex) void {
        var keys = self.names.keyIterator();
        while (keys.next()) |key| self.allocator.free(key.*);
        self.names.deinit();
        self.* = undefined;
    }

    fn contains(self: *const MetadataIndex, name: []const u8) bool {
        return self.names.contains(name);
    }

    fn add(self: *MetadataIndex, name: []const u8) !void {
        if (self.names.contains(name)) return;
        const owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned);
        try self.names.put(owned, {});
    }
};

fn scanKind(allocator: std.mem.Allocator, io: std.Io, snapshot: *ResourceSnapshot, root: []const u8, dirname: []const u8, kind: common.ResourceKind, source: common.ResourceSource, index: *MetadataIndex) !void {
    const path = try std.fs.path.join(allocator, &.{ root, dirname });
    defer allocator.free(path);
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return,
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (source == .project and index.contains(entry.name)) {
            const collision_path = try std.fs.path.join(allocator, &.{ path, entry.name });
            defer allocator.free(collision_path);
            try common.appendWarning(allocator, &snapshot.warnings, .collision, collision_path, "project resource overrides a global resource with the same name");
        }
        try index.add(entry.name);
        switch (kind) {
            .skill => snapshot.counters.skills += 1,
            .prompt_template => snapshot.counters.prompts += 1,
            .theme => snapshot.counters.themes += 1,
            .package => snapshot.counters.packages += 1,
            else => {},
        }
    }
}
