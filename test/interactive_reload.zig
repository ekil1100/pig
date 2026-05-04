const std = @import("std");
const pig = @import("pig");
const agent = pig.core.agent;
const provider = pig.provider;

test "interactive reload does not call model and next turn uses new system prompt" {
    const turn = [_]provider.ProviderEvent{
        .{ .message_start = .{ .role = .assistant } },
        .{ .text_delta = .{ .text = "ok" } },
        .message_end,
        .done,
    };
    const turns = [_][]const provider.ProviderEvent{&turn};
    var model = agent.model_client.ScriptedModelClient{ .turns = &turns };
    var reload = ReloadFixture{};
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();

    const status = try pig.app.interactive.runScript(.{ .mode = .interactive }, .{
        .allocator = std.testing.allocator,
        .model_client = model.client(),
        .reload_hook = .{ .ptr = &reload, .reload_fn = ReloadFixture.reload },
    }, "/reload\rhello\rquit\r", &stdout.writer);

    try std.testing.expectEqual(pig.app.interactive.InteractiveStatus.ok, status);
    try std.testing.expectEqual(@as(usize, 1), reload.count);
    try std.testing.expectEqual(@as(usize, 1), model.request_count);
    try std.testing.expectEqualStrings("new system", model.last_system_prompt.?);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "resources reloaded") != null);
}

const ReloadFixture = struct {
    count: usize = 0,

    fn reload(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!pig.app.interactive.ReloadResult {
        const self: *ReloadFixture = @ptrCast(@alignCast(ptr));
        self.count += 1;
        return .{
            .status = try allocator.dupe(u8, "resources reloaded"),
            .system_prompt = try allocator.dupe(u8, "new system"),
        };
    }
};
