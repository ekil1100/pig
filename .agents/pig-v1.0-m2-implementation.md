# Pig v1.0 M2 Implementation Plan：Agent Runtime（`pi-agent-core`）

> 本文是 `.agents/pig-v1.0-roadmap.md` 中 M2 的执行计划。
>
> M2 的目标是在 M1 provider layer 之上实现可复用的 agent runtime：统一状态、turn loop、provider-event consumption、tool-call loop、agent event bus、middleware hooks，以及用于离线测试的 fake provider/fake tool harness。
>
> M2 仍然不是完整 coding-agent 产品模式。它不实现真实文件/命令工具、不实现 session persistence、不实现 TUI、不实现 JSON/RPC 产品协议；这些分别属于 M3/M4/M5/M6。M2 只提供后续 print、interactive、JSON、RPC、SDK 都能复用的核心 loop。

## 1. M2 目标

M2 要解决的问题：

1. 建立 `core` 下的 Agent runtime 模块边界，保持不依赖 `app`、`tui`、`session`。
2. 定义 `AgentState`：system prompt、model/provider client、thinking level、messages、pending tool calls、streaming assistant accumulator、error/abort state。
3. 定义 `ModelClient` 抽象：agent runtime 只消费 M1 的 `provider.ProviderEvent`，不解析 provider-specific SSE/JSON。
4. 定义 `ToolRegistry` / `ToolExecutor` 抽象：M2 用 fake tools 跑通 tool-call loop；真实 coding tools 留到 M3。
5. 实现标准 turn loop：append user input → stream assistant → detect tool calls → execute tools sequentially → append tool results → continue until final text。
6. 建立 `AgentEvent` 和 event bus：agent/turn/message/tool/error/abort/retry 状态变化都通过 sink 发出。
7. 实现 middleware hooks 的最小框架：before input、before provider request、before tool call、after tool result；compaction/tree hooks 仅保留类型空间。
8. 建立 offline fixture/fake tests，证明 no-tool prompt 和 tool-call continuation 都能跑通。
9. 更新 build steps、docs、README，使 M2 验收命令保持默认离线。

M2 不做：

- 不实现 `read` / `write` / `edit` / `bash` 等真实 coding tools；M3 负责。
- 不实现 tool schema validation、approval UI、preview、bash timeout、file boundary；M3 负责。
- 不实现 durable session JSONL；M4 负责。
- 不实现 product CLI modes：`--print`、`--json`、RPC stdin/stdout、interactive prompt loop；M5 负责。
- 不实现 terminal rendering/editor；M6 负责。
- 不实现 config hierarchy/resource loading/model registry；M7 负责。
- 不实现 compaction/tree navigation；M4/M8 负责。
- 不接入 live provider by default；M2 tests must stay offline。

Roadmap note: M2 acceptance says “Print mode can complete a no-tool prompt.” For M2, interpret this as: core `AgentRuntime` can complete a no-tool prompt through a scripted model client, verified by runtime tests and the offline `agent-fixtures` harness. The user-facing product CLI flag `pig --print` remains M5 so M2 does not prematurely design CLI modes, JSON output, session selection, or real provider configuration.

## 2. 当前基础

M0 和 M1 已提交：

```text
3772d3a feat: add zig m0 foundation
58d1247 docs: add m1 provider implementation plan
0c22936 feat: add m1 provider layer
```

M1 已提供 M2 可消费的 provider API：

```zig
provider.MessageView
provider.OwnedMessage
provider.ContentBlockView
provider.OwnedContentBlock
provider.ProviderEvent
provider.ProviderEventTag
provider.EventSink
provider.EventSinkError
provider.openai_compatible.parseStream / parseBytes
provider.anthropic.parseStream / parseBytes
provider.transport.ResponseStream
```

M2 必须把 provider 当成下层依赖：

```text
core -> provider
provider -/-> core
core -/-> app/tui/session
```

## 3. 建议目录结构

M2 后建议的 core 目录：

```text
src/core/
├── mod.zig
├── errors.zig
├── ids.zig
└── agent/
    ├── mod.zig
    ├── state.zig
    ├── events.zig
    ├── model_client.zig
    ├── tool.zig
    ├── middleware.zig
    ├── runtime.zig
    └── testing.zig
```

测试和 fixtures：

```text
test/
├── agent_state.zig
├── agent_events.zig
├── agent_runtime_text.zig
├── agent_runtime_tools.zig
└── agent_middleware.zig

fixtures/agent/
├── README.md
├── no-tool-turn.jsonl
└── tool-call-turn.jsonl

docs/
├── agent-runtime.md
└── agent-events.md
```

如果实现时某个文件非常小，可以合并到 `src/core/agent/mod.zig`；但 `events.zig`、`runtime.zig`、`tool.zig`、`model_client.zig` 建议独立，避免 core runtime 变成单文件大杂烩。

## 4. M2 API 合约

### 4.1 Event ownership

M2 沿用 M1 的 callback-scoped event view：

```text
Agent runtime owns temporary buffers while emitting AgentEvent.
AgentEvent string slices are valid only during AgentEventSink.emit().
If a sink needs to retain events, it must duplicate payloads.
Testing collector clones events into owned memory.
```

原因：message streaming 和 tool progress 是 hot path，不应每个 delta 都强制分配 owned event。后续 M4 session writer 如需持久化，应在 session 层 clone。

### 4.2 AgentEventSink shape

`src/core/agent/events.zig` 使用 concrete vtable：

```zig
pub const AgentEventSinkError = error{
    OutOfMemory,
    SinkRejectedEvent,
};

pub const AgentEventSink = struct {
    ptr: *anyopaque,
    on_event: *const fn (ptr: *anyopaque, event: AgentEvent) AgentEventSinkError!void,

    pub fn emit(self: AgentEventSink, event: AgentEvent) AgentEventSinkError!void {
        return self.on_event(self.ptr, event);
    }
};
```

