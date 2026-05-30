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
    const literal = json.getBool(object, "literal", true);
    if (!literal) return errorResult(ctx, "unsupported_regex", "M3 grep supports literal matching only");
    const ignore_case = json.getBool(object, "ignore_case", false);
    const limit_i = json.getInteger(object, "limit", 100);
    const limit: usize = if (limit_i < 1) 1 else @intCast(limit_i);
    var norm = path_mod.normalizeWorkspacePath(ctx.allocator, ctx.workspace_root, input_path) catch |err| return pathError(ctx, err);
    defer norm.deinit(ctx.allocator);

    _ = std.Io.Dir.cwd().statFile(ctx.io, norm.absolute, .{}) catch return errorResult(ctx, "file_not_found", "path not found or unreadable");

    var matches: std.ArrayList(Match) = .empty;
    defer {
        for (matches.items) |m| m.deinit(ctx.allocator);
        matches.deinit(ctx.allocator);
    }
    var scan_truncated = false;
    var result_bytes: usize = 0;
    try scanPath(ctx, norm.relative, norm.absolute, pattern, ignore_case, limit + 1, &matches, &scan_truncated, &result_bytes);
    std.mem.sort(Match, matches.items, {}, struct {
        fn lessThan(_: void, a: Match, b: Match) bool {
            const path_order = std.mem.order(u8, a.path, b.path);
            if (path_order != .eq) return path_order == .lt;
            return a.line < b.line;
        }
    }.lessThan);
    const emit_count = @min(limit, matches.items.len);
    const truncated = scan_truncated or matches.items.len > limit;

    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer out.deinit();
    out.writer.writeAll("{\"ok\":true,\"matches\":[") catch return error.OutOfMemory;
    for (matches.items[0..emit_count], 0..) |m, i| {
        if (i > 0) out.writer.writeByte(',') catch return error.OutOfMemory;
        out.writer.writeAll("{\"path\":") catch return error.OutOfMemory;
        try json.writeJsonString(&out.writer, m.path);
        try out.writer.print(",\"line\":{d},\"text\":", .{m.line});
        try json.writeJsonString(&out.writer, m.text);
        out.writer.writeAll("}") catch return error.OutOfMemory;
    }
    out.writer.writeAll("],\"truncated\":") catch return error.OutOfMemory;
    out.writer.writeAll(if (truncated) "true" else "false") catch return error.OutOfMemory;
    out.writer.writeAll("}") catch return error.OutOfMemory;
    return .{ .content_json = try out.toOwnedSlice() };
}

const Match = struct {
    path: []const u8,
    line: usize,
    text: []const u8,
    fn deinit(self: Match, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.text);
    }
};

const FilePath = struct {
    rel: []const u8,
    abs: []const u8,
    fn deinit(self: FilePath, allocator: std.mem.Allocator) void {
        allocator.free(self.rel);
        allocator.free(self.abs);
    }
};

fn scanPath(ctx: *context_mod.ToolContext, rel: []const u8, abs: []const u8, pattern: []const u8, ignore_case: bool, collect_limit: usize, matches: *std.ArrayList(Match), truncated: *bool, result_bytes: *usize) !void {
    const stat = std.Io.Dir.cwd().statFile(ctx.io, abs, .{}) catch return;
    if (stat.kind == .directory) {
        var dir = std.Io.Dir.cwd().openDir(ctx.io, abs, .{ .iterate = true }) catch return;
        defer dir.close(ctx.io);
        var walker = try dir.walk(ctx.allocator);
        defer walker.deinit();
        var files: std.ArrayList(FilePath) = .empty;
        defer {
            for (files.items) |file| file.deinit(ctx.allocator);
            files.deinit(ctx.allocator);
        }
        while (try walker.next(ctx.io)) |entry| {
            if (entry.kind == .directory) continue;
            if (isSkipped(entry.path)) continue;
            const child_abs = try std.fs.path.join(ctx.allocator, &.{ abs, entry.path });
            errdefer ctx.allocator.free(child_abs);
            const child_rel = if (std.mem.eql(u8, rel, ".")) try ctx.allocator.dupe(u8, entry.path) else try std.fs.path.join(ctx.allocator, &.{ rel, entry.path });
            errdefer ctx.allocator.free(child_rel);
            try files.append(ctx.allocator, .{ .rel = child_rel, .abs = child_abs });
        }
        std.mem.sort(FilePath, files.items, {}, struct {
            fn lessThan(_: void, a: FilePath, b: FilePath) bool {
                return std.mem.lessThan(u8, a.rel, b.rel);
            }
        }.lessThan);
        for (files.items) |file| {
            if (matches.items.len >= collect_limit) {
                truncated.* = true;
                return;
            }
            try scanFile(ctx, file.rel, file.abs, pattern, ignore_case, collect_limit, matches, truncated, result_bytes);
            if (truncated.*) return;
        }
    } else {
        try scanFile(ctx, rel, abs, pattern, ignore_case, collect_limit, matches, truncated, result_bytes);
    }
}

fn scanFile(ctx: *context_mod.ToolContext, rel: []const u8, abs: []const u8, pattern: []const u8, ignore_case: bool, collect_limit: usize, matches: *std.ArrayList(Match), truncated: *bool, result_bytes: *usize) !void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(ctx.io, abs, ctx.allocator, .limited(ctx.limits.max_read_bytes)) catch |err| {
        if (err == error.StreamTooLong) truncated.* = true;
        return;
    };
    defer ctx.allocator.free(bytes);
    if (json.hasNul(bytes)) return;
    var line_no: usize = 1;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| : (line_no += 1) {
        if (matches.items.len >= collect_limit) {
            truncated.* = true;
            return;
        }
        if (!contains(line, pattern, ignore_case)) continue;
        const projected_bytes = result_bytes.* + rel.len + line.len + 64;
        if (projected_bytes > ctx.limits.max_result_bytes) {
            truncated.* = true;
            return;
        }
        const path_copy = try ctx.allocator.dupe(u8, rel);
        errdefer ctx.allocator.free(path_copy);
        const text_copy = try ctx.allocator.dupe(u8, line);
        errdefer ctx.allocator.free(text_copy);
        try matches.append(ctx.allocator, .{ .path = path_copy, .line = line_no, .text = text_copy });
        result_bytes.* = projected_bytes;
    }
}

fn contains(haystack: []const u8, needle: []const u8, ignore_case: bool) bool {
    if (!ignore_case) return std.mem.indexOf(u8, haystack, needle) != null;
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}
fn isSkipped(path: []const u8) bool {
    return std.mem.startsWith(u8, path, ".git/") or std.mem.startsWith(u8, path, ".zig-cache/") or std.mem.startsWith(u8, path, "zig-out/") or std.mem.startsWith(u8, path, "node_modules/");
}
fn errorResult(ctx: *context_mod.ToolContext, code: []const u8, message: []const u8) !context_mod.ToolResult {
    return .{ .content_json = try json.errorJson(ctx.allocator, code, message), .is_error = true };
}
fn pathError(ctx: *context_mod.ToolContext, err: path_mod.PathPolicyError) !context_mod.ToolResult {
    return errorResult(ctx, @errorName(err), "path is outside workspace or invalid");
}
