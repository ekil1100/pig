const std = @import("std");
const pig = @import("pig");
const render = pig.tui.render;

test "renderer emits full frame with cursor" {
    var frame = render.Frame.init(std.testing.allocator, .{ .width = 20, .height = 4 });
    defer frame.deinit();
    try frame.appendLine("hello");
    frame.cursor = .{ .row = 0, .col = 5 };

    const bytes = try render.renderFull(std.testing.allocator, &frame);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.startsWith(u8, bytes, "\x1b[2J\x1b[H"));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[1;6H") != null);
}

test "renderer full frame maps logical rows through viewport" {
    var frame = render.Frame.init(std.testing.allocator, .{ .width = 20, .height = 2 });
    defer frame.deinit();
    try frame.appendLine("hidden");
    try frame.appendLine("visible");
    try frame.appendLine("> input");
    frame.cursor = .{ .row = 2, .col = 7 };

    const bytes = try render.renderFull(std.testing.allocator, &frame);
    defer std.testing.allocator.free(bytes);

    try std.testing.expect(std.mem.indexOf(u8, bytes, "hidden") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "visible") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[2;8H") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[3;8H") == null);
}

test "renderer document snapshot includes all logical rows" {
    var frame = render.Frame.init(std.testing.allocator, .{ .width = 20, .height = 2 });
    defer frame.deinit();
    try frame.appendLine("hidden");
    try frame.appendLine("visible");
    try frame.appendLine("> input");
    frame.cursor = .{ .row = 2, .col = 7 };

    const bytes = try render.renderDocument(std.testing.allocator, &frame);
    defer std.testing.allocator.free(bytes);

    try std.testing.expect(std.mem.indexOf(u8, bytes, "hidden") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "visible") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b[3;8H") != null);
}

test "renderer emits changed lines for diff and full redraw on resize" {
    var prev = render.Frame.init(std.testing.allocator, .{ .width = 20, .height = 4 });
    defer prev.deinit();
    try prev.appendLine("hello");

    var next = render.Frame.init(std.testing.allocator, .{ .width = 20, .height = 4 });
    defer next.deinit();
    try next.appendLine("world");

    const diff = try render.renderDiff(std.testing.allocator, &prev, &next);
    defer std.testing.allocator.free(diff);
    try std.testing.expect(std.mem.indexOf(u8, diff, "world") != null);

    var resized = render.Frame.init(std.testing.allocator, .{ .width = 10, .height = 4 });
    defer resized.deinit();
    try resized.appendLine("world");
    const full = try render.renderDiff(std.testing.allocator, &next, &resized);
    defer std.testing.allocator.free(full);
    try std.testing.expect(std.mem.startsWith(u8, full, "\x1b[2J"));
}

test "renderer diff clears stale trailing lines" {
    var prev = render.Frame.init(std.testing.allocator, .{ .width = 20, .height = 4 });
    defer prev.deinit();
    try prev.appendLine("hello");
    try prev.appendLine("stale");

    var next = render.Frame.init(std.testing.allocator, .{ .width = 20, .height = 4 });
    defer next.deinit();
    try next.appendLine("hello");

    const diff = try render.renderDiff(std.testing.allocator, &prev, &next);
    defer std.testing.allocator.free(diff);
    try std.testing.expect(std.mem.indexOf(u8, diff, "\x1b[2;1H\x1b[2K") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff, "stale") == null);
}

test "renderer diff maps logical rows through viewport" {
    var prev = render.Frame.init(std.testing.allocator, .{ .width = 20, .height = 2 });
    defer prev.deinit();
    try prev.appendLine("hidden");
    try prev.appendLine("old visible");
    try prev.appendLine("> input");
    prev.cursor = .{ .row = 2, .col = 7 };

    var next = render.Frame.init(std.testing.allocator, .{ .width = 20, .height = 2 });
    defer next.deinit();
    try next.appendLine("hidden");
    try next.appendLine("new visible");
    try next.appendLine("> input");
    next.cursor = .{ .row = 2, .col = 7 };

    const diff = try render.renderDiff(std.testing.allocator, &prev, &next);
    defer std.testing.allocator.free(diff);

    try std.testing.expect(std.mem.indexOf(u8, diff, "\x1b[1;1H\x1b[2Knew visible") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff, "\x1b[3;") == null);
}

