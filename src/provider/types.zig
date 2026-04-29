const std = @import("std");

pub const ProviderKind = enum {
    openai_compatible,
    anthropic,
    gemini,
    openai_responses,
    azure_openai,
    bedrock,
    openrouter,
    custom,

    pub fn toString(kind: ProviderKind) []const u8 {
        return @tagName(kind);
    }

    pub fn fromString(value: []const u8) error{UnknownProviderKind}!ProviderKind {
        inline for (std.meta.fields(ProviderKind)) |field| {
            if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
        }
        return error.UnknownProviderKind;
    }
};

pub const ProviderStatus = enum {
    unconfigured,
    configured,
    unavailable,
};

pub const Role = enum {
    system,
    user,
    assistant,
    tool,

    pub fn toString(role: Role) []const u8 {
        return @tagName(role);
    }

    pub fn fromString(value: []const u8) error{UnknownRole}!Role {
        inline for (std.meta.fields(Role)) |field| {
            if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
        }
        return error.UnknownRole;
    }
};

pub const ModelId = struct {
    value: []const u8,
};
