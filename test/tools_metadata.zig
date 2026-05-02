const std = @import("std");
const pig = @import("pig");
const tools = pig.tools;

test "builtin tool metadata has unique names and parseable schemas" {
    for (tools.metadata.builtin_specs, 0..) |spec, i| {
        try std.testing.expect(spec.name.len > 0);
        try std.testing.expect(spec.display_label.len > 0);
        try std.testing.expect(spec.description.len > 0);
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, spec.schema_json, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .object);
        for (tools.metadata.builtin_specs[0..i]) |prev| try std.testing.expect(!std.mem.eql(u8, spec.name, prev.name));
    }
    try std.testing.expect(tools.metadata.specFor("read") != null);
    try std.testing.expect(tools.metadata.specFor("bash") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.metadata.write_schema, "\"enum\":[\"create_new\",\"overwrite\",\"append\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.metadata.edit_schema, "\"old_text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.metadata.edit_schema, "\"new_text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools.metadata.edit_schema, "\"minItems\":1") != null);
}
