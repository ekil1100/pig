const std = @import("std");
const agent_tool = @import("../core/agent/tool.zig");
const context_mod = @import("context.zig");
const metadata = @import("metadata.zig");
const read_tool = @import("read.zig");
const write_tool = @import("write.zig");
const edit_tool = @import("edit.zig");
const bash_tool = @import("bash.zig");
const grep_tool = @import("grep.zig");
const find_tool = @import("find.zig");
const ls_tool = @import("ls.zig");

pub const BuiltinToolOptions = struct { include_p1: bool = true };

const ToolAdapter = struct {
    context: *context_mod.ToolContext,
    name: []const u8,
};

fn riskName(risk: metadata.ToolRisk) []const u8 {
    return switch (risk) {
        .safe => "safe",
        .confirmation_required => "confirmation_required",
        .destructive => "destructive",
    };
}

fn accessName(access: metadata.ToolAccess) []const u8 {
    return switch (access) {
        .read_only => "read_only",
        .write_files => "write_files",
        .execute_process => "execute_process",
        .network => "network",
    };
}

pub const BuiltinToolSet = struct {
    context: *context_mod.ToolContext,
    adapters: []ToolAdapter,
    registrations: []agent_tool.ToolRegistration,

    pub fn deinit(self: *BuiltinToolSet, allocator: std.mem.Allocator) void {
        allocator.free(self.adapters);
        allocator.free(self.registrations);
        self.* = undefined;
    }
};

pub fn initBuiltinToolSet(allocator: std.mem.Allocator, context: *context_mod.ToolContext, options: BuiltinToolOptions) !BuiltinToolSet {
    const count: usize = if (options.include_p1) metadata.builtin_specs.len else 4;
    const adapters = try allocator.alloc(ToolAdapter, count);
    errdefer allocator.free(adapters);
    const registrations = try allocator.alloc(agent_tool.ToolRegistration, count);
    errdefer allocator.free(registrations);
    for (metadata.builtin_specs[0..count], 0..) |spec, i| {
        adapters[i] = .{ .context = context, .name = spec.name };
        registrations[i] = .{
            .spec = .{
                .name = spec.name,
                .description = spec.description,
                .schema_json = spec.schema_json,
                .display_label = spec.display_label,
                .risk_level = riskName(spec.risk),
                .access_kind = accessName(spec.access),
            },
            .executor = .{ .ptr = &adapters[i], .execute_fn = execute },
        };
    }
    return .{ .context = context, .adapters = adapters, .registrations = registrations };
}

fn execute(ptr: *anyopaque, exec_context: agent_tool.ToolExecutionContext, call: agent_tool.ToolCall) agent_tool.ToolExecutorError!agent_tool.ToolExecutionResult {
    const adapter: *ToolAdapter = @ptrCast(@alignCast(ptr));
    const result = dispatch(adapter.context, adapter.name, call.arguments_json) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ToolFailed,
    };
    errdefer result.deinit(adapter.context.allocator);
    const id = try exec_context.allocator.dupe(u8, call.id);
    errdefer exec_context.allocator.free(id);
    const content = try exec_context.allocator.dupe(u8, result.content_json);
    result.deinit(adapter.context.allocator);
    return .{ .tool_call_id = id, .content_json = content, .is_error = result.is_error };
}

fn dispatch(context: *context_mod.ToolContext, name: []const u8, args_json: []const u8) !context_mod.ToolResult {
    if (std.mem.eql(u8, name, "read")) return read_tool.execute(context, args_json);
    if (std.mem.eql(u8, name, "write")) return write_tool.execute(context, args_json);
    if (std.mem.eql(u8, name, "edit")) return edit_tool.execute(context, args_json);
    if (std.mem.eql(u8, name, "bash")) return bash_tool.execute(context, args_json);
    if (std.mem.eql(u8, name, "grep")) return grep_tool.execute(context, args_json);
    if (std.mem.eql(u8, name, "find")) return find_tool.execute(context, args_json);
    if (std.mem.eql(u8, name, "ls")) return ls_tool.execute(context, args_json);
    return error.UnknownTool;
}
