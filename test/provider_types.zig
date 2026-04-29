const std = @import("std");
const pig = @import("pig");
const provider = pig.provider;

test "provider kinds roles usage and compatibility exports" {
    try std.testing.expectEqual(provider.ProviderKind.openai_compatible, try provider.ProviderKind.fromString("openai_compatible"));
    try std.testing.expectEqualStrings("anthropic", provider.ProviderKind.toString(.anthropic));
    try std.testing.expectError(error.UnknownProviderKind, provider.ProviderKind.fromString("unknown"));
    try std.testing.expectEqual(provider.ProviderStatus.unconfigured, provider.ProviderStatus.unconfigured);

    try std.testing.expectEqual(provider.Role.assistant, try provider.Role.fromString("assistant"));
    try std.testing.expectEqualStrings("tool", provider.Role.toString(.tool));
    try std.testing.expectError(error.UnknownRole, provider.Role.fromString("bot"));

    const a = provider.Usage{ .input_tokens = 2, .output_tokens = null, .cache_read_tokens = 1, .cache_write_tokens = null };
    const b = provider.Usage{ .input_tokens = 3, .output_tokens = 5, .cache_read_tokens = null, .cache_write_tokens = null };
    const sum = provider.Usage.add(a, b);
    try std.testing.expectEqual(@as(?u64, 5), sum.input_tokens);
    try std.testing.expectEqual(@as(?u64, 5), sum.output_tokens);
    try std.testing.expectEqual(@as(?u64, 1), sum.cache_read_tokens);
    try std.testing.expectEqual(@as(?u64, null), sum.cache_write_tokens);
}

test "message and content views are borrowed and owned messages deinit" {
    const blocks = [_]provider.ContentBlockView{
        .{ .text = .{ .text = "hello" } },
        .{ .tool_call = .{ .id = "call-1", .name = "read", .arguments_json = "{}" } },
    };
    const view = provider.MessageView{ .role = .user, .content = &blocks };
    try std.testing.expectEqual(provider.Role.user, view.role);
    try std.testing.expectEqual(@as(usize, 2), view.content.len);

    var owned = try provider.OwnedMessage.cloneFromView(std.testing.allocator, view);
    defer owned.deinit(std.testing.allocator);
    try std.testing.expectEqual(provider.Role.user, owned.role);
    try std.testing.expectEqualStrings("hello", owned.content[0].text.text);
    try std.testing.expectEqualStrings("read", owned.content[1].tool_call.name);
}

test "provider error event never needs to include secrets" {
    const err = provider.ProviderErrorEvent{ .category = .auth, .message = "missing API key", .retryable = false };
    try std.testing.expectEqual(provider.ProviderErrorKind.auth, err.category);
    try std.testing.expect(std.mem.indexOf(u8, err.message, "test-openai-key") == null);
}

fn cloneOwnedToolCallWithAllocator(allocator: std.mem.Allocator) !void {
    const view = provider.ContentBlockView{ .tool_call = .{ .id = "call", .name = "tool", .arguments_json = "{}" } };
    const owned = try provider.OwnedContentBlock.cloneFromView(allocator, view);
    defer owned.deinit(allocator);
}

test "owned content clone cleans up partial allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, cloneOwnedToolCallWithAllocator, .{});
}
