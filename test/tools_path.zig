const std = @import("std");
const pig = @import("pig");
const tools = pig.tools;

test "workspace paths normalize and reject escapes" {
    var p = try tools.path.normalizeWorkspacePath(std.testing.allocator, "/tmp/work", "src/./main.zig");
    defer p.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("src/main.zig", p.relative);
    try std.testing.expect(std.mem.endsWith(u8, p.absolute, "/tmp/work/src/main.zig"));

    var absolute = try tools.path.normalizeWorkspacePath(std.testing.allocator, "/tmp/work", "/tmp/work/src/main.zig");
    defer absolute.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("src/main.zig", absolute.relative);
    try std.testing.expectEqualStrings("/tmp/work/src/main.zig", absolute.absolute);

    var root = try tools.path.normalizeWorkspacePath(std.testing.allocator, "/tmp/work", "/tmp/work/");
    defer root.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(".", root.relative);
    try std.testing.expectEqualStrings("/tmp/work", root.absolute);

    try std.testing.expectError(error.EmptyPath, tools.path.normalizeWorkspacePath(std.testing.allocator, "/tmp/work", ""));
    try std.testing.expectError(error.PathEscapesWorkspace, tools.path.normalizeWorkspacePath(std.testing.allocator, "/tmp/work", "../x"));
    try std.testing.expectError(error.PathEscapesWorkspace, tools.path.normalizeWorkspacePath(std.testing.allocator, "/tmp/work", "/etc/passwd"));
    try std.testing.expectError(error.PathEscapesWorkspace, tools.path.normalizeWorkspacePath(std.testing.allocator, "/tmp/work", "/tmp/workspace/main.zig"));
    try std.testing.expectError(error.PathContainsNul, tools.path.normalizeWorkspacePath(std.testing.allocator, "/tmp/work", "a\x00b"));
}
