const std = @import("std");
const pig = @import("pig");
const agent = pig.core.agent;
const provider = pig.provider;

fn runtimeWith(state: *agent.state.AgentState, model: agent.model_client.ModelClient, collector: *agent.testing.AgentEventCollector) agent.runtime.AgentRuntime {
    return .{ .allocator = std.testing.allocator, .state = state, .model = model, .event_sink = collector.sink() };
}

test "runtime completes no-tool text turn" {
    const turn = [_]provider.ProviderEvent{
        .{ .message_start = .{ .role = .assistant } },
        .{ .text_delta = .{ .text = "hello" } },
        .{ .text_delta = .{ .text = " world" } },
        .{ .message_delta = .{ .stop_reason = "stop" } },
        .message_end,
        .done,
    };
    const turns = [_][]const provider.ProviderEvent{&turn};
    var model = agent.model_client.ScriptedModelClient{ .turns = &turns };
    var state = agent.state.AgentState.init(std.testing.allocator, .{});
    defer state.deinit();
    var collector = agent.testing.AgentEventCollector.init(std.testing.allocator);
    defer collector.deinit();
    var runtime = runtimeWith(&state, model.client(), &collector);

    try runtime.runUserText("hi");

    try std.testing.expectEqual(@as(usize, 2), state.messages.items.len);
    try std.testing.expectEqualStrings("hello world", state.messages.items[1].content[0].text.text);
    try std.testing.expectEqual(@as(usize, 1), model.request_count);
    try std.testing.expectEqual(agent.events.AgentEventTag.agent_start, collector.events.items[0].tag);
    try std.testing.expectEqual(agent.events.AgentEventTag.agent_end, collector.events.items[collector.events.items.len - 1].tag);
    try std.testing.expectEqual(agent.state.AgentStatus.completed, collector.events.items[collector.events.items.len - 1].status.?);
}

test "runtime skips empty text and thinking deltas" {
    const turn = [_]provider.ProviderEvent{
        .{ .message_start = .{ .role = .assistant } },
        .{ .text_delta = .{ .text = "" } },
        .{ .thinking_delta = .{ .text = "" } },
        .{ .text_delta = .{ .text = "visible" } },
        .message_end,
        .done,
    };
    const turns = [_][]const provider.ProviderEvent{&turn};
    var model = agent.model_client.ScriptedModelClient{ .turns = &turns };
    var state = agent.state.AgentState.init(std.testing.allocator, .{});
    defer state.deinit();
    var collector = agent.testing.AgentEventCollector.init(std.testing.allocator);
    defer collector.deinit();
    var runtime = runtimeWith(&state, model.client(), &collector);

    try runtime.runUserText("hi");

    var text_count: usize = 0;
    var thinking_count: usize = 0;
    for (collector.events.items) |event| {
        if (event.tag == .message_delta and event.text_delta != null) {
            text_count += 1;
            try std.testing.expect(event.text_delta.?.len > 0);
        }
        if (event.tag == .message_delta and event.thinking_delta != null) thinking_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), text_count);
    try std.testing.expectEqual(@as(usize, 0), thinking_count);
    try std.testing.expectEqualStrings("visible", state.messages.items[1].content[0].text.text);
}

test "runtime repeated calls keep history and pair lifecycle" {
    const turn1 = [_]provider.ProviderEvent{ .{ .message_start = .{ .role = .assistant } }, .{ .text_delta = .{ .text = "one" } }, .message_end, .done };
    const turn2 = [_]provider.ProviderEvent{ .{ .message_start = .{ .role = .assistant } }, .{ .text_delta = .{ .text = "two" } }, .message_end, .done };
    const turns = [_][]const provider.ProviderEvent{ &turn1, &turn2 };
    var model = agent.model_client.ScriptedModelClient{ .turns = &turns };
    var state = agent.state.AgentState.init(std.testing.allocator, .{});
    defer state.deinit();
    var collector = agent.testing.AgentEventCollector.init(std.testing.allocator);
    defer collector.deinit();
    var runtime = runtimeWith(&state, model.client(), &collector);

    try runtime.runUserText("first");
    try runtime.runUserText("second");

    try std.testing.expectEqual(@as(usize, 4), state.messages.items.len);
    try std.testing.expectEqual(@as(usize, 2), model.request_count);
    try std.testing.expectEqual(@as(usize, 3), model.last_message_count);
    var starts: usize = 0;
    var ends: usize = 0;
    for (collector.events.items) |event| {
        if (event.tag == .agent_start) starts += 1;
        if (event.tag == .agent_end) ends += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), starts);
    try std.testing.expectEqual(@as(usize, 2), ends);
}
