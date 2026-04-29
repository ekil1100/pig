const std = @import("std");
const pig = @import("pig");

const cli = pig.app.cli;
const build_info = pig.app.build_info;
const paths = pig.util.paths;
const core = pig.core;
const provider = pig.provider;
const tools = pig.tools;
const resources = pig.resources;
const tui = pig.tui;
const rpc = pig.rpc;
const plugin = pig.plugin;

test "build info includes required fields" {
    var buffer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buffer.deinit();

    try build_info.write(&buffer.writer);
    const output = buffer.written();

    try std.testing.expect(std.mem.indexOf(u8, output, "Pig version:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Zig version:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Build mode:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Target:") != null);
}

test "cli dispatches version help paths doctor and unknown commands" {
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();
    const context = cli.Context{ .allocator = std.testing.allocator };

    try std.testing.expectEqual(cli.ExitCode.ok, try cli.runWithContext(&.{"--version"}, context, &stdout.writer, &stderr.writer));
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "Pig version:") != null);

    stdout.clearRetainingCapacity();
    stderr.clearRetainingCapacity();
    try std.testing.expectEqual(cli.ExitCode.ok, try cli.runWithContext(&.{"--help"}, context, &stdout.writer, &stderr.writer));
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "agent functionality is not implemented") != null);

    stdout.clearRetainingCapacity();
    stderr.clearRetainingCapacity();
    try std.testing.expectEqual(cli.ExitCode.ok, try cli.runWithContext(&.{"paths"}, context, &stdout.writer, &stderr.writer));
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "global_config:") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "project_resources:") != null);

    stdout.clearRetainingCapacity();
    stderr.clearRetainingCapacity();
    try std.testing.expectEqual(cli.ExitCode.ok, try cli.runWithContext(&.{"doctor"}, context, &stdout.writer, &stderr.writer));
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "fixtures:") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "temp_dir:") != null);

    stdout.clearRetainingCapacity();
    stderr.clearRetainingCapacity();
    try std.testing.expectEqual(cli.ExitCode.usage, try cli.runWithContext(&.{"nope"}, context, &stdout.writer, &stderr.writer));
    try std.testing.expect(std.mem.indexOf(u8, stderr.written(), "unknown command") != null);
}

test "cli reports usage for extra arguments" {
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const code = try cli.runWithContext(&.{ "paths", "extra" }, .{ .allocator = std.testing.allocator }, &stdout.writer, &stderr.writer);

    try std.testing.expectEqual(cli.ExitCode.usage, code);
    try std.testing.expect(std.mem.indexOf(u8, stderr.written(), "unexpected argument") != null);
}

test "doctor reports missing home instead of ok dot" {
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const code = try cli.runWithContext(&.{"doctor"}, .{ .allocator = std.testing.allocator }, &stdout.writer, &stderr.writer);

    try std.testing.expectEqual(cli.ExitCode.ok, code);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "home: missing") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "home: ok .") == null);
}

test "default paths include pi-compatible global and project paths" {
    const set = try paths.resolveDefaultPaths(std.testing.allocator);
    defer set.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.endsWith(u8, set.global_config, ".pi/agent/settings.json"));
    try std.testing.expect(std.mem.endsWith(u8, set.global_auth, ".pi/agent/auth.json"));
    try std.testing.expect(std.mem.endsWith(u8, set.global_models, ".pi/agent/models.json"));
    try std.testing.expect(std.mem.endsWith(u8, set.global_sessions, ".pi/agent/sessions"));
    try std.testing.expect(std.mem.endsWith(u8, set.project_config, ".pi/settings.json"));
    try std.testing.expect(std.mem.endsWith(u8, set.project_resources, ".pi"));
}

test "session default paths expose a session-specific path set" {
    const set = try pig.session.resolveDefaultPaths(std.testing.allocator);
    defer set.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.endsWith(u8, set.sessions_dir, ".pi/agent/sessions"));
}

test "m0 placeholder modules expose stable public constants and enums" {
    try std.testing.expectEqual(core.errors.PigError.ConfigError, core.errors.PigError.ConfigError);
    try std.testing.expectEqual(provider.ProviderKind.openai_compatible, provider.ProviderKind.openai_compatible);
    try std.testing.expectEqual(provider.ProviderStatus.unconfigured, provider.ProviderStatus.unconfigured);
    try std.testing.expectEqual(tools.ToolRisk.safe, tools.ToolRisk.safe);
    try std.testing.expectEqual(tools.ToolAccess.read_only, tools.ToolAccess.read_only);
    try std.testing.expectEqual(resources.ResourceKind.settings, resources.ResourceKind.settings);
    try std.testing.expectEqual(resources.ResourceSource.project, resources.ResourceSource.project);
    try std.testing.expectEqual(tui.TerminalMode.cooked, tui.TerminalMode.cooked);
    try std.testing.expectEqual(@as(u32, 1), rpc.PROTOCOL_VERSION);
    try std.testing.expectEqual(@as(u32, 1), plugin.PROTOCOL_VERSION);
}
