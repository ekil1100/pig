const std = @import("std");

pub fn renderPlain(allocator: std.mem.Allocator, markdown: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var in_fence = false;
    var lines = std.mem.splitScalar(u8, markdown, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "```")) {
            in_fence = !in_fence;
            continue;
        }
        if (!first) try out.writer.writeByte('\n');
        first = false;
        const trimmed = if (!in_fence) std.mem.trimLeft(u8, line, "#> -*\t ") else line;
        try out.writer.writeAll(trimmed);
    }
    return try out.toOwnedSlice();
}
