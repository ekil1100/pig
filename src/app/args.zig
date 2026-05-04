const std = @import("std");
const agent = @import("../core/agent/mod.zig");

pub const ParseError = error{
    MissingValue,
    UnknownArgument,
    UnexpectedArgument,
    DuplicateMode,
    InvalidCombination,
    InvalidValue,
};

pub const CommandTag = enum { help, version, paths, doctor, run };

pub const ParsedCommand = union(CommandTag) {
    help,
    version,
    paths,
    doctor,
    run: RunConfig,
};

pub const RunMode = enum { print, interactive, rpc };
pub const OutputMode = enum { text, json };
pub const SessionMode = enum { default, ephemeral, resume_session, new_session, explicit };

pub const RunConfig = struct {
    mode: RunMode,
    output: OutputMode = .text,
    prompt: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    session_mode: SessionMode = .default,
    session_ref: ?[]const u8 = null,
    thinking_level: agent.ThinkingLevel = .off,
    thinking_overridden: bool = false,
    tools_enabled: bool = true,
    tools_enabled_overridden: bool = false,
    include_p1_tools: bool = false,
    include_p1_tools_overridden: bool = false,
    max_iterations: u32 = 8,
};

pub fn parse(argv: []const []const u8) ParseError!ParsedCommand {
    if (argv.len == 0) return .help;

    if (argv.len == 1) {
        if (std.mem.eql(u8, argv[0], "--help") or std.mem.eql(u8, argv[0], "help")) return .help;
        if (std.mem.eql(u8, argv[0], "--version")) return .version;
        if (std.mem.eql(u8, argv[0], "paths")) return .paths;
        if (std.mem.eql(u8, argv[0], "doctor")) return .doctor;
    }

    var config = RunConfig{ .mode = .print };
    var mode_seen = false;
    var session_seen = false;

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--print")) {
            if (mode_seen) return error.DuplicateMode;
            mode_seen = true;
            config.mode = .print;
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            config.prompt = argv[i];
        } else if (std.mem.eql(u8, arg, "--interactive")) {
            if (mode_seen) return error.DuplicateMode;
            mode_seen = true;
            config.mode = .interactive;
        } else if (std.mem.eql(u8, arg, "--rpc")) {
            if (mode_seen) return error.DuplicateMode;
            mode_seen = true;
            config.mode = .rpc;
        } else if (std.mem.eql(u8, arg, "--json")) {
            config.output = .json;
        } else if (std.mem.eql(u8, arg, "--cwd")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            config.cwd = argv[i];
        } else if (std.mem.eql(u8, arg, "--provider")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            config.provider = argv[i];
        } else if (std.mem.eql(u8, arg, "--model")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            config.model = argv[i];
        } else if (std.mem.eql(u8, arg, "--thinking")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            config.thinking_level = parseThinking(argv[i]) orelse return error.InvalidValue;
            config.thinking_overridden = true;
        } else if (std.mem.eql(u8, arg, "--max-iterations")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            config.max_iterations = std.fmt.parseUnsigned(u32, argv[i], 10) catch return error.InvalidValue;
            if (config.max_iterations == 0) return error.InvalidValue;
        } else if (std.mem.eql(u8, arg, "--no-tools")) {
            config.tools_enabled = false;
            config.tools_enabled_overridden = true;
        } else if (std.mem.eql(u8, arg, "--include-p1-tools")) {
            config.include_p1_tools = true;
            config.include_p1_tools_overridden = true;
        } else if (std.mem.eql(u8, arg, "--ephemeral")) {
            if (session_seen) return error.InvalidCombination;
            session_seen = true;
            config.session_mode = .ephemeral;
        } else if (std.mem.eql(u8, arg, "--resume")) {
            if (session_seen) return error.InvalidCombination;
            session_seen = true;
            config.session_mode = .resume_session;
        } else if (std.mem.eql(u8, arg, "--new-session")) {
            if (session_seen) return error.InvalidCombination;
            session_seen = true;
            config.session_mode = .new_session;
        } else if (std.mem.eql(u8, arg, "--session")) {
            if (session_seen) return error.InvalidCombination;
            session_seen = true;
            config.session_mode = .explicit;
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            config.session_ref = argv[i];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownArgument;
        } else {
            return error.UnexpectedArgument;
        }
    }

    if (!mode_seen) return error.InvalidCombination;
    if (config.output == .json and config.mode != .print) return error.InvalidCombination;
    if (config.mode == .print and config.prompt == null) return error.InvalidCombination;
    if (!config.tools_enabled and config.include_p1_tools) return error.InvalidCombination;

    return .{ .run = config };
}

fn parseThinking(value: []const u8) ?agent.ThinkingLevel {
    if (std.mem.eql(u8, value, "off")) return .off;
    if (std.mem.eql(u8, value, "low")) return .low;
    if (std.mem.eql(u8, value, "medium")) return .medium;
    if (std.mem.eql(u8, value, "high")) return .high;
    if (std.mem.eql(u8, value, "xhigh")) return .xhigh;
    if (std.mem.eql(u8, value, "max")) return .max;
    return null;
}
