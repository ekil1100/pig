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

test "config runtime provider override selects provider default model" {
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
    try std.testing.expectEqualStrings("deepseek", resolved.model.provider_id);
    try std.testing.expectEqualStrings("deepseek-v4-flash", resolved.model.model);
    try std.testing.expectEqualStrings("deepseek", resolved.effective_run_config.provider.?);
    try std.testing.expectEqual(@as(?[]const u8, null), resolved.effective_run_config.model);
}

test "config runtime keeps default model implicit" {
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
    try std.testing.expectEqualStrings("gpt-4.1-mini", resolved.model.id);
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
    try std.testing.expectEqualStrings("deepseek-v4-pro", resolved.model.id);
    try std.testing.expectEqualStrings("deepseek-v4-pro", resolved.effective_run_config.model.?);
}
