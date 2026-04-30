# Agent Events

M2 exposes provider-independent `AgentEvent` values through `AgentEventSink`.

## Ownership

Agent event payload slices are callback-scoped. A sink that retains events must clone payloads. `core.agent.testing.AgentEventCollector` clones event strings for tests.

## Event groups

- Lifecycle: `agent_start`, `agent_end`, `turn_start`, `turn_end`
- Assistant stream: `message_start`, `message_delta`, `message_end`
- Tool execution: `tool_execution_start`, `tool_execution_delta`, `tool_execution_end`
- Control/errors: `retry`, `abort`, `error_event`

M2 defines `retry` for schema stability but does not implement retry policy.

## Provider mapping

Provider parsers remain below the runtime. Runtime consumes only M1 `provider.ProviderEvent` values:

```text
provider.message_start   -> agent.message_start
provider.text_delta      -> agent.message_delta(text_delta)
provider.thinking_delta  -> accumulated assistant ThinkingBlock content
provider.message_delta   -> agent.message_delta(stop_reason) when present
provider.message_end     -> agent.message_end
provider.tool_call_*     -> pending tool-call accumulation
provider.usage           -> stream usage accumulation
provider.error_event     -> agent.error_event
provider.done            -> diagnostic saw_done flag
```

Provider-specific SSE/JSON names are not exposed through agent events.

## Ordering

No-tool turn:

```text
agent_start
turn_start
message_start
message_delta*
message_end
turn_end(completed)
agent_end(completed)
```

One tool-call turn:

```text
agent_start
turn_start
message_start
message_delta*
message_end
tool_execution_start
tool_execution_end
message_start
message_delta*
message_end
turn_end(completed)
agent_end(completed)
```

Failure and abort paths emit `turn_end(status)` and `agent_end(status)` after a turn has started, unless the event sink itself rejects events.
