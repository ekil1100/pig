const std = @import("std");
const args = @import("args.zig");
const commands = @import("commands.zig");
const agent = @import("../core/agent/mod.zig");
const tui = @import("../tui/mod.zig");

pub const InteractiveStatus = enum { ok, failure, internal };

pub const Context = struct {
    allocator: std.mem.Allocator,
    model_client: ?agent.ModelClient = null,
    tool_registry: agent.ToolRegistry = .{},
    system_prompt: ?[]const u8 = null,
    reload_hook: ?ReloadHook = null,
    model_switch_hook: ?ModelSwitchHook = null,
    size: tui.layout.Size = .{ .width = 80, .height = 24 },
    initial_status: ?[]const u8 = null,
    model_status: ?[]const u8 = null,
    scoped_models_status: ?[]const u8 = null,
    recover_missing_model: bool = false,
};

pub const ReloadResult = struct {
    status: []const u8,
    system_prompt: ?[]const u8 = null,

    pub fn deinit(self: *ReloadResult, allocator: std.mem.Allocator) void {
        allocator.free(self.status);
        if (self.system_prompt) |prompt| allocator.free(prompt);
        self.* = undefined;
    }
};

pub const ReloadHook = struct {
    ptr: *anyopaque,
    reload_fn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!ReloadResult,

    pub fn reload(self: ReloadHook, allocator: std.mem.Allocator) !ReloadResult {
        return try self.reload_fn(self.ptr, allocator);
    }
};

pub const ModelSwitchResult = struct {
    status: []const u8,
    model_status: ?[]const u8 = null,
    scoped_models_status: ?[]const u8 = null,
    model_client: ?agent.ModelClient = null,
    clear_model_client: bool = false,

    pub fn deinit(self: *ModelSwitchResult, allocator: std.mem.Allocator) void {
        allocator.free(self.status);
        if (self.model_status) |status| allocator.free(status);
        if (self.scoped_models_status) |status| allocator.free(status);
        self.* = undefined;
    }
};

pub const ModelSwitchHook = struct {
    ptr: *anyopaque,
    select_fn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, model_id: []const u8) anyerror!ModelSwitchResult,

    pub fn select(self: ModelSwitchHook, allocator: std.mem.Allocator, model_id: []const u8) !ModelSwitchResult {
        return try self.select_fn(self.ptr, allocator, model_id);
    }
};

pub const InteractiveEventKind = enum { user, assistant, thinking, tool, error_item, status };

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
        if (try self.mergeIntoLast(kind, text, is_streaming)) return;
        if (self.events.items.len >= self.capacity) return error.QueueFull;
        var event = try QueuedInteractiveEvent.init(self.allocator, kind, text, is_streaming);
        errdefer event.deinit(self.allocator);
        try self.events.append(self.allocator, event);
    }

    pub fn popFront(self: *InteractiveEventQueue) ?QueuedInteractiveEvent {
        if (self.events.items.len == 0) return null;
        return self.events.orderedRemove(0);
    }

    fn mergeIntoLast(self: *InteractiveEventQueue, kind: InteractiveEventKind, text: []const u8, is_streaming: bool) !bool {
        if (text.len == 0 or self.events.items.len == 0) return false;
        const last = &self.events.items[self.events.items.len - 1];
        if (last.kind != kind or last.is_streaming != is_streaming) return false;
        switch (kind) {
            .assistant, .thinking => {
                if (!is_streaming) return false;
                try last.text.appendSlice(self.allocator, text);
                return true;
            },
            else => return false,
        }
    }
};

