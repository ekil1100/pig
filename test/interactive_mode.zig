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

test "interactive render does not append newline after cursor positioning" {
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
    try std.testing.expect(!std.mem.endsWith(u8, stdout.written(), "\n"));
}

test "interactive mode renders thinking separately and keeps user input visible" {
    const turn = [_]provider.ProviderEvent{
        .{ .message_start = .{ .role = .assistant } },
        .{ .thinking_delta = .{ .text = "checking context" } },
        .{ .text_delta = .{ .text = "done" } },
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
        .terminal_size = .{ .width = 80, .height = 10 },
    }, &stdout.writer, &stderr.writer);

    try std.testing.expectEqual(cli.ExitCode.ok, code);
    try std.testing.expectEqualStrings("", stderr.written());
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "you: hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "thinking: checking context") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "pig: done") != null);
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

test "interactive mode executes builtin tools and renders tool result" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root);
    const readme_relative = try std.fs.path.join(std.testing.allocator, &.{ root, "README.md" });
    defer std.testing.allocator.free(readme_relative);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = readme_relative, .data = "hello interactive tools\n" });
    const cwd = try pig.util.paths.cwd(std.testing.allocator, std.testing.io);
    defer std.testing.allocator.free(cwd);
    const root_absolute = try std.fs.path.join(std.testing.allocator, &.{ cwd, root });
    defer std.testing.allocator.free(root_absolute);
    const readme_absolute = try std.fs.path.join(std.testing.allocator, &.{ root_absolute, "README.md" });
    defer std.testing.allocator.free(readme_absolute);
    const tool_args = try std.fmt.allocPrint(std.testing.allocator, "{{\"path\":\"{s}\"}}", .{readme_absolute});
    defer std.testing.allocator.free(tool_args);

    var first = [_]provider.ProviderEvent{
        .{ .message_start = .{ .role = .assistant } },
        .{ .tool_call_end = .{ .index = 0, .id = "call_1", .name = "read", .arguments_json = tool_args } },
        .message_end,
        .done,
    };
    const second = [_]provider.ProviderEvent{
        .{ .message_start = .{ .role = .assistant } },
        .{ .text_delta = .{ .text = "read complete" } },
        .message_end,
        .done,
    };
    const turns = [_][]const provider.ProviderEvent{ &first, &second };
    var model = agent.model_client.ScriptedModelClient{ .turns = &turns };

    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const code = try cli.runWithContext(&.{ "--interactive", "--ephemeral", "--cwd", root_absolute }, .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .model_client = model.client(),
        .interactive_input = "show readme\rquit\r",
        .terminal_size = .{ .width = 120, .height = 24 },
    }, &stdout.writer, &stderr.writer);

    try std.testing.expectEqual(cli.ExitCode.ok, code);
    try std.testing.expectEqualStrings("", stderr.written());
    try std.testing.expectEqual(@as(usize, 2), model.request_count);
    try std.testing.expect(model.last_tool_count > 0);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "you: show readme") != null);
    const expected_tool_line = try std.fmt.allocPrint(std.testing.allocator, "tool: read {s}", .{readme_absolute});
    defer std.testing.allocator.free(expected_tool_line);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), expected_tool_line) != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "path is outside workspace or invalid") == null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "hello interactive tools") == null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "read complete") != null);
}

test "interactive mode allows builtin bash execution" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root);

    const first = [_]provider.ProviderEvent{
        .{ .message_start = .{ .role = .assistant } },
        .{ .tool_call_end = .{ .index = 0, .id = "call_1", .name = "bash", .arguments_json = "{\"command\":\"printf shell-ok\"}" } },
        .message_end,
        .done,
    };
    const second = [_]provider.ProviderEvent{
        .{ .message_start = .{ .role = .assistant } },
        .{ .text_delta = .{ .text = "bash complete" } },
        .message_end,
        .done,
    };
    const turns = [_][]const provider.ProviderEvent{ &first, &second };
    var model = agent.model_client.ScriptedModelClient{ .turns = &turns };

    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const code = try cli.runWithContext(&.{ "--interactive", "--ephemeral", "--cwd", root }, .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .model_client = model.client(),
        .interactive_input = "run shell\rquit\r",
        .terminal_size = .{ .width = 120, .height = 24 },
    }, &stdout.writer, &stderr.writer);

    try std.testing.expectEqual(cli.ExitCode.ok, code);
    try std.testing.expectEqualStrings("", stderr.written());
    try std.testing.expectEqual(@as(usize, 2), model.request_count);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "tool: bash printf shell-ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "tool: error approval denied") == null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "bash complete") != null);
}

