const std = @import("std");
const agent = @import("../core/agent/mod.zig");
const json_util = @import("../util/json.zig");

pub const JsonEventSink = struct {
    writer: *std.Io.Writer,
    session_id: []const u8 = "ephemeral",

    pub fn sink(self: *JsonEventSink) agent.AgentEventSink {
        return .{ .ptr = self, .on_event = onEvent };
    }

    fn onEvent(ptr: *anyopaque, event: agent.AgentEvent) agent.events.AgentEventSinkError!void {
        const self: *JsonEventSink = @ptrCast(@alignCast(ptr));
        try writeEvent(self.writer, self.session_id, event);
    }
};

pub fn writeModelUnavailable(writer: *std.Io.Writer) agent.events.AgentEventSinkError!void {
    try writeError(writer, "provider", "model client unavailable");
}

pub fn writeError(writer: *std.Io.Writer, category: []const u8, message: []const u8) agent.events.AgentEventSinkError!void {
    try writePreamble(writer, "error", "ephemeral");
    try writeFieldString(writer, "category", category);
    writer.writeAll(",\"message\":") catch return error.SinkRejectedEvent;
    try json_util.writeJsonString(writer, message);
    writer.writeAll(",\"retryable\":false}\n") catch return error.SinkRejectedEvent;
}

fn writeEvent(writer: *std.Io.Writer, session_id: []const u8, event: agent.AgentEvent) agent.events.AgentEventSinkError!void {
    switch (event) {
        .agent_start => {
            try writePreamble(writer, "agent_start", session_id);
            writer.writeAll("}\n") catch return error.SinkRejectedEvent;
        },
        .agent_end => |v| {
            try writePreamble(writer, "agent_end", session_id);
            try writeFieldString(writer, "status", @tagName(v.status));
            writer.writeAll("}\n") catch return error.SinkRejectedEvent;
        },
        .turn_start => |v| {
            try writePreamble(writer, "turn_start", session_id);
            try writeFieldString(writer, "text", v.user_text);
            writer.writeAll("}\n") catch return error.SinkRejectedEvent;
        },
        .turn_end => |v| {
            try writePreamble(writer, "turn_end", session_id);
            try writeFieldString(writer, "status", @tagName(v.status));
            writer.writeAll("}\n") catch return error.SinkRejectedEvent;
        },
        .message_start => |v| {
            try writePreamble(writer, "message_start", session_id);
            try writeFieldString(writer, "role", @tagName(v.role));
            writer.writeAll("}\n") catch return error.SinkRejectedEvent;
        },
        .message_delta => |v| {
            try writePreamble(writer, "message_delta", session_id);
            if (v.text_delta) |text| try writeFieldString(writer, "text_delta", text);
            if (v.stop_reason) |reason| try writeFieldString(writer, "stop_reason", reason);
            writer.writeAll("}\n") catch return error.SinkRejectedEvent;
        },
        .message_end => |v| {
            try writePreamble(writer, "message_end", session_id);
            try writeFieldString(writer, "role", @tagName(v.role));
            writer.writeAll("}\n") catch return error.SinkRejectedEvent;
        },
        .tool_execution_start => |v| {
            try writePreamble(writer, "tool_start", session_id);
            try writeFieldString(writer, "id", v.id);
            try writeFieldString(writer, "name", v.name);
            try writeFieldString(writer, "arguments_json", v.arguments_json);
            writer.writeAll("}\n") catch return error.SinkRejectedEvent;
        },
        .tool_execution_delta => |v| {
            try writePreamble(writer, "tool_delta", session_id);
            try writeFieldString(writer, "id", v.id);
            try writeFieldString(writer, "message", v.message);
            writer.writeAll("}\n") catch return error.SinkRejectedEvent;
        },
        .tool_execution_end => |v| {
            try writePreamble(writer, "tool_end", session_id);
            try writeFieldString(writer, "id", v.id);
            try writeFieldString(writer, "name", v.name);
            writer.print(",\"is_error\":{}", .{v.is_error}) catch return error.SinkRejectedEvent;
            try writeFieldString(writer, "content_json", v.content_json);
            writer.writeAll("}\n") catch return error.SinkRejectedEvent;
        },
        .retry => |v| {
            try writePreamble(writer, "retry", session_id);
            writer.print(",\"attempt\":{}", .{v.attempt}) catch return error.SinkRejectedEvent;
            try writeFieldString(writer, "reason", v.reason);
            writer.writeAll("}\n") catch return error.SinkRejectedEvent;
        },
        .abort => |v| {
            try writePreamble(writer, "abort", session_id);
            if (v.reason) |reason| try writeFieldString(writer, "reason", reason);
            writer.writeAll("}\n") catch return error.SinkRejectedEvent;
        },
        .error_event => |v| {
            try writePreamble(writer, "error", session_id);
            try writeFieldString(writer, "category", @tagName(v.category));
            try writeFieldString(writer, "message", v.message);
            writer.print(",\"retryable\":{}", .{v.retryable}) catch return error.SinkRejectedEvent;
            writer.writeAll("}\n") catch return error.SinkRejectedEvent;
        },
    }
}

fn writePreamble(writer: *std.Io.Writer, event_type: []const u8, session_id: []const u8) agent.events.AgentEventSinkError!void {
    writer.writeAll("{\"schema\":1,\"type\":") catch return error.SinkRejectedEvent;
    try json_util.writeJsonString(writer, event_type);
    writer.writeAll(",\"session_id\":") catch return error.SinkRejectedEvent;
    try json_util.writeJsonString(writer, session_id);
}

fn writeFieldString(writer: *std.Io.Writer, name: []const u8, value: []const u8) agent.events.AgentEventSinkError!void {
    writer.writeAll(",") catch return error.SinkRejectedEvent;
    try json_util.writeJsonString(writer, name);
    writer.writeAll(":") catch return error.SinkRejectedEvent;
    try json_util.writeJsonString(writer, value);
}
