pub const ProviderKind = enum {
    openai_compatible,
    anthropic,
    gemini,
    openai_responses,
    custom,
};

pub const ProviderStatus = enum {
    unconfigured,
    configured,
    unavailable,
};
