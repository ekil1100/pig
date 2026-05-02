const std = @import("std");

pub const PathPolicyError = error{ OutOfMemory, EmptyPath, AbsolutePathRejected, PathEscapesWorkspace, PathContainsNul };

pub const NormalizedPath = struct {
    relative: []const u8,
    absolute: []const u8,

    pub fn deinit(self: *NormalizedPath, allocator: std.mem.Allocator) void {
        allocator.free(self.relative);
        allocator.free(self.absolute);
        self.* = undefined;
    }
};

pub fn normalizeWorkspacePath(allocator: std.mem.Allocator, workspace_root: []const u8, input: []const u8) PathPolicyError!NormalizedPath {
    if (input.len == 0) return error.EmptyPath;
    if (std.mem.indexOfScalar(u8, input, 0) != null) return error.PathContainsNul;
    if (std.fs.path.isAbsolute(input)) return error.AbsolutePathRejected;

    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);
    var it = std.mem.tokenizeAny(u8, input, "/\\");
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len == 0) return error.PathEscapesWorkspace;
            _ = parts.pop();
            continue;
        }
        try parts.append(allocator, part);
    }

    const relative = if (parts.items.len == 0)
        try allocator.dupe(u8, ".")
    else
        try std.mem.join(allocator, "/", parts.items);
    errdefer allocator.free(relative);

    const absolute = if (std.mem.eql(u8, relative, "."))
        try allocator.dupe(u8, workspace_root)
    else
        try std.fs.path.join(allocator, &.{ workspace_root, relative });
    errdefer allocator.free(absolute);

    return .{ .relative = relative, .absolute = absolute };
}

pub fn dirname(allocator: std.mem.Allocator, relative: []const u8) !?[]const u8 {
    const idx = std.mem.lastIndexOfScalar(u8, relative, '/') orelse return null;
    return try allocator.dupe(u8, relative[0..idx]);
}
