const std = @import("std");
const pig = @import("pig");

test "model registry merges and project overrides global" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root);
    const global = try std.fs.path.join(std.testing.allocator, &.{ root, "global-models.json" });
    defer std.testing.allocator.free(global);
    const project = try std.fs.path.join(std.testing.allocator, &.{ root, "project-models.json" });
    defer std.testing.allocator.free(project);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = global, .data = "{\"models\":[{\"id\":\"local\",\"provider_id\":\"openai_compatible\",\"display_name\":\"Global\",\"model\":\"global-model\",\"enabled\":true}],\"default_model\":\"local\"}" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = project, .data = "{\"models\":[{\"id\":\"local\",\"provider_id\":\"openai_compatible\",\"display_name\":\"Project\",\"model\":\"project-model\",\"enabled\":true}]}" });

    var registry = try pig.resources.models.loadRegistry(std.testing.allocator, std.testing.io, global, project);
    defer registry.deinit(std.testing.allocator);
    const entry = registry.find("local").?;
    try std.testing.expectEqualStrings("project-model", entry.model);
    try std.testing.expect(registry.warnings.items.len > 0);
}

test "model selection supports transient cli provider model" {
    var registry = try pig.resources.models.loadRegistry(std.testing.allocator, std.testing.io, "missing-global-models.json", "missing-project-models.json");
    defer registry.deinit(std.testing.allocator);
    var entry = try pig.resources.models.selectModel(std.testing.allocator, &registry, .{ .provider_override = "openai_compatible", .model_override = "custom-model", .settings_model = "gpt-4.1-mini" });
    defer entry.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("openai_compatible", entry.provider_id);
    try std.testing.expectEqualStrings("custom-model", entry.model);
}
