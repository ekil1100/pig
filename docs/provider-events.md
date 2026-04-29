# Provider Events

M1 defines provider-agnostic events in `src/provider/events.zig`. Provider parsers map provider-specific stream chunks into this schema before M2 consumes them.

## Ownership

`ProviderEvent` payload slices are callback-scoped. They are valid only during `EventSink.emit()` / `on_event`. A sink that needs to retain events must clone payloads. Test code uses `provider.testing.EventCollector` for that purpose.

## Sink Contract

```zig
pub const EventSinkError = error{ OutOfMemory, SinkRejectedEvent };

pub const EventSink = struct {
    ptr: *anyopaque,
    on_event: *const fn (*anyopaque, ProviderEvent) EventSinkError!void,
};
```

Parser functions return `(ProviderParseError || EventSinkError)!void`.

## Event Ordering

Successful text stream:

```text
message_start
text_delta*
usage?
message_delta?
message_end
done
```

Successful tool stream:

```text
message_start
tool_call_start
tool_call_delta*
tool_call_end
usage?
message_delta?
message_end
done
```

`done` is emitted at most once and only for successful stream completion. API errors, SSE error events, and malformed streams emit `error_event` and do not emit `done`.

## Provider Mapping

OpenAI-compatible:

- assistant role/content/tool delta starts the message if needed
- `delta.content` -> `text_delta`
- streamed `tool_calls[].function.arguments` -> tool-call delta/end assembly
- `finish_reason` -> `message_delta` and `message_end`
- `[DONE]` -> `done`

Anthropic:

- `message_start` -> `message_start`
- text deltas -> `text_delta`
- `tool_use` content block -> tool-call start/delta/end by content block index
- `message_delta.usage` -> `usage`
- `message_stop` -> `message_end` + `done`
