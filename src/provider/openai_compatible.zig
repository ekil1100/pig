const std = @import("std");
const events = @import("events.zig");
const errors = @import("errors.zig");
const sse = @import("sse.zig");
const types = @import("types.zig");
const transport = @import("transport.zig");
const messages = @import("messages.zig");
const config_mod = @import("config.zig");

pub const OpenAiCompatibleConfig = config_mod.OpenAiCompatibleConfig;
const ParseError = errors.ProviderParseError || events.EventSinkError || transport.ResponseStreamError || error{OutOfMemory};

const ToolState = struct {
    active: bool = false,
    started: bool = false,
    index: u32 = 0,
    id: std.ArrayList(u8) = .empty,
    name: std.ArrayList(u8) = .empty,
    args: std.ArrayList(u8) = .empty,

    fn deinit(self: *ToolState, allocator: std.mem.Allocator) void {
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
        try state.emitParseError("OpenAI-compatible stream ended without [DONE]");
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
        try self.state.handle(event.data);
    }
};

const ParserState = struct {
    allocator: std.mem.Allocator,
    sink: events.EventSink,
    started: bool = false,
    ended: bool = false,
    done: bool = false,
    had_provider_error: bool = false,
    tools: std.ArrayList(ToolState) = .empty,

    fn deinit(self: *ParserState) void {
        for (self.tools.items) |*tool| tool.deinit(self.allocator);
        self.tools.deinit(self.allocator);
    }

    fn ensureStart(self: *ParserState) ParseError!void {
        if (!self.started) {
            try self.sink.emit(.{ .message_start = .{ .role = .assistant } });
            self.started = true;
        }
    }

    fn handle(self: *ParserState, data: []const u8) ParseError!void {
        if (std.mem.eql(u8, data, "[DONE]")) {
            if (!self.done) try self.sink.emit(.done);
            self.done = true;
            return;
        }
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch {
            try self.emitParseError("invalid OpenAI-compatible JSON chunk");
            return error.StreamParseError;
        };
        defer parsed.deinit();
        const root = parsed.value;
        if (objectGet(root, "error")) |_| {
            self.had_provider_error = true;
            try self.sink.emit(.{ .error_event = .{ .category = .provider, .message = "provider error", .retryable = false } });
            return;
        }
        if (objectGet(root, "usage")) |usage_value| try self.emitUsage(usage_value);
        const choices_value = objectGet(root, "choices") orelse return;
        if (choices_value != .array or choices_value.array.items.len == 0) return;
        const choice = choices_value.array.items[0];
        if (objectGet(choice, "delta")) |delta| try self.handleDelta(delta);
        if (objectGet(choice, "finish_reason")) |finish| if (finish != .null) {
            const reason = if (finish == .string) finish.string else "stop";
            try self.finishActiveTools();
            try self.sink.emit(.{ .message_delta = .{ .stop_reason = reason } });
            if (!self.ended) {
                try self.sink.emit(.message_end);
                self.ended = true;
            }
        };
    }

    fn handleDelta(self: *ParserState, delta: std.json.Value) ParseError!void {
        if (objectGet(delta, "role")) |role_value| if (role_value == .string and std.mem.eql(u8, role_value.string, "assistant")) try self.ensureStart();
        if (objectGet(delta, "content")) |content| if (content == .string) {
            try self.ensureStart();
            try self.sink.emit(.{ .text_delta = .{ .text = content.string } });
        };
        if (objectGet(delta, "tool_calls")) |calls| {
            try self.ensureStart();
            if (calls == .array) for (calls.array.items) |call| try self.handleToolCall(call);
        }
    }

    fn getTool(self: *ParserState, index: u32) !*ToolState {
        for (self.tools.items) |*tool| if (tool.index == index) return tool;
        try self.tools.append(self.allocator, .{ .active = true, .index = index });
        return &self.tools.items[self.tools.items.len - 1];
    }

    fn handleToolCall(self: *ParserState, call: std.json.Value) ParseError!void {
        const idx = try intFromValue(objectGet(call, "index") orelse return error.StreamParseError);
        var tool = try self.getTool(idx);
        tool.active = true;
        if (objectGet(call, "id")) |id_value| if (id_value == .string and tool.id.items.len == 0) try tool.id.appendSlice(self.allocator, id_value.string);
        if (objectGet(call, "function")) |function| {
            if (objectGet(function, "name")) |name_value| if (name_value == .string and tool.name.items.len == 0) try tool.name.appendSlice(self.allocator, name_value.string);
            if (!tool.started and (tool.id.items.len > 0 or tool.name.items.len > 0)) {
                try self.sink.emit(.{ .tool_call_start = .{ .index = idx, .id = tool.id.items, .name = tool.name.items } });
                tool.started = true;
            }
            if (objectGet(function, "arguments")) |arg_value| if (arg_value == .string) {
                try tool.args.appendSlice(self.allocator, arg_value.string);
                try self.sink.emit(.{ .tool_call_delta = .{ .index = idx, .arguments_json_delta = arg_value.string } });
            };
        }
    }

    fn finishActiveTools(self: *ParserState) ParseError!void {
        for (self.tools.items) |*tool| {
            if (!tool.active) continue;
            if (tool.args.items.len == 0) try tool.args.appendSlice(self.allocator, "{}");
            validateJson(self.allocator, tool.args.items) catch {
                try self.emitParseError("invalid tool call arguments JSON");
                return error.StreamParseError;
            };
            try self.sink.emit(.{ .tool_call_end = .{ .index = tool.index, .id = tool.id.items, .name = tool.name.items, .arguments_json = tool.args.items } });
            tool.active = false;
        }
    }

    fn emitUsage(self: *ParserState, value: std.json.Value) ParseError!void {
        try self.sink.emit(.{ .usage = .{ .input_tokens = optionalInt(objectGet(value, "prompt_tokens")), .output_tokens = optionalInt(objectGet(value, "completion_tokens")) } });
    }

    fn emitParseError(self: *ParserState, message: []const u8) ParseError!void {
        try self.sink.emit(.{ .error_event = .{ .category = .stream_parse, .message = message, .retryable = false } });
    }
};

