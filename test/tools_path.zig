const std = @import("std");
const pig = @import("pig");
const tools = pig.tools;

test "workspace paths normalize and reject escapes" {
    var p = try tools.path.normalizeWorkspacePath(std.testing.allocator, "/tmp/work", "src/./main.zig");
    defer p.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("src/main.zig", p.relative);
    try std.testing.expect(std.mem.endsWith(u8, p.absolute, "/tmp/work/src/main.zig"));

    try std.testing.expectError(error.EmptyPath, tools.path.normalizeWorkspacePath(std.testing.allocator, "/tmp/work", ""));
    try std.testing.expectError(error.PathEscapesWorkspace, tools.path.normalizeWorkspacePath(std.testing.allocator, "/tmp/work", "../x"));
    try std.testing.expectError(error.AbsolutePathRejected, tools.path.normalizeWorkspacePath(std.testing.allocator, "/tmp/work", "/etc/passwd"));
    try std.testing.expectError(error.PathContainsNul, tools.path.normalizeWorkspacePath(std.testing.allocator, "/tmp/work", "a\x00b"));
}
