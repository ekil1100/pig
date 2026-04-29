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

`done` means successful provider stream completion only.

## User-Fixable Errors

Config, auth, path, and resource errors should include remediation text. Provider auth errors should name the missing environment variable without echoing secrets. Stream parse errors are usually not user-fixable unless caused by an incompatible custom provider endpoint.

## Retry

Network/provider failures and rate limits may be retryable. Auth errors, malformed streams, invalid configs, malformed tool-call JSON, and internal invariant failures are not automatically retryable.
