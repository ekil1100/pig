# Pig

Pig is a local coding-agent project. The current repository keeps the original Bun/TypeScript teaching demo and now also contains the Pig v1.0 Zig implementation skeleton.

## Current Tracks

### Bun/TypeScript Demo

The demo agent is a small learning implementation using raw Gemini HTTP calls.

Run it with:

```bash
bun install
bun agent.ts
```

It supports the teaching/demo tools in `agent.ts`:

- `list_files`
- `read_file`
- `run_bash`
- `edit_file`

### Zig v1.0 M0 Skeleton

M0 establishes the Zig 0.16 engineering foundation. It intentionally does not implement real provider calls, the agent loop, coding tools, session persistence, or a TUI.

Available M0 commands:

```bash
zig build run -- --version
zig build run -- --help
zig build run -- doctor
zig build run -- paths
```

## Zig Requirements

- Zig 0.16.x
- No third-party Zig dependencies in M0

Check your version:

```bash
zig version
```

## Zig Build and Test

```bash
zig build
zig build test
zig build smoke
zig build fmt-check
```

## M0 Project Structure

- `build.zig` / `build.zig.zon` — Zig 0.16 build configuration
- `src/main.zig` — Zig CLI entry point
- `src/app` — CLI dispatch and build info
- `src/core` — shared errors and ID placeholders
- `src/provider` — provider placeholders
- `src/tools` — tool risk/access placeholders
- `src/session` — session path placeholders
- `src/resources` — resource placeholders
- `src/tui` — terminal capability placeholders
- `src/rpc` / `src/plugin` — protocol version placeholders
- `src/util` — path and testing helpers
- `test` — M0 unit/fixture tests
- `fixtures` — small offline fixtures
- `docs` — M0 architecture, error, fixture, and allocator notes

## Documentation

- `docs/architecture.md`
- `docs/error-model.md`
- `docs/fixtures.md`
- `docs/allocator-policy.md`

## Notes

- `.env` is local-only and gitignored.
- M0 tests are offline and do not require API keys.
- Agent functionality starts in later milestones.
