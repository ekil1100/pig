const std = @import("std");
const args = @import("args.zig");
const agent = @import("../core/agent/mod.zig");
const provider = @import("../provider/mod.zig");
const tui = @import("../tui/mod.zig");

pub const InteractiveStatus = enum { ok, failure, internal };

pub const Context = struct {
    allocator: std.mem.Allocator,
    model_client: ?agent.ModelClient = null,
    size: tui.layout.Size = .{ .width = 80, .height = 24 },
};

pub const InteractiveEventKind = enum { user, assistant, tool, error_item, status };

const TranscriptItem = struct {
    kind: InteractiveEventKind,
    text: std.ArrayList(u8) = .empty,
    is_streaming: bool = false,

    fn deinit(self: *TranscriptItem, allocator: std.mem.Allocator) void {
        self.text.deinit(allocator);
        self.* = undefined;
    }
};

pub const QueuedInteractiveEvent = struct {
    kind: InteractiveEventKind,
    text: std.ArrayList(u8) = .empty,
    is_streaming: bool = false,

    pub fn init(allocator: std.mem.Allocator, kind: InteractiveEventKind, text: []const u8, is_streaming: bool) !QueuedInteractiveEvent {
        var event = QueuedInteractiveEvent{ .kind = kind, .is_streaming = is_streaming };
        errdefer event.deinit(allocator);
        try event.text.appendSlice(allocator, text);
        return event;
    }

    pub fn deinit(self: *QueuedInteractiveEvent, allocator: std.mem.Allocator) void {
        self.text.deinit(allocator);
        self.* = undefined;
    }
};

pub const InteractiveEventQueue = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(QueuedInteractiveEvent) = .empty,
    capacity: usize = 256,

    pub fn init(allocator: std.mem.Allocator) InteractiveEventQueue {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *InteractiveEventQueue) void {
        for (self.events.items) |*event| event.deinit(self.allocator);
        self.events.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn push(self: *InteractiveEventQueue, kind: InteractiveEventKind, text: []const u8, is_streaming: bool) !void {
        if (self.events.items.len >= self.capacity) return error.QueueFull;
        var event = try QueuedInteractiveEvent.init(self.allocator, kind, text, is_streaming);
        errdefer event.deinit(self.allocator);
        try self.events.append(self.allocator, event);
    }

    pub fn popFront(self: *InteractiveEventQueue) ?QueuedInteractiveEvent {
        if (self.events.items.len == 0) return null;
        return self.events.orderedRemove(0);
    }
};

pub const AgentWorker = struct {
    abort_requested: bool = false,
    busy: bool = false,

    pub fn requestAbort(self: *AgentWorker) void {
        self.abort_requested = true;
    }
};

pub const InteractiveApp = struct {
    allocator: std.mem.Allocator,
    editor: tui.editor.EditorState,
    state: agent.AgentState,
    transcript: std.ArrayList(TranscriptItem) = .empty,
    size: tui.layout.Size,
    worker: AgentWorker = .{},

    pub fn init(allocator: std.mem.Allocator, size: tui.layout.Size, agent_config: agent.AgentConfig) InteractiveApp {
        return .{
            .allocator = allocator,
            .editor = tui.editor.EditorState.init(allocator),
            .state = agent.AgentState.init(allocator, agent_config),
            .size = size,
        };
    }

    pub fn deinit(self: *InteractiveApp) void {
        self.editor.deinit();
        self.state.deinit();
        for (self.transcript.items) |*item| item.deinit(self.allocator);
        self.transcript.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn handleInput(self: *InteractiveApp, event: tui.input.KeyEvent) !tui.editor.SubmitResult {
        return try self.editor.handle(event, self.worker.busy);
    }

    fn appendItem(self: *InteractiveApp, kind: InteractiveEventKind, text: []const u8, streaming: bool) !void {
        var item = TranscriptItem{ .kind = kind, .is_streaming = streaming };
        errdefer item.deinit(self.allocator);
        try item.text.appendSlice(self.allocator, text);
        try self.transcript.append(self.allocator, item);
    }

    fn appendToLastAssistant(self: *InteractiveApp, text: []const u8) !void {
        if (self.transcript.items.len == 0 or self.transcript.items[self.transcript.items.len - 1].kind != .assistant) {
            try self.appendItem(.assistant, "", true);
        }
        try self.transcript.items[self.transcript.items.len - 1].text.appendSlice(self.allocator, text);
    }

    fn markAssistantDone(self: *InteractiveApp) void {
        if (self.transcript.items.len == 0) return;
        const last = &self.transcript.items[self.transcript.items.len - 1];
        if (last.kind == .assistant) last.is_streaming = false;
    }

    pub fn renderFrame(self: *InteractiveApp) !tui.render.Frame {
        var frame = tui.render.Frame.init(self.allocator, self.size);
        errdefer frame.deinit();
        for (self.transcript.items) |item| {
            const prefix = switch (item.kind) {
                .user => "you: ",
                .assistant => "pig: ",
                .tool => "tool: ",
                .error_item => "error: ",
                .status => "status: ",
            };
            const line = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ prefix, item.text.items });
            defer self.allocator.free(line);
            try frame.appendLine(line);
        }
        if (self.worker.busy) {
            try frame.appendLine("... running (Ctrl+C to abort)");
        }
        const input_line = try std.fmt.allocPrint(self.allocator, "> {s}", .{self.editor.text()});
        defer self.allocator.free(input_line);
        try frame.appendLine(input_line);
        frame.cursor = .{ .row = @intCast(@min(frame.lines.items.len, @as(usize, self.size.height)) -| 1), .col = @intCast(@min(tui.layout.displayWidth(input_line), @as(usize, self.size.width) -| 1)) };
        return frame;
    }
};

