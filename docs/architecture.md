# Pig v1.0 Architecture

Pig v1.0 is a Zig 0.16 local-first coding-agent implementation. M0 established the skeleton; M1 adds the provider layer while still avoiding agent runtime, tools, session persistence, and TUI coupling.

## Modules

- `app`: CLI dispatch, build info, diagnostics, path output.
- `core`: shared error categories and ID placeholders; future agent runtime.
- `provider`: message/content models, provider events, SSE parsing, auth resolution, request building, and provider-specific recorded parsers.
- `tools`: tool risk and access classifications.
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

Provider modules must not depend on `app` or `tui`. Provider parsers emit `ProviderEvent` through `EventSink`; M2 will consume those events without parsing provider-specific SSE/JSON.

## M0 to M2 Evolution

- M0: compileable skeleton, local diagnostics, fixtures, docs, tests.
- M1: provider message/content models, unified streaming events, SSE parser, auth resolver, OpenAI-compatible recorded parser, Anthropic recorded parser, provider fixtures, and optional live smoke harness.
- M2: reusable agent runtime and event bus, still independent of terminal rendering.
