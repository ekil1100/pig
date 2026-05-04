const std = @import("std");
const provider = @import("../../provider/mod.zig");
const state = @import("state.zig");
const tool = @import("tool.zig");

pub const ModelClientError = error{ OutOfMemory, ProviderFailed, ProviderStreamParseFailed, SinkRejectedEvent };

pub const ModelRequest = struct {
    messages: []const provider.MessageView,
    tools: []const tool.ToolSpec = &.{},
    system_prompt: ?[]const u8 = null,
    thinking_level: state.ThinkingLevel = .off,
};

pub const ModelClient = struct {
    ptr: *anyopaque,
    stream_turn: *const fn (ptr: *anyopaque, request: ModelRequest, sink: provider.EventSink) ModelClientError!void,

    pub fn streamTurn(self: ModelClient, request: ModelRequest, sink: provider.EventSink) ModelClientError!void {
        return self.stream_turn(self.ptr, request, sink);
    }
};

pub const ScriptedModelClient = struct {
    turns: []const []const provider.ProviderEvent,
    index: usize = 0,
    request_count: usize = 0,
    last_message_count: usize = 0,
    last_tool_count: usize = 0,
    last_system_prompt: ?[]const u8 = null,
    last_system_prompt_buffer: [4096]u8 = undefined,

    pub fn client(self: *ScriptedModelClient) ModelClient {
        return .{ .ptr = self, .stream_turn = streamTurn };
    }

    fn streamTurn(ptr: *anyopaque, request: ModelRequest, sink: provider.EventSink) ModelClientError!void {
        const self: *ScriptedModelClient = @ptrCast(@alignCast(ptr));
        self.request_count += 1;
        self.last_message_count = request.messages.len;
        self.last_tool_count = request.tools.len;
        if (request.system_prompt) |prompt| {
            const len = @min(prompt.len, self.last_system_prompt_buffer.len);
            @memcpy(self.last_system_prompt_buffer[0..len], prompt[0..len]);
            self.last_system_prompt = self.last_system_prompt_buffer[0..len];
        } else {
            self.last_system_prompt = null;
        }
        if (self.index >= self.turns.len) return error.ProviderFailed;
        const turn = self.turns[self.index];
        self.index += 1;
        for (turn) |event| sink.emit(event) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SinkRejectedEvent => return error.SinkRejectedEvent,
        };
    }
};
