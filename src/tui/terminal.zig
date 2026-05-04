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
    original_termios: ?std.posix.termios = null,

    pub fn enterRawMode(self: *TerminalSession) void {
        self.mode = .raw;
        self.raw_entered = true;
    }

    pub fn enterRawModeForFd(self: *TerminalSession, fd: std.posix.fd_t) !void {
        const original = try std.posix.tcgetattr(fd);
        var raw = original;
        setFlag(&raw.iflag, "BRKINT", false);
        setFlag(&raw.iflag, "ICRNL", false);
        setFlag(&raw.iflag, "INPCK", false);
        setFlag(&raw.iflag, "ISTRIP", false);
        setFlag(&raw.iflag, "IXON", false);
        setFlag(&raw.oflag, "OPOST", false);
        setFlag(&raw.lflag, "ECHO", false);
        setFlag(&raw.lflag, "ICANON", false);
        setFlag(&raw.lflag, "IEXTEN", false);
        setFlag(&raw.lflag, "ISIG", false);
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        try std.posix.tcsetattr(fd, .FLUSH, raw);
        self.original_termios = original;
        self.enterRawMode();
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

    pub fn restoreForFd(self: *TerminalSession, fd: std.posix.fd_t) void {
        if (self.original_termios) |original| {
            std.posix.tcsetattr(fd, .FLUSH, original) catch {};
            self.original_termios = null;
        }
        self.restore();
    }
};

fn setFlag(flags: anytype, comptime name: []const u8, value: bool) void {
    const FlagSet = @TypeOf(flags.*);
    if (@hasField(FlagSet, name)) @field(flags.*, name) = value;
}

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
