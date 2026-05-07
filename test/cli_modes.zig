const std = @import("std");
const pig = @import("pig");
const cli = pig.app.cli;
const agent = pig.core.agent;
const provider = pig.provider;
const session = pig.session;

test "print mode streams assistant text to stdout" {
    const turn = [_]provider.ProviderEvent{
        .{ .message_start = .{ .role = .assistant } },
        .{ .text_delta = .{ .text = "hello" } },
        .{ .text_delta = .{ .text = " world" } },
        .message_end,
        .done,
    };
    const turns = [_][]const provider.ProviderEvent{&turn};
    var model = agent.model_client.ScriptedModelClient{ .turns = &turns };

    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const code = try cli.runWithContext(&.{ "--print", "hi", "--no-tools" }, .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .model_client = model.client(),
    }, &stdout.writer, &stderr.writer);

    try std.testing.expectEqual(cli.ExitCode.ok, code);
    try std.testing.expectEqualStrings("hello world", stdout.written());
    try std.testing.expectEqualStrings("", stderr.written());
}

test "json print mode emits newline-delimited event objects" {
    const turn = [_]provider.ProviderEvent{
        .{ .message_start = .{ .role = .assistant } },
        .{ .text_delta = .{ .text = "json ok" } },
        .message_end,
        .done,
    };
    const turns = [_][]const provider.ProviderEvent{&turn};
    var model = agent.model_client.ScriptedModelClient{ .turns = &turns };

    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const code = try cli.runWithContext(&.{ "--json", "--print", "hi", "--no-tools" }, .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .model_client = model.client(),
    }, &stdout.writer, &stderr.writer);

    try std.testing.expectEqual(cli.ExitCode.ok, code);
    try std.testing.expectEqualStrings("", stderr.written());
    try expectJsonLineTypes(stdout.written(), &.{ "agent_start", "turn_start", "message_start", "message_delta", "message_end", "turn_end", "agent_end" });
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "\"text_delta\":\"json ok\"") != null);
}

test "print mode exposes builtin tools to the model" {
    var tc = try pig.tools.testing.TempToolContext.init(std.testing.allocator);
    defer tc.deinit();
    try tc.writeFile("main.txt", "hello from cli tool\n");

    const turn1 = [_]provider.ProviderEvent{
        .{ .message_start = .{ .role = .assistant } },
        .{ .tool_call_end = .{ .index = 0, .id = "call_1", .name = "read", .arguments_json = "{\"path\":\"main.txt\"}" } },
        .message_end,
        .done,
    };
    const turn2 = [_]provider.ProviderEvent{
        .{ .message_start = .{ .role = .assistant } },
        .{ .text_delta = .{ .text = "read done" } },
        .message_end,
        .done,
    };
    const turns = [_][]const provider.ProviderEvent{ &turn1, &turn2 };
    var model = agent.model_client.ScriptedModelClient{ .turns = &turns };

    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const code = try cli.runWithContext(&.{ "--print", "read main.txt", "--cwd", tc.workspace_root }, .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .model_client = model.client(),
    }, &stdout.writer, &stderr.writer);

    try std.testing.expectEqual(cli.ExitCode.ok, code);
    try std.testing.expectEqualStrings("read done", stdout.written());
    try std.testing.expect(std.mem.indexOf(u8, stderr.written(), "tool: read") != null);
    try std.testing.expectEqual(@as(usize, 4), model.last_tool_count);
}

test "print mode without model client fails clearly" {
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const code = try cli.runWithContext(&.{ "--print", "hi", "--no-tools" }, .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
    }, &stdout.writer, &stderr.writer);

    try std.testing.expectEqual(cli.ExitCode.failure, code);
    try std.testing.expectEqualStrings("", stdout.written());
    try std.testing.expect(std.mem.indexOf(u8, stderr.written(), "no model selected") != null);
}

