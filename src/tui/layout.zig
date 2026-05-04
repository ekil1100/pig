const std = @import("std");

pub const Size = struct { width: u16, height: u16 };

pub fn displayWidth(text: []const u8) usize {
    var width: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const byte = text[i];
        if (byte == '\n' or byte == '\r') {
            i += 1;
            continue;
        }
        const len = utf8SequenceLength(byte) orelse 1;
        width += if (byte < 0x80) @as(usize, 1) else 2;
        i += @min(len, text.len - i);
    }
    return width;
}

pub fn wrapText(allocator: std.mem.Allocator, text: []const u8, raw_width: u16) ![][]const u8 {
    const width = @max(@as(usize, raw_width), 1);
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }

    var start: usize = 0;
    var i: usize = 0;
    var current_width: usize = 0;
    while (i < text.len) {
        if (text[i] == '\n') {
            try appendLine(allocator, &lines, text[start..i]);
            i += 1;
            start = i;
            current_width = 0;
            continue;
        }

        const len = utf8SequenceLength(text[i]) orelse 1;
        const char_width: usize = if (text[i] < 0x80) 1 else 2;
        if (current_width > 0 and current_width + char_width > width) {
            try appendLine(allocator, &lines, text[start..i]);
            start = i;
            current_width = 0;
            continue;
        }
        current_width += char_width;
        i += @min(len, text.len - i);
    }
    try appendLine(allocator, &lines, text[start..]);
    return try lines.toOwnedSlice(allocator);
}

pub fn freeLines(allocator: std.mem.Allocator, lines: [][]const u8) void {
    for (lines) |line| allocator.free(line);
    allocator.free(lines);
}

fn appendLine(allocator: std.mem.Allocator, lines: *std.ArrayList([]const u8), line: []const u8) !void {
    try lines.append(allocator, try allocator.dupe(u8, line));
}

fn utf8SequenceLength(byte: u8) ?usize {
    if (byte < 0x80) return 1;
    if ((byte & 0xe0) == 0xc0) return 2;
    if ((byte & 0xf0) == 0xe0) return 3;
    if ((byte & 0xf8) == 0xf0) return 4;
    return null;
}
