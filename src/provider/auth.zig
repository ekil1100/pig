const std = @import("std");
const types = @import("types.zig");

pub const EnvReader = struct {
    ptr: *anyopaque,
    get_fn: *const fn (ptr: *anyopaque, key: []const u8) ?[]const u8,

    pub fn get(self: EnvReader, key: []const u8) ?[]const u8 {
        return self.get_fn(self.ptr, key);
    }
};

pub const EnvPair = struct { key: []const u8, value: []const u8 };

pub const TestEnv = struct {
    pairs: []const EnvPair,

    pub fn init(pairs: []const EnvPair) TestEnv {
        return .{ .pairs = pairs };
    }

    pub fn reader(self: *TestEnv) EnvReader {
        return .{ .ptr = self, .get_fn = get };
    }

    fn get(ptr: *anyopaque, key: []const u8) ?[]const u8 {
        const self: *TestEnv = @ptrCast(@alignCast(ptr));
        for (self.pairs) |pair| if (std.mem.eql(u8, pair.key, key)) return pair.value;
        return null;
    }
};

pub const ResolveOptions = struct {
    kind: types.ProviderKind,
    explicit_api_key: ?[]const u8 = null,
    auth_json_path: ?[]const u8 = null,
    io: ?std.Io = null,
    env: EnvReader,
};

pub fn resolveApiKey(allocator: std.mem.Allocator, options: ResolveOptions) ![]u8 {
    if (options.explicit_api_key) |key| return try allocator.dupe(u8, key);
    if (options.auth_json_path) |path| {
        const io = options.io orelse return error.InvalidAuthJson;
        if (try readAuthJson(allocator, io, path, options.kind)) |key| return key;
    }
    for (envNames(options.kind)) |name| {
        if (options.env.get(name)) |key| return try allocator.dupe(u8, key);
    }
    return error.MissingApiKey;
}

fn envNames(kind: types.ProviderKind) []const []const u8 {
    return switch (kind) {
        .openai_compatible, .openai_responses, .azure_openai, .openrouter, .custom => &.{"PIG_OPENAI_COMPAT_API_KEY"},
        .anthropic => &.{ "ANTHROPIC_API_KEY", "PIG_ANTHROPIC_API_KEY" },
        .gemini => &.{ "GEMINI_API_KEY", "PIG_GEMINI_API_KEY" },
        .bedrock => &.{"AWS_ACCESS_KEY_ID"},
    };
}

fn providerJsonKey(kind: types.ProviderKind) []const u8 {
    return switch (kind) {
        .openai_compatible => "openai_compatible",
        .anthropic => "anthropic",
        .gemini => "gemini",
        .openai_responses => "openai_responses",
        .azure_openai => "azure_openai",
        .bedrock => "bedrock",
        .openrouter => "openrouter",
        .custom => "custom",
    };
}

fn readAuthJson(allocator: std.mem.Allocator, io: std.Io, path: []const u8, kind: types.ProviderKind) !?[]u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return error.InvalidAuthJson;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidAuthJson;
    const providers = parsed.value.object.get("providers") orelse return null;
    if (providers != .object) return error.InvalidAuthJson;
    const provider_value = providers.object.get(providerJsonKey(kind)) orelse return null;
    if (provider_value != .object) return error.InvalidAuthJson;
    const api_key = provider_value.object.get("api_key") orelse return null;
    if (api_key != .string) return error.InvalidAuthJson;
    return try allocator.dupe(u8, api_key.string);
}

pub fn formatMissingKeyMessage(kind: types.ProviderKind) []const u8 {
    return switch (kind) {
        .openai_compatible => "missing OpenAI-compatible API key: set PIG_OPENAI_COMPAT_API_KEY",
        .anthropic => "missing Anthropic API key: set ANTHROPIC_API_KEY or PIG_ANTHROPIC_API_KEY",
        .gemini => "missing Gemini API key: set GEMINI_API_KEY or PIG_GEMINI_API_KEY",
        else => "missing provider API key",
    };
}
