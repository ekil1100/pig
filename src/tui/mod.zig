pub const TerminalMode = enum {
    cooked,
    raw,
};

pub const Capabilities = struct {
    color: bool = true,
    alternate_screen: bool = false,
    synchronized_output: bool = false,
};

pub const input = @import("input.zig");
pub const editor = @import("editor.zig");
pub const layout = @import("layout.zig");
pub const render = @import("render.zig");
pub const components = @import("components.zig");
pub const markdown = @import("markdown.zig");
pub const terminal = @import("terminal.zig");
pub const theme = @import("theme.zig");
pub const testing = @import("testing.zig");
