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

test "model factory creates deepseek openai-compatible client" {
    var entry = pig.resources.models.ModelEntry{
        .id = try std.testing.allocator.dupe(u8, "deepseek-v4-flash"),
        .provider_id = try std.testing.allocator.dupe(u8, "deepseek"),
        .display_name = try std.testing.allocator.dupe(u8, "DeepSeek V4 Flash"),
        .model = try std.testing.allocator.dupe(u8, "deepseek-v4-flash"),
        .base_url = null,
        .source = try pig.resources.common.ResourceSourceInfo.clone(std.testing.allocator, .builtin, "test", 0),
    };
    defer entry.deinit(std.testing.allocator);
    var env = pig.provider.auth.TestEnv.init(&.{
        .{ .key = "DEEPSEEK_API_KEY", .value = "deepseek-key" },
    });

    var client = try pig.app.model_factory.create(.{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .auth_json_path = "missing-auth.json",
        .env = env.reader(),
        .model = entry,
    });
    defer client.deinit();
    try std.testing.expectEqual(pig.provider.ProviderKind.deepseek, client.provider_kind);
    try std.testing.expectEqualStrings("deepseek-key", client.api_key);
    try std.testing.expectEqualStrings("https://api.deepseek.com", client.base_url);
    try std.testing.expectEqualStrings("deepseek-v4-flash", client.model);
}

test "model factory reports unsupported non-openai live providers" {
    var entry = pig.resources.models.ModelEntry{
        .id = try std.testing.allocator.dupe(u8, "anthropic-test"),
        .provider_id = try std.testing.allocator.dupe(u8, "anthropic"),
        .display_name = try std.testing.allocator.dupe(u8, "Anthropic Test"),
        .model = try std.testing.allocator.dupe(u8, "claude-test"),
        .base_url = null,
        .source = try pig.resources.common.ResourceSourceInfo.clone(std.testing.allocator, .builtin, "test", 0),
    };
    defer entry.deinit(std.testing.allocator);

    try std.testing.expectError(error.UnsupportedTransport, pig.app.model_factory.create(.{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .auth_json_path = "missing-auth.json",
        .model = entry,
    }));
}
