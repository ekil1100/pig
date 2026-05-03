const std = @import("std");
const pig = @import("pig");

const store = pig.session.store;
const tree = pig.session.tree;

test "session fixtures rebuild trees" {
    const fixture_paths = [_][]const u8{
        "fixtures/session/simple-linear.jsonl",
        "fixtures/session/tool-turn.jsonl",
        "fixtures/session/branched.jsonl",
    };

    for (fixture_paths) |path| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(bytes);
        var entries: std.ArrayList(pig.session.entry.Entry) = .empty;
        defer {
            for (entries.items) |*entry| entry.deinit(std.testing.allocator);
            entries.deinit(std.testing.allocator);
        }
        const load_info = try store.parseJsonl(std.testing.allocator, bytes, &entries);
        try std.testing.expect(!load_info.recovered_partial_final_line);
        try std.testing.expectEqual(bytes.len, load_info.valid_prefix_len);
        var rebuilt = try tree.rebuild(std.testing.allocator, entries.items);
        defer rebuilt.deinit();
        try std.testing.expectEqualStrings("entry_root", rebuilt.root_id);
    }
}

test "partial final line fixture recovers valid prefix" {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "fixtures/session/partial-final-line.jsonl", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(bytes);
    var entries: std.ArrayList(pig.session.entry.Entry) = .empty;
    defer {
        for (entries.items) |*entry| entry.deinit(std.testing.allocator);
        entries.deinit(std.testing.allocator);
    }
    const load_info = try store.parseJsonl(std.testing.allocator, bytes, &entries);
    try std.testing.expect(load_info.recovered_partial_final_line);
    try std.testing.expect(load_info.valid_prefix_len < bytes.len);
    try std.testing.expectEqual(@as(usize, 1), entries.items.len);
    var rebuilt = try tree.rebuild(std.testing.allocator, entries.items);
    defer rebuilt.deinit();
    try std.testing.expectEqualStrings("entry_root", rebuilt.current_leaf_id);
}

test "session tree rejects header with parent" {
    const lines = [_][]const u8{
        "{\"schema\":1,\"id\":\"entry_parent\",\"session_id\":\"session_bad\",\"parent_id\":null,\"kind\":\"message\",\"created_ms\":1,\"role\":\"user\",\"content\":[]}",
        "{\"schema\":1,\"id\":\"entry_root\",\"session_id\":\"session_bad\",\"parent_id\":\"entry_parent\",\"kind\":\"header\",\"created_ms\":2}",
    };
    var entries: std.ArrayList(pig.session.entry.Entry) = .empty;
    defer {
        for (entries.items) |*entry| entry.deinit(std.testing.allocator);
        entries.deinit(std.testing.allocator);
    }
    for (lines) |line| {
        var parsed = try pig.session.entry.parseLine(std.testing.allocator, line);
        errdefer parsed.deinit(std.testing.allocator);
        try entries.append(std.testing.allocator, parsed);
    }
    try std.testing.expectError(error.InvalidRoot, tree.rebuild(std.testing.allocator, entries.items));
}
