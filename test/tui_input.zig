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
