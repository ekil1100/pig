const std = @import("std");
const pig = @import("pig");
const tools = pig.tools;

fn expectContains(content: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, content, needle) != null);
}

test "ls find grep return deterministic JSON" {
    var tc = try tools.testing.TempToolContext.init(std.testing.allocator);
    defer tc.deinit();
    try tc.writeFile("src/main.txt", "hello\nAgentRuntime\n");
    try tc.writeFile("src/lib.zig", "const x = 1;\n");
    try tc.writeFile("README.md", "hello readme\n");

    var listed = try tools.ls.execute(&tc.context, "{\"path\":\".\"}");
    defer listed.deinit(std.testing.allocator);
    try expectContains(listed.content_json, "README.md");
    try expectContains(listed.content_json, "src/");

    var found = try tools.find.execute(&tc.context, "{\"path\":\"src\",\"pattern\":\"*.zig\"}");
    defer found.deinit(std.testing.allocator);
    try expectContains(found.content_json, "src/lib.zig");

    var grepped = try tools.grep.execute(&tc.context, "{\"path\":\"src\",\"pattern\":\"AgentRuntime\"}");
    defer grepped.deinit(std.testing.allocator);
    try expectContains(grepped.content_json, "main.txt");

    var limited = try tools.grep.execute(&tc.context, "{\"path\":\".\",\"pattern\":\"hello\",\"limit\":1}");
    defer limited.deinit(std.testing.allocator);
    try expectContains(limited.content_json, "\"truncated\":true");

    var missing = try tools.grep.execute(&tc.context, "{\"path\":\"missing\",\"pattern\":\"hello\"}");
    defer missing.deinit(std.testing.allocator);
    try expectContains(missing.content_json, "file_not_found");
    try std.testing.expect(missing.is_error);

    var unsupported = try tools.grep.execute(&tc.context, "{\"path\":\"src\",\"pattern\":\"Agent.*\",\"literal\":false}");
    defer unsupported.deinit(std.testing.allocator);
    try expectContains(unsupported.content_json, "unsupported_regex");
}

test "grep and find truncation reflects omitted results" {
    var tc = try tools.testing.TempToolContext.init(std.testing.allocator);
    defer tc.deinit();
    try tc.writeFile("one.txt", "needle\n");

    var exact = try tools.grep.execute(&tc.context, "{\"path\":\"one.txt\",\"pattern\":\"needle\",\"limit\":1}");
    defer exact.deinit(std.testing.allocator);
    try expectContains(exact.content_json, "\"truncated\":false");

    try tc.writeFile("two.txt", "needle\n");
    var limited = try tools.grep.execute(&tc.context, "{\"path\":\".\",\"pattern\":\"needle\",\"limit\":1}");
    defer limited.deinit(std.testing.allocator);
    try expectContains(limited.content_json, "\"truncated\":true");

    try tc.writeFile("a.txt", "");
    try tc.writeFile("b.txt", "");
    try tc.writeFile("c.txt", "");
    try tc.writeFile(".git/secret.txt", "ignored\n");
    var found = try tools.find.execute(&tc.context, "{\"path\":\".\",\"pattern\":\"*.txt\",\"limit\":2}");
    defer found.deinit(std.testing.allocator);
    try expectContains(found.content_json, "\"truncated\":true");
    try std.testing.expect(std.mem.indexOf(u8, found.content_json, ".git") == null);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, found.content_json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.object.get("matches").?.array.items.len);
}

test "grep marks unreadably large files as truncated instead of silently complete" {
    var tc = try tools.testing.TempToolContext.init(std.testing.allocator);
    defer tc.deinit();
    tc.context.limits.max_read_bytes = 4;
    try tc.writeFile("large.txt", "needle\n");

    var result = try tools.grep.execute(&tc.context, "{\"path\":\".\",\"pattern\":\"needle\"}");
    defer result.deinit(std.testing.allocator);
    try expectContains(result.content_json, "\"truncated\":true");
}

fn lsExecuteWithAllocator(allocator: std.mem.Allocator) !void {
    var tc = try tools.testing.TempToolContext.init(allocator);
    defer tc.deinit();
    try tc.writeFile("alpha.txt", "x\n");
    try tc.writeFile("nested/beta.txt", "y\n");

    var result = try tools.ls.execute(&tc.context, "{\"path\":\".\"}");
    defer result.deinit(allocator);
}

test "ls cleans up partial allocation failures while listing entries" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, lsExecuteWithAllocator, .{});
}

fn findExecuteWithAllocator(allocator: std.mem.Allocator) !void {
    var tc = try tools.testing.TempToolContext.init(allocator);
    defer tc.deinit();
    // A subdirectory forces walkSorted to recurse (exercising the entries append),
    // and matching files in both levels exercise the matches append.
    try tc.writeFile("top.txt", "x\n");
    try tc.writeFile("sub/inner.txt", "y\n");

    var result = try tools.find.execute(&tc.context, "{\"path\":\".\",\"pattern\":\"*.txt\"}");
    defer result.deinit(allocator);
}

test "find cleans up partial allocation failures across both append sites" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, findExecuteWithAllocator, .{});
}

fn grepExecuteWithAllocator(allocator: std.mem.Allocator) !void {
    var tc = try tools.testing.TempToolContext.init(allocator);
    defer tc.deinit();
    try tc.writeFile("hit.txt", "needle here\n");

    var result = try tools.grep.execute(&tc.context, "{\"path\":\".\",\"pattern\":\"needle\"}");
    defer result.deinit(allocator);
}

test "grep cleans up partial allocation failures while collecting matches" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, grepExecuteWithAllocator, .{});
}
