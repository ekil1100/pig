const std = @import("std");
const events = @import("events.zig");
const errors = @import("errors.zig");
const sse = @import("sse.zig");
const transport = @import("transport.zig");

const ParseError = errors.ProviderParseError || events.EventSinkError || transport.ResponseStreamError || error{OutOfMemory};

const BlockState = struct {
    active: bool = false,
    is_tool: bool = false,
    index: u32 = 0,
    id: std.ArrayList(u8) = .empty,
    name: std.ArrayList(u8) = .empty,
    args: std.ArrayList(u8) = .empty,

    fn deinit(self: *BlockState, allocator: std.mem.Allocator) void {
        self.id.deinit(allocator);
        self.name.deinit(allocator);
        self.args.deinit(allocator);
    }
};

pub fn parseBytes(allocator: std.mem.Allocator, bytes: []const u8, sink: events.EventSink) ParseError!void {
    var stream = transport.RecordedStream{ .chunks = &.{bytes} };
    try parseStream(allocator, stream.stream(), sink);
}

pub fn parseStream(allocator: std.mem.Allocator, stream: transport.ResponseStream, sink: events.EventSink) ParseError!void {
    var response_stream = stream;
    defer response_stream.deinit();
    var state = ParserState{ .allocator = allocator, .sink = sink };
    defer state.deinit();
    var parser = sse.Parser.init(allocator);
    defer parser.deinit();
    var bridge = SseBridge{ .state = &state };
    var buffer: [8192]u8 = undefined;
    while (try response_stream.nextChunk(&buffer)) |chunk| parser.feed(chunk, bridge.sink()) catch |err| return mapSseError(err);
    parser.finish(bridge.sink()) catch |err| return mapSseError(err);
    if (!state.done and !state.had_provider_error) {
        try state.emitParseError("Anthropic stream ended without message_stop");
        return error.StreamParseError;
    }
}

const SseBridge = struct {
    state: *ParserState,

    fn sink(self: *SseBridge) sse.EventSink {
        return .{ .ptr = self, .on_event = onEvent };
    }

    fn onEvent(ptr: *anyopaque, event: sse.SseEvent) anyerror!void {
        const self: *SseBridge = @ptrCast(@alignCast(ptr));
        try self.state.handle(event.event, event.data);
    }
};

