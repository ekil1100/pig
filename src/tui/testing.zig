const std = @import("std");
const terminal = @import("terminal.zig");
const layout = @import("layout.zig");

pub fn inMemoryTerminal(allocator: std.mem.Allocator, input: []const u8) terminal.InMemoryTerminal {
    return terminal.InMemoryTerminal.init(allocator, input, .{ .width = 80, .height = 24 });
}

pub fn smallTerminal(allocator: std.mem.Allocator, input: []const u8) terminal.InMemoryTerminal {
    return terminal.InMemoryTerminal.init(allocator, input, .{ .width = 20, .height = 8 });
}

pub const Size = layout.Size;
