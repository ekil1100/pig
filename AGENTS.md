# Pig

Local-first coding-agent project implemented in Zig.

## Project Goal

Pig v1.0 is a Zig implementation of a local coding-agent CLI. The current codebase is in the M1 provider-layer phase: CLI diagnostics and build foundation are present, provider message/event/auth/parsing foundations are in place, and the reusable agent runtime starts in later milestones.

Near-term priorities:

1. Keep the Zig foundation compiling and well tested.
2. Preserve provider-agnostic message, event, auth, and transport boundaries.
3. Build the reusable agent runtime without coupling it to terminal rendering.
4. Keep CLI behavior local-first and predictable.

## Current State

- Runtime/language: Zig 0.16.x
- Entry point: `src/main.zig`
- Build files: `build.zig`, `build.zig.zon`
- Main implemented areas:
  - CLI dispatch and diagnostics
  - provider message/content types
  - unified provider streaming events
  - SSE parsing
  - OpenAI-compatible and Anthropic recorded parsers
  - provider auth resolution
  - optional live smoke harness

## Working Rules

- Prefer Zig build commands for run, test, smoke, fixture, and formatting checks.
- Do not add Bun, Node, TypeScript, or other runtime tooling unless the user explicitly asks.
- Keep the implementation simple. Avoid introducing frameworks or deep abstractions unless they directly support the v1.0 roadmap.
- Preserve clear module boundaries:
  `app -> core/provider/session/resources/tools/tui/rpc/plugin/util`
- Keep provider parsing and transport details out of `app` and `tui`.
- Treat this repo as local-first CLI software, not a web app or multi-agent platform.
- Never commit secrets. API keys must come from the environment or local auth files and stay gitignored.

## Expected Commands

```bash
zig build run -- --version
zig build run -- --help
zig build run -- doctor
zig build run -- paths
zig build test
zig build smoke
zig build provider-fixtures
zig build fmt-check
```

## Implementation Guidance

When making nontrivial changes, align with the current Zig docs and roadmap:

- `docs/architecture.md`
- `docs/error-model.md`
- `docs/fixtures.md`
- `docs/allocator-policy.md`
- `docs/provider-events.md`
- `docs/provider-auth.md`
- `docs/provider-transport.md`
- `.agents/pig-v1.0-roadmap.md`

Current milestone shape:

1. M0: compileable skeleton, local diagnostics, fixtures, docs, tests.
2. M1: provider message/content models, unified streaming events, SSE parser, auth resolver, recorded parsers, provider fixtures, optional live smoke harness.
3. M2: reusable agent runtime and event bus, still independent of terminal rendering.

## Scope Boundaries

For the current v1.0 roadmap, do not expand into:

- Multi-agent workflows
- Web UI
- Cloud sync
- Plugin/runtime ecosystems beyond planned local protocol placeholders
- RAG/vector search
- Multi-model routing

Those may come later, but they are not the current target.

## Files

- `src/main.zig`: CLI entry point
- `src/app`: CLI dispatch and build info
- `src/provider`: provider models, events, auth, transport, and recorded parsers
- `src/core`: shared errors and future runtime placeholders
- `test`: unit, fixture, and provider tests
- `fixtures`: small offline fixtures
- `docs`: architecture, error, fixture, allocator, and provider notes
- `.env`: local-only environment file, not committed
