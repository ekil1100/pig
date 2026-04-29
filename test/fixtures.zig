const std = @import("std");

test "m0 fixtures exist and are readable" {
    const fixture_paths = [_][]const u8{
        "fixtures/README.md",
        "fixtures/pi-mono/package-list.json",
        "fixtures/pi-mono/package-readmes.json",
        "fixtures/pi-mono/cli-samples.jsonl",
        "fixtures/fake-provider/empty-turn.jsonl",
    };

    for (fixture_paths) |path| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1024 * 1024));
        defer std.testing.allocator.free(bytes);
        try std.testing.expect(bytes.len > 0);
    }
}