const SharedInteractiveEventQueue = struct {
    allocator: std.mem.Allocator,
    mutex: std.atomic.Mutex = .unlocked,
    queue: InteractiveEventQueue,

    fn init(allocator: std.mem.Allocator) SharedInteractiveEventQueue {
        return .{ .allocator = allocator, .queue = InteractiveEventQueue.init(allocator) };
    }

    fn deinit(self: *SharedInteractiveEventQueue) void {
        self.lock();
        defer self.unlock();
        self.queue.deinit();
    }

    fn push(self: *SharedInteractiveEventQueue, kind: InteractiveEventKind, text: []const u8, is_streaming: bool) !void {
        self.lock();
        defer self.unlock();
        try self.queue.push(kind, text, is_streaming);
    }

    fn popFront(self: *SharedInteractiveEventQueue) ?QueuedInteractiveEvent {
        self.lock();
        defer self.unlock();
        return self.queue.popFront();
    }

    fn lock(self: *SharedInteractiveEventQueue) void {
        while (!self.mutex.tryLock()) std.Thread.yield() catch {};
    }

    fn unlock(self: *SharedInteractiveEventQueue) void {
        self.mutex.unlock();
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
    owned_system_prompt: ?[]const u8 = null,
    model_client: ?agent.ModelClient = null,
    model_status: std.ArrayList(u8) = .empty,
    scoped_models_status: std.ArrayList(u8) = .empty,
    transcript: std.ArrayList(TranscriptItem) = .empty,
    size: tui.layout.Size,
    scroll_offset: usize = 0,
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
        if (self.owned_system_prompt) |prompt| self.allocator.free(prompt);
        self.model_status.deinit(self.allocator);
        self.scoped_models_status.deinit(self.allocator);
        for (self.transcript.items) |*item| item.deinit(self.allocator);
        self.transcript.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn handleInput(self: *InteractiveApp, event: tui.input.KeyEvent) !tui.editor.SubmitResult {
        switch (event.kind) {
            .page_up => {
                self.scrollByPage(.up);
                return .none;
            },
            .page_down => {
                self.scrollByPage(.down);
                return .none;
            },
            .mouse_scroll => {
                if (event.mouse_scroll) |direction| switch (direction) {
                    .up => self.scrollByLines(.up, 3),
                    .down => self.scrollByLines(.down, 3),
                    else => {},
                };
                return .none;
            },
            else => {},
        }
        const result = try self.editor.handle(event, self.worker.busy);
        self.scroll_offset = 0;
        return result;
    }

    const ScrollDirection = enum { up, down };

    fn scrollByPage(self: *InteractiveApp, direction: ScrollDirection) void {
        const step: usize = @max(@as(usize, self.size.height) / 2, 1);
        self.scrollByLines(direction, step);
    }

    fn scrollByLines(self: *InteractiveApp, direction: ScrollDirection, step: usize) void {
        switch (direction) {
            .up => self.scroll_offset +|= step,
            .down => self.scroll_offset -|= step,
        }
    }

    fn appendItem(self: *InteractiveApp, kind: InteractiveEventKind, text: []const u8, streaming: bool) !void {
        var item = TranscriptItem{ .kind = kind, .is_streaming = streaming };
        errdefer item.deinit(self.allocator);
        try item.text.appendSlice(self.allocator, text);
        try self.transcript.append(self.allocator, item);
        if (kind == .user) {
            self.scroll_offset = 0;
        }
    }

    fn appendToLastAssistant(self: *InteractiveApp, text: []const u8) !void {
        self.markLastStreamingKindDone(.thinking);
        if (self.transcript.items.len == 0 or self.transcript.items[self.transcript.items.len - 1].kind != .assistant) {
            try self.appendItem(.assistant, "", true);
        }
        try self.transcript.items[self.transcript.items.len - 1].text.appendSlice(self.allocator, text);
    }

    fn appendToLastThinking(self: *InteractiveApp, text: []const u8) !void {
        self.markLastStreamingKindDone(.assistant);
        if (self.transcript.items.len == 0 or self.transcript.items[self.transcript.items.len - 1].kind != .thinking) {
            try self.appendItem(.thinking, "", true);
        }
        try self.transcript.items[self.transcript.items.len - 1].text.appendSlice(self.allocator, text);
    }

    fn markStreamingTextDone(self: *InteractiveApp) void {
        self.markLastStreamingKindDone(.assistant);
        self.markLastStreamingKindDone(.thinking);
    }

    fn markLastStreamingKindDone(self: *InteractiveApp, kind: InteractiveEventKind) void {
        if (self.transcript.items.len == 0) return;
        const last = &self.transcript.items[self.transcript.items.len - 1];
        if (last.kind == kind) last.is_streaming = false;
    }

    fn markLastStreamingToolDone(self: *InteractiveApp) void {
        var index = self.transcript.items.len;
        while (index > 0) {
            index -= 1;
            const item = &self.transcript.items[index];
            if (item.kind == .tool and item.is_streaming) {
                item.is_streaming = false;
                return;
            }
        }
    }

    fn setSystemPrompt(self: *InteractiveApp, prompt: ?[]const u8) !void {
        if (self.owned_system_prompt) |old| self.allocator.free(old);
        self.owned_system_prompt = if (prompt) |value| try self.allocator.dupe(u8, value) else null;
        self.state.config.system_prompt = self.owned_system_prompt;
    }

    fn setModelInfo(self: *InteractiveApp, model_status: ?[]const u8, scoped_models_status: ?[]const u8) !void {
        self.model_status.clearRetainingCapacity();
        self.scoped_models_status.clearRetainingCapacity();
        if (model_status) |status| try self.model_status.appendSlice(self.allocator, status);
        if (scoped_models_status) |status| try self.scoped_models_status.appendSlice(self.allocator, status);
    }

    pub fn renderFrame(self: *InteractiveApp) !tui.render.Frame {
        var frame = tui.render.Frame.init(self.allocator, self.size);
        errdefer frame.deinit();

        for (self.transcript.items) |*item| {
            try appendTranscriptItemLines(self.allocator, &frame.lines, item, self.size.width);
        }
        if (self.worker.busy) {
            try appendWrappedLines(self.allocator, &frame.lines, "... running (Ctrl+C to abort)", self.size.width);
        }
        const input_row_start = frame.lines.items.len;
        const input_line = try std.fmt.allocPrint(self.allocator, "> {s}", .{self.editor.text()});
        defer self.allocator.free(input_line);
        // Append the wrapped input lines straight into frame.lines. Each line is
        // already at most `width` columns, so wrapping is idempotent and there is
        // no need to round-trip through frame.appendLine (which would re-wrap via
        // the leak-prone tui.layout.wrapText).
        try appendWrappedLines(self.allocator, &frame.lines, input_line, self.size.width);
        const input_cursor = try editorCursorPosition(self.allocator, &self.editor, self.size.width);

        const height = @max(@as(usize, self.size.height), 1);
        const tail_top = frame.lines.items.len -| height;
        self.scroll_offset = @min(self.scroll_offset, tail_top);
        frame.viewport_top = tail_top -| self.scroll_offset;
        frame.cursor = .{
            .row = input_row_start + input_cursor.row_offset,
            .col = @min(input_cursor.col, @as(usize, self.size.width) -| 1),
        };
        return frame;
    }
};

const EditorCursorPosition = struct {
    row_offset: usize,
    col: usize,
};

fn editorCursorPosition(allocator: std.mem.Allocator, editor: *const tui.editor.EditorState, width: u16) !EditorCursorPosition {
    const cursor_prefix = try std.fmt.allocPrint(allocator, "> {s}", .{editor.text()[0..editor.cursor_byte]});
    defer allocator.free(cursor_prefix);
    var wrapped: std.ArrayList([]const u8) = .empty;
    defer freeOwnedLines(allocator, &wrapped);
    try appendWrappedLines(allocator, &wrapped, cursor_prefix, width);
    const last_line = if (wrapped.items.len == 0) "" else wrapped.items[wrapped.items.len - 1];
    return .{
        .row_offset = wrapped.items.len -| 1,
        .col = tui.layout.displayWidth(last_line),
    };
}

// Wrap `text` to `width` display columns and append each resulting line, as an
// owned dup, into `lines`. This mirrors tui.layout.wrapText's wrapping rules but
// streams the duped lines straight into the destination list. We deliberately do
// not route through tui.layout.wrapText here: that helper appends each line via
// `lines.append(allocator, try allocator.dupe(...))`, so an OOM growing its
// internal list leaks the already-duped line (the dup is evaluated before the
// failing append, and the failed append never stores it). Building the dup in a
// local first and only then appending keeps every line freed on the OOM path.
fn appendWrappedLines(allocator: std.mem.Allocator, lines: *std.ArrayList([]const u8), text: []const u8, raw_width: u16) !void {
    const width = @max(@as(usize, raw_width), 1);
    var start: usize = 0;
    var i: usize = 0;
    var current_width: usize = 0;
    while (i < text.len) {
        if (text[i] == '\n') {
            try appendOwnedLine(allocator, lines, text[start..i]);
            i += 1;
            start = i;
            current_width = 0;
            continue;
        }
        const unit_end = tui.layout.nextDisplayUnitEnd(text, i);
        const char_width = tui.layout.displayWidth(text[i..unit_end]);
        if (current_width > 0 and current_width + char_width > width) {
            try appendOwnedLine(allocator, lines, text[start..i]);
            start = i;
            current_width = 0;
            continue;
        }
        current_width += char_width;
        i = unit_end;
    }
    try appendOwnedLine(allocator, lines, text[start..]);
}

fn appendOwnedLine(allocator: std.mem.Allocator, lines: *std.ArrayList([]const u8), line: []const u8) !void {
    const copy = try allocator.dupe(u8, line);
    errdefer allocator.free(copy);
    try lines.append(allocator, copy);
}

fn freeOwnedLines(allocator: std.mem.Allocator, lines: *std.ArrayList([]const u8)) void {
    for (lines.items) |line| allocator.free(line);
    lines.deinit(allocator);
}

fn appendTranscriptItemLines(allocator: std.mem.Allocator, lines: *std.ArrayList([]const u8), item: *const TranscriptItem, width: u16) !void {
    const prefix = switch (item.kind) {
        .user => "you: ",
        .assistant => "pig: ",
        .thinking => "thinking: ",
        .tool => "tool: ",
        .error_item => "error: ",
        .status => "status: ",
    };
    const line = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, item.text.items });
    defer allocator.free(line);
    try appendWrappedLines(allocator, lines, line, width);
}

