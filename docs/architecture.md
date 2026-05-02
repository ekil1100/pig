# Pig v1.0 Architecture

Pig v1.0 is a Zig 0.16 local-first coding-agent implementation. M0 established the skeleton; M1 added the provider layer; M2 added a reusable agent runtime; M3 adds built-in local coding tools while still avoiding session persistence, product CLI modes, and TUI coupling.

## Modules

- `app`: CLI dispatch, build info, diagnostics, path output.
- `core`: shared errors/IDs and `core.agent`, the M2 reusable runtime, event bus, state, model-client, tool, middleware, and test harness contracts.
- `provider`: message/content models, provider events, SSE parsing, auth resolution, request building, and provider-specific recorded parsers.
- `tools`: built-in coding tools, metadata/schema, approval, path policy, output handling, and M2 registry adapter.
- `session`: session path placeholder API.
- `resources`: resource kind/source classifications.
- `tui`: terminal capability placeholders.
- `rpc`: protocol version placeholder.
- `plugin`: protocol version placeholder.
- `util`: path, JSON, and testing helpers.

## Dependency Direction

The intended direction is:

```text
app -> core/provider/session/resources/tools/tui/rpc/plugin/util
core -> provider/tools/session/resources
provider -> util
provider -> stdlib HTTP/IO through provider.transport only
tools -> util
session -> util
```

Provider modules must not depend on `app` or `tui`. Provider parsers emit `ProviderEvent` through `EventSink`; `core.agent` consumes those events without parsing provider-specific SSE/JSON.

## M0 to M2 Evolution

- M0: compileable skeleton, local diagnostics, fixtures, docs, tests.
- M1: provider message/content models, unified streaming events, SSE parser, auth resolver, OpenAI-compatible recorded parser, Anthropic recorded parser, provider fixtures, and optional live smoke harness.
- M2: reusable agent runtime and event bus, scripted model client, fake tool harness, middleware hooks, cooperative abort, and offline agent fixtures; still independent of terminal rendering.
- M3: built-in coding tools (`read`, `write`, `edit`, `bash`, `grep`, `find`, `ls`) with approval policy, workspace path checks, structured JSON results, and offline tool fixtures.
