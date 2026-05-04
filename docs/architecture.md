# Pig v1.0 Architecture

Pig v1.0 is a Zig 0.16 local-first coding-agent implementation. M0 established the skeleton; M1 added the provider layer; M2 added a reusable agent runtime; M3 added built-in local coding tools; M4 added append-only session JSONL persistence and context tree indexing; M5 exposed print/json CLI modes; M6 started the terminal UI foundation; M7 adds config, auth, models, context files, and resource loading while keeping resources independent from app/runtime concerns.

## Modules

- `app`: CLI dispatch, build info, diagnostics, path output, print/json mode assembly, config runtime assembly, model factory, and interactive-mode glue.
- `core`: shared errors/IDs and `core.agent`, the M2 reusable runtime, event bus, state, model-client, tool, middleware, and test harness contracts.
- `provider`: message/content models, provider events, SSE parsing, auth resolution, request building, and provider-specific recorded parsers.
- `tools`: built-in coding tools, metadata/schema, approval, path policy, output handling, and M2 registry adapter.
- `session`: session path API, provider-independent entry DTOs, append-only JSONL store, and context tree index.
- `resources`: settings, model registry, context file discovery, metadata resource discovery, source tracking, and warnings.
- `tui`: terminal capability declarations, input decoding, editor state, layout, components, virtual frame rendering, and in-memory terminal testing helpers.
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
- M4: `.pig` path namespace, provider-independent session entries, append-only JSONL store, partial final line recovery, context tree rebuild, and offline session fixtures.
- M5: product CLI mode parser, non-interactive print mode, JSONL output mode, runtime assembly, and session recorder fanout.
- M6: TUI foundation modules for input/editor/layout/render/components and a scripted interactive mode path that maps agent events into a terminal transcript view.
- M7: settings/model registry/context file/resource metadata loading, app-level config runtime assembly, auth-backed model factory boundary, doctor resource diagnostics, and scripted interactive `/reload`.
