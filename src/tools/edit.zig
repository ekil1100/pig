const std = @import("std");
const context_mod = @import("context.zig");
const approval = @import("approval.zig");
const json = @import("json.zig");
const path_mod = @import("path.zig");

const Range = struct { start: usize, end: usize, old_text: []const u8, new_text: []const u8, order: usize };

pub fn execute(ctx: *context_mod.ToolContext, args_json: []const u8) !context_mod.ToolResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch return errorResult(ctx, "invalid_arguments", "arguments must be valid JSON");
    defer parsed.deinit();
    const object = json.getObject(parsed.value) orelse return errorResult(ctx, "invalid_arguments", "arguments must be an object");
    const input_path = json.getString(object, "path") orelse return errorResult(ctx, "invalid_arguments", "path is required");
    var norm = path_mod.normalizeWorkspacePath(ctx.allocator, ctx.workspace_root, input_path) catch |err| return pathError(ctx, err);
    defer norm.deinit(ctx.allocator);

    const edits_value = object.get("edits") orelse return errorResult(ctx, "invalid_arguments", "edits is required");
    if (edits_value != .array or edits_value.array.items.len == 0) return errorResult(ctx, "invalid_arguments", "edits must be a non-empty array");

    const content = std.Io.Dir.cwd().readFileAlloc(ctx.io, norm.absolute, ctx.allocator, .limited(ctx.limits.max_read_bytes)) catch |err| switch (err) {
        error.StreamTooLong => return errorResult(ctx, "file_too_large", "file exceeds max_read_bytes"),
        else => return errorResult(ctx, "file_not_found", "file not found"),
    };
    defer ctx.allocator.free(content);

    var ranges: std.ArrayList(Range) = .empty;
    defer ranges.deinit(ctx.allocator);
    for (edits_value.array.items, 0..) |item, idx| {
        if (item != .object) return errorResult(ctx, "invalid_arguments", "each edit must be an object");
        const old_text = json.getString(item.object, "old_text") orelse return errorResult(ctx, "invalid_arguments", "old_text is required");
        const new_text = json.getString(item.object, "new_text") orelse return errorResult(ctx, "invalid_arguments", "new_text is required");
        if (old_text.len == 0) return errorResult(ctx, "empty_old_text", "old_text must not be empty");
        const first = std.mem.indexOf(u8, content, old_text) orelse return errorResult(ctx, "old_text_not_found", "old_text was not found");
        if (std.mem.indexOf(u8, content[first + old_text.len ..], old_text) != null) return errorResult(ctx, "old_text_repeated", "old_text appears multiple times");
        try ranges.append(ctx.allocator, .{ .start = first, .end = first + old_text.len, .old_text = old_text, .new_text = new_text, .order = idx });
    }

    std.mem.sort(Range, ranges.items, {}, struct {
        fn lessThan(_: void, a: Range, b: Range) bool {
            if (a.start == b.start) return a.order < b.order;
            return a.start < b.start;
        }
    }.lessThan);
    for (ranges.items[1..], 1..) |range, i| {
        if (range.start < ranges.items[i - 1].end) return errorResult(ctx, "overlapping_edits", "edits overlap");
    }

    const preview = try previewJson(ctx, norm.relative, ranges.items, content.len);
    defer ctx.allocator.free(preview);
    const decision = ctx.approval.decide(.{ .kind = .edit_file, .tool_name = "edit", .summary = "edit file", .preview_json = preview, .risk = .confirmation_required, .access = .write_files }) catch return errorResult(ctx, "approval_failed", "approval backend failed");
    if (decision == .deny) return errorResult(ctx, "approval_denied", "approval denied");

    var out_content: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer out_content.deinit();
    var pos: usize = 0;
    for (ranges.items) |range| {
        out_content.writer.writeAll(content[pos..range.start]) catch return error.OutOfMemory;
        out_content.writer.writeAll(range.new_text) catch return error.OutOfMemory;
        pos = range.end;
    }
    out_content.writer.writeAll(content[pos..]) catch return error.OutOfMemory;
    const new_content = try out_content.toOwnedSlice();
    defer ctx.allocator.free(new_content);
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = norm.absolute, .data = new_content });

    var result: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer result.deinit();
    result.writer.writeAll("{\"ok\":true,\"path\":") catch return error.OutOfMemory;
    try json.writeJsonString(&result.writer, norm.relative);
    try result.writer.print(",\"edit_count\":{d},\"old_bytes\":{d},\"new_bytes\":{d}}}", .{ ranges.items.len, content.len, new_content.len });
    return .{ .content_json = try result.toOwnedSlice() };
}

const max_preview_bytes = 2048;

fn previewJson(ctx: *context_mod.ToolContext, relative: []const u8, ranges: []const Range, old_bytes: usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer out.deinit();
    out.writer.writeAll("{\"path\":") catch return error.OutOfMemory;
    try json.writeJsonString(&out.writer, relative);
    try out.writer.print(",\"edit_count\":{d},\"old_bytes\":{d},\"edits\":[", .{ ranges.len, old_bytes });
    for (ranges, 0..) |range, i| {
        if (i > 0) out.writer.writeByte(',') catch return error.OutOfMemory;
        const old_preview_len = @min(range.old_text.len, max_preview_bytes);
        const new_preview_len = @min(range.new_text.len, max_preview_bytes);
        try out.writer.print("{{\"start\":{d},\"end\":{d},\"old_text_preview\":", .{ range.start, range.end });
        try json.writeJsonString(&out.writer, range.old_text[0..old_preview_len]);
        out.writer.writeAll(",\"new_text_preview\":") catch return error.OutOfMemory;
        try json.writeJsonString(&out.writer, range.new_text[0..new_preview_len]);
        try out.writer.print(",\"old_text_truncated\":{},\"new_text_truncated\":{}}}", .{ range.old_text.len > old_preview_len, range.new_text.len > new_preview_len });
    }
    out.writer.writeAll("]}") catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn errorResult(ctx: *context_mod.ToolContext, code: []const u8, message: []const u8) !context_mod.ToolResult {
    return .{ .content_json = try json.errorJson(ctx.allocator, code, message), .is_error = true };
}
fn pathError(ctx: *context_mod.ToolContext, err: path_mod.PathPolicyError) !context_mod.ToolResult {
    return errorResult(ctx, @errorName(err), "path is outside workspace or invalid");
}
