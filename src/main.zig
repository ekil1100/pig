const std = @import("std");
const pig = @import("pig");

const ProcessEnv = struct {
    map: *std.process.Environ.Map,

    fn reader(self: *ProcessEnv) pig.provider.auth.EnvReader {
        return .{ .ptr = self, .get_fn = get };
    }

    fn get(ptr: *anyopaque, key: []const u8) ?[]const u8 {
        const self: *ProcessEnv = @ptrCast(@alignCast(ptr));
        return self.map.get(key);
    }
};

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
    var env = ProcessEnv{ .map = init.environ_map };

    const code = try pig.app.cli.runWithContext(args, .{
        .allocator = allocator,
        .io = io,
        .env_home = init.environ_map.get("HOME"),
        .env_tmpdir = init.environ_map.get("TMPDIR"),
        .env = env.reader(),
    }, stdout, stderr);

    try stdout.flush();
    try stderr.flush();
    std.process.exit(@intFromEnum(code));
}
