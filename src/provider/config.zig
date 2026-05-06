pub const ThinkingType = enum {
    omitted,
    disabled,
    enabled,
};

pub const ThinkingOptions = struct {
    type: ThinkingType = .omitted,
    reasoning_effort: ?[]const u8 = null,
};

pub const OpenAiCompatibleConfig = struct {
    base_url: []const u8,
    api_key: []const u8,
    model: []const u8,
    thinking: ThinkingOptions = .{},
};
