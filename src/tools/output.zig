const std = @import("std");

pub const TruncatedOutput = struct {
    visible: []const u8,
    truncated: bool,
    full_output_path: ?[]const u8 = null,

    pub fn deinit(self: *TruncatedOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.visible);
        if (self.full_output_path) |p| allocator.free(p);
        self.* = undefined;
    }
};

pub fn truncateAndMaybeSpill(allocator: std.mem.Allocator, io: std.Io, spill_dir: []const u8, name: []const u8, content: []const u8, limit: usize) !TruncatedOutput {
    if (content.len <= limit) return .{ .visible = try allocator.dupe(u8, content), .truncated = false };
    const visible = try allocator.dupe(u8, content[0..limit]);
    errdefer allocator.free(visible);
    try std.Io.Dir.cwd().createDirPath(io, spill_dir);
    const digest = std.hash.Wyhash.hash(0, content);
    const filename = try std.fmt.allocPrint(allocator, "{s}-{d}-{x}.txt", .{ name, content.len, digest });
    defer allocator.free(filename);
    const full_path = try std.fs.path.join(allocator, &.{ spill_dir, filename });
    errdefer allocator.free(full_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = full_path, .data = content });
    return .{ .visible = visible, .truncated = true, .full_output_path = full_path };
}
