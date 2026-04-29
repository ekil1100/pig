pub const ResourceKind = enum {
    settings,
    auth,
    model_registry,
    agents_file,
    skill,
    prompt_template,
    theme,
    package,
};

pub const ResourceSource = enum {
    builtin,
    global,
    project,
};
