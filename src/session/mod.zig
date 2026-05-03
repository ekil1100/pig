const std = @import("std");
const paths = @import("../util/paths.zig");

pub const entry = @import("entry.zig");
pub const store = @import("store.zig");
pub const tree = @import("tree.zig");

pub const SessionPathSet = struct {
    sessions_dir: []const u8,

    pub fn deinit(self: SessionPathSet, allocator: std.mem.Allocator) void {
        allocator.free(self.sessions_dir);
    }
};

pub fn resolveDefaultPaths(allocator: std.mem.Allocator) !SessionPathSet {
    const set = try paths.resolveDefaultPaths(allocator);
    defer set.deinit(allocator);

    return .{
        .sessions_dir = try allocator.dupe(u8, set.global_sessions),
    };
}
