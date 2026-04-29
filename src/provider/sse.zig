const std = @import("std");

pub const SseEvent = struct {
    event: ?[]const u8 = null,
    data: []const u8,
};

pub const EventSinkError = anyerror;
pub const EventSink = struct {
    ptr: *anyopaque,
    on_event: *const fn (ptr: *anyopaque, event: SseEvent) EventSinkError!void,

    pub fn emit(self: EventSink, event: SseEvent) EventSinkError!void {
        return self.on_event(self.ptr, event);
    }
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    line_buffer: std.ArrayList(u8) = .empty,
    event_name: std.ArrayList(u8) = .empty,
    data: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) Parser {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Parser) void {
        self.line_buffer.deinit(self.allocator);
        self.event_name.deinit(self.allocator);
        self.data.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn feed(self: *Parser, chunk: []const u8, sink: EventSink) !void {
        for (chunk) |byte| {
            if (byte == '\n') {
                var line = self.line_buffer.items;
                if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
                try self.processLine(line, sink);
                self.line_buffer.clearRetainingCapacity();
            } else {
                try self.line_buffer.append(self.allocator, byte);
            }
        }
    }

    pub fn finish(self: *Parser, sink: EventSink) !void {
        if (self.line_buffer.items.len > 0) {
            try self.processLine(self.line_buffer.items, sink);
            self.line_buffer.clearRetainingCapacity();
        }
        if (self.data.items.len > 0) try self.emit(sink);
        self.event_name.clearRetainingCapacity();
    }

    fn processLine(self: *Parser, line: []const u8, sink: EventSink) !void {
        if (line.len == 0) {
            if (self.data.items.len > 0) try self.emit(sink);
            self.event_name.clearRetainingCapacity();
            return;
        }
        if (line[0] == ':') return;
        if (std.mem.startsWith(u8, line, "event:")) {
            self.event_name.clearRetainingCapacity();
            var value = line[6..];
            if (value.len > 0 and value[0] == ' ') value = value[1..];
            try self.event_name.appendSlice(self.allocator, value);
            return;
        }
        if (std.mem.startsWith(u8, line, "data:")) {
            var value = line[5..];
            if (value.len > 0 and value[0] == ' ') value = value[1..];
            if (self.data.items.len > 0) try self.data.append(self.allocator, '\n');
            try self.data.appendSlice(self.allocator, value);
        }
    }

    fn emit(self: *Parser, sink: EventSink) !void {
        const event: ?[]const u8 = if (self.event_name.items.len > 0) self.event_name.items else null;
        try sink.emit(.{ .event = event, .data = self.data.items });
        self.event_name.clearRetainingCapacity();
        self.data.clearRetainingCapacity();
    }
};

pub const CollectedSseEvent = struct {
    event: ?[]const u8,
    data: []const u8,

    pub fn deinit(self: CollectedSseEvent, allocator: std.mem.Allocator) void {
        if (self.event) |event| allocator.free(event);
        allocator.free(self.data);
    }
};

pub const EventCollector = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(CollectedSseEvent) = .empty,

    pub fn init(allocator: std.mem.Allocator) EventCollector {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *EventCollector) void {
        for (self.events.items) |event| event.deinit(self.allocator);
        self.events.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn sink(self: *EventCollector) EventSink {
        return .{ .ptr = self, .on_event = onEvent };
    }

    fn onEvent(ptr: *anyopaque, event: SseEvent) EventSinkError!void {
        const self: *EventCollector = @ptrCast(@alignCast(ptr));
        const owned = CollectedSseEvent{
            .event = if (event.event) |name| self.allocator.dupe(u8, name) catch return error.OutOfMemory else null,
            .data = self.allocator.dupe(u8, event.data) catch return error.OutOfMemory,
        };
        self.events.append(self.allocator, owned) catch return error.OutOfMemory;
    }
};
