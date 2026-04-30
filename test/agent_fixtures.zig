const std = @import("std");

fn validateFixture(path: []const u8) !void {
    const data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    var rows: usize = 0;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        rows += 1;
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, trimmed, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .object);
        const kind = parsed.value.object.get("kind") orelse return error.MissingKind;
        try std.testing.expect(kind == .string);
        if (std.mem.eql(u8, kind.string, "provider_event")) {
            const event = parsed.value.object.get("event") orelse return error.MissingEvent;
            try std.testing.expect(event == .string);
        }
    }
    try std.testing.expect(rows > 0);
}

test "agent fixtures are valid JSONL shape" {
    try validateFixture("fixtures/agent/no-tool-turn.jsonl");
    try validateFixture("fixtures/agent/tool-call-turn.jsonl");
}
