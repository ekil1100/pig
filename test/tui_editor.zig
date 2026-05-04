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
