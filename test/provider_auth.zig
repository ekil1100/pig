const std = @import("std");
const provider = @import("pig").provider;

test "auth resolver uses explicit config then auth json then env" {
    var env = provider.auth.TestEnv.init(&.{
        .{ .key = "PIG_OPENAI_COMPAT_API_KEY", .value = "env-key" },
    });

    const explicit = try provider.auth.resolveApiKey(std.testing.allocator, .{
        .kind = .openai_compatible,
        .explicit_api_key = "explicit-key",
        .auth_json_path = null,
        .env = env.reader(),
    });
    defer std.testing.allocator.free(explicit);
    try std.testing.expectEqualStrings("explicit-key", explicit);

    const json_key = try provider.auth.resolveApiKey(std.testing.allocator, .{
        .kind = .openai_compatible,
        .explicit_api_key = null,
        .auth_json_path = "fixtures/provider/auth/auth-openai.json",
        .io = std.testing.io,
        .env = env.reader(),
    });
    defer std.testing.allocator.free(json_key);
    try std.testing.expectEqualStrings("test-openai-key", json_key);

    const env_key = try provider.auth.resolveApiKey(std.testing.allocator, .{
        .kind = .openai_compatible,
        .explicit_api_key = null,
        .auth_json_path = null,
        .env = env.reader(),
    });
    defer std.testing.allocator.free(env_key);
    try std.testing.expectEqualStrings("env-key", env_key);
}

test "missing auth key returns sanitized auth error" {
    var env = provider.auth.TestEnv.init(&.{});
    const result = provider.auth.resolveApiKey(std.testing.allocator, .{
        .kind = .anthropic,
        .explicit_api_key = null,
        .auth_json_path = null,
        .env = env.reader(),
    });
    try std.testing.expectError(error.MissingApiKey, result);

    const msg = provider.auth.formatMissingKeyMessage(.anthropic);
    try std.testing.expect(std.mem.indexOf(u8, msg, "test-openai-key") == null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "ANTHROPIC") != null);
}

test "invalid auth json shape is sanitized" {
    var env = provider.auth.TestEnv.init(&.{});
    const result = provider.auth.resolveApiKey(std.testing.allocator, .{
        .kind = .openai_compatible,
        .explicit_api_key = null,
        .auth_json_path = "fixtures/provider/auth/invalid-auth.json",
        .io = std.testing.io,
        .env = env.reader(),
    });
    try std.testing.expectError(error.InvalidAuthJson, result);
}
