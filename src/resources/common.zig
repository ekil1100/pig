const std = @import("std");

pub const ResourceKind = enum {
    settings,
    auth,
    model_registry,
    context_file,
    skill,
    prompt_template,
    theme,
    package,
};

pub const ResourceSource = enum {
    builtin,
    global,
    project,
};

pub const ResourceSourceInfo = struct {
    source: ResourceSource,
    path: []const u8,
    priority: u8,

    pub fn clone(allocator: std.mem.Allocator, source: ResourceSource, path: []const u8, priority: u8) !ResourceSourceInfo {
        return .{ .source = source, .path = try allocator.dupe(u8, path), .priority = priority };
    }

    pub fn deinit(self: *ResourceSourceInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
};

pub const ResourceWarningKind = enum {
    collision,
    invalid_json,
    ignored_unknown_key,
    truncated,
    secret_in_config,
    unsupported,
    missing,
};

pub const ResourceWarning = struct {
    kind: ResourceWarningKind,
    path: []const u8,
    message: []const u8,

    pub fn clone(allocator: std.mem.Allocator, kind: ResourceWarningKind, path: []const u8, message: []const u8) !ResourceWarning {
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        const owned_message = try allocator.dupe(u8, message);
        return .{ .kind = kind, .path = owned_path, .message = owned_message };
    }

    pub fn deinit(self: *ResourceWarning, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.message);
        self.* = undefined;
    }
};

pub fn appendWarning(allocator: std.mem.Allocator, warnings: *std.ArrayList(ResourceWarning), kind: ResourceWarningKind, path: []const u8, message: []const u8) !void {
    const warning = try ResourceWarning.clone(allocator, kind, path, message);
    errdefer {
        var mutable = warning;
        mutable.deinit(allocator);
    }
    try warnings.append(allocator, warning);
}
