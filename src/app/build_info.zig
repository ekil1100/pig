const std = @import("std");
const builtin = @import("builtin");
const version = @import("../version.zig");

pub fn write(writer: anytype) !void {
    try writer.print("Pig version: {s}\n", .{version.version});
    try writer.print("Zig version: {s}\n", .{builtin.zig_version_string});
    try writer.print("Build mode: {s}\n", .{@tagName(builtin.mode)});
    try writer.print("Target: {s}-{s}-{s}\n", .{
        @tagName(builtin.target.cpu.arch),
        @tagName(builtin.target.os.tag),
        @tagName(builtin.target.abi),
    });
}
