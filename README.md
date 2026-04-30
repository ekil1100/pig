# Pig

Pig is a local-first coding-agent project implemented in Zig.

The Zig implementation targets Zig 0.16.x.

M0 established the engineering foundation and CLI diagnostics. M1 adds the provider layer foundation: provider message/content types, unified streaming events, SSE parsing, OpenAI-compatible recorded parser, Anthropic recorded parser, provider auth resolution, and optional live smoke harness.

Available local commands:

```bash
zig build run -- --version
zig build run -- --help
zig build run -- doctor
zig build run -- paths
```

## Zig Requirements

- Zig 0.16.x
- No third-party Zig dependencies in M1

Check your version:

```bash
zig version
```

## Zig Build and Test

Default checks are offline:

```bash
zig build
zig build test
zig build smoke
zig build provider-fixtures
zig build provider-live
zig build fmt-check
```

`zig build provider-live` skips unless explicitly enabled. M1 includes the live harness; actual live HTTP streaming transport currently reports unsupported when fully enabled. To attempt a live OpenAI-compatible streaming check once transport is implemented:

```bash
PIG_PROVIDER_LIVE=1 \
PIG_OPENAI_COMPAT_BASE_URL="https://..." \
PIG_OPENAI_COMPAT_API_KEY="..." \
PIG_OPENAI_COMPAT_MODEL="..." \
zig build provider-live
```

API keys must come from the environment and must not be committed.

## Zig Project Structure

- `build.zig` / `build.zig.zon` — Zig 0.16 build configuration
- `src/main.zig` — Zig CLI entry point
- `src/app` — CLI dispatch and build info
- `src/core` — shared errors and ID placeholders
- `src/provider` — M1 provider models, events, SSE parsing, auth, transport, recorded parsers
- `src/tools` — tool risk/access placeholders
- `src/session` — session path placeholders
- `src/resources` — resource placeholders
- `src/tui` — terminal capability placeholders
- `src/rpc` / `src/plugin` — protocol version placeholders
- `src/util` — path and testing helpers
- `test` — unit, fixture, and provider tests
- `fixtures` — small offline fixtures
- `docs` — architecture, error, fixture, allocator, and provider notes

## Documentation

- `docs/architecture.md`
- `docs/error-model.md`
- `docs/fixtures.md`
- `docs/allocator-policy.md`
- `docs/provider-events.md`
- `docs/provider-auth.md`
- `docs/provider-transport.md`

## Notes

- `.env` is local-only and gitignored.
- Default tests are offline and do not require API keys.
- Agent runtime, coding tools, sessions, and product CLI modes start in later milestones.
