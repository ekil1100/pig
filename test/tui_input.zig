const std = @import("std");
const pig = @import("pig");
const input = pig.tui.input;

test "input decoder recognizes text arrows ctrl and paste markers" {
    const events = try input.decodeAll(std.testing.allocator, "h中\x1b[D\x03\x1b[200~x\x1b[201~");
    defer std.testing.allocator.free(events);

    try std.testing.expectEqual(input.KeyKind.char, events[0].kind);
    try std.testing.expectEqualStrings("h", events[0].text.?);
    try std.testing.expectEqual(input.KeyKind.char, events[1].kind);
    try std.testing.expectEqualStrings("中", events[1].text.?);
    try std.testing.expectEqual(input.KeyKind.arrow, events[2].kind);
    try std.testing.expectEqual(input.Direction.left, events[2].arrow.?);
    try std.testing.expectEqual(input.KeyKind.ctrl, events[3].kind);
    try std.testing.expectEqual(@as(u8, 'c'), events[3].ctrl.?);
    try std.testing.expectEqual(input.KeyKind.paste_start, events[4].kind);
    try std.testing.expectEqual(input.KeyKind.char, events[5].kind);
    try std.testing.expectEqual(input.KeyKind.paste_end, events[6].kind);
}

test "input decoder separates enter submit from ctrl-j newline" {
    const events = try input.decodeAll(std.testing.allocator, "a\nb\r");
    defer std.testing.allocator.free(events);

    try std.testing.expectEqual(input.KeyKind.char, events[0].kind);
    try std.testing.expectEqual(input.KeyKind.newline, events[1].kind);
    try std.testing.expectEqual(input.KeyKind.char, events[2].kind);
    try std.testing.expectEqual(input.KeyKind.enter, events[3].kind);
}

test "input decoder recognizes page scroll keys" {
    const events = try input.decodeAll(std.testing.allocator, "\x1b[5~\x1b[6~");
    defer std.testing.allocator.free(events);

    try std.testing.expectEqual(input.KeyKind.page_up, events[0].kind);
    try std.testing.expectEqual(input.KeyKind.page_down, events[1].kind);
}

test "input decoder recognizes mouse wheel scroll" {
    const events = try input.decodeAll(std.testing.allocator, "\x1b[<64;10;20M\x1b[<65;10;20M\x1b[M`!!\x1b[Ma!!");
    defer std.testing.allocator.free(events);

    try std.testing.expectEqual(input.KeyKind.mouse_scroll, events[0].kind);
    try std.testing.expectEqual(input.Direction.up, events[0].mouse_scroll.?);
    try std.testing.expectEqual(input.KeyKind.mouse_scroll, events[1].kind);
    try std.testing.expectEqual(input.Direction.down, events[1].mouse_scroll.?);
    try std.testing.expectEqual(input.Direction.up, events[2].mouse_scroll.?);
    try std.testing.expectEqual(input.Direction.down, events[3].mouse_scroll.?);
}

test "input decoder ignores horizontal mouse wheel scroll" {
    const events = try input.decodeAll(std.testing.allocator, "\x1b[<66;10;20M\x1b[<67;10;20M");
    defer std.testing.allocator.free(events);

    try std.testing.expectEqual(@as(usize, 0), events.len);
}
