const std = @import("std");
const pig = @import("pig");
const tools = pig.tools;

fn expectContains(content: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, content, needle) != null);
}

test "checked-in tools fixtures are usable as a read-only workspace" {
    var allow = tools.approval.AllowAllApproval{};
    var ctx = tools.context.ToolContext{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .workspace_root = "fixtures/tools/sample-project",
        .spill_dir = ".zig-cache/tools-fixture-spill",
        .approval = allow.policy(),
    };

    var readme = try tools.read.execute(&ctx, "{\"path\":\"README.md\"}");
    defer readme.deinit(std.testing.allocator);
    try expectContains(readme.content_json, "Sample Project");

    var found = try tools.find.execute(&ctx, "{\"path\":\".\",\"pattern\":\"*.txt\"}");
    defer found.deinit(std.testing.allocator);
    try expectContains(found.content_json, "src/main.txt");

    var grepped = try tools.grep.execute(&ctx, "{\"path\":\"src\",\"pattern\":\"AgentRuntime\"}");
    defer grepped.deinit(std.testing.allocator);
    try expectContains(grepped.content_json, "src/lib.txt");
}
