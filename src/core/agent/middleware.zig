const model_client = @import("model_client.zig");
const state = @import("state.zig");
const tool = @import("tool.zig");

pub const MiddlewareError = error{ OutOfMemory, MiddlewareRejected };

pub const ShouldStopAfterTurnContext = struct {
    state: *const state.AgentState,
    assistant_index: usize,
    tool_result_start_index: usize,
    tool_result_count: usize,
};

pub const MiddlewareHooks = struct {
    ptr: ?*anyopaque = null,
    before_input: ?*const fn (ptr: ?*anyopaque, input: []const u8) MiddlewareError!void = null,
    before_provider_request: ?*const fn (ptr: ?*anyopaque, request: model_client.ModelRequest) MiddlewareError!void = null,
    before_tool_call: ?*const fn (ptr: ?*anyopaque, call: tool.ToolCall) MiddlewareError!void = null,
    after_tool_result: ?*const fn (ptr: ?*anyopaque, result: tool.ToolExecutionResult) MiddlewareError!void = null,
    should_stop_after_turn: ?*const fn (ptr: ?*anyopaque, context: ShouldStopAfterTurnContext) bool = null,
    before_compaction: ?*const fn (ptr: ?*anyopaque) MiddlewareError!void = null,
    before_tree_navigation: ?*const fn (ptr: ?*anyopaque) MiddlewareError!void = null,

    pub fn callBeforeInput(self: MiddlewareHooks, input: []const u8) MiddlewareError!void {
        if (self.before_input) |f| try f(self.ptr, input);
    }

    pub fn callBeforeProviderRequest(self: MiddlewareHooks, request: model_client.ModelRequest) MiddlewareError!void {
        if (self.before_provider_request) |f| try f(self.ptr, request);
    }

    pub fn callBeforeToolCall(self: MiddlewareHooks, call: tool.ToolCall) MiddlewareError!void {
        if (self.before_tool_call) |f| try f(self.ptr, call);
    }

    pub fn callAfterToolResult(self: MiddlewareHooks, result: tool.ToolExecutionResult) MiddlewareError!void {
        if (self.after_tool_result) |f| try f(self.ptr, result);
    }

    pub fn callShouldStopAfterTurn(self: MiddlewareHooks, context: ShouldStopAfterTurnContext) bool {
        if (self.should_stop_after_turn) |f| return f(self.ptr, context);
        return false;
    }
};
