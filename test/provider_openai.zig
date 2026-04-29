const std = @import("std");
const provider = @import("pig").provider;

fn parseFixture(path: []const u8, collector: *provider.testing.EventCollector) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(bytes);
    try provider.openai_compatible.parseBytes(std.testing.allocator, bytes, collector.sink());
}

test "openai compatible text stream maps to unified events" {
    var collector = provider.testing.EventCollector.init(std.testing.allocator);
    defer collector.deinit();

    try parseFixture("fixtures/provider/openai-compatible/text-stream.sse", &collector);

    try std.testing.expectEqual(provider.ProviderEventTag.message_start, collector.events.items[0].tag);
    try std.testing.expectEqual(provider.ProviderEventTag.text_delta, collector.events.items[1].tag);
    try std.testing.expectEqualStrings("hel", collector.events.items[1].text.?);
    try std.testing.expectEqual(provider.ProviderEventTag.message_delta, collector.events.items[3].tag);
    try std.testing.expectEqual(provider.ProviderEventTag.message_end, collector.events.items[4].tag);
    try std.testing.expectEqual(provider.ProviderEventTag.done, collector.events.items[5].tag);
}

test "openai compatible tool stream assembles tool call arguments" {
    var collector = provider.testing.EventCollector.init(std.testing.allocator);
    defer collector.deinit();

    try parseFixture("fixtures/provider/openai-compatible/tool-call-stream.sse", &collector);

    try std.testing.expectEqual(provider.ProviderEventTag.tool_call_start, collector.events.items[1].tag);
    try std.testing.expectEqualStrings("call_1", collector.events.items[1].id.?);
    try std.testing.expectEqual(provider.ProviderEventTag.tool_call_delta, collector.events.items[2].tag);
    try std.testing.expectEqual(provider.ProviderEventTag.tool_call_end, collector.events.items[5].tag);
    try std.testing.expectEqualStrings("{\"path\":\"README.md\"}", collector.events.items[5].arguments_json.?);
}

test "openai compatible usage and missing done behavior" {
    var usage_collector = provider.testing.EventCollector.init(std.testing.allocator);
    defer usage_collector.deinit();
    try parseFixture("fixtures/provider/openai-compatible/usage-final-chunk.sse", &usage_collector);
    try std.testing.expectEqual(provider.ProviderEventTag.usage, usage_collector.events.items[2].tag);
    try std.testing.expectEqual(@as(?u64, 3), usage_collector.events.items[2].usage.?.input_tokens);

    var missing_done = provider.testing.EventCollector.init(std.testing.allocator);
    defer missing_done.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "fixtures/provider/openai-compatible/missing-done.sse", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectError(error.StreamParseError, provider.openai_compatible.parseBytes(std.testing.allocator, bytes, missing_done.sink()));
    try std.testing.expectEqual(provider.ProviderEventTag.error_event, missing_done.events.items[missing_done.events.items.len - 1].tag);
    for (missing_done.events.items) |event| try std.testing.expect(event.tag != .done);
}

test "openai request builder creates streaming chat completions request" {
    const blocks = [_]provider.ContentBlockView{.{ .text = .{ .text = "hello" } }};
    const messages = [_]provider.MessageView{.{ .role = .user, .content = &blocks }};
    var req = try provider.openai_compatible.buildChatCompletionsRequest(std.testing.allocator, .{
        .base_url = "https://example.invalid/v1",
        .api_key = "test-openai-key",
        .model = "test-model",
    }, &messages);
    defer req.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("POST", req.method);
    try std.testing.expectEqualStrings("https://example.invalid/v1/chat/completions", req.url);
    try std.testing.expect(std.mem.indexOf(u8, req.body, "\"stream\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, req.body, "test-openai-key") == null);
    try std.testing.expect(req.headerValue("Authorization") != null);
}

test "openai parser handles provider errors and multiple tool indexes" {
    var provider_error = provider.testing.EventCollector.init(std.testing.allocator);
    defer provider_error.deinit();
    const err_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "fixtures/provider/openai-compatible/stream-error.sse", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(err_bytes);
    try provider.openai_compatible.parseBytes(std.testing.allocator, err_bytes, provider_error.sink());
    try std.testing.expectEqual(provider.ProviderEventTag.error_event, provider_error.events.items[0].tag);
    try std.testing.expectEqual(@as(usize, 1), provider_error.events.items.len);

    var multi = provider.testing.EventCollector.init(std.testing.allocator);
    defer multi.deinit();
    const multi_bytes =
        "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"a\",\"function\":{\"name\":\"one\",\"arguments\":\"{}\"}},{\"index\":1,\"id\":\"b\",\"function\":{\"name\":\"two\",\"arguments\":\"{}\"}}]},\"finish_reason\":\"tool_calls\"}]}\n\n" ++
        "data: [DONE]\n\n";
    try provider.openai_compatible.parseBytes(std.testing.allocator, multi_bytes, multi.sink());
    var tool_end_count: usize = 0;
    for (multi.events.items) |event| {
        if (event.tag == .tool_call_end) tool_end_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), tool_end_count);
}

test "openai request builder JSON-escapes model and content" {
    const blocks = [_]provider.ContentBlockView{.{ .text = .{ .text = "hello \"zig\"\n" } }};
    const messages = [_]provider.MessageView{.{ .role = .user, .content = &blocks }};
    var req = try provider.openai_compatible.buildChatCompletionsRequest(std.testing.allocator, .{
        .base_url = "https://example.invalid/v1/",
        .api_key = "test-openai-key",
        .model = "test\"model",
    }, &messages);
    defer req.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, req.body, "test\\\"model") != null);
    try std.testing.expect(std.mem.indexOf(u8, req.body, "hello \\\"zig\\\"\\n") != null);
}

fn buildEscapedRequestWithAllocator(allocator: std.mem.Allocator) !void {
    const blocks = [_]provider.ContentBlockView{.{ .text = .{ .text = "hello \"zig\"\n\x01" } }};
    const messages = [_]provider.MessageView{.{ .role = .user, .content = &blocks }};
    var req = try provider.openai_compatible.buildChatCompletionsRequest(allocator, .{
        .base_url = "https://example.invalid/v1/",
        .api_key = "test-openai-key",
        .model = "test\"model",
    }, &messages);
    defer req.deinit(allocator);
}

test "openai request builder cleans up partial allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, buildEscapedRequestWithAllocator, .{});
}
