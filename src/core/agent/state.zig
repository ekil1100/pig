const std = @import("std");
const provider = @import("../../provider/mod.zig");
const tool = @import("tool.zig");

pub const ThinkingLevel = enum { off, low, medium, high, xhigh, max };
pub const AgentStatus = enum { idle, running, awaiting_provider, executing_tools, completed, failed, aborted };

pub const AgentConfig = struct {
    system_prompt: ?[]const u8 = null,
    thinking_level: ThinkingLevel = .off,
};

pub const AgentErrorInfo = struct { message: []const u8 };

pub const PendingToolCall = struct {
    index: u32,
    id: []const u8,
    name: []const u8,
    arguments_json: []const u8,

    pub fn clone(allocator: std.mem.Allocator, index: u32, id: []const u8, name: []const u8, arguments_json: []const u8) !PendingToolCall {
        const owned_id = try allocator.dupe(u8, id);
        errdefer allocator.free(owned_id);
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        const owned_args = try allocator.dupe(u8, arguments_json);
        errdefer allocator.free(owned_args);
        return .{ .index = index, .id = owned_id, .name = owned_name, .arguments_json = owned_args };
    }

    pub fn deinit(self: PendingToolCall, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.arguments_json);
    }
};

pub const StreamAccumulator = struct {
    text: std.ArrayList(u8) = .empty,
    thinking: std.ArrayList(u8) = .empty,
    thinking_signature: std.ArrayList(u8) = .empty,
    tool_calls: std.ArrayList(PendingToolCall) = .empty,
    saw_done: bool = false,
    usage: provider.Usage = .{},

    pub fn resetRetainingCapacity(self: *StreamAccumulator, allocator: std.mem.Allocator) void {
        self.text.clearRetainingCapacity();
        self.thinking.clearRetainingCapacity();
        self.thinking_signature.clearRetainingCapacity();
        for (self.tool_calls.items) |call| call.deinit(allocator);
        self.tool_calls.clearRetainingCapacity();
        self.saw_done = false;
        self.usage = .{};
    }

    pub fn deinit(self: *StreamAccumulator, allocator: std.mem.Allocator) void {
        self.text.deinit(allocator);
        self.thinking.deinit(allocator);
        self.thinking_signature.deinit(allocator);
        for (self.tool_calls.items) |call| call.deinit(allocator);
        self.tool_calls.deinit(allocator);
        self.* = undefined;
    }
};

pub const MessageViewBatch = struct {
    messages: []provider.MessageView,
    content_views: [][]provider.ContentBlockView,

    pub fn deinit(self: *MessageViewBatch, allocator: std.mem.Allocator) void {
        for (self.content_views) |views| allocator.free(views);
        allocator.free(self.content_views);
        allocator.free(self.messages);
        self.* = undefined;
    }
};

pub const AgentState = struct {
    allocator: std.mem.Allocator,
    config: AgentConfig,
    status: AgentStatus = .idle,
    messages: std.ArrayList(provider.OwnedMessage) = .empty,
    stream: StreamAccumulator = .{},
    last_error: ?AgentErrorInfo = null,

    pub fn init(allocator: std.mem.Allocator, config: AgentConfig) AgentState {
        return .{ .allocator = allocator, .config = config };
    }

    pub fn deinit(self: *AgentState) void {
        for (self.messages.items) |*message| message.deinit(self.allocator);
        self.messages.deinit(self.allocator);
        self.stream.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn appendUserText(self: *AgentState, text: []const u8) !void {
        const blocks = [_]provider.ContentBlockView{.{ .text = .{ .text = text } }};
        var owned = try provider.OwnedMessage.cloneFromView(self.allocator, .{ .role = .user, .content = &blocks });
        errdefer owned.deinit(self.allocator);
        try self.messages.append(self.allocator, owned);
    }

    pub fn appendAssistantFromStream(self: *AgentState) !void {
        const count = @as(usize, if (self.stream.text.items.len > 0) 1 else 0) +
            @as(usize, if (self.stream.thinking.items.len > 0) 1 else 0) + self.stream.tool_calls.items.len;
        const blocks = try self.allocator.alloc(provider.ContentBlockView, count);
        defer self.allocator.free(blocks);
        var i: usize = 0;
        if (self.stream.text.items.len > 0) {
            blocks[i] = .{ .text = .{ .text = self.stream.text.items } };
            i += 1;
        }
        if (self.stream.thinking.items.len > 0) {
            blocks[i] = .{ .thinking = .{ .text = self.stream.thinking.items, .signature = if (self.stream.thinking_signature.items.len > 0) self.stream.thinking_signature.items else null } };
            i += 1;
        }
        for (self.stream.tool_calls.items) |call| {
            blocks[i] = .{ .tool_call = .{ .id = call.id, .name = call.name, .arguments_json = call.arguments_json } };
            i += 1;
        }
        var owned = try provider.OwnedMessage.cloneFromView(self.allocator, .{ .role = .assistant, .content = blocks });
        errdefer owned.deinit(self.allocator);
        try self.messages.append(self.allocator, owned);
    }

    pub fn appendToolResult(self: *AgentState, result: tool.ToolExecutionResult) !void {
        const blocks = [_]provider.ContentBlockView{.{ .tool_result = .{ .tool_call_id = result.tool_call_id, .content_json = result.content_json, .is_error = result.is_error } }};
        var owned = try provider.OwnedMessage.cloneFromView(self.allocator, .{ .role = .tool, .content = &blocks });
        errdefer owned.deinit(self.allocator);
        try self.messages.append(self.allocator, owned);
    }

    pub fn messageViews(self: *AgentState, allocator: std.mem.Allocator) !MessageViewBatch {
        const messages = try allocator.alloc(provider.MessageView, self.messages.items.len);
        errdefer allocator.free(messages);
        const content_views = try allocator.alloc([]provider.ContentBlockView, self.messages.items.len);
        errdefer allocator.free(content_views);
        var initialized: usize = 0;
        errdefer for (content_views[0..initialized]) |views| allocator.free(views);
        for (self.messages.items, 0..) |message, i| {
            const views = try allocator.alloc(provider.ContentBlockView, message.content.len);
            content_views[i] = views;
            initialized += 1;
            for (message.content, 0..) |block, j| views[j] = viewFromOwned(block);
            messages[i] = .{ .role = message.role, .content = views };
        }
        return .{ .messages = messages, .content_views = content_views };
    }
};

fn viewFromOwned(block: provider.OwnedContentBlock) provider.ContentBlockView {
    return switch (block) {
        .text => |b| .{ .text = b },
        .image_ref => |b| .{ .image_ref = b },
        .thinking => |b| .{ .thinking = b },
        .tool_call => |b| .{ .tool_call = b },
        .tool_result => |b| .{ .tool_result = b },
    };
}
