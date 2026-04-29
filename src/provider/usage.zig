pub const Usage = struct {
    input_tokens: ?u64 = null,
    output_tokens: ?u64 = null,
    cache_read_tokens: ?u64 = null,
    cache_write_tokens: ?u64 = null,

    pub fn add(a: Usage, b: Usage) Usage {
        return .{
            .input_tokens = addOptional(a.input_tokens, b.input_tokens),
            .output_tokens = addOptional(a.output_tokens, b.output_tokens),
            .cache_read_tokens = addOptional(a.cache_read_tokens, b.cache_read_tokens),
            .cache_write_tokens = addOptional(a.cache_write_tokens, b.cache_write_tokens),
        };
    }

    fn addOptional(a: ?u64, b: ?u64) ?u64 {
        if (a == null and b == null) return null;
        return (a orelse 0) + (b orelse 0);
    }
};
