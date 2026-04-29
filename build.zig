const std = @import("std");

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

    const cli_test_module = b.createModule(.{
        .root_source_file = b.path("test/cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_test_module.addImport("pig", pig_module);
    const cli_tests = b.addTest(.{ .root_module = cli_test_module });

    const fixtures_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/fixtures.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_cli_tests = b.addRunArtifact(cli_tests);
    const run_fixtures_tests = b.addRunArtifact(fixtures_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_cli_tests.step);
    test_step.dependOn(&run_fixtures_tests.step);

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
