const std = @import("std");

pub fn writeJsonString(writer: *std.Io.Writer, value: []const u8) error{OutOfMemory}!void {
    writer.writeByte('"') catch return error.OutOfMemory;
    for (value) |byte| {
        switch (byte) {
            '"' => writer.writeAll("\\\"") catch return error.OutOfMemory,
            '\\' => writer.writeAll("\\\\") catch return error.OutOfMemory,
            '\n' => writer.writeAll("\\n") catch return error.OutOfMemory,
            '\r' => writer.writeAll("\\r") catch return error.OutOfMemory,
            '\t' => writer.writeAll("\\t") catch return error.OutOfMemory,
            else => {
                if (byte < 0x20) {
                    writer.print("\\u00{x:0>2}", .{byte}) catch return error.OutOfMemory;
                } else {
                    writer.writeByte(byte) catch return error.OutOfMemory;
                }
            },
        }
    }
    writer.writeByte('"') catch return error.OutOfMemory;
}

pub fn objectGet(value: std.json.Value, key: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(key);
}

pub fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

pub fn optionalStringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value == .null) return null;
    if (value != .string) return null;
    return value.string;
}

pub fn boolField(object: std.json.ObjectMap, key: []const u8, default: bool) bool {
    const value = object.get(key) orelse return default;
    if (value != .bool) return default;
    return value.bool;
}

pub fn intField(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |i| std.math.cast(i64, i),
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}
