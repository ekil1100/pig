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

pub const StreamDecoder = struct {
    pub const escape_timeout_ms: u64 = 250;

    allocator: std.mem.Allocator,
    pending: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) StreamDecoder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *StreamDecoder) void {
        self.pending.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn push(self: *StreamDecoder, bytes: []const u8) !void {
        try self.pending.appendSlice(self.allocator, bytes);
    }

    pub fn decodeAvailable(self: *StreamDecoder) !DecodeResult {
        return try decodePrefix(self.allocator, self.pending.items, .partial);
    }

    pub fn discard(self: *StreamDecoder, consumed: usize) void {
        if (consumed == 0) return;
        if (consumed >= self.pending.items.len) {
            self.pending.clearRetainingCapacity();
            return;
        }
        std.mem.copyForwards(u8, self.pending.items[0..], self.pending.items[consumed..]);
        self.pending.shrinkRetainingCapacity(self.pending.items.len - consumed);
    }

    pub fn flushPending(self: *StreamDecoder) !DecodeResult {
        return try decodePrefix(self.allocator, self.pending.items, .complete);
    }

    pub fn flushTimedOut(self: *StreamDecoder) !DecodeResult {
        if (self.pending.items.len > 0 and self.pending.items[0] == 0x1b) {
            return try self.flushPending();
        }
        return try self.decodeAvailable();
    }

    pub fn shouldFlushTimedOut(self: *const StreamDecoder, elapsed_ms: u64) bool {
        return self.pending.items.len > 0 and self.pending.items[0] == 0x1b and elapsed_ms >= escape_timeout_ms;
    }
};

pub const DecodeResult = struct {
    events: []KeyEvent,
    consumed: usize,
};

pub fn decodeAll(allocator: std.mem.Allocator, bytes: []const u8) ![]KeyEvent {
    const result = try decodePrefix(allocator, bytes, .complete);
    std.debug.assert(result.consumed == bytes.len);
    return result.events;
}

const DecodeMode = enum { complete, partial };

fn decodePrefix(allocator: std.mem.Allocator, bytes: []const u8, mode: DecodeMode) !DecodeResult {
    var events: std.ArrayList(KeyEvent) = .empty;
    errdefer events.deinit(allocator);

    var i: usize = 0;
    while (i < bytes.len) {
        switch (try decodeOne(bytes[i..], mode)) {
            .need_more => break,
            .decoded => |decoded| {
                if (decoded.event) |event| try events.append(allocator, event);
                i += decoded.consumed;
            },
        }
    }
    return .{ .events = try events.toOwnedSlice(allocator), .consumed = i };
}

const DecodeOneResult = union(enum) {
    need_more,
    decoded: struct {
        consumed: usize,
        event: ?KeyEvent = null,
    },
};

fn decodeOne(bytes: []const u8, mode: DecodeMode) !DecodeOneResult {
    const byte = bytes[0];
    switch (byte) {
        '\r' => return decodedEvent(1, .{ .kind = .enter }),
        '\n' => return decodedEvent(1, .{ .kind = .newline }),
        '\t' => return decodedEvent(1, .{ .kind = .tab }),
        0x03 => return decodedEvent(1, .{ .kind = .ctrl, .ctrl = 'c' }),
        0x04 => return decodedEvent(1, .{ .kind = .ctrl, .ctrl = 'd' }),
        0x7f, 0x08 => return decodedEvent(1, .{ .kind = .backspace }),
        0x1b => return try decodeEscape(bytes, mode),
        else => return decodeText(bytes, mode),
    }
}

fn decodeText(bytes: []const u8, mode: DecodeMode) !DecodeOneResult {
    const len = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return decodedEvent(1, .{ .kind = .unknown });
    if (bytes.len < len) {
        for (bytes[1..]) |byte| {
            if ((byte & 0xc0) != 0x80) return decodedEvent(1, .{ .kind = .unknown });
        }
        if (mode == .partial) return .need_more;
        return decodedEvent(1, .{ .kind = .unknown });
    }
    _ = std.unicode.utf8Decode(bytes[0..len]) catch return decodedEvent(1, .{ .kind = .unknown });
    return decodedEvent(len, .{ .kind = .char, .text = bytes[0..len] });
}

