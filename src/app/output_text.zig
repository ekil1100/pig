const std = @import("std");
const agent = @import("../core/agent/mod.zig");
const interactive = @import("interactive.zig");

pub const TextEventSink = struct {
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,

    pub fn sink(self: *TextEventSink) agent.AgentEventSink {
        return .{ .ptr = self, .on_event = onEvent };
    }

    fn onEvent(ptr: *anyopaque, event: agent.AgentEvent) agent.events.AgentEventSinkError!void {
        const self: *TextEventSink = @ptrCast(@alignCast(ptr));
        switch (event) {
            .message_delta => |delta| {
                if (delta.thinking_delta) |text| {
                    try writeAll(self.stderr, "thinking: ");
                    try writeAll(self.stderr, text);
                    try writeAll(self.stderr, "\n");
                }
                if (delta.text_delta) |text| try writeAll(self.stdout, text);
            },
            .tool_execution_start => |tool| {
                const text = try interactive.toolStartText(self.allocator, tool.name, tool.arguments_json);
                defer self.allocator.free(text);
                try writeAll(self.stderr, "tool: ");
                try writeAll(self.stderr, text);
                try writeAll(self.stderr, "\n");
            },
            .tool_execution_end => |tool| if (tool.is_error) {
                const reason = try interactive.toolErrorText(self.allocator, tool.content_json);
                defer self.allocator.free(reason);
                try writeAll(self.stderr, "tool: error ");
                try writeAll(self.stderr, reason);
                try writeAll(self.stderr, "\n");
            },
            .tool_execution_delta => |delta| {
                try writeAll(self.stderr, delta.message);
                try writeAll(self.stderr, "\n");
            },
            .error_event => |err| {
                try writeAll(self.stderr, "error: ");
                try writeAll(self.stderr, err.message);
                try writeAll(self.stderr, "\n");
            },
            .abort => |abort| {
                try writeAll(self.stderr, "aborted");
                if (abort.reason) |reason| {
                    try writeAll(self.stderr, ": ");
                    try writeAll(self.stderr, reason);
                }
                try writeAll(self.stderr, "\n");
            },
            else => {},
        }
    }
};

fn writeAll(writer: *std.Io.Writer, bytes: []const u8) agent.events.AgentEventSinkError!void {
    writer.writeAll(bytes) catch return error.SinkRejectedEvent;
}
