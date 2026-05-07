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

    const allocator = init.gpa;
    const blocks = [_]pig.provider.ContentBlockView{.{ .text = .{ .text = "Reply with exactly: pig-live-ok" } }};
    const messages = [_]pig.provider.MessageView{.{ .role = .user, .content = &blocks }};
    var request = try pig.provider.openai_compatible.buildChatCompletionsRequest(allocator, .{
        .base_url = env.reader().get("PIG_OPENAI_COMPAT_BASE_URL").?,
        .api_key = env.reader().get("PIG_OPENAI_COMPAT_API_KEY").?,
        .model = env.reader().get("PIG_OPENAI_COMPAT_MODEL").?,
    }, .{ .messages = &messages });
    defer request.deinit(allocator);

    var http_transport = pig.provider.transport.HttpTransport{ .allocator = allocator, .io = io };
    var transport = http_transport.transport();
    const stream = transport.sendStreaming(request) catch |err| {
        try stderr.print("provider-live: request failed: {s}\n", .{@errorName(err)});
        try stderr.flush();
        std.process.exit(1);
    };
    var sink_state = SmokeSink{};
    pig.provider.openai_compatible.parseStream(allocator, stream, sink_state.sink()) catch |err| {
        try stderr.print("provider-live: stream parse failed: {s}\n", .{@errorName(err)});
        try stderr.flush();
        std.process.exit(1);
    };
    if (!sink_state.done or sink_state.error_count > 0) {
        try stderr.writeAll("provider-live: stream ended without a clean done event\n");
        try stderr.flush();
        std.process.exit(1);
    }
    try stdout.print("provider-live: ok text_chunks={d}\n", .{sink_state.text_count});
}

const SmokeSink = struct {
    text_count: usize = 0,
    error_count: usize = 0,
    done: bool = false,

    fn sink(self: *SmokeSink) pig.provider.EventSink {
        return .{ .ptr = self, .on_event = onEvent };
    }

    fn onEvent(ptr: *anyopaque, event: pig.provider.ProviderEvent) pig.provider.EventSinkError!void {
        const self: *SmokeSink = @ptrCast(@alignCast(ptr));
        switch (event) {
            .text_delta => self.text_count += 1,
            .error_event => self.error_count += 1,
            .done => self.done = true,
            else => {},
        }
    }
};
