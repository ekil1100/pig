const std = @import("std");
const events = @import("events.zig");
const usage_mod = @import("usage.zig");
const types = @import("types.zig");
const errors = @import("errors.zig");

pub const CollectedEvent = struct {
    tag: events.ProviderEventTag,
    role: ?types.Role = null,
    text: ?[]const u8 = null,
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    arguments_json: ?[]const u8 = null,
    arguments_json_delta: ?[]const u8 = null,
    usage: ?usage_mod.Usage = null,
    stop_reason: ?[]const u8 = null,
    metadata_json: ?[]const u8 = null,
    error_kind: ?errors.ProviderErrorKind = null,
    error_message: ?[]const u8 = null,

    pub fn deinit(self: CollectedEvent, allocator: std.mem.Allocator) void {
        if (self.text) |v| allocator.free(v);
        if (self.id) |v| allocator.free(v);
        if (self.name) |v| allocator.free(v);
        if (self.arguments_json) |v| allocator.free(v);
        if (self.arguments_json_delta) |v| allocator.free(v);
        if (self.stop_reason) |v| allocator.free(v);
        if (self.metadata_json) |v| allocator.free(v);
        if (self.error_message) |v| allocator.free(v);
    }
};

pub const EventCollector = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(CollectedEvent),

    pub fn init(allocator: std.mem.Allocator) EventCollector {
        return .{ .allocator = allocator, .events = .empty };
    }

    pub fn deinit(self: *EventCollector) void {
        for (self.events.items) |event| event.deinit(self.allocator);
        self.events.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn sink(self: *EventCollector) events.EventSink {
        return .{ .ptr = self, .on_event = onEvent };
    }

    fn dupeOpt(self: *EventCollector, value: ?[]const u8) !?[]const u8 {
        return if (value) |v| try self.allocator.dupe(u8, v) else null;
    }

    fn append(self: *EventCollector, event: events.ProviderEvent) !void {
        const collected: CollectedEvent = switch (event) {
            .message_start => |v| .{ .tag = .message_start, .role = v.role, .id = try self.dupeOpt(v.provider_message_id) },
            .message_delta => |v| .{ .tag = .message_delta, .stop_reason = try self.dupeOpt(v.stop_reason), .metadata_json = try self.dupeOpt(v.metadata_json) },
            .message_end => .{ .tag = .message_end },
            .text_delta => |v| .{ .tag = .text_delta, .text = try self.allocator.dupe(u8, v.text) },
            .thinking_delta => |v| .{ .tag = .thinking_delta, .text = try self.allocator.dupe(u8, v.text), .metadata_json = try self.dupeOpt(v.signature_delta) },
            .tool_call_start => |v| .{ .tag = .tool_call_start, .id = try self.dupeOpt(v.id), .name = try self.dupeOpt(v.name) },
            .tool_call_delta => |v| .{ .tag = .tool_call_delta, .arguments_json_delta = try self.allocator.dupe(u8, v.arguments_json_delta) },
            .tool_call_end => |v| .{ .tag = .tool_call_end, .id = try self.allocator.dupe(u8, v.id), .name = try self.allocator.dupe(u8, v.name), .arguments_json = try self.allocator.dupe(u8, v.arguments_json) },
            .usage => |v| .{ .tag = .usage, .usage = v },
            .cost => .{ .tag = .cost },
            .error_event => |v| .{ .tag = .error_event, .error_kind = v.category, .error_message = try self.allocator.dupe(u8, v.message) },
            .done => .{ .tag = .done },
        };
        try self.events.append(self.allocator, collected);
    }

    fn onEvent(ptr: *anyopaque, event: events.ProviderEvent) events.EventSinkError!void {
        const self: *EventCollector = @ptrCast(@alignCast(ptr));
        self.append(event) catch return error.OutOfMemory;
    }
};