Provider sink error 要映射到 agent runtime error，不要让 provider callback 直接依赖 app/session/TUI。

### 4.3 Agent errors

新增 agent runtime error set：

```zig
pub const AgentRunError = error{
    OutOfMemory,
    ProviderFailed,
    ProviderStreamParseFailed,
    ToolNotFound,
    ToolFailed,
    MiddlewareRejected,
    MaxIterationsExceeded,
    Aborted,
    SinkRejectedEvent,
};
```

错误语义：

1. Provider malformed stream：emit `AgentEvent.error_event` 后返回 `ProviderStreamParseFailed`。
2. Provider API error event：emit mapped `AgentEvent.error_event`，按 fatal provider failure 结束 turn。如果当前 provider iteration 已经观察并映射过 `provider.error_event`，runtime 不要再为同一次 `ModelClient` failure 合成第二个 generic provider error。
3. Missing tool：emit `tool_execution_end` with error result or `error_event`，append tool error result if safe, then continue only if configured; M2 default should return `ToolNotFound` after emitting error。
4. Tool executor returns error：emit tool end/error and append error tool result only if executor produced a result; otherwise return `ToolFailed`。
5. Abort requested：emit `abort` and return `Aborted` without further provider/tool calls。M2 abort is cooperative, not preemptive: runtime checks it at phase boundaries and inside the provider event bridge, but it cannot interrupt a blocking model client or blocking tool executor unless that implementation cooperates。
6. Infinite tool loop protection：after `max_iterations`, emit error and return `MaxIterationsExceeded`。

### 4.3.1 Failure finalization rule

`AgentRuntime.runUserText()` represents one bounded agent run for one user turn. It always emits `agent_start` after `before_input` succeeds, even when the same `AgentState` already contains prior conversation history. This keeps lifecycle events paired for repeated calls on the same state. After `agent_start` and `turn_start` have both been emitted, every terminal path must emit exactly one `turn_end(status)` and exactly one `agent_end(status)`, unless emitting to the event sink itself fails.

Status mapping:

```text
provider failure              -> failed
provider stream parse failure -> failed
missing tool                  -> failed
tool executor failure         -> failed
middleware rejection after turn_start -> failed
max iterations exceeded       -> failed
abort requested               -> aborted
```

Special cases:

- If `before_input` rejects, no user message is appended and no `agent_start`, `turn_start`, `turn_end`, or `agent_end` is emitted. Runtime returns `MiddlewareRejected`; M2 does not emit an `error_event` for this pre-run rejection because no agent run has started yet.
- If `before_provider_request`, `before_tool_call`, or `after_tool_result` rejects after `turn_start`, emit `error_event`, then `turn_end(failed)`, then `agent_end(failed)`.
- If event sink emission fails, runtime returns `SinkRejectedEvent`; no further lifecycle events are guaranteed because the sink is unavailable.
- Failure finalization should be centralized in a small helper in `runtime.zig` so success, failure, and abort paths cannot drift.

### 4.4 Message ownership

`AgentState` owns conversation history as `provider.OwnedMessage` values:

```text
AgentState.messages: ArrayList(provider.OwnedMessage)
AgentState.deinit() frees all owned messages.
```

For provider request calls, runtime builds temporary borrowed `provider.MessageView` values pointing into owned state. Because `provider.MessageView.content` is a `[]ContentBlockView`, runtime must also allocate per-message borrowed content view slices; it is not enough to allocate only the outer message slice. Do not store borrowed views after the provider call returns.

Suggested helper shape:

```zig
pub const MessageViewBatch = struct {
    messages: []provider.MessageView,
    content_views: [][]provider.ContentBlockView,

    pub fn deinit(self: *MessageViewBatch, allocator: std.mem.Allocator) void { ... }
};

pub fn messageViews(self: *AgentState, allocator: std.mem.Allocator) !MessageViewBatch;
```

Caller owns the `MessageViewBatch` allocations and must call `deinit`; message/content payload strings remain owned by `AgentState`.

### 4.5 Tool-call boundaries

M2 consumes `provider.tool_call_*` events and builds pending tool calls.

M2 does:

- Detect provider tool-call end events.
- Append assistant message containing tool-call content blocks.
- Look up tool by name in M2 `ToolRegistry`.
- Execute fake/test tool sequentially.
- Append tool result message containing `provider.ToolResultBlock`.
- Continue provider loop with updated messages.

M2 does not:

- Validate arguments against JSON schema.
- Execute real filesystem/shell tools.
- Ask for approval.
- Preview file edits.
- Run tools in parallel.

`appendAssistantFromStream()` ownership rule: it clones accumulated text, thinking blocks, and completed tool calls into an owned assistant message, but it must not clear `state.stream`. The runtime reads `state.stream.tool_calls` after appending the assistant message in order to execute tools. The stream accumulator is cleared only at the beginning of the next provider iteration.

Thinking rule: M2 keeps `ThinkingLevel` in the request contract and supports `provider.thinking_delta` by accumulating both thinking text and `signature_delta` bytes into assistant `provider.ThinkingBlock` content. If no signature bytes were observed, the resulting `ThinkingBlock.signature` is `null`. Tests should cover at least one thinking-delta path so thinking content is not silently dropped.

Tool-call argument rule: `provider.tool_call_end.arguments_json` is canonical in M2. `provider.tool_call_delta.arguments_json_delta` may be accumulated for diagnostics or future fallback, but runtime must not concatenate deltas and then also append the final full `arguments_json` as if it were another delta.

