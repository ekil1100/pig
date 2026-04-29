# Allocator Policy

Pig v1.0 is local-first CLI software. Allocation ownership is explicit so provider streaming, session trees, and TUI state do not accumulate hidden lifetime bugs.

## Rules

- CLI commands receive an allocator from the caller.
- Tests use `std.testing.allocator` and must free owned memory.
- Short-lived command data may use the process allocator or an arena owned by the command.
- Long-lived structs that own memory must expose `deinit()`.
- Module APIs should prefer caller-provided allocators over globals.
- Owned slices returned from helpers must document and provide cleanup.

## M0 Policy

- `PathSet` owns all path strings and must be released with `PathSet.deinit(allocator)`.
- CLI path diagnostics allocate path strings for the duration of one command.
- Fixture tests allocate file contents with `std.testing.allocator` and free them immediately.

## M1 Provider Policy

- `ProviderEvent` payload slices are callback-scoped and owned by parser buffers.
- Sinks that retain events must clone payloads; `provider.testing.EventCollector` does this for tests.
- SSE parser buffers are owned by one `Parser` and released with `Parser.deinit()`.
- Provider JSON parsing uses temporary parsed values and deinitializes them after each chunk.
- `transport.Request` owns method, URL, headers, and body; call `Request.deinit(allocator)`.
- `OwnedMessage` and `OwnedContentBlock` own duplicated content and must be deinitialized.
- `MessageView` and `ContentBlockView` are borrowed and must not free caller-owned slices.

## Later Milestones

- Session indexes should have explicit init/deinit ownership.
- TUI render buffers should be owned by the renderer or command session, not global state.
