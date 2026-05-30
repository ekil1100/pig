const std = @import("std");
const pig = @import("pig");

const entry = pig.session.entry;
const store = pig.session.store;

test "session store creates appends and reopens a tree" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root);
    const sessions_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "sessions" });
    defer std.testing.allocator.free(sessions_dir);

    var created = try store.create(std.testing.allocator, std.testing.io, .{
        .sessions_dir = sessions_dir,
        .session_id = "session_store",
        .cwd = root,
        .created_ms = 100,
        .policy = .flush_only,
    });

    const blocks = [_]entry.ContentBlock{.{ .text = .{ .text = "hi" } }};
    try created.append(.{
        .id = "entry_user",
        .session_id = "session_store",
        .parent_id = "entry_root",
        .created_ms = 101,
        .data = .{ .message = .{ .role = .user, .content = &blocks } },
    });
    try std.testing.expectEqualStrings("entry_user", created.currentLeaf());
    const path = try std.testing.allocator.dupe(u8, created.path);
    defer std.testing.allocator.free(path);
    created.deinit();

    var reopened = try store.open(std.testing.allocator, std.testing.io, .{ .path = path, .policy = .flush_only });
    defer reopened.deinit();
    try std.testing.expect(!reopened.recovered_partial_final_line);
    try std.testing.expectEqual(@as(usize, 2), reopened.entries.items.len);
    try std.testing.expectEqualStrings("entry_root", reopened.tree.root_id);
    try std.testing.expectEqualStrings("entry_user", reopened.tree.current_leaf_id);
    try std.testing.expectEqual(@as(usize, 1), reopened.tree.childrenOf("entry_root").len);
}

test "session store ignores invalid final partial line" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "partial.jsonl" });
    defer std.testing.allocator.free(path);

    const header = entry.EntryView{
        .id = "entry_root",
        .session_id = "session_partial",
        .parent_id = null,
        .created_ms = 1,
        .data = .{ .header = .{ .cwd = root } },
    };
    const line = try entry.writeLine(std.testing.allocator, header);
    defer std.testing.allocator.free(line);
    const bytes = try std.mem.concat(std.testing.allocator, u8, &.{ line, "\n", "{\"schema\":1" });
    defer std.testing.allocator.free(bytes);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = bytes });

    var opened = try store.open(std.testing.allocator, std.testing.io, .{ .path = path, .policy = .flush_only });
    try std.testing.expect(opened.recovered_partial_final_line);
    try std.testing.expectEqual(@as(usize, 1), opened.entries.items.len);
    try std.testing.expectEqualStrings("entry_root", opened.currentLeaf());

    const blocks = [_]entry.ContentBlock{.{ .text = .{ .text = "after recovery" } }};
    try opened.append(.{
        .id = "entry_after",
        .session_id = "session_partial",
        .parent_id = "entry_root",
        .created_ms = 2,
        .data = .{ .message = .{ .role = .user, .content = &blocks } },
    });
    const repaired = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(repaired);
    try std.testing.expect(std.mem.indexOf(u8, repaired, "{\"schema\":1{\"schema\"") == null);

    opened.deinit();
    var reopened = try store.open(std.testing.allocator, std.testing.io, .{ .path = path, .policy = .flush_only });
    defer reopened.deinit();
    try std.testing.expectEqual(@as(usize, 2), reopened.entries.items.len);
    try std.testing.expectEqualStrings("entry_after", reopened.currentLeaf());
}

test "session store rejects appending another header before writing" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root);
    const sessions_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "sessions" });
    defer std.testing.allocator.free(sessions_dir);

    var created = try store.create(std.testing.allocator, std.testing.io, .{
        .sessions_dir = sessions_dir,
        .session_id = "session_duplicate_header",
        .cwd = root,
        .created_ms = 1,
        .policy = .flush_only,
    });
    defer created.deinit();

    try std.testing.expectError(error.DuplicateHeader, created.append(.{
        .id = "entry_other_header",
        .session_id = "session_duplicate_header",
        .parent_id = null,
        .created_ms = 2,
        .data = .{ .header = .{ .cwd = root } },
    }));

    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, created.path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.count(u8, bytes, "\"kind\":\"header\"") == 1);
}

fn createStoreWithAllocator(allocator: std.mem.Allocator, sessions_dir: []const u8) !void {
    var created = try store.create(allocator, std.testing.io, .{
        .sessions_dir = sessions_dir,
        .session_id = "session_alloc_failure",
        .cwd = sessions_dir,
        .created_ms = 7,
        .policy = .flush_only,
    });
    created.deinit();
}

test "session store create cleans up partial allocation failures" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root);
    const sessions_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "sessions" });
    defer std.testing.allocator.free(sessions_dir);

    try std.testing.checkAllAllocationFailures(std.testing.allocator, createStoreWithAllocator, .{sessions_dir});
}

test "session store rejects unsupported schema before writing" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root);
    const sessions_dir = try std.fs.path.join(std.testing.allocator, &.{ root, "sessions" });
    defer std.testing.allocator.free(sessions_dir);

    var created = try store.create(std.testing.allocator, std.testing.io, .{
        .sessions_dir = sessions_dir,
        .session_id = "session_bad_schema",
        .cwd = root,
        .created_ms = 1,
        .policy = .flush_only,
    });
    defer created.deinit();

    const blocks = [_]entry.ContentBlock{.{ .text = .{ .text = "bad schema" } }};
    try std.testing.expectError(error.UnsupportedSchema, created.append(.{
        .schema = 2,
        .id = "entry_schema_2",
        .session_id = "session_bad_schema",
        .parent_id = "entry_root",
        .created_ms = 2,
        .data = .{ .message = .{ .role = .user, .content = &blocks } },
    }));

    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, created.path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "entry_schema_2") == null);
}
