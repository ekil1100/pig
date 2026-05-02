const std = @import("std");
const pig = @import("pig");
const tools = pig.tools;

fn jsonOk(content: []const u8) !bool {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, content, .{});
    defer parsed.deinit();
    return parsed.value.object.get("ok").?.bool;
}

test "edit applies multiple exact replacements" {
    var tc = try tools.testing.TempToolContext.init(std.testing.allocator);
    defer tc.deinit();
    try tc.writeFile("src/main.txt", "alpha beta gamma\nunique\n");

    var result = try tools.edit.execute(&tc.context, "{\"path\":\"src/main.txt\",\"edits\":[{\"old_text\":\"alpha\",\"new_text\":\"one\"},{\"old_text\":\"gamma\",\"new_text\":\"three\"}]}");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(try jsonOk(result.content_json));
    const bytes = try tc.readFile("src/main.txt");
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("one beta three\nunique\n", bytes);
}

test "edit reports repeated and approval denied" {
    var tc = try tools.testing.TempToolContext.init(std.testing.allocator);
    defer tc.deinit();
    try tc.writeFile("main.txt", "repeat repeat\n");

    var repeated = try tools.edit.execute(&tc.context, "{\"path\":\"main.txt\",\"edits\":[{\"old_text\":\"repeat\",\"new_text\":\"x\"}]}");
    defer repeated.deinit(std.testing.allocator);
    try std.testing.expect(!(try jsonOk(repeated.content_json)));

    var recorder = tools.approval.RecordingApproval.init(std.testing.allocator, .deny);
    defer recorder.deinit();
    tc.context.approval = recorder.policy();
    var denied = try tools.edit.execute(&tc.context, "{\"path\":\"main.txt\",\"edits\":[{\"old_text\":\"repeat repeat\",\"new_text\":\"x\"}]}");
    defer denied.deinit(std.testing.allocator);
    try std.testing.expect(!(try jsonOk(denied.content_json)));
    try std.testing.expectEqual(@as(usize, 1), recorder.count);
    try std.testing.expect(std.mem.indexOf(u8, recorder.last_preview_json.?, "old_text_preview") != null);
    try std.testing.expect(std.mem.indexOf(u8, recorder.last_preview_json.?, "repeat repeat") != null);
    try std.testing.expect(std.mem.indexOf(u8, recorder.last_preview_json.?, "new_text_preview") != null);
    const bytes = try tc.readFile("main.txt");
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("repeat repeat\n", bytes);
}

test "edit reports file too large separately from missing file" {
    var tc = try tools.testing.TempToolContext.init(std.testing.allocator);
    defer tc.deinit();
    tc.context.limits.max_read_bytes = 4;
    try tc.writeFile("main.txt", "12345");

    var result = try tools.edit.execute(&tc.context, "{\"path\":\"main.txt\",\"edits\":[{\"old_text\":\"1\",\"new_text\":\"x\"}]}");
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!(try jsonOk(result.content_json)));
    try std.testing.expect(std.mem.indexOf(u8, result.content_json, "file_too_large") != null);
}
