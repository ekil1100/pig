# Pig v1.0 M0 Architecture

M0 establishes a Zig 0.16 engineering skeleton. It does not implement provider calls, agent loops, tools, session persistence, or TUI rendering.

## Modules

- `app`: CLI dispatch, build info, diagnostics, path output.
- `core`: shared error categories and ID placeholders.
- `provider`: provider kind/status placeholders for the future `pi-ai` equivalent.
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
tools -> util
session -> util
```

M0 keeps the modules shallow so later milestones can add behavior without reversing dependencies. Provider modules must not depend on `app` or `tui`, and TUI modules must not know coding-agent business semantics.

## M0 to M2 Evolution

- M0: compileable skeleton, local diagnostics, fixtures, docs, tests.
- M1: provider message/content/streaming abstractions and recorded provider fixtures.
- M2: reusable agent runtime and event bus, still independent of terminal rendering.