### 4.6 Iteration model

A single user turn may require multiple provider requests:

```text
iteration 1: user -> assistant tool_call
execute tool(s)
iteration 2: messages + tool_result -> assistant final text
```

M2 default:

```text
max_iterations = 8
sequential tool execution only
predictable event order
```

If assistant returns no tool calls, turn ends immediately.

Provider `done` rule: M2 scripted fixtures should include `provider.done`, and the bridge records whether it was seen for tests/diagnostics. Runtime does not require `done` if `ModelClient.streamTurn()` returns success; transport/parser-specific stream completeness remains the provider layer's responsibility.

## 5. Agent state model

`src/core/agent/state.zig` should define:

```zig
pub const ThinkingLevel = enum {
    off,
    low,
    medium,
    high,
    xhigh,
    max,
};

pub const AgentStatus = enum {
    idle,
    running,
    awaiting_provider,
    executing_tools,
    completed,
    failed,
    aborted,
};

pub const AgentConfig = struct {
    system_prompt: ?[]const u8 = null,
    thinking_level: ThinkingLevel = .off,
    max_iterations: u32 = 8,
};

pub const PendingToolCall = struct {
    index: u32,
    id: []const u8,
    name: []const u8,
    arguments_json: []const u8,

    pub fn deinit(self: PendingToolCall, allocator: std.mem.Allocator) void { ... }
};

pub const StreamAccumulator = struct {
    text: std.ArrayList(u8),
    thinking: std.ArrayList(u8),
    thinking_signature: std.ArrayList(u8),
    tool_calls: std.ArrayList(PendingToolCall),
    saw_done: bool = false,
    usage: provider.Usage,

    pub fn resetRetainingCapacity(self: *StreamAccumulator, allocator: std.mem.Allocator) void { ... }
    pub fn deinit(self: *StreamAccumulator, allocator: std.mem.Allocator) void { ... }
};

pub const MessageViewBatch = struct {
    messages: []provider.MessageView,
    content_views: [][]provider.ContentBlockView,

    pub fn deinit(self: *MessageViewBatch, allocator: std.mem.Allocator) void { ... }
};

pub const AgentState = struct {
    allocator: std.mem.Allocator,
    config: AgentConfig,
    status: AgentStatus = .idle,
    messages: std.ArrayList(provider.OwnedMessage) = .empty,
    stream: StreamAccumulator,
    last_error: ?AgentErrorInfo = null,

    pub fn init(allocator: std.mem.Allocator, config: AgentConfig) AgentState { ... }
    pub fn deinit(self: *AgentState) void { ... }
    pub fn appendUserText(self: *AgentState, text: []const u8) !void { ... }
    pub fn appendAssistantFromStream(self: *AgentState) !void { ... }
    pub fn appendToolResult(self: *AgentState, result: ToolExecutionResult) !void { ... }
    pub fn messageViews(self: *AgentState, allocator: std.mem.Allocator) !MessageViewBatch { ... }
};
```

Important implementation detail: `messageViews()` returns a `MessageViewBatch`. Caller owns the batch allocations and must call `deinit`; message/content payload strings remain owned by `AgentState`.

## 6. Agent event model

`src/core/agent/events.zig` should define a provider-independent event model for app/session/TUI/RPC consumers.

Suggested event tags:

```zig
pub const AgentEventTag = enum {
    agent_start,
    agent_end,
    turn_start,
    turn_end,
    message_start,
    message_delta,
    message_end,
    tool_execution_start,
    tool_execution_delta,
    tool_execution_end,
    retry,
    abort,
    error_event,
};
```

M2 defines the `retry` event shape for downstream schema stability, but it does not implement retry policy. Retry behavior can be added later without changing the event union.

Suggested payloads:

```zig
pub const AgentStart = struct { model_label: ?[]const u8 = null };
pub const AgentEnd = struct { status: state.AgentStatus };
pub const TurnStart = struct { user_text: []const u8 };
pub const TurnEnd = struct { status: state.AgentStatus };
pub const MessageStart = struct { role: provider.Role };
pub const MessageDelta = struct { text_delta: ?[]const u8 = null, stop_reason: ?[]const u8 = null };
pub const MessageEnd = struct { role: provider.Role };
pub const ToolExecutionStart = struct { id: []const u8, name: []const u8, arguments_json: []const u8 };
pub const ToolExecutionDelta = struct { id: []const u8, message: []const u8 };
pub const ToolExecutionEnd = struct { id: []const u8, name: []const u8, is_error: bool, content_json: []const u8 };
pub const Retry = struct { attempt: u32, reason: []const u8 };
pub const Abort = struct { reason: ?[]const u8 = null };
pub const AgentErrorEvent = struct { category: AgentErrorCategory, message: []const u8, retryable: bool = false };
```

M2 should map provider events as follows:

```text
provider.message_start       -> agent.message_start(role=assistant)
provider.text_delta          -> agent.message_delta(text_delta=...)
provider.thinking_delta      -> accumulate assistant thinking content; no public event in M2
provider.message_delta       -> agent.message_delta(stop_reason=...)
provider.message_end         -> agent.message_end(role=assistant)
provider.tool_call_start     -> no public tool execution event yet; track pending call index/id/name
provider.tool_call_delta     -> optional diagnostic/fallback accumulation only
provider.tool_call_end       -> add PendingToolCall using canonical id/name/arguments_json
provider.usage               -> keep in accumulator; optional event can be deferred
provider.error_event         -> agent.error_event
provider.done                -> marks provider iteration complete
```

M2 should not expose provider-specific event names or raw SSE details.

## 7. Model client abstraction

`src/core/agent/model_client.zig` should define a minimal interface:

