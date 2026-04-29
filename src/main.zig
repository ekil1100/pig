const std = @import("std");
const pig = @import("pig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    const all_args = try init.minimal.args.toSlice(init.arena.allocator());
    const args = if (all_args.len > 0) all_args[1..] else all_args;

    const code = try pig.app.cli.runWithContext(args, .{
        .allocator = allocator,
        .io = io,
        .env_home = init.environ_map.get("HOME"),
        .env_tmpdir = init.environ_map.get("TMPDIR"),
    }, stdout, stderr);

    try stdout.flush();
    try stderr.flush();
    std.process.exit(@intFromEnum(code));
}
