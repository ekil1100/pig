const std = @import("std");
const pig = @import("pig");

test "model factory reports missing auth without reading real env" {
    var source = try pig.resources.common.ResourceSourceInfo.clone(std.testing.allocator, .builtin, "test", 0);
    defer source.deinit(std.testing.allocator);
    var entry = pig.resources.models.ModelEntry{
        .id = try std.testing.allocator.dupe(u8, "test"),
        .provider_id = try std.testing.allocator.dupe(u8, "openai_compatible"),
        .display_name = try std.testing.allocator.dupe(u8, "Test"),
        .model = try std.testing.allocator.dupe(u8, "test-model"),
        .base_url = null,
        .source = try pig.resources.common.ResourceSourceInfo.clone(std.testing.allocator, source.source, source.path, source.priority),
    };
    defer entry.deinit(std.testing.allocator);
    try std.testing.expectError(error.MissingApiKey, pig.app.model_factory.create(.{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .auth_json_path = "missing-auth.json",
        .model = entry,
    }));
}