pub fn runScript(config: args.RunConfig, context: Context, input_bytes: []const u8, output: *std.Io.Writer) !InteractiveStatus {
    var app = InteractiveApp.init(context.allocator, context.size, .{
        .system_prompt = context.system_prompt,
        .thinking_level = config.thinking_level,
    });
    defer app.deinit();
    app.model_client = context.model_client;
    try app.setSystemPrompt(context.system_prompt);
    try app.setModelInfo(context.model_status, context.scoped_models_status);
    if (context.initial_status) |status| try app.appendItem(.status, status, false);

    const events = try tui.input.decodeAll(context.allocator, input_bytes);
    defer context.allocator.free(events);

    try renderApp(&app, output);
    for (events) |event| {
        const status = try handleInputEvent(config, context, &app, event, output);
        switch (status) {
            .continue_loop => {},
            .exit_ok => return .ok,
            .failure => return .failure,
            .internal => return .internal,
        }
    }
    return .ok;
}

pub fn runLive(config: args.RunConfig, context: Context, io: std.Io, output: *std.Io.Writer) !InteractiveStatus {
    var app = InteractiveApp.init(context.allocator, context.size, .{
        .system_prompt = context.system_prompt,
        .thinking_level = config.thinking_level,
    });
    defer app.deinit();
    app.model_client = context.model_client;
    try app.setSystemPrompt(context.system_prompt);
    try app.setModelInfo(context.model_status, context.scoped_models_status);
    if (context.initial_status) |status| try app.appendItem(.status, status, false);

    var session = tui.terminal.TerminalSession{ .size = context.size };
    const stdin_file = std.Io.File.stdin();
    const stdout_file = std.Io.File.stdout();
    const stdin_is_tty = stdin_file.isTty(io) catch false;
    const stdout_is_tty = stdout_file.isTty(io) catch false;
    const interactive_tty = stdin_is_tty and stdout_is_tty;
    if (interactive_tty) {
        session.enterRawModeForFd(std.posix.STDIN_FILENO) catch {};
    }
    defer session.restoreForFd(std.posix.STDIN_FILENO);

    if (interactive_tty) {
        try output.writeAll(tui.terminal.interactive_enter_sequence);
        try output.flush();
    }
    defer if (interactive_tty) {
        output.writeAll(tui.terminal.interactive_exit_sequence) catch {};
        output.flush() catch {};
    };

    var live_renderer = tui.render.TerminalRenderer.init(context.allocator);
    defer live_renderer.deinit();
    defer live_renderer.finish(output);

    try renderLiveApp(&live_renderer, &app, output);
    try output.flush();

    var active_turn: ?*ActiveTurn = null;
    defer if (active_turn) |turn| turn.finish(&app);

    var input_decoder = tui.input.StreamDecoder.init(context.allocator);
    defer input_decoder.deinit();
    var input_pending_elapsed_ms: u64 = 0;

    var input_buffer: [128]u8 = undefined;
    while (true) {
        if (interactive_tty) {
            if (tui.terminal.detectSizeForFd(std.posix.STDOUT_FILENO) orelse tui.terminal.detectSizeForFd(std.posix.STDIN_FILENO)) |size| {
                if (size.width != app.size.width or size.height != app.size.height) {
                    app.size = size;
                    session.size = size;
                    try renderLiveApp(&live_renderer, &app, output);
                    try output.flush();
                }
            }
        }
        if (try pumpActiveTurn(&active_turn, &app)) {
            try renderLiveApp(&live_renderer, &app, output);
            try output.flush();
        }
        const poll_timeout: i32 = if (active_turn == null) if (interactive_tty) 250 else -1 else 25;
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = std.posix.STDIN_FILENO,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = try std.posix.poll(&poll_fds, poll_timeout);
        if (ready == 0) {
            if (poll_timeout > 0 and input_decoder.pending.items.len > 0) input_pending_elapsed_ms += @intCast(poll_timeout);
            if (input_decoder.shouldFlushTimedOut(input_pending_elapsed_ms)) {
                if (try flushLiveInputDecoder(&input_decoder, config, context, &app, &active_turn, &live_renderer, output)) |status| return status;
                input_pending_elapsed_ms = 0;
            }
            continue;
        }
        const has_input = (poll_fds[0].revents & std.posix.POLL.IN) != 0;
        if (!has_input and (poll_fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL)) != 0) return .ok;

        const read_len = std.posix.read(std.posix.STDIN_FILENO, &input_buffer) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        };
        if (read_len == 0) return .ok;

        var cooked_buffer: [128]u8 = undefined;
        const bytes = if (session.mode == .raw)
            input_buffer[0..read_len]
        else blk: {
            for (input_buffer[0..read_len], 0..) |byte, index| {
                cooked_buffer[index] = if (byte == '\n') '\r' else byte;
            }
            break :blk cooked_buffer[0..read_len];
        };

        try input_decoder.push(bytes);
        input_pending_elapsed_ms = 0;
        if (try handleLiveDecodedInput(&input_decoder, config, context, &app, &active_turn, &live_renderer, output, false)) |status| return status;
    }
}