test "terminal renderer owns viewport and maps cursor into visible rows" {
    var renderer = render.TerminalRenderer.init(std.testing.allocator);
    defer renderer.deinit();

    var frame = render.Frame.init(std.testing.allocator, .{ .width = 20, .height = 3 });
    defer frame.deinit();
    try frame.appendLine("line 0");
    try frame.appendLine("line 1");
    try frame.appendLine("line 2");
    try frame.appendLine("line 3");
    try frame.appendLine("> input");
    frame.cursor = .{ .row = 4, .col = 7 };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderer.render(&frame, &out.writer);

    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b[2J") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b[3J") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "line 0") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "line 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b[3;8H") != null);
}

test "terminal renderer appends tail growth to preserve scrollback" {
    var renderer = render.TerminalRenderer.init(std.testing.allocator);
    defer renderer.deinit();

    var first = render.Frame.init(std.testing.allocator, .{ .width = 20, .height = 3 });
    defer first.deinit();
    try first.appendLine("line 0");
    try first.appendLine("line 1");
    try first.appendLine("> input");
    first.cursor = .{ .row = 2, .col = 7 };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderer.render(&first, &out.writer);
    out.clearRetainingCapacity();

    var next = render.Frame.init(std.testing.allocator, .{ .width = 20, .height = 3 });
    defer next.deinit();
    try next.appendLine("line 0");
    try next.appendLine("line 1");
    try next.appendLine("line 2");
    try next.appendLine("> input");
    next.cursor = .{ .row = 3, .col = 7 };

    try renderer.render(&next, &out.writer);

    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b[2J") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "line 0") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "line 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "> input") != null);
}

test "terminal renderer clips hidden changes when viewport stays fixed" {
    var renderer = render.TerminalRenderer.init(std.testing.allocator);
    defer renderer.deinit();

    var first = render.Frame.init(std.testing.allocator, .{ .width = 20, .height = 2 });
    defer first.deinit();
    try first.appendLine("line 0");
    try first.appendLine("old visible");
    try first.appendLine("old hidden");
    first.viewport_top = 0;

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderer.render(&first, &out.writer);
    out.clearRetainingCapacity();

    var next = render.Frame.init(std.testing.allocator, .{ .width = 20, .height = 2 });
    defer next.deinit();
    try next.appendLine("line 0");
    try next.appendLine("new visible");
    try next.appendLine("new hidden");
    next.viewport_top = 0;

    try renderer.render(&next, &out.writer);

    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b[2J") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "new visible") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "new hidden") == null);
}

test "terminal renderer redraws when viewport changes without line changes" {
    var renderer = render.TerminalRenderer.init(std.testing.allocator);
    defer renderer.deinit();

    var first = render.Frame.init(std.testing.allocator, .{ .width = 20, .height = 2 });
    defer first.deinit();
    try first.appendLine("line 0");
    try first.appendLine("line 1");
    try first.appendLine("> input");
    first.cursor = .{ .row = 2, .col = 7 };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderer.render(&first, &out.writer);
    out.clearRetainingCapacity();

    var scrolled = render.Frame.init(std.testing.allocator, .{ .width = 20, .height = 2 });
    defer scrolled.deinit();
    try scrolled.appendLine("line 0");
    try scrolled.appendLine("line 1");
    try scrolled.appendLine("> input");
    scrolled.viewport_top = 0;
    scrolled.cursor = .{ .row = 2, .col = 7 };

    try renderer.render(&scrolled, &out.writer);

    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b[2J") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "line 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "> input") == null);
}

test "terminal renderer diffs same-size visible line changes" {
    var renderer = render.TerminalRenderer.init(std.testing.allocator);
    defer renderer.deinit();

    var first = render.Frame.init(std.testing.allocator, .{ .width = 20, .height = 4 });
    defer first.deinit();
    try first.appendLine("header");
    try first.appendLine("working");
    try first.appendLine("> input");
    first.cursor = .{ .row = 2, .col = 7 };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderer.render(&first, &out.writer);
    out.clearRetainingCapacity();

    var next = render.Frame.init(std.testing.allocator, .{ .width = 20, .height = 4 });
    defer next.deinit();
    try next.appendLine("header");
    try next.appendLine("done");
    try next.appendLine("> input");
    next.cursor = .{ .row = 2, .col = 7 };

    try renderer.render(&next, &out.writer);

    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b[2J") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b[2;1H\x1b[2Kdone") != null);
}
