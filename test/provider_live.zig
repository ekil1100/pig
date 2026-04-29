const std = @import("std");
const provider = @import("pig").provider;

test "provider live config skips unless explicitly enabled with complete env" {
    var disabled = provider.live.SmokeEnv.init(&.{});
    try std.testing.expectEqual(provider.live.Decision.skip, provider.live.decide(disabled.reader()).kind);

    var incomplete = provider.live.SmokeEnv.init(&.{.{ .key = "PIG_PROVIDER_LIVE", .value = "1" }});
    const missing = provider.live.decide(incomplete.reader());
    try std.testing.expectEqual(provider.live.Decision.skip, missing.kind);
    try std.testing.expect(missing.missing_count > 0);
    try std.testing.expectEqualStrings("PIG_OPENAI_COMPAT_BASE_URL", missing.missingName(0).?);

    var partial = provider.live.SmokeEnv.init(&.{
        .{ .key = "PIG_PROVIDER_LIVE", .value = "1" },
        .{ .key = "PIG_OPENAI_COMPAT_BASE_URL", .value = "https://example.invalid/v1" },
    });
    const partial_missing = provider.live.decide(partial.reader());
    try std.testing.expectEqualStrings("PIG_OPENAI_COMPAT_API_KEY", partial_missing.missingName(0).?);

    var complete = provider.live.SmokeEnv.init(&.{
        .{ .key = "PIG_PROVIDER_LIVE", .value = "1" },
        .{ .key = "PIG_OPENAI_COMPAT_BASE_URL", .value = "https://example.invalid/v1" },
        .{ .key = "PIG_OPENAI_COMPAT_API_KEY", .value = "test-openai-key" },
        .{ .key = "PIG_OPENAI_COMPAT_MODEL", .value = "test-model" },
    });
    try std.testing.expectEqual(provider.live.Decision.run, provider.live.decide(complete.reader()).kind);
}
