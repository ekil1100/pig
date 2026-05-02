const std = @import("std");
const metadata = @import("metadata.zig");

pub const ApprovalDecision = enum { allow, deny };
pub const ApprovalError = error{ OutOfMemory, ApprovalBackendFailed };
pub const ApprovalRequestKind = enum { run_bash, write_file, edit_file };

pub const ApprovalRequest = struct {
    kind: ApprovalRequestKind,
    tool_name: []const u8,
    summary: []const u8,
    preview_json: []const u8,
    risk: metadata.ToolRisk,
    access: metadata.ToolAccess,
};

pub const ApprovalPolicy = struct {
    ptr: *anyopaque,
    decide_fn: *const fn (ptr: *anyopaque, request: ApprovalRequest) ApprovalError!ApprovalDecision,

    pub fn decide(self: ApprovalPolicy, request: ApprovalRequest) ApprovalError!ApprovalDecision {
        return self.decide_fn(self.ptr, request);
    }
};

pub const AllowAllApproval = struct {
    pub fn policy(self: *AllowAllApproval) ApprovalPolicy {
        return .{ .ptr = self, .decide_fn = decide };
    }
    fn decide(_: *anyopaque, _: ApprovalRequest) ApprovalError!ApprovalDecision {
        return .allow;
    }
};

pub const DenyAllApproval = struct {
    pub fn policy(self: *DenyAllApproval) ApprovalPolicy {
        return .{ .ptr = self, .decide_fn = decide };
    }
    fn decide(_: *anyopaque, _: ApprovalRequest) ApprovalError!ApprovalDecision {
        return .deny;
    }
};

pub const RecordingApproval = struct {
    allocator: std.mem.Allocator,
    decision: ApprovalDecision = .allow,
    count: usize = 0,
    last_tool_name: ?[]const u8 = null,
    last_preview_json: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, decision: ApprovalDecision) RecordingApproval {
        return .{ .allocator = allocator, .decision = decision };
    }

    pub fn deinit(self: *RecordingApproval) void {
        if (self.last_tool_name) |v| self.allocator.free(v);
        if (self.last_preview_json) |v| self.allocator.free(v);
        self.* = undefined;
    }

    pub fn policy(self: *RecordingApproval) ApprovalPolicy {
        return .{ .ptr = self, .decide_fn = decide };
    }

    fn decide(ptr: *anyopaque, request: ApprovalRequest) ApprovalError!ApprovalDecision {
        const self: *RecordingApproval = @ptrCast(@alignCast(ptr));
        self.count += 1;
        if (self.last_tool_name) |v| self.allocator.free(v);
        if (self.last_preview_json) |v| self.allocator.free(v);
        self.last_tool_name = null;
        self.last_preview_json = null;

        const tool_name = self.allocator.dupe(u8, request.tool_name) catch return error.OutOfMemory;
        errdefer self.allocator.free(tool_name);
        const preview_json = self.allocator.dupe(u8, request.preview_json) catch return error.OutOfMemory;
        self.last_tool_name = tool_name;
        self.last_preview_json = preview_json;
        return self.decision;
    }
};
