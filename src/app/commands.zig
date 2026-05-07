const std = @import("std");

pub const ParseError = error{
    NotCommand,
    LiteralSlash,
    MissingCommandName,
    UnterminatedQuote,
    InvalidEscape,
} || std.mem.Allocator.Error;

pub const CommandCategory = enum {
    auth,
    model,
    session,
    workflow,
    system,
};

pub const CommandKind = enum {
    login,
    logout,
    model,
    scoped_models,
    settings,
    resume_session,
    new_session,
    name,
    session,
    tree,
    fork,
    compact,
    copy,
    export_session,
    reload,
    hotkeys,
    changelog,
    quit,
    exit,
};

pub const CommandSpec = struct {
    kind: CommandKind,
    name: []const u8,
    aliases: []const []const u8 = &.{},
    summary: []const u8,
    usage: []const u8,
    category: CommandCategory,
    available_when_busy: bool = false,
    hidden: bool = false,
};

pub const ParsedCommand = struct {
    allocator: std.mem.Allocator,
    raw: []const u8,
    name: []const u8,
    argv: []const []const u8,

    pub fn deinit(self: *ParsedCommand) void {
        self.allocator.free(self.raw);
        self.allocator.free(self.name);
        for (self.argv) |arg| self.allocator.free(arg);
        self.allocator.free(self.argv);
        self.* = undefined;
    }
};

pub const specs = [_]CommandSpec{
    .{ .kind = .login, .name = "login", .summary = "show provider auth setup guidance", .usage = "/login [provider]", .category = .auth },
    .{ .kind = .logout, .name = "logout", .summary = "remove local auth for a provider", .usage = "/logout <provider>", .category = .auth },
    .{ .kind = .model, .name = "model", .summary = "show or switch the current model", .usage = "/model [model-id]", .category = .model },
    .{ .kind = .scoped_models, .name = "scoped-models", .summary = "list enabled models by source scope", .usage = "/scoped-models", .category = .model },
    .{ .kind = .settings, .name = "settings", .summary = "show effective non-secret settings", .usage = "/settings", .category = .system, .available_when_busy = true },
    .{ .kind = .resume_session, .name = "resume", .summary = "resume a previous session", .usage = "/resume [session-id-or-path]", .category = .session },
    .{ .kind = .new_session, .name = "new", .aliases = &.{"new-session"}, .summary = "start a new session", .usage = "/new", .category = .session },
    .{ .kind = .name, .name = "name", .summary = "show or rename the current session", .usage = "/name [title]", .category = .session },
    .{ .kind = .session, .name = "session", .summary = "show current session status", .usage = "/session", .category = .session, .available_when_busy = true },
    .{ .kind = .tree, .name = "tree", .summary = "show the current session tree", .usage = "/tree [entry-id]", .category = .session, .available_when_busy = true },
    .{ .kind = .fork, .name = "fork", .summary = "continue from a historical entry", .usage = "/fork <entry-id>", .category = .session },
    .{ .kind = .compact, .name = "compact", .summary = "summarize older context and continue", .usage = "/compact", .category = .workflow },
    .{ .kind = .copy, .name = "copy", .summary = "copy recent output or session metadata", .usage = "/copy [target]", .category = .workflow },
    .{ .kind = .export_session, .name = "export", .summary = "export the current session", .usage = "/export <path>", .category = .workflow },
    .{ .kind = .reload, .name = "reload", .summary = "reload settings, models, and resources", .usage = "/reload", .category = .system },
    .{ .kind = .hotkeys, .name = "hotkeys", .aliases = &.{"help"}, .summary = "show commands and keyboard shortcuts", .usage = "/hotkeys", .category = .system, .available_when_busy = true },
    .{ .kind = .changelog, .name = "changelog", .summary = "show the built-in milestone summary", .usage = "/changelog", .category = .system, .available_when_busy = true },
    .{ .kind = .quit, .name = "quit", .aliases = &.{"q"}, .summary = "exit interactive mode", .usage = "/quit", .category = .system, .available_when_busy = true },
    .{ .kind = .exit, .name = "exit", .summary = "exit interactive mode", .usage = "/exit", .category = .system, .available_when_busy = true },
};

pub fn isCommandInput(input: []const u8) bool {
    const trimmed = trimInput(input);
    return std.mem.startsWith(u8, trimmed, "/") and !std.mem.startsWith(u8, trimmed, "//");
}

