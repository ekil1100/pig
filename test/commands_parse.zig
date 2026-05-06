const std = @import("std");
const pig = @import("pig");

const commands = pig.app.commands;

test "slash command parser handles quoted args and escapes" {
    var parsed = try commands.parse(std.testing.allocator, "/model \"local qwen\" escaped\\ value");
    defer parsed.deinit();

    try std.testing.expectEqualStrings("/model \"local qwen\" escaped\\ value", parsed.raw);
    try std.testing.expectEqualStrings("model", parsed.name);
    try std.testing.expectEqual(@as(usize, 2), parsed.argv.len);
    try std.testing.expectEqualStrings("local qwen", parsed.argv[0]);
    try std.testing.expectEqualStrings("escaped value", parsed.argv[1]);
}

test "slash command parser distinguishes prompts and slash literals" {
    try std.testing.expect(!commands.isCommandInput("hello"));
    try std.testing.expect(!commands.isCommandInput("//send slash"));
    try std.testing.expect(commands.isSlashLiteral("//send slash"));
    try std.testing.expect(commands.isCommandInput("  /reload  "));
    try std.testing.expectError(error.NotCommand, commands.parse(std.testing.allocator, "hello"));
    try std.testing.expectError(error.LiteralSlash, commands.parse(std.testing.allocator, "//send slash"));
}

test "slash command parser reports malformed input" {
    try std.testing.expectError(error.MissingCommandName, commands.parse(std.testing.allocator, "/"));
    try std.testing.expectError(error.UnterminatedQuote, commands.parse(std.testing.allocator, "/model \"unterminated"));
    try std.testing.expectError(error.InvalidEscape, commands.parse(std.testing.allocator, "/model trailing\\"));
}
