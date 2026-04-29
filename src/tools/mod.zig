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
