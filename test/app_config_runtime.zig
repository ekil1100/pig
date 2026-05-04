const std = @import("std");
const pig = @import("pig");

test "config runtime resolves context prompt for injected model path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root);
    const pig_dir = try std.fs.path.join(std.testing.allocator, &.{ root, ".pig" });
    defer std.testing.allocator.free(pig_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, pig_dir);
    const agents = try std.fs.path.join(std.testing.allocator, &.{ root, "AGENTS.md" });
    defer std.testing.allocator.free(agents);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = agents, .data = "project instructions" });

    var resolved = try pig.app.config_runtime.resolve(.{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .env_home = root,
        .config = .{ .mode = .print, .prompt = "hi", .cwd = root },
    });
    defer resolved.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, resolved.systemPrompt().?, "project instructions") != null);
}