const InputStatus = enum { continue_loop, exit_ok, failure, internal };

fn flushLiveInputDecoder(input_decoder: *tui.input.StreamDecoder, config: args.RunConfig, context: Context, app: *InteractiveApp, active_turn: *?*ActiveTurn, renderer: *tui.render.TerminalRenderer, output: *std.Io.Writer) !?InteractiveStatus {
    if (input_decoder.pending.items.len == 0) return null;
    return try handleLiveDecodedInput(input_decoder, config, context, app, active_turn, renderer, output, true);
}

fn handleLiveDecodedInput(input_decoder: *tui.input.StreamDecoder, config: args.RunConfig, context: Context, app: *InteractiveApp, active_turn: *?*ActiveTurn, renderer: *tui.render.TerminalRenderer, output: *std.Io.Writer, flush_pending: bool) !?InteractiveStatus {
    const decoded = if (flush_pending) try input_decoder.flushTimedOut() else try input_decoder.decodeAvailable();
    defer context.allocator.free(decoded.events);
    defer input_decoder.discard(decoded.consumed);

    for (decoded.events) |event| {
        const status = try handleLiveInputEvent(config, context, app, active_turn, renderer, event, output);
        try output.flush();
        switch (status) {
            .continue_loop => {},
            .exit_ok => return .ok,
            .failure => return .failure,
            .internal => return .internal,
        }
    }
    return null;
}

