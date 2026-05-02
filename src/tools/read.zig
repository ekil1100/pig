const std = @import("std");
const context_mod = @import("context.zig");
const json = @import("json.zig");
const path_mod = @import("path.zig");

pub fn execute(ctx: *context_mod.ToolContext, args_json: []const u8) !context_mod.ToolResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch return errorResult(ctx, "invalid_arguments", "arguments must be valid JSON");
    defer parsed.deinit();
    const object = json.getObject(parsed.value) orelse return errorResult(ctx, "invalid_arguments", "arguments must be an object");
    const input_path = json.getString(object, "path") orelse return errorResult(ctx, "invalid_arguments", "path is required");
    var norm = path_mod.normalizeWorkspacePath(ctx.allocator, ctx.workspace_root, input_path) catch |err| return pathError(ctx, err);
    defer norm.deinit(ctx.allocator);

    const offset_i = json.getInteger(object, "offset", 1);
    const limit_i = json.getInteger(object, "limit", 200);
    const offset: usize = if (offset_i < 1) 1 else @intCast(offset_i);
    const limit_uncapped: usize = if (limit_i < 1) 1 else @intCast(limit_i);
    const limit = @min(limit_uncapped, 2000);

    const bytes = std.Io.Dir.cwd().readFileAlloc(ctx.io, norm.absolute, ctx.allocator, .limited(ctx.limits.max_read_bytes)) catch |err| switch (err) {
        error.StreamTooLong => return errorResult(ctx, "file_too_large", "file exceeds max_read_bytes"),
        else => return errorResult(ctx, "file_not_found", "file not found or unreadable"),
    };
    defer ctx.allocator.free(bytes);
    if (json.hasNul(bytes)) return errorResult(ctx, "binary_file", "file appears to be binary");

    var line_no: usize = 1;
    var emitted: usize = 0;
    var content_bytes: usize = 0;
    var truncated = false;
    const content_limit = visibleContentLimit(ctx);
    var w: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer w.deinit();
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| : (line_no += 1) {
        if (line_no < offset) continue;
        if (emitted >= limit) {
            truncated = true;
            break;
        }
        if (emitted > 0) {
            if (content_bytes >= content_limit) {
                truncated = true;
                break;
            }
            w.writer.writeByte('\n') catch return error.OutOfMemory;
            content_bytes += 1;
        }
        const remaining = content_limit -| content_bytes;
        if (line.len > remaining) {
            w.writer.writeAll(line[0..remaining]) catch return error.OutOfMemory;
            truncated = true;
            break;
        }
        w.writer.writeAll(line) catch return error.OutOfMemory;
        content_bytes += line.len;
        emitted += 1;
    }
    const content = try w.toOwnedSlice();
    defer ctx.allocator.free(content);

    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer out.deinit();
    out.writer.writeAll("{\"ok\":true,\"path\":") catch return error.OutOfMemory;
    try json.writeJsonString(&out.writer, norm.relative);
    try out.writer.print(",\"offset\":{d},\"line_count\":{d},\"content\":", .{ offset, emitted });
    try json.writeJsonString(&out.writer, content);
    out.writer.writeAll(",\"truncated\":") catch return error.OutOfMemory;
    out.writer.writeAll(if (truncated) "true" else "false") catch return error.OutOfMemory;
    out.writer.writeAll("}") catch return error.OutOfMemory;
    return .{ .content_json = try out.toOwnedSlice() };
}

fn visibleContentLimit(ctx: *context_mod.ToolContext) usize {
    return if (ctx.limits.max_result_bytes > 512) ctx.limits.max_result_bytes - 512 else ctx.limits.max_result_bytes;
}

fn errorResult(ctx: *context_mod.ToolContext, code: []const u8, message: []const u8) !context_mod.ToolResult {
    return .{ .content_json = try json.errorJson(ctx.allocator, code, message), .is_error = true };
}

fn pathError(ctx: *context_mod.ToolContext, err: path_mod.PathPolicyError) !context_mod.ToolResult {
    return errorResult(ctx, @errorName(err), "path is outside workspace or invalid");
}
