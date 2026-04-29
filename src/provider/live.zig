const std = @import("std");
const auth = @import("auth.zig");

pub const SmokeEnv = auth.TestEnv;
pub const EnvReader = auth.EnvReader;

pub const Decision = enum { skip, run };

pub const LiveDecision = struct {
    kind: Decision,
    missing: [required.len]?[]const u8 = [_]?[]const u8{null} ** required.len,
    missing_count: usize = 0,

    pub fn missingName(self: LiveDecision, index: usize) ?[]const u8 {
        if (index >= self.missing_count) return null;
        return self.missing[index];
    }
};

const required = [_][]const u8{
    "PIG_OPENAI_COMPAT_BASE_URL",
    "PIG_OPENAI_COMPAT_API_KEY",
    "PIG_OPENAI_COMPAT_MODEL",
};

pub fn decide(env: EnvReader) LiveDecision {
    const enabled = env.get("PIG_PROVIDER_LIVE") orelse return .{ .kind = .skip };
    if (!std.mem.eql(u8, enabled, "1")) return .{ .kind = .skip };
    var decision = LiveDecision{ .kind = .skip };
    for (required) |name| {
        if (env.get(name) == null) {
            decision.missing[decision.missing_count] = name;
            decision.missing_count += 1;
        }
    }
    if (decision.missing_count > 0) return decision;
    return .{ .kind = .run };
}
