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
    var entry = try pig.resources.models.selectModel(std.testing.allocator, &registry, .{ .provider_override = "openai_compatible", .model_override = "custom-model" });
    defer entry.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("openai_compatible", entry.provider_id);
    try std.testing.expectEqualStrings("custom-model", entry.model);
}

test "model selection uses provider default when cli provider omits model" {
    var registry = try pig.resources.models.loadRegistry(std.testing.allocator, std.testing.io, "missing-global-models.json", "missing-project-models.json");
    defer registry.deinit(std.testing.allocator);
    var entry = try pig.resources.models.selectModel(std.testing.allocator, &registry, .{ .provider_override = "deepseek", .model_override = null });
    defer entry.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("deepseek-v4-flash", entry.id);
    try std.testing.expectEqualStrings("deepseek", entry.provider_id);
    try std.testing.expectEqualStrings("deepseek-v4-flash", entry.model);
    try std.testing.expectEqualStrings("https://api.deepseek.com", entry.base_url.?);
}

test "model registry includes builtin deepseek models" {
    var registry = try pig.resources.models.loadRegistry(std.testing.allocator, std.testing.io, "missing-global-models.json", "missing-project-models.json");
    defer registry.deinit(std.testing.allocator);
    const flash = registry.find("deepseek-v4-flash").?;
    try std.testing.expectEqualStrings("deepseek", flash.provider_id);
    try std.testing.expectEqualStrings("deepseek-v4-flash", flash.model);
    try std.testing.expectEqualStrings("https://api.deepseek.com", flash.base_url.?);
    const pro = registry.find("deepseek-v4-pro").?;
    try std.testing.expectEqualStrings("deepseek", pro.provider_id);
    try std.testing.expectEqualStrings("gpt-4.1-mini", registry.default_model.?);
}

test "model selection prefers settings model before registry default" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root);
    const global = try std.fs.path.join(std.testing.allocator, &.{ root, "global-models.json" });
    defer std.testing.allocator.free(global);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = global, .data = "{\"models\":[{\"id\":\"local\",\"provider_id\":\"openai_compatible\",\"display_name\":\"Local\",\"model\":\"local-model\",\"enabled\":true}]}" });

    var registry = try pig.resources.models.loadRegistry(std.testing.allocator, std.testing.io, global, "missing-project-models.json");
    defer registry.deinit(std.testing.allocator);
    var entry = try pig.resources.models.selectModel(std.testing.allocator, &registry, .{ .settings_model = "local" });
    defer entry.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("local", entry.id);
    try std.testing.expectEqualStrings("local-model", entry.model);
}

test "model selection supports settings provider without pinning a model" {
    var registry = try pig.resources.models.loadRegistry(std.testing.allocator, std.testing.io, "missing-global-models.json", "missing-project-models.json");
    defer registry.deinit(std.testing.allocator);
    var entry = try pig.resources.models.selectModel(std.testing.allocator, &registry, .{ .settings_provider = "deepseek" });
    defer entry.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("deepseek-v4-flash", entry.id);
    try std.testing.expectEqualStrings("deepseek", entry.provider_id);
}

test "model selection keeps registry entry when provider and model id both match" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root);
    const global = try std.fs.path.join(std.testing.allocator, &.{ root, "global-models.json" });
    defer std.testing.allocator.free(global);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = global, .data = "{\"models\":[{\"id\":\"custom-local\",\"provider_id\":\"custom\",\"display_name\":\"Custom Local\",\"model\":\"provider-local\",\"base_url\":\"https://local.invalid/v1\",\"enabled\":true}]}" });

    var registry = try pig.resources.models.loadRegistry(std.testing.allocator, std.testing.io, global, "missing-project-models.json");
    defer registry.deinit(std.testing.allocator);
    var entry = try pig.resources.models.selectModel(std.testing.allocator, &registry, .{ .settings_provider = "custom", .settings_model = "custom-local" });
    defer entry.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("custom-local", entry.id);
    try std.testing.expectEqualStrings("provider-local", entry.model);
    try std.testing.expectEqualStrings("https://local.invalid/v1", entry.base_url.?);
    try std.testing.expectEqual(pig.resources.models.ModelScope.global, entry.scope);
}
