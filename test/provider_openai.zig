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

test "openai compatible parser preserves malformed tool arguments for tool layer" {
    var collector = provider.testing.EventCollector.init(std.testing.allocator);
    defer collector.deinit();

    const bytes =
        "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_bad\",\"function\":{\"name\":\"edit\",\"arguments\":\"{\\\"path\\\":\"}}]}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n" ++
        "data: [DONE]\n\n";

    try provider.openai_compatible.parseBytes(std.testing.allocator, bytes, collector.sink());
    try std.testing.expectEqual(provider.ProviderEventTag.tool_call_end, collector.events.items[3].tag);
    try std.testing.expectEqualStrings("call_bad", collector.events.items[3].id.?);
    try std.testing.expectEqualStrings("{\"path\":", collector.events.items[3].arguments_json.?);
}

test "openai compatible reasoning content maps to thinking deltas" {
    var collector = provider.testing.EventCollector.init(std.testing.allocator);
    defer collector.deinit();

    const bytes =
        "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"plan\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"done\"},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: [DONE]\n\n";
    try provider.openai_compatible.parseBytes(std.testing.allocator, bytes, collector.sink());
    try std.testing.expectEqual(provider.ProviderEventTag.thinking_delta, collector.events.items[1].tag);
    try std.testing.expectEqualStrings("plan", collector.events.items[1].text.?);
    try std.testing.expectEqual(provider.ProviderEventTag.text_delta, collector.events.items[2].tag);
    try std.testing.expectEqualStrings("done", collector.events.items[2].text.?);
}

test "openai compatible parser skips empty content deltas" {
    var collector = provider.testing.EventCollector.init(std.testing.allocator);
    defer collector.deinit();

    const bytes =
        "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"done\"},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: [DONE]\n\n";
    try provider.openai_compatible.parseBytes(std.testing.allocator, bytes, collector.sink());

    var text_count: usize = 0;
    var thinking_count: usize = 0;
    for (collector.events.items) |event| {
        if (event.tag == .text_delta) {
            text_count += 1;
            try std.testing.expect(event.text.?.len > 0);
        }
        if (event.tag == .thinking_delta) thinking_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), text_count);
    try std.testing.expectEqual(@as(usize, 0), thinking_count);
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

test "openai request builder serializes thinking controls and reasoning replay" {
    const user_blocks = [_]provider.ContentBlockView{.{ .text = .{ .text = "hello" } }};
    const assistant_blocks = [_]provider.ContentBlockView{
        .{ .thinking = .{ .text = "plan" } },
        .{ .tool_call = .{ .id = "call_1", .name = "read", .arguments_json = "{\"path\":\"README.md\"}" } },
    };
    const tool_blocks = [_]provider.ContentBlockView{.{ .tool_result = .{ .tool_call_id = "call_1", .content_json = "{\"ok\":true}" } }};
    const messages = [_]provider.MessageView{
        .{ .role = .user, .content = &user_blocks },
        .{ .role = .assistant, .content = &assistant_blocks },
        .{ .role = .tool, .content = &tool_blocks },
    };
    var req = try provider.openai_compatible.buildChatCompletionsRequest(std.testing.allocator, .{
        .base_url = "https://api.deepseek.com",
        .api_key = "test-deepseek-key",
        .model = "deepseek-v4-flash",
        .thinking = .{ .type = .enabled, .reasoning_effort = "high" },
    }, .{ .messages = &messages });
    defer req.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, req.body, "\"thinking\":{\"type\":\"enabled\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, req.body, "\"reasoning_effort\":\"high\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, req.body, "\"reasoning_content\":\"plan\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, req.body, "\"tool_calls\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, req.body, "\"tool_call_id\":\"call_1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, req.body, "test-deepseek-key") == null);
}

test "openai request builder omits final-answer reasoning replay" {
    const user_blocks = [_]provider.ContentBlockView{.{ .text = .{ .text = "hello" } }};
    const assistant_blocks = [_]provider.ContentBlockView{
        .{ .thinking = .{ .text = "private prior reasoning" } },
        .{ .text = .{ .text = "final answer" } },
    };
    const messages = [_]provider.MessageView{
        .{ .role = .user, .content = &user_blocks },
        .{ .role = .assistant, .content = &assistant_blocks },
    };
    var req = try provider.openai_compatible.buildChatCompletionsRequest(std.testing.allocator, .{
        .base_url = "https://api.deepseek.com",
        .api_key = "test-deepseek-key",
        .model = "deepseek-v4-flash",
        .thinking = .{ .type = .enabled, .reasoning_effort = "high" },
    }, .{ .messages = &messages });
    defer req.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, req.body, "reasoning_content") == null);
    try std.testing.expect(std.mem.indexOf(u8, req.body, "private prior reasoning") == null);
    try std.testing.expect(std.mem.indexOf(u8, req.body, "final answer") != null);
}

