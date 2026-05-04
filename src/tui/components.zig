const std = @import("std");

pub const ComponentKind = enum {
    text,
    markdown,
    box,
    spacer,
    loader,
    cancellable_loader,
    select_list,
    settings_list,
    overlay,
    image_placeholder,
};

pub const Component = struct {
    kind: ComponentKind,
    text: []const u8 = "",
};

pub fn text(value: []const u8) Component {
    return .{ .kind = .text, .text = value };
}

pub fn loader(label: []const u8) Component {
    return .{ .kind = .loader, .text = label };
}

pub fn cancellableLoader(label: []const u8) Component {
    return .{ .kind = .cancellable_loader, .text = label };
}

pub fn renderPlain(allocator: std.mem.Allocator, component: Component) ![]const u8 {
    return switch (component.kind) {
        .text, .markdown => try allocator.dupe(u8, component.text),
        .box => try std.fmt.allocPrint(allocator, "[ {s} ]", .{component.text}),
        .spacer => try allocator.dupe(u8, ""),
        .loader => try std.fmt.allocPrint(allocator, "... {s}", .{component.text}),
        .cancellable_loader => try std.fmt.allocPrint(allocator, "... {s} (Ctrl+C to abort)", .{component.text}),
        .select_list => try std.fmt.allocPrint(allocator, "> {s}", .{component.text}),
        .settings_list => try std.fmt.allocPrint(allocator, "settings: {s}", .{component.text}),
        .overlay => try std.fmt.allocPrint(allocator, "[overlay] {s}", .{component.text}),
        .image_placeholder => try std.fmt.allocPrint(allocator, "[image: {s}]", .{component.text}),
    };
}
