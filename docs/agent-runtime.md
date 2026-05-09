# Agent Runtime

M2 adds `core.agent`, a reusable runtime layer above the M1 provider event model.

## Scope

M2 implements the core loop only:

```text
append user input -> stream provider events -> append assistant message -> execute fake/test tools -> append tool results -> continue until final assistant text or a graceful stop decision
```

It does not implement real coding tools, session persistence, product CLI modes, TUI rendering, config loading, or live provider transport.

## State

`AgentState` owns conversation history as `provider.OwnedMessage` values. Provider requests are built with temporary borrowed `MessageViewBatch` values. A batch owns only the view slices; message payload strings remain owned by `AgentState`.

`StreamAccumulator` owns in-progress text, thinking text/signature bytes, completed pending tool calls, usage, and a diagnostic `saw_done` flag for one provider iteration.

## Lifecycle

Each `AgentRuntime.runUserText()` call is one bounded agent run. After `before_input` succeeds, it emits `agent_start`, then one or more provider/tool turns. A tool-call response that continues to another provider request closes the current turn and opens the next one:

```text
agent_start
turn_start
...
turn_end(status)
turn_start
...
turn_end(status)
agent_end(status)
```

The same `AgentState` may be reused across multiple calls; prior messages remain conversation history while lifecycle events stay bounded by each call.

If `before_input` rejects, no message is appended and no lifecycle events are emitted.

## Tool loop

M2 tools use `ToolRegistry` and `ToolExecutor` with deterministic sequential execution. The included fake echo tool is for offline tests only. Real read/write/edit/bash tools, schemas, approval, preview, timeouts, and workspace boundaries belong to M3.

`provider.tool_call_end.arguments_json` is canonical. Tool-call deltas are optional diagnostics/fallback input and must not be appended again after the final full arguments.

After a provider response and its tool batch complete, the runtime emits `turn_end`, then either continues with another `turn_start` and provider request or stops gracefully. A tool can request this by returning `ToolExecutionResult.terminate = true`; all tool results in the batch must terminate for the batch to stop. Host code can also install `MiddlewareHooks.should_stop_after_turn`, which receives the current state plus assistant/tool-result indexes after the tool results have been appended.

## Abort

Abort is cooperative. Runtime checks the abort flag before a run, before provider requests, between provider events in the bridge, and before each tool call. M2 does not preempt blocking model clients or blocking tool executors unless those implementations cooperate.
