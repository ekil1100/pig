const std = @import("std");
const root = @import("mod.zig");
const layout = @import("layout.zig");

pub const TerminalSession = struct {
    mode: root.TerminalMode = .cooked,
    capabilities: root.Capabilities = .{},
    size: layout.Size = .{ .width = 80, .height = 24 },
    raw_entered: bool = false,
    alternate_entered: bool = false,
    cursor_hidden: bool = false,
    synchronized_output: bool = false,

    pub fn enterRawMode(self: *TerminalSession) void {
        self.mode = .raw;
        self.raw_entered = true;
    }

    pub fn enterAlternateScreen(self: *TerminalSession) void {
        if (!self.capabilities.alternate_screen) return;
        self.alternate_entered = true;
    }

    pub fn hideCursor(self: *TerminalSession) void {
        self.cursor_hidden = true;
    }

    pub fn enableSynchronizedOutput(self: *TerminalSession) void {
        if (!self.capabilities.synchronized_output) return;
        self.synchronized_output = true;
    }

    pub fn restore(self: *TerminalSession) void {
        self.synchronized_output = false;
        self.cursor_hidden = false;
        self.alternate_entered = false;
        if (self.raw_entered) self.mode = .cooked;
        self.raw_entered = false;
    }
};

pub const InMemoryTerminal = struct {
    allocator: std.mem.Allocator,
    input_bytes: []const u8,
    output: std.Io.Writer.Allocating,
    session: TerminalSession = .{},

    pub fn init(allocator: std.mem.Allocator, input_bytes: []const u8, size: layout.Size) InMemoryTerminal {
        return .{ .allocator = allocator, .input_bytes = input_bytes, .output = .init(allocator), .session = .{ .size = size } };
    }

    pub fn deinit(self: *InMemoryTerminal) void {
        self.output.deinit();
        self.* = undefined;
    }

    pub fn written(self: *const InMemoryTerminal) []const u8 {
        return self.output.written();
    }
};
