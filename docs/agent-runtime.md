# Agent Runtime

M2 adds `core.agent`, a reusable runtime layer above the M1 provider event model.

## Scope

M2 implements the core loop only:

```text
append user input -> stream provider events -> append assistant message -> execute fake/test tools -> append tool results -> continue until final assistant text
```

It does not implement real coding tools, session persistence, product CLI modes, TUI rendering, config loading, or live provider transport.

## State

`AgentState` owns conversation history as `provider.OwnedMessage` values. Provider requests are built with temporary borrowed `MessageViewBatch` values. A batch owns only the view slices; message payload strings remain owned by `AgentState`.

`StreamAccumulator` owns in-progress text, thinking text/signature bytes, completed pending tool calls, usage, and a diagnostic `saw_done` flag for one provider iteration.

## Lifecycle

Each `AgentRuntime.runUserText()` call is one bounded agent run for one user turn. After `before_input` succeeds, it emits paired lifecycle events:

```text
agent_start
turn_start
...
turn_end(status)
agent_end(status)
```

The same `AgentState` may be reused across multiple calls; prior messages remain conversation history while lifecycle events stay paired per call.

If `before_input` rejects, no message is appended and no lifecycle events are emitted.

## Tool loop

M2 tools use `ToolRegistry` and `ToolExecutor` with deterministic sequential execution. The included fake echo tool is for offline tests only. Real read/write/edit/bash tools, schemas, approval, preview, timeouts, and workspace boundaries belong to M3.

`provider.tool_call_end.arguments_json` is canonical. Tool-call deltas are optional diagnostics/fallback input and must not be appended again after the final full arguments.

## Abort

Abort is cooperative. Runtime checks the abort flag before a run, before provider requests, between provider events in the bridge, and before each tool call. M2 does not preempt blocking model clients or blocking tool executors unless those implementations cooperate.
