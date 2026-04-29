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
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    var env = ProcessEnv{ .map = init.environ_map };
    const decision = pig.provider.live.decide(env.reader());
    if (decision.kind == .skip) {
        try stdout.writeAll("provider-live: skipped");
        if (decision.missing_count > 0) {
            try stdout.writeAll(" missing:");
            var i: usize = 0;
            while (i < decision.missing_count) : (i += 1) {
                if (decision.missingName(i)) |name| try stdout.print(" {s}", .{name});
            }
        }
        try stdout.writeAll("\n");
        try stdout.flush();
        return;
    }

    try stderr.writeAll("provider-live: live transport unsupported on this platform/build\n");
    try stderr.flush();
    std.process.exit(1);
}