const ParserState = struct {
    allocator: std.mem.Allocator,
    sink: events.EventSink,
    block: BlockState = .{},
    done: bool = false,
    had_provider_error: bool = false,
    pending_usage: ?@import("usage.zig").Usage = null,

    fn deinit(self: *ParserState) void {
        self.block.deinit(self.allocator);
    }

    fn handle(self: *ParserState, event_name: ?[]const u8, data: []const u8) ParseError!void {
        const name = event_name orelse "message";
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch {
            try self.emitParseError("invalid Anthropic JSON chunk");
            return error.StreamParseError;
        };
        defer parsed.deinit();
        const root = parsed.value;

        if (std.mem.eql(u8, name, "error")) {
            self.had_provider_error = true;
            try self.sink.emit(.{ .error_event = .{ .category = .provider, .message = "provider error", .retryable = false } });
            return;
        }
        if (std.mem.eql(u8, name, "message_start")) {
            const msg = objectGet(root, "message") orelse root;
            const id = if (objectGet(msg, "id")) |idv| if (idv == .string) idv.string else null else null;
            try self.sink.emit(.{ .message_start = .{ .provider_message_id = id, .role = .assistant } });
            if (objectGet(msg, "usage")) |usage| self.pending_usage = usageFromValue(usage);
        } else if (std.mem.eql(u8, name, "content_block_start")) {
            try self.startBlock(root);
        } else if (std.mem.eql(u8, name, "content_block_delta")) {
            try self.deltaBlock(root);
        } else if (std.mem.eql(u8, name, "content_block_stop")) {
            try self.stopBlock(root);
        } else if (std.mem.eql(u8, name, "message_delta")) {
            if (objectGet(root, "usage")) |usage| {
                const current = usageFromValue(usage);
                const combined = if (self.pending_usage) |pending| pending.add(current) else current;
                self.pending_usage = null;
                try self.sink.emit(.{ .usage = combined });
            }
        } else if (std.mem.eql(u8, name, "message_stop")) {
            if (self.pending_usage) |pending| {
                try self.sink.emit(.{ .usage = pending });
                self.pending_usage = null;
            }
            if (self.block.active) {
                try self.emitParseError("Anthropic message_stop with active content block");
                return error.StreamParseError;
            }
            try self.sink.emit(.message_end);
            try self.sink.emit(.done);
            self.done = true;
        }
    }

    fn startBlock(self: *ParserState, root: std.json.Value) ParseError!void {
        if (self.block.active) {
            try self.emitParseError("duplicate Anthropic content block start");
            return error.StreamParseError;
        }
        const index = try intFromValue(objectGet(root, "index") orelse return error.StreamParseError);
        const block = objectGet(root, "content_block") orelse return;
        self.block.active = true;
        self.block.index = index;
        if (objectGet(block, "type")) |typ| if (typ == .string and std.mem.eql(u8, typ.string, "tool_use")) {
            self.block.is_tool = true;
            if (objectGet(block, "id")) |idv| if (idv == .string) try self.block.id.appendSlice(self.allocator, idv.string);
            if (objectGet(block, "name")) |namev| if (namev == .string) try self.block.name.appendSlice(self.allocator, namev.string);
            try self.sink.emit(.{ .tool_call_start = .{ .index = index, .id = self.block.id.items, .name = self.block.name.items } });
        };
    }

    fn deltaBlock(self: *ParserState, root: std.json.Value) ParseError!void {
        const index = try intFromValue(objectGet(root, "index") orelse return error.StreamParseError);
        if (!self.block.active or self.block.index != index) {
            try self.emitParseError("Anthropic delta for unknown content block");
            return error.StreamParseError;
        }
        const delta = objectGet(root, "delta") orelse return;
        if (objectGet(delta, "text")) |textv| if (textv == .string) try self.sink.emit(.{ .text_delta = .{ .text = textv.string } });
        if (objectGet(delta, "partial_json")) |part| if (part == .string) {
            try self.block.args.appendSlice(self.allocator, part.string);
            try self.sink.emit(.{ .tool_call_delta = .{ .index = index, .arguments_json_delta = part.string } });
        };
    }

    fn stopBlock(self: *ParserState, root: std.json.Value) ParseError!void {
        const index = try intFromValue(objectGet(root, "index") orelse return error.StreamParseError);
        if (!self.block.active or self.block.index != index) {
            try self.emitParseError("Anthropic stop for unknown content block");
            return error.StreamParseError;
        }
        if (self.block.is_tool) {
            if (self.block.args.items.len == 0) try self.block.args.appendSlice(self.allocator, "{}");
            validateJson(self.allocator, self.block.args.items) catch {
                try self.emitParseError("invalid tool call arguments JSON");
                return error.StreamParseError;
            };
            try self.sink.emit(.{ .tool_call_end = .{ .index = index, .id = self.block.id.items, .name = self.block.name.items, .arguments_json = self.block.args.items } });
        }
        self.block.active = false;
        self.block.is_tool = false;
        self.block.id.clearRetainingCapacity();
        self.block.name.clearRetainingCapacity();
        self.block.args.clearRetainingCapacity();
    }

    fn emitParseError(self: *ParserState, message: []const u8) ParseError!void {
        try self.sink.emit(.{ .error_event = .{ .category = .stream_parse, .message = message, .retryable = false } });
    }
};

fn objectGet(value: std.json.Value, key: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(key);
}

fn usageFromValue(value: std.json.Value) @import("usage.zig").Usage {
    return .{ .input_tokens = optionalInt(objectGet(value, "input_tokens")), .output_tokens = optionalInt(objectGet(value, "output_tokens")) };
}

fn optionalInt(value: ?std.json.Value) ?u64 {
    if (value) |v| return intFromValue(v) catch null;
    return null;
}

fn intFromValue(value: std.json.Value) error{StreamParseError}!u32 {
    return switch (value) {
        .integer => |i| std.math.cast(u32, i) orelse error.StreamParseError,
        .number_string => |s| std.fmt.parseUnsigned(u32, s, 10) catch error.StreamParseError,
        else => error.StreamParseError,
    };
}

fn mapSseError(err: anyerror) ParseError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.SinkRejectedEvent => error.SinkRejectedEvent,
        error.StreamParseError => error.StreamParseError,
        else => error.StreamParseError,
    };
}

fn validateJson(allocator: std.mem.Allocator, bytes: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return error.StreamParseError;
    defer parsed.deinit();
}
