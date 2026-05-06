const std = @import("std");
const pig = @import("pig");
const agent = pig.core.agent;
const provider = pig.provider;

test "interactive hotkeys command does not call model" {
    const turn = [_]provider.ProviderEvent{
        .{ .message_start = .{ .role = .assistant } },
        .{ .text_delta = .{ .text = "unused" } },
        .message_end,
        .done,
    };
    const turns = [_][]const provider.ProviderEvent{&turn};
    var model = agent.model_client.ScriptedModelClient{ .turns = &turns };
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();

    const status = try pig.app.interactive.runScript(.{ .mode = .interactive }, .{
        .allocator = std.testing.allocator,
        .model_client = model.client(),
    }, "/hotkeys\rquit\r", &stdout.writer);

    try std.testing.expectEqual(pig.app.interactive.InteractiveStatus.ok, status);
    try std.testing.expectEqual(@as(usize, 0), model.request_count);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "available commands") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "/scoped-models") != null);
}

test "interactive unknown slash command reports error and continues" {
    const turn = [_]provider.ProviderEvent{
        .{ .message_start = .{ .role = .assistant } },
        .{ .text_delta = .{ .text = "after command" } },
        .message_end,
        .done,
    };
    const turns = [_][]const provider.ProviderEvent{&turn};
    var model = agent.model_client.ScriptedModelClient{ .turns = &turns };
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();

    const status = try pig.app.interactive.runScript(.{ .mode = .interactive }, .{
        .allocator = std.testing.allocator,
        .model_client = model.client(),
    }, "/unknown\rhello\rquit\r", &stdout.writer);

    try std.testing.expectEqual(pig.app.interactive.InteractiveStatus.ok, status);
    try std.testing.expectEqual(@as(usize, 1), model.request_count);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "unknown command: /unknown") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "pig: after command") != null);
}

test "interactive model commands show available status without calling model" {
    const turn = [_]provider.ProviderEvent{
        .{ .message_start = .{ .role = .assistant } },
        .{ .text_delta = .{ .text = "unused" } },
        .message_end,
        .done,
    };
    const turns = [_][]const provider.ProviderEvent{&turn};
    var model = agent.model_client.ScriptedModelClient{ .turns = &turns };
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();

    const status = try pig.app.interactive.runScript(.{ .mode = .interactive }, .{
        .allocator = std.testing.allocator,
        .model_client = model.client(),
        .model_status = "current model:\n  id: gpt-4.1-mini",
        .scoped_models_status = "available models:\n* gpt-4.1-mini",
    }, "/model\r/scoped-models\rquit\r", &stdout.writer);

    try std.testing.expectEqual(pig.app.interactive.InteractiveStatus.ok, status);
    try std.testing.expectEqual(@as(usize, 0), model.request_count);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "current model:") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "available models:") != null);
}

test "interactive model command with args needs a switch hook" {
    const turn = [_]provider.ProviderEvent{
        .{ .message_start = .{ .role = .assistant } },
        .{ .text_delta = .{ .text = "unused" } },
        .message_end,
        .done,
    };
    const turns = [_][]const provider.ProviderEvent{&turn};
    var model = agent.model_client.ScriptedModelClient{ .turns = &turns };
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();

    const status = try pig.app.interactive.runScript(.{ .mode = .interactive }, .{
        .allocator = std.testing.allocator,
        .model_client = model.client(),
        .model_status = "current model",
    }, "/model gpt-4.1-mini\rquit\r", &stdout.writer);

    try std.testing.expectEqual(pig.app.interactive.InteractiveStatus.ok, status);
    try std.testing.expectEqual(@as(usize, 0), model.request_count);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "model switching unavailable") != null);
}

