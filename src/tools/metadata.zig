pub const ToolRisk = enum {
    safe,
    confirmation_required,
    destructive,
};

pub const ToolAccess = enum {
    read_only,
    write_files,
    execute_process,
    network,
};

pub const BuiltinToolSpec = struct {
    name: []const u8,
    display_label: []const u8,
    description: []const u8,
    schema_json: []const u8,
    risk: ToolRisk,
    access: ToolAccess,
};

pub const read_schema =
    \\{"type":"object","properties":{"path":{"type":"string"},"offset":{"type":"integer","minimum":1},"limit":{"type":"integer","minimum":1,"maximum":2000}},"required":["path"],"additionalProperties":false}
;
pub const write_schema =
    \\{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"},"mode":{"type":"string","enum":["create_new","overwrite","append"]},"create_parents":{"type":"boolean"}},"required":["path","content"],"additionalProperties":false}
;
pub const edit_schema =
    \\{"type":"object","properties":{"path":{"type":"string"},"edits":{"type":"array","minItems":1,"items":{"type":"object","properties":{"old_text":{"type":"string","minLength":1},"new_text":{"type":"string"}},"required":["old_text","new_text"],"additionalProperties":false}}},"required":["path","edits"],"additionalProperties":false}
;
pub const bash_schema =
    \\{"type":"object","properties":{"command":{"type":"string","minLength":1},"timeout_ms":{"type":"integer","minimum":1}},"required":["command"],"additionalProperties":false}
;
pub const grep_schema =
    \\{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string"},"literal":{"type":"boolean"},"ignore_case":{"type":"boolean"},"limit":{"type":"integer","minimum":1}},"required":["pattern"],"additionalProperties":false}
;
pub const find_schema =
    \\{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string"},"limit":{"type":"integer","minimum":1}},"required":["pattern"],"additionalProperties":false}
;
pub const ls_schema =
    \\{"type":"object","properties":{"path":{"type":"string"},"limit":{"type":"integer","minimum":1}},"additionalProperties":false}
;

pub const builtin_specs = [_]BuiltinToolSpec{
    .{ .name = "read", .display_label = "Read File", .description = "Read a text file in the workspace", .schema_json = read_schema, .risk = .safe, .access = .read_only },
    .{ .name = "write", .display_label = "Write File", .description = "Create, overwrite, or append to a workspace file", .schema_json = write_schema, .risk = .confirmation_required, .access = .write_files },
    .{ .name = "edit", .display_label = "Edit File", .description = "Replace exact text in a workspace file", .schema_json = edit_schema, .risk = .confirmation_required, .access = .write_files },
    .{ .name = "bash", .display_label = "Run Bash", .description = "Run a bash command in the workspace", .schema_json = bash_schema, .risk = .confirmation_required, .access = .execute_process },
    .{ .name = "grep", .display_label = "Grep", .description = "Search text files with literal substring matching", .schema_json = grep_schema, .risk = .safe, .access = .read_only },
    .{ .name = "find", .display_label = "Find Files", .description = "Find workspace files by simple basename wildcard", .schema_json = find_schema, .risk = .safe, .access = .read_only },
    .{ .name = "ls", .display_label = "List Directory", .description = "List workspace directory entries", .schema_json = ls_schema, .risk = .safe, .access = .read_only },
};

pub fn specFor(name: []const u8) ?BuiltinToolSpec {
    const std = @import("std");
    for (builtin_specs) |spec| if (std.mem.eql(u8, spec.name, name)) return spec;
    return null;
}
