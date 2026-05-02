const std = @import("std");

pub fn writeJsonString(writer: *std.Io.Writer, value: []const u8) error{OutOfMemory}!void {
    const valid_utf8 = std.unicode.utf8ValidateSlice(value);
    writer.writeByte('"') catch return error.OutOfMemory;
    for (value) |byte| switch (byte) {
        '"' => writer.writeAll("\\\"") catch return error.OutOfMemory,
        '\\' => writer.writeAll("\\\\") catch return error.OutOfMemory,
        '\n' => writer.writeAll("\\n") catch return error.OutOfMemory,
        '\r' => writer.writeAll("\\r") catch return error.OutOfMemory,
        '\t' => writer.writeAll("\\t") catch return error.OutOfMemory,
        else => {
            if (byte < 0x20 or (!valid_utf8 and byte >= 0x80)) {
                writer.print("\\u00{x:0>2}", .{byte}) catch return error.OutOfMemory;
            } else writer.writeByte(byte) catch return error.OutOfMemory;
        },
    };
    writer.writeByte('"') catch return error.OutOfMemory;
}

pub fn errorJson(allocator: std.mem.Allocator, code: []const u8, message: []const u8) ![]u8 {
    var w: std.Io.Writer.Allocating = .init(allocator);
    defer w.deinit();
    w.writer.writeAll("{\"ok\":false,\"error\":{\"code\":") catch return error.OutOfMemory;
    try writeJsonString(&w.writer, code);
    w.writer.writeAll(",\"message\":") catch return error.OutOfMemory;
    try writeJsonString(&w.writer, message);
    w.writer.writeAll("}}") catch return error.OutOfMemory;
    return w.toOwnedSlice() catch return error.OutOfMemory;
}

pub fn getObject(root: std.json.Value) ?std.json.ObjectMap {
    return if (root == .object) root.object else null;
}

pub fn getString(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

pub fn getBool(object: std.json.ObjectMap, name: []const u8, default: bool) bool {
    const value = object.get(name) orelse return default;
    return if (value == .bool) value.bool else default;
}

pub fn getInteger(object: std.json.ObjectMap, name: []const u8, default: i64) i64 {
    const value = object.get(name) orelse return default;
    return switch (value) {
        .integer => |v| v,
        else => default,
    };
}

pub fn hasNul(value: []const u8) bool {
    return std.mem.indexOfScalar(u8, value, 0) != null;
}