pub fn isSlashLiteral(input: []const u8) bool {
    return std.mem.startsWith(u8, trimInput(input), "//");
}

pub fn parse(allocator: std.mem.Allocator, input: []const u8) ParseError!ParsedCommand {
    const trimmed = trimInput(input);
    if (!std.mem.startsWith(u8, trimmed, "/")) return error.NotCommand;
    if (std.mem.startsWith(u8, trimmed, "//")) return error.LiteralSlash;

    const body = trimmed[1..];
    if (body.len == 0) return error.MissingCommandName;

    var tokens: std.ArrayList([]const u8) = .empty;
    defer tokens.deinit(allocator);
    errdefer freeTokens(allocator, tokens.items);
    try parseTokens(allocator, body, &tokens);
    if (tokens.items.len == 0) return error.MissingCommandName;

    const raw = try allocator.dupe(u8, trimmed);
    errdefer allocator.free(raw);
    const name = tokens.items[0];
    const argv = try allocator.alloc([]const u8, tokens.items.len - 1);
    errdefer allocator.free(argv);
    for (tokens.items[1..], 0..) |token, index| argv[index] = token;

    return .{
        .allocator = allocator,
        .raw = raw,
        .name = name,
        .argv = argv,
    };
}

pub fn lookup(name: []const u8) ?CommandSpec {
    for (specs) |spec| {
        if (std.mem.eql(u8, name, spec.name)) return spec;
        for (spec.aliases) |alias| {
            if (std.mem.eql(u8, name, alias)) return spec;
        }
    }
    return null;
}

pub fn formatParseError(err: ParseError) []const u8 {
    return switch (err) {
        error.NotCommand => "not a slash command",
        error.LiteralSlash => "slash literal is not a command",
        error.MissingCommandName => "missing slash command name",
        error.UnterminatedQuote => "unterminated quote in slash command",
        error.InvalidEscape => "invalid escape in slash command",
        error.OutOfMemory => "out of memory while parsing slash command",
    };
}

pub fn formatUnknownCommand(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "unknown command: /{s} (try /hotkeys)", .{name});
}

pub fn formatHotkeys(allocator: std.mem.Allocator) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll("available commands:\n");
    for (specs) |spec| {
        if (spec.hidden) continue;
        try out.writer.print("/{s} - {s}\n", .{ spec.name, spec.summary });
    }
    try out.writer.writeAll("shortcuts:\nCtrl+C - abort active turn or exit when idle\nCtrl+D - exit on empty input\nPageUp/PageDown or mouse wheel - scroll transcript\n");
    return try out.toOwnedSlice();
}

fn trimInput(input: []const u8) []const u8 {
    return std.mem.trim(u8, input, " \t\r\n");
}

fn parseTokens(allocator: std.mem.Allocator, input: []const u8, tokens: *std.ArrayList([]const u8)) ParseError!void {
    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(allocator);

    var active = false;
    var quote: ?u8 = null;
    var i: usize = 0;
    while (i < input.len) {
        const byte = input[i];
        if (quote) |q| {
            if (byte == q) {
                quote = null;
                active = true;
                i += 1;
            } else if (byte == '\\') {
                if (i + 1 >= input.len) return error.InvalidEscape;
                try current.append(allocator, input[i + 1]);
                active = true;
                i += 2;
            } else {
                try current.append(allocator, byte);
                active = true;
                i += 1;
            }
            continue;
        }

        if (std.ascii.isWhitespace(byte)) {
            if (active) {
                try appendToken(allocator, tokens, current.items);
                current.clearRetainingCapacity();
                active = false;
            }
            i += 1;
        } else if (byte == '"' or byte == '\'') {
            quote = byte;
            active = true;
            i += 1;
        } else if (byte == '\\') {
            if (i + 1 >= input.len) return error.InvalidEscape;
            try current.append(allocator, input[i + 1]);
            active = true;
            i += 2;
        } else {
            try current.append(allocator, byte);
            active = true;
            i += 1;
        }
    }

    if (quote != null) return error.UnterminatedQuote;
    if (active) try appendToken(allocator, tokens, current.items);
}

fn appendToken(allocator: std.mem.Allocator, tokens: *std.ArrayList([]const u8), value: []const u8) !void {
    const owned = try allocator.dupe(u8, value);
    errdefer allocator.free(owned);
    try tokens.append(allocator, owned);
}

fn freeTokens(allocator: std.mem.Allocator, tokens: []const []const u8) void {
    for (tokens) |token| allocator.free(token);
}