test "openai request builder can explicitly disable provider thinking" {
    const blocks = [_]provider.ContentBlockView{.{ .text = .{ .text = "hello" } }};
    const messages = [_]provider.MessageView{.{ .role = .user, .content = &blocks }};
    var req = try provider.openai_compatible.buildChatCompletionsRequest(std.testing.allocator, .{
        .base_url = "https://api.deepseek.com",
        .api_key = "test-deepseek-key",
        .model = "deepseek-v4-flash",
        .thinking = .{ .type = .disabled, .reasoning_effort = "high" },
    }, .{ .messages = &messages });
    defer req.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, req.body, "\"thinking\":{\"type\":\"disabled\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, req.body, "reasoning_effort") == null);
}

test "openai request builder creates streaming chat completions request" {
    const blocks = [_]provider.ContentBlockView{.{ .text = .{ .text = "hello" } }};
    const messages = [_]provider.MessageView{.{ .role = .user, .content = &blocks }};
    var req = try provider.openai_compatible.buildChatCompletionsRequest(std.testing.allocator, .{
        .base_url = "https://example.invalid/v1",
        .api_key = "test-openai-key",
        .model = "test-model",
    }, .{ .messages = &messages });
    defer req.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("POST", req.method);
    try std.testing.expectEqualStrings("https://example.invalid/v1/chat/completions", req.url);
    try std.testing.expect(std.mem.indexOf(u8, req.body, "\"stream\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, req.body, "test-openai-key") == null);
    try std.testing.expect(req.headerValue("Authorization") != null);
}

test "openai request builder serializes system prompt and tool specs" {
    const blocks = [_]provider.ContentBlockView{.{ .text = .{ .text = "list files" } }};
    const messages = [_]provider.MessageView{.{ .role = .user, .content = &blocks }};
    const tool_specs = [_]provider.openai_compatible.ToolSpecView{.{
        .name = "ls",
        .description = "List workspace directory entries",
        .schema_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"additionalProperties\":false}",
    }};
    var req = try provider.openai_compatible.buildChatCompletionsRequest(std.testing.allocator, .{
        .base_url = "https://example.invalid/v1",
        .api_key = "test-openai-key",
        .model = "test-model",
    }, .{
        .messages = &messages,
        .tools = &tool_specs,
        .system_prompt = "You are Pig.",
    });
    defer req.deinit(std.testing.allocator);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, req.body, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const message_items = root.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), message_items.len);
    try std.testing.expectEqualStrings("system", message_items[0].object.get("role").?.string);
    try std.testing.expectEqualStrings("You are Pig.", message_items[0].object.get("content").?.string);
    try std.testing.expectEqualStrings("user", message_items[1].object.get("role").?.string);

    const tools = root.get("tools").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), tools.len);
    const function = tools[0].object.get("function").?.object;
    try std.testing.expectEqualStrings("ls", function.get("name").?.string);
    try std.testing.expectEqualStrings("List workspace directory entries", function.get("description").?.string);
    try std.testing.expectEqualStrings("object", function.get("parameters").?.object.get("type").?.string);
}

test "openai request builder falls back for invalid tool schema" {
    const blocks = [_]provider.ContentBlockView{.{ .text = .{ .text = "list files" } }};
    const messages = [_]provider.MessageView{.{ .role = .user, .content = &blocks }};
    const tool_specs = [_]provider.openai_compatible.ToolSpecView{.{
        .name = "bad",
        .description = "Bad schema",
        .schema_json = "\"not an object\"",
    }};
    var req = try provider.openai_compatible.buildChatCompletionsRequest(std.testing.allocator, .{
        .base_url = "https://example.invalid/v1",
        .api_key = "test-openai-key",
        .model = "test-model",
    }, .{
        .messages = &messages,
        .tools = &tool_specs,
    });
    defer req.deinit(std.testing.allocator);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, req.body, .{});
    defer parsed.deinit();
    const parameters = parsed.value.object.get("tools").?.array.items[0].object.get("function").?.object.get("parameters").?.object;
    try std.testing.expectEqual(@as(usize, 0), parameters.count());
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
    }, .{ .messages = &messages });
    defer req.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, req.body, "test\\\"model") != null);
    try std.testing.expect(std.mem.indexOf(u8, req.body, "hello \\\"zig\\\"\\n") != null);
}

fn buildEscapedRequestWithAllocator(allocator: std.mem.Allocator) !void {
    const blocks = [_]provider.ContentBlockView{.{ .text = .{ .text = "hello \"zig\"\n\x01" } }};
    const messages = [_]provider.MessageView{.{ .role = .user, .content = &blocks }};
    const tool_specs = [_]provider.openai_compatible.ToolSpecView{.{
        .name = "read",
        .description = "Read a file",
        .schema_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}}}",
    }};
    var req = try provider.openai_compatible.buildChatCompletionsRequest(allocator, .{
        .base_url = "https://example.invalid/v1/",
        .api_key = "test-openai-key",
        .model = "test\"model",
    }, .{ .messages = &messages, .tools = &tool_specs, .system_prompt = "system" });
    defer req.deinit(allocator);
}

test "openai request builder cleans up partial allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, buildEscapedRequestWithAllocator, .{});
}
