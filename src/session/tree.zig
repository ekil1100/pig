const std = @import("std");
const entry_mod = @import("entry.zig");

pub const TreeError = error{
    MissingHeader,
    DuplicateHeader,
    DuplicateId,
    InvalidRoot,
    MissingParent,
    UnknownEntry,
} || std.mem.Allocator.Error;

pub const SessionTree = struct {
    allocator: std.mem.Allocator,
    entries_by_id: std.StringHashMap(usize),
    children_by_parent: std.StringHashMap(std.ArrayList(usize)),
    root_id: []const u8,
    current_leaf_id: []const u8,

    pub fn init(allocator: std.mem.Allocator, root_id: []const u8, current_leaf_id: []const u8) SessionTree {
        return .{
            .allocator = allocator,
            .entries_by_id = std.StringHashMap(usize).init(allocator),
            .children_by_parent = std.StringHashMap(std.ArrayList(usize)).init(allocator),
            .root_id = root_id,
            .current_leaf_id = current_leaf_id,
        };
    }

    pub fn deinit(self: *SessionTree) void {
        var values = self.children_by_parent.valueIterator();
        while (values.next()) |list| list.deinit(self.allocator);
        self.children_by_parent.deinit();
        self.entries_by_id.deinit();
        self.* = undefined;
    }

    pub fn indexOf(self: *const SessionTree, id: []const u8) ?usize {
        return self.entries_by_id.get(id);
    }

    pub fn childrenOf(self: *const SessionTree, parent_id: []const u8) []const usize {
        if (self.children_by_parent.get(parent_id)) |list| return list.items;
        return &.{};
    }

    pub fn branchFrom(self: *SessionTree, id: []const u8) TreeError!void {
        if (!self.entries_by_id.contains(id)) return error.UnknownEntry;
        self.current_leaf_id = id;
    }
};

pub fn rebuild(allocator: std.mem.Allocator, entries: []const entry_mod.Entry) TreeError!SessionTree {
    if (entries.len == 0) return error.MissingHeader;

    var root_id: ?[]const u8 = null;
    var current_leaf_id: []const u8 = entries[entries.len - 1].id;
    var tree = SessionTree.init(allocator, entries[0].id, current_leaf_id);
    errdefer tree.deinit();

    for (entries, 0..) |entry, index| {
        if (tree.entries_by_id.contains(entry.id)) return error.DuplicateId;
        try tree.entries_by_id.put(entry.id, index);
        if (entry.kind() == .header) {
            if (root_id != null) return error.DuplicateHeader;
            root_id = entry.id;
        }
    }

    const root = root_id orelse return error.MissingHeader;
    for (entries, 0..) |entry, index| {
        if (entry.kind() == .header and entry.parent_id != null) return error.InvalidRoot;
        if (entry.parent_id) |parent| {
            if (!tree.entries_by_id.contains(parent)) return error.MissingParent;
            try addChild(&tree, parent, index);
        } else if (entry.kind() != .header) {
            return error.InvalidRoot;
        }

        if (entry.kind() == .session_info) {
            if (entry.data.session_info.current_leaf_id) |leaf| {
                if (tree.entries_by_id.contains(leaf)) current_leaf_id = leaf;
            }
        }
    }

    tree.root_id = root;
    tree.current_leaf_id = current_leaf_id;
    return tree;
}

fn addChild(tree: *SessionTree, parent_id: []const u8, child_index: usize) TreeError!void {
    if (!tree.children_by_parent.contains(parent_id)) {
        try tree.children_by_parent.put(parent_id, .empty);
    }
    const children = tree.children_by_parent.getPtr(parent_id) orelse return error.MissingParent;
    try children.append(tree.allocator, child_index);
}
