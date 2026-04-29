# Allocator Policy

Pig v1.0 is local-first CLI software. M0 keeps allocation ownership explicit so later provider streaming, session trees, and TUI state do not accumulate hidden lifetime bugs.

## Rules

- CLI commands receive an allocator from the caller.
- Tests use `std.testing.allocator` and must free owned memory.
- Short-lived command data may use the process allocator or an arena owned by the command.
- Long-lived structs that own memory must expose `deinit()`.
- Module APIs should prefer caller-provided allocators over globals.
- Owned slices returned from helpers must document and provide cleanup.

## Current M0 Policy

- `PathSet` owns all path strings and must be released with `PathSet.deinit(allocator)`.
- CLI path diagnostics allocate path strings for the duration of one command.
- Fixture tests allocate file contents with `std.testing.allocator` and free them immediately.

## Later Milestones

- Provider stream parsers should bind temporary buffers to one request.
- Session indexes should have explicit init/deinit ownership.
- TUI render buffers should be owned by the renderer or command session, not global state.
