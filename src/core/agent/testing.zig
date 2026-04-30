const std = @import("std");
const provider = @import("../../provider/mod.zig");
const events = @import("events.zig");
const tool = @import("tool.zig");

pub const CollectedAgentEvent = struct {
    tag: events.AgentEventTag,
    status: ?@import("state.zig").AgentStatus = null,
    role: ?provider.Role = null,
    text_delta: ?[]const u8 = null,
    stop_reason: ?[]const u8 = null,
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    arguments_json: ?[]const u8 = null,
    content_json: ?[]const u8 = null,
    is_error: bool = false,
    error_category: ?events.AgentErrorCategory = null,
    message: ?[]const u8 = null,

    pub fn deinit(self: CollectedAgentEvent, allocator: std.mem.Allocator) void {
        if (self.text_delta) |v| allocator.free(v);
        if (self.stop_reason) |v| allocator.free(v);
        if (self.id) |v| allocator.free(v);
        if (self.name) |v| allocator.free(v);
        if (self.arguments_json) |v| allocator.free(v);
        if (self.content_json) |v| allocator.free(v);
        if (self.message) |v| allocator.free(v);
    }
};

pub const AgentEventCollector = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(CollectedAgentEvent) = .empty,
    reject_after: ?usize = null,

    pub fn init(allocator: std.mem.Allocator) AgentEventCollector {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *AgentEventCollector) void {
        for (self.events.items) |event| event.deinit(self.allocator);
        self.events.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn sink(self: *AgentEventCollector) events.AgentEventSink {
        return .{ .ptr = self, .on_event = onEvent };
    }

    fn dupeOpt(self: *AgentEventCollector, value: ?[]const u8) !?[]const u8 {
        return if (value) |v| try self.allocator.dupe(u8, v) else null;
    }

    fn append(self: *AgentEventCollector, event: events.AgentEvent) !void {
        if (self.reject_after) |limit| if (self.events.items.len >= limit) return error.SinkRejectedEvent;
        var collected = CollectedAgentEvent{ .tag = tagOf(event) };
        errdefer collected.deinit(self.allocator);
        switch (event) {
            .agent_start => {},
            .agent_end => |v| collected.status = v.status,
            .turn_start => |v| collected.message = try self.allocator.dupe(u8, v.user_text),
            .turn_end => |v| collected.status = v.status,
            .message_start => |v| collected.role = v.role,
            .message_delta => |v| {
                collected.text_delta = try self.dupeOpt(v.text_delta);
                collected.stop_reason = try self.dupeOpt(v.stop_reason);
            },
            .message_end => |v| collected.role = v.role,
            .tool_execution_start => |v| {
                collected.id = try self.allocator.dupe(u8, v.id);
                collected.name = try self.allocator.dupe(u8, v.name);
                collected.arguments_json = try self.allocator.dupe(u8, v.arguments_json);
            },
            .tool_execution_delta => |v| {
                collected.id = try self.allocator.dupe(u8, v.id);
                collected.message = try self.allocator.dupe(u8, v.message);
            },
            .tool_execution_end => |v| {
                collected.id = try self.allocator.dupe(u8, v.id);
                collected.name = try self.allocator.dupe(u8, v.name);
                collected.is_error = v.is_error;
                collected.content_json = try self.allocator.dupe(u8, v.content_json);
            },
            .retry => |v| collected.message = try self.allocator.dupe(u8, v.reason),
            .abort => |v| collected.message = try self.dupeOpt(v.reason),
            .error_event => |v| {
                collected.error_category = v.category;
                collected.message = try self.allocator.dupe(u8, v.message);
            },
        }
        try self.events.append(self.allocator, collected);
    }

    fn tagOf(event: events.AgentEvent) events.AgentEventTag {
        return switch (event) {
            .agent_start => .agent_start,
            .agent_end => .agent_end,
            .turn_start => .turn_start,
            .turn_end => .turn_end,
            .message_start => .message_start,
            .message_delta => .message_delta,
            .message_end => .message_end,
            .tool_execution_start => .tool_execution_start,
            .tool_execution_delta => .tool_execution_delta,
            .tool_execution_end => .tool_execution_end,
            .retry => .retry,
            .abort => .abort,
            .error_event => .error_event,
        };
    }

    fn onEvent(ptr: *anyopaque, event: events.AgentEvent) events.AgentEventSinkError!void {
        const self: *AgentEventCollector = @ptrCast(@alignCast(ptr));
        self.append(event) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.SinkRejectedEvent => error.SinkRejectedEvent,
        };
    }
};

pub const EchoTool = struct {
    calls: usize = 0,

    pub fn registration(self: *EchoTool) tool.ToolRegistration {
        return .{ .spec = .{ .name = "echo", .description = "return arguments JSON" }, .executor = .{ .ptr = self, .execute_fn = execute } };
    }

    fn execute(ptr: *anyopaque, context: tool.ToolExecutionContext, call: tool.ToolCall) tool.ToolExecutorError!tool.ToolExecutionResult {
        const self: *EchoTool = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        const id = try context.allocator.dupe(u8, call.id);
        errdefer context.allocator.free(id);
        const content = try context.allocator.dupe(u8, call.arguments_json);
        return .{ .tool_call_id = id, .content_json = content };
    }
};

pub const FailingTool = struct {
    pub fn registration(self: *FailingTool) tool.ToolRegistration {
        return .{ .spec = .{ .name = "fail", .description = "fail" }, .executor = .{ .ptr = self, .execute_fn = execute } };
    }

    fn execute(_: *anyopaque, _: tool.ToolExecutionContext, _: tool.ToolCall) tool.ToolExecutorError!tool.ToolExecutionResult {
        return error.ToolFailed;
    }
};
