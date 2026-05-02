const std = @import("std");
const provider = @import("../../provider/mod.zig");
const state = @import("state.zig");
const events = @import("events.zig");
const model_client = @import("model_client.zig");
const tool = @import("tool.zig");
const middleware = @import("middleware.zig");

pub const AgentRunError = error{
    OutOfMemory,
    ProviderFailed,
    ProviderStreamParseFailed,
    ToolNotFound,
    ToolFailed,
    MiddlewareRejected,
    MaxIterationsExceeded,
    Aborted,
    SinkRejectedEvent,
};

pub const AgentRuntime = struct {
    allocator: std.mem.Allocator,
    state: *state.AgentState,
    model: model_client.ModelClient,
    tools: tool.ToolRegistry = .{},
    hooks: middleware.MiddlewareHooks = .{},
    event_sink: events.AgentEventSink,
    abort_flag: ?*const bool = null,

    pub fn runUserText(self: *AgentRuntime, text: []const u8) AgentRunError!void {
        if (self.abortRequested()) {
            try self.emit(.{ .abort = .{ .reason = "aborted before run" } });
            return error.Aborted;
        }

        self.hooks.callBeforeInput(text) catch |err| return mapMiddlewareError(err);

        try self.emit(.{ .agent_start = .{} });
        var turn_started = false;
        try self.emit(.{ .turn_start = .{ .user_text = text } });
        turn_started = true;
        self.state.status = .running;
        self.state.appendUserText(text) catch |err| return self.failAfterTurn(turn_started, .failed, .internal, "failed to append user message", mapAlloc(err));

        var iteration: u32 = 0;
        while (iteration < self.state.config.max_iterations) {
            if (self.abortRequested()) return self.abortAfterTurn(turn_started, "aborted before provider request");
            iteration += 1;
            self.state.status = .awaiting_provider;
            self.state.stream.resetRetainingCapacity(self.allocator);

            var batch = self.state.messageViews(self.allocator) catch |err| return self.failAfterTurn(turn_started, .failed, .internal, "failed to build message views", mapAlloc(err));
            defer batch.deinit(self.allocator);
            const tool_specs = self.tools.specs(self.allocator) catch |err| return self.failAfterTurn(turn_started, .failed, .internal, "failed to build tool specs", mapAlloc(err));
            defer self.allocator.free(tool_specs);
            const request = model_client.ModelRequest{ .messages = batch.messages, .tools = tool_specs, .system_prompt = self.state.config.system_prompt, .thinking_level = self.state.config.thinking_level };
            self.hooks.callBeforeProviderRequest(request) catch |err| return self.failAfterTurn(turn_started, .failed, .middleware, "middleware rejected provider request", mapMiddlewareError(err));

            var bridge = ProviderBridge{ .runtime = self };
            self.model.streamTurn(request, bridge.sink()) catch |err| {
                if (bridge.aborted) return self.abortAfterTurn(turn_started, "aborted during provider stream");
                if (err == error.SinkRejectedEvent) return error.SinkRejectedEvent;
                if (bridge.had_provider_error) return self.finalizeAfterTurn(turn_started, .failed, bridge.errorForModelFailure(err));
                return switch (err) {
                    error.OutOfMemory => self.failAfterTurn(turn_started, .failed, .internal, "out of memory during provider stream", error.OutOfMemory),
                    error.ProviderFailed => self.failAfterTurn(turn_started, .failed, .provider, "provider failed", error.ProviderFailed),
                    error.ProviderStreamParseFailed => self.failAfterTurn(turn_started, .failed, .stream_parse, "provider stream parse failed", error.ProviderStreamParseFailed),
                    error.SinkRejectedEvent => unreachable,
                };
            };
            if (bridge.aborted) return self.abortAfterTurn(turn_started, "aborted during provider stream");
            if (bridge.had_provider_error) return self.finalizeAfterTurn(turn_started, .failed, bridge.errorAfterProviderEvent());

            self.state.appendAssistantFromStream() catch |err| return self.failAfterTurn(turn_started, .failed, .internal, "failed to append assistant message", mapAlloc(err));

            if (self.state.stream.tool_calls.items.len == 0) {
                self.state.status = .completed;
                try self.emit(.{ .turn_end = .{ .status = .completed } });
                try self.emit(.{ .agent_end = .{ .status = .completed } });
                return;
            }

            self.state.status = .executing_tools;
            const order = self.toolExecutionOrder() catch |err| return self.failAfterTurn(turn_started, .failed, .internal, "failed to order tool calls", err);
            defer self.allocator.free(order);
            for (order) |pending_index| {
                const pending = self.state.stream.tool_calls.items[pending_index];
                if (self.abortRequested()) return self.abortAfterTurn(turn_started, "aborted before tool call");
                const call = tool.ToolCall{ .id = pending.id, .name = pending.name, .arguments_json = pending.arguments_json };
                self.hooks.callBeforeToolCall(call) catch |err| return self.failAfterTurn(turn_started, .failed, .middleware, "middleware rejected tool call", mapMiddlewareError(err));
                const registration = self.tools.find(call.name) orelse return self.failAfterTurn(turn_started, .failed, .tool, "tool not found", error.ToolNotFound);
                try self.emit(.{ .tool_execution_start = .{ .id = call.id, .name = call.name, .arguments_json = call.arguments_json } });
                {
                    const context = tool.ToolExecutionContext{ .allocator = self.allocator, .event_sink = self.event_sink, .abort_flag = self.abort_flag };
                    const result = registration.executor.execute(context, call) catch |err| {
                        const message = switch (err) {
                            error.OutOfMemory => "tool allocation failed",
                            error.ToolFailed => "tool execution failed",
                        };
                        const content_json = switch (err) {
                            error.OutOfMemory => "{\"error\":\"tool allocation failed\"}",
                            error.ToolFailed => "{\"error\":\"tool execution failed\"}",
                        };
                        try self.emit(.{ .tool_execution_end = .{ .id = call.id, .name = call.name, .is_error = true, .content_json = content_json } });
                        return switch (err) {
                            error.OutOfMemory => self.failAfterTurn(turn_started, .failed, .tool, message, error.OutOfMemory),
                            error.ToolFailed => self.failAfterTurn(turn_started, .failed, .tool, message, error.ToolFailed),
                        };
                    };
                    defer result.deinit(self.allocator);
                    try self.emit(.{ .tool_execution_end = .{ .id = result.tool_call_id, .name = call.name, .is_error = result.is_error, .content_json = result.content_json } });
                    self.hooks.callAfterToolResult(result) catch |err| return self.failAfterTurn(turn_started, .failed, .middleware, "middleware rejected tool result", mapMiddlewareError(err));
                    self.state.appendToolResult(result) catch |err| return self.failAfterTurn(turn_started, .failed, .internal, "failed to append tool result", mapAlloc(err));
                }
            }
        }

        return self.failAfterTurn(turn_started, .failed, .internal, "max iterations exceeded", error.MaxIterationsExceeded);
    }

    fn toolExecutionOrder(self: *AgentRuntime) AgentRunError![]usize {
        const calls = self.state.stream.tool_calls.items;
        const order = try self.allocator.alloc(usize, calls.len);
        errdefer self.allocator.free(order);
        for (order, 0..) |*slot, i| slot.* = i;
        std.mem.sort(usize, order, calls, struct {
            fn lessThan(items: []const state.PendingToolCall, lhs: usize, rhs: usize) bool {
                const left = items[lhs];
                const right = items[rhs];
                if (left.index == right.index) return lhs < rhs;
                return left.index < right.index;
            }
        }.lessThan);
        return order;
    }

    fn abortRequested(self: *AgentRuntime) bool {
        return if (self.abort_flag) |flag| flag.* else false;
    }

    fn emit(self: *AgentRuntime, event: events.AgentEvent) AgentRunError!void {
        self.event_sink.emit(event) catch |err| return mapSinkError(err);
    }

    fn emitError(self: *AgentRuntime, category: events.AgentErrorCategory, message: []const u8) AgentRunError!void {
        try self.emit(.{ .error_event = .{ .category = category, .message = message } });
    }

    fn finalizeAfterTurn(self: *AgentRuntime, turn_started: bool, status: state.AgentStatus, err: AgentRunError) AgentRunError {
        if (turn_started) {
            self.state.status = status;
            self.emit(.{ .turn_end = .{ .status = status } }) catch |sink_err| return sink_err;
            self.emit(.{ .agent_end = .{ .status = status } }) catch |sink_err| return sink_err;
        }
        return err;
    }

    fn failAfterTurn(self: *AgentRuntime, turn_started: bool, status: state.AgentStatus, category: events.AgentErrorCategory, message: []const u8, err: AgentRunError) AgentRunError {
        if (turn_started) self.emitError(category, message) catch |sink_err| return sink_err;
        return self.finalizeAfterTurn(turn_started, status, err);
    }

    fn abortAfterTurn(self: *AgentRuntime, turn_started: bool, reason: []const u8) AgentRunError {
        self.emit(.{ .abort = .{ .reason = reason } }) catch |sink_err| return sink_err;
        return self.finalizeAfterTurn(turn_started, .aborted, error.Aborted);
    }
};

