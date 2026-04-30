const std = @import("std");
const pig = @import("pig");
const agent = pig.core.agent;

test "agent event collector clones callback-scoped payloads" {
    var collector = agent.testing.AgentEventCollector.init(std.testing.allocator);
    defer collector.deinit();
    const sink = collector.sink();

    var buffer = [_]u8{ 'h', 'i' };
    try sink.emit(.{ .message_delta = .{ .text_delta = buffer[0..] } });
    buffer[0] = 'b';

    try std.testing.expectEqual(@as(usize, 1), collector.events.items.len);
    try std.testing.expectEqualStrings("hi", collector.events.items[0].text_delta.?);
}

test "agent event collector supports error events and rejection" {
    var collector = agent.testing.AgentEventCollector.init(std.testing.allocator);
    defer collector.deinit();
    try collector.sink().emit(.{ .error_event = .{ .category = .provider, .message = "provider failed" } });
    try std.testing.expectEqual(agent.events.AgentEventTag.error_event, collector.events.items[0].tag);
    try std.testing.expectEqual(agent.events.AgentErrorCategory.provider, collector.events.items[0].error_category.?);

    var rejecting = agent.testing.AgentEventCollector.init(std.testing.allocator);
    defer rejecting.deinit();
    rejecting.reject_after = 0;
    try std.testing.expectError(error.SinkRejectedEvent, rejecting.sink().emit(.{ .agent_start = .{} }));
}
