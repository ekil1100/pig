const std = @import("std");
const layout = @import("layout.zig");

pub const Position = struct { row: u16, col: u16 };

pub const Frame = struct {
    allocator: std.mem.Allocator,
    size: layout.Size,
    lines: std.ArrayList([]const u8) = .empty,
    cursor: ?Position = null,

    pub fn init(allocator: std.mem.Allocator, size: layout.Size) Frame {
        return .{ .allocator = allocator, .size = size };
    }

    pub fn deinit(self: *Frame) void {
        for (self.lines.items) |line| self.allocator.free(line);
        self.lines.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn appendLine(self: *Frame, text: []const u8) !void {
        if (self.lines.items.len >= self.size.height) return;
        const wrapped = try layout.wrapText(self.allocator, text, self.size.width);
        defer layout.freeLines(self.allocator, wrapped);
        for (wrapped) |line| {
            if (self.lines.items.len >= self.size.height) break;
            try self.lines.append(self.allocator, try self.allocator.dupe(u8, line));
        }
    }
};

pub fn renderFull(allocator: std.mem.Allocator, frame: *const Frame) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll("\x1b[2J\x1b[H");
    for (frame.lines.items, 0..) |line, index| {
        if (index > 0) try out.writer.writeAll("\r\n");
        try out.writer.writeAll(line);
    }
    if (frame.cursor) |cursor| try out.writer.print("\x1b[{d};{d}H", .{ cursor.row + 1, cursor.col + 1 });
    return try out.toOwnedSlice();
}

pub fn renderDiff(allocator: std.mem.Allocator, previous: *const Frame, next: *const Frame) ![]const u8 {
    if (previous.size.width != next.size.width or previous.size.height != next.size.height) return renderFull(allocator, next);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const max_lines = @max(previous.lines.items.len, next.lines.items.len);
    var row: usize = 0;
    while (row < max_lines) : (row += 1) {
        const next_line = if (row < next.lines.items.len) next.lines.items[row] else "";
        const changed = row >= previous.lines.items.len or row >= next.lines.items.len or !std.mem.eql(u8, previous.lines.items[row], next_line);
        if (changed) try out.writer.print("\x1b[{d};1H\x1b[2K{s}", .{ row + 1, next_line });
    }
    if (next.cursor) |cursor| try out.writer.print("\x1b[{d};{d}H", .{ cursor.row + 1, cursor.col + 1 });
    return try out.toOwnedSlice();
}