test "scripted interactive renderer scrolls transcript with page keys" {
    const turn = [_]provider.ProviderEvent{
        .{ .message_start = .{ .role = .assistant } },
        .{ .text_delta = .{ .text = "line1\nline2\nline3\nline4\nline5" } },
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
        .interactive_input = "hello\r\x1b[5~quit\r",
        .terminal_size = .{ .width = 80, .height = 4 },
    }, &stdout.writer, &stderr.writer);

    try std.testing.expectEqual(cli.ExitCode.ok, code);
    try std.testing.expectEqualStrings("", stderr.written());
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "pig: line1") != null);
}

test "scripted interactive renderer scrolls transcript with decoded mouse wheel events" {
    const turn = [_]provider.ProviderEvent{
        .{ .message_start = .{ .role = .assistant } },
        .{ .text_delta = .{ .text = "line1\nline2\nline3\nline4\nline5" } },
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
        .interactive_input = "hello\r\x1b[<64;10;20Mquit\r",
        .terminal_size = .{ .width = 80, .height = 4 },
    }, &stdout.writer, &stderr.writer);

    try std.testing.expectEqual(cli.ExitCode.ok, code);
    try std.testing.expectEqualStrings("", stderr.written());
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "pig: line1") != null);
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

test "interactive mode starts without a default model and prompts for setup" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root);

    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const code = try cli.runWithContext(&.{"--interactive"}, .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .env_home = root,
        .interactive_input = "/model\rquit\r",
        .terminal_size = .{ .width = 96, .height = 20 },
    }, &stdout.writer, &stderr.writer);

    try std.testing.expectEqual(cli.ExitCode.ok, code);
    try std.testing.expectEqualStrings("", stderr.written());
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "no model selected") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "current model:") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "none") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "run /login or set a provider API key") != null);
}

test "interactive model selector only shows configured provider models" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root);
    var env = provider.auth.TestEnv.init(&.{.{ .key = "DEEPSEEK_API_KEY", .value = "test-key" }});

    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const code = try cli.runWithContext(&.{"--interactive"}, .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .env_home = root,
        .env = env.reader(),
        .interactive_input = "/model\rquit\r",
        .terminal_size = .{ .width = 96, .height = 20 },
    }, &stdout.writer, &stderr.writer);

    try std.testing.expectEqual(cli.ExitCode.ok, code);
    try std.testing.expectEqualStrings("", stderr.written());
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "deepseek-v4-flash") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "deepseek-v4-pro") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "gpt-4.1-mini") == null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "run /login") == null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "use /model <model-id>") != null);
}

test "interactive model selection persists to global settings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root);
    var env = provider.auth.TestEnv.init(&.{.{ .key = "DEEPSEEK_API_KEY", .value = "test-key" }});

    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const code = try cli.runWithContext(&.{ "--interactive", "--cwd", root }, .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .env_home = root,
        .env = env.reader(),
        .interactive_input = "/model deepseek-v4-flash\rquit\r",
        .terminal_size = .{ .width = 96, .height = 20 },
    }, &stdout.writer, &stderr.writer);

    try std.testing.expectEqual(cli.ExitCode.ok, code);
    try std.testing.expectEqualStrings("", stderr.written());
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "model selected: deepseek-v4-flash (saved)") != null);

    const settings_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/.pig/agent/settings.json", .{root});
    defer std.testing.allocator.free(settings_path);
    const saved = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, settings_path, std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(saved);
    try std.testing.expect(std.mem.indexOf(u8, saved, "\"provider\": \"deepseek\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, saved, "\"model\": \"deepseek-v4-flash\"") != null);
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

test "interactive render tracks editor cursor inside input" {
    var app = pig.app.interactive.InteractiveApp.init(std.testing.allocator, .{ .width = 40, .height = 8 }, .{});
    defer app.deinit();

    _ = try app.handleInput(.{ .kind = .char, .text = "a" });
    _ = try app.handleInput(.{ .kind = .char, .text = "b" });
    _ = try app.handleInput(.{ .kind = .char, .text = "c" });
    _ = try app.handleInput(.{ .kind = .char, .text = "d" });
    _ = try app.handleInput(.{ .kind = .arrow, .arrow = pig.tui.input.Direction.left });
    _ = try app.handleInput(.{ .kind = .arrow, .arrow = pig.tui.input.Direction.left });

    var frame = try app.renderFrame();
    defer frame.deinit();

    try std.testing.expect(frame.cursor != null);
    try std.testing.expectEqual(@as(usize, 0), frame.cursor.?.row);
    try std.testing.expectEqual(@as(usize, 4), frame.cursor.?.col);
}

