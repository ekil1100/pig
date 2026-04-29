pub const TerminalMode = enum {
    cooked,
    raw,
};

pub const Capabilities = struct {
    color: bool = true,
    alternate_screen: bool = false,
    synchronized_output: bool = false,
};
