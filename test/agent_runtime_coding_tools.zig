const std = @import("std");
const pig = @import("pig");
const agent = pig.core.agent;
const provider = pig.provider;
const tools = pig.tools;

test "agent runtime can call read tool from builtin registry" {
    var tc = try tools.testing.TempToolContext.init(std.testing.allocator);
    defer tc.deinit();
    try tc.writeFile("main.txt", "hello runtime\n");
    var set = try tools.registry.initBuiltinToolSet(std.testing.allocator, &tc.context, .{});
    defer set.deinit(std.testing.allocator);

    const turn1 = [_]provider.ProviderEvent{
        .{ .message_start = .{ .role = .assistant } },
        .{ .tool_call_end = .{ .index = 0, .id = "call_1", .name = "read", .arguments_json = "{\"path\":\"main.txt\"}" } },
        .message_end,
        .done,
    };
    const turn2 = [_]provider.ProviderEvent{ .{ .message_start = .{ .role = .assistant } }, .{ .text_delta = .{ .text = "done" } }, .message_end, .done };
    const turns = [_][]const provider.ProviderEvent{ &turn1, &turn2 };
    var model = agent.model_client.ScriptedModelClient{ .turns = &turns };
    var state = agent.state.AgentState.init(std.testing.allocator, .{});
    defer state.deinit();
    var collector = agent.testing.AgentEventCollector.init(std.testing.allocator);
    defer collector.deinit();
    var runtime = agent.runtime.AgentRuntime{ .allocator = std.testing.allocator, .state = &state, .model = model.client(), .tools = .{ .registrations = set.registrations }, .event_sink = collector.sink() };

    try runtime.runUserText("read it");
    try std.testing.expectEqual(@as(usize, 4), state.messages.items.len);
    try std.testing.expectEqual(provider.Role.tool, state.messages.items[2].role);
    try std.testing.expect(std.mem.indexOf(u8, state.messages.items[2].content[0].tool_result.content_json, "hello runtime") != null);
    try std.testing.expectEqual(tools.metadata.builtin_specs.len, model.last_tool_count);
}