```zig
pub const ModelClientError = error{
    OutOfMemory,
    ProviderFailed,
    ProviderStreamParseFailed,
    SinkRejectedEvent,
};

pub const ModelRequest = struct {
    messages: []const provider.MessageView,
    system_prompt: ?[]const u8 = null,
    thinking_level: state.ThinkingLevel = .off,
};

pub const ModelClient = struct {
    ptr: *anyopaque,
    stream_turn: *const fn (ptr: *anyopaque, request: ModelRequest, sink: provider.EventSink) ModelClientError!void,

    pub fn streamTurn(self: ModelClient, request: ModelRequest, sink: provider.EventSink) ModelClientError!void {
        return self.stream_turn(self.ptr, request, sink);
    }
};
```

M2 testing client:

```zig
pub const ScriptedModelClient = struct {
    turns: []const []const provider.ProviderEvent,
    index: usize = 0,

    pub fn client(self: *ScriptedModelClient) ModelClient { ... }
};
```

Rules for `ScriptedModelClient`:

- Each provider request consumes one scripted turn.
- It emits each `ProviderEvent` to the supplied provider sink.
- If runtime asks for more turns than provided, return `ProviderFailed`.
- Test event payload strings are static literals or owned by the fixture for the duration of the test.
- If the scripted client records `ModelRequest` values for assertions, it must deep-copy the observed message/content payloads during `streamTurn`; borrowed `MessageView` slices must not be retained after `streamTurn` returns.

Optional fixture-backed variant can read `fixtures/agent/*.jsonl`, but M2 can start with static scripted events in tests and use JSONL fixtures for documentation/golden checks only.

## 8. Tool abstraction

`src/core/agent/tool.zig` should define fake-tool-ready interfaces, not real coding tools.

```zig
pub const ToolSpec = struct {
    name: []const u8,
    description: []const u8,
};
```

M2 intentionally does not define another tool risk enum. The repository already has `src/tools.ToolRisk` / `src/tools.ToolAccess`; M3 will map real coding tools and approval policy there. M2 fake tools only need name/description plus the executor contract.

```zig
pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments_json: []const u8,
};

pub const ToolExecutionResult = struct {
    // Owned by the result. Runtime appends/clones it into AgentState, then deinitializes the result.
    tool_call_id: []const u8,
    content_json: []const u8,
    is_error: bool = false,

    pub fn deinit(self: ToolExecutionResult, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_call_id);
        allocator.free(self.content_json);
    }
};

pub const ToolExecutorError = error{
    OutOfMemory,
    ToolFailed,
};

pub const ToolExecutionContext = struct {
    allocator: std.mem.Allocator,
    event_sink: events.AgentEventSink,
    abort_flag: ?*const bool = null,
};

pub const ToolExecutor = struct {
    ptr: *anyopaque,
    execute_fn: *const fn (ptr: *anyopaque, context: ToolExecutionContext, call: ToolCall) ToolExecutorError!ToolExecutionResult,

    pub fn execute(self: ToolExecutor, context: ToolExecutionContext, call: ToolCall) ToolExecutorError!ToolExecutionResult { ... }
};

pub const ToolRegistration = struct {
    spec: ToolSpec,
    executor: ToolExecutor,
};

pub const ToolRegistry = struct {
    registrations: []const ToolRegistration,

    pub fn find(self: ToolRegistry, name: []const u8) ?ToolRegistration { ... }
};
```

M2 fake tools:

```zig
pub const EchoTool = struct {
    pub fn registration(self: *EchoTool) ToolRegistration { ... }
};
```

`EchoTool` should return deterministic JSON, e.g.:

```json
{"echo":"..."}
```

Do not parse arbitrary JSON deeply unless needed for one test. If parsing is needed, use `std.json.Value` and keep errors deterministic.

## 9. Middleware hooks

`src/core/agent/middleware.zig` should define hook types without building a complex plugin system:

```zig
pub const MiddlewareError = error{ OutOfMemory, MiddlewareRejected };

pub const MiddlewareHooks = struct {
    ptr: ?*anyopaque = null,
    before_input: ?*const fn (ptr: ?*anyopaque, input: []const u8) MiddlewareError!void = null,
    before_provider_request: ?*const fn (ptr: ?*anyopaque, request: model_client.ModelRequest) MiddlewareError!void = null,
    before_tool_call: ?*const fn (ptr: ?*anyopaque, call: tool.ToolCall) MiddlewareError!void = null,
    after_tool_result: ?*const fn (ptr: ?*anyopaque, result: tool.ToolExecutionResult) MiddlewareError!void = null,

    // Reserved for later milestones; M2 runtime does not call these.
    before_compaction: ?*const fn (ptr: ?*anyopaque) MiddlewareError!void = null,
    before_tree_navigation: ?*const fn (ptr: ?*anyopaque) MiddlewareError!void = null,
};
```

M2 should support one hooks struct. Do not implement middleware chains/plugin loading yet. Middleware hook payloads are callback-scoped borrowed views; if a hook needs to retain input, request, call, or result payloads, it must clone them before returning.

## 10. Runtime algorithm

`src/core/agent/runtime.zig` should expose:

```zig
pub const AgentRuntime = struct {
    allocator: std.mem.Allocator,
    state: *state.AgentState,
    model: model_client.ModelClient,
    tools: tool.ToolRegistry = .{ .registrations = &.{} },
    hooks: middleware.MiddlewareHooks = .{},
    event_sink: events.AgentEventSink,
    abort_flag: ?*const bool = null,

    pub fn runUserText(self: *AgentRuntime, text: []const u8) AgentRunError!void { ... }
};
```

Algorithm:

