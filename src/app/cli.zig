const std = @import("std");
const agent = @import("../core/agent/mod.zig");
const parsed_args = @import("args.zig");
const build_info = @import("build_info.zig");
const config_runtime = @import("config_runtime.zig");
const app_interactive = @import("interactive.zig");
const model_factory = @import("model_factory.zig");
const app_runtime = @import("runtime.zig");
const provider = @import("../provider/mod.zig");
const paths = @import("../util/paths.zig");
const tui = @import("../tui/mod.zig");

pub const ExitCode = enum(u8) {
    ok = 0,
    failure = 1,
    usage = 2,
    internal = 70,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: ?std.Io = null,
    env_home: ?[]const u8 = null,
    env_tmpdir: ?[]const u8 = null,
    env: ?provider.auth.EnvReader = null,
    model_client: ?agent.ModelClient = null,
    interactive_input: ?[]const u8 = null,
    terminal_size: tui.layout.Size = .{ .width = 80, .height = 24 },
};

pub fn run(args: []const []const u8, stdout: anytype, stderr: anytype) !ExitCode {
    return try runWithContext(args, .{ .allocator = std.heap.page_allocator }, stdout, stderr);
}

pub fn runWithContext(args: []const []const u8, context: Context, stdout: anytype, stderr: anytype) !ExitCode {
    const command = parsed_args.parse(args) catch |err| {
        try writeParseError(stderr, err);
        try writeHelp(stderr);
        return .usage;
    };

    switch (command) {
        .help => {
            try writeHelp(stdout);
            return .ok;
        },
        .version => {
            try build_info.write(stdout);
            return .ok;
        },
        .paths => {
            try writePaths(context, stdout);
            return .ok;
        },
        .doctor => {
            try writeDoctor(context, stdout);
            return .ok;
        },
        .run => |config| return mapRunStatus(switch (config.mode) {
            .print => try app_runtime.runPrint(config, .{
                .allocator = context.allocator,
                .io = context.io,
                .env_home = context.env_home,
                .env = context.env,
                .model_client = context.model_client,
            }, stdout, stderr),
            .interactive => try runInteractive(config, context, stdout, stderr),
            .rpc => try app_runtime.unsupportedMode(config, stdout, stderr),
        }),
    }
}

fn writeHelp(writer: anytype) !void {
    try writer.writeAll(
        \\Pig v1.0 M7
        \\
        \\Usage:
        \\  pig --version
        \\  pig --help
        \\  pig doctor
        \\  pig paths
        \\  pig --print "prompt"
        \\  pig --json --print "prompt"
        \\  pig --interactive
        \\  pig --rpc
        \\
        \\Options:
        \\  --cwd PATH              Set workspace root for tool execution
        \\  --provider NAME         Select provider label
        \\  --model NAME            Select model label
        \\  --thinking LEVEL        off, low, medium, high, xhigh, max
        \\  --no-tools              Disable builtin tools
        \\  --include-p1-tools      Include grep/find/ls in addition to P0 tools
        \\  --ephemeral             Do not attach the run to a saved session
        \\
        \\M7 adds config/auth/models/resources loading on top of terminal UI foundation.
        \\RPC serving remains exposed as a mode skeleton.
        \\
    );
}

fn writeParseError(writer: anytype, err: parsed_args.ParseError) !void {
    const message = switch (err) {
        error.MissingValue => "missing value for option",
        error.UnknownArgument => "unknown argument",
        error.UnexpectedArgument => "unexpected positional argument",
        error.DuplicateMode => "only one mode may be selected",
        error.InvalidCombination => "invalid option combination",
        error.InvalidValue => "invalid option value",
    };
    try writer.print("{s}\n", .{message});
}

fn mapRunStatus(status: app_runtime.RunStatus) ExitCode {
    return switch (status) {
        .ok => .ok,
        .failure => .failure,
        .usage => .usage,
        .internal => .internal,
    };
}

fn runInteractive(config: parsed_args.RunConfig, context: Context, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !app_runtime.RunStatus {
    if (config.output == .json) return .usage;
    if (context.model_client == null and context.io == null) {
        try stderr.writeAll("model client unavailable\n");
        return .failure;
    }
    const input = context.interactive_input orelse {
        try stderr.writeAll("interactive terminal input is not wired in this M7 build\n");
        return .failure;
    };

    var resolved: ?config_runtime.ResolvedRuntimeConfig = null;
    defer if (resolved) |*runtime_config| runtime_config.deinit(context.allocator);
    if (context.io) |io| {
        resolved = config_runtime.resolve(.{
            .allocator = context.allocator,
            .io = io,
            .env_home = context.env_home,
            .config = config,
        }) catch |err| {
            try stderr.print("{s}\n", .{@errorName(err)});
            return .failure;
        };
    }

    var owned_model: ?model_factory.OwnedModelClient = null;
    defer if (owned_model) |*client| client.deinit();
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
            try stderr.print("{s}\n", .{@errorName(err)});
            return .failure;
        };
        break :blk owned_model.?.client();
    } else {
        try stderr.writeAll("model client unavailable\n");
        return .failure;
    };

    var reload_context = ReloadContext{ .cli_context = context, .config = config };
    const reload_hook = app_interactive.ReloadHook{ .ptr = &reload_context, .reload_fn = ReloadContext.reload };
    const effective_config = if (resolved) |runtime_config| runtime_config.effective_run_config else config;
    const status = try app_interactive.runScript(effective_config, .{
        .allocator = context.allocator,
        .model_client = model,
        .system_prompt = if (resolved) |runtime_config| runtime_config.systemPrompt() else null,
        .reload_hook = if (context.io != null) reload_hook else null,
        .size = context.terminal_size,
    }, input, stdout);
    return switch (status) {
        .ok => .ok,
        .failure => .failure,
        .internal => .internal,
    };
}

