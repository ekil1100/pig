const std = @import("std");
const pig = @import("pig");
const input = pig.tui.input;
const terminal = pig.tui.terminal;

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

test "stream input decoder preserves split escape sequences" {
    var decoder = input.StreamDecoder.init(std.testing.allocator);
    defer decoder.deinit();

    try decoder.push("\x1b");
    const first = try decoder.decodeAvailable();
    defer std.testing.allocator.free(first.events);
    defer decoder.discard(first.consumed);
    try std.testing.expectEqual(@as(usize, 0), first.events.len);
    try std.testing.expectEqual(@as(usize, 0), first.consumed);

    try decoder.push("[D");
    const second = try decoder.decodeAvailable();
    defer std.testing.allocator.free(second.events);
    defer decoder.discard(second.consumed);
    try std.testing.expectEqual(@as(usize, 1), second.events.len);
    try std.testing.expectEqual(input.KeyKind.arrow, second.events[0].kind);
    try std.testing.expectEqual(input.Direction.left, second.events[0].arrow.?);
    try std.testing.expectEqual(@as(usize, 3), second.consumed);
}

test "stream input decoder preserves split utf8 characters" {
    var decoder = input.StreamDecoder.init(std.testing.allocator);
    defer decoder.deinit();

    try decoder.push("中"[0..1]);
    const first = try decoder.decodeAvailable();
    defer std.testing.allocator.free(first.events);
    defer decoder.discard(first.consumed);
    try std.testing.expectEqual(@as(usize, 0), first.events.len);
    try std.testing.expectEqual(@as(usize, 0), first.consumed);

    try decoder.push("中"[1..]);
    const second = try decoder.decodeAvailable();
    defer std.testing.allocator.free(second.events);
    defer decoder.discard(second.consumed);
    try std.testing.expectEqual(@as(usize, 1), second.events.len);
    try std.testing.expectEqual(input.KeyKind.char, second.events[0].kind);
    try std.testing.expectEqualStrings("中", second.events[0].text.?);
    try std.testing.expectEqual(@as(usize, 3), second.consumed);
}

test "stream input decoder flushes lone escape" {
    var decoder = input.StreamDecoder.init(std.testing.allocator);
    defer decoder.deinit();

    try decoder.push("\x1b");
    const flushed = try decoder.flushPending();
    defer std.testing.allocator.free(flushed.events);
    defer decoder.discard(flushed.consumed);
    try std.testing.expectEqual(@as(usize, 1), flushed.events.len);
    try std.testing.expectEqual(input.KeyKind.escape, flushed.events[0].kind);
    try std.testing.expectEqual(@as(usize, 1), flushed.consumed);
}

test "stream input decoder uses separate escape timeout threshold" {
    var decoder = input.StreamDecoder.init(std.testing.allocator);
    defer decoder.deinit();

    try decoder.push("\x1b");
    try std.testing.expect(!decoder.shouldFlushTimedOut(25));
    try std.testing.expect(decoder.shouldFlushTimedOut(input.StreamDecoder.escape_timeout_ms));
}

test "stream input decoder timeout keeps split utf8 pending" {
    var decoder = input.StreamDecoder.init(std.testing.allocator);
    defer decoder.deinit();

    try decoder.push("中"[0..1]);
    const timed_out = try decoder.flushTimedOut();
    defer std.testing.allocator.free(timed_out.events);
    defer decoder.discard(timed_out.consumed);
    try std.testing.expectEqual(@as(usize, 0), timed_out.events.len);
    try std.testing.expectEqual(@as(usize, 0), timed_out.consumed);
}

test "stream input decoder releases impossible partial utf8" {
    var decoder = input.StreamDecoder.init(std.testing.allocator);
    defer decoder.deinit();

    try decoder.push("\xe4a");
    const decoded = try decoder.decodeAvailable();
    defer std.testing.allocator.free(decoded.events);
    defer decoder.discard(decoded.consumed);

    try std.testing.expectEqual(@as(usize, 2), decoded.events.len);
    try std.testing.expectEqual(input.KeyKind.unknown, decoded.events[0].kind);
    try std.testing.expectEqual(input.KeyKind.char, decoded.events[1].kind);
    try std.testing.expectEqualStrings("a", decoded.events[1].text.?);
    try std.testing.expectEqual(@as(usize, 2), decoded.consumed);
}

test "stream input decoder does not pin invalid mouse escape prefixes" {
    var decoder = input.StreamDecoder.init(std.testing.allocator);
    defer decoder.deinit();

    try decoder.push("\x1b[<x");
    const decoded = try decoder.decodeAvailable();
    defer std.testing.allocator.free(decoded.events);
    defer decoder.discard(decoded.consumed);

    try std.testing.expect(decoded.events.len > 0);
    try std.testing.expectEqual(input.KeyKind.escape, decoded.events[0].kind);
    try std.testing.expectEqual(@as(usize, 4), decoded.consumed);
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

test "interactive terminal sequences keep native mouse selection available" {
    try std.testing.expect(std.mem.indexOf(u8, terminal.interactive_enter_sequence, "\x1b[?25l") == null);
    try std.testing.expect(std.mem.indexOf(u8, terminal.interactive_enter_sequence, "\x1b[?1049h") == null);
    try std.testing.expect(std.mem.indexOf(u8, terminal.interactive_exit_sequence, "\x1b[?1049l") == null);
    try std.testing.expect(std.mem.indexOf(u8, terminal.interactive_enter_sequence, "\x1b[?1000h") == null);
    try std.testing.expect(std.mem.indexOf(u8, terminal.interactive_enter_sequence, "\x1b[?1006h") == null);
    try std.testing.expect(std.mem.indexOf(u8, terminal.interactive_exit_sequence, "\x1b[?1000l") == null);
    try std.testing.expect(std.mem.indexOf(u8, terminal.interactive_exit_sequence, "\x1b[?1006l") == null);
    try std.testing.expect(std.mem.indexOf(u8, terminal.interactive_enter_sequence, "\x1b[?1007h") == null);
    try std.testing.expect(std.mem.indexOf(u8, terminal.interactive_exit_sequence, "\x1b[?1007l") == null);
}