const ProviderBridge = struct {
    runtime: *AgentRuntime,
    had_provider_error: bool = false,
    provider_error_kind: ?provider.ProviderErrorKind = null,
    aborted: bool = false,

    fn sink(self: *ProviderBridge) provider.EventSink {
        return .{ .ptr = self, .on_event = onEvent };
    }

    fn onEvent(ptr: *anyopaque, event: provider.ProviderEvent) provider.EventSinkError!void {
        const self: *ProviderBridge = @ptrCast(@alignCast(ptr));
        if (self.runtime.abortRequested()) {
            self.aborted = true;
            return error.SinkRejectedEvent;
        }
        self.handle(event) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.SinkRejectedEvent => error.SinkRejectedEvent,
        };
    }

    fn handle(self: *ProviderBridge, event: provider.ProviderEvent) (error{ OutOfMemory, SinkRejectedEvent })!void {
        const allocator = self.runtime.allocator;
        switch (event) {
            .message_start => |v| try self.runtime.event_sink.emit(.{ .message_start = .{ .role = v.role } }),
            .text_delta => |v| {
                try self.runtime.state.stream.text.appendSlice(allocator, v.text);
                try self.runtime.event_sink.emit(.{ .message_delta = .{ .text_delta = v.text } });
            },
            .thinking_delta => |v| {
                try self.runtime.state.stream.thinking.appendSlice(allocator, v.text);
                if (v.signature_delta) |sig| try self.runtime.state.stream.thinking_signature.appendSlice(allocator, sig);
            },
            .message_delta => |v| if (v.stop_reason) |reason| try self.runtime.event_sink.emit(.{ .message_delta = .{ .stop_reason = reason } }),
            .message_end => try self.runtime.event_sink.emit(.{ .message_end = .{ .role = .assistant } }),
            .tool_call_start => {},
            .tool_call_delta => {},
            .tool_call_end => |v| {
                const pending = try state.PendingToolCall.clone(allocator, v.index, v.id, v.name, v.arguments_json);
                errdefer pending.deinit(allocator);
                try self.runtime.state.stream.tool_calls.append(allocator, pending);
            },
            .usage => |v| self.runtime.state.stream.usage = provider.Usage.add(self.runtime.state.stream.usage, v),
            .cost => {},
            .error_event => |v| {
                self.had_provider_error = true;
                self.provider_error_kind = v.category;
                try self.runtime.event_sink.emit(.{ .error_event = .{ .category = mapProviderError(v.category), .message = v.message, .retryable = v.retryable } });
            },
            .done => self.runtime.state.stream.saw_done = true,
        }
    }

    fn errorForModelFailure(self: ProviderBridge, err: model_client.ModelClientError) AgentRunError {
        if (err == error.ProviderStreamParseFailed or self.provider_error_kind == .stream_parse) return error.ProviderStreamParseFailed;
        return error.ProviderFailed;
    }

    fn errorAfterProviderEvent(self: ProviderBridge) AgentRunError {
        if (self.provider_error_kind == .stream_parse) return error.ProviderStreamParseFailed;
        return error.ProviderFailed;
    }
};

fn mapProviderError(kind: provider.ProviderErrorKind) events.AgentErrorCategory {
    return switch (kind) {
        .stream_parse => .stream_parse,
        else => .provider,
    };
}

fn mapSinkError(err: events.AgentEventSinkError) AgentRunError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.SinkRejectedEvent => error.SinkRejectedEvent,
    };
}

fn mapMiddlewareError(err: middleware.MiddlewareError) AgentRunError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.MiddlewareRejected => error.MiddlewareRejected,
    };
}

fn mapAlloc(err: anyerror) AgentRunError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.OutOfMemory,
    };
}
