const std = @import("std");
const pig = @import("pig");
const tools = pig.tools;

fn expectOk(content: []const u8, ok: bool) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, content, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(ok, parsed.value.object.get("ok").?.bool);
}

test "bash captures stdout and nonzero exit" {
    var tc = try tools.testing.TempToolContext.init(std.testing.allocator);
    defer tc.deinit();
    var result = try tools.bash.execute(&tc.context, "{\"command\":\"printf hello\"}");
    defer result.deinit(std.testing.allocator);
    try expectOk(result.content_json, true);
    try std.testing.expect(std.mem.indexOf(u8, result.content_json, "hello") != null);

    var nonzero = try tools.bash.execute(&tc.context, "{\"command\":\"exit 7\"}");
    defer nonzero.deinit(std.testing.allocator);
    try expectOk(nonzero.content_json, true);
    try std.testing.expect(std.mem.indexOf(u8, nonzero.content_json, "\"exit_code\":7") != null);
}

test "bash approval deny prevents execution" {
    var tc = try tools.testing.TempToolContext.init(std.testing.allocator);
    defer tc.deinit();
    var deny = tools.approval.DenyAllApproval{};
    tc.context.approval = deny.policy();
    var result = try tools.bash.execute(&tc.context, "{\"command\":\"touch should-not-exist\"}");
    defer result.deinit(std.testing.allocator);
    try expectOk(result.content_json, false);
    const denied_path = try std.fs.path.join(std.testing.allocator, &.{ tc.workspace_root, "should-not-exist" });
    defer std.testing.allocator.free(denied_path);
    std.Io.Dir.cwd().access(std.testing.io, denied_path, .{}) catch return;
    return error.TestUnexpectedResult;
}

test "bash truncates visible output and spills full output" {
    var tc = try tools.testing.TempToolContext.init(std.testing.allocator);
    defer tc.deinit();
    tc.context.limits.max_bash_output_bytes = 4;
    tc.context.limits.max_bash_capture_bytes = 64;

    var result = try tools.bash.execute(&tc.context, "{\"command\":\"printf 1234567890\"}");
    defer result.deinit(std.testing.allocator);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result.content_json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expect(root.get("ok").?.bool);
    try std.testing.expect(root.get("truncated").?.bool);
    try std.testing.expectEqualStrings("1234", root.get("stdout").?.string);
    const spill_path = root.get("stdout_full_output_path").?.string;
    const spilled = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, spill_path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(spilled);
    try std.testing.expectEqualStrings("1234567890", spilled);
}

test "bash rejects output beyond capture limit" {
    var tc = try tools.testing.TempToolContext.init(std.testing.allocator);
    defer tc.deinit();
    tc.context.limits.max_bash_output_bytes = 4;
    tc.context.limits.max_bash_capture_bytes = 8;

    var result = try tools.bash.execute(&tc.context, "{\"command\":\"printf 1234567890\"}");
    defer result.deinit(std.testing.allocator);

    try expectOk(result.content_json, false);
    try std.testing.expect(std.mem.indexOf(u8, result.content_json, "output_too_large") != null);
}
