const std = @import("std");
const context_mod = @import("context.zig");
const approval = @import("approval.zig");
const json = @import("json.zig");
const metadata = @import("metadata.zig");
const output = @import("output.zig");

pub fn execute(ctx: *context_mod.ToolContext, args_json: []const u8) !context_mod.ToolResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch return errorResult(ctx, "invalid_arguments", "arguments must be valid JSON");
    defer parsed.deinit();
    const object = json.getObject(parsed.value) orelse return errorResult(ctx, "invalid_arguments", "arguments must be an object");
    const command = json.getString(object, "command") orelse return errorResult(ctx, "invalid_arguments", "command is required");
    const timeout_ms_i = json.getInteger(object, "timeout_ms", @intCast(ctx.limits.bash_timeout_ms));
    const timeout_ms: i64 = if (timeout_ms_i <= 0) @intCast(ctx.limits.bash_timeout_ms) else timeout_ms_i;

    const preview = try previewJson(ctx, command, timeout_ms);
    defer ctx.allocator.free(preview);
    const decision = ctx.approval.decide(.{ .kind = .run_bash, .tool_name = "bash", .summary = "run bash command", .preview_json = preview, .risk = .confirmation_required, .access = .execute_process }) catch return errorResult(ctx, "approval_failed", "approval backend failed");
    if (decision == .deny) return errorResult(ctx, "approval_denied", "approval denied");

    const argv = [_][]const u8{ "bash", "-lc", command };
    const capture_limit = @max(ctx.limits.max_bash_capture_bytes, ctx.limits.max_bash_output_bytes);
    const run_result = std.process.run(ctx.allocator, ctx.io, .{
        .argv = &argv,
        .cwd = .{ .path = ctx.workspace_root },
        .stdout_limit = .limited(capture_limit + 1),
        .stderr_limit = .limited(capture_limit + 1),
        .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(timeout_ms), .clock = .awake } },
    }) catch |err| switch (err) {
        error.Timeout => return errorResult(ctx, "timeout", "command timed out"),
        error.StreamTooLong => return errorResult(ctx, "output_too_large", "command output exceeded capture limit"),
        else => return errorResult(ctx, "spawn_failed", "failed to run command"),
    };
    defer ctx.allocator.free(run_result.stdout);
    defer ctx.allocator.free(run_result.stderr);

    var stdout_out = try output.truncateAndMaybeSpill(ctx.allocator, ctx.io, ctx.spill_dir, "stdout", run_result.stdout, ctx.limits.max_bash_output_bytes);
    defer stdout_out.deinit(ctx.allocator);
    var stderr_out = try output.truncateAndMaybeSpill(ctx.allocator, ctx.io, ctx.spill_dir, "stderr", run_result.stderr, ctx.limits.max_bash_output_bytes);
    defer stderr_out.deinit(ctx.allocator);

    const exit_code: i64 = switch (run_result.term) {
        .exited => |code| code,
        .signal => |sig| 128 + @intFromEnum(sig),
        .stopped => |sig| 128 + @intFromEnum(sig),
        .unknown => |code| @intCast(code),
    };

    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer out.deinit();
    out.writer.writeAll("{\"ok\":true,\"command\":") catch return error.OutOfMemory;
    try json.writeJsonString(&out.writer, command);
    try out.writer.print(",\"exit_code\":{d},\"stdout\":", .{exit_code});
    try json.writeJsonString(&out.writer, stdout_out.visible);
    out.writer.writeAll(",\"stderr\":") catch return error.OutOfMemory;
    try json.writeJsonString(&out.writer, stderr_out.visible);
    out.writer.writeAll(",\"truncated\":") catch return error.OutOfMemory;
    out.writer.writeAll(if (stdout_out.truncated or stderr_out.truncated) "true" else "false") catch return error.OutOfMemory;
    if (stdout_out.full_output_path) |path| {
        out.writer.writeAll(",\"stdout_full_output_path\":") catch return error.OutOfMemory;
        try json.writeJsonString(&out.writer, path);
    }
    if (stderr_out.full_output_path) |path| {
        out.writer.writeAll(",\"stderr_full_output_path\":") catch return error.OutOfMemory;
        try json.writeJsonString(&out.writer, path);
    }
    out.writer.writeAll("}") catch return error.OutOfMemory;
    return .{ .content_json = try out.toOwnedSlice() };
}

fn previewJson(ctx: *context_mod.ToolContext, command: []const u8, timeout_ms: i64) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer out.deinit();
    out.writer.writeAll("{\"command\":") catch return error.OutOfMemory;
    try json.writeJsonString(&out.writer, command);
    try out.writer.print(",\"timeout_ms\":{d}}}", .{timeout_ms});
    return out.toOwnedSlice() catch return error.OutOfMemory;
}
fn errorResult(ctx: *context_mod.ToolContext, code: []const u8, message: []const u8) !context_mod.ToolResult {
    return .{ .content_json = try json.errorJson(ctx.allocator, code, message), .is_error = true };
}