```text
runUserText(text):
  if abort requested -> emit abort, return Aborted
  hooks.before_input(text)
  emit agent_start
  emit turn_start(text)
  state.appendUserText(text)

  iteration = 0
  while iteration < max_iterations:
    if abort requested -> emit abort, finalize aborted, return Aborted
    iteration += 1
    state.stream.resetRetainingCapacity()

    batch = state.messageViews()
    defer batch.deinit(allocator)
    request = ModelRequest{ messages = batch.messages, system_prompt = config.system_prompt, thinking_level = config.thinking_level }
    hooks.before_provider_request(request)

    bridge provider events into state.stream + AgentEventSink
    // The bridge checks abort between provider events and records whether provider.error_event/done were seen.
    model.streamTurn(request, provider_bridge_sink)

    state.appendAssistantFromStream()

    if state.stream.tool_calls is empty:
      state.status = completed
      emit turn_end(completed)
      emit agent_end(completed)
      return

    state.status = executing_tools
    for each pending tool call in index order:
      if abort requested -> emit abort, finalize aborted, return Aborted
      hooks.before_tool_call(call)
      registration = tools.find(call.name) orelse fail ToolNotFound
      emit tool_execution_start
      {
        result = registration.executor.execute(ToolExecutionContext{ allocator, event_sink, abort_flag }, call)
        defer result.deinit(allocator)
        emit tool_execution_end
        hooks.after_tool_result(result)
        state.appendToolResult(result)
      }

  emit error_event(MaxIterationsExceeded)
  state.status = failed
  emit turn_end(failed)
  emit agent_end(failed)
  return MaxIterationsExceeded
```

Event ordering guarantee for no-tool turn:

```text
agent_start
turn_start
message_start
message_delta*
message_end
turn_end(completed)
agent_end(completed)
```

Event ordering guarantee for one tool-call turn:

```text
agent_start
turn_start
message_start
message_delta*
message_end
/tool accumulation happens from provider events/
tool_execution_start
tool_execution_end
message_start
message_delta*
message_end
turn_end(completed)
agent_end(completed)
```

M2 may emit `message_delta(stop_reason=...)` before `message_end` if provider emitted a stop reason.

## 11. Build system updates

Update `build.zig`:

- Add agent tests to `zig build test`.
- Add `zig build agent-fixtures` step for offline agent runtime fixture/golden tests.
- Keep `zig build smoke` as M0 CLI smoke; do not require agent runtime from CLI yet.
- Keep `zig build provider-fixtures` and `zig build provider-live` unchanged.
- Keep `zig build fmt-check` covering `build.zig`, `build.zig.zon`, `src`, `test`.

Suggested new step:

```bash
zig build agent-fixtures
```

Concrete M2 behavior:

- `zig build agent-fixtures` runs a dedicated `test/agent_fixtures.zig` test file.
- `test/agent_fixtures.zig` reads `fixtures/agent/no-tool-turn.jsonl` and `fixtures/agent/tool-call-turn.jsonl`.
- It validates that every non-empty line is valid JSON and has at least `kind` and `event` fields.
- It validates only documented fixture shape in M2; a full JSONL-to-runtime replay engine is optional and should be added only if it stays small.
- It must be offline and use no real provider/auth/tool data.

## 12. Testing plan

All default tests must be offline and deterministic.

### 12.1 `test/agent_state.zig`

Test cases:

- `AgentState.init` starts idle with empty messages.
- `appendUserText` appends owned user message.
- `appendAssistantFromStream` turns accumulated text into assistant message.
- `appendAssistantFromStream` includes accumulated thinking text/signature bytes as an assistant `thinking` content block.
- `appendAssistantFromStream` includes completed tool calls as assistant tool-call content blocks.
- `appendToolResult` appends tool role message with `tool_result` block.
- `messageViews` returns a `MessageViewBatch` with borrowed views that reflect owned state, including multiple messages and multiple content blocks per message.
- `MessageViewBatch.deinit` frees outer message/content view allocations without freeing state-owned payload strings.
- `AgentState.deinit` has no leaks under `std.testing.allocator`.
- Allocation failure cleanup with `std.testing.checkAllAllocationFailures` for user/assistant/thinking/tool result append paths.

### 12.2 `test/agent_events.zig`

Test cases:

- Agent event collector clones callback-scoped payloads.
- Event collector deinit frees all retained strings.
- Provider text events map to message start/delta/end.
- Provider thinking events accumulate into assistant thinking content according to the M2 thinking rule.
- Provider error event maps to agent error event without provider-specific raw JSON.
- Provider error event plus `ModelClient` failure does not duplicate the same generic agent error.
- Sink rejection stops runtime with `SinkRejectedEvent`.

### 12.3 `test/agent_runtime_text.zig`

Use `ScriptedModelClient` with one provider turn:

```text
message_start(role=assistant)
text_delta("hello")
text_delta(" world")
message_delta(stop_reason="stop")
message_end
done
```

Assert:

- `runUserText("hi")` succeeds.
- Final state has two messages: user + assistant.
- Assistant text is `hello world`.
- Event order matches no-tool turn guarantee.
- Model client saw the user message in request views.
- Reusing the same `AgentState` for a second `runUserText()` emits a fresh paired `agent_start`/`agent_end`, preserves prior messages, and sends prior assistant history in the second model request.

### 12.4 `test/agent_runtime_tools.zig`

Use `ScriptedModelClient` with two provider turns:

Turn 1:

```text
message_start(role=assistant)
tool_call_start(index=0, id="call_1", name="echo")
tool_call_delta(index=0, arguments_json_delta="{\"text\":\"ping\"}")
tool_call_end(index=0, id="call_1", name="echo", arguments_json="{\"text\":\"ping\"}")
message_delta(stop_reason="tool_calls")
message_end
done
```