fn handleLiveInputEvent(config: args.RunConfig, context: Context, app: *InteractiveApp, active_turn: *?*ActiveTurn, renderer: *tui.render.TerminalRenderer, event: tui.input.KeyEvent, output: *std.Io.Writer) !InputStatus {
    const result = try app.handleInput(event);
    switch (result) {
        .none => try renderLiveApp(renderer, app, output),
        .exit => {
            if (active_turn.*) |turn| {
                turn.requestAbort();
                try app.appendItem(.status, "abort requested", false);
                try renderLiveApp(renderer, app, output);
                return .continue_loop;
            }
            return .exit_ok;
        },
        .abort => {
            if (active_turn.*) |turn| turn.requestAbort();
            app.worker.requestAbort();
            try app.appendItem(.status, "abort requested", false);
            try renderLiveApp(renderer, app, output);
        },
        .submit => |prompt| {
            var prompt_owned = true;
            defer if (prompt_owned) app.editor.freeSubmitted(prompt);
            if (commands.isCommandInput(prompt)) {
                const command_status = try handleCommand(context, app, prompt, active_turn);
                try renderLiveApp(renderer, app, output);
                return command_status;
            }
            if (active_turn.* != null) {
                try app.appendItem(.status, "turn already running", false);
                try renderLiveApp(renderer, app, output);
                return .continue_loop;
            }
            var model_prompt = try prepareSubmittedPrompt(context.allocator, prompt);
            defer model_prompt.deinit(context.allocator);
            try app.appendItem(.user, model_prompt.text, false);
            try renderLiveApp(renderer, app, output);
            const model = app.model_client orelse {
                try app.appendItem(.error_item, "model client unavailable", false);
                try renderLiveApp(renderer, app, output);
                return if (context.recover_missing_model) .continue_loop else .failure;
            };
            active_turn.* = try ActiveTurn.start(config, context, app, model, model_prompt.text);
            // ActiveTurn.start adopts the prompt slice by value (turn.prompt = the
            // slice; no dupe). Hand ownership to the turn BEFORE any further fallible
            // call: if renderLiveApp below fails, the surrounding defers (prompt_owned
            // and model_prompt.deinit) must NOT free a buffer that the turn now owns
            // and will free in finish(), or we double-free the same pointer.
            if (model_prompt.owned) {
                model_prompt.owned = false;
            } else {
                prompt_owned = false;
            }
            try renderLiveApp(renderer, app, output);
        },
    }
    return .continue_loop;
}

fn handleInputEvent(config: args.RunConfig, context: Context, app: *InteractiveApp, event: tui.input.KeyEvent, output: *std.Io.Writer) !InputStatus {
    const result = try app.handleInput(event);
    switch (result) {
        .none => try renderApp(app, output),
        .exit => return .exit_ok,
        .abort => {
            app.worker.requestAbort();
            try app.appendItem(.status, "abort requested", false);
            try renderApp(app, output);
        },
        .submit => |prompt| {
            defer app.editor.freeSubmitted(prompt);
            if (commands.isCommandInput(prompt)) {
                const command_status = try handleCommand(context, app, prompt, null);
                try renderApp(app, output);
                return command_status;
            }
            var model_prompt = try prepareSubmittedPrompt(context.allocator, prompt);
            defer model_prompt.deinit(context.allocator);
            try app.appendItem(.user, model_prompt.text, false);
            try renderApp(app, output);
            const model = app.model_client orelse {
                try app.appendItem(.error_item, "model client unavailable", false);
                try renderApp(app, output);
                return if (context.recover_missing_model) .continue_loop else .failure;
            };
            try runTurn(config, context, app, model, model_prompt.text);
            try renderApp(app, output);
        },
    }
    return .continue_loop;
}

