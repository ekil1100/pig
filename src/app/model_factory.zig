const std = @import("std");
const agent = @import("../core/agent/mod.zig");
const provider = @import("../provider/mod.zig");
const resources = @import("../resources/mod.zig");

pub const ModelFactoryError = error{
    OutOfMemory,
    UnknownProvider,
    MissingApiKey,
    InvalidAuthJson,
};

const EmptyEnv = struct {
    fn reader(self: *EmptyEnv) provider.auth.EnvReader {
        return .{ .ptr = self, .get_fn = get };
    }

    fn get(ptr: *anyopaque, key: []const u8) ?[]const u8 {
        _ = ptr;
        _ = key;
        return null;
    }
};

pub const CreateOptions = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    auth_json_path: []const u8,
    env: ?provider.auth.EnvReader = null,
    model: resources.models.ModelEntry,
};

pub const OwnedModelClient = struct {
    allocator: std.mem.Allocator,
    provider_kind: provider.ProviderKind,
    api_key: []const u8,
    base_url: []const u8,
    model: []const u8,
    unsupported_transport: provider.transport.UnsupportedTransport = .{},

    pub fn deinit(self: *OwnedModelClient) void {
        self.allocator.free(self.api_key);
        self.allocator.free(self.base_url);
        self.allocator.free(self.model);
        self.* = undefined;
    }

    pub fn client(self: *OwnedModelClient) agent.ModelClient {
        return .{ .ptr = self, .stream_turn = streamTurn };
    }

    fn streamTurn(ptr: *anyopaque, request: agent.model_client.ModelRequest, sink: provider.EventSink) agent.model_client.ModelClientError!void {
        const self: *OwnedModelClient = @ptrCast(@alignCast(ptr));
        switch (self.provider_kind) {
            .openai_compatible, .openrouter, .deepseek, .custom => {
                var provider_request = provider.openai_compatible.buildChatCompletionsRequest(self.allocator, .{
                    .base_url = self.base_url,
                    .api_key = self.api_key,
                    .model = self.model,
                    .thinking = self.thinkingOptions(request.thinking_level),
                }, request.messages) catch return error.OutOfMemory;
                defer provider_request.deinit(self.allocator);
                var transport = self.unsupported_transport.transport();
                const stream = transport.sendStreaming(provider_request) catch return error.ProviderFailed;
                provider.openai_compatible.parseStream(self.allocator, stream, sink) catch |err| return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.SinkRejectedEvent => error.SinkRejectedEvent,
                    error.StreamParseError => error.ProviderStreamParseFailed,
                    else => error.ProviderFailed,
                };
            },
            else => return error.ProviderFailed,
        }
    }

    fn thinkingOptions(self: *OwnedModelClient, level: agent.ThinkingLevel) provider.config.ThinkingOptions {
        if (self.provider_kind != .deepseek) return .{};
        if (level == .off) return .{ .type = .disabled };
        return .{ .type = .enabled, .reasoning_effort = @tagName(level) };
    }
};

pub fn create(options: CreateOptions) ModelFactoryError!OwnedModelClient {
    const kind = provider.ProviderKind.fromString(options.model.provider_id) catch return error.UnknownProvider;
    var empty = EmptyEnv{};
    const env = options.env orelse empty.reader();
    const api_key = provider.auth.resolveApiKey(options.allocator, .{
        .kind = kind,
        .explicit_api_key = null,
        .auth_json_path = options.auth_json_path,
        .io = options.io,
        .env = env,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.MissingApiKey => error.MissingApiKey,
        error.InvalidAuthJson => error.InvalidAuthJson,
    };
    errdefer options.allocator.free(api_key);
    const base_url_default = switch (kind) {
        .openai_compatible, .openrouter, .custom => "https://api.openai.com/v1",
        .deepseek => "https://api.deepseek.com",
        .anthropic => "https://api.anthropic.com/v1",
        else => "https://example.invalid",
    };
    const base_url = try options.allocator.dupe(u8, options.model.base_url orelse base_url_default);
    errdefer options.allocator.free(base_url);
    const model = try options.allocator.dupe(u8, options.model.model);
    return .{ .allocator = options.allocator, .provider_kind = kind, .api_key = api_key, .base_url = base_url, .model = model };
}