Turn 2:

```text
message_start(role=assistant)
text_delta("pong")
message_delta(stop_reason="stop")
message_end
done
```

Fake `echo` tool returns:

```json
{"text":"ping"}
```

Assert:

- Runtime makes two model requests.
- State messages are: user, assistant tool-call, tool result, assistant final text.
- Tool executes once.
- `tool_execution_start` occurs before `tool_execution_end`.
- Second model request includes the tool result message.
- Event order is deterministic.

Error tests:

- Missing tool returns `ToolNotFound` and emits `error_event`, `turn_end(failed)`, and `agent_end(failed)`.
- Tool executor failure returns `ToolFailed` and emits tool/error events, `turn_end(failed)`, and `agent_end(failed)`.
- `after_tool_result` middleware rejection after a successful tool execution deinitializes the owned `ToolExecutionResult` and emits failed lifecycle closure.
- Infinite tool-call loop returns `MaxIterationsExceeded` after configured max and emits `turn_end(failed)` plus `agent_end(failed)`.
- Provider failure returns `ProviderFailed` and emits `error_event`, `turn_end(failed)`, and `agent_end(failed)`.
- Provider stream parse failure returns `ProviderStreamParseFailed` and emits `error_event`, `turn_end(failed)`, and `agent_end(failed)`.

### 12.5 `test/agent_middleware.zig`

Test cases:

- Hooks are called in order:

```text
before_input
before_provider_request
before_tool_call
after_tool_result
before_provider_request
```

- `before_input` rejection prevents user message append and emits no lifecycle events because no agent run has started yet.
- `before_provider_request` rejection prevents provider call and emits failure lifecycle closure if `turn_start` was emitted.
- `before_tool_call` rejection prevents tool execution and emits failure lifecycle closure.
- Abort before or during a turn emits `abort`, `turn_end(aborted)` if the turn started, and `agent_end(aborted)` if the agent started.
- Abort tests cover cooperative boundaries: before provider request, inside provider event bridge between events, and before each tool call. They do not require preempting a blocking model/tool implementation.
- Reserved compaction/tree hooks are not called in M2.

### 12.6 `test/agent_fixtures.zig`

Test cases:

- `fixtures/agent/no-tool-turn.jsonl` exists and every non-empty line is valid JSON.
- `fixtures/agent/tool-call-turn.jsonl` exists and every non-empty line is valid JSON.
- Each fixture row has a string `kind` field.
- Provider event fixture rows have a string `event` field.
- Fixture validation does not execute tools, call providers, read auth files, or access the network.

### 12.7 Regression tests

M2 must not break M0/M1 commands:

```bash
zig build run -- --version
zig build run -- --help
zig build run -- doctor
zig build run -- paths
zig build smoke
zig build provider-fixtures
zig build provider-live
```

## 13. Fixtures

Add `fixtures/agent/README.md` documenting:

- Agent fixtures are offline.
- They contain fake provider/tool event scripts only.
- They must not contain API keys, real provider responses, private user prompts, or real filesystem paths.
- Tool result payloads should be small deterministic JSON.

Suggested JSONL fixture shape for later golden tests:

```jsonl
{"kind":"provider_event","event":"message_start","role":"assistant"}
{"kind":"provider_event","event":"text_delta","text":"hello"}
{"kind":"provider_event","event":"message_end"}
{"kind":"provider_event","event":"done"}
```

M2 implementation may keep static Zig scripted events as primary tests; JSONL fixtures can be documentation/golden seed for M5/M11.

## 14. Documentation deliverables

Create:

```text
docs/agent-runtime.md
docs/agent-events.md
fixtures/agent/README.md
```

Update:

```text
README.md
docs/architecture.md
docs/error-model.md
docs/allocator-policy.md
docs/fixtures.md
```

Content requirements:

- `docs/agent-runtime.md`：state model、turn loop、tool loop, lifecycle pairing per `runUserText`, cooperative abort boundaries, scope boundaries, M2 fake tool limitation。
- `docs/agent-events.md`：AgentEvent schema、ordering guarantees、provider event mapping including thinking accumulation, callback-scoped ownership。
- `docs/error-model.md`：agent runtime errors、provider/tool/middleware/abort/max-iteration behavior, including provider-error deduplication。
- `docs/allocator-policy.md`：AgentState owns messages; `MessageViewBatch` owns temporary view allocations; event payloads callback-scoped; test collectors clone。
- `docs/fixtures.md`：agent fixture rules。
- `README.md`：mention M2 adds core runtime and offline `agent-fixtures` step; product CLI modes still later。

## 15. Recommended task split

### Task 0：Tighten runtime contracts before implementation

**Files:**

- Modify: `.agents/pig-v1.0-m2-implementation.md` if further clarifications are needed
- No production source changes required

Steps:

- [ ] Confirm `messageViews()` returns `MessageViewBatch`, not only `[]provider.MessageView`.
- [ ] Confirm `runUserText()` lifecycle semantics: each call emits a paired `agent_start`/`agent_end` while preserving conversation history in `AgentState`.
- [ ] Confirm M2 does not define a duplicate tool risk enum; M3 will integrate with `src/tools.ToolRisk` / `src/tools.ToolAccess`.
- [ ] Confirm M2 supports `provider.thinking_delta` by accumulating assistant thinking content.
- [ ] Confirm abort is cooperative and only guaranteed at runtime/provider-event/tool boundaries.
- [ ] Confirm `tool_call_end.arguments_json` is canonical and `provider.done` is diagnostic, not required for runtime success.

### Task 1：Agent state and message ownership

**Files:**

