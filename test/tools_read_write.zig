const std = @import("std");
const pig = @import("pig");
const tools = pig.tools;

fn expectJsonOk(content: []const u8, ok: bool) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, content, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(ok, parsed.value.object.get("ok").?.bool);
}

test "read returns content and missing file returns structured error" {
    var tc = try tools.testing.TempToolContext.init(std.testing.allocator);
    defer tc.deinit();
    try tc.writeFile("src/main.txt", "one\ntwo\nthree\n");

    var result = try tools.read.execute(&tc.context, "{\"path\":\"src/main.txt\",\"offset\":2,\"limit\":1}");
    defer result.deinit(std.testing.allocator);
    try expectJsonOk(result.content_json, true);
    try std.testing.expect(std.mem.indexOf(u8, result.content_json, "two") != null);

    var missing = try tools.read.execute(&tc.context, "{\"path\":\"missing.txt\"}");
    defer missing.deinit(std.testing.allocator);
    try expectJsonOk(missing.content_json, false);
    try std.testing.expect(missing.is_error);

    try tc.writeFile("bad-utf8.txt", "ok \x80\n");
    var bad_utf8 = try tools.read.execute(&tc.context, "{\"path\":\"bad-utf8.txt\"}");
    defer bad_utf8.deinit(std.testing.allocator);
    try expectJsonOk(bad_utf8.content_json, true);
}

test "read reports large files and respects result budget" {
    var tc = try tools.testing.TempToolContext.init(std.testing.allocator);
    defer tc.deinit();
    tc.context.limits.max_read_bytes = 8;
    try tc.writeFile("large.txt", "123456789");

    var large = try tools.read.execute(&tc.context, "{\"path\":\"large.txt\"}");
    defer large.deinit(std.testing.allocator);
    try expectJsonOk(large.content_json, false);
    try std.testing.expect(std.mem.indexOf(u8, large.content_json, "file_too_large") != null);

    tc.context.limits.max_read_bytes = 1024;
    tc.context.limits.max_result_bytes = 8;
    var truncated = try tools.read.execute(&tc.context, "{\"path\":\"large.txt\"}");
    defer truncated.deinit(std.testing.allocator);
    try expectJsonOk(truncated.content_json, true);
    try std.testing.expect(std.mem.indexOf(u8, truncated.content_json, "\"truncated\":true") != null);
}

test "write create_new/overwrite and approval deny" {
    var tc = try tools.testing.TempToolContext.init(std.testing.allocator);
    defer tc.deinit();

    var created = try tools.write.execute(&tc.context, "{\"path\":\"notes/todo.txt\",\"content\":\"hello\\n\",\"create_parents\":true}");
    defer created.deinit(std.testing.allocator);
    try expectJsonOk(created.content_json, true);
    const bytes = try tc.readFile("notes/todo.txt");
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("hello\n", bytes);

    var recorder = tools.approval.RecordingApproval.init(std.testing.allocator, .deny);
    defer recorder.deinit();
    tc.context.approval = recorder.policy();
    var denied = try tools.write.execute(&tc.context, "{\"path\":\"notes/todo.txt\",\"content\":\"bye\",\"mode\":\"overwrite\"}");
    defer denied.deinit(std.testing.allocator);
    try expectJsonOk(denied.content_json, false);
    try std.testing.expectEqual(@as(usize, 1), recorder.count);
    try std.testing.expect(std.mem.indexOf(u8, recorder.last_preview_json.?, "notes/todo.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, recorder.last_preview_json.?, "content_preview") != null);
    try std.testing.expect(std.mem.indexOf(u8, recorder.last_preview_json.?, "\"old_bytes\":6") != null);
    try std.testing.expect(std.mem.indexOf(u8, recorder.last_preview_json.?, "bye") != null);
}