test "explicit session fails instead of being ignored when io is unavailable" {
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

    const code = try cli.runWithContext(&.{ "--print", "hi", "--no-tools", "--session", "missing" }, .{
        .allocator = std.testing.allocator,
        .model_client = model.client(),
    }, &stdout.writer, &stderr.writer);

    try std.testing.expectEqual(cli.ExitCode.failure, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr.written(), "failed to open session") != null);
}

test "print mode records a default session when home is available" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const home = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(home);

    const turn = [_]provider.ProviderEvent{
        .{ .message_start = .{ .role = .assistant } },
        .{ .text_delta = .{ .text = "saved" } },
        .message_end,
        .done,
    };
    const turns = [_][]const provider.ProviderEvent{&turn};
    var model = agent.model_client.ScriptedModelClient{ .turns = &turns };

    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const code = try cli.runWithContext(&.{ "--print", "persist", "--no-tools" }, .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .env_home = home,
        .model_client = model.client(),
    }, &stdout.writer, &stderr.writer);

    try std.testing.expectEqual(cli.ExitCode.ok, code);
    const sessions_dir = try std.fs.path.join(std.testing.allocator, &.{ home, ".pig/agent/sessions" });
    defer std.testing.allocator.free(sessions_dir);
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, sessions_dir, .{ .iterate = true });
    defer dir.close(std.testing.io);
    var it = dir.iterate();
    const entry = (try it.next(std.testing.io)) orelse return error.TestExpectedEqual;
    try std.testing.expect(std.mem.endsWith(u8, entry.name, ".jsonl"));
    const bytes = try dir.readFileAlloc(std.testing.io, entry.name, std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"kind\":\"header\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"role\":\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"role\":\"assistant\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "saved") != null);
}

test "print mode appends to explicit session without duplicate entry ids" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root);
    const sessions_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "sessions" });
    defer std.testing.allocator.free(sessions_dir);

    var store = try session.store.create(std.testing.allocator, std.testing.io, .{
        .sessions_dir = sessions_dir,
        .session_id = "fixed_session",
        .cwd = root,
        .created_ms = 0,
        .policy = .flush_only,
    });
    const existing_blocks = [_]session.entry.ContentBlock{.{ .text = .{ .text = "existing" } }};
    try store.append(.{
        .id = "entry_3",
        .session_id = "fixed_session",
        .parent_id = store.currentLeaf(),
        .created_ms = 0,
        .data = .{ .message = .{ .role = .user, .content = &existing_blocks } },
    });
    const session_path = try std.testing.allocator.dupe(u8, store.path);
    store.deinit();
    defer std.testing.allocator.free(session_path);

    const turn = [_]provider.ProviderEvent{
        .{ .message_start = .{ .role = .assistant } },
        .{ .text_delta = .{ .text = "appended" } },
        .message_end,
        .done,
    };
    const turns = [_][]const provider.ProviderEvent{&turn};
    var model = agent.model_client.ScriptedModelClient{ .turns = &turns };

    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const code = try cli.runWithContext(&.{ "--print", "again", "--no-tools", "--session", session_path }, .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .model_client = model.client(),
    }, &stdout.writer, &stderr.writer);

    try std.testing.expectEqual(cli.ExitCode.ok, code);
    try std.testing.expectEqualStrings("appended", stdout.written());
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, session_path, std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"id\":\"entry_3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"id\":\"entry_4\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "appended") != null);
}

fn expectJsonLineTypes(output: []const u8, expected: []const []const u8) !void {
    var it = std.mem.splitScalar(u8, output, '\n');
    var index: usize = 0;
    while (it.next()) |line| {
        if (line.len == 0) continue;
        try std.testing.expect(index < expected.len);
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
        defer parsed.deinit();
        const root = parsed.value.object;
        try std.testing.expectEqual(@as(i64, 1), root.get("schema").?.integer);
        try std.testing.expectEqualStrings(expected[index], root.get("type").?.string);
        try std.testing.expectEqualStrings("ephemeral", root.get("session_id").?.string);
        index += 1;
    }
    try std.testing.expectEqual(expected.len, index);
}
