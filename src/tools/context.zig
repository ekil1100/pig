const std = @import("std");
const approval = @import("approval.zig");

pub const ToolLimits = struct {
    max_read_bytes: usize = 256 * 1024,
    max_result_bytes: usize = 64 * 1024,
    max_bash_output_bytes: usize = 64 * 1024,
    max_bash_capture_bytes: usize = 8 * 1024 * 1024,
    bash_timeout_ms: u64 = 30_000,
};

pub const ToolResult = struct {
    content_json: []const u8,
    is_error: bool = false,

    pub fn deinit(self: ToolResult, allocator: std.mem.Allocator) void {
        allocator.free(self.content_json);
    }
};

pub const ToolContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_root: []const u8,
    spill_dir: []const u8,
    approval: approval.ApprovalPolicy,
    limits: ToolLimits = .{},
};
