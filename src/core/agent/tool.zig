const std = @import("std");
const events = @import("events.zig");

pub const ToolSpec = struct {
    name: []const u8,
    description: []const u8,
};

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments_json: []const u8,
};

pub const ToolExecutionResult = struct {
    tool_call_id: []const u8,
    content_json: []const u8,
    is_error: bool = false,

    pub fn deinit(self: ToolExecutionResult, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_call_id);
        allocator.free(self.content_json);
    }
};

pub const ToolExecutorError = error{ OutOfMemory, ToolFailed };

pub const ToolExecutionContext = struct {
    allocator: std.mem.Allocator,
    event_sink: events.AgentEventSink,
    abort_flag: ?*const bool = null,
};

pub const ToolExecutor = struct {
    ptr: *anyopaque,
    execute_fn: *const fn (ptr: *anyopaque, context: ToolExecutionContext, call: ToolCall) ToolExecutorError!ToolExecutionResult,

    pub fn execute(self: ToolExecutor, context: ToolExecutionContext, call: ToolCall) ToolExecutorError!ToolExecutionResult {
        return self.execute_fn(self.ptr, context, call);
    }
};

pub const ToolRegistration = struct {
    spec: ToolSpec,
    executor: ToolExecutor,
};

pub const ToolRegistry = struct {
    registrations: []const ToolRegistration = &.{},

    pub fn find(self: ToolRegistry, name: []const u8) ?ToolRegistration {
        for (self.registrations) |registration| {
            if (std.mem.eql(u8, registration.spec.name, name)) return registration;
        }
        return null;
    }
};
