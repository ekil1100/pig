const std = @import("std");
const build_info = @import("build_info.zig");
const paths = @import("../util/paths.zig");

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
};

pub fn run(args: []const []const u8, stdout: anytype, stderr: anytype) !ExitCode {
    return try runWithContext(args, .{ .allocator = std.heap.page_allocator }, stdout, stderr);
}

pub fn runWithContext(args: []const []const u8, context: Context, stdout: anytype, stderr: anytype) !ExitCode {
    if (args.len == 0) {
        try writeHelp(stdout);
        return .ok;
    }

    const command = args[0];
    if (args.len > 1) {
        try stderr.print("unexpected argument for {s}: {s}\n", .{ command, args[1] });
        try writeHelp(stderr);
        return .usage;
    }

    if (std.mem.eql(u8, command, "--version")) {
        try build_info.write(stdout);
        return .ok;
    }
    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "help")) {
        try writeHelp(stdout);
        return .ok;
    }
    if (std.mem.eql(u8, command, "paths")) {
        try writePaths(context, stdout);
        return .ok;
    }
    if (std.mem.eql(u8, command, "doctor")) {
        try writeDoctor(context, stdout);
        return .ok;
    }

    try stderr.print("unknown command: {s}\n", .{command});
    try writeHelp(stderr);
    return .usage;
}

fn writeHelp(writer: anytype) !void {
    try writer.writeAll(
        \\Pig v1.0 M0
        \\
        \\Usage:
        \\  pig --version
        \\  pig --help
        \\  pig doctor
        \\  pig paths
        \\
        \\The agent functionality is not implemented in M0. Provider, agent loop,
        \\tools, sessions, and TUI behavior start in later milestones.
        \\
    );
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

    try writer.writeAll("Pig doctor (M0)\n");
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