const PreparedPrompt = struct {
    text: []const u8,
    owned: bool = false,

    fn deinit(self: *PreparedPrompt, allocator: std.mem.Allocator) void {
        if (self.owned) allocator.free(self.text);
        self.* = undefined;
    }
};

fn prepareSubmittedPrompt(allocator: std.mem.Allocator, prompt: []const u8) !PreparedPrompt {
    const trimmed = std.mem.trim(u8, prompt, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "//")) {
        return .{ .text = try allocator.dupe(u8, trimmed[1..]), .owned = true };
    }
    return .{ .text = prompt };
}

const ActiveTurn = struct {
    allocator: std.mem.Allocator,
    config: args.RunConfig,
    context: Context,
    app: *InteractiveApp,
    model: agent.ModelClient,
    prompt: []const u8,
    queue: SharedInteractiveEventQueue,
    abort_requested: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    fn start(config: args.RunConfig, context: Context, app: *InteractiveApp, model: agent.ModelClient, prompt: []const u8) !*ActiveTurn {
        const turn = try context.allocator.create(ActiveTurn);
        errdefer context.allocator.destroy(turn);
        turn.* = .{
            .allocator = context.allocator,
            .config = config,
            .context = context,
            .app = app,
            .model = model,
            .prompt = prompt,
            .queue = SharedInteractiveEventQueue.init(context.allocator),
        };
        errdefer turn.queue.deinit();
        app.worker.busy = true;
        app.worker.abort_requested = false;
        errdefer app.worker.busy = false;
        turn.thread = try std.Thread.spawn(.{}, ActiveTurn.run, .{turn});
        return turn;
    }

    fn run(turn: *ActiveTurn) void {
        defer turn.done.store(true, .release);
        var sink = QueueSink{ .queue = &turn.queue };
        var runtime = agent.AgentRuntime{
            .allocator = turn.context.allocator,
            .state = &turn.app.state,
            .model = turn.model,
            .tools = turn.context.tool_registry,
            .event_sink = sink.sink(),
            .abort_signal = .{ .ptr = turn, .load_fn = loadAbort },
        };
        runtime.runUserText(turn.prompt) catch |err| switch (err) {
            error.Aborted => turn.queue.push(.status, "aborted", false) catch {},
            else => {
                turn.queue.push(.error_item, "agent turn failed", false) catch {};
            },
        };
    }

    fn finish(turn: *ActiveTurn, app: *InteractiveApp) void {
        if (turn.thread) |thread| thread.join();
        turn.queue.deinit();
        turn.allocator.free(turn.prompt);
        app.worker.busy = false;
        app.worker.abort_requested = false;
        turn.allocator.destroy(turn);
    }

    fn requestAbort(turn: *ActiveTurn) void {
        turn.abort_requested.store(true, .release);
    }

    fn loadAbort(ptr: *const anyopaque) bool {
        const turn: *const ActiveTurn = @ptrCast(@alignCast(ptr));
        return turn.abort_requested.load(.acquire);
    }
};

fn pumpActiveTurn(active_turn: *?*ActiveTurn, app: *InteractiveApp) !bool {
    const turn = active_turn.* orelse return false;
    var changed = try drainQueuedEvents(turn, app);
    if (turn.done.load(.acquire)) {
        if (try drainQueuedEvents(turn, app)) changed = true;
        active_turn.* = null;
        turn.finish(app);
        changed = true;
    }
    return changed;
}

fn drainQueuedEvents(turn: *ActiveTurn, app: *InteractiveApp) !bool {
    var changed = false;
    while (turn.queue.popFront()) |event_const| {
        var event = event_const;
        defer event.deinit(turn.allocator);
        try applyQueuedEvent(app, event);
        changed = true;
    }
    return changed;
}

fn applyQueuedEvent(app: *InteractiveApp, event: QueuedInteractiveEvent) !void {
    switch (event.kind) {
        .assistant => {
            if (!event.is_streaming and event.text.items.len == 0) {
                app.markStreamingTextDone();
            } else {
                try app.appendToLastAssistant(event.text.items);
            }
        },
        .thinking => try app.appendToLastThinking(event.text.items),
        .tool => {
            if (!event.is_streaming and event.text.items.len == 0) {
                app.markLastStreamingToolDone();
            } else {
                try app.appendItem(.tool, event.text.items, event.is_streaming);
            }
        },
        .error_item => try app.appendItem(.error_item, event.text.items, event.is_streaming),
        .status => try app.appendItem(.status, event.text.items, event.is_streaming),
        .user => try app.appendItem(.user, event.text.items, event.is_streaming),
    }
}

