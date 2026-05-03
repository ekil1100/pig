const std = @import("std");
const entry_mod = @import("entry.zig");
const tree_mod = @import("tree.zig");

pub const FsyncPolicy = enum {
    flush_only,
    header_and_turn_end,
    strict,
};

pub const CreateOptions = struct {
    sessions_dir: []const u8,
    session_id: []const u8,
    cwd: []const u8,
    created_ms: i64,
    pig_version: ?[]const u8 = null,
    policy: FsyncPolicy = .header_and_turn_end,
};

pub const OpenOptions = struct {
    path: []const u8,
    policy: FsyncPolicy = .header_and_turn_end,
    max_bytes: usize = 16 * 1024 * 1024,
};

pub const LoadInfo = struct {
    recovered_partial_final_line: bool,
    valid_prefix_len: usize,
};

pub const SessionStore = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    file: std.Io.File,
    entries: std.ArrayList(entry_mod.Entry) = .empty,
    tree: tree_mod.SessionTree,
    policy: FsyncPolicy,
    recovered_partial_final_line: bool = false,

    pub fn deinit(self: *SessionStore) void {
        self.tree.deinit();
        for (self.entries.items) |*entry| entry.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.file.close(self.io);
        self.allocator.free(self.path);
        self.* = undefined;
    }

    pub fn append(self: *SessionStore, view: entry_mod.EntryView) !void {
        if (view.schema != entry_mod.schema_version) return error.UnsupportedSchema;
        if (self.tree.entries_by_id.contains(view.id)) return error.DuplicateId;
        if (view.kind() == .header) return error.DuplicateHeader;
        if (view.parent_id) |parent| {
            if (!self.tree.entries_by_id.contains(parent)) return error.MissingParent;
        } else if (view.kind() != .header) {
            return error.InvalidRoot;
        }

        const line = try entry_mod.writeLine(self.allocator, view);
        defer self.allocator.free(line);
        var owned = try entry_mod.cloneFromView(self.allocator, view);
        errdefer owned.deinit(self.allocator);
        try self.entries.ensureUnusedCapacity(self.allocator, 1);

        const projected_entries = try self.allocator.alloc(entry_mod.Entry, self.entries.items.len + 1);
        defer self.allocator.free(projected_entries);
        @memcpy(projected_entries[0..self.entries.items.len], self.entries.items);
        projected_entries[self.entries.items.len] = owned;
        var next_tree = try tree_mod.rebuild(self.allocator, projected_entries);
        errdefer next_tree.deinit();

        const offset = try self.file.length(self.io);
        try self.file.writePositionalAll(self.io, line, offset);
        try self.file.writePositionalAll(self.io, "\n", offset + line.len);
        if (self.policy == .strict) try self.file.sync(self.io);

        self.entries.appendAssumeCapacity(owned);
        self.tree.deinit();
        self.tree = next_tree;
    }

    pub fn branchFrom(self: *SessionStore, id: []const u8) !void {
        try self.tree.branchFrom(id);
    }

    pub fn finishTurn(self: *SessionStore) !void {
        if (self.policy == .header_and_turn_end or self.policy == .strict) try self.file.sync(self.io);
    }

    pub fn currentLeaf(self: *const SessionStore) []const u8 {
        return self.tree.current_leaf_id;
    }
};

pub fn create(allocator: std.mem.Allocator, io: std.Io, options: CreateOptions) !SessionStore {
    try std.Io.Dir.cwd().createDirPath(io, options.sessions_dir);
    const filename = try std.fmt.allocPrint(allocator, "{s}.jsonl", .{options.session_id});
    defer allocator.free(filename);
    const path = try std.fs.path.join(allocator, &.{ options.sessions_dir, filename });
    errdefer allocator.free(path);

    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = true });
    errdefer file.close(io);

    const header = entry_mod.EntryView{
        .id = "entry_root",
        .session_id = options.session_id,
        .parent_id = null,
        .created_ms = options.created_ms,
        .data = .{ .header = .{ .cwd = options.cwd, .pig_version = options.pig_version } },
    };
    const line = try entry_mod.writeLine(allocator, header);
    defer allocator.free(line);
    try file.writePositionalAll(io, line, 0);
    try file.writePositionalAll(io, "\n", line.len);
    if (options.policy != .flush_only) try file.sync(io);

    var entries: std.ArrayList(entry_mod.Entry) = .empty;
    errdefer {
        for (entries.items) |*entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }
    var owned_header = try entry_mod.cloneFromView(allocator, header);
    errdefer owned_header.deinit(allocator);
    try entries.append(allocator, owned_header);
    var tree = try tree_mod.rebuild(allocator, entries.items);
    errdefer tree.deinit();

    return .{
        .allocator = allocator,
        .io = io,
        .path = path,
        .file = file,
        .entries = entries,
        .tree = tree,
        .policy = options.policy,
    };
}

pub fn open(allocator: std.mem.Allocator, io: std.Io, options: OpenOptions) !SessionStore {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, options.path, allocator, .limited(options.max_bytes));
    defer allocator.free(bytes);

    var entries: std.ArrayList(entry_mod.Entry) = .empty;
    errdefer {
        for (entries.items) |*entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }
    const load_info = try parseJsonl(allocator, bytes, &entries);
    var tree = try tree_mod.rebuild(allocator, entries.items);
    errdefer tree.deinit();

    const path = try allocator.dupe(u8, options.path);
    errdefer allocator.free(path);
    var file = try std.Io.Dir.cwd().openFile(io, options.path, .{ .mode = .read_write });
    errdefer file.close(io);
    if (load_info.recovered_partial_final_line) {
        try file.setLength(io, load_info.valid_prefix_len);
        if (options.policy != .flush_only) try file.sync(io);
    }

    return .{
        .allocator = allocator,
        .io = io,
        .path = path,
        .file = file,
        .entries = entries,
        .tree = tree,
        .policy = options.policy,
        .recovered_partial_final_line = load_info.recovered_partial_final_line,
    };
}

pub fn parseJsonl(allocator: std.mem.Allocator, bytes: []const u8, entries: *std.ArrayList(entry_mod.Entry)) !LoadInfo {
    var load_info = LoadInfo{ .recovered_partial_final_line = false, .valid_prefix_len = 0 };
    var start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, bytes, start, '\n')) |newline| {
        const line = bytes[start..newline];
        var entry = try entry_mod.parseLine(allocator, line);
        errdefer entry.deinit(allocator);
        try entries.append(allocator, entry);
        start = newline + 1;
        load_info.valid_prefix_len = start;
    }

    if (start < bytes.len) {
        const final_line = bytes[start..];
        var entry = entry_mod.parseLine(allocator, final_line) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                load_info.recovered_partial_final_line = true;
                return load_info;
            },
        };
        errdefer entry.deinit(allocator);
        try entries.append(allocator, entry);
        load_info.valid_prefix_len = bytes.len;
    }
    return load_info;
}
