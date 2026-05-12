const std = @import("std");
const pig = @import("pig");
const input = pig.tui.input;
const editor = pig.tui.editor;

test "editor supports multiline input and submit" {
    var state = editor.EditorState.init(std.testing.allocator);
    defer state.deinit();

    try state.insert("hello");
    _ = try state.handle(.{ .kind = .newline }, false);
    try state.insert("world");
    try std.testing.expectEqualStrings("hello\nworld", state.text());

    const result = try state.handle(.{ .kind = .enter }, false);
    switch (result) {
        .submit => |prompt| {
            defer state.freeSubmitted(prompt);
            try std.testing.expectEqualStrings("hello\nworld", prompt);
        },
        else => return error.TestExpectedEqual,
    }
    try std.testing.expectEqualStrings("", state.text());
}

test "editor moves through lines and history" {
    var state = editor.EditorState.init(std.testing.allocator);
    defer state.deinit();

    try state.insert("one");
    const first = try state.handle(.{ .kind = .enter }, false);
    if (first == .submit) state.freeSubmitted(first.submit);

    try state.insert("ab\ncd");
    state.cursor_byte = state.text().len;
    _ = try state.handle(.{ .kind = .arrow, .arrow = input.Direction.up }, false);
    try std.testing.expectEqual(@as(usize, 2), state.cursor_byte);
    _ = try state.handle(.{ .kind = .arrow, .arrow = input.Direction.up }, false);
    try std.testing.expectEqualStrings("one", state.text());
}

test "editor ctrl-c aborts only while busy" {
    var state = editor.EditorState.init(std.testing.allocator);
    defer state.deinit();

    try std.testing.expectEqual(editor.SubmitResult.exit, try state.handle(.{ .kind = .ctrl, .ctrl = 'c' }, false));
    try std.testing.expectEqual(editor.SubmitResult.abort, try state.handle(.{ .kind = .ctrl, .ctrl = 'c' }, true));
}

test "editor preserves busy input on enter" {
    var state = editor.EditorState.init(std.testing.allocator);
    defer state.deinit();

    try state.insert("next");
    try std.testing.expectEqual(editor.SubmitResult.none, try state.handle(.{ .kind = .enter }, true));
    try std.testing.expectEqualStrings("next", state.text());

    const result = try state.handle(.{ .kind = .enter }, false);
    switch (result) {
        .submit => |prompt| {
            defer state.freeSubmitted(prompt);
            try std.testing.expectEqualStrings("next", prompt);
        },
        else => return error.TestExpectedEqual,
    }
}

test "editor moves and deletes display units" {
    var state = editor.EditorState.init(std.testing.allocator);
    defer state.deinit();

    try state.insert("👩‍💻");
    _ = try state.handle(.{ .kind = .arrow, .arrow = input.Direction.left }, false);
    try std.testing.expectEqual(@as(usize, 0), state.cursor_byte);
    _ = try state.handle(.{ .kind = .arrow, .arrow = input.Direction.right }, false);
    try std.testing.expectEqual(state.text().len, state.cursor_byte);
    _ = try state.handle(.{ .kind = .backspace }, false);
    try std.testing.expectEqualStrings("", state.text());

    try state.insert("e\u{301}");
    _ = try state.handle(.{ .kind = .arrow, .arrow = input.Direction.left }, false);
    try std.testing.expectEqual(@as(usize, 0), state.cursor_byte);
    _ = try state.handle(.{ .kind = .delete }, false);
    try std.testing.expectEqualStrings("", state.text());
}

test "editor vertical movement snaps to display unit boundaries" {
    var state = editor.EditorState.init(std.testing.allocator);
    defer state.deinit();

    try state.insert("a\n中");
    state.cursor_byte = 1;
    _ = try state.handle(.{ .kind = .arrow, .arrow = input.Direction.down }, false);
    try std.testing.expectEqual(@as(usize, 2), state.cursor_byte);
    _ = try state.handle(.{ .kind = .delete }, false);
    try std.testing.expectEqualStrings("a\n", state.text());

    var state2 = editor.EditorState.init(std.testing.allocator);
    defer state2.deinit();
    try state2.insert("e\u{301}\n👩‍💻");
    state2.cursor_byte = state2.text().len;
    _ = try state2.handle(.{ .kind = .arrow, .arrow = input.Direction.up }, false);
    try std.testing.expectEqual("e\u{301}".len, state2.cursor_byte);
}

test "editor does not merge invalid zwj text into emoji unit" {
    var state = editor.EditorState.init(std.testing.allocator);
    defer state.deinit();

    try state.insert("🙂‍a");
    _ = try state.handle(.{ .kind = .backspace }, false);
    try std.testing.expectEqualStrings("🙂‍", state.text());
}
