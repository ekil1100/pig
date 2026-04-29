const std = @import("std");

pub const TextBlock = struct { text: []const u8 };
pub const ImageRefBlock = struct { uri: []const u8, mime_type: ?[]const u8 = null };
pub const ThinkingBlock = struct { text: []const u8, signature: ?[]const u8 = null };
pub const ToolCallBlock = struct { id: []const u8, name: []const u8, arguments_json: []const u8 };
pub const ToolResultBlock = struct { tool_call_id: []const u8, content_json: []const u8, is_error: bool = false };

pub const ContentBlockView = union(enum) {
    text: TextBlock,
    image_ref: ImageRefBlock,
    thinking: ThinkingBlock,
    tool_call: ToolCallBlock,
    tool_result: ToolResultBlock,
};

pub const OwnedContentBlock = union(enum) {
    text: TextBlock,
    image_ref: ImageRefBlock,
    thinking: ThinkingBlock,
    tool_call: ToolCallBlock,
    tool_result: ToolResultBlock,

    pub fn cloneFromView(allocator: std.mem.Allocator, view: ContentBlockView) !OwnedContentBlock {
        return switch (view) {
            .text => |b| cloneText(allocator, b),
            .image_ref => |b| cloneImageRef(allocator, b),
            .thinking => |b| cloneThinking(allocator, b),
            .tool_call => |b| cloneToolCall(allocator, b),
            .tool_result => |b| cloneToolResult(allocator, b),
        };
    }

    pub fn deinit(self: OwnedContentBlock, allocator: std.mem.Allocator) void {
        switch (self) {
            .text => |b| allocator.free(b.text),
            .image_ref => |b| {
                allocator.free(b.uri);
                if (b.mime_type) |m| allocator.free(m);
            },
            .thinking => |b| {
                allocator.free(b.text);
                if (b.signature) |sig| allocator.free(sig);
            },
            .tool_call => |b| {
                allocator.free(b.id);
                allocator.free(b.name);
                allocator.free(b.arguments_json);
            },
            .tool_result => |b| {
                allocator.free(b.tool_call_id);
                allocator.free(b.content_json);
            },
        }
    }
};

fn cloneText(allocator: std.mem.Allocator, block: TextBlock) !OwnedContentBlock {
    return .{ .text = .{ .text = try allocator.dupe(u8, block.text) } };
}

fn cloneImageRef(allocator: std.mem.Allocator, block: ImageRefBlock) !OwnedContentBlock {
    const uri = try allocator.dupe(u8, block.uri);
    errdefer allocator.free(uri);
    const mime_type = if (block.mime_type) |mime| try allocator.dupe(u8, mime) else null;
    errdefer if (mime_type) |mime| allocator.free(mime);
    return .{ .image_ref = .{ .uri = uri, .mime_type = mime_type } };
}

fn cloneThinking(allocator: std.mem.Allocator, block: ThinkingBlock) !OwnedContentBlock {
    const text = try allocator.dupe(u8, block.text);
    errdefer allocator.free(text);
    const signature = if (block.signature) |sig| try allocator.dupe(u8, sig) else null;
    errdefer if (signature) |sig| allocator.free(sig);
    return .{ .thinking = .{ .text = text, .signature = signature } };
}

fn cloneToolCall(allocator: std.mem.Allocator, block: ToolCallBlock) !OwnedContentBlock {
    const id = try allocator.dupe(u8, block.id);
    errdefer allocator.free(id);
    const name = try allocator.dupe(u8, block.name);
    errdefer allocator.free(name);
    const arguments_json = try allocator.dupe(u8, block.arguments_json);
    errdefer allocator.free(arguments_json);
    return .{ .tool_call = .{ .id = id, .name = name, .arguments_json = arguments_json } };
}

fn cloneToolResult(allocator: std.mem.Allocator, block: ToolResultBlock) !OwnedContentBlock {
    const tool_call_id = try allocator.dupe(u8, block.tool_call_id);
    errdefer allocator.free(tool_call_id);
    const content_json = try allocator.dupe(u8, block.content_json);
    errdefer allocator.free(content_json);
    return .{ .tool_result = .{ .tool_call_id = tool_call_id, .content_json = content_json, .is_error = block.is_error } };
}
