const std = @import("std");
const pig = @import("pig");

test "context discovery stays inside workspace root and orders root before child" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root);
    const workspace = try std.fs.path.join(std.testing.allocator, &.{ root, "repo" });
    defer std.testing.allocator.free(workspace);
    const child = try std.fs.path.join(std.testing.allocator, &.{ workspace, "src" });
    defer std.testing.allocator.free(child);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, child);
    const pig_dir = try std.fs.path.join(std.testing.allocator, &.{ workspace, ".pig" });
    defer std.testing.allocator.free(pig_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, pig_dir);
    const parent_agents = try std.fs.path.join(std.testing.allocator, &.{ root, "AGENTS.md" });
    defer std.testing.allocator.free(parent_agents);
    const root_agents = try std.fs.path.join(std.testing.allocator, &.{ workspace, "AGENTS.md" });
    defer std.testing.allocator.free(root_agents);
    const child_agents = try std.fs.path.join(std.testing.allocator, &.{ child, "AGENTS.md" });
    defer std.testing.allocator.free(child_agents);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = parent_agents, .data = "outside" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root_agents, .data = "root" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = child_agents, .data = "child" });

    var snapshot = try pig.resources.context_files.load(std.testing.allocator, std.testing.io, .{ .cwd = child, .include = &.{"AGENTS.md"}, .max_bytes = 4096 });
    defer snapshot.deinit(std.testing.allocator);
    const prompt = snapshot.system_prompt.?;
    try std.testing.expect(std.mem.indexOf(u8, prompt, "outside") == null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "root").? < std.mem.indexOf(u8, prompt, "child").?);
}

test "context discovery without workspace marker only reads cwd" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root);
    const child = try std.fs.path.join(std.testing.allocator, &.{ root, "src" });
    defer std.testing.allocator.free(child);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, child);
    const parent_agents = try std.fs.path.join(std.testing.allocator, &.{ root, "AGENTS.md" });
    defer std.testing.allocator.free(parent_agents);
    const child_agents = try std.fs.path.join(std.testing.allocator, &.{ child, "AGENTS.md" });
    defer std.testing.allocator.free(child_agents);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = parent_agents, .data = "parent" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = child_agents, .data = "child" });

    var snapshot = try pig.resources.context_files.load(std.testing.allocator, std.testing.io, .{ .cwd = child, .include = &.{"AGENTS.md"}, .max_bytes = 4096 });
    defer snapshot.deinit(std.testing.allocator);
    const prompt = snapshot.system_prompt.?;
    try std.testing.expect(std.mem.indexOf(u8, prompt, "parent") == null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "child") != null);
}

test "context prompt places system and append system in stable sections" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root);
    const child = try std.fs.path.join(std.testing.allocator, &.{ root, "src" });
    defer std.testing.allocator.free(child);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, child);
    const pig_dir = try std.fs.path.join(std.testing.allocator, &.{ root, ".pig" });
    defer std.testing.allocator.free(pig_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, pig_dir);

    const root_agents = try std.fs.path.join(std.testing.allocator, &.{ root, "AGENTS.md" });
    defer std.testing.allocator.free(root_agents);
    const child_agents = try std.fs.path.join(std.testing.allocator, &.{ child, "AGENTS.md" });
    defer std.testing.allocator.free(child_agents);
    const system = try std.fs.path.join(std.testing.allocator, &.{ root, "SYSTEM.md" });
    defer std.testing.allocator.free(system);
    const append_system = try std.fs.path.join(std.testing.allocator, &.{ root, "APPEND_SYSTEM.md" });
    defer std.testing.allocator.free(append_system);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root_agents, .data = "root agents" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = child_agents, .data = "child agents" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = system, .data = "system" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = append_system, .data = "append system" });

    var snapshot = try pig.resources.context_files.load(std.testing.allocator, std.testing.io, .{ .cwd = child, .include = &.{ "AGENTS.md", "SYSTEM.md", "APPEND_SYSTEM.md" }, .max_bytes = 4096 });
    defer snapshot.deinit(std.testing.allocator);
    const prompt = snapshot.system_prompt.?;
    const root_agents_index = std.mem.indexOf(u8, prompt, "root agents").?;
    const child_agents_index = std.mem.indexOf(u8, prompt, "child agents").?;
    const system_index = std.mem.indexOf(u8, prompt, "system").?;
    const append_index = std.mem.lastIndexOf(u8, prompt, "append system").?;
    try std.testing.expect(root_agents_index < child_agents_index);
    try std.testing.expect(child_agents_index < system_index);
    try std.testing.expect(system_index < append_index);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "[System:") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "[Append System:") != null);
}