const QueueSink = struct {
    queue: *SharedInteractiveEventQueue,

    fn sink(self: *QueueSink) agent.AgentEventSink {
        return .{ .ptr = self, .on_event = onEvent };
    }

    fn onEvent(ptr: *anyopaque, event: agent.AgentEvent) agent.events.AgentEventSinkError!void {
        const self: *QueueSink = @ptrCast(@alignCast(ptr));
        self.handle(event) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.QueueFull => error.SinkRejectedEvent,
        };
    }

    fn handle(self: *QueueSink, event: agent.AgentEvent) !void {
        switch (event) {
            .message_start => {},
            .message_delta => |delta| {
                if (delta.thinking_delta) |text| try self.queue.push(.thinking, text, true);
                if (delta.text_delta) |text| try self.queue.push(.assistant, text, true);
            },
            .message_end => try self.queue.push(.assistant, "", false),
            .tool_execution_start => |tool_event| try pushToolStart(self.queue, self.queue.allocator, tool_event.name, tool_event.arguments_json),
            .tool_execution_delta => |delta| try self.queue.push(.tool, delta.message, false),
            .tool_execution_end => |tool_event| {
                try self.queue.push(.tool, "", false);
                if (tool_event.is_error) try pushToolError(self.queue, self.queue.allocator, tool_event.content_json);
            },
            .error_event => |err| try self.queue.push(.error_item, err.message, false),
            .abort => try self.queue.push(.status, "aborted", false),
            else => {},
        }
    }
};

pub fn toolStartText(allocator: std.mem.Allocator, name: []const u8, arguments_json: []const u8) ![]const u8 {
    const detail = try toolDetail(allocator, name, arguments_json);
    defer allocator.free(detail);
    if (detail.len == 0) return try allocator.dupe(u8, name);
    return try std.fmt.allocPrint(allocator, "{s} {s}", .{ name, detail });
}

fn toolDetail(allocator: std.mem.Allocator, name: []const u8, arguments_json: []const u8) ![]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, arguments_json, .{}) catch return try allocator.dupe(u8, "");
    defer parsed.deinit();
    if (parsed.value != .object) return try allocator.dupe(u8, "");
    const object = parsed.value.object;
    if (std.mem.eql(u8, name, "bash")) return try allocator.dupe(u8, jsonString(object.get("command")) orelse "");
    if (std.mem.eql(u8, name, "grep")) {
        const pattern = jsonString(object.get("pattern")) orelse "";
        const path = jsonString(object.get("path")) orelse ".";
        if (pattern.len == 0) return try allocator.dupe(u8, path);
        return try std.fmt.allocPrint(allocator, "{s} in {s}", .{ pattern, path });
    }
    if (std.mem.eql(u8, name, "find")) {
        const pattern = jsonString(object.get("pattern")) orelse "";
        const path = jsonString(object.get("path")) orelse ".";
        if (pattern.len == 0) return try allocator.dupe(u8, path);
        return try std.fmt.allocPrint(allocator, "{s} in {s}", .{ pattern, path });
    }
    return try allocator.dupe(u8, jsonString(object.get("path")) orelse "");
}

pub fn toolErrorText(allocator: std.mem.Allocator, content_json: []const u8) ![]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content_json, .{}) catch return try allocator.dupe(u8, "error");
    defer parsed.deinit();
    if (parsed.value != .object) return try allocator.dupe(u8, "error");
    const object = parsed.value.object;
    if (object.get("error")) |error_value| {
        if (error_value == .object) {
            if (jsonString(error_value.object.get("message"))) |message| return try allocator.dupe(u8, message);
            if (jsonString(error_value.object.get("code"))) |code| return try allocator.dupe(u8, code);
        }
        if (error_value == .string) return try allocator.dupe(u8, error_value.string);
    }
    return try allocator.dupe(u8, "error");
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    if (value) |v| if (v == .string) return v.string;
    return null;
}

fn pushToolStart(queue: *SharedInteractiveEventQueue, allocator: std.mem.Allocator, name: []const u8, arguments_json: []const u8) !void {
    const text = try toolStartText(allocator, name, arguments_json);
    defer allocator.free(text);
    try queue.push(.tool, text, false);
}

fn pushToolError(queue: *SharedInteractiveEventQueue, allocator: std.mem.Allocator, content_json: []const u8) !void {
    const reason = try toolErrorText(allocator, content_json);
    defer allocator.free(reason);
    const text = try std.fmt.allocPrint(allocator, "error {s}", .{reason});
    defer allocator.free(text);
    try queue.push(.tool, text, false);
}

fn handleReload(context: Context, app: *InteractiveApp) !void {
    const hook = context.reload_hook orelse {
        try app.appendItem(.status, "resources reload unavailable", false);
        return;
    };
    var result = hook.reload(context.allocator) catch {
        try app.appendItem(.error_item, "resources reload failed", false);
        return;
    };
    defer result.deinit(context.allocator);
    if (result.system_prompt) |prompt| try app.setSystemPrompt(prompt);
    try app.appendItem(.status, result.status, false);
}

