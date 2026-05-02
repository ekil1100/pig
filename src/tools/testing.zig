const std = @import("std");
const context_mod = @import("context.zig");
const approval = @import("approval.zig");

pub const TempToolContext = struct {
    allocator: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    workspace_root: []const u8,
    spill_dir: []const u8,
    approval_impl: *approval.AllowAllApproval,
    context: context_mod.ToolContext,

    pub fn init(allocator: std.mem.Allocator) !TempToolContext {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        const workspace_root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        errdefer allocator.free(workspace_root);
        const spill_dir = try std.fs.path.join(allocator, &.{ workspace_root, ".pig-spill" });
        errdefer allocator.free(spill_dir);
        const approval_impl = try allocator.create(approval.AllowAllApproval);
        errdefer allocator.destroy(approval_impl);
        approval_impl.* = .{};
        return .{
            .allocator = allocator,
            .tmp = tmp,
            .workspace_root = workspace_root,
            .spill_dir = spill_dir,
            .approval_impl = approval_impl,
            .context = .{ .allocator = allocator, .io = std.testing.io, .workspace_root = workspace_root, .spill_dir = spill_dir, .approval = approval_impl.policy() },
        };
    }

    pub fn deinit(self: *TempToolContext) void {
        self.allocator.destroy(self.approval_impl);
        self.allocator.free(self.spill_dir);
        self.allocator.free(self.workspace_root);
        self.tmp.cleanup();
        self.* = undefined;
    }

    pub fn writeFile(self: *TempToolContext, path: []const u8, content: []const u8) !void {
        if (std.fs.path.dirname(path)) |parent| try self.tmp.dir.createDirPath(std.testing.io, parent);
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = content });
    }

    pub fn readFile(self: *TempToolContext, path: []const u8) ![]u8 {
        return try self.tmp.dir.readFileAlloc(std.testing.io, path, self.allocator, .limited(1024 * 1024));
    }
};