test "interactive model command switches next turn model client" {
    var first_model = CapturePromptModel{};
    var second_model = CapturePromptModel{};
    var switcher = ModelSwitchFixture{ .next_model = second_model.client() };
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();

    const status = try pig.app.interactive.runScript(.{ .mode = .interactive }, .{
        .allocator = std.testing.allocator,
        .model_client = first_model.client(),
        .model_switch_hook = .{ .ptr = &switcher, .select_fn = ModelSwitchFixture.select },
        .model_status = "current model:\n  id: first",
        .scoped_models_status = "available models:\n  first\n  second",
    }, "/model second\rhello\rquit\r", &stdout.writer);

    try std.testing.expectEqual(pig.app.interactive.InteractiveStatus.ok, status);
    try std.testing.expectEqual(@as(usize, 0), first_model.request_count);
    try std.testing.expectEqual(@as(usize, 1), second_model.request_count);
    try std.testing.expectEqualStrings("second", switcher.selected[0..switcher.selected_len]);
    try std.testing.expectEqualStrings("hello", second_model.last_user_text[0..second_model.last_user_text_len]);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "model selected: second") != null);
}

test "interactive double slash submits a literal slash prompt" {
    var model = CapturePromptModel{};
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();

    const status = try pig.app.interactive.runScript(.{ .mode = .interactive }, .{
        .allocator = std.testing.allocator,
        .model_client = model.client(),
    }, "//reload\rquit\r", &stdout.writer);

    try std.testing.expectEqual(pig.app.interactive.InteractiveStatus.ok, status);
    try std.testing.expectEqual(@as(usize, 1), model.request_count);
    try std.testing.expectEqualStrings("/reload", model.last_user_text[0..model.last_user_text_len]);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "you: /reload") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "you: //reload") == null);
}

const CapturePromptModel = struct {
    request_count: usize = 0,
    last_user_text: [128]u8 = undefined,
    last_user_text_len: usize = 0,

    fn client(self: *CapturePromptModel) agent.ModelClient {
        return .{ .ptr = self, .stream_turn = streamTurn };
    }

    fn streamTurn(ptr: *anyopaque, request: agent.model_client.ModelRequest, sink: provider.EventSink) agent.model_client.ModelClientError!void {
        const self: *CapturePromptModel = @ptrCast(@alignCast(ptr));
        self.request_count += 1;
        if (request.messages.len > 0) {
            const message = request.messages[request.messages.len - 1];
            if (message.content.len > 0 and message.content[0] == .text) {
                const text = message.content[0].text.text;
                const len = @min(text.len, self.last_user_text.len);
                @memcpy(self.last_user_text[0..len], text[0..len]);
                self.last_user_text_len = len;
            }
        }
        emit(sink, .{ .message_start = .{ .role = .assistant } }) catch |err| return err;
        emit(sink, .{ .text_delta = .{ .text = "literal" } }) catch |err| return err;
        emit(sink, .message_end) catch |err| return err;
        emit(sink, .done) catch |err| return err;
    }

    fn emit(sink: provider.EventSink, event: provider.ProviderEvent) agent.model_client.ModelClientError!void {
        sink.emit(event) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SinkRejectedEvent => return error.SinkRejectedEvent,
        };
    }
};

const ModelSwitchFixture = struct {
    next_model: agent.ModelClient,
    selected: [64]u8 = undefined,
    selected_len: usize = 0,

    fn select(ptr: *anyopaque, allocator: std.mem.Allocator, model_id: []const u8) anyerror!pig.app.interactive.ModelSwitchResult {
        const self: *ModelSwitchFixture = @ptrCast(@alignCast(ptr));
        const len = @min(model_id.len, self.selected.len);
        @memcpy(self.selected[0..len], model_id[0..len]);
        self.selected_len = len;
        return .{
            .status = try allocator.dupe(u8, "model selected: second"),
            .model_status = try allocator.dupe(u8, "current model:\n  id: second"),
            .scoped_models_status = try allocator.dupe(u8, "available models:\n  first\n* second"),
            .model_client = self.next_model,
        };
    }
};
