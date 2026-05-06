const std = @import("std");
const args = @import("args.zig");
const commands = @import("commands.zig");
const agent = @import("../core/agent/mod.zig");
const provider = @import("../provider/mod.zig");
const tui = @import("../tui/mod.zig");

pub const InteractiveStatus = enum { ok, failure, internal };

pub const Context = struct {
    allocator: std.mem.Allocator,
    model_client: ?agent.ModelClient = null,
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
        .system_prompt = context.system_prompt,
        .thinking_level = config.thinking_level,
        .max_iterations = config.max_iterations,
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
        .max_iterations = config.max_iterations,
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
        try output.writeAll("\x1b[?1049h\x1b[?25l");
        session.alternate_entered = true;
        session.cursor_hidden = true;
        try output.flush();
    }
    defer if (interactive_tty) {
        output.writeAll("\x1b[?25h\x1b[?1049l") catch {};
        output.flush() catch {};
    };

    try renderApp(&app, output);
    try output.flush();

    var active_turn: ?*ActiveTurn = null;
    defer if (active_turn) |turn| turn.finish(&app);

    var input_buffer: [128]u8 = undefined;
    while (true) {
        try pumpActiveTurn(&active_turn, &app, output);
        const poll_timeout: i32 = if (active_turn == null) -1 else 25;
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = std.posix.STDIN_FILENO,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = try std.posix.poll(&poll_fds, poll_timeout);
        if (ready == 0) continue;
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

        const events = try tui.input.decodeAll(context.allocator, bytes);
        defer context.allocator.free(events);
        for (events) |event| {
            const status = try handleLiveInputEvent(config, context, &app, &active_turn, event, output);
            try output.flush();
            switch (status) {
                .continue_loop => {},
                .exit_ok => return .ok,
                .failure => return .failure,
                .internal => return .internal,
            }
        }
    }
}

const InputStatus = enum { continue_loop, exit_ok, failure, internal };

fn handleLiveInputEvent(config: args.RunConfig, context: Context, app: *InteractiveApp, active_turn: *?*ActiveTurn, event: tui.input.KeyEvent, output: *std.Io.Writer) !InputStatus {
    const result = try app.handleInput(event);
    switch (result) {
        .none => try renderApp(app, output),
        .exit => {
            if (active_turn.*) |turn| {
                turn.requestAbort();
                try app.appendItem(.status, "abort requested", false);
                try renderApp(app, output);
                return .continue_loop;
            }
            return .exit_ok;
        },
        .abort => {
            if (active_turn.*) |turn| turn.requestAbort();
            app.worker.requestAbort();
            try app.appendItem(.status, "abort requested", false);
            try renderApp(app, output);
        },
        .submit => |prompt| {
            var prompt_owned = true;
            defer if (prompt_owned) app.editor.freeSubmitted(prompt);
            if (commands.isCommandInput(prompt)) {
                const command_status = try handleCommand(context, app, prompt, active_turn);
                try renderApp(app, output);
                return command_status;
            }
            if (active_turn.* != null) {
                try app.appendItem(.status, "turn already running", false);
                try renderApp(app, output);
                return .continue_loop;
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
            active_turn.* = try ActiveTurn.start(config, context, app, model, model_prompt.text);
            if (model_prompt.owned) {
                model_prompt.owned = false;
            } else {
                prompt_owned = false;
            }
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

fn pumpActiveTurn(active_turn: *?*ActiveTurn, app: *InteractiveApp, output: *std.Io.Writer) !void {
    const turn = active_turn.* orelse return;
    var changed = try drainQueuedEvents(turn, app);
    if (turn.done.load(.acquire)) {
        if (try drainQueuedEvents(turn, app)) changed = true;
        active_turn.* = null;
        turn.finish(app);
        changed = true;
    }
    if (changed) try renderApp(app, output);
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
                app.markAssistantDone();
            } else {
                try app.appendToLastAssistant(event.text.items);
            }
        },
        .tool => try app.appendItem(.tool, event.text.items, event.is_streaming),
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
            .message_start => |start| if (start.role == provider.Role.assistant) try self.queue.push(.assistant, "", true),
            .message_delta => |delta| if (delta.text_delta) |text| try self.queue.push(.assistant, text, true),
            .message_end => try self.queue.push(.assistant, "", false),
            .tool_execution_start => |tool_event| try self.queue.push(.tool, tool_event.name, true),
            .tool_execution_delta => |delta| try self.queue.push(.tool, delta.message, true),
            .tool_execution_end => |tool_event| {
                const text = if (tool_event.is_error) "failed" else "done";
                try self.queue.push(.tool, text, false);
            },
            .error_event => |err| try self.queue.push(.error_item, err.message, false),
            .abort => try self.queue.push(.status, "aborted", false),
            else => {},
        }
    }
};

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
            } else if (app.model_status.items.len > 0) {
                try app.appendItem(.status, app.model_status.items, false);
            } else {
                try app.appendItem(.status, "model info unavailable", false);
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
