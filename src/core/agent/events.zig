const std = @import("std");
const provider = @import("../../provider/mod.zig");
const state = @import("state.zig");

pub const AgentErrorCategory = enum { provider, stream_parse, tool, middleware, abort, internal };

pub const AgentEventTag = enum {
    agent_start,
    agent_end,
    turn_start,
    turn_end,
    message_start,
    message_delta,
    message_end,
    tool_execution_start,
    tool_execution_delta,
    tool_execution_end,
    retry,
    abort,
    error_event,
};

pub const AgentStart = struct { model_label: ?[]const u8 = null };
pub const AgentEnd = struct { status: state.AgentStatus };
pub const TurnStart = struct { user_text: []const u8 };
pub const TurnEnd = struct { status: state.AgentStatus };
pub const MessageStart = struct { role: provider.Role };
pub const MessageDelta = struct { text_delta: ?[]const u8 = null, thinking_delta: ?[]const u8 = null, stop_reason: ?[]const u8 = null };
pub const MessageEnd = struct { role: provider.Role };
pub const ToolExecutionStart = struct { id: []const u8, name: []const u8, arguments_json: []const u8 };
pub const ToolExecutionDelta = struct { id: []const u8, message: []const u8 };
pub const ToolExecutionEnd = struct { id: []const u8, name: []const u8, is_error: bool, content_json: []const u8 };
pub const Retry = struct { attempt: u32, reason: []const u8 };
pub const Abort = struct { reason: ?[]const u8 = null };
pub const AgentErrorEvent = struct { category: AgentErrorCategory, message: []const u8, retryable: bool = false };

pub const AgentEvent = union(AgentEventTag) {
    agent_start: AgentStart,
    agent_end: AgentEnd,
    turn_start: TurnStart,
    turn_end: TurnEnd,
    message_start: MessageStart,
    message_delta: MessageDelta,
    message_end: MessageEnd,
    tool_execution_start: ToolExecutionStart,
    tool_execution_delta: ToolExecutionDelta,
    tool_execution_end: ToolExecutionEnd,
    retry: Retry,
    abort: Abort,
    error_event: AgentErrorEvent,
};

pub const AgentEventSinkError = error{ OutOfMemory, SinkRejectedEvent };

pub const AgentEventSink = struct {
    ptr: *anyopaque,
    on_event: *const fn (ptr: *anyopaque, event: AgentEvent) AgentEventSinkError!void,

    pub fn emit(self: AgentEventSink, event: AgentEvent) AgentEventSinkError!void {
        return self.on_event(self.ptr, event);
    }
};

pub const NullSink = struct {
    pub fn sink(self: *NullSink) AgentEventSink {
        return .{ .ptr = self, .on_event = onEvent };
    }

    fn onEvent(_: *anyopaque, _: AgentEvent) AgentEventSinkError!void {}
};
