const std = @import("std");
const pig = @import("pig");

test "settings merge global project and cli overrides" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root);
    const global = try std.fs.path.join(std.testing.allocator, &.{ root, "global.json" });
    defer std.testing.allocator.free(global);
    const project = try std.fs.path.join(std.testing.allocator, &.{ root, "project.json" });
    defer std.testing.allocator.free(project);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = global, .data = "{\"provider\":\"openai_compatible\",\"model\":\"global\",\"tools\":{\"enabled\":false},\"context\":{\"max_bytes\":12}}" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = project, .data = "{\"model\":\"project\",\"tools\":{\"include_p1\":true},\"context\":{\"include\":[\"AGENTS.md\"]}}" });

    var loaded = try pig.resources.settings.load(std.testing.allocator, std.testing.io, global, project, .{ .model = "cli" });
    defer loaded.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("openai_compatible", loaded.settings.provider.?);
    try std.testing.expectEqualStrings("cli", loaded.settings.model.?);
    try std.testing.expect(!loaded.settings.tools_enabled);
    try std.testing.expect(loaded.settings.include_p1_tools);
    try std.testing.expectEqual(@as(usize, 12), loaded.settings.context_max_bytes);
    try std.testing.expectEqual(@as(usize, 1), loaded.settings.context_include.len);
    try std.testing.expectEqualStrings("AGENTS.md", loaded.settings.context_include[0]);
}

test "settings missing files are warnings and model/provider stay unset" {
    var loaded = try pig.resources.settings.load(std.testing.allocator, std.testing.io, "missing-global.json", "missing-project.json", .{});
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), loaded.warnings.items.len);
    try std.testing.expectEqual(@as(?[]const u8, null), loaded.settings.provider);
    try std.testing.expectEqual(@as(?[]const u8, null), loaded.settings.model);
}

test "saving model selection preserves existing settings fields" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root);
    const project = try std.fs.path.join(std.testing.allocator, &.{ root, ".pig", "settings.json" });
    defer std.testing.allocator.free(project);

    try std.Io.Dir.cwd().createDirPath(std.testing.io, std.fs.path.dirname(project).?);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = project, .data = "{\"model\":\"old\",\"tools\":{\"enabled\":false}}" });

    try pig.resources.settings.saveModelSelection(std.testing.allocator, std.testing.io, project, "deepseek", "deepseek-v4-flash");

    var loaded = try pig.resources.settings.load(std.testing.allocator, std.testing.io, "missing-global.json", project, .{});
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("deepseek", loaded.settings.provider.?);
    try std.testing.expectEqualStrings("deepseek-v4-flash", loaded.settings.model.?);
    try std.testing.expect(!loaded.settings.tools_enabled);
}
