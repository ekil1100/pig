# Pig Error Model

Pig uses stable error categories so CLI output, provider events, and future session logs can stay structured.

## Categories

- `ConfigError`: invalid or unreadable configuration.
- `AuthError`: missing or invalid credentials.
- `ProviderError`: provider transport or API failures.
- `StreamParseError`: malformed streaming chunks or incomplete stream events.
- `ToolError`: tool schema, execution, or permission failures.
- `SessionError`: session read/write/recovery failures.
- `ResourceError`: AGENTS, skills, prompts, themes, or package discovery failures.
- `TerminalError`: terminal capability, raw-mode, or rendering failures.
- `RpcError`: JSONL RPC protocol failures.
- `PluginError`: external plugin host or protocol failures.
- `InternalError`: invariant violations and bugs.

M1 provider code also exposes provider-local categories in `ProviderErrorKind`: `auth`, `provider`, `stream_parse`, `transport`, `rate_limit`, and `internal`.

M2 agent runtime exposes `AgentRunError`: `ProviderFailed`, `ProviderStreamParseFailed`, `ToolNotFound`, `ToolFailed`, `MiddlewareRejected`, `MaxIterationsExceeded`, `Aborted`, `SinkRejectedEvent`, and `OutOfMemory`.

## Exit Codes

- `0`: success.
- `1`: environment, path, provider, or runtime failure.
- `2`: CLI usage or argument error.
- `70`: internal bug. Reserved for later use.

## Provider Error Semantics

Provider parsers distinguish:

1. Local allocation/I/O failure: returned as a Zig error.
2. Provider/API error response: emitted as `ProviderEvent.error_event`; no `done`.
3. Fatal malformed stream: emitted as `ProviderEvent.error_event`, then returns `StreamParseError`; no `done`.

`done` means successful provider stream completion only. M2 records provider `done` as a diagnostic flag but does not require it after `ModelClient.streamTurn()` returns success; provider parsers remain responsible for transport-specific completeness checks.

## Agent Runtime Error Semantics

After `agent_start` and `turn_start`, runtime failures emit `error_event` when appropriate, then `turn_end(failed)` and `agent_end(failed)`. Abort emits `abort`, then `turn_end(aborted)` and `agent_end(aborted)` after a turn has started.

If `before_input` rejects, no run has started: no user message and no lifecycle events are emitted.

If a provider already emitted `provider.error_event`, runtime maps it to one `AgentEvent.error_event` and does not synthesize a duplicate generic provider error for the same failure.

Tool execution is sequential. Missing tools, executor failures, and max-iteration protection fail the turn. Middleware rejection after a tool result still deinitializes the owned tool result.

## User-Fixable Errors

Config, auth, path, and resource errors should include remediation text. Provider auth errors should name the missing environment variable without echoing secrets. Stream parse errors are usually not user-fixable unless caused by an incompatible custom provider endpoint.

## Retry

Network/provider failures and rate limits may be retryable. Auth errors, malformed streams, invalid configs, malformed tool-call JSON, and internal invariant failures are not automatically retryable.
