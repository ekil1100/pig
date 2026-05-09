const std = @import("std");
const layout = @import("layout.zig");

pub const Position = struct { row: usize, col: usize };

pub const Frame = struct {
    allocator: std.mem.Allocator,
    size: layout.Size,
    lines: std.ArrayList([]const u8) = .empty,
    cursor: ?Position = null,
    viewport_top: ?usize = null,

    pub fn init(allocator: std.mem.Allocator, size: layout.Size) Frame {
        return .{ .allocator = allocator, .size = size };
    }

    pub fn deinit(self: *Frame) void {
        for (self.lines.items) |line| self.allocator.free(line);
        self.lines.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn appendLine(self: *Frame, text: []const u8) !void {
        const wrapped = try layout.wrapText(self.allocator, text, self.size.width);
        defer layout.freeLines(self.allocator, wrapped);
        for (wrapped) |line| {
            try self.lines.append(self.allocator, try self.allocator.dupe(u8, line));
        }
    }
};

pub fn renderFull(allocator: std.mem.Allocator, frame: *const Frame) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll("\x1b[2J\x1b[H");
    try appendVisibleLines(&out.writer, frame);
    try appendCursorMove(&out.writer, frame);
    return try out.toOwnedSlice();
}

pub fn renderDocument(allocator: std.mem.Allocator, frame: *const Frame) ![]const u8 {
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
    const previous_top = frameViewportTop(previous);
    const next_top = frameViewportTop(next);
    if (previous_top != next_top) return renderFull(allocator, next);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const max_lines = @max(previous.lines.items.len, next.lines.items.len);
    const height = @max(@as(usize, next.size.height), 1);
    const end = @min(next_top + height, max_lines);
    var row = next_top;
    while (row < end) : (row += 1) {
        const next_line = if (row < next.lines.items.len) next.lines.items[row] else "";
        const changed = row >= previous.lines.items.len or row >= next.lines.items.len or !std.mem.eql(u8, previous.lines.items[row], next_line);
        if (changed) try out.writer.print("\x1b[{d};1H\x1b[2K{s}", .{ row - next_top + 1, next_line });
    }
    if (next.cursor) |cursor| {
        if (visibleCursorRow(next, cursor)) |screen_row| try out.writer.print("\x1b[{d};{d}H", .{ screen_row + 1, cursor.col + 1 });
    }
    return try out.toOwnedSlice();
}

