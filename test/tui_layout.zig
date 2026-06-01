const std = @import("std");
const pig = @import("pig");
const layout = pig.tui.layout;
const components = pig.tui.components;

test "layout wraps text and handles narrow widths" {
    const lines = try layout.wrapText(std.testing.allocator, "abcdef", 2);
    defer layout.freeLines(std.testing.allocator, lines);

    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqualStrings("ab", lines[0]);
    try std.testing.expectEqualStrings("cd", lines[1]);
    try std.testing.expectEqualStrings("ef", lines[2]);
}

fn wrapTextWithAllocator(allocator: std.mem.Allocator) !void {
    const lines = try layout.wrapText(allocator, "alpha\nbravo charlie delta echo foxtrot", 4);
    layout.freeLines(allocator, lines);
}

test "layout wrapText cleans up partial allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, wrapTextWithAllocator, .{});
}

test "layout treats wide characters conservatively" {
    try std.testing.expectEqual(@as(usize, 5), layout.displayWidth("中a中"));
}

test "layout treats combining marks and emoji width consistently" {
    try std.testing.expectEqual(@as(usize, 1), layout.displayWidth("\t"));
    try std.testing.expectEqual(@as(usize, 1), layout.displayWidth("e\u{301}"));
    try std.testing.expectEqual(@as(usize, 2), layout.displayWidth("🙂"));
    try std.testing.expectEqual(@as(usize, 2), layout.displayWidth("🚀"));
    try std.testing.expectEqual(@as(usize, 2), layout.displayWidth("❤️"));
    try std.testing.expectEqual(@as(usize, 2), layout.displayWidth("👩‍💻"));
    try std.testing.expectEqual(@as(usize, 2), layout.displayWidth("🇺🇸"));
    try std.testing.expectEqual(@as(usize, 2), layout.displayWidth("1️⃣"));
    try std.testing.expectEqual(@as(usize, 3), layout.displayWidth("🙂‍a"));
}

test "components render cancellable loader and settings list" {
    const loader = try components.renderPlain(std.testing.allocator, components.cancellableLoader("running"));
    defer std.testing.allocator.free(loader);
    try std.testing.expect(std.mem.indexOf(u8, loader, "Ctrl+C") != null);

    const settings = try components.renderPlain(std.testing.allocator, .{ .kind = .settings_list, .text = "model" });
    defer std.testing.allocator.free(settings);
    try std.testing.expect(std.mem.indexOf(u8, settings, "settings: model") != null);
}
