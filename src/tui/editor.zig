const std = @import("std");
const input = @import("input.zig");
const layout = @import("layout.zig");

pub const SubmitResult = union(enum) {
    none,
    submit: []const u8,
    exit,
    abort,
};

pub const EditorState = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8) = .empty,
    cursor_byte: usize = 0,
    history: std.ArrayList([]const u8) = .empty,
    history_index: ?usize = null,

    pub fn init(allocator: std.mem.Allocator) EditorState {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *EditorState) void {
        self.buffer.deinit(self.allocator);
        for (self.history.items) |item| self.allocator.free(item);
        self.history.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn text(self: *const EditorState) []const u8 {
        return self.buffer.items;
    }

    pub fn handle(self: *EditorState, event: input.KeyEvent, busy: bool) !SubmitResult {
        switch (event.kind) {
            .char => if (event.text) |text_bytes| try self.insert(text_bytes),
            .newline => try self.insert("\n"),
            .tab => try self.insert("\t"),
            .enter => if (!busy) return try self.submit(),
            .backspace => try self.backspace(),
            .delete => try self.deleteForward(),
            .arrow => if (event.arrow) |arrow| switch (arrow) {
                .left => self.moveLeft(),
                .right => self.moveRight(),
                .up => try self.moveUpOrHistory(),
                .down => try self.moveDownOrHistory(),
            },
            .home => self.cursor_byte = lineStart(self.buffer.items, self.cursor_byte),
            .end => self.cursor_byte = lineEnd(self.buffer.items, self.cursor_byte),
            .ctrl => if (event.ctrl) |ctrl| {
                if (ctrl == 'c') return if (busy) .abort else .exit;
                if (ctrl == 'd' and self.buffer.items.len == 0) return .exit;
            },
            else => {},
        }
        return .none;
    }

    pub fn insert(self: *EditorState, bytes: []const u8) !void {
        try self.buffer.insertSlice(self.allocator, self.cursor_byte, bytes);
        self.cursor_byte += bytes.len;
        self.history_index = null;
    }

    pub fn submit(self: *EditorState) !SubmitResult {
        const trimmed = std.mem.trim(u8, self.buffer.items, " \t\r\n");
        if (trimmed.len == 0) {
            self.clearRetainingCapacity();
            return .none;
        }
        if (std.mem.eql(u8, trimmed, "exit") or std.mem.eql(u8, trimmed, "quit")) {
            self.clearRetainingCapacity();
            return .exit;
        }
        const owned = try self.allocator.dupe(u8, self.buffer.items);
        errdefer self.allocator.free(owned);
        const history_copy = try self.allocator.dupe(u8, self.buffer.items);
        errdefer self.allocator.free(history_copy);
        try self.history.append(self.allocator, history_copy);
        self.clearRetainingCapacity();
        return .{ .submit = owned };
    }

    pub fn freeSubmitted(self: *EditorState, text_value: []const u8) void {
        self.allocator.free(text_value);
    }

    fn clearRetainingCapacity(self: *EditorState) void {
        self.buffer.clearRetainingCapacity();
        self.cursor_byte = 0;
        self.history_index = null;
    }

    fn backspace(self: *EditorState) !void {
        if (self.cursor_byte == 0) return;
        const start = layout.previousDisplayUnitStart(self.buffer.items, self.cursor_byte);
        try self.buffer.replaceRange(self.allocator, start, self.cursor_byte - start, "");
        self.cursor_byte = start;
        self.history_index = null;
    }

    fn deleteForward(self: *EditorState) !void {
        if (self.cursor_byte >= self.buffer.items.len) return;
        const end = layout.nextDisplayUnitEnd(self.buffer.items, self.cursor_byte);
        try self.buffer.replaceRange(self.allocator, self.cursor_byte, end - self.cursor_byte, "");
        self.history_index = null;
    }

    fn moveLeft(self: *EditorState) void {
        if (self.cursor_byte == 0) return;
        self.cursor_byte = layout.previousDisplayUnitStart(self.buffer.items, self.cursor_byte);
    }

    fn moveRight(self: *EditorState) void {
        if (self.cursor_byte >= self.buffer.items.len) return;
        self.cursor_byte = layout.nextDisplayUnitEnd(self.buffer.items, self.cursor_byte);
    }

    fn moveUpOrHistory(self: *EditorState) !void {
        const start = lineStart(self.buffer.items, self.cursor_byte);
        if (start > 0) {
            const column = layout.displayWidth(self.buffer.items[start..self.cursor_byte]);
            const previous_end = start - 1;
            const previous_start = lineStart(self.buffer.items, previous_end);
            self.cursor_byte = cursorAtDisplayColumn(self.buffer.items, previous_start, previous_end, column);
            return;
        }
        if (self.history.items.len == 0) return;
        const next_index = if (self.history_index) |index| if (index > 0) index - 1 else 0 else self.history.items.len - 1;
        try self.loadHistory(next_index);
    }

    fn moveDownOrHistory(self: *EditorState) !void {
        const end = lineEnd(self.buffer.items, self.cursor_byte);
        if (end < self.buffer.items.len) {
            const start = lineStart(self.buffer.items, self.cursor_byte);
            const column = layout.displayWidth(self.buffer.items[start..self.cursor_byte]);
            const next_start = end + 1;
            const next_end = lineEnd(self.buffer.items, next_start);
            self.cursor_byte = cursorAtDisplayColumn(self.buffer.items, next_start, next_end, column);
            return;
        }
        if (self.history_index) |index| {
            if (index + 1 < self.history.items.len) {
                try self.loadHistory(index + 1);
            } else {
                self.clearRetainingCapacity();
            }
        }
    }

    fn loadHistory(self: *EditorState, index: usize) !void {
        self.buffer.clearRetainingCapacity();
        try self.buffer.appendSlice(self.allocator, self.history.items[index]);
        self.cursor_byte = self.buffer.items.len;
        self.history_index = index;
    }
};

fn lineStart(bytes: []const u8, cursor: usize) usize {
    var i = @min(cursor, bytes.len);
    while (i > 0) {
        if (bytes[i - 1] == '\n') break;
        i -= 1;
    }
    return i;
}

fn lineEnd(bytes: []const u8, cursor: usize) usize {
    var i = @min(cursor, bytes.len);
    while (i < bytes.len and bytes[i] != '\n') i += 1;
    return i;
}

fn cursorAtDisplayColumn(bytes: []const u8, start: usize, end: usize, column: usize) usize {
    return start + layout.displayUnitOffsetAtColumn(bytes[start..end], column);
}
