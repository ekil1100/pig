const std = @import("std");

fn addPigTest(b: *std.Build, test_step: *std.Build.Step, pig_module: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, path: []const u8) *std.Build.Step.Run {
    const test_module = b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
    });
    test_module.addImport("pig", pig_module);
    const test_artifact = b.addTest(.{ .root_module = test_module });
    const run_test = b.addRunArtifact(test_artifact);
    test_step.dependOn(&run_test.step);
    return run_test;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const pig_module = b.createModule(.{
        .root_source_file = b.path("src/mod.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_module.addImport("pig", pig_module);

    const exe = b.addExecutable(.{
        .name = "pig",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run pig");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    _ = addPigTest(b, test_step, pig_module, target, optimize, "test/cli.zig");
    _ = addPigTest(b, test_step, pig_module, target, optimize, "test/fixtures.zig");
    _ = addPigTest(b, test_step, pig_module, target, optimize, "test/provider_types.zig");
    _ = addPigTest(b, test_step, pig_module, target, optimize, "test/provider_events.zig");
    _ = addPigTest(b, test_step, pig_module, target, optimize, "test/provider_sse.zig");
    _ = addPigTest(b, test_step, pig_module, target, optimize, "test/provider_auth.zig");
    _ = addPigTest(b, test_step, pig_module, target, optimize, "test/provider_openai.zig");
    _ = addPigTest(b, test_step, pig_module, target, optimize, "test/provider_anthropic.zig");
    _ = addPigTest(b, test_step, pig_module, target, optimize, "test/provider_live.zig");

    const provider_fixtures_step = b.step("provider-fixtures", "Run offline provider recorded fixture tests");
    _ = addPigTest(b, provider_fixtures_step, pig_module, target, optimize, "test/provider_openai.zig");
    _ = addPigTest(b, provider_fixtures_step, pig_module, target, optimize, "test/provider_anthropic.zig");

    const live_module = b.createModule(.{
        .root_source_file = b.path("src/provider/live_smoke.zig"),
        .target = target,
        .optimize = optimize,
    });
    live_module.addImport("pig", pig_module);
    const live_exe = b.addExecutable(.{
        .name = "pig-provider-live",
        .root_module = live_module,
    });
    const run_live = b.addRunArtifact(live_exe);
    const provider_live_step = b.step("provider-live", "Run optional live provider smoke test");
    provider_live_step.dependOn(&run_live.step);

    const smoke_step = b.step("smoke", "Run smoke tests");
    inline for (.{ "--version", "--help", "doctor", "paths" }) |arg| {
        const smoke_cmd = b.addRunArtifact(exe);
        smoke_cmd.addArg(arg);
        smoke_step.dependOn(&smoke_cmd.step);
    }

    const fmt_cmd = b.addSystemCommand(&.{ "zig", "fmt", "--check", "build.zig", "build.zig.zon", "src", "test" });
    const fmt_step = b.step("fmt-check", "Check Zig formatting");
    fmt_step.dependOn(&fmt_cmd.step);
}
