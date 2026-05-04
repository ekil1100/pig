const std = @import("std");
const pig = @import("pig");
const cli = pig.app.cli;
const agent = pig.core.agent;
const provider = pig.provider;

test "interactive mode runs scripted model and renders transcript" {
    const turn = [_]provider.ProviderEvent{
        .{ .message_start = .{ .role = .assistant } },
        .{ .text_delta = .{ .text = "hi there" } },
        .message_end,
        .done,
    };
    const turns = [_][]const provider.ProviderEvent{&turn};
    var model = agent.model_client.ScriptedModelClient{ .turns = &turns };

    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const code = try cli.runWithContext(&.{ "--interactive", "--ephemeral", "--no-tools" }, .{
        .allocator = std.testing.allocator,
        .model_client = model.client(),
        .interactive_input = "hello\rquit\r",
        .terminal_size = .{ .width = 40, .height = 8 },
    }, &stdout.writer, &stderr.writer);

    try std.testing.expectEqual(cli.ExitCode.ok, code);
    try std.testing.expectEqualStrings("", stderr.written());
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "you: hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "pig: hi there") != null);
}

test "interactive mode preserves message history across turns" {
    const first = [_]provider.ProviderEvent{
        .{ .message_start = .{ .role = .assistant } },
        .{ .text_delta = .{ .text = "first answer" } },
        .message_end,
        .done,
    };
    const second = [_]provider.ProviderEvent{
        .{ .message_start = .{ .role = .assistant } },
        .{ .text_delta = .{ .text = "second answer" } },
        .message_end,
        .done,
    };
    const turns = [_][]const provider.ProviderEvent{ &first, &second };
    var model = agent.model_client.ScriptedModelClient{ .turns = &turns };

    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const code = try cli.runWithContext(&.{ "--interactive", "--ephemeral", "--no-tools" }, .{
        .allocator = std.testing.allocator,
        .model_client = model.client(),
        .interactive_input = "first\rsecond\rquit\r",
        .terminal_size = .{ .width = 48, .height = 10 },
    }, &stdout.writer, &stderr.writer);

    try std.testing.expectEqual(cli.ExitCode.ok, code);
    try std.testing.expectEqual(@as(usize, 2), model.request_count);
    try std.testing.expectEqual(@as(usize, 3), model.last_message_count);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "pig: first answer") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "pig: second answer") != null);
}

test "interactive mode reports missing model without unsupported skeleton" {
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const code = try cli.runWithContext(&.{"--interactive"}, .{
        .allocator = std.testing.allocator,
    }, &stdout.writer, &stderr.writer);

    try std.testing.expectEqual(cli.ExitCode.failure, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr.written(), "model client unavailable") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr.written(), "not implemented") == null);
}

test "no arguments start interactive mode" {
    const turn = [_]provider.ProviderEvent{
        .{ .message_start = .{ .role = .assistant } },
        .{ .text_delta = .{ .text = "default tui" } },
        .message_end,
        .done,
    };
    const turns = [_][]const provider.ProviderEvent{&turn};
    var model = agent.model_client.ScriptedModelClient{ .turns = &turns };

    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const code = try cli.runWithContext(&.{}, .{
        .allocator = std.testing.allocator,
        .model_client = model.client(),
        .interactive_input = "hello\rquit\r",
        .terminal_size = .{ .width = 40, .height = 8 },
    }, &stdout.writer, &stderr.writer);

    try std.testing.expectEqual(cli.ExitCode.ok, code);
    try std.testing.expectEqual(@as(usize, 1), model.request_count);
    try std.testing.expectEqualStrings("", stderr.written());
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "pig: default tui") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "Pig v1.0") == null);
}

test "interactive mode fails clearly when terminal input is unavailable" {
    const turn = [_]provider.ProviderEvent{
        .{ .message_start = .{ .role = .assistant } },
        .{ .text_delta = .{ .text = "unused" } },
        .message_end,
        .done,
    };
    const turns = [_][]const provider.ProviderEvent{&turn};
    var model = agent.model_client.ScriptedModelClient{ .turns = &turns };

    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const code = try cli.runWithContext(&.{ "--interactive", "--ephemeral", "--no-tools" }, .{
        .allocator = std.testing.allocator,
        .model_client = model.client(),
    }, &stdout.writer, &stderr.writer);

    try std.testing.expectEqual(cli.ExitCode.failure, code);
    try std.testing.expectEqual(@as(usize, 0), model.request_count);
    try std.testing.expect(std.mem.indexOf(u8, stderr.written(), "interactive terminal input is unavailable") != null);
}

test "interactive app preserves editor input while busy and supports abort" {
    var app = pig.app.interactive.InteractiveApp.init(std.testing.allocator, .{ .width = 40, .height = 8 }, .{});
    defer app.deinit();
    app.worker.busy = true;

    _ = try app.handleInput(.{ .kind = .char, .text = "n" });
    _ = try app.handleInput(.{ .kind = .char, .text = "e" });
    _ = try app.handleInput(.{ .kind = .char, .text = "x" });
    _ = try app.handleInput(.{ .kind = .char, .text = "t" });
    try std.testing.expectEqualStrings("next", app.editor.text());

    const result = try app.handleInput(.{ .kind = .ctrl, .ctrl = 'c' });
    try std.testing.expectEqual(pig.tui.editor.SubmitResult.abort, result);
}

test "interactive event queue owns text and enforces capacity" {
    var queue = pig.app.interactive.InteractiveEventQueue.init(std.testing.allocator);
    defer queue.deinit();
    queue.capacity = 1;

    var source = try std.testing.allocator.dupe(u8, "hello");
    defer std.testing.allocator.free(source);
    try queue.push(.assistant, source, true);
    source[0] = 'j';

    try std.testing.expectError(error.QueueFull, queue.push(.status, "busy", false));

    var event = queue.popFront().?;
    defer event.deinit(std.testing.allocator);
    try std.testing.expectEqual(pig.app.interactive.InteractiveEventKind.assistant, event.kind);
    try std.testing.expectEqualStrings("hello", event.text.items);
    try std.testing.expect(event.is_streaming);
    try std.testing.expect(queue.popFront() == null);
}
