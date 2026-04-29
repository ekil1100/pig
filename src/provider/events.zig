const usage_mod = @import("usage.zig");
const types = @import("types.zig");
const errors = @import("errors.zig");

pub const ProviderEventTag = enum {
    message_start,
    message_delta,
    message_end,
    text_delta,
    thinking_delta,
    tool_call_start,
    tool_call_delta,
    tool_call_end,
    usage,
    cost,
    error_event,
    done,
};

pub const MessageStart = struct { provider_message_id: ?[]const u8 = null, role: types.Role };
pub const MessageDelta = struct { stop_reason: ?[]const u8 = null, metadata_json: ?[]const u8 = null };
pub const TextDelta = struct { text: []const u8 };
pub const ThinkingDelta = struct { text: []const u8, signature_delta: ?[]const u8 = null };
pub const ToolCallStart = struct { index: u32, id: ?[]const u8 = null, name: ?[]const u8 = null };
pub const ToolCallDelta = struct { index: u32, arguments_json_delta: []const u8 };
pub const ToolCallEnd = struct { index: u32, id: []const u8, name: []const u8, arguments_json: []const u8 };
pub const Cost = struct { amount_micros: u64 = 0, currency: []const u8 = "USD" };

pub const ProviderEvent = union(ProviderEventTag) {
    message_start: MessageStart,
    message_delta: MessageDelta,
    message_end,
    text_delta: TextDelta,
    thinking_delta: ThinkingDelta,
    tool_call_start: ToolCallStart,
    tool_call_delta: ToolCallDelta,
    tool_call_end: ToolCallEnd,
    usage: usage_mod.Usage,
    cost: Cost,
    error_event: errors.ProviderErrorEvent,
    done,
};

pub const EventSinkError = error{
    OutOfMemory,
    SinkRejectedEvent,
};

pub const EventSink = struct {
    ptr: *anyopaque,
    on_event: *const fn (ptr: *anyopaque, event: ProviderEvent) EventSinkError!void,

    pub fn emit(self: EventSink, event: ProviderEvent) EventSinkError!void {
        return self.on_event(self.ptr, event);
    }
};
