const std = @import("std");
const pig = @import("pig");
const tools = pig.tools;

fn expectJson(content: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, content, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}

test "builtin registry exposes all tool registrations" {
    var tc = try tools.testing.TempToolContext.init(std.testing.allocator);
    defer tc.deinit();
    var set = try tools.registry.initBuiltinToolSet(std.testing.allocator, &tc.context, .{});
    defer set.deinit(std.testing.allocator);
    try std.testing.expectEqual(tools.metadata.builtin_specs.len, set.registrations.len);
    const reg = pig.core.agent.tool.ToolRegistry{ .registrations = set.registrations };
    try std.testing.expect(reg.find("read") != null);
    try std.testing.expect(reg.find("bash") != null);
    const read = reg.find("read").?;
    try std.testing.expectEqualStrings("Read File", read.spec.display_label);
    try std.testing.expectEqualStrings("safe", read.spec.risk_level);
    try std.testing.expectEqualStrings("read_only", read.spec.access_kind);
    try std.testing.expect(std.mem.indexOf(u8, read.spec.schema_json, "\"path\"") != null);
    const bash = reg.find("bash").?;
    try std.testing.expectEqualStrings("confirmation_required", bash.spec.risk_level);
    try std.testing.expectEqualStrings("execute_process", bash.spec.access_kind);
}

test "registry executor returns valid JSON" {
    var tc = try tools.testing.TempToolContext.init(std.testing.allocator);
    defer tc.deinit();
    try tc.writeFile("main.txt", "hello\n");
    var set = try tools.registry.initBuiltinToolSet(std.testing.allocator, &tc.context, .{});
    defer set.deinit(std.testing.allocator);
    const reg = pig.core.agent.tool.ToolRegistry{ .registrations = set.registrations };
    const read_reg = reg.find("read").?;
    var null_sink = pig.core.agent.events.NullSink{};
    const result = try read_reg.executor.execute(.{ .allocator = std.testing.allocator, .event_sink = null_sink.sink() }, .{ .id = "call_1", .name = "read", .arguments_json = "{\"path\":\"main.txt\"}" });
    defer result.deinit(std.testing.allocator);
    try expectJson(result.content_json);
}
