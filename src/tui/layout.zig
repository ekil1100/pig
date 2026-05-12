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
        const unit = decodeDisplayUnit(text[i..]);
        width += unit.width;
        i += unit.len;
    }
    return width;
}

pub fn previousDisplayUnitStart(text: []const u8, cursor: usize) usize {
    const end = @min(cursor, text.len);
    if (end == 0) return 0;
    var i: usize = 0;
    var previous: usize = 0;
    while (i < end) {
        previous = i;
        const unit = decodeDisplayUnit(text[i..]);
        if (unit.len == 0) break;
        const next = i + unit.len;
        if (next >= end) return i;
        i = next;
    }
    return previous;
}

pub fn nextDisplayUnitEnd(text: []const u8, cursor: usize) usize {
    const start = @min(cursor, text.len);
    if (start >= text.len) return text.len;
    const unit = decodeDisplayUnit(text[start..]);
    return @min(start + unit.len, text.len);
}

pub fn displayUnitOffsetAtColumn(text: []const u8, target_column: usize) usize {
    var i: usize = 0;
    var column: usize = 0;
    while (i < text.len) {
        const unit = decodeDisplayUnit(text[i..]);
        if (unit.len == 0) break;
        if (column + unit.width > target_column) return i;
        column += unit.width;
        i += unit.len;
        if (column == target_column) return i;
    }
    return text.len;
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

        const unit = decodeDisplayUnit(text[i..]);
        const char_width = unit.width;
        if (current_width > 0 and current_width + char_width > width) {
            try appendLine(allocator, &lines, text[start..i]);
            start = i;
            current_width = 0;
            continue;
        }
        current_width += char_width;
        i += unit.len;
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

const DecodedCodepoint = struct {
    codepoint: u21,
    len: usize,
};

const DisplayUnit = struct {
    len: usize,
    width: usize,
};

fn decodeDisplayUnit(bytes: []const u8) DisplayUnit {
    const first = decodeCodepoint(bytes);
    var len = first.len;
    var has_joiner = false;
    var pending_joiner = false;
    var emoji_cluster = isEmojiPresentationBase(first.codepoint);
    var emoji_variation = false;
    var keycap = false;

    if (isRegionalIndicator(first.codepoint) and len < bytes.len) {
        const next = decodeCodepoint(bytes[len..]);
        if (isRegionalIndicator(next.codepoint)) return .{ .len = len + next.len, .width = 2 };
    }

    while (len < bytes.len) {
        const next = decodeCodepoint(bytes[len..]);
        if (next.len == 0) break;
        if (isKeycapBase(first.codepoint) and next.codepoint == 0x20e3) {
            keycap = true;
            len += next.len;
            continue;
        }
        if (isCombining(next.codepoint) and !isCombining(first.codepoint)) {
            len += next.len;
            continue;
        }
        if (isVariationSelector(next.codepoint)) {
            if (next.codepoint == 0xfe0f and isEmojiVariationBase(first.codepoint)) {
                emoji_variation = true;
            }
            len += next.len;
            continue;
        }
        if (next.codepoint == 0x200d) {
            if (len + next.len >= bytes.len) break;
            const joined = decodeCodepoint(bytes[len + next.len ..]);
            if (!isEmojiVariationBase(joined.codepoint)) break;
            has_joiner = true;
            pending_joiner = true;
            len += next.len;
            continue;
        }
        if (pending_joiner) {
            emoji_cluster = emoji_cluster or isEmojiVariationBase(next.codepoint);
            pending_joiner = false;
            len += next.len;
            continue;
        }
        if (emoji_cluster and isEmojiModifier(next.codepoint)) {
            len += next.len;
            continue;
        }
        break;
    }

    if (keycap) return .{ .len = len, .width = 2 };
    if (emoji_cluster and (has_joiner or codepointWidth(first.codepoint) == 2)) return .{ .len = len, .width = 2 };
    if (emoji_variation) return .{ .len = len, .width = 2 };
    if (len > first.len) return .{ .len = len, .width = codepointWidth(first.codepoint) };
    return .{ .len = first.len, .width = codepointWidth(first.codepoint) };
}

fn decodeCodepoint(bytes: []const u8) DecodedCodepoint {
    const len = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return .{ .codepoint = 0xfffd, .len = 1 };
    if (bytes.len < len) return .{ .codepoint = 0xfffd, .len = 1 };
    const codepoint = std.unicode.utf8Decode(bytes[0..len]) catch return .{ .codepoint = 0xfffd, .len = 1 };
    return .{ .codepoint = codepoint, .len = len };
}

fn codepointWidth(codepoint: u21) usize {
    if (codepoint == 0) return 0;
    if (codepoint == '\t') return 1;
    if (codepoint < 0x20 or (codepoint >= 0x7f and codepoint < 0xa0)) return 0;
    if (isCombining(codepoint) or isVariationSelector(codepoint) or codepoint == 0x200d) return 0;
    if (isWide(codepoint)) return 2;
    return 1;
}

fn isCombining(codepoint: u21) bool {
    return inRange(codepoint, 0x0300, 0x036f) or
        inRange(codepoint, 0x0483, 0x0489) or
        inRange(codepoint, 0x0591, 0x05bd) or
        codepoint == 0x05bf or
        inRange(codepoint, 0x05c1, 0x05c2) or
        inRange(codepoint, 0x05c4, 0x05c5) or
        codepoint == 0x05c7 or
        inRange(codepoint, 0x0610, 0x061a) or
        inRange(codepoint, 0x064b, 0x065f) or
        codepoint == 0x0670 or
        inRange(codepoint, 0x06d6, 0x06dc) or
        inRange(codepoint, 0x06df, 0x06e4) or
        inRange(codepoint, 0x06e7, 0x06e8) or
        inRange(codepoint, 0x06ea, 0x06ed) or
        inRange(codepoint, 0x0711, 0x0711) or
        inRange(codepoint, 0x0730, 0x074a) or
        inRange(codepoint, 0x07a6, 0x07b0) or
        inRange(codepoint, 0x07eb, 0x07f3) or
        inRange(codepoint, 0x0816, 0x0819) or
        inRange(codepoint, 0x081b, 0x0823) or
        inRange(codepoint, 0x0825, 0x0827) or
        inRange(codepoint, 0x0829, 0x082d) or
        inRange(codepoint, 0x0859, 0x085b) or
        inRange(codepoint, 0x08d3, 0x08e1) or
        inRange(codepoint, 0x08e3, 0x0903) or
        inRange(codepoint, 0x093a, 0x093c) or
        inRange(codepoint, 0x0941, 0x0948) or
        codepoint == 0x094d or
        inRange(codepoint, 0x0951, 0x0957) or
        inRange(codepoint, 0x0962, 0x0963) or
        inRange(codepoint, 0x0981, 0x0981) or
        codepoint == 0x09bc or
        inRange(codepoint, 0x09c1, 0x09c4) or
        codepoint == 0x09cd or
        inRange(codepoint, 0x09e2, 0x09e3) or
        inRange(codepoint, 0x0a01, 0x0a02) or
        codepoint == 0x0a3c or
        inRange(codepoint, 0x0a41, 0x0a42) or
        inRange(codepoint, 0x0a47, 0x0a48) or
        inRange(codepoint, 0x0a4b, 0x0a4d) or
        inRange(codepoint, 0x0a70, 0x0a71) or
        inRange(codepoint, 0x0a81, 0x0a82) or
        codepoint == 0x0abc or
        inRange(codepoint, 0x0ac1, 0x0ac5) or
        inRange(codepoint, 0x0ac7, 0x0ac8) or
        codepoint == 0x0acd or
        inRange(codepoint, 0x0ae2, 0x0ae3) or
        inRange(codepoint, 0x0b01, 0x0b01) or
        codepoint == 0x0b3c or
        codepoint == 0x0b3f or
        inRange(codepoint, 0x0b41, 0x0b44) or
        codepoint == 0x0b4d or
        inRange(codepoint, 0x0b56, 0x0b56) or
        inRange(codepoint, 0x0b62, 0x0b63) or
        inRange(codepoint, 0x0c3e, 0x0c40) or
        inRange(codepoint, 0x0c46, 0x0c48) or
        inRange(codepoint, 0x0c4a, 0x0c4d) or
        inRange(codepoint, 0x0c55, 0x0c56) or
        inRange(codepoint, 0x0c62, 0x0c63) or
        inRange(codepoint, 0x0cbc, 0x0cbc) or
        codepoint == 0x0cbf or
        codepoint == 0x0cc6 or
        inRange(codepoint, 0x0ccc, 0x0ccd) or
        inRange(codepoint, 0x0ce2, 0x0ce3) or
        inRange(codepoint, 0x0d41, 0x0d44) or
        codepoint == 0x0d4d or
        inRange(codepoint, 0x0d62, 0x0d63) or
        codepoint == 0x0dca or
        inRange(codepoint, 0x0dd2, 0x0dd4) or
        codepoint == 0x0dd6 or
        inRange(codepoint, 0x0e31, 0x0e31) or
        inRange(codepoint, 0x0e34, 0x0e3a) or
        inRange(codepoint, 0x0e47, 0x0e4e) or
        codepoint == 0x0eb1 or
        inRange(codepoint, 0x0eb4, 0x0eb9) or
        inRange(codepoint, 0x0ebb, 0x0ebc) or
        inRange(codepoint, 0x0ec8, 0x0ecd) or
        inRange(codepoint, 0x0f18, 0x0f19) or
        codepoint == 0x0f35 or
        codepoint == 0x0f37 or
        codepoint == 0x0f39 or
        inRange(codepoint, 0x0f71, 0x0f7e) or
        inRange(codepoint, 0x0f80, 0x0f84) or
        inRange(codepoint, 0x0f86, 0x0f87) or
        inRange(codepoint, 0x0f8d, 0x0f97) or
        inRange(codepoint, 0x0f99, 0x0fbc) or
        codepoint == 0x0fc6 or
        inRange(codepoint, 0x102d, 0x1030) or
        inRange(codepoint, 0x1032, 0x1037) or
        inRange(codepoint, 0x1039, 0x103a) or
        inRange(codepoint, 0x103d, 0x103e) or
        inRange(codepoint, 0x1058, 0x1059) or
        inRange(codepoint, 0x105e, 0x1060) or
        inRange(codepoint, 0x1071, 0x1074) or
        inRange(codepoint, 0x1082, 0x1082) or
        inRange(codepoint, 0x1085, 0x1086) or
        codepoint == 0x108d or
        codepoint == 0x109d or
        inRange(codepoint, 0x135d, 0x135f) or
        inRange(codepoint, 0x1712, 0x1714) or
        inRange(codepoint, 0x1732, 0x1734) or
        inRange(codepoint, 0x1752, 0x1753) or
        inRange(codepoint, 0x1772, 0x1773) or
        inRange(codepoint, 0x17b4, 0x17b5) or
        inRange(codepoint, 0x17b7, 0x17bd) or
        codepoint == 0x17c6 or
        inRange(codepoint, 0x17c9, 0x17d3) or
        codepoint == 0x17dd or
        inRange(codepoint, 0x180b, 0x180d) or
        codepoint == 0x1885 or
        codepoint == 0x1886 or
        inRange(codepoint, 0x18a9, 0x18a9) or
        inRange(codepoint, 0x1920, 0x1922) or
        inRange(codepoint, 0x1927, 0x1928) or
        codepoint == 0x1932 or
        inRange(codepoint, 0x1939, 0x193b) or
        inRange(codepoint, 0x1a17, 0x1a18) or
        codepoint == 0x1a1b or
        codepoint == 0x1a56 or
        inRange(codepoint, 0x1a58, 0x1a5e) or
        codepoint == 0x1a60 or
        codepoint == 0x1a62 or
        inRange(codepoint, 0x1a65, 0x1a6c) or
        inRange(codepoint, 0x1a73, 0x1a7c) or
        codepoint == 0x1a7f or
        inRange(codepoint, 0x1ab0, 0x1aff) or
        inRange(codepoint, 0x1dc0, 0x1dff) or
        inRange(codepoint, 0x20d0, 0x20ff) or
        inRange(codepoint, 0xfe20, 0xfe2f);
}

fn isVariationSelector(codepoint: u21) bool {
    return inRange(codepoint, 0xfe00, 0xfe0f) or inRange(codepoint, 0xe0100, 0xe01ef);
}

fn isEmojiModifier(codepoint: u21) bool {
    return inRange(codepoint, 0x1f3fb, 0x1f3ff);
}

fn isKeycapBase(codepoint: u21) bool {
    return (codepoint >= '0' and codepoint <= '9') or codepoint == '#' or codepoint == '*';
}

fn isRegionalIndicator(codepoint: u21) bool {
    return inRange(codepoint, 0x1f1e6, 0x1f1ff);
}

fn isEmojiPresentationBase(codepoint: u21) bool {
    return inRange(codepoint, 0x1f000, 0x1faff);
}

fn isEmojiVariationBase(codepoint: u21) bool {
    return isEmojiPresentationBase(codepoint) or
        codepoint == 0x00a9 or
        codepoint == 0x00ae or
        codepoint == 0x203c or
        codepoint == 0x2049 or
        inRange(codepoint, 0x2122, 0x2139) or
        inRange(codepoint, 0x2194, 0x21aa) or
        inRange(codepoint, 0x231a, 0x231b) or
        inRange(codepoint, 0x23e9, 0x23f3) or
        inRange(codepoint, 0x23f8, 0x23fa) or
        inRange(codepoint, 0x25aa, 0x25ab) or
        inRange(codepoint, 0x25b6, 0x25c0) or
        inRange(codepoint, 0x25fb, 0x25fe) or
        inRange(codepoint, 0x2600, 0x27bf) or
        inRange(codepoint, 0x2934, 0x2935) or
        inRange(codepoint, 0x2b05, 0x2b55) or
        codepoint == 0x3030 or
        codepoint == 0x303d or
        codepoint == 0x3297 or
        codepoint == 0x3299;
}

fn isWide(codepoint: u21) bool {
    return inRange(codepoint, 0x1100, 0x115f) or
        codepoint == 0x2329 or
        codepoint == 0x232a or
        inRange(codepoint, 0x2e80, 0xa4cf) or
        inRange(codepoint, 0xac00, 0xd7a3) or
        inRange(codepoint, 0xf900, 0xfaff) or
        inRange(codepoint, 0xfe10, 0xfe19) or
        inRange(codepoint, 0xfe30, 0xfe6f) or
        inRange(codepoint, 0xff00, 0xff60) or
        inRange(codepoint, 0xffe0, 0xffe6) or
        inRange(codepoint, 0x1f000, 0x1faff) or
        inRange(codepoint, 0x20000, 0x3fffd);
}

fn inRange(codepoint: u21, start: u21, end: u21) bool {
    return codepoint >= start and codepoint <= end;
}
