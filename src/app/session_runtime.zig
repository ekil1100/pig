const std = @import("std");
const agent = @import("../core/agent/mod.zig");
const provider = @import("../provider/mod.zig");
const session = @import("../session/mod.zig");

pub const AgentEventFanout = struct {
    sinks: []const agent.AgentEventSink,

    pub fn sink(self: *AgentEventFanout) agent.AgentEventSink {
        return .{ .ptr = self, .on_event = onEvent };
    }

    fn onEvent(ptr: *anyopaque, event: agent.AgentEvent) agent.events.AgentEventSinkError!void {
        const self: *AgentEventFanout = @ptrCast(@alignCast(ptr));
        for (self.sinks) |child| try child.emit(event);
    }
};

pub const SessionRecorderSink = struct {
    state: *agent.AgentState,
    store: *session.store.SessionStore,
    session_id: []const u8,
    next_index: u64 = 0,
    turn_start_message_count: usize = 0,

    pub fn sink(self: *SessionRecorderSink) agent.AgentEventSink {
        return .{ .ptr = self, .on_event = onEvent };
    }

    fn onEvent(ptr: *anyopaque, event: agent.AgentEvent) agent.events.AgentEventSinkError!void {
        const self: *SessionRecorderSink = @ptrCast(@alignCast(ptr));
        self.handle(event) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.SinkRejectedEvent,
        };
    }

    fn handle(self: *SessionRecorderSink, event: agent.AgentEvent) !void {
        switch (event) {
            .turn_start => self.turn_start_message_count = self.state.messages.items.len,
            .tool_execution_start => |tool| try self.appendToolEvent(tool.id, tool.name, "start"),
            .tool_execution_delta => |delta| try self.appendToolEvent(delta.id, "", "delta"),
            .tool_execution_end => |tool| {
                try self.appendToolEvent(tool.id, tool.name, "end");
                try self.appendToolResult(tool.id, tool.is_error, tool.content_json);
            },
            .turn_end => {
                try self.appendNewMessages();
                try self.store.finishTurn();
            },
            else => {},
        }
    }

    fn appendToolEvent(self: *SessionRecorderSink, id: []const u8, name: []const u8, phase: []const u8) !void {
        const entry_id = try self.nextEntryId();
        defer self.store.allocator.free(entry_id);
        try self.store.append(.{
            .id = entry_id,
            .session_id = self.session_id,
            .parent_id = self.store.currentLeaf(),
            .created_ms = 0,
            .data = .{ .tool_event = .{ .tool_call_id = id, .tool_name = name, .phase = phase } },
        });
    }

    fn appendToolResult(self: *SessionRecorderSink, id: []const u8, is_error: bool, content_json: []const u8) !void {
        const entry_id = try self.nextEntryId();
        defer self.store.allocator.free(entry_id);
        try self.store.append(.{
            .id = entry_id,
            .session_id = self.session_id,
            .parent_id = self.store.currentLeaf(),
            .created_ms = 0,
            .data = .{ .tool_result = .{ .tool_call_id = id, .is_error = is_error, .content_json = content_json } },
        });
    }

    fn appendNewMessages(self: *SessionRecorderSink) !void {
        for (self.state.messages.items[self.turn_start_message_count..]) |message| {
            const entry_id = try self.nextEntryId();
            defer self.store.allocator.free(entry_id);
            const blocks = try self.store.allocator.alloc(session.entry.ContentBlock, message.content.len);
            defer self.store.allocator.free(blocks);
            for (message.content, 0..) |block, i| blocks[i] = contentBlockFromProvider(block);
            try self.store.append(.{
                .id = entry_id,
                .session_id = self.session_id,
                .parent_id = self.store.currentLeaf(),
                .created_ms = 0,
                .data = .{ .message = .{ .role = roleFromProvider(message.role), .content = blocks } },
            });
        }
    }

    fn nextEntryId(self: *SessionRecorderSink) ![]const u8 {
        self.next_index += 1;
        return try std.fmt.allocPrint(self.store.allocator, "entry_{d}", .{self.next_index});
    }
};

pub fn nextEntryIndex(entries: []const session.entry.Entry) u64 {
    var max: u64 = 0;
    for (entries) |entry| {
        if (!std.mem.startsWith(u8, entry.id, "entry_")) continue;
        const suffix = entry.id["entry_".len..];
        const value = std.fmt.parseUnsigned(u64, suffix, 10) catch continue;
        max = @max(max, value);
    }
    return max;
}

fn roleFromProvider(role: provider.Role) session.entry.Role {
    return switch (role) {
        .system => .system,
        .user => .user,
        .assistant => .assistant,
        .tool => .tool,
    };
}

fn contentBlockFromProvider(block: provider.OwnedContentBlock) session.entry.ContentBlock {
    return switch (block) {
        .text => |b| .{ .text = .{ .text = b.text } },
        .image_ref => |b| .{ .image_ref = .{ .uri = b.uri, .mime_type = b.mime_type } },
        .thinking => |b| .{ .thinking = .{ .text = b.text, .signature = b.signature } },
        .tool_call => |b| .{ .tool_call = .{ .id = b.id, .name = b.name, .arguments_json = b.arguments_json } },
        .tool_result => |b| .{ .tool_result = .{ .tool_call_id = b.tool_call_id, .content_json = b.content_json, .is_error = b.is_error } },
    };
}