- Create: `src/core/agent/mod.zig`
- Create: `src/core/agent/state.zig`
- Modify: `src/core/mod.zig`
- Create: `test/agent_state.zig`
- Modify: `build.zig`

Steps:

- [ ] Add failing tests for `AgentState.init/deinit`, `appendUserText`, `appendAssistantFromStream`, `appendToolResult`, `messageViews`, and `MessageViewBatch.deinit`.
- [ ] Run `zig build test`; expected failure because `core.agent` does not exist.
- [ ] Implement minimal `AgentState`, `ThinkingLevel`, `AgentStatus`, `StreamAccumulator`, `PendingToolCall`, and `MessageViewBatch`.
- [ ] Implement owned message append helpers using `provider.OwnedMessage.cloneFromView` or equivalent owned construction.
- [ ] Add allocation-failure tests for append paths and `messageViews()` with `std.testing.checkAllAllocationFailures`.
- [ ] Run `zig build test` and `zig build fmt-check`.
- [ ] Commit: `feat: add agent state model`.

### Task 2：Agent event bus and test collector

**Files:**

- Create: `src/core/agent/events.zig`
- Create: `src/core/agent/testing.zig`
- Create: `test/agent_events.zig`
- Modify: `src/core/agent/mod.zig`

Steps:

- [ ] Add failing tests for `AgentEventSink`, event collector clone/deinit, and sink rejection.
- [ ] Run `zig build test`; expected missing event APIs.
- [ ] Implement `AgentEventTag`, payload structs, `AgentEvent`, `AgentEventSink`.
- [ ] Implement testing collector with owned cloned payloads and `deinit`.
- [ ] Add provider-to-agent mapping helper tests for text/error events if mapping helper is introduced here.
- [ ] Run `zig build test` and `zig build fmt-check`.
- [ ] Commit: `feat: add agent event bus`.

### Task 3：Model client and scripted provider harness

**Files:**

- Create: `src/core/agent/model_client.zig`
- Modify: `src/core/agent/testing.zig`
- Create or update: `test/agent_runtime_text.zig`
- Modify: `build.zig`

Steps:

- [ ] Add failing test proving `ScriptedModelClient` emits one scripted provider turn into a provider sink.
- [ ] Add failing test proving runtime-facing request views are captured by the scripted model.
- [ ] Run `zig build test`; expected missing model client APIs.
- [ ] Implement `ModelRequest`, `ModelClient`, `ScriptedModelClient`.
- [ ] Ensure scripted client returns a deterministic error when requests exceed provided turns.
- [ ] Run `zig build test` and `zig build fmt-check`.
- [ ] Commit: `feat: add scripted model client`.

### Task 4：Tool abstraction, middleware stub, and fake tool registry

**Files:**

- Create: `src/core/agent/tool.zig`
- Create: `src/core/agent/middleware.zig`
- Modify: `src/core/agent/testing.zig`
- Create or update: `test/agent_runtime_tools.zig`
- Modify: `src/core/agent/mod.zig`

Steps:

- [ ] Add failing tests for `ToolRegistry.find`, fake `EchoTool`, deterministic result ownership, and default no-op `MiddlewareHooks` construction.
- [ ] Run `zig build test`; expected missing tool/middleware APIs.
- [ ] Implement `ToolSpec`, `ToolCall`, `ToolExecutionResult`, `ToolExecutionContext`, `ToolExecutor`, `ToolRegistration`, `ToolRegistry`.
- [ ] Implement minimal `MiddlewareError` and `MiddlewareHooks` with nullable hooks and no runtime behavior yet, so `runtime.zig` can depend on the type in Task 5.
- [ ] Implement fake `EchoTool` in testing module.
- [ ] Ensure `ToolExecutionResult` ownership is clear and deinitialized by caller/runtime.
- [ ] Run `zig build test` and `zig build fmt-check`.
- [ ] Commit: `feat: add agent tool and middleware contracts`.

### Task 5：Core runtime no-tool loop

**Files:**

- Create: `src/core/agent/runtime.zig`
- Update: `test/agent_runtime_text.zig`
- Modify: `src/core/agent/mod.zig`

Steps:

- [ ] Add failing no-tool runtime test with scripted provider text events.
- [ ] Assert final state contains user + assistant messages and event order is deterministic.
- [ ] Run `zig build test`; expected missing runtime.
- [ ] Implement `AgentRuntime.runUserText` for no-tool path only.
- [ ] Implement provider-event bridge for message_start/text_delta/thinking_delta/message_delta/message_end/done/error_event.
- [ ] Map provider parse/provider failures to agent errors and event sink errors.
- [ ] Add failure lifecycle tests for provider failure and provider stream parse failure: `error_event`, `turn_end(failed)`, `agent_end(failed)`, without duplicating the same provider error when `provider.error_event` was already observed.
- [ ] Implement centralized failure finalization helper for post-`turn_start` failures.
- [ ] Run `zig build test` and `zig build fmt-check`.
- [ ] Commit: `feat: add no-tool agent runtime loop`.

### Task 6：Sequential tool-call loop

**Files:**

- Update: `src/core/agent/runtime.zig`
- Update: `src/core/agent/state.zig`
- Update: `test/agent_runtime_tools.zig`

Steps:

- [ ] Add failing test for one tool-call iteration followed by final assistant text.
- [ ] Add failing tests for missing tool, tool failure, tool result cleanup on middleware rejection, and max iteration.
- [ ] Run `zig build test`; expected missing tool loop behavior.
- [ ] Extend provider bridge to accumulate `tool_call_start/delta/end` into pending tool calls, treating `tool_call_end.arguments_json` as canonical.
- [ ] Append assistant tool-call message after provider iteration.
- [ ] Execute tools sequentially by pending call index.
- [ ] Emit `tool_execution_start` and `tool_execution_end` around executor call.
- [ ] Append tool result messages, deinitialize owned `ToolExecutionResult` on both success and post-execution failure paths, and continue provider loop.
- [ ] Enforce `max_iterations`.
- [ ] Assert missing tool, tool failure, and max-iteration paths emit `turn_end(failed)` plus `agent_end(failed)`.
- [ ] Run `zig build test` and `zig build fmt-check`.
- [ ] Commit: `feat: add sequential agent tool loop`.

