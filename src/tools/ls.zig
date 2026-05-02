const std = @import("std");
const context_mod = @import("context.zig");
const json = @import("json.zig");
const path_mod = @import("path.zig");

pub fn execute(ctx: *context_mod.ToolContext, args_json: []const u8) !context_mod.ToolResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch return errorResult(ctx, "invalid_arguments", "arguments must be valid JSON");
    defer parsed.deinit();
    const object = json.getObject(parsed.value) orelse return errorResult(ctx, "invalid_arguments", "arguments must be an object");
    const input_path = json.getString(object, "path") orelse ".";
    const limit_i = json.getInteger(object, "limit", 500);
    const limit: usize = if (limit_i < 1) 1 else @intCast(limit_i);
    var norm = path_mod.normalizeWorkspacePath(ctx.allocator, ctx.workspace_root, input_path) catch |err| return pathError(ctx, err);
    defer norm.deinit(ctx.allocator);

    var dir = std.Io.Dir.cwd().openDir(ctx.io, norm.absolute, .{ .iterate = true }) catch return errorResult(ctx, "not_directory", "path is not a directory");
    defer dir.close(ctx.io);
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| ctx.allocator.free(n);
        names.deinit(ctx.allocator);
    }
    var it = dir.iterate();
    while (try it.next(ctx.io)) |entry| {
        const suffix = if (entry.kind == .directory) "/" else "";
        try names.append(ctx.allocator, try std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ entry.name, suffix }));
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer out.deinit();
    out.writer.writeAll("{\"ok\":true,\"path\":") catch return error.OutOfMemory;
    try json.writeJsonString(&out.writer, norm.relative);
    out.writer.writeAll(",\"entries\":[") catch return error.OutOfMemory;
    var rendered_bytes: usize = 0;
    var output_truncated = names.items.len > limit;
    for (names.items[0..@min(limit, names.items.len)], 0..) |name, i| {
        const projected_bytes = rendered_bytes + name.len + 4;
        if (projected_bytes > ctx.limits.max_result_bytes) {
            output_truncated = true;
            break;
        }
        if (i > 0) out.writer.writeByte(',') catch return error.OutOfMemory;
        try json.writeJsonString(&out.writer, name);
        rendered_bytes = projected_bytes;
    }
    out.writer.writeAll("],\"truncated\":") catch return error.OutOfMemory;
    out.writer.writeAll(if (output_truncated) "true" else "false") catch return error.OutOfMemory;
    out.writer.writeAll("}") catch return error.OutOfMemory;
    return .{ .content_json = try out.toOwnedSlice() };
}

fn errorResult(ctx: *context_mod.ToolContext, code: []const u8, message: []const u8) !context_mod.ToolResult {
    return .{ .content_json = try json.errorJson(ctx.allocator, code, message), .is_error = true };
}
fn pathError(ctx: *context_mod.ToolContext, err: path_mod.PathPolicyError) !context_mod.ToolResult {
    return errorResult(ctx, @errorName(err), "path is outside workspace or invalid");
}
