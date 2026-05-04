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
