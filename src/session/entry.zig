const std = @import("std");
const json = @import("../util/json.zig");

pub const schema_version: u32 = 1;

pub const ParseError = error{
    InvalidEntry,
    UnsupportedSchema,
} || std.mem.Allocator.Error;

pub const EntryKind = enum {
    header,
    message,
    tool_event,
    tool_result,
    model_change,
    thinking_level_change,
    session_info,
    label,
    branch_summary,
    compaction,
    custom,

    pub fn toString(kind: EntryKind) []const u8 {
        return @tagName(kind);
    }

    pub fn fromString(value: []const u8) ParseError!EntryKind {
        inline for (std.meta.fields(EntryKind)) |field| {
            if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
        }
        return error.InvalidEntry;
    }
};

pub const Role = enum {
    system,
    user,
    assistant,
    tool,

    pub fn toString(role: Role) []const u8 {
        return @tagName(role);
    }

    pub fn fromString(value: []const u8) ParseError!Role {
        inline for (std.meta.fields(Role)) |field| {
            if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
        }
        return error.InvalidEntry;
    }
};

pub const ContentBlock = union(enum) {
    text: struct { text: []const u8 },
    image_ref: struct { uri: []const u8, mime_type: ?[]const u8 = null },
    thinking: struct { text: []const u8, signature: ?[]const u8 = null },
    tool_call: struct { id: []const u8, name: []const u8, arguments_json: []const u8 },
    tool_result: struct { tool_call_id: []const u8, content_json: []const u8, is_error: bool = false },

    pub fn deinit(self: ContentBlock, allocator: std.mem.Allocator) void {
        switch (self) {
            .text => |b| allocator.free(b.text),
            .image_ref => |b| {
                allocator.free(b.uri);
                if (b.mime_type) |mime| allocator.free(mime);
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

pub const HeaderData = struct {
    cwd: ?[]const u8 = null,
    title: ?[]const u8 = null,
    pig_version: ?[]const u8 = null,
};

pub const MessageData = struct {
    role: Role,
    content: []const ContentBlock,
};

pub const ToolEventData = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    phase: []const u8,
};

pub const ToolResultData = struct {
    tool_call_id: []const u8,
    is_error: bool,
    content_json: []const u8,
};

pub const ModelChangeData = struct {
    provider: []const u8,
    model: []const u8,
};

pub const ThinkingLevelChangeData = struct {
    level: []const u8,
};

pub const SessionInfoData = struct {
    title: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    current_leaf_id: ?[]const u8 = null,
};

pub const LabelData = struct {
    text: []const u8,
};

pub const BranchSummaryData = struct {
    target_id: []const u8,
    summary: []const u8,
};

pub const CompactionData = struct {
    target_id: []const u8,
    summary: []const u8,
};

pub const CustomData = struct {
    name: []const u8,
    payload_json: ?[]const u8 = null,
};

pub const EntryData = union(EntryKind) {
    header: HeaderData,
    message: MessageData,
    tool_event: ToolEventData,
    tool_result: ToolResultData,
    model_change: ModelChangeData,
    thinking_level_change: ThinkingLevelChangeData,
    session_info: SessionInfoData,
    label: LabelData,
    branch_summary: BranchSummaryData,
    compaction: CompactionData,
    custom: CustomData,

    pub fn deinit(self: EntryData, allocator: std.mem.Allocator) void {
        switch (self) {
            .header => |d| {
                if (d.cwd) |v| allocator.free(v);
                if (d.title) |v| allocator.free(v);
                if (d.pig_version) |v| allocator.free(v);
            },
            .message => |d| {
                for (d.content) |block| block.deinit(allocator);
                allocator.free(d.content);
            },
            .tool_event => |d| {
                allocator.free(d.tool_call_id);
                allocator.free(d.tool_name);
                allocator.free(d.phase);
            },
            .tool_result => |d| {
                allocator.free(d.tool_call_id);
                allocator.free(d.content_json);
            },
            .model_change => |d| {
                allocator.free(d.provider);
                allocator.free(d.model);
            },
            .thinking_level_change => |d| allocator.free(d.level),
            .session_info => |d| {
                if (d.title) |v| allocator.free(v);
                if (d.cwd) |v| allocator.free(v);
                if (d.current_leaf_id) |v| allocator.free(v);
            },
            .label => |d| allocator.free(d.text),
            .branch_summary => |d| {
                allocator.free(d.target_id);
                allocator.free(d.summary);
            },
            .compaction => |d| {
                allocator.free(d.target_id);
                allocator.free(d.summary);
            },
            .custom => |d| {
                allocator.free(d.name);
                if (d.payload_json) |v| allocator.free(v);
            },
        }
    }
};

pub const EntryView = struct {
    schema: u32 = schema_version,
    id: []const u8,
    session_id: []const u8,
    parent_id: ?[]const u8,
    created_ms: i64,
    data: EntryData,

    pub fn kind(self: EntryView) EntryKind {
        return std.meta.activeTag(self.data);
    }
};

pub const Entry = struct {
    schema: u32 = schema_version,
    id: []const u8,
    session_id: []const u8,
    parent_id: ?[]const u8,
    created_ms: i64,
    data: EntryData,

    pub fn view(self: Entry) EntryView {
        return .{
            .schema = self.schema,
            .id = self.id,
            .session_id = self.session_id,
            .parent_id = self.parent_id,
            .created_ms = self.created_ms,
            .data = self.data,
        };
    }

    pub fn kind(self: Entry) EntryKind {
        return std.meta.activeTag(self.data);
    }

    pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.session_id);
        if (self.parent_id) |v| allocator.free(v);
        self.data.deinit(allocator);
        self.* = undefined;
    }
};

pub fn cloneFromView(allocator: std.mem.Allocator, view: EntryView) !Entry {
    const id = try allocator.dupe(u8, view.id);
    errdefer allocator.free(id);
    const session_id = try allocator.dupe(u8, view.session_id);
    errdefer allocator.free(session_id);
    const parent_id = try dupeOptional(allocator, view.parent_id);
    errdefer if (parent_id) |v| allocator.free(v);
    const data = try cloneData(allocator, view.data);
    errdefer data.deinit(allocator);
    return .{
        .schema = view.schema,
        .id = id,
        .session_id = session_id,
        .parent_id = parent_id,
        .created_ms = view.created_ms,
        .data = data,
    };
}

pub fn writeLine(allocator: std.mem.Allocator, view: EntryView) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.print("{{\"schema\":{d},\"id\":", .{view.schema});
    try json.writeJsonString(&out.writer, view.id);
    out.writer.writeAll(",\"session_id\":") catch return error.OutOfMemory;
    try json.writeJsonString(&out.writer, view.session_id);
    out.writer.writeAll(",\"parent_id\":") catch return error.OutOfMemory;
    if (view.parent_id) |parent| {
        try json.writeJsonString(&out.writer, parent);
    } else {
        out.writer.writeAll("null") catch return error.OutOfMemory;
    }
    out.writer.writeAll(",\"kind\":") catch return error.OutOfMemory;
    try json.writeJsonString(&out.writer, view.kind().toString());
    try out.writer.print(",\"created_ms\":{d}", .{view.created_ms});
    try writePayload(&out.writer, view.data);
    out.writer.writeByte('}') catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

pub fn parseLine(allocator: std.mem.Allocator, bytes: []const u8) ParseError!Entry {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidEntry,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidEntry;
    const object = parsed.value.object;
    const schema_i = json.intField(object, "schema") orelse return error.InvalidEntry;
    if (schema_i != schema_version) return error.UnsupportedSchema;
    const id = json.stringField(object, "id") orelse return error.InvalidEntry;
    const session_id = json.stringField(object, "session_id") orelse return error.InvalidEntry;
    const parent_id = blk: {
        const parent_value = object.get("parent_id") orelse return error.InvalidEntry;
        if (parent_value == .null) break :blk null;
        if (parent_value != .string) return error.InvalidEntry;
        break :blk parent_value.string;
    };
    const kind_name = json.stringField(object, "kind") orelse return error.InvalidEntry;
    const kind = try EntryKind.fromString(kind_name);
    const created_ms = json.intField(object, "created_ms") orelse return error.InvalidEntry;
    const data = try parseData(allocator, object, kind);
    errdefer data.deinit(allocator);
    const view = EntryView{
        .schema = schema_version,
        .id = id,
        .session_id = session_id,
        .parent_id = parent_id,
        .created_ms = created_ms,
        .data = data,
    };
    const owned = try cloneFromView(allocator, view);
    data.deinit(allocator);
    return owned;
}

fn writePayload(writer: *std.Io.Writer, data: EntryData) error{OutOfMemory}!void {
    switch (data) {
        .header => |d| {
            try writeOptionalStringField(writer, "cwd", d.cwd);
            try writeOptionalStringField(writer, "title", d.title);
            try writeOptionalStringField(writer, "pig_version", d.pig_version);
        },
        .message => |d| {
            writer.writeAll(",\"role\":") catch return error.OutOfMemory;
            try json.writeJsonString(writer, d.role.toString());
            writer.writeAll(",\"content\":[") catch return error.OutOfMemory;
            for (d.content, 0..) |block, i| {
                if (i > 0) writer.writeByte(',') catch return error.OutOfMemory;
                try writeContentBlock(writer, block);
            }
            writer.writeByte(']') catch return error.OutOfMemory;
        },
        .tool_event => |d| {
            try writeStringField(writer, "tool_call_id", d.tool_call_id);
            try writeStringField(writer, "tool_name", d.tool_name);
            try writeStringField(writer, "phase", d.phase);
        },
        .tool_result => |d| {
            try writeStringField(writer, "tool_call_id", d.tool_call_id);
            writer.writeAll(",\"is_error\":") catch return error.OutOfMemory;
            writer.writeAll(if (d.is_error) "true" else "false") catch return error.OutOfMemory;
            try writeStringField(writer, "content_json", d.content_json);
        },
        .model_change => |d| {
            try writeStringField(writer, "provider", d.provider);
            try writeStringField(writer, "model", d.model);
        },
        .thinking_level_change => |d| try writeStringField(writer, "level", d.level),
        .session_info => |d| {
            try writeOptionalStringField(writer, "title", d.title);
            try writeOptionalStringField(writer, "cwd", d.cwd);
            try writeOptionalStringField(writer, "current_leaf_id", d.current_leaf_id);
        },
        .label => |d| try writeStringField(writer, "text", d.text),
        .branch_summary => |d| {
            try writeStringField(writer, "target_id", d.target_id);
            try writeStringField(writer, "summary", d.summary);
        },
        .compaction => |d| {
            try writeStringField(writer, "target_id", d.target_id);
            try writeStringField(writer, "summary", d.summary);
        },
        .custom => |d| {
            try writeStringField(writer, "name", d.name);
            try writeOptionalStringField(writer, "payload_json", d.payload_json);
        },
    }
}

fn writeContentBlock(writer: *std.Io.Writer, block: ContentBlock) error{OutOfMemory}!void {
    writer.writeByte('{') catch return error.OutOfMemory;
    switch (block) {
        .text => |b| {
            try writeStringFieldFirst(writer, "type", "text");
            try writeStringField(writer, "text", b.text);
        },
        .image_ref => |b| {
            try writeStringFieldFirst(writer, "type", "image_ref");
            try writeStringField(writer, "uri", b.uri);
            try writeOptionalStringField(writer, "mime_type", b.mime_type);
        },
        .thinking => |b| {
            try writeStringFieldFirst(writer, "type", "thinking");
            try writeStringField(writer, "text", b.text);
            try writeOptionalStringField(writer, "signature", b.signature);
        },
        .tool_call => |b| {
            try writeStringFieldFirst(writer, "type", "tool_call");
            try writeStringField(writer, "id", b.id);
            try writeStringField(writer, "name", b.name);
            try writeStringField(writer, "arguments_json", b.arguments_json);
        },
        .tool_result => |b| {
            try writeStringFieldFirst(writer, "type", "tool_result");
            try writeStringField(writer, "tool_call_id", b.tool_call_id);
            try writeStringField(writer, "content_json", b.content_json);
            writer.writeAll(",\"is_error\":") catch return error.OutOfMemory;
            writer.writeAll(if (b.is_error) "true" else "false") catch return error.OutOfMemory;
        },
    }
    writer.writeByte('}') catch return error.OutOfMemory;
}

fn parseData(allocator: std.mem.Allocator, object: std.json.ObjectMap, kind: EntryKind) ParseError!EntryData {
    return switch (kind) {
        .header => .{ .header = .{
            .cwd = try dupeOptional(allocator, try optionalStringField(object, "cwd")),
            .title = try dupeOptional(allocator, try optionalStringField(object, "title")),
            .pig_version = try dupeOptional(allocator, try optionalStringField(object, "pig_version")),
        } },
        .message => .{ .message = .{
            .role = try Role.fromString(json.stringField(object, "role") orelse return error.InvalidEntry),
            .content = try parseContentBlocks(allocator, object.get("content") orelse return error.InvalidEntry),
        } },
        .tool_event => .{ .tool_event = .{
            .tool_call_id = try dupeRequired(allocator, object, "tool_call_id"),
            .tool_name = try dupeRequired(allocator, object, "tool_name"),
            .phase = try dupeRequired(allocator, object, "phase"),
        } },
        .tool_result => blk: {
            const is_error = try boolField(object, "is_error", false);
            break :blk .{ .tool_result = .{
                .tool_call_id = try dupeRequired(allocator, object, "tool_call_id"),
                .is_error = is_error,
                .content_json = try dupeRequired(allocator, object, "content_json"),
            } };
        },
        .model_change => .{ .model_change = .{
            .provider = try dupeRequired(allocator, object, "provider"),
            .model = try dupeRequired(allocator, object, "model"),
        } },
        .thinking_level_change => .{ .thinking_level_change = .{
            .level = try dupeRequired(allocator, object, "level"),
        } },
        .session_info => .{ .session_info = .{
            .title = try dupeOptional(allocator, try optionalStringField(object, "title")),
            .cwd = try dupeOptional(allocator, try optionalStringField(object, "cwd")),
            .current_leaf_id = try dupeOptional(allocator, try optionalStringField(object, "current_leaf_id")),
        } },
        .label => .{ .label = .{
            .text = try dupeRequired(allocator, object, "text"),
        } },
        .branch_summary => .{ .branch_summary = .{
            .target_id = try dupeRequired(allocator, object, "target_id"),
            .summary = try dupeRequired(allocator, object, "summary"),
        } },
        .compaction => .{ .compaction = .{
            .target_id = try dupeRequired(allocator, object, "target_id"),
            .summary = try dupeRequired(allocator, object, "summary"),
        } },
        .custom => .{ .custom = .{
            .name = try dupeRequired(allocator, object, "name"),
            .payload_json = try dupeOptional(allocator, try optionalStringField(object, "payload_json")),
        } },
    };
}

fn parseContentBlocks(allocator: std.mem.Allocator, value: std.json.Value) ParseError![]const ContentBlock {
    if (value != .array) return error.InvalidEntry;
    const blocks = try allocator.alloc(ContentBlock, value.array.items.len);
    errdefer allocator.free(blocks);
    var initialized: usize = 0;
    errdefer for (blocks[0..initialized]) |block| block.deinit(allocator);
    for (value.array.items, 0..) |item, i| {
        if (item != .object) return error.InvalidEntry;
        blocks[i] = try parseContentBlock(allocator, item.object);
        initialized += 1;
    }
    return blocks;
}

fn parseContentBlock(allocator: std.mem.Allocator, object: std.json.ObjectMap) ParseError!ContentBlock {
    const block_type = json.stringField(object, "type") orelse return error.InvalidEntry;
    if (std.mem.eql(u8, block_type, "text")) {
        return .{ .text = .{ .text = try dupeRequired(allocator, object, "text") } };
    } else if (std.mem.eql(u8, block_type, "image_ref")) {
        const mime_type = try optionalStringField(object, "mime_type");
        return .{ .image_ref = .{
            .uri = try dupeRequired(allocator, object, "uri"),
            .mime_type = try dupeOptional(allocator, mime_type),
        } };
    } else if (std.mem.eql(u8, block_type, "thinking")) {
        const signature = try optionalStringField(object, "signature");
        return .{ .thinking = .{
            .text = try dupeRequired(allocator, object, "text"),
            .signature = try dupeOptional(allocator, signature),
        } };
    } else if (std.mem.eql(u8, block_type, "tool_call")) {
        return .{ .tool_call = .{
            .id = try dupeRequired(allocator, object, "id"),
            .name = try dupeRequired(allocator, object, "name"),
            .arguments_json = try dupeRequired(allocator, object, "arguments_json"),
        } };
    } else if (std.mem.eql(u8, block_type, "tool_result")) {
        const is_error = try boolField(object, "is_error", false);
        return .{ .tool_result = .{
            .tool_call_id = try dupeRequired(allocator, object, "tool_call_id"),
            .content_json = try dupeRequired(allocator, object, "content_json"),
            .is_error = is_error,
        } };
    }
    return error.InvalidEntry;
}

fn cloneData(allocator: std.mem.Allocator, data: EntryData) !EntryData {
    return switch (data) {
        .header => |d| .{ .header = .{
            .cwd = try dupeOptional(allocator, d.cwd),
            .title = try dupeOptional(allocator, d.title),
            .pig_version = try dupeOptional(allocator, d.pig_version),
        } },
        .message => |d| .{ .message = .{
            .role = d.role,
            .content = try cloneContentBlocks(allocator, d.content),
        } },
        .tool_event => |d| .{ .tool_event = .{
            .tool_call_id = try allocator.dupe(u8, d.tool_call_id),
            .tool_name = try allocator.dupe(u8, d.tool_name),
            .phase = try allocator.dupe(u8, d.phase),
        } },
        .tool_result => |d| .{ .tool_result = .{
            .tool_call_id = try allocator.dupe(u8, d.tool_call_id),
            .is_error = d.is_error,
            .content_json = try allocator.dupe(u8, d.content_json),
        } },
        .model_change => |d| .{ .model_change = .{
            .provider = try allocator.dupe(u8, d.provider),
            .model = try allocator.dupe(u8, d.model),
        } },
        .thinking_level_change => |d| .{ .thinking_level_change = .{
            .level = try allocator.dupe(u8, d.level),
        } },
        .session_info => |d| .{ .session_info = .{
            .title = try dupeOptional(allocator, d.title),
            .cwd = try dupeOptional(allocator, d.cwd),
            .current_leaf_id = try dupeOptional(allocator, d.current_leaf_id),
        } },
        .label => |d| .{ .label = .{ .text = try allocator.dupe(u8, d.text) } },
        .branch_summary => |d| .{ .branch_summary = .{
            .target_id = try allocator.dupe(u8, d.target_id),
            .summary = try allocator.dupe(u8, d.summary),
        } },
        .compaction => |d| .{ .compaction = .{
            .target_id = try allocator.dupe(u8, d.target_id),
            .summary = try allocator.dupe(u8, d.summary),
        } },
        .custom => |d| .{ .custom = .{
            .name = try allocator.dupe(u8, d.name),
            .payload_json = try dupeOptional(allocator, d.payload_json),
        } },
    };
}

fn cloneContentBlocks(allocator: std.mem.Allocator, content: []const ContentBlock) ![]const ContentBlock {
    const blocks = try allocator.alloc(ContentBlock, content.len);
    errdefer allocator.free(blocks);
    var initialized: usize = 0;
    errdefer for (blocks[0..initialized]) |block| block.deinit(allocator);
    for (content, 0..) |block, i| {
        blocks[i] = try cloneContentBlock(allocator, block);
        initialized += 1;
    }
    return blocks;
}

fn cloneContentBlock(allocator: std.mem.Allocator, block: ContentBlock) !ContentBlock {
    return switch (block) {
        .text => |b| .{ .text = .{ .text = try allocator.dupe(u8, b.text) } },
        .image_ref => |b| .{ .image_ref = .{
            .uri = try allocator.dupe(u8, b.uri),
            .mime_type = try dupeOptional(allocator, b.mime_type),
        } },
        .thinking => |b| .{ .thinking = .{
            .text = try allocator.dupe(u8, b.text),
            .signature = try dupeOptional(allocator, b.signature),
        } },
        .tool_call => |b| .{ .tool_call = .{
            .id = try allocator.dupe(u8, b.id),
            .name = try allocator.dupe(u8, b.name),
            .arguments_json = try allocator.dupe(u8, b.arguments_json),
        } },
        .tool_result => |b| .{ .tool_result = .{
            .tool_call_id = try allocator.dupe(u8, b.tool_call_id),
            .content_json = try allocator.dupe(u8, b.content_json),
            .is_error = b.is_error,
        } },
    };
}

fn dupeRequired(allocator: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8) ParseError![]const u8 {
    const value = json.stringField(object, key) orelse return error.InvalidEntry;
    return try allocator.dupe(u8, value);
}

fn dupeOptional(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    if (value) |v| return try allocator.dupe(u8, v);
    return null;
}

fn optionalStringField(object: std.json.ObjectMap, key: []const u8) ParseError!?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value == .null) return null;
    if (value != .string) return error.InvalidEntry;
    return value.string;
}

fn boolField(object: std.json.ObjectMap, key: []const u8, default: bool) ParseError!bool {
    const value = object.get(key) orelse return default;
    if (value != .bool) return error.InvalidEntry;
    return value.bool;
}

fn writeStringFieldFirst(writer: *std.Io.Writer, name: []const u8, value: []const u8) error{OutOfMemory}!void {
    try json.writeJsonString(writer, name);
    writer.writeByte(':') catch return error.OutOfMemory;
    try json.writeJsonString(writer, value);
}

fn writeStringField(writer: *std.Io.Writer, name: []const u8, value: []const u8) error{OutOfMemory}!void {
    writer.writeByte(',') catch return error.OutOfMemory;
    try writeStringFieldFirst(writer, name, value);
}

fn writeOptionalStringField(writer: *std.Io.Writer, name: []const u8, value: ?[]const u8) error{OutOfMemory}!void {
    if (value) |v| try writeStringField(writer, name, v);
}
