const std = @import("std");
const pig = @import("pig");
const agent = pig.core.agent;
const provider = pig.provider;

fn makeRuntime(state: *agent.state.AgentState, model: agent.model_client.ModelClient, collector: *agent.testing.AgentEventCollector, registry: agent.tool.ToolRegistry) agent.runtime.AgentRuntime {
    return .{ .allocator = std.testing.allocator, .state = state, .model = model, .tools = registry, .event_sink = collector.sink() };
}

test "runtime executes one tool call and continues" {
    const turn1 = [_]provider.ProviderEvent{
        .{ .message_start = .{ .role = .assistant } },
        .{ .tool_call_start = .{ .index = 0, .id = "call_1", .name = "echo" } },
        .{ .tool_call_delta = .{ .index = 0, .arguments_json_delta = "{\"text\":\"ping\"}" } },
        .{ .tool_call_end = .{ .index = 0, .id = "call_1", .name = "echo", .arguments_json = "{\"text\":\"ping\"}" } },
        .{ .message_delta = .{ .stop_reason = "tool_calls" } },
        .message_end,
        .done,
    };
    const turn2 = [_]provider.ProviderEvent{ .{ .message_start = .{ .role = .assistant } }, .{ .text_delta = .{ .text = "pong" } }, .message_end, .done };
    const turns = [_][]const provider.ProviderEvent{ &turn1, &turn2 };
    var model = agent.model_client.ScriptedModelClient{ .turns = &turns };
    var echo = agent.testing.EchoTool{};
    const registrations = [_]agent.tool.ToolRegistration{echo.registration()};
    var state = agent.state.AgentState.init(std.testing.allocator, .{});
    defer state.deinit();
    var collector = agent.testing.AgentEventCollector.init(std.testing.allocator);
    defer collector.deinit();
    var runtime = makeRuntime(&state, model.client(), &collector, .{ .registrations = &registrations });

    try runtime.runUserText("use tool");

    try std.testing.expectEqual(@as(usize, 2), model.request_count);
    try std.testing.expectEqual(@as(usize, 1), echo.calls);
    try std.testing.expectEqual(@as(usize, 4), state.messages.items.len);
    try std.testing.expectEqual(provider.Role.tool, state.messages.items[2].role);
    try std.testing.expectEqualStrings("pong", state.messages.items[3].content[0].text.text);
    var turn_starts: usize = 0;
    var turn_ends: usize = 0;
    for (collector.events.items) |event| {
        if (event.tag == .turn_start) turn_starts += 1;
        if (event.tag == .turn_end) turn_ends += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), turn_starts);
    try std.testing.expectEqual(@as(usize, 2), turn_ends);
}

const RejectResult = struct {
    fn afterToolResult(_: ?*anyopaque, _: agent.tool.ToolExecutionResult) agent.middleware.MiddlewareError!void {
        return error.MiddlewareRejected;
    }
};

const StopAfterTurn = struct {
    calls: usize = 0,
    tool_result_count: usize = 0,
    message_count: usize = 0,
    assistant_index: usize = 0,
    tool_result_start_index: usize = 0,

    fn hook(ptr: ?*anyopaque, context: agent.middleware.ShouldStopAfterTurnContext) bool {
        const self: *StopAfterTurn = @ptrCast(@alignCast(ptr.?));
        self.calls += 1;
        self.tool_result_count = context.tool_result_count;
        self.message_count = context.state.messages.items.len;
        self.assistant_index = context.assistant_index;
        self.tool_result_start_index = context.tool_result_start_index;
        return true;
    }
};

const TerminatingTool = struct {
    calls: usize = 0,

    fn registration(self: *TerminatingTool) agent.tool.ToolRegistration {
        return .{ .spec = .{ .name = "terminate", .description = "return a terminating result" }, .executor = .{ .ptr = self, .execute_fn = execute } };
    }

    fn execute(ptr: *anyopaque, context: agent.tool.ToolExecutionContext, call: agent.tool.ToolCall) agent.tool.ToolExecutorError!agent.tool.ToolExecutionResult {
        const self: *TerminatingTool = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        const id = try context.allocator.dupe(u8, call.id);
        errdefer context.allocator.free(id);
        const content = try context.allocator.dupe(u8, "{\"ok\":true}");
        return .{ .tool_call_id = id, .content_json = content, .terminate = true };
    }
};

