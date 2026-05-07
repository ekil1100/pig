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
    mouse_scroll,
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
    mouse_scroll: ?Direction = null,
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
    if (try decodeSgrMouse(allocator, bytes, events)) |consumed| return consumed;
    if (try decodeLegacyMouse(allocator, bytes, events)) |consumed| return consumed;
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
    if (std.mem.startsWith(u8, bytes, "\x1b[5~")) {
        try events.append(allocator, .{ .kind = .page_up });
        return 4;
    }
    if (std.mem.startsWith(u8, bytes, "\x1b[6~")) {
        try events.append(allocator, .{ .kind = .page_down });
        return 4;
    }
    try events.append(allocator, .{ .kind = .escape });
    return 1;
}

fn decodeSgrMouse(allocator: std.mem.Allocator, bytes: []const u8, events: *std.ArrayList(KeyEvent)) !?usize {
    if (!std.mem.startsWith(u8, bytes, "\x1b[<")) return null;
    var i: usize = 3;
    const button_start = i;
    while (i < bytes.len and std.ascii.isDigit(bytes[i])) i += 1;
    if (i == button_start or i >= bytes.len or bytes[i] != ';') return null;
    const button = std.fmt.parseInt(u16, bytes[button_start..i], 10) catch return null;
    i += 1;
    while (i < bytes.len and std.ascii.isDigit(bytes[i])) i += 1;
    if (i >= bytes.len or bytes[i] != ';') return null;
    i += 1;
    while (i < bytes.len and std.ascii.isDigit(bytes[i])) i += 1;
    if (i >= bytes.len or (bytes[i] != 'M' and bytes[i] != 'm')) return null;

    const direction = wheelDirection(button) orelse return i + 1;
    try events.append(allocator, .{ .kind = .mouse_scroll, .mouse_scroll = direction });
    return i + 1;
}

fn decodeLegacyMouse(allocator: std.mem.Allocator, bytes: []const u8, events: *std.ArrayList(KeyEvent)) !?usize {
    if (!std.mem.startsWith(u8, bytes, "\x1b[M")) return null;
    if (bytes.len < 6) return null;
    if (bytes[3] < 32) return null;
    const button = @as(u16, bytes[3] - 32);
    const direction = wheelDirection(button) orelse return 6;
    try events.append(allocator, .{ .kind = .mouse_scroll, .mouse_scroll = direction });
    return 6;
}

fn wheelDirection(button: u16) ?Direction {
    if ((button & 64) == 0) return null;
    return switch (button & 3) {
        0 => .up,
        1 => .down,
        else => null,
    };
}

fn utf8SequenceLength(byte: u8) ?usize {
    if (byte < 0x80) return 1;
    if ((byte & 0xe0) == 0xc0) return 2;
    if ((byte & 0xf0) == 0xe0) return 3;
    if ((byte & 0xf8) == 0xf0) return 4;
    return null;
}
