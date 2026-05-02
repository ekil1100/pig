const std = @import("std");
const context_mod = @import("context.zig");
const approval = @import("approval.zig");
const metadata = @import("metadata.zig");
const json = @import("json.zig");
const path_mod = @import("path.zig");

pub fn execute(ctx: *context_mod.ToolContext, args_json: []const u8) !context_mod.ToolResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch return errorResult(ctx, "invalid_arguments", "arguments must be valid JSON");
    defer parsed.deinit();
    const object = json.getObject(parsed.value) orelse return errorResult(ctx, "invalid_arguments", "arguments must be an object");
    const input_path = json.getString(object, "path") orelse return errorResult(ctx, "invalid_arguments", "path is required");
    const content = json.getString(object, "content") orelse return errorResult(ctx, "invalid_arguments", "content is required");
    const mode = json.getString(object, "mode") orelse "create_new";
    const create_parents = json.getBool(object, "create_parents", false);
    var norm = path_mod.normalizeWorkspacePath(ctx.allocator, ctx.workspace_root, input_path) catch |err| return pathError(ctx, err);
    defer norm.deinit(ctx.allocator);

    const exists = fileExists(ctx, norm.absolute);
    if (std.mem.eql(u8, mode, "create_new") and exists) return errorResult(ctx, "file_exists", "file already exists");
    if (!std.mem.eql(u8, mode, "create_new") and !std.mem.eql(u8, mode, "overwrite") and !std.mem.eql(u8, mode, "append")) return errorResult(ctx, "invalid_arguments", "mode must be create_new, overwrite, or append");
    const old_bytes = fileSize(ctx, norm.absolute);

    const preview = try previewJson(ctx, norm.relative, mode, exists, old_bytes, content);
    defer ctx.allocator.free(preview);
    const decision = ctx.approval.decide(.{ .kind = .write_file, .tool_name = "write", .summary = "write file", .preview_json = preview, .risk = .confirmation_required, .access = .write_files }) catch return errorResult(ctx, "approval_failed", "approval backend failed");
    if (decision == .deny) return errorResult(ctx, "approval_denied", "approval denied");

    if (create_parents) {
        if (try path_mod.dirname(ctx.allocator, norm.relative)) |parent| {
            defer ctx.allocator.free(parent);
            const parent_abs = try std.fs.path.join(ctx.allocator, &.{ ctx.workspace_root, parent });
            defer ctx.allocator.free(parent_abs);
            try std.Io.Dir.cwd().createDirPath(ctx.io, parent_abs);
        }
    } else if (try path_mod.dirname(ctx.allocator, norm.relative)) |parent| {
        defer ctx.allocator.free(parent);
        const parent_abs = try std.fs.path.join(ctx.allocator, &.{ ctx.workspace_root, parent });
        defer ctx.allocator.free(parent_abs);
        std.Io.Dir.cwd().access(ctx.io, parent_abs, .{}) catch return errorResult(ctx, "parent_missing", "parent directory does not exist");
    }

    var final_content: []const u8 = content;
    var owned_final: ?[]u8 = null;
    defer if (owned_final) |v| ctx.allocator.free(v);
    if (std.mem.eql(u8, mode, "append") and exists) {
        const old = std.Io.Dir.cwd().readFileAlloc(ctx.io, norm.absolute, ctx.allocator, .limited(ctx.limits.max_read_bytes + content.len)) catch |err| switch (err) {
            error.StreamTooLong => return errorResult(ctx, "file_too_large", "existing file exceeds append read limit"),
            else => return errorResult(ctx, "read_failed", "failed to read existing file"),
        };
        defer ctx.allocator.free(old);
        owned_final = try std.mem.concat(ctx.allocator, u8, &.{ old, content });
        final_content = owned_final.?;
    }

    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = norm.absolute, .data = final_content, .flags = .{ .exclusive = std.mem.eql(u8, mode, "create_new") } });

    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer out.deinit();
    out.writer.writeAll("{\"ok\":true,\"path\":") catch return error.OutOfMemory;
    try json.writeJsonString(&out.writer, norm.relative);
    out.writer.writeAll(",\"mode\":") catch return error.OutOfMemory;
    try json.writeJsonString(&out.writer, mode);
    try out.writer.print(",\"bytes_written\":{d}}}", .{final_content.len});
    return .{ .content_json = try out.toOwnedSlice() };
}

fn fileExists(ctx: *context_mod.ToolContext, absolute: []const u8) bool {
    std.Io.Dir.cwd().access(ctx.io, absolute, .{}) catch return false;
    return true;
}

fn fileSize(ctx: *context_mod.ToolContext, absolute: []const u8) ?u64 {
    const stat = std.Io.Dir.cwd().statFile(ctx.io, absolute, .{}) catch return null;
    return stat.size;
}

const max_preview_bytes = 4096;

fn previewJson(ctx: *context_mod.ToolContext, relative: []const u8, mode: []const u8, exists: bool, old_bytes: ?u64, content: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer out.deinit();
    const preview_len = @min(content.len, max_preview_bytes);
    out.writer.writeAll("{\"path\":") catch return error.OutOfMemory;
    try json.writeJsonString(&out.writer, relative);
    out.writer.writeAll(",\"mode\":") catch return error.OutOfMemory;
    try json.writeJsonString(&out.writer, mode);
    try out.writer.print(",\"exists\":{},\"old_bytes\":", .{exists});
    if (old_bytes) |bytes| {
        try out.writer.print("{d}", .{bytes});
    } else {
        out.writer.writeAll("null") catch return error.OutOfMemory;
    }
    try out.writer.print(",\"new_bytes\":{d},\"content_preview\":", .{content.len});
    try json.writeJsonString(&out.writer, content[0..preview_len]);
    try out.writer.print(",\"content_truncated\":{}}}", .{content.len > preview_len});
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn errorResult(ctx: *context_mod.ToolContext, code: []const u8, message: []const u8) !context_mod.ToolResult {
    return .{ .content_json = try json.errorJson(ctx.allocator, code, message), .is_error = true };
}
fn pathError(ctx: *context_mod.ToolContext, err: path_mod.PathPolicyError) !context_mod.ToolResult {
    return errorResult(ctx, @errorName(err), "path is outside workspace or invalid");
}