test "runtime executes tool calls by index order" {
    const turn1 = [_]provider.ProviderEvent{
        .{ .message_start = .{ .role = .assistant } },
        .{ .tool_call_end = .{ .index = 1, .id = "call_2", .name = "echo", .arguments_json = "{\"n\":2}" } },
        .{ .tool_call_end = .{ .index = 0, .id = "call_1", .name = "echo", .arguments_json = "{\"n\":1}" } },
        .message_end,
        .done,
    };
    const turn2 = [_]provider.ProviderEvent{ .{ .message_start = .{ .role = .assistant } }, .{ .text_delta = .{ .text = "done" } }, .message_end, .done };
    const turns = [_][]const provider.ProviderEvent{ &turn1, &turn2 };
    var model = agent.model_client.ScriptedModelClient{ .turns = &turns };
    var echo = agent.testing.EchoTool{};
    const registrations = [_]agent.tool.ToolRegistration{echo.registration()};
    var state = agent.state.AgentState.init(std.testing.allocator, .{});
    defer state.deinit();
    var collector = agent.testing.AgentEventCollector.init(std.testing.allocator);
    defer collector.deinit();
    var runtime = makeRuntime(&state, model.client(), &collector, .{ .registrations = &registrations });

    try runtime.runUserText("x");
    var seen: usize = 0;
    for (collector.events.items) |event| {
        if (event.tag == .tool_execution_start) {
            if (seen == 0) try std.testing.expectEqualStrings("call_1", event.id.?);
            if (seen == 1) try std.testing.expectEqualStrings("call_2", event.id.?);
            seen += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), seen);
}

test "tool executor failure emits error tool end and fails lifecycle" {
    const turn = [_]provider.ProviderEvent{ .{ .message_start = .{ .role = .assistant } }, .{ .tool_call_end = .{ .index = 0, .id = "call_1", .name = "fail", .arguments_json = "{}" } }, .message_end, .done };
    const turns = [_][]const provider.ProviderEvent{&turn};
    var model = agent.model_client.ScriptedModelClient{ .turns = &turns };
    var failing = agent.testing.FailingTool{};
    const registrations = [_]agent.tool.ToolRegistration{failing.registration()};
    var state = agent.state.AgentState.init(std.testing.allocator, .{});
    defer state.deinit();
    var collector = agent.testing.AgentEventCollector.init(std.testing.allocator);
    defer collector.deinit();
    var runtime = makeRuntime(&state, model.client(), &collector, .{ .registrations = &registrations });

    try std.testing.expectError(error.ToolFailed, runtime.runUserText("x"));
    var saw_start = false;
    var saw_error_end = false;
    for (collector.events.items) |event| {
        if (event.tag == .tool_execution_start) saw_start = true;
        if (event.tag == .tool_execution_end and event.is_error) {
            saw_error_end = true;
            try std.testing.expectEqualStrings("{\"error\":\"tool execution failed\"}", event.content_json.?);
        }
    }
    try std.testing.expect(saw_start);
    try std.testing.expect(saw_error_end);
    try std.testing.expectEqual(agent.state.AgentStatus.failed, collector.events.items[collector.events.items.len - 1].status.?);
}

test "after tool result rejection fails with lifecycle closure" {
    const turn = [_]provider.ProviderEvent{ .{ .message_start = .{ .role = .assistant } }, .{ .tool_call_end = .{ .index = 0, .id = "call_1", .name = "echo", .arguments_json = "{}" } }, .message_end, .done };
    const turns = [_][]const provider.ProviderEvent{&turn};
    var model = agent.model_client.ScriptedModelClient{ .turns = &turns };
    var echo = agent.testing.EchoTool{};
    const registrations = [_]agent.tool.ToolRegistration{echo.registration()};
    var state = agent.state.AgentState.init(std.testing.allocator, .{});
    defer state.deinit();
    var collector = agent.testing.AgentEventCollector.init(std.testing.allocator);
    defer collector.deinit();
    var runtime = makeRuntime(&state, model.client(), &collector, .{ .registrations = &registrations });
    runtime.hooks = .{ .after_tool_result = RejectResult.afterToolResult };

    try std.testing.expectError(error.MiddlewareRejected, runtime.runUserText("x"));
    try std.testing.expectEqual(@as(usize, 1), echo.calls);
    try std.testing.expectEqual(agent.state.AgentStatus.failed, collector.events.items[collector.events.items.len - 1].status.?);
}

test "missing tool fails with lifecycle closure" {
    const turn = [_]provider.ProviderEvent{ .{ .message_start = .{ .role = .assistant } }, .{ .tool_call_end = .{ .index = 0, .id = "call_1", .name = "missing", .arguments_json = "{}" } }, .message_end, .done };
    const turns = [_][]const provider.ProviderEvent{&turn};
    var model = agent.model_client.ScriptedModelClient{ .turns = &turns };
    var state = agent.state.AgentState.init(std.testing.allocator, .{});
    defer state.deinit();
    var collector = agent.testing.AgentEventCollector.init(std.testing.allocator);
    defer collector.deinit();
    var runtime = makeRuntime(&state, model.client(), &collector, .{});

    try std.testing.expectError(error.ToolNotFound, runtime.runUserText("x"));
    try std.testing.expectEqual(agent.events.AgentEventTag.agent_end, collector.events.items[collector.events.items.len - 1].tag);
    try std.testing.expectEqual(agent.state.AgentStatus.failed, collector.events.items[collector.events.items.len - 1].status.?);
}

