const std = @import("std");
const provider = @import("pig").provider;

test "event sink collects callback-scoped provider events" {
    var collector = provider.testing.EventCollector.init(std.testing.allocator);
    defer collector.deinit();
    const sink = collector.sink();

    try sink.emit(.{ .message_start = .{ .provider_message_id = "msg_1", .role = .assistant } });
    try sink.emit(.{ .text_delta = .{ .text = "hel" } });
    try sink.emit(.{ .text_delta = .{ .text = "lo" } });
    try sink.emit(.message_end);
    try sink.emit(.done);

    try std.testing.expectEqual(@as(usize, 5), collector.events.items.len);
    try std.testing.expectEqual(provider.ProviderEventTag.message_start, collector.events.items[0].tag);
    try std.testing.expectEqualStrings("hel", collector.events.items[1].text.?);
    try std.testing.expectEqual(provider.ProviderEventTag.done, collector.events.items[4].tag);
}

test "event collector clones metadata and supports message_delta" {
    var collector = provider.testing.EventCollector.init(std.testing.allocator);
    defer collector.deinit();

    try collector.sink().emit(.{ .message_delta = .{ .stop_reason = "stop", .metadata_json = "{\"x\":1}" } });

    try std.testing.expectEqual(provider.ProviderEventTag.message_delta, collector.events.items[0].tag);
    try std.testing.expectEqualStrings("stop", collector.events.items[0].stop_reason.?);
    try std.testing.expectEqualStrings("{\"x\":1}", collector.events.items[0].metadata_json.?);
}