fn decodeEscape(bytes: []const u8, mode: DecodeMode) !DecodeOneResult {
    if (bytes.len == 1 and mode == .partial) return .need_more;

    if (std.mem.startsWith(u8, bytes, "\x1b[200~")) {
        return decodedEvent(6, .{ .kind = .paste_start });
    }
    if (std.mem.startsWith(u8, bytes, "\x1b[201~")) {
        return decodedEvent(6, .{ .kind = .paste_end });
    }
    if (try decodeSgrMouse(bytes, mode)) |decoded| return decoded;
    if (try decodeLegacyMouse(bytes, mode)) |decoded| return decoded;
    if (std.mem.startsWith(u8, bytes, "\x1b[A")) {
        return decodedEvent(3, .{ .kind = .arrow, .arrow = .up });
    }
    if (std.mem.startsWith(u8, bytes, "\x1b[B")) {
        return decodedEvent(3, .{ .kind = .arrow, .arrow = .down });
    }
    if (std.mem.startsWith(u8, bytes, "\x1b[C")) {
        return decodedEvent(3, .{ .kind = .arrow, .arrow = .right });
    }
    if (std.mem.startsWith(u8, bytes, "\x1b[D")) {
        return decodedEvent(3, .{ .kind = .arrow, .arrow = .left });
    }
    if (std.mem.startsWith(u8, bytes, "\x1b[H") or std.mem.startsWith(u8, bytes, "\x1b[1~")) {
        return decodedEvent(if (bytes.len >= 4 and bytes[2] == '1') 4 else 3, .{ .kind = .home });
    }
    if (std.mem.startsWith(u8, bytes, "\x1b[F") or std.mem.startsWith(u8, bytes, "\x1b[4~")) {
        return decodedEvent(if (bytes.len >= 4 and bytes[2] == '4') 4 else 3, .{ .kind = .end });
    }
    if (std.mem.startsWith(u8, bytes, "\x1b[3~")) {
        return decodedEvent(4, .{ .kind = .delete });
    }
    if (std.mem.startsWith(u8, bytes, "\x1b[5~")) {
        return decodedEvent(4, .{ .kind = .page_up });
    }
    if (std.mem.startsWith(u8, bytes, "\x1b[6~")) {
        return decodedEvent(4, .{ .kind = .page_down });
    }

    if (mode == .partial and isPotentialEscapeSequence(bytes)) return .need_more;
    return decodedEvent(1, .{ .kind = .escape });
}

fn decodeSgrMouse(bytes: []const u8, mode: DecodeMode) !?DecodeOneResult {
    if (!std.mem.startsWith(u8, bytes, "\x1b[<")) return null;
    var i: usize = 3;
    const button_start = i;
    while (i < bytes.len and std.ascii.isDigit(bytes[i])) i += 1;
    if (i == button_start) return null;
    if (i >= bytes.len) return if (mode == .partial) .need_more else null;
    if (bytes[i] != ';') return null;
    const button = std.fmt.parseInt(u16, bytes[button_start..i], 10) catch return null;
    i += 1;
    while (i < bytes.len and std.ascii.isDigit(bytes[i])) i += 1;
    if (i >= bytes.len) return if (mode == .partial) .need_more else null;
    if (bytes[i] != ';') return null;
    i += 1;
    while (i < bytes.len and std.ascii.isDigit(bytes[i])) i += 1;
    if (i >= bytes.len) return if (mode == .partial) .need_more else null;
    if (bytes[i] != 'M' and bytes[i] != 'm') return null;

    const direction = wheelDirection(button) orelse return decodedSkip(i + 1);
    return decodedEvent(i + 1, .{ .kind = .mouse_scroll, .mouse_scroll = direction });
}

fn decodeLegacyMouse(bytes: []const u8, mode: DecodeMode) !?DecodeOneResult {
    if (!std.mem.startsWith(u8, bytes, "\x1b[M")) return null;
    if (bytes.len < 6) return if (mode == .partial) .need_more else null;
    if (bytes[3] < 32) return null;
    const button = @as(u16, bytes[3] - 32);
    const direction = wheelDirection(button) orelse return decodedSkip(6);
    return decodedEvent(6, .{ .kind = .mouse_scroll, .mouse_scroll = direction });
}

fn isPotentialEscapeSequence(bytes: []const u8) bool {
    if (bytes.len == 0 or bytes[0] != 0x1b) return false;
    if (bytes.len == 1) return true;
    if (bytes[1] != '[') return false;
    if (bytes.len == 2) return true;
    return switch (bytes[2]) {
        '<' => isPotentialSgrMouseSequence(bytes),
        'M' => isPotentialLegacyMouseSequence(bytes),
        '0'...'9' => isPotentialNumberedCsiSequence(bytes),
        else => false,
    };
}

fn isPotentialNumberedCsiSequence(bytes: []const u8) bool {
    var i: usize = 2;
    while (i < bytes.len and std.ascii.isDigit(bytes[i])) i += 1;
    return i == bytes.len;
}

fn isPotentialLegacyMouseSequence(bytes: []const u8) bool {
    if (bytes.len >= 4 and bytes[3] < 32) return false;
    return bytes.len < 6;
}

fn isPotentialSgrMouseSequence(bytes: []const u8) bool {
    var i: usize = 3;
    if (i == bytes.len) return true;

    const button_start = i;
    while (i < bytes.len and std.ascii.isDigit(bytes[i])) i += 1;
    if (i == button_start) return false;
    if (i == bytes.len) return true;
    if (bytes[i] != ';') return false;
    i += 1;
    if (i == bytes.len) return true;

    const x_start = i;
    while (i < bytes.len and std.ascii.isDigit(bytes[i])) i += 1;
    if (i == x_start) return false;
    if (i == bytes.len) return true;
    if (bytes[i] != ';') return false;
    i += 1;
    if (i == bytes.len) return true;

    const y_start = i;
    while (i < bytes.len and std.ascii.isDigit(bytes[i])) i += 1;
    if (i == y_start) return false;
    return i == bytes.len;
}

fn decodedEvent(consumed: usize, event: KeyEvent) DecodeOneResult {
    return .{ .decoded = .{ .consumed = consumed, .event = event } };
}

fn decodedSkip(consumed: usize) DecodeOneResult {
    return .{ .decoded = .{ .consumed = consumed } };
}

fn wheelDirection(button: u16) ?Direction {
    if ((button & 64) == 0) return null;
    return switch (button & 3) {
        0 => .up,
        1 => .down,
        else => null,
    };
}