pub fn runScript(config: args.RunConfig, context: Context, input_bytes: []const u8, output: *std.Io.Writer) !InteractiveStatus {
    var app = InteractiveApp.init(context.allocator, context.size, .{
        .thinking_level = config.thinking_level,
        .max_iterations = config.max_iterations,
    });
    defer app.deinit();

    const events = try tui.input.decodeAll(context.allocator, input_bytes);
    defer context.allocator.free(events);

    try renderApp(&app, output);
    for (events) |event| {
        const result = try app.handleInput(event);
        switch (result) {
            .none => try renderApp(&app, output),
            .exit => return .ok,
            .abort => {
                app.worker.requestAbort();
                try app.appendItem(.status, "abort requested", false);
                try renderApp(&app, output);
            },
            .submit => |prompt| {
                defer app.editor.freeSubmitted(prompt);
                try app.appendItem(.user, prompt, false);
                try renderApp(&app, output);
                const model = context.model_client orelse {
                    try app.appendItem(.error_item, "model client unavailable", false);
                    try renderApp(&app, output);
                    return .failure;
                };
                try runTurn(config, context, &app, model, prompt);
                try renderApp(&app, output);
            },
        }
    }
    return .ok;
}

fn runTurn(config: args.RunConfig, context: Context, app: *InteractiveApp, model: agent.ModelClient, prompt: []const u8) !void {
    _ = config;
    app.worker.busy = true;
    app.worker.abort_requested = false;
    defer app.worker.busy = false;

    var sink = InteractiveSink{ .app = app };
    var runtime = agent.AgentRuntime{
        .allocator = context.allocator,
        .state = &app.state,
        .model = model,
        .event_sink = sink.sink(),
        .abort_flag = &app.worker.abort_requested,
    };
    runtime.runUserText(prompt) catch |err| switch (err) {
        error.Aborted => try app.appendItem(.status, "aborted", false),
        else => try app.appendItem(.error_item, "agent turn failed", false),
    };
}

fn renderApp(app: *InteractiveApp, output: *std.Io.Writer) !void {
    var frame = try app.renderFrame();
    defer frame.deinit();
    const bytes = try tui.render.renderFull(app.allocator, &frame);
    defer app.allocator.free(bytes);
    try output.writeAll(bytes);
    try output.writeAll("\n");
}

const InteractiveSink = struct {
    app: *InteractiveApp,

    fn sink(self: *InteractiveSink) agent.AgentEventSink {
        return .{ .ptr = self, .on_event = onEvent };
    }

    fn onEvent(ptr: *anyopaque, event: agent.AgentEvent) agent.events.AgentEventSinkError!void {
        const self: *InteractiveSink = @ptrCast(@alignCast(ptr));
        self.handle(event) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
        };
    }

    fn handle(self: *InteractiveSink, event: agent.AgentEvent) !void {
        switch (event) {
            .message_start => |start| if (start.role == provider.Role.assistant) try self.app.appendItem(.assistant, "", true),
            .message_delta => |delta| if (delta.text_delta) |text| try self.app.appendToLastAssistant(text),
            .message_end => self.app.markAssistantDone(),
            .tool_execution_start => |tool| try self.app.appendItem(.tool, tool.name, true),
            .tool_execution_delta => |delta| try self.app.appendItem(.tool, delta.message, true),
            .tool_execution_end => |tool| {
                const text = if (tool.is_error) "failed" else "done";
                try self.app.appendItem(.tool, text, false);
            },
            .error_event => |err| try self.app.appendItem(.error_item, err.message, false),
            .abort => try self.app.appendItem(.status, "aborted", false),
            else => {},
        }
    }
};