pub fn buildChatCompletionsRequest(allocator: std.mem.Allocator, config: OpenAiCompatibleConfig, input_messages: []const messages.MessageView) !transport.Request {
    const url = try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{std.mem.trimEnd(u8, config.base_url, "/")});
    errdefer allocator.free(url);
    const method = try allocator.dupe(u8, "POST");
    errdefer allocator.free(method);
    const auth = try std.fmt.allocPrint(allocator, "Bearer {s}", .{config.api_key});
    errdefer allocator.free(auth);
    const body = try buildBody(allocator, config.model, input_messages);
    errdefer allocator.free(body);

    const headers = try allocator.alloc(transport.Header, 3);
    errdefer allocator.free(headers);

    const authorization_name = try allocator.dupe(u8, "Authorization");
    errdefer allocator.free(authorization_name);
    headers[0] = .{ .name = authorization_name, .value = auth };

    const content_type_name = try allocator.dupe(u8, "Content-Type");
    errdefer allocator.free(content_type_name);
    const content_type_value = try allocator.dupe(u8, "application/json");
    errdefer allocator.free(content_type_value);
    headers[1] = .{ .name = content_type_name, .value = content_type_value };

    const accept_name = try allocator.dupe(u8, "Accept");
    errdefer allocator.free(accept_name);
    const accept_value = try allocator.dupe(u8, "text/event-stream");
    errdefer allocator.free(accept_value);
    headers[2] = .{ .name = accept_name, .value = accept_value };

    return .{ .method = method, .url = url, .headers = headers, .body = body };
}

fn buildBody(allocator: std.mem.Allocator, model: []const u8, input_messages: []const messages.MessageView) error{OutOfMemory}![]u8 {
    var w: std.Io.Writer.Allocating = .init(allocator);
    defer w.deinit();
    w.writer.writeAll("{\"model\":") catch return error.OutOfMemory;
    try writeJsonString(&w.writer, model);
    w.writer.writeAll(",\"stream\":true,\"messages\":[") catch return error.OutOfMemory;
    for (input_messages, 0..) |message, i| {
        if (i > 0) w.writer.writeAll(",") catch return error.OutOfMemory;
        w.writer.writeAll("{\"role\":") catch return error.OutOfMemory;
        try writeJsonString(&w.writer, types.Role.toString(message.role));
        w.writer.writeAll(",\"content\":") catch return error.OutOfMemory;
        try writeJsonString(&w.writer, firstText(message));
        w.writer.writeAll("}") catch return error.OutOfMemory;
    }
    w.writer.writeAll("]}") catch return error.OutOfMemory;
    return w.toOwnedSlice() catch return error.OutOfMemory;
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) error{OutOfMemory}!void {
    writer.writeByte('"') catch return error.OutOfMemory;
    for (value) |byte| {
        switch (byte) {
            '"' => writer.writeAll("\\\"") catch return error.OutOfMemory,
            '\\' => writer.writeAll("\\\\") catch return error.OutOfMemory,
            '\n' => writer.writeAll("\\n") catch return error.OutOfMemory,
            '\r' => writer.writeAll("\\r") catch return error.OutOfMemory,
            '\t' => writer.writeAll("\\t") catch return error.OutOfMemory,
            else => {
                if (byte < 0x20) {
                    writer.print("\\u00{x:0>2}", .{byte}) catch return error.OutOfMemory;
                } else {
                    writer.writeByte(byte) catch return error.OutOfMemory;
                }
            },
        }
    }
    writer.writeByte('"') catch return error.OutOfMemory;
}

fn firstText(message: messages.MessageView) []const u8 {
    for (message.content) |block| switch (block) {
        .text => |text| return text.text,
        else => {},
    };
    return "";
}

fn objectGet(value: std.json.Value, key: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(key);
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
