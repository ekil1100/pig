const std = @import("std");
const pig = @import("pig");
const agent = pig.core.agent;
const provider = pig.provider;

const RejectInput = struct {
    fn beforeInput(_: ?*anyopaque, _: []const u8) agent.middleware.MiddlewareError!void {
        return error.MiddlewareRejected;
    }
};

const CountingHooks = struct {
    calls: std.ArrayList([]const u8) = .empty,

    fn beforeInput(ptr: ?*anyopaque, _: []const u8) agent.middleware.MiddlewareError!void {
        const self: *CountingHooks = @ptrCast(@alignCast(ptr.?));
        try self.calls.append(std.testing.allocator, "before_input");
    }
    fn beforeProvider(ptr: ?*anyopaque, _: agent.model_client.ModelRequest) agent.middleware.MiddlewareError!void {
        const self: *CountingHooks = @ptrCast(@alignCast(ptr.?));
        try self.calls.append(std.testing.allocator, "before_provider_request");
    }
};

test "before input rejection starts no lifecycle" {
    const turn = [_]provider.ProviderEvent{.{ .message_start = .{ .role = .assistant } }};
    const turns = [_][]const provider.ProviderEvent{&turn};
    var model = agent.model_client.ScriptedModelClient{ .turns = &turns };
    var state = agent.state.AgentState.init(std.testing.allocator, .{});
    defer state.deinit();
    var collector = agent.testing.AgentEventCollector.init(std.testing.allocator);
    defer collector.deinit();
    var runtime = agent.runtime.AgentRuntime{ .allocator = std.testing.allocator, .state = &state, .model = model.client(), .event_sink = collector.sink(), .hooks = .{ .before_input = RejectInput.beforeInput } };

    try std.testing.expectError(error.MiddlewareRejected, runtime.runUserText("x"));
    try std.testing.expectEqual(@as(usize, 0), state.messages.items.len);
    try std.testing.expectEqual(@as(usize, 0), collector.events.items.len);
}

test "hooks run before input and provider request" {
    const turn = [_]provider.ProviderEvent{ .{ .message_start = .{ .role = .assistant } }, .{ .text_delta = .{ .text = "ok" } }, .message_end, .done };
    const turns = [_][]const provider.ProviderEvent{&turn};
    var model = agent.model_client.ScriptedModelClient{ .turns = &turns };
    var state = agent.state.AgentState.init(std.testing.allocator, .{});
    defer state.deinit();
    var collector = agent.testing.AgentEventCollector.init(std.testing.allocator);
    defer collector.deinit();
    var hooks = CountingHooks{};
    defer hooks.calls.deinit(std.testing.allocator);
    var runtime = agent.runtime.AgentRuntime{ .allocator = std.testing.allocator, .state = &state, .model = model.client(), .event_sink = collector.sink(), .hooks = .{ .ptr = &hooks, .before_input = CountingHooks.beforeInput, .before_provider_request = CountingHooks.beforeProvider } };

    try runtime.runUserText("x");
    try std.testing.expectEqual(@as(usize, 2), hooks.calls.items.len);
    try std.testing.expectEqualStrings("before_input", hooks.calls.items[0]);
    try std.testing.expectEqualStrings("before_provider_request", hooks.calls.items[1]);
}

const AbortAfterFirstEventModel = struct {
    abort: *bool,

    fn client(self: *AbortAfterFirstEventModel) agent.model_client.ModelClient {
        return .{ .ptr = self, .stream_turn = streamTurn };
    }

    fn streamTurn(ptr: *anyopaque, _: agent.model_client.ModelRequest, sink: provider.EventSink) agent.model_client.ModelClientError!void {
        const self: *AbortAfterFirstEventModel = @ptrCast(@alignCast(ptr));
        try sink.emit(.{ .message_start = .{ .role = .assistant } });
        self.abort.* = true;
        sink.emit(.{ .text_delta = .{ .text = "ignored" } }) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.SinkRejectedEvent => error.SinkRejectedEvent,
        };
    }
};

const AbortBeforeToolModel = struct {
    abort: *bool,

    fn client(self: *AbortBeforeToolModel) agent.model_client.ModelClient {
        return .{ .ptr = self, .stream_turn = streamTurn };
    }

    fn streamTurn(ptr: *anyopaque, _: agent.model_client.ModelRequest, sink: provider.EventSink) agent.model_client.ModelClientError!void {
        const self: *AbortBeforeToolModel = @ptrCast(@alignCast(ptr));
        try sink.emit(.{ .message_start = .{ .role = .assistant } });
        try sink.emit(.{ .tool_call_end = .{ .index = 0, .id = "call_1", .name = "echo", .arguments_json = "{}" } });
        try sink.emit(.message_end);
        try sink.emit(.done);
        self.abort.* = true;
    }
};

test "abort before run emits only abort event" {
    const turn = [_]provider.ProviderEvent{ .{ .message_start = .{ .role = .assistant } }, .done };
    const turns = [_][]const provider.ProviderEvent{&turn};
    var model = agent.model_client.ScriptedModelClient{ .turns = &turns };
    var state = agent.state.AgentState.init(std.testing.allocator, .{});
    defer state.deinit();
    var collector = agent.testing.AgentEventCollector.init(std.testing.allocator);
    defer collector.deinit();
    var abort = true;
    var runtime = agent.runtime.AgentRuntime{ .allocator = std.testing.allocator, .state = &state, .model = model.client(), .event_sink = collector.sink(), .abort_flag = &abort };

    try std.testing.expectError(error.Aborted, runtime.runUserText("x"));
    try std.testing.expectEqual(@as(usize, 1), collector.events.items.len);
    try std.testing.expectEqual(agent.events.AgentEventTag.abort, collector.events.items[0].tag);
}

test "abort during provider event bridge closes aborted lifecycle" {
    var abort = false;
    var model = AbortAfterFirstEventModel{ .abort = &abort };
    var state = agent.state.AgentState.init(std.testing.allocator, .{});
    defer state.deinit();
    var collector = agent.testing.AgentEventCollector.init(std.testing.allocator);
    defer collector.deinit();
    var runtime = agent.runtime.AgentRuntime{ .allocator = std.testing.allocator, .state = &state, .model = model.client(), .event_sink = collector.sink(), .abort_flag = &abort };

    try std.testing.expectError(error.Aborted, runtime.runUserText("x"));
    try std.testing.expectEqual(agent.events.AgentEventTag.abort, collector.events.items[collector.events.items.len - 3].tag);
    try std.testing.expectEqual(agent.state.AgentStatus.aborted, collector.events.items[collector.events.items.len - 1].status.?);
}

test "abort before tool call closes aborted lifecycle" {
    var abort = false;
    var model = AbortBeforeToolModel{ .abort = &abort };
    var echo = agent.testing.EchoTool{};
    const registrations = [_]agent.tool.ToolRegistration{echo.registration()};
    var state = agent.state.AgentState.init(std.testing.allocator, .{});
    defer state.deinit();
    var collector = agent.testing.AgentEventCollector.init(std.testing.allocator);
    defer collector.deinit();
    var runtime = agent.runtime.AgentRuntime{ .allocator = std.testing.allocator, .state = &state, .model = model.client(), .tools = .{ .registrations = &registrations }, .event_sink = collector.sink(), .abort_flag = &abort };

    try std.testing.expectError(error.Aborted, runtime.runUserText("x"));
    try std.testing.expectEqual(@as(usize, 0), echo.calls);
    try std.testing.expectEqual(agent.state.AgentStatus.aborted, collector.events.items[collector.events.items.len - 1].status.?);
}