### Task 7：Middleware behavior and abort handling

**Files:**

- Update: `src/core/agent/middleware.zig`
- Update: `src/core/agent/runtime.zig`
- Create: `test/agent_middleware.zig`
- Modify: `src/core/agent/mod.zig`

Steps:

- [ ] Add failing tests for hook order across input/provider/tool/result.
- [ ] Add failing tests for hook rejection short-circuit behavior.
- [ ] Add failing tests for cooperative abort boundaries before provider request, between provider events, and before tool calls.
- [ ] Run `zig build test`; expected missing middleware behavior.
- [ ] Wire `MiddlewareHooks` calls at the specified runtime points.
- [ ] Map hook rejection to `MiddlewareRejected`; emit agent error event only after an agent run has started.
- [ ] Implement simple abort flag checks and `AgentEvent.abort`.
- [ ] Run `zig build test` and `zig build fmt-check`.
- [ ] Commit: `feat: add agent middleware behavior`.

### Task 8：Agent fixtures build step and docs

**Files:**

- Modify: `build.zig`
- Create: `fixtures/agent/README.md`
- Create: `fixtures/agent/no-tool-turn.jsonl`
- Create: `fixtures/agent/tool-call-turn.jsonl`
- Create: `docs/agent-runtime.md`
- Create: `docs/agent-events.md`
- Modify: `docs/architecture.md`
- Modify: `docs/error-model.md`
- Modify: `docs/allocator-policy.md`
- Modify: `docs/fixtures.md`
- Modify: `README.md`

Steps:

- [ ] Add `zig build agent-fixtures` step running `test/agent_fixtures.zig`.
- [ ] Add minimal JSONL fixture examples with fake provider/tool events only.
- [ ] Implement `test/agent_fixtures.zig` to validate fixture JSONL shape without replaying live providers/tools.
- [ ] Document M2 runtime loop, event schema, ownership, failure finalization, and scope boundaries.
- [ ] Update README command list to include `agent-fixtures`.
- [ ] Run full M2 verification commands.
- [ ] Commit: `docs: document m2 agent runtime`.

## 16. Acceptance commands

M2 completion must pass:

```bash
zig version
zig build
zig build run -- --version
zig build run -- --help
zig build run -- doctor
zig build run -- paths
zig build test
zig build smoke
zig build provider-fixtures
zig build agent-fixtures
zig build provider-live
zig build fmt-check
```

Default behavior:

- `zig build test` is offline.
- `zig build smoke` is offline.
- `zig build provider-fixtures` is offline.
- `zig build agent-fixtures` is offline.
- `zig build provider-live` skips unless explicitly enabled, same as M1.

## 17. Done definition

M2 is done when:

- `core.agent` exposes state, event, model client, tool, middleware, runtime modules.
- Agent runtime can complete a no-tool user turn with a scripted provider.
- Agent runtime can complete a tool-call turn with scripted provider + fake tool + continuation provider turn.
- Agent runtime emits deterministic events for agent/turn/message/tool/error/abort transitions, with paired `agent_start`/`agent_end` for each `runUserText()` call.
- Tool execution is sequential and predictable.
- Runtime accumulates `provider.thinking_delta` into assistant thinking content.
- Middleware hooks exist and are tested for order/rejection.
- Runtime does not depend on app, TUI, session, resources, RPC, or plugin modules.
- Runtime does not parse provider-specific SSE/JSON; it consumes M1 `ProviderEvent` only.
- Default tests and fixtures are offline and contain no secrets.
- Docs describe event ownership, runtime loop, scope boundaries, and M3/M4/M5 handoff.
- Full acceptance commands pass.

## 18. Main risks

- If M2 stores borrowed `MessageView` payloads in state, later provider calls will use dangling memory. `AgentState` must own messages and `MessageViewBatch` must own only temporary view allocations.
- If `runUserText()` emits `agent_end` without a matching `agent_start` on repeated calls, downstream session/TUI consumers will see broken lifecycle pairs.
- If runtime silently drops `provider.thinking_delta`, thinking-enabled providers will lose model output. Accumulate it into assistant thinking content or fail deterministically if this contract changes.
- If runtime directly parses OpenAI/Anthropic JSON, provider/core layering is broken. Use only `provider.ProviderEvent`.
- If real coding tools are added in M2, approval/preview/security scope will leak from M3 and delay runtime completion.
- If product CLI flags are added in M2, M5 mode design may be prematurely constrained. Keep CLI changes to build/test docs only unless explicitly requested.
- If event collectors do not clone payloads, tests may pass accidentally with static strings but fail with streaming buffers later.
- If max-iteration guard is missing, scripted or real providers can create infinite tool loops.
- If middleware is overbuilt as a plugin system, M10 scope leaks into M2. Keep one hooks struct.

## 19. Handoff to M3/M4/M5

After M2:

- M3 can register real coding tools behind `ToolRegistry` / `ToolExecutor`.
- M4 can subscribe to `AgentEventSink` and clone events/messages into append-only session JSONL.
- M5 can expose print/json/interactive/RPC modes by constructing `AgentRuntime` with real provider/model clients and tool registries.
- M6 can render streaming output by consuming `AgentEvent` without knowing provider-specific details.
