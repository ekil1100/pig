const std = @import("std");
const context_mod = @import("context.zig");
const json = @import("json.zig");
const path_mod = @import("path.zig");

pub fn execute(ctx: *context_mod.ToolContext, args_json: []const u8) !context_mod.ToolResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch return errorResult(ctx, "invalid_arguments", "arguments must be valid JSON");
    defer parsed.deinit();
    const object = json.getObject(parsed.value) orelse return errorResult(ctx, "invalid_arguments", "arguments must be an object");
    const pattern = json.getString(object, "pattern") orelse return errorResult(ctx, "invalid_arguments", "pattern is required");
    const input_path = json.getString(object, "path") orelse ".";
    const limit_i = json.getInteger(object, "limit", 1000);
    const limit: usize = if (limit_i < 1) 1 else @intCast(limit_i);
    var norm = path_mod.normalizeWorkspacePath(ctx.allocator, ctx.workspace_root, input_path) catch |err| return pathError(ctx, err);
    defer norm.deinit(ctx.allocator);

    var matches: std.ArrayList([]u8) = .empty;
    defer {
        for (matches.items) |m| ctx.allocator.free(m);
        matches.deinit(ctx.allocator);
    }
    const collect_limit = limit + 1;
    var root_dir = std.Io.Dir.cwd().openDir(ctx.io, norm.absolute, .{ .iterate = true }) catch return errorResult(ctx, "not_directory", "path is not a directory");
    root_dir.close(ctx.io);
    try walkSorted(ctx, norm.absolute, norm.relative, pattern, collect_limit, &matches);

    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer out.deinit();
    out.writer.writeAll("{\"ok\":true,\"matches\":[") catch return error.OutOfMemory;
    var rendered_bytes: usize = 0;
    var output_truncated = matches.items.len > limit;
    for (matches.items[0..@min(limit, matches.items.len)], 0..) |m, i| {
        const projected_bytes = rendered_bytes + m.len + 4;
        if (projected_bytes > ctx.limits.max_result_bytes) {
            output_truncated = true;
            break;
        }
        if (i > 0) out.writer.writeByte(',') catch return error.OutOfMemory;
        try json.writeJsonString(&out.writer, m);
        rendered_bytes = projected_bytes;
    }
    out.writer.writeAll("],\"truncated\":") catch return error.OutOfMemory;
    out.writer.writeAll(if (output_truncated) "true" else "false") catch return error.OutOfMemory;
    out.writer.writeAll("}") catch return error.OutOfMemory;
    return .{ .content_json = try out.toOwnedSlice() };
}

fn isSkipped(path: []const u8) bool {
    return std.mem.eql(u8, path, ".git") or
        std.mem.eql(u8, path, ".zig-cache") or
        std.mem.eql(u8, path, "zig-out") or
        std.mem.eql(u8, path, "node_modules") or
        std.mem.startsWith(u8, path, ".git/") or
        std.mem.startsWith(u8, path, ".zig-cache/") or
        std.mem.startsWith(u8, path, "zig-out/") or
        std.mem.startsWith(u8, path, "node_modules/");
}

const Entry = struct {
    name: []const u8,
    is_dir: bool,

    fn deinit(self: Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

fn walkSorted(ctx: *context_mod.ToolContext, abs: []const u8, rel: []const u8, pattern: []const u8, collect_limit: usize, matches: *std.ArrayList([]u8)) !void {
    if (matches.items.len >= collect_limit) return;
    var dir = std.Io.Dir.cwd().openDir(ctx.io, abs, .{ .iterate = true }) catch return;
    defer dir.close(ctx.io);

    var entries: std.ArrayList(Entry) = .empty;
    defer {
        for (entries.items) |entry| entry.deinit(ctx.allocator);
        entries.deinit(ctx.allocator);
    }
    var it = dir.iterate();
    while (try it.next(ctx.io)) |entry| {
        try entries.append(ctx.allocator, .{ .name = try ctx.allocator.dupe(u8, entry.name), .is_dir = entry.kind == .directory });
    }
    std.mem.sort(Entry, entries.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    for (entries.items) |entry| {
        if (matches.items.len >= collect_limit) return;
        const child_rel = if (std.mem.eql(u8, rel, ".")) try ctx.allocator.dupe(u8, entry.name) else try std.fs.path.join(ctx.allocator, &.{ rel, entry.name });
        defer ctx.allocator.free(child_rel);
        if (isSkipped(child_rel)) continue;

        if (matchWildcard(pattern, entry.name)) {
            const suffix = if (entry.is_dir) "/" else "";
            try matches.append(ctx.allocator, try std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ child_rel, suffix }));
            if (matches.items.len >= collect_limit) return;
        }
        if (entry.is_dir) {
            const child_abs = try std.fs.path.join(ctx.allocator, &.{ abs, entry.name });
            defer ctx.allocator.free(child_abs);
            try walkSorted(ctx, child_abs, child_rel, pattern, collect_limit, matches);
        }
    }
}

fn matchWildcard(pattern: []const u8, text: []const u8) bool {
    return matchAt(pattern, text, 0, 0);
}
fn matchAt(pattern: []const u8, text: []const u8, pi: usize, ti: usize) bool {
    if (pi == pattern.len) return ti == text.len;
    if (pattern[pi] == '*') {
        var i = ti;
        while (i <= text.len) : (i += 1) if (matchAt(pattern, text, pi + 1, i)) return true;
        return false;
    }
    if (ti == text.len) return false;
    if (pattern[pi] == '?' or pattern[pi] == text[ti]) return matchAt(pattern, text, pi + 1, ti + 1);
    return false;
}

fn errorResult(ctx: *context_mod.ToolContext, code: []const u8, message: []const u8) !context_mod.ToolResult {
    return .{ .content_json = try json.errorJson(ctx.allocator, code, message), .is_error = true };
}
fn pathError(ctx: *context_mod.ToolContext, err: path_mod.PathPolicyError) !context_mod.ToolResult {
    return errorResult(ctx, @errorName(err), "path is outside workspace or invalid");
}
