const std = @import("std");
const provider = @import("pig").provider;

fn parseFixture(path: []const u8, collector: *provider.testing.EventCollector) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(bytes);
    try provider.anthropic.parseBytes(std.testing.allocator, bytes, collector.sink());
}

test "anthropic text stream maps to unified events" {
    var collector = provider.testing.EventCollector.init(std.testing.allocator);
    defer collector.deinit();

    try parseFixture("fixtures/provider/anthropic/text-stream.sse", &collector);

    try std.testing.expectEqual(provider.ProviderEventTag.message_start, collector.events.items[0].tag);
    try std.testing.expectEqual(provider.ProviderEventTag.text_delta, collector.events.items[1].tag);
    try std.testing.expectEqualStrings("hello", collector.events.items[1].text.?);
    try std.testing.expectEqual(provider.ProviderEventTag.usage, collector.events.items[2].tag);
    try std.testing.expectEqual(@as(?u64, 4), collector.events.items[2].usage.?.input_tokens);
    try std.testing.expectEqual(@as(?u64, 2), collector.events.items[2].usage.?.output_tokens);
    try std.testing.expectEqual(provider.ProviderEventTag.message_end, collector.events.items[3].tag);
    try std.testing.expectEqual(provider.ProviderEventTag.done, collector.events.items[4].tag);
}

test "anthropic tool use stream assembles tool call by content block index" {
    var collector = provider.testing.EventCollector.init(std.testing.allocator);
    defer collector.deinit();

    try parseFixture("fixtures/provider/anthropic/tool-use-stream.sse", &collector);

    try std.testing.expectEqual(provider.ProviderEventTag.tool_call_start, collector.events.items[1].tag);
    try std.testing.expectEqualStrings("toolu_1", collector.events.items[1].id.?);
    try std.testing.expectEqual(provider.ProviderEventTag.tool_call_delta, collector.events.items[2].tag);
    try std.testing.expectEqual(provider.ProviderEventTag.tool_call_end, collector.events.items[4].tag);
    try std.testing.expectEqualStrings("{\"path\":\"README.md\"}", collector.events.items[4].arguments_json.?);
}

test "anthropic parser rejects malformed stream sequences" {
    var missing_stop = provider.testing.EventCollector.init(std.testing.allocator);
    defer missing_stop.deinit();
    const missing_bytes =
        "event: message_start\n" ++
        "data: {\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\"}}\n\n";
    try std.testing.expectError(error.StreamParseError, provider.anthropic.parseBytes(std.testing.allocator, missing_bytes, missing_stop.sink()));
    try std.testing.expectEqual(provider.ProviderEventTag.error_event, missing_stop.events.items[missing_stop.events.items.len - 1].tag);

    var unknown_delta = provider.testing.EventCollector.init(std.testing.allocator);
    defer unknown_delta.deinit();
    const delta_bytes =
        "event: message_start\n" ++
        "data: {\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\"}}\n\n" ++
        "event: content_block_delta\n" ++
        "data: {\"index\":3,\"delta\":{\"type\":\"text_delta\",\"text\":\"oops\"}}\n\n";
    try std.testing.expectError(error.StreamParseError, provider.anthropic.parseBytes(std.testing.allocator, delta_bytes, unknown_delta.sink()));
}
