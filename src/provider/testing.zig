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
        var collected = CollectedEvent{ .tag = tagOf(event) };
        errdefer collected.deinit(self.allocator);
        switch (event) {
            .message_start => |v| {
                collected.role = v.role;
                collected.id = try self.dupeOpt(v.provider_message_id);
            },
            .message_delta => |v| {
                collected.stop_reason = try self.dupeOpt(v.stop_reason);
                collected.metadata_json = try self.dupeOpt(v.metadata_json);
            },
            .message_end => {},
            .text_delta => |v| collected.text = try self.allocator.dupe(u8, v.text),
            .thinking_delta => |v| {
                collected.text = try self.allocator.dupe(u8, v.text);
                collected.metadata_json = try self.dupeOpt(v.signature_delta);
            },
            .tool_call_start => |v| {
                collected.id = try self.dupeOpt(v.id);
                collected.name = try self.dupeOpt(v.name);
            },
            .tool_call_delta => |v| collected.arguments_json_delta = try self.allocator.dupe(u8, v.arguments_json_delta),
            .tool_call_end => |v| {
                collected.id = try self.allocator.dupe(u8, v.id);
                collected.name = try self.allocator.dupe(u8, v.name);
                collected.arguments_json = try self.allocator.dupe(u8, v.arguments_json);
            },
            .usage => |v| collected.usage = v,
            .cost => {},
            .error_event => |v| {
                collected.error_kind = v.category;
                collected.error_message = try self.allocator.dupe(u8, v.message);
            },
            .done => {},
        }
        try self.events.append(self.allocator, collected);
    }

    fn tagOf(event: events.ProviderEvent) events.ProviderEventTag {
        return switch (event) {
            .message_start => .message_start,
            .message_delta => .message_delta,
            .message_end => .message_end,
            .text_delta => .text_delta,
            .thinking_delta => .thinking_delta,
            .tool_call_start => .tool_call_start,
            .tool_call_delta => .tool_call_delta,
            .tool_call_end => .tool_call_end,
            .usage => .usage,
            .cost => .cost,
            .error_event => .error_event,
            .done => .done,
        };
    }

    fn onEvent(ptr: *anyopaque, event: events.ProviderEvent) events.EventSinkError!void {
        const self: *EventCollector = @ptrCast(@alignCast(ptr));
        self.append(event) catch return error.OutOfMemory;
    }
};