test "terminating tool result stops before follow-up provider request" {
    const turn = [_]provider.ProviderEvent{ .{ .message_start = .{ .role = .assistant } }, .{ .tool_call_end = .{ .index = 0, .id = "call_1", .name = "terminate", .arguments_json = "{}" } }, .message_end, .done };
    const turns = [_][]const provider.ProviderEvent{&turn};
    var model = agent.model_client.ScriptedModelClient{ .turns = &turns };
    var terminating = TerminatingTool{};
    const registrations = [_]agent.tool.ToolRegistration{terminating.registration()};
    var state = agent.state.AgentState.init(std.testing.allocator, .{});
    defer state.deinit();
    var collector = agent.testing.AgentEventCollector.init(std.testing.allocator);
    defer collector.deinit();
    var runtime = makeRuntime(&state, model.client(), &collector, .{ .registrations = &registrations });

    try runtime.runUserText("x");
    try std.testing.expectEqual(@as(usize, 1), model.request_count);
    try std.testing.expectEqual(@as(usize, 1), terminating.calls);
    try std.testing.expectEqual(@as(usize, 3), state.messages.items.len);
    try std.testing.expectEqual(agent.state.AgentStatus.completed, collector.events.items[collector.events.items.len - 1].status.?);
}

test "should stop after turn hook stops before follow-up provider request" {
    const turn = [_]provider.ProviderEvent{ .{ .message_start = .{ .role = .assistant } }, .{ .tool_call_end = .{ .index = 0, .id = "call_1", .name = "echo", .arguments_json = "{}" } }, .message_end, .done };
    const turns = [_][]const provider.ProviderEvent{&turn};
    var model = agent.model_client.ScriptedModelClient{ .turns = &turns };
    var echo = agent.testing.EchoTool{};
    const registrations = [_]agent.tool.ToolRegistration{echo.registration()};
    var state = agent.state.AgentState.init(std.testing.allocator, .{});
    defer state.deinit();
    var collector = agent.testing.AgentEventCollector.init(std.testing.allocator);
    defer collector.deinit();
    var runtime = makeRuntime(&state, model.client(), &collector, .{ .registrations = &registrations });
    var stop = StopAfterTurn{};
    runtime.hooks = .{ .ptr = &stop, .should_stop_after_turn = StopAfterTurn.hook };

    try runtime.runUserText("x");
    try std.testing.expectEqual(@as(usize, 1), model.request_count);
    try std.testing.expectEqual(@as(usize, 1), echo.calls);
    try std.testing.expectEqual(@as(usize, 1), stop.calls);
    try std.testing.expectEqual(@as(usize, 1), stop.tool_result_count);
    try std.testing.expectEqual(@as(usize, 3), stop.message_count);
    try std.testing.expectEqual(@as(usize, 1), stop.assistant_index);
    try std.testing.expectEqual(@as(usize, 2), stop.tool_result_start_index);
    try std.testing.expectEqual(agent.state.AgentStatus.completed, collector.events.items[collector.events.items.len - 1].status.?);
}

test "provider stream parse error returns stream parse failure" {
    const turn = [_]provider.ProviderEvent{.{ .error_event = .{ .category = .stream_parse, .message = "bad stream" } }};
    const turns = [_][]const provider.ProviderEvent{&turn};
    var model = agent.model_client.ScriptedModelClient{ .turns = &turns };
    var state = agent.state.AgentState.init(std.testing.allocator, .{});
    defer state.deinit();
    var collector = agent.testing.AgentEventCollector.init(std.testing.allocator);
    defer collector.deinit();
    var runtime = makeRuntime(&state, model.client(), &collector, .{});

    try std.testing.expectError(error.ProviderStreamParseFailed, runtime.runUserText("x"));
    try std.testing.expectEqual(agent.events.AgentErrorCategory.stream_parse, collector.events.items[2].error_category.?);
}

test "sink rejection during provider error is not swallowed" {
    const turn = [_]provider.ProviderEvent{.{ .error_event = .{ .category = .provider, .message = "provider failed" } }};
    const turns = [_][]const provider.ProviderEvent{&turn};
    var model = agent.model_client.ScriptedModelClient{ .turns = &turns };
    var state = agent.state.AgentState.init(std.testing.allocator, .{});
    defer state.deinit();
    var collector = agent.testing.AgentEventCollector.init(std.testing.allocator);
    defer collector.deinit();
    collector.reject_after = 2;
    var runtime = makeRuntime(&state, model.client(), &collector, .{});

    try std.testing.expectError(error.SinkRejectedEvent, runtime.runUserText("x"));
}

test "provider error is mapped once" {
    const turn = [_]provider.ProviderEvent{.{ .error_event = .{ .category = .provider, .message = "provider failed" } }};
    const turns = [_][]const provider.ProviderEvent{&turn};
    var model = agent.model_client.ScriptedModelClient{ .turns = &turns };
    var state = agent.state.AgentState.init(std.testing.allocator, .{});
    defer state.deinit();
    var collector = agent.testing.AgentEventCollector.init(std.testing.allocator);
    defer collector.deinit();
    var runtime = makeRuntime(&state, model.client(), &collector, .{});

    try std.testing.expectError(error.ProviderFailed, runtime.runUserText("x"));
    var errors: usize = 0;
    for (collector.events.items) |event| {
        if (event.tag == .error_event) errors += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), errors);
}
