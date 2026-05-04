pub const Color = enum { default, dim, accent, danger, success };

pub const Style = struct {
    bold: bool = false,
    dim: bool = false,
    fg: Color = .default,
};

pub const Theme = struct {
    user: Style = .{ .bold = true, .fg = .accent },
    assistant: Style = .{},
    tool: Style = .{ .dim = true },
    error_style: Style = .{ .fg = .danger },
    status: Style = .{ .dim = true },
};

pub const default_theme = Theme{};
