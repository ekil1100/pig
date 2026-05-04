const std = @import("std");
const args = @import("args.zig");
const agent = @import("../core/agent/mod.zig");
const tools = @import("../tools/mod.zig");
const app_json = @import("output_json.zig");
const app_text = @import("output_text.zig");
const app_session = @import("session_runtime.zig");
const config_runtime = @import("config_runtime.zig");
const model_factory = @import("model_factory.zig");
const paths = @import("../util/paths.zig");
const provider = @import("../provider/mod.zig");
const session = @import("../session/mod.zig");
const version = @import("../version.zig");

pub const RunStatus = enum { ok, failure, usage, internal };

pub const RuntimeContext = struct {
    allocator: std.mem.Allocator,
    io: ?std.Io = null,
    env_home: ?[]const u8 = null,
    env: ?provider.auth.EnvReader = null,
    model_client: ?agent.ModelClient = null,
};

pub fn runPrint(config: args.RunConfig, context: RuntimeContext, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !RunStatus {
    const prompt = config.prompt orelse return .usage;
    if (config.session_mode == .resume_session) {
        if (config.output == .json) {
            app_json.writeError(stdout, "session", "session resume is not implemented in M7 print mode") catch return .internal;
        } else {
            try stderr.writeAll("session resume is not implemented in M7 print mode\n");
        }
        return .failure;
    }

    var resolved: ?config_runtime.ResolvedRuntimeConfig = null;
    defer if (resolved) |*runtime_config| runtime_config.deinit(context.allocator);
    if (context.io) |io| {
        resolved = config_runtime.resolve(.{
            .allocator = context.allocator,
            .io = io,
            .env_home = context.env_home,
            .config = config,
        }) catch |err| {
            try writeConfigError(config.output, stdout, stderr, err);
            return .failure;
        };
    }

    var owned_model: ?model_factory.OwnedModelClient = null;
    defer if (owned_model) |*model_client| model_client.deinit();
    const model = if (context.model_client) |injected|
        injected
    else if (resolved) |runtime_config| blk: {
        const io = context.io orelse return .internal;
        owned_model = model_factory.create(.{
            .allocator = context.allocator,
            .io = io,
            .auth_json_path = runtime_config.paths.global_auth,
            .env = context.env,
            .model = runtime_config.model,
        }) catch |err| {
            try writeModelFactoryError(config.output, stdout, stderr, err, runtime_config.model.provider_id);
            return .failure;
        };
        break :blk owned_model.?.client();
    } else {
        try writeModelUnavailable(config.output, stdout, stderr);
        return .failure;
    };

    const effective_config = if (resolved) |runtime_config| runtime_config.effective_run_config else config;
    const system_prompt = if (resolved) |runtime_config| runtime_config.systemPrompt() else null;
    switch (config.output) {
        .text => {
            var sink = app_text.TextEventSink{ .stdout = stdout, .stderr = stderr };
            return runWithSink(effective_config, context, model, prompt, sink.sink(), null, system_prompt);
        },
        .json => {
            var sink = app_json.JsonEventSink{ .writer = stdout };
            return runWithSink(effective_config, context, model, prompt, sink.sink(), &sink.session_id, system_prompt);
        },
    }
}

pub fn unsupportedMode(config: args.RunConfig, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !RunStatus {
    const message = switch (config.mode) {
        .interactive => "interactive mode is not implemented in M7 yet",
        .rpc => "rpc mode is not implemented in M7 yet",
        .print => unreachable,
    };
    _ = stdout;
    try stderr.print("{s}\n", .{message});
    return .failure;
}

fn runWithSink(config: args.RunConfig, context: RuntimeContext, model: agent.ModelClient, prompt: []const u8, sink: agent.AgentEventSink, session_id_target: ?*[]const u8, system_prompt: ?[]const u8) !RunStatus {
    var state = agent.AgentState.init(context.allocator, .{
        .system_prompt = system_prompt,
        .thinking_level = config.thinking_level,
        .max_iterations = config.max_iterations,
    });
    defer state.deinit();

    var tool_registry = agent.ToolRegistry{};
    var builtin_set: ?tools.registry.BuiltinToolSet = null;
    var workspace_root: ?[]const u8 = null;
    var spill_dir: ?[]const u8 = null;
    var deny_approval = tools.approval.DenyAllApproval{};
    var tool_context: tools.ToolContext = undefined;
    var store: ?session.store.SessionStore = null;

    if (config.tools_enabled or shouldPersistSession(config, context)) {
        workspace_root = try resolveWorkspaceRoot(context.allocator, context.io, config.cwd);
        errdefer if (workspace_root) |path| context.allocator.free(path);
    }

    if (config.tools_enabled) {
        const io = context.io orelse return .internal;
        spill_dir = try std.fs.path.join(context.allocator, &.{ workspace_root.?, ".pig-spill" });
        errdefer if (spill_dir) |path| context.allocator.free(path);
        tool_context = .{
            .allocator = context.allocator,
            .io = io,
            .workspace_root = workspace_root.?,
            .spill_dir = spill_dir.?,
            .approval = deny_approval.policy(),
        };
        builtin_set = try tools.registry.initBuiltinToolSet(context.allocator, &tool_context, .{ .include_p1 = config.include_p1_tools });
        tool_registry = .{ .registrations = builtin_set.?.registrations };
    }
    defer {
        if (store) |*session_store| session_store.deinit();
        if (builtin_set) |*set| set.deinit(context.allocator);
        if (spill_dir) |path| context.allocator.free(path);
        if (workspace_root) |path| context.allocator.free(path);
    }

    if (shouldPersistSession(config, context)) {
        store = openSession(config, context, workspace_root.?) catch |err| {
            const message = switch (err) {
                error.OutOfMemory => return .internal,
                else => "failed to open session",
            };
            sink.emit(.{ .error_event = .{ .category = .internal, .message = message } }) catch return .failure;
            return .failure;
        };
        if (session_id_target) |target| {
            if (store) |*session_store| target.* = session_store.entries.items[0].session_id;
        }
    }

    var recorder: app_session.SessionRecorderSink = undefined;
    var fanout: app_session.AgentEventFanout = undefined;
    var fanout_sinks: [2]agent.AgentEventSink = undefined;
    const event_sink = if (store) |*session_store| blk: {
        recorder = .{
            .state = &state,
            .store = session_store,
            .session_id = session_store.entries.items[0].session_id,
            .next_index = app_session.nextEntryIndex(session_store.entries.items),
        };
        fanout_sinks = .{ sink, recorder.sink() };
        fanout = .{ .sinks = &fanout_sinks };
        break :blk fanout.sink();
    } else sink;

    var runtime = agent.AgentRuntime{
        .allocator = context.allocator,
        .state = &state,
        .model = model,
        .tools = tool_registry,
        .event_sink = event_sink,
    };

    runtime.runUserText(prompt) catch |err| return switch (err) {
        error.OutOfMemory => .internal,
        else => .failure,
    };
    return .ok;
}

fn writeModelUnavailable(output: args.OutputMode, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    if (output == .json) {
        app_json.writeModelUnavailable(stdout) catch return error.WriteFailed;
    } else {
        try stderr.writeAll("model client unavailable\n");
    }
}

fn writeConfigError(output: args.OutputMode, stdout: *std.Io.Writer, stderr: *std.Io.Writer, err: config_runtime.ConfigRuntimeError) !void {
    const message = switch (err) {
        error.InvalidSettingsJson => "invalid settings JSON",
        error.InvalidModelsJson => "invalid models JSON",
        error.UnknownModel => "unknown model",
        error.DisabledModel => "selected model is disabled",
        error.InvalidThinkingLevel => "invalid thinking level in settings",
        error.ResourceLoadFailed => "failed to load resources",
        error.OutOfMemory => "out of memory while loading config",
    };
    if (output == .json) {
        app_json.writeError(stdout, "config", message) catch return error.WriteFailed;
    } else {
        try stderr.print("{s}\n", .{message});
    }
}

fn writeModelFactoryError(output: args.OutputMode, stdout: *std.Io.Writer, stderr: *std.Io.Writer, err: model_factory.ModelFactoryError, provider_id: []const u8) !void {
    const message = switch (err) {
        error.UnknownProvider => "unknown provider",
        error.MissingApiKey => provider.auth.formatMissingKeyMessage(provider.ProviderKind.fromString(provider_id) catch .custom),
        error.InvalidAuthJson => "invalid auth JSON",
        error.OutOfMemory => "out of memory while creating model client",
    };
    if (output == .json) {
        app_json.writeError(stdout, "auth", message) catch return error.WriteFailed;
    } else {
        try stderr.print("{s}\n", .{message});
    }
}

fn resolveWorkspaceRoot(allocator: std.mem.Allocator, maybe_io: ?std.Io, cwd_arg: ?[]const u8) ![]const u8 {
    if (cwd_arg) |cwd| {
        if (std.fs.path.isAbsolute(cwd)) return try allocator.dupe(u8, cwd);
        const base = if (maybe_io) |io| try paths.cwd(allocator, io) else try allocator.dupe(u8, ".");
        defer allocator.free(base);
        return try std.fs.path.join(allocator, &.{ base, cwd });
    }
    if (maybe_io) |io| return try paths.cwd(allocator, io);
    return try allocator.dupe(u8, ".");
}

fn shouldPersistSession(config: args.RunConfig, context: RuntimeContext) bool {
    if (config.session_mode == .ephemeral) return false;
    if (config.session_mode == .explicit or config.session_mode == .new_session) return true;
    if (context.io == null) return false;
    return context.env_home != null;
}

fn openSession(config: args.RunConfig, context: RuntimeContext, cwd: []const u8) !session.store.SessionStore {
    const io = context.io orelse return error.MissingIo;
    switch (config.session_mode) {
        .explicit => {
            const ref = config.session_ref orelse return error.MissingSession;
            if (std.fs.path.isAbsolute(ref) or std.mem.indexOfScalar(u8, ref, '/') != null or std.mem.endsWith(u8, ref, ".jsonl")) {
                return try session.store.open(context.allocator, io, .{ .path = ref });
            }
            const sessions_dir = try resolveSessionsDir(context.allocator, context.env_home);
            defer context.allocator.free(sessions_dir);
            const filename = try std.fmt.allocPrint(context.allocator, "{s}.jsonl", .{ref});
            defer context.allocator.free(filename);
            const path = try std.fs.path.join(context.allocator, &.{ sessions_dir, filename });
            defer context.allocator.free(path);
            return try session.store.open(context.allocator, io, .{ .path = path });
        },
        .new_session, .default => {
            const sessions_dir = try resolveSessionsDir(context.allocator, context.env_home);
            defer context.allocator.free(sessions_dir);
            var entropy: [8]u8 = undefined;
            io.random(&entropy);
            const random_id = std.mem.readInt(u64, &entropy, .little);
            const session_id = try std.fmt.allocPrint(context.allocator, "session_{x}", .{random_id});
            defer context.allocator.free(session_id);
            return try session.store.create(context.allocator, io, .{
                .sessions_dir = sessions_dir,
                .session_id = session_id,
                .cwd = cwd,
                .created_ms = 0,
                .pig_version = version.version,
            });
        },
        .ephemeral => return error.EphemeralSession,
        .resume_session => return error.ResumeUnsupported,
    }
}

fn resolveSessionsDir(allocator: std.mem.Allocator, env_home: ?[]const u8) ![]const u8 {
    const home = try paths.homeDir(allocator, env_home);
    defer allocator.free(home);
    const cwd = try allocator.dupe(u8, ".");
    defer allocator.free(cwd);
    const set = try paths.resolveDefaultPathsFrom(allocator, cwd, home);
    defer set.deinit(allocator);
    return try allocator.dupe(u8, set.global_sessions);
}
