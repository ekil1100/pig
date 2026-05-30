const std = @import("std");
const common = @import("common.zig");

pub const ContextFile = struct {
    path: []const u8,
    bytes: usize,

    fn deinit(self: *ContextFile, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
};

pub const ContextSnapshot = struct {
    files: std.ArrayList(ContextFile) = .empty,
    system_prompt: ?[]const u8 = null,
    total_bytes: usize = 0,
    warnings: std.ArrayList(common.ResourceWarning) = .empty,

    pub fn deinit(self: *ContextSnapshot, allocator: std.mem.Allocator) void {
        for (self.files.items) |*file| file.deinit(allocator);
        self.files.deinit(allocator);
        if (self.system_prompt) |prompt| allocator.free(prompt);
        for (self.warnings.items) |*warning| warning.deinit(allocator);
        self.warnings.deinit(allocator);
        self.* = undefined;
    }
};

pub const LoadOptions = struct {
    cwd: []const u8,
    include: []const []const u8,
    max_bytes: usize,
};

pub fn load(allocator: std.mem.Allocator, io: std.Io, options: LoadOptions) !ContextSnapshot {
    var snapshot = ContextSnapshot{};
    errdefer snapshot.deinit(allocator);
    const root = try resolveWorkspaceRoot(allocator, io, options.cwd);
    defer allocator.free(root);
    const dirs = try dirsFromRootToCwd(allocator, root, options.cwd);
    defer {
        for (dirs) |dir| allocator.free(dir);
        allocator.free(dirs);
    }
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var used: usize = 0;
    for (0..3) |phase| {
        for (dirs) |dir| {
            for (options.include) |name| {
                if (contextPhase(name) != phase) continue;
                try appendContextFile(allocator, io, &snapshot, &out.writer, dir, name, options.max_bytes, &used);
            }
        }
    }
    if (out.written().len > 0) snapshot.system_prompt = try out.toOwnedSlice() else out.deinit();
    return snapshot;
}

fn contextPhase(name: []const u8) usize {
    if (std.mem.eql(u8, name, "APPEND_SYSTEM.md")) return 2;
    if (std.mem.eql(u8, name, "SYSTEM.md")) return 1;
    return 0;
}

fn headerPrefix(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "APPEND_SYSTEM.md")) return "Append System";
    if (std.mem.eql(u8, name, "SYSTEM.md")) return "System";
    return "Context";
}

fn appendContextFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    snapshot: *ContextSnapshot,
    writer: *std.Io.Writer,
    dir: []const u8,
    name: []const u8,
    max_bytes: usize,
    used: *usize,
) !void {
    const path = try std.fs.path.join(allocator, &.{ dir, name });
    defer allocator.free(path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => {
            try common.appendWarning(allocator, &snapshot.warnings, .unsupported, path, "context file could not be read");
            return;
        },
    };
    defer allocator.free(bytes);
    const header = try std.fmt.allocPrint(allocator, "\n[{s}: {s}]\n", .{ headerPrefix(name), path });
    defer allocator.free(header);
    const projected = used.* + header.len + bytes.len;
    if (projected > max_bytes) {
        try common.appendWarning(allocator, &snapshot.warnings, .truncated, path, "context files exceeded max_bytes");
        return;
    }
    // `writer` wraps a std.Io.Writer.Allocating whose only failure mode is the
    // backing allocator running out of memory; surface that as error.OutOfMemory
    // so callers (and checkAllAllocationFailures) see the real OOM rather than
    // the writer's generic error.WriteFailed.
    writer.writeAll(header) catch return error.OutOfMemory;
    writer.writeAll(bytes) catch return error.OutOfMemory;
    used.* = projected;
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    try snapshot.files.append(allocator, .{ .path = owned_path, .bytes = bytes.len });
    snapshot.total_bytes += bytes.len;
}

pub fn resolveWorkspaceRoot(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8) ![]u8 {
    const fallback = try allocator.dupe(u8, cwd);
    errdefer allocator.free(fallback);
    var current = try allocator.dupe(u8, cwd);
    errdefer allocator.free(current);
    while (true) {
        if (try hasMarker(allocator, io, current)) {
            allocator.free(fallback);
            return current;
        }
        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }
    allocator.free(current);
    return fallback;
}

fn hasMarker(allocator: std.mem.Allocator, io: std.Io, dir: []const u8) !bool {
    const git = try std.fs.path.join(allocator, &.{ dir, ".git" });
    defer allocator.free(git);
    if (std.Io.Dir.cwd().access(io, git, .{})) return true else |_| {}
    const pig = try std.fs.path.join(allocator, &.{ dir, ".pig" });
    defer allocator.free(pig);
    if (std.Io.Dir.cwd().access(io, pig, .{})) return true else |_| {}
    return false;
}

fn dirsFromRootToCwd(allocator: std.mem.Allocator, root: []const u8, cwd: []const u8) ![][]const u8 {
    var reversed: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (reversed.items) |item| allocator.free(item);
        reversed.deinit(allocator);
    }
    // `pending` holds the freshly-duped path that has not yet been handed to
    // `reversed`. It must be freed if `reversed.append` (or a later dupe) OOMs,
    // since on failure the unmanaged ArrayList neither stores nor frees it. Once
    // ownership transfers into `reversed`, clear it so the errdefer below does
    // not double-free the slice the `reversed` errdefer already owns.
    var pending: ?[]const u8 = try allocator.dupe(u8, cwd);
    errdefer if (pending) |path| allocator.free(path);
    while (pending) |current| {
        try reversed.append(allocator, current);
        pending = null;
        if (std.mem.eql(u8, current, root)) break;
        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        pending = try allocator.dupe(u8, parent);
    }
    const dirs = try allocator.alloc([]const u8, reversed.items.len);
    for (reversed.items, 0..) |_, i| dirs[i] = reversed.items[reversed.items.len - 1 - i];
    reversed.deinit(allocator);
    return dirs;
}
