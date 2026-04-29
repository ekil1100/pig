const std = @import("std");
const provider = @import("pig").provider;

test "sse parser handles split chunks multiline data comments and crlf" {
    var collector = provider.sse.EventCollector.init(std.testing.allocator);
    defer collector.deinit();
    var parser = provider.sse.Parser.init(std.testing.allocator);
    defer parser.deinit();

    try parser.feed("event: mess", collector.sink());
    try parser.feed("age\r\ndata: one\r\ndata: two\r\n: ignored\r\n\r\n", collector.sink());
    try parser.feed("data: [DONE]\n\n", collector.sink());
    try parser.finish(collector.sink());

    try std.testing.expectEqual(@as(usize, 2), collector.events.items.len);
    try std.testing.expectEqualStrings("message", collector.events.items[0].event.?);
    try std.testing.expectEqualStrings("one\ntwo", collector.events.items[0].data);
    try std.testing.expectEqual(@as(?[]const u8, null), collector.events.items[1].event);
    try std.testing.expectEqualStrings("[DONE]", collector.events.items[1].data);
}

test "sse parser finish handles trailing buffered line" {
    var collector = provider.sse.EventCollector.init(std.testing.allocator);
    defer collector.deinit();
    var parser = provider.sse.Parser.init(std.testing.allocator);
    defer parser.deinit();

    try parser.feed("data: tail", collector.sink());
    try parser.finish(collector.sink());

    try std.testing.expectEqual(@as(usize, 1), collector.events.items.len);
    try std.testing.expectEqualStrings("tail", collector.events.items[0].data);
}

test "sse parser ignores event name without data" {
    var collector = provider.sse.EventCollector.init(std.testing.allocator);
    defer collector.deinit();
    var parser = provider.sse.Parser.init(std.testing.allocator);
    defer parser.deinit();

    try parser.feed("event: ping\n\n", collector.sink());
    try parser.finish(collector.sink());

    try std.testing.expectEqual(@as(usize, 0), collector.events.items.len);
}
