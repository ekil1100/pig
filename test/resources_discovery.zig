const std = @import("std");
const pig = @import("pig");

test "resource snapshot loads settings models context and metadata counters" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root);
    const global_root = try std.fs.path.join(std.testing.allocator, &.{ root, "global" });
    defer std.testing.allocator.free(global_root);
    const project_root = try std.fs.path.join(std.testing.allocator, &.{ root, "project" });
    defer std.testing.allocator.free(project_root);
    const project_pig = try std.fs.path.join(std.testing.allocator, &.{ project_root, ".pig" });
    defer std.testing.allocator.free(project_pig);
    const skills_dir = try std.fs.path.join(std.testing.allocator, &.{ global_root, "skills" });
    defer std.testing.allocator.free(skills_dir);
    const prompts_dir = try std.fs.path.join(std.testing.allocator, &.{ project_pig, "prompts" });
    defer std.testing.allocator.free(prompts_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, skills_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, prompts_dir);
    const skill_path = try std.fs.path.join(std.testing.allocator, &.{ skills_dir, "one.md" });
    defer std.testing.allocator.free(skill_path);
    const prompt_path = try std.fs.path.join(std.testing.allocator, &.{ prompts_dir, "p.md" });
    defer std.testing.allocator.free(prompt_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = skill_path, .data = "skill" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = prompt_path, .data = "prompt" });

    var snapshot = try pig.resources.discovery.loadSnapshot(std.testing.allocator, std.testing.io, .{
        .cwd = project_root,
        .global_config = "missing-settings.json",
        .project_config = "missing-project-settings.json",
        .global_models = "missing-global-models.json",
        .project_models = "missing-project-models.json",
        .global_resources = global_root,
        .project_resources = project_pig,
    });
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), snapshot.counters.skills);
    try std.testing.expectEqual(@as(usize, 1), snapshot.counters.prompts);
}

test "resource snapshot warns when project metadata overrides global name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root);
    const global_root = try std.fs.path.join(std.testing.allocator, &.{ root, "global" });
    defer std.testing.allocator.free(global_root);
    const project_root = try std.fs.path.join(std.testing.allocator, &.{ root, "project" });
    defer std.testing.allocator.free(project_root);
    const global_skills = try std.fs.path.join(std.testing.allocator, &.{ global_root, "skills" });
    defer std.testing.allocator.free(global_skills);
    const project_pig = try std.fs.path.join(std.testing.allocator, &.{ project_root, ".pig" });
    defer std.testing.allocator.free(project_pig);
    const project_skills = try std.fs.path.join(std.testing.allocator, &.{ project_pig, "skills" });
    defer std.testing.allocator.free(project_skills);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, global_skills);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, project_skills);
    const global_skill = try std.fs.path.join(std.testing.allocator, &.{ global_skills, "same.md" });
    defer std.testing.allocator.free(global_skill);
    const project_skill = try std.fs.path.join(std.testing.allocator, &.{ project_skills, "same.md" });
    defer std.testing.allocator.free(project_skill);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = global_skill, .data = "global" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = project_skill, .data = "project" });

    var snapshot = try pig.resources.discovery.loadSnapshot(std.testing.allocator, std.testing.io, .{
        .cwd = project_root,
        .global_config = "missing-settings.json",
        .project_config = "missing-project-settings.json",
        .global_models = "missing-global-models.json",
        .project_models = "missing-project-models.json",
        .global_resources = global_root,
        .project_resources = project_pig,
    });
    defer snapshot.deinit(std.testing.allocator);
    var found_collision = false;
    for (snapshot.warnings.items) |warning| {
        if (warning.kind == .collision and std.mem.indexOf(u8, warning.path, "same.md") != null) found_collision = true;
    }
    try std.testing.expect(found_collision);
}

fn loadSnapshotWithAllocator(allocator: std.mem.Allocator, global_resources: []const u8, project_resources: []const u8) !void {
    var snapshot = try pig.resources.discovery.loadSnapshot(allocator, std.testing.io, .{
        .cwd = project_resources,
        // Point settings/models at missing files so the loaders emit `.missing`
        // warnings. Those warnings then flow through moveWarnings, which is the
        // exact append-OOM injection point that double-frees the snapshot and
        // leaks warning items on the un-fixed source.
        .global_config = "missing-settings.json",
        .project_config = "missing-project-settings.json",
        .global_models = "missing-global-models.json",
        .project_models = "missing-project-models.json",
        .global_resources = global_resources,
        .project_resources = project_resources,
    });
    snapshot.deinit(allocator);
}

test "resource snapshot cleans up on every allocation failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root);
    const global_root = try std.fs.path.join(std.testing.allocator, &.{ root, "global" });
    defer std.testing.allocator.free(global_root);
    const project_root = try std.fs.path.join(std.testing.allocator, &.{ root, "project" });
    defer std.testing.allocator.free(project_root);
    const project_pig = try std.fs.path.join(std.testing.allocator, &.{ project_root, ".pig" });
    defer std.testing.allocator.free(project_pig);
    const skills_dir = try std.fs.path.join(std.testing.allocator, &.{ global_root, "skills" });
    defer std.testing.allocator.free(skills_dir);
    const prompts_dir = try std.fs.path.join(std.testing.allocator, &.{ project_pig, "prompts" });
    defer std.testing.allocator.free(prompts_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, skills_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, prompts_dir);
    const skill_path = try std.fs.path.join(std.testing.allocator, &.{ skills_dir, "one.md" });
    defer std.testing.allocator.free(skill_path);
    const prompt_path = try std.fs.path.join(std.testing.allocator, &.{ prompts_dir, "p.md" });
    defer std.testing.allocator.free(prompt_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = skill_path, .data = "skill" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = prompt_path, .data = "prompt" });

    // Drive every allocation-failure injection point inside loadSnapshot. On the
    // un-fixed source the moveWarnings append-OOM path fires the per-component
    // errdefers plus snapshot.deinit (double free -> std.testing.allocator
    // panics) and strands un-moved warning items (leak). After the fix every
    // injection point unwinds with each allocation owned and freed exactly once.
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        loadSnapshotWithAllocator,
        .{ global_root, project_pig },
    );
}
