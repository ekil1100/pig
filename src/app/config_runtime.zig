const std = @import("std");
const args = @import("args.zig");
const agent = @import("../core/agent/mod.zig");
const resources = @import("../resources/mod.zig");
const paths = @import("../util/paths.zig");

pub const ConfigRuntimeError = error{
    OutOfMemory,
    InvalidSettingsJson,
    InvalidModelsJson,
    UnknownModel,
    DisabledModel,
    InvalidThinkingLevel,
    ResourceLoadFailed,
};

pub const ResolveOptions = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    env_home: ?[]const u8,
    config: args.RunConfig,
};

pub const ResolvedRuntimeConfig = struct {
    paths: paths.PathSet,
    snapshot: resources.discovery.ResourceSnapshot,
    model: resources.models.ModelEntry,
    thinking_level: agent.ThinkingLevel,
    effective_run_config: args.RunConfig,

    pub fn deinit(self: *ResolvedRuntimeConfig, allocator: std.mem.Allocator) void {
        self.paths.deinit(allocator);
        self.snapshot.deinit(allocator);
        self.model.deinit(allocator);
        self.* = undefined;
    }

    pub fn systemPrompt(self: *const ResolvedRuntimeConfig) ?[]const u8 {
        return self.snapshot.context.system_prompt;
    }
};

pub fn resolve(options: ResolveOptions) ConfigRuntimeError!ResolvedRuntimeConfig {
    const allocator = options.allocator;
    const cwd_value = resolveCwd(allocator, options.io, options.config.cwd) catch return error.OutOfMemory;
    defer allocator.free(cwd_value);
    const home_value = paths.homeDir(allocator, options.env_home) catch return error.OutOfMemory;
    defer allocator.free(home_value);

    var path_set = paths.resolveDefaultPathsFrom(allocator, cwd_value, home_value) catch return error.OutOfMemory;
    errdefer path_set.deinit(allocator);

    const global_resources = std.fs.path.dirname(path_set.global_config) orelse path_set.home;
    const project_models = std.fs.path.join(allocator, &.{ path_set.project_resources, "models.json" }) catch return error.OutOfMemory;
    defer allocator.free(project_models);

    const overrides = resources.settings.CliOverrides{
        .provider = options.config.provider,
        .model = options.config.model,
        .thinking = if (options.config.thinking_overridden) @tagName(options.config.thinking_level) else null,
        .tools_enabled = if (options.config.tools_enabled_overridden) options.config.tools_enabled else null,
        .include_p1_tools = if (options.config.include_p1_tools_overridden) options.config.include_p1_tools else null,
    };

    var snapshot = resources.discovery.loadSnapshot(allocator, options.io, .{
        .cwd = path_set.cwd,
        .global_config = path_set.global_config,
        .project_config = path_set.project_config,
        .global_models = path_set.global_models,
        .project_models = project_models,
        .global_resources = global_resources,
        .project_resources = path_set.project_resources,
        .overrides = overrides,
    }) catch |err| return mapResourceError(err);
    errdefer snapshot.deinit(allocator);

    var model = resources.models.selectModel(allocator, &snapshot.models, .{
        .provider_override = options.config.provider,
        .model_override = options.config.model,
        .settings_model = snapshot.settings.model,
    }) catch |err| return mapModelError(err);
    errdefer model.deinit(allocator);

    const thinking_level = parseThinking(snapshot.settings.thinking) orelse return error.InvalidThinkingLevel;
    var effective = options.config;
    effective.provider = model.provider_id;
    effective.model = model.model;
    effective.thinking_level = thinking_level;
    effective.tools_enabled = snapshot.settings.tools_enabled;
    effective.include_p1_tools = snapshot.settings.include_p1_tools;

    return .{ .paths = path_set, .snapshot = snapshot, .model = model, .thinking_level = thinking_level, .effective_run_config = effective };
}

fn resolveCwd(allocator: std.mem.Allocator, io: std.Io, cwd_arg: ?[]const u8) ![]u8 {
    if (cwd_arg) |cwd| {
        if (std.fs.path.isAbsolute(cwd)) return try allocator.dupe(u8, cwd);
        const base = try paths.cwd(allocator, io);
        defer allocator.free(base);
        return try std.fs.path.join(allocator, &.{ base, cwd });
    }
    return try paths.cwd(allocator, io);
}

pub fn parseThinking(value: []const u8) ?agent.ThinkingLevel {
    if (std.mem.eql(u8, value, "off")) return .off;
    if (std.mem.eql(u8, value, "low")) return .low;
    if (std.mem.eql(u8, value, "medium")) return .medium;
    if (std.mem.eql(u8, value, "high")) return .high;
    if (std.mem.eql(u8, value, "xhigh")) return .xhigh;
    if (std.mem.eql(u8, value, "max")) return .max;
    return null;
}

fn mapResourceError(err: anyerror) ConfigRuntimeError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidSettingsJson => error.InvalidSettingsJson,
        error.InvalidModelsJson => error.InvalidModelsJson,
        else => error.ResourceLoadFailed,
    };
}

fn mapModelError(err: anyerror) ConfigRuntimeError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.UnknownModel => error.UnknownModel,
        error.DisabledModel => error.DisabledModel,
        else => error.UnknownModel,
    };
}
