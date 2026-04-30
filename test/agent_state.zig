const std = @import("std");
const pig = @import("pig");
const agent = pig.core.agent;
const provider = pig.provider;

test "agent state appends messages and builds borrowed view batch" {
    var state = agent.state.AgentState.init(std.testing.allocator, .{});
    defer state.deinit();

    try std.testing.expectEqual(agent.state.AgentStatus.idle, state.status);
    try state.appendUserText("hi");
    try state.stream.text.appendSlice(std.testing.allocator, "hello");
    try state.stream.thinking.appendSlice(std.testing.allocator, "think");
    try state.stream.thinking_signature.appendSlice(std.testing.allocator, "sig");
    try state.stream.tool_calls.append(std.testing.allocator, try agent.state.PendingToolCall.clone(std.testing.allocator, 0, "call_1", "echo", "{}"));
    try state.appendAssistantFromStream();

    try std.testing.expectEqual(@as(usize, 2), state.messages.items.len);
    try std.testing.expectEqual(provider.Role.user, state.messages.items[0].role);
    try std.testing.expectEqual(provider.Role.assistant, state.messages.items[1].role);
    try std.testing.expectEqual(@as(usize, 3), state.messages.items[1].content.len);
    try std.testing.expectEqualStrings("hello", state.messages.items[1].content[0].text.text);
    try std.testing.expectEqualStrings("think", state.messages.items[1].content[1].thinking.text);
    try std.testing.expectEqualStrings("sig", state.messages.items[1].content[1].thinking.signature.?);

    var batch = try state.messageViews(std.testing.allocator);
    defer batch.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), batch.messages.len);
    try std.testing.expectEqual(@as(usize, 3), batch.messages[1].content.len);
    try std.testing.expectEqualStrings("echo", batch.messages[1].content[2].tool_call.name);
}

test "append tool result creates tool message" {
    var state = agent.state.AgentState.init(std.testing.allocator, .{});
    defer state.deinit();
    const result = agent.tool.ToolExecutionResult{ .tool_call_id = try std.testing.allocator.dupe(u8, "call_1"), .content_json = try std.testing.allocator.dupe(u8, "{\"ok\":true}") };
    defer result.deinit(std.testing.allocator);

    try state.appendToolResult(result);
    try std.testing.expectEqual(@as(usize, 1), state.messages.items.len);
    try std.testing.expectEqual(provider.Role.tool, state.messages.items[0].role);
    try std.testing.expectEqualStrings("call_1", state.messages.items[0].content[0].tool_result.tool_call_id);
}
