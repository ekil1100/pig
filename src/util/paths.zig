const std = @import("std");

pub const PathSet = struct {
    cwd: []const u8,
    home: []const u8,
    global_config: []const u8,
    global_auth: []const u8,
    global_models: []const u8,
    global_sessions: []const u8,
    project_config: []const u8,
    project_resources: []const u8,

    pub fn deinit(self: PathSet, allocator: std.mem.Allocator) void {
        allocator.free(self.cwd);
        allocator.free(self.home);
        allocator.free(self.global_config);
        allocator.free(self.global_auth);
        allocator.free(self.global_models);
        allocator.free(self.global_sessions);
        allocator.free(self.project_config);
        allocator.free(self.project_resources);
    }
};

pub fn cwd(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const cwd_z = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_z);
    return try allocator.dupe(u8, cwd_z);
}

pub fn homeDir(allocator: std.mem.Allocator, env_home: ?[]const u8) ![]u8 {
    if (env_home) |home| return try allocator.dupe(u8, home);
    return try allocator.dupe(u8, ".");
}

pub fn join(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    return try std.fs.path.join(allocator, parts);
}

pub fn resolveDefaultPaths(allocator: std.mem.Allocator) !PathSet {
    return try resolveDefaultPathsFrom(allocator, ".", ".");
}

pub fn resolveDefaultPathsFrom(allocator: std.mem.Allocator, cwd_path: []const u8, home_path: []const u8) !PathSet {
    var result: PathSet = undefined;

    result.cwd = try allocator.dupe(u8, cwd_path);
    errdefer allocator.free(result.cwd);

    result.home = try allocator.dupe(u8, home_path);
    errdefer allocator.free(result.home);

    result.global_config = try join(allocator, &.{ home_path, ".pi", "agent", "settings.json" });
    errdefer allocator.free(result.global_config);

    result.global_auth = try join(allocator, &.{ home_path, ".pi", "agent", "auth.json" });
    errdefer allocator.free(result.global_auth);

    result.global_models = try join(allocator, &.{ home_path, ".pi", "agent", "models.json" });
    errdefer allocator.free(result.global_models);

    result.global_sessions = try join(allocator, &.{ home_path, ".pi", "agent", "sessions" });
    errdefer allocator.free(result.global_sessions);

    result.project_config = try join(allocator, &.{ cwd_path, ".pi", "settings.json" });
    errdefer allocator.free(result.project_config);

    result.project_resources = try join(allocator, &.{ cwd_path, ".pi" });
    errdefer allocator.free(result.project_resources);

    return result;
}