test "interactive app saturates repeated upward scroll" {
    var app = pig.app.interactive.InteractiveApp.init(std.testing.allocator, .{ .width = 40, .height = 8 }, .{});
    defer app.deinit();
    app.scroll_offset = std.math.maxInt(usize) - 1;

    _ = try app.handleInput(.{ .kind = .mouse_scroll, .mouse_scroll = .up });

    try std.testing.expectEqual(std.math.maxInt(usize), app.scroll_offset);
}

test "interactive render keeps transcript order when transcript overflows" {
    var app = pig.app.interactive.InteractiveApp.init(std.testing.allocator, .{ .width = 80, .height = 6 }, .{});
    defer app.deinit();

    try appendTranscriptForTest(&app, .user, "inspect this project");
    try appendTranscriptForTest(&app, .assistant, "I will inspect the project.");
    try appendTranscriptForTest(&app, .tool, "bash ls -la /tmp/project");
    try appendTranscriptForTest(&app, .tool, "read /tmp/project/build.zig");
    try appendTranscriptForTest(&app, .tool, "read /tmp/project/README.md");
    try appendTranscriptForTest(&app, .tool, "read /tmp/project/src/main.zig");
    try appendTranscriptForTest(&app, .assistant, "final answer");

    var frame = try app.renderFrame();
    defer frame.deinit();

    try std.testing.expectEqualStrings("you: inspect this project", frame.lines.items[0]);
    try std.testing.expect(frameContains(&frame, "tool: bash ls -la /tmp/project"));
    try std.testing.expect(frameContains(&frame, "pig: final answer"));
}

test "interactive render applies scroll offset to viewport" {
    var app = pig.app.interactive.InteractiveApp.init(std.testing.allocator, .{ .width = 80, .height = 3 }, .{});
    defer app.deinit();

    try appendTranscriptForTest(&app, .user, "first");
    try appendTranscriptForTest(&app, .assistant, "second");
    try appendTranscriptForTest(&app, .tool, "third");
    try appendTranscriptForTest(&app, .assistant, "fourth");
    try appendTranscriptForTest(&app, .assistant, "fifth");
    app.scroll_offset = 2;

    var frame = try app.renderFrame();
    defer frame.deinit();

    try std.testing.expectEqual(@as(?usize, 1), frame.viewport_top);
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

fn appendTranscriptForTest(app: *pig.app.interactive.InteractiveApp, kind: pig.app.interactive.InteractiveEventKind, text: []const u8) !void {
    var item_text: std.ArrayList(u8) = .empty;
    errdefer item_text.deinit(std.testing.allocator);
    try item_text.appendSlice(std.testing.allocator, text);
    try app.transcript.append(std.testing.allocator, .{ .kind = kind, .text = item_text, .is_streaming = false });
}

fn frameContains(frame: *const pig.tui.render.Frame, needle: []const u8) bool {
    for (frame.lines.items) |line| {
        if (std.mem.indexOf(u8, line, needle) != null) return true;
    }
    return false;
}

test "interactive tool formatting is semantic" {
    const bash = try pig.app.interactive.toolStartText(std.testing.allocator, "bash", "{\"command\":\"ls -la\"}");
    defer std.testing.allocator.free(bash);
    try std.testing.expectEqualStrings("bash ls -la", bash);

    const read = try pig.app.interactive.toolStartText(std.testing.allocator, "read", "{\"path\":\"src/main.zig\"}");
    defer std.testing.allocator.free(read);
    try std.testing.expectEqualStrings("read src/main.zig", read);

    const grep = try pig.app.interactive.toolStartText(std.testing.allocator, "grep", "{\"pattern\":\"TODO\",\"path\":\"src\"}");
    defer std.testing.allocator.free(grep);
    try std.testing.expectEqualStrings("grep TODO in src", grep);

    const reason = try pig.app.interactive.toolErrorText(std.testing.allocator, "{\"ok\":false,\"error\":{\"code\":\"approval_denied\",\"message\":\"approval denied\"}}");
    defer std.testing.allocator.free(reason);
    try std.testing.expectEqualStrings("approval denied", reason);
}