fn handleCommand(context: Context, app: *InteractiveApp, prompt: []const u8, active_turn: ?*?*ActiveTurn) !InputStatus {
    var parsed = commands.parse(context.allocator, prompt) catch |err| {
        try app.appendItem(.error_item, commands.formatParseError(err), false);
        return .continue_loop;
    };
    defer parsed.deinit();

    const spec = commands.lookup(parsed.name) orelse {
        const message = try commands.formatUnknownCommand(context.allocator, parsed.name);
        defer context.allocator.free(message);
        try app.appendItem(.error_item, message, false);
        return .continue_loop;
    };

    if (active_turn) |turn_slot| {
        if (turn_slot.* != null and !spec.available_when_busy) {
            try app.appendItem(.status, "command unavailable while turn is running", false);
            return .continue_loop;
        }
    }

    switch (spec.kind) {
        .reload => try handleReload(context, app),
        .model => {
            if (parsed.argv.len > 0) {
                try handleModelSwitch(context, app, parsed.argv[0]);
            } else {
                if (app.model_status.items.len > 0) {
                    try app.appendItem(.status, app.model_status.items, false);
                } else {
                    try app.appendItem(.status, "model info unavailable", false);
                }
                if (app.scoped_models_status.items.len > 0) {
                    try app.appendItem(.status, app.scoped_models_status.items, false);
                }
            }
        },
        .scoped_models => {
            if (app.scoped_models_status.items.len > 0) {
                try app.appendItem(.status, app.scoped_models_status.items, false);
            } else {
                try app.appendItem(.status, "scoped model info unavailable", false);
            }
        },
        .hotkeys => {
            const text = try commands.formatHotkeys(context.allocator);
            defer context.allocator.free(text);
            try app.appendItem(.status, text, false);
        },
        .quit, .exit => {
            if (active_turn) |turn_slot| {
                if (turn_slot.*) |turn| {
                    turn.requestAbort();
                    try app.appendItem(.status, "abort requested", false);
                    return .continue_loop;
                }
            }
            return .exit_ok;
        },
        .changelog => try app.appendItem(.status, "Pig v1.0 M8: slash commands, workflow features, session tree navigation, and compaction foundation", false),
        .login => try app.appendItem(.status, "login setup: set a provider API key environment variable, then restart Pig and use /model. DeepSeek: DEEPSEEK_API_KEY or PIG_DEEPSEEK_API_KEY. OpenAI-compatible: PIG_OPENAI_COMPAT_API_KEY.", false),
        else => {
            const message = try std.fmt.allocPrint(context.allocator, "command not implemented yet: /{s}", .{spec.name});
            defer context.allocator.free(message);
            try app.appendItem(.status, message, false);
        },
    }
    return .continue_loop;
}

fn handleModelSwitch(context: Context, app: *InteractiveApp, model_id: []const u8) !void {
    const hook = context.model_switch_hook orelse {
        try app.appendItem(.status, "model switching unavailable", false);
        return;
    };
    var result = hook.select(context.allocator, model_id) catch |err| {
        const message = try std.fmt.allocPrint(context.allocator, "model switch failed: {s}", .{@errorName(err)});
        defer context.allocator.free(message);
        try app.appendItem(.error_item, message, false);
        return;
    };
    defer result.deinit(context.allocator);

    if (result.model_client) |client| {
        app.model_client = client;
    } else if (result.clear_model_client) {
        app.model_client = null;
    }
    try app.setModelInfo(result.model_status, result.scoped_models_status);
    try app.appendItem(.status, result.status, false);
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
        .tools = context.tool_registry,
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
    const bytes = try tui.render.renderDocument(app.allocator, &frame);
    defer app.allocator.free(bytes);
    try output.writeAll(bytes);
}

fn renderLiveApp(renderer: *tui.render.TerminalRenderer, app: *InteractiveApp, output: *std.Io.Writer) !void {
    var frame = try app.renderFrame();
    defer frame.deinit();
    try renderer.render(&frame, output);
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
            .message_start => {},
            .message_delta => |delta| {
                if (delta.thinking_delta) |text| try self.app.appendToLastThinking(text);
                if (delta.text_delta) |text| try self.app.appendToLastAssistant(text);
            },
            .message_end => self.app.markStreamingTextDone(),
            .tool_execution_start => |tool| {
                const text = try toolStartText(self.app.allocator, tool.name, tool.arguments_json);
                defer self.app.allocator.free(text);
                try self.app.appendItem(.tool, text, false);
            },
            .tool_execution_delta => |delta| try self.app.appendItem(.tool, delta.message, false),
            .tool_execution_end => |tool| {
                self.app.markLastStreamingToolDone();
                if (tool.is_error) {
                    const reason = try toolErrorText(self.app.allocator, tool.content_json);
                    defer self.app.allocator.free(reason);
                    const text = try std.fmt.allocPrint(self.app.allocator, "error {s}", .{reason});
                    defer self.app.allocator.free(text);
                    try self.app.appendItem(.tool, text, false);
                }
            },
            .error_event => |err| try self.app.appendItem(.error_item, err.message, false),
            .abort => try self.app.appendItem(.status, "aborted", false),
            else => {},
        }
    }
};
