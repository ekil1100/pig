const std = @import("std");
const types = @import("types.zig");
const content = @import("content.zig");

pub const Role = types.Role;
pub const MessageView = struct {
    role: Role,
    content: []const content.ContentBlockView,
};

pub const OwnedMessage = struct {
    role: Role,
    content: []content.OwnedContentBlock,

    pub fn cloneFromView(allocator: std.mem.Allocator, view: MessageView) !OwnedMessage {
        const blocks = try allocator.alloc(content.OwnedContentBlock, view.content.len);
        errdefer allocator.free(blocks);
        var initialized: usize = 0;
        errdefer for (blocks[0..initialized]) |block| block.deinit(allocator);
        for (view.content, 0..) |block, i| {
            blocks[i] = try content.OwnedContentBlock.cloneFromView(allocator, block);
            initialized += 1;
        }
        return .{ .role = view.role, .content = blocks };
    }

    pub fn deinit(self: *OwnedMessage, allocator: std.mem.Allocator) void {
        for (self.content) |block| block.deinit(allocator);
        allocator.free(self.content);
        self.* = undefined;
    }
};
