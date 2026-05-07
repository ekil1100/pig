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
    try std.testing.expect(std.mem.indexOf(u8, resolved.systemPrompt().?, "You are Pig") != null);
    try std.testing.expect(std.mem.indexOf(u8, resolved.systemPrompt().?, "project instructions") != null);
}

test "config runtime builds default system prompt and tool list without context files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root);
    const pig_dir = try std.fs.path.join(std.testing.allocator, &.{ root, ".pig" });
    defer std.testing.allocator.free(pig_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, pig_dir);

    var resolved = try pig.app.config_runtime.resolve(.{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .env_home = root,
        .config = .{ .mode = .print, .prompt = "hi", .cwd = root },
    });
    defer resolved.deinit(std.testing.allocator);
    const prompt = resolved.systemPrompt().?;
    try std.testing.expect(std.mem.indexOf(u8, prompt, "You are Pig") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Current working directory:") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "- read:") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "- grep:") == null);
}

test "config runtime provider override without model stays unselected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root);
    const pig_dir = try std.fs.path.join(std.testing.allocator, &.{ root, ".pig" });
    defer std.testing.allocator.free(pig_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, pig_dir);

    var resolved = try pig.app.config_runtime.resolve(.{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .env_home = root,
        .config = .{ .mode = .print, .prompt = "hi", .cwd = root, .provider = "deepseek" },
    });
    defer resolved.deinit(std.testing.allocator);
    try std.testing.expect(resolved.model == null);
    try std.testing.expectEqualStrings("deepseek", resolved.effective_run_config.provider.?);
    try std.testing.expectEqual(@as(?[]const u8, null), resolved.effective_run_config.model);
}

test "config runtime keeps default model empty" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root);
    const pig_dir = try std.fs.path.join(std.testing.allocator, &.{ root, ".pig" });
    defer std.testing.allocator.free(pig_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, pig_dir);

    var resolved = try pig.app.config_runtime.resolve(.{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .env_home = root,
        .config = .{ .mode = .print, .prompt = "hi", .cwd = root },
    });
    defer resolved.deinit(std.testing.allocator);
    try std.testing.expect(resolved.model == null);
    try std.testing.expectEqual(@as(?[]const u8, null), resolved.effective_run_config.provider);
    try std.testing.expectEqual(@as(?[]const u8, null), resolved.effective_run_config.model);
}

test "config runtime uses explicit settings model" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root);
    const pig_dir = try std.fs.path.join(std.testing.allocator, &.{ root, ".pig" });
    defer std.testing.allocator.free(pig_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, pig_dir);
    const settings = try std.fs.path.join(std.testing.allocator, &.{ pig_dir, "settings.json" });
    defer std.testing.allocator.free(settings);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = settings, .data = "{\"model\":\"deepseek-v4-pro\"}" });

    var resolved = try pig.app.config_runtime.resolve(.{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .env_home = root,
        .config = .{ .mode = .print, .prompt = "hi", .cwd = root },
    });
    defer resolved.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("deepseek-v4-pro", resolved.model.?.id);
    try std.testing.expectEqualStrings("deepseek-v4-pro", resolved.effective_run_config.model.?);
}
