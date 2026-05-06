const std = @import("std");
const pig = @import("pig");

const commands = pig.app.commands;

test "command registry exposes roadmap M8 commands" {
    const expected = [_][]const u8{
        "login",
        "logout",
        "model",
        "scoped-models",
        "settings",
        "resume",
        "new",
        "name",
        "session",
        "tree",
        "fork",
        "compact",
        "copy",
        "export",
        "reload",
        "hotkeys",
        "changelog",
        "quit",
        "exit",
    };

    for (expected) |name| {
        try std.testing.expect(commands.lookup(name) != null);
    }
}

test "command registry resolves aliases and formats hotkeys" {
    try std.testing.expectEqual(commands.CommandKind.new_session, commands.lookup("new-session").?.kind);
    try std.testing.expectEqual(commands.CommandKind.hotkeys, commands.lookup("help").?.kind);
    try std.testing.expectEqual(commands.CommandKind.quit, commands.lookup("q").?.kind);

    const hotkeys = try commands.formatHotkeys(std.testing.allocator);
    defer std.testing.allocator.free(hotkeys);
    try std.testing.expect(std.mem.indexOf(u8, hotkeys, "/reload - reload settings") != null);
    try std.testing.expect(std.mem.indexOf(u8, hotkeys, "/scoped-models") != null);
    try std.testing.expect(std.mem.indexOf(u8, hotkeys, "Ctrl+C") != null);
}