pub const TerminalRenderer = struct {
    allocator: std.mem.Allocator,
    previous_lines: std.ArrayList([]const u8) = .empty,
    previous_width: u16 = 0,
    previous_height: u16 = 0,
    previous_viewport_top: usize = 0,
    hardware_cursor_row: usize = 0,
    max_lines_rendered: usize = 0,

    pub fn init(allocator: std.mem.Allocator) TerminalRenderer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TerminalRenderer) void {
        self.freePreviousLines();
        self.previous_lines.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn render(self: *TerminalRenderer, frame: *const Frame, output: *std.Io.Writer) !void {
        const first_render = self.previous_width == 0 or self.previous_height == 0;
        const width_changed = !first_render and self.previous_width != frame.size.width;
        const height_changed = !first_render and self.previous_height != frame.size.height;
        const shrunk = frame.lines.items.len < self.max_lines_rendered;

        if (first_render) {
            try self.renderFullFrame(frame, output);
            return;
        }

        if (width_changed or height_changed or shrunk) {
            try self.renderFullFrame(frame, output);
            return;
        }

        const viewport_top = frameViewportTop(frame);
        const changed = findChangedRange(self.previous_lines.items, frame.lines.items);
        if (changed == null) {
            if (viewport_top != self.previous_viewport_top) {
                try self.renderFullFrame(frame, output);
                return;
            }
            try self.positionCursor(frame, output);
            try self.replacePreviousLines(frame);
            self.previous_viewport_top = viewport_top;
            return;
        }

        const range = changed.?;
        if (viewport_top < self.previous_viewport_top or range.first < self.previous_viewport_top) {
            try self.renderFullFrame(frame, output);
            return;
        }
        if (viewport_top != self.previous_viewport_top and frame.lines.items.len <= self.previous_lines.items.len) {
            try self.renderFullFrame(frame, output);
            return;
        }

        if (viewport_top == self.previous_viewport_top) {
            const height = @max(@as(usize, frame.size.height), 1);
            const visible_end = viewport_top + height;
            if (range.last < viewport_top or range.first >= visible_end) {
                try self.positionCursor(frame, output);
                try self.replacePreviousLines(frame);
                self.previous_width = frame.size.width;
                self.previous_height = frame.size.height;
                self.previous_viewport_top = viewport_top;
                self.max_lines_rendered = @max(self.max_lines_rendered, frame.lines.items.len);
                return;
            }

            try self.renderChangedRange(frame, .{
                .first = @max(range.first, viewport_top),
                .last = @min(range.last, visible_end - 1),
            }, output);
            return;
        }

        try self.renderChangedRange(frame, range, output);
    }

    pub fn finish(self: *TerminalRenderer, output: *std.Io.Writer) void {
        _ = self;
        output.writeAll("\r\n") catch {};
    }

    fn renderFullFrame(self: *TerminalRenderer, frame: *const Frame, output: *std.Io.Writer) !void {
        var buffer: std.Io.Writer.Allocating = .init(self.allocator);
        defer buffer.deinit();

        try buffer.writer.writeAll("\x1b[?2026h\x1b[2J\x1b[H");
        try appendVisibleLines(&buffer.writer, frame);
        try appendCursorMove(&buffer.writer, frame);
        try buffer.writer.writeAll("\x1b[?2026l");

        try output.writeAll(buffer.written());
        try self.replacePreviousLines(frame);
        self.previous_width = frame.size.width;
        self.previous_height = frame.size.height;
        self.previous_viewport_top = frameViewportTop(frame);
        self.hardware_cursor_row = if (frame.cursor) |cursor| cursor.row else if (frame.lines.items.len == 0) 0 else frame.lines.items.len - 1;
        self.max_lines_rendered = frame.lines.items.len;
    }

    fn renderChangedRange(self: *TerminalRenderer, frame: *const Frame, range: ChangedRange, output: *std.Io.Writer) !void {
        var buffer: std.Io.Writer.Allocating = .init(self.allocator);
        defer buffer.deinit();

        const height = @max(@as(usize, frame.size.height), 1);
        const previous_bottom = self.previous_viewport_top + height - 1;
        try buffer.writer.writeAll("\x1b[?2026h");

        if (range.first > previous_bottom) {
            try buffer.writer.print("\x1b[{d};1H", .{height});
            var scroll = range.first - previous_bottom;
            while (scroll > 0) : (scroll -= 1) {
                try buffer.writer.writeAll("\r\n");
            }
        } else {
            try buffer.writer.print("\x1b[{d};1H", .{range.first - self.previous_viewport_top + 1});
        }

        var row = range.first;
        while (row <= range.last and row < frame.lines.items.len) : (row += 1) {
            if (row > range.first) try buffer.writer.writeAll("\r\n");
            try buffer.writer.print("\x1b[2K{s}", .{frame.lines.items[row]});
        }

        try appendCursorMove(&buffer.writer, frame);
        try buffer.writer.writeAll("\x1b[?2026l");

        try output.writeAll(buffer.written());
        try self.replacePreviousLines(frame);
        self.previous_width = frame.size.width;
        self.previous_height = frame.size.height;
        self.previous_viewport_top = frameViewportTop(frame);
        self.hardware_cursor_row = if (frame.cursor) |cursor| cursor.row else if (frame.lines.items.len == 0) 0 else frame.lines.items.len - 1;
        self.max_lines_rendered = @max(self.max_lines_rendered, frame.lines.items.len);
    }

    fn positionCursor(self: *TerminalRenderer, frame: *const Frame, output: *std.Io.Writer) !void {
        _ = self;
        var buffer: std.Io.Writer.Allocating = .init(frame.allocator);
        defer buffer.deinit();
        try appendCursorMove(&buffer.writer, frame);
        try output.writeAll(buffer.written());
    }

    fn replacePreviousLines(self: *TerminalRenderer, frame: *const Frame) !void {
        self.freePreviousLines();
        for (frame.lines.items) |line| {
            try self.previous_lines.append(self.allocator, try self.allocator.dupe(u8, line));
        }
    }

    fn freePreviousLines(self: *TerminalRenderer) void {
        for (self.previous_lines.items) |line| self.allocator.free(line);
        self.previous_lines.clearRetainingCapacity();
    }
};

const ChangedRange = struct { first: usize, last: usize };

fn findChangedRange(previous: []const []const u8, next: []const []const u8) ?ChangedRange {
    const max_lines = @max(previous.len, next.len);
    var first: ?usize = null;
    var last: usize = 0;
    var row: usize = 0;
    while (row < max_lines) : (row += 1) {
        const previous_line = if (row < previous.len) previous[row] else "";
        const next_line = if (row < next.len) next[row] else "";
        if (!std.mem.eql(u8, previous_line, next_line)) {
            if (first == null) first = row;
            last = row;
        }
    }
    if (first) |value| return .{ .first = value, .last = last };
    return null;
}

fn appendCursorMove(writer: *std.Io.Writer, frame: *const Frame) !void {
    if (frame.cursor) |cursor| {
        if (visibleCursorRow(frame, cursor)) |row| {
            try writer.print("\x1b[{d};{d}H", .{ row + 1, cursor.col + 1 });
        }
    }
}

fn appendVisibleLines(writer: *std.Io.Writer, frame: *const Frame) !void {
    const top = frameViewportTop(frame);
    const height = @max(@as(usize, frame.size.height), 1);
    const end = @min(top + height, frame.lines.items.len);
    for (frame.lines.items[top..end], 0..) |line, index| {
        if (index > 0) try writer.writeAll("\r\n");
        try writer.writeAll(line);
    }
}

fn visibleCursorRow(frame: *const Frame, cursor: Position) ?usize {
    const top = frameViewportTop(frame);
    const height = @max(@as(usize, frame.size.height), 1);
    if (cursor.row < top or cursor.row >= top + height) return null;
    return cursor.row - top;
}

fn frameViewportTop(frame: *const Frame) usize {
    const tail_top = viewportTop(frame.lines.items.len, frame.size.height);
    const requested_top = frame.viewport_top orelse tail_top;
    return @min(requested_top, tail_top);
}

fn viewportTop(line_count: usize, raw_height: u16) usize {
    const height = @max(@as(usize, raw_height), 1);
    return line_count -| height;
}
