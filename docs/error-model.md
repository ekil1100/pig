# Pig Error Model

M0 defines shared error categories before adding behavior-heavy subsystems.

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

## Exit Codes

- `0`: success.
- `1`: environment, path, or runtime failure.
- `2`: CLI usage or argument error.
- `70`: internal bug. M0 reserves this code for later use.

## User-Fixable Errors

Config, auth, path, tool permission, and resource errors should be presented with direct remediation text. Provider and stream parse errors may be user-fixable if caused by model/provider configuration.

## Events and Retry

From M1 onward, provider, tool, session, RPC, and plugin errors should be representable as structured events. Network/provider failures may be retryable. CLI usage errors, invalid configs, malformed tool calls, and internal invariant failures are not automatically retryable.
