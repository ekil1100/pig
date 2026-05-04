const std = @import("std");
const agent = @import("../core/agent/mod.zig");
const parsed_args = @import("args.zig");
const build_info = @import("build_info.zig");
const app_interactive = @import("interactive.zig");
const app_runtime = @import("runtime.zig");
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
                .model_client = context.model_client,
            }, stdout, stderr),
            .interactive => try runInteractive(config, context, stdout, stderr),
            .rpc => try app_runtime.unsupportedMode(config, stdout, stderr),
        }),
    }
}

fn writeHelp(writer: anytype) !void {
    try writer.writeAll(
        \\Pig v1.0 M6
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
        \\M6 wires product-mode dispatch, print/json, and interactive TUI foundation.
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
    if (context.model_client == null) {
        try stderr.writeAll("model client unavailable\n");
        return .failure;
    }
    const input = context.interactive_input orelse {
        try stderr.writeAll("interactive terminal input is not wired in this M6 build\n");
        return .failure;
    };
    const status = try app_interactive.runScript(config, .{
        .allocator = context.allocator,
        .model_client = context.model_client,
        .size = context.terminal_size,
    }, input, stdout);
    return switch (status) {
        .ok => .ok,
        .failure => .failure,
        .internal => .internal,
    };
}

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

    try writer.writeAll("Pig doctor (M6)\n");
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
