const std = @import("std");

pub const Direction = enum { left, right, up, down };

pub const KeyKind = enum {
    char,
    enter,
    newline,
    escape,
    backspace,
    delete,
    arrow,
    home,
    end,
    page_up,
    page_down,
    tab,
    paste_start,
    paste_end,
    ctrl,
    unknown,
};

pub const KeyEvent = struct {
    kind: KeyKind,
    text: ?[]const u8 = null,
    ctrl: ?u8 = null,
    arrow: ?Direction = null,
};

pub fn decodeAll(allocator: std.mem.Allocator, bytes: []const u8) ![]KeyEvent {
    var events: std.ArrayList(KeyEvent) = .empty;
    errdefer events.deinit(allocator);

    var i: usize = 0;
    while (i < bytes.len) {
        const byte = bytes[i];
        switch (byte) {
            '\r' => {
                try events.append(allocator, .{ .kind = .enter });
                i += 1;
            },
            '\n' => {
                try events.append(allocator, .{ .kind = .newline });
                i += 1;
            },
            '\t' => {
                try events.append(allocator, .{ .kind = .tab });
                i += 1;
            },
            0x03 => {
                try events.append(allocator, .{ .kind = .ctrl, .ctrl = 'c' });
                i += 1;
            },
            0x04 => {
                try events.append(allocator, .{ .kind = .ctrl, .ctrl = 'd' });
                i += 1;
            },
            0x7f, 0x08 => {
                try events.append(allocator, .{ .kind = .backspace });
                i += 1;
            },
            0x1b => {
                const consumed = try decodeEscape(allocator, bytes[i..], &events);
                i += consumed;
            },
            else => {
                const len = utf8SequenceLength(byte) orelse {
                    try events.append(allocator, .{ .kind = .unknown });
                    i += 1;
                    continue;
                };
                if (i + len > bytes.len) {
                    try events.append(allocator, .{ .kind = .unknown });
                    break;
                }
                try events.append(allocator, .{ .kind = .char, .text = bytes[i .. i + len] });
                i += len;
            },
        }
    }
    return try events.toOwnedSlice(allocator);
}

fn decodeEscape(allocator: std.mem.Allocator, bytes: []const u8, events: *std.ArrayList(KeyEvent)) !usize {
    if (std.mem.startsWith(u8, bytes, "\x1b[200~")) {
        try events.append(allocator, .{ .kind = .paste_start });
        return 6;
    }
    if (std.mem.startsWith(u8, bytes, "\x1b[201~")) {
        try events.append(allocator, .{ .kind = .paste_end });
        return 6;
    }
    if (std.mem.startsWith(u8, bytes, "\x1b[A")) {
        try events.append(allocator, .{ .kind = .arrow, .arrow = .up });
        return 3;
    }
    if (std.mem.startsWith(u8, bytes, "\x1b[B")) {
        try events.append(allocator, .{ .kind = .arrow, .arrow = .down });
        return 3;
    }
    if (std.mem.startsWith(u8, bytes, "\x1b[C")) {
        try events.append(allocator, .{ .kind = .arrow, .arrow = .right });
        return 3;
    }
    if (std.mem.startsWith(u8, bytes, "\x1b[D")) {
        try events.append(allocator, .{ .kind = .arrow, .arrow = .left });
        return 3;
    }
    if (std.mem.startsWith(u8, bytes, "\x1b[H") or std.mem.startsWith(u8, bytes, "\x1b[1~")) {
        try events.append(allocator, .{ .kind = .home });
        return if (bytes.len >= 4 and bytes[2] == '1') 4 else 3;
    }
    if (std.mem.startsWith(u8, bytes, "\x1b[F") or std.mem.startsWith(u8, bytes, "\x1b[4~")) {
        try events.append(allocator, .{ .kind = .end });
        return if (bytes.len >= 4 and bytes[2] == '4') 4 else 3;
    }
    if (std.mem.startsWith(u8, bytes, "\x1b[3~")) {
        try events.append(allocator, .{ .kind = .delete });
        return 4;
    }
    try events.append(allocator, .{ .kind = .escape });
    return 1;
}

fn utf8SequenceLength(byte: u8) ?usize {
    if (byte < 0x80) return 1;
    if ((byte & 0xe0) == 0xc0) return 2;
    if ((byte & 0xf0) == 0xe0) return 3;
    if ((byte & 0xf8) == 0xf0) return 4;
    return null;
}