const ReloadContext = struct {
    cli_context: Context,
    config: parsed_args.RunConfig,

    fn reload(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!app_interactive.ReloadResult {
        const self: *ReloadContext = @ptrCast(@alignCast(ptr));
        const io = self.cli_context.io orelse return error.MissingIo;
        var resolved = try config_runtime.resolve(.{
            .allocator = allocator,
            .io = io,
            .env_home = self.cli_context.env_home,
            .config = self.config,
        });
        defer resolved.deinit(allocator);
        const status = try std.fmt.allocPrint(allocator, "resources reloaded: {d} context files, {d} models, {d} warnings", .{
            resolved.snapshot.context.files.items.len,
            resolved.snapshot.models.entries.items.len,
            resolved.snapshot.warnings.items.len,
        });
        errdefer allocator.free(status);
        const prompt = if (resolved.systemPrompt()) |system_prompt| try allocator.dupe(u8, system_prompt) else null;
        return .{ .status = status, .system_prompt = prompt };
    }
};

fn resolveRuntimePaths(context: Context) !paths.PathSet {
    const cwd_path = if (context.io) |io|
        try paths.cwd(context.allocator, io)
    else
        try context.allocator.dupe(u8, ".");
    defer context.allocator.free(cwd_path);

    const home_path = try paths.homeDir(context.allocator, context.env_home);
    defer context.allocator.free(home_path);

    return try paths.resolveDefaultPathsFrom(context.allocator, cwd_path, home_path);
}

fn writePaths(context: Context, writer: anytype) !void {
    const set = try resolveRuntimePaths(context);
    defer set.deinit(context.allocator);

    try writer.print("cwd: {s}\n", .{set.cwd});
    try writer.print("home: {s}\n", .{set.home});
    try writer.print("global_config: {s}\n", .{set.global_config});
    try writer.print("global_auth: {s}\n", .{set.global_auth});
    try writer.print("global_models: {s}\n", .{set.global_models});
    try writer.print("global_sessions: {s}\n", .{set.global_sessions});
    try writer.print("project_config: {s}\n", .{set.project_config});
    try writer.print("project_resources: {s}\n", .{set.project_resources});
}

fn writeDoctor(context: Context, writer: anytype) !void {
    const set = try resolveRuntimePaths(context);
    defer set.deinit(context.allocator);

    try writer.writeAll("Pig doctor (M7)\n");
    try writer.print("cwd: ok {s}\n", .{set.cwd});
    if (context.env_home) |home| {
        try writer.print("home: ok {s}\n", .{home});
    } else {
        try writer.writeAll("home: missing\n");
    }
    try writer.print("global_config: candidate {s}\n", .{set.global_config});
    try writer.print("project_config: candidate {s}\n", .{set.project_config});
    try writer.print("sessions: candidate {s}\n", .{set.global_sessions});

    const fixture_status = if (context.io) |io| fixtureStatus(io) else "unknown";
    try writer.print("fixtures: {s}\n", .{fixture_status});

    const temp_status = if (context.io) |io| tempDirStatus(io, context.env_tmpdir) else "unknown";
    try writer.print("temp_dir: {s}\n", .{temp_status});

    if (context.io) |io| {
        const config = parsed_args.RunConfig{ .mode = .print, .prompt = "" };
        var resolved = config_runtime.resolve(.{
            .allocator = context.allocator,
            .io = io,
            .env_home = context.env_home,
            .config = config,
        }) catch |err| {
            try writer.print("resources: error {s}\n", .{@errorName(err)});
            return;
        };
        defer resolved.deinit(context.allocator);
        try writer.print("models: ok {d} enabled\n", .{resolved.snapshot.models.entries.items.len});
        try writer.print("context: ok {d} files {d} bytes\n", .{ resolved.snapshot.context.files.items.len, resolved.snapshot.context.total_bytes });
        try writer.print("resources: warnings {d}\n", .{resolved.snapshot.warnings.items.len});
    }
}

fn fixtureStatus(io: std.Io) []const u8 {
    std.Io.Dir.cwd().access(io, "fixtures", .{}) catch return "missing";
    return "ok";
}

fn tempDirStatus(io: std.Io, env_tmpdir: ?[]const u8) []const u8 {
    const temp_root = env_tmpdir orelse "/tmp";
    if (!std.fs.path.isAbsolute(temp_root)) return "unavailable";

    var root_dir = std.Io.Dir.openDirAbsolute(io, temp_root, .{}) catch return "unavailable";
    defer root_dir.close(io);

    const probe_name = "pig-doctor-m0-probe";
    root_dir.createDir(io, probe_name, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => return "ok",
        else => return "unavailable",
    };
    root_dir.deleteDir(io, probe_name) catch return "created";
    return "ok";
}
