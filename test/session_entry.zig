const std = @import("std");
const pig = @import("pig");

const entry = pig.session.entry;

test "session entry round trips P0 kinds" {
    const blocks = [_]entry.ContentBlock{
        .{ .text = .{ .text = "hello" } },
        .{ .thinking = .{ .text = "plan", .signature = "sig" } },
        .{ .tool_call = .{ .id = "call_1", .name = "read", .arguments_json = "{\"path\":\"README.md\"}" } },
    };
    const cases = [_]entry.EntryView{
        .{ .id = "entry_root", .session_id = "session_1", .parent_id = null, .created_ms = 1, .data = .{ .header = .{ .cwd = "/tmp/pig", .title = "demo", .pig_version = "0.1.0" } } },
        .{ .id = "entry_msg", .session_id = "session_1", .parent_id = "entry_root", .created_ms = 2, .data = .{ .message = .{ .role = .assistant, .content = &blocks } } },
        .{ .id = "entry_tool_event", .session_id = "session_1", .parent_id = "entry_msg", .created_ms = 3, .data = .{ .tool_event = .{ .tool_call_id = "call_1", .tool_name = "read", .phase = "start" } } },
        .{ .id = "entry_tool_result", .session_id = "session_1", .parent_id = "entry_tool_event", .created_ms = 4, .data = .{ .tool_result = .{ .tool_call_id = "call_1", .is_error = false, .content_json = "{\"ok\":true}" } } },
        .{ .id = "entry_model", .session_id = "session_1", .parent_id = "entry_tool_result", .created_ms = 5, .data = .{ .model_change = .{ .provider = "openai_compatible", .model = "test-model" } } },
        .{ .id = "entry_thinking", .session_id = "session_1", .parent_id = "entry_model", .created_ms = 6, .data = .{ .thinking_level_change = .{ .level = "medium" } } },
        .{ .id = "entry_info", .session_id = "session_1", .parent_id = "entry_thinking", .created_ms = 7, .data = .{ .session_info = .{ .title = "renamed", .cwd = "/tmp/pig", .current_leaf_id = "entry_thinking" } } },
        .{ .id = "entry_label", .session_id = "session_1", .parent_id = "entry_info", .created_ms = 8, .data = .{ .label = .{ .text = "before refactor" } } },
        .{ .id = "entry_summary", .session_id = "session_1", .parent_id = "entry_label", .created_ms = 9, .data = .{ .branch_summary = .{ .target_id = "entry_label", .summary = "short branch" } } },
        .{ .id = "entry_compaction", .session_id = "session_1", .parent_id = "entry_summary", .created_ms = 10, .data = .{ .compaction = .{ .target_id = "entry_summary", .summary = "compressed" } } },
        .{ .id = "entry_custom", .session_id = "session_1", .parent_id = "entry_compaction", .created_ms = 11, .data = .{ .custom = .{ .name = "workflow", .payload_json = "{\"ok\":true}" } } },
    };

    for (cases) |case| {
        const line = try entry.writeLine(std.testing.allocator, case);
        defer std.testing.allocator.free(line);
        var parsed = try entry.parseLine(std.testing.allocator, line);
        defer parsed.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.kind(), parsed.kind());
        try std.testing.expectEqualStrings(case.id, parsed.id);
        try std.testing.expectEqualStrings(case.session_id, parsed.session_id);
    }
}

test "session entry rejects missing required fields" {
    const bad = "{\"schema\":1,\"id\":\"e\",\"session_id\":\"s\",\"parent_id\":null,\"kind\":\"message\",\"created_ms\":1}";
    try std.testing.expectError(error.InvalidEntry, entry.parseLine(std.testing.allocator, bad));
}

test "session entry rejects wrong typed known fields" {
    const bad_optional = "{\"schema\":1,\"id\":\"e\",\"session_id\":\"s\",\"parent_id\":null,\"kind\":\"header\",\"created_ms\":1,\"cwd\":42}";
    try std.testing.expectError(error.InvalidEntry, entry.parseLine(std.testing.allocator, bad_optional));

    const bad_bool = "{\"schema\":1,\"id\":\"e\",\"session_id\":\"s\",\"parent_id\":null,\"kind\":\"tool_result\",\"created_ms\":1,\"tool_call_id\":\"call_1\",\"is_error\":\"false\",\"content_json\":\"{}\"}";
    try std.testing.expectError(error.InvalidEntry, entry.parseLine(std.testing.allocator, bad_bool));
}
