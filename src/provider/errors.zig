pub const ProviderErrorKind = enum {
    auth,
    provider,
    stream_parse,
    transport,
    rate_limit,
    internal,
};

pub const ProviderErrorEvent = struct {
    category: ProviderErrorKind,
    message: []const u8,
    retryable: bool = false,
};

pub const ProviderParseError = error{
    StreamParseError,
    ProviderApiError,
    UnsupportedTransport,
    MissingApiKey,
    InvalidAuthJson,
    OutOfMemory,
};

pub fn kindName(kind: ProviderErrorKind) []const u8 {
    return @tagName(kind);
}
