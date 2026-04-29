# Pig v1.0 M1 Implementation Plan：Provider Layer（`pi-ai` Core）

> 本文是 `pig-v1.0-roadmap.md` 中 M1 的执行计划。
>
> M1 的目标是在 agent loop 依赖具体模型 API 之前，建立 Zig 版 provider 抽象：统一消息模型、统一 streaming event、SSE/chunked 解析、OpenAI-compatible provider 的最小可用实现，以及 Anthropic/Gemini 等 provider 后续接入所需的边界。
>
> M1 不追求完整 coding-agent 产品体验；它只把 provider 层做成可测试、可替换、可被 M2 agent runtime 直接消费的底座。

## 1. M1 目标

M1 要解决的问题：

1. 建立 provider 层的核心数据模型：message、content、tool call、tool result、usage、stream event。
2. 建立 provider 与 app/CLI 解耦的 streaming event API。
3. 建立 HTTP transport 抽象，先支持 Zig stdlib HTTP，同时保留替换 curl/外部 transport 的窄接口。
4. 实现 SSE / chunked stream parser，支持 partial-line buffering。
5. 实现 OpenAI-compatible Chat Completions provider：优先 streaming text，兼容后续 tool call delta。
6. 实现 Anthropic Messages recorded-stream parser：至少能从 fixtures 解析 text delta 和 tool-call 事件为统一 event。
7. 建立 auth resolution 的最小能力：env、显式 auth JSON、显式 provider config。
8. 建立 recorded fixtures 和 provider tests，默认测试不访问网络、不读取真实 API key。
9. 提供一个可选 live smoke 路径，显式开启后可以验证 OpenAI-compatible endpoint 的 streaming text。

M1 不做：

- 不实现 agent loop。
- 不实现 tool execution。
- 不实现 print/json/interactive 产品模式。
- 不实现 session 持久化。
- 不实现完整 config hierarchy。
- 不实现 OAuth、browser login、secure storage。
- 不实现完整 Gemini、OpenAI Responses、Azure、Bedrock、OpenRouter 行为；只保留类型和接口空间。
- 不把 provider event 直接耦合到 TUI 或 app mode。

## 2. 当前基础

M0 已经在当前 repo root 提交，commit 为 `3772d3a feat: add zig m0 foundation`。本计划默认 Pig v1.0 Zig 实现直接位于 repo root，与 Bun/TypeScript demo 并存；不要再创建 `zig/` 子目录，也不要把 M1 写到旧 `agent.ts` demo 中。

M0 已经提供：

```text
build.zig
build.zig.zon
src/main.zig
src/mod.zig
src/app/
src/core/
src/provider/mod.zig
src/tools/mod.zig
src/session/mod.zig
src/resources/mod.zig
src/tui/mod.zig
src/rpc/mod.zig
src/plugin/mod.zig
src/util/
test/cli.zig
test/fixtures.zig
fixtures/fake-provider/empty-turn.jsonl
docs/architecture.md
docs/error-model.md
docs/allocator-policy.md
docs/fixtures.md
```

M1 应该在这个 skeleton 上扩展，不重写 M0 架构。

## 3. 建议目录结构

M1 后建议的 provider 目录：

```text
src/provider/
├── mod.zig
├── types.zig
├── content.zig
├── messages.zig
├── events.zig
├── usage.zig
├── errors.zig
├── auth.zig
├── config.zig
├── transport.zig
├── request.zig
├── response.zig
├── sse.zig
├── openai_compatible.zig
├── anthropic.zig
├── fake.zig
└── testing.zig
```

测试和 fixtures：

```text
test/
├── provider_types.zig
├── provider_sse.zig
├── provider_openai.zig
├── provider_anthropic.zig
├── provider_auth.zig
└── provider_live.zig       # 默认不跑 live network；通过 build step/env 显式开启

fixtures/provider/
├── README.md
├── openai-compatible/
│   ├── text-stream.sse
│   ├── tool-call-stream.sse
│   ├── usage-final-chunk.sse
│   ├── missing-done.sse
│   ├── stream-error.sse
│   └── response-error.json
├── anthropic/
│   ├── text-stream.sse
│   ├── tool-use-stream.sse
│   ├── stream-error.sse
│   └── response-error.json
└── auth/
    ├── auth-openai.json
    └── provider-config.json

docs/
├── provider-events.md
├── provider-auth.md
└── provider-transport.md
```

如果某个文件在实现时过小，可以先合并；但 `types/events/sse/transport/openai_compatible/anthropic/auth` 建议保持独立，避免 `provider/mod.zig` 变成大文件。

## 4. Provider 数据模型

### 4.1 Provider kind 和 model id

`src/provider/types.zig` 应定义：

```text
ProviderKind:
  openai_compatible
  anthropic
  gemini
  openai_responses
  azure_openai
  bedrock
  openrouter
  custom

ModelId:
  value: []const u8
```

M0 已经有 `ProviderKind` / `ProviderStatus` placeholder。M1 应该把它们移动或扩展为正式类型，并保持 `provider.ProviderKind` 仍可从 `src/provider/mod.zig` 导出，避免破坏 M0 tests。

### 4.2 Content block

`src/provider/content.zig` 应定义 tagged union：

```text
ContentBlock:
  text: TextBlock
  image_ref: ImageRefBlock
  thinking: ThinkingBlock
  tool_call: ToolCallBlock
  tool_result: ToolResultBlock
```

最小字段：

```text
TextBlock:
  text: []const u8

ImageRefBlock:
  uri: []const u8
  mime_type: ?[]const u8

ThinkingBlock:
  text: []const u8
  signature: ?[]const u8

ToolCallBlock:
  id: []const u8
  name: []const u8
  arguments_json: []const u8

ToolResultBlock:
  tool_call_id: []const u8
  content_json: []const u8
  is_error: bool
```

M1 只存 JSON string，不执行 tool，也不校验 tool schema。严格 schema 校验在 M3 tool execution 前做。

### 4.3 Message

`src/provider/messages.zig` 应定义：

```text
Role:
  system
  user
  assistant
  tool

Message:
  role: Role
  content: []const ContentBlock
```

M1 必须显式区分 borrowed view 和 owned value：

```text
MessageView / ContentBlockView:
  borrowed slices, no deinit, valid only as long as caller-owned input lives

OwnedMessage / OwnedContentBlock:
  owns duplicated payloads, has deinit(allocator)
```

Provider request builders可以接受 `MessageView`；如果需要跨 callback 或跨 request 保存，则必须 clone 为 owned value。不要在同一个 struct 中混用 borrowed/owned slices。

### 4.4 Streaming event

`src/provider/events.zig` 应定义统一 event：

```text
ProviderEvent:
  message_start
  message_delta
  message_end
  text_delta
  thinking_delta
  tool_call_start
  tool_call_delta
  tool_call_end
  usage
  cost
  error
  done
```

事件必须 provider-agnostic。OpenAI/Anthropic/Gemini 的原始字段不能泄漏到 app/core 层；如果需要保留 raw metadata，用 `metadata_json: ?[]const u8`，但 M1 默认不依赖它。

`message_delta` 在 M1 只承载 provider-agnostic 的 message metadata：

```text
MessageDelta:
  stop_reason: ?[]const u8
  metadata_json: ?[]const u8
```

`cost` 在 M1 是保留 variant，不要求任何 provider emit，也不要求测试构造。若实现 union 需要 payload，可先使用占位 payload：

```text
Cost:
  amount_micros: u64
  currency: []const u8
```

M1 只实现 `usage`，后续 M15 或 provider registry 有价格表后再计算 cost。

建议事件字段：

```text
MessageStart:
  provider_message_id: ?[]const u8
  role: Role

TextDelta:
  text: []const u8

ThinkingDelta:
  text: []const u8
  signature_delta: ?[]const u8

ToolCallStart:
  index: u32
  id: ?[]const u8
  name: ?[]const u8

ToolCallDelta:
  index: u32
  arguments_json_delta: []const u8

ToolCallEnd:
  index: u32
  id: []const u8
  name: []const u8
  arguments_json: []const u8

Usage:
  input_tokens: ?u64
  output_tokens: ?u64
  cache_read_tokens: ?u64
  cache_write_tokens: ?u64

Usage.add(a, b):
  sums fields that are present in both or either side;
  null + null remains null.

ProviderError:
  category: provider.errors.ProviderErrorKind
  message: []const u8
  retryable: bool
```

## 5. M1 API 合约

这些决策必须在实现前固定，避免 stream parser、event sink、transport 和 M2 agent runtime 之间产生生命周期歧义。

### 5.1 Event ownership

M1 采用 callback-scoped event view：

```text
Provider parser owns temporary buffers.
ProviderEvent string slices are valid only during EventSink.onEvent().
If a sink needs to retain events, it must duplicate payloads.
Recorded test sinks clone events into owned EventList.
```

原因：streaming parser 会复用 buffers；如果每个 delta 都分配 owned event，会让 hot path allocation 过多。后续 M2 如果需要持久化 event，应在 core/session 层 clone。

### 5.2 EventSink shape

M1 使用 concrete sink vtable，而不是让 parser 直接依赖 app/core：

```zig
pub const EventSinkError = error{
    OutOfMemory,
    SinkRejectedEvent,
};

pub const EventSink = struct {
    ptr: *anyopaque,
    on_event: *const fn (ptr: *anyopaque, event: ProviderEvent) EventSinkError!void,

    pub fn emit(self: EventSink, event: ProviderEvent) EventSinkError!void {
        return self.on_event(self.ptr, event);
    }
};
```

Parser 函数签名建议：

```text
parseStream(allocator, stream, sink) -> (ProviderParseError || EventSinkError)!void
parseSseEvent(allocator, event, sink, state) -> (ProviderParseError || EventSinkError)!void
```

### 5.3 Error semantics

命名约定：

- `ProviderErrorKind`：domain error category enum，用在 event payload。
- `ProviderErrorEvent`：`ProviderEvent.error` 的 payload。
- `ProviderParseError`：parser 函数返回的 Zig error set。
- `EventSinkError`：event sink callback 返回的 Zig error set。
- 不使用一个含混的 `ProviderError` 同时表示 event payload 和 Zig error set。

M1 区分三类错误：

1. Allocation / local I/O failure：返回 Zig error，不保证 emit `ProviderEvent.error`。
2. Provider/API error response：尽量 emit `ProviderEvent.error`，parser 可正常结束。
3. Fatal malformed stream：emit `ProviderEvent.error` 后返回 `error.StreamParseError`，不再 emit `done`。

`done` 只表示 provider stream 成功结束，不表示“没有错误”。API error response、SSE error event、malformed stream 都不 emit `done`。

### 5.4 Event ordering guarantees

OpenAI-compatible text stream：

```text
message_start
text_delta*
usage?
message_delta?
message_end
done
```

OpenAI-compatible tool stream：

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

Anthropic text/tool streams 也映射到同样的统一顺序。`done` 每个 stream 最多 emit 一次。

OpenAI-specific 规则：

- `finish_reason` 触发 `message_delta(stop_reason=...)` 和 `message_end`。
- `[DONE]` 触发 `done`。
- 如果已经 emit `done`，后续 duplicate done ignored。
- 如果 stream clean EOF 但没有 `[DONE]`，recorded parser 默认返回 `StreamParseError`；live transport 可以在以后增加 lenient mode，但 M1 fixtures 使用 strict mode。

### 5.5 JSON parsing strategy

M1 使用 Zig stdlib JSON，不引入第三方依赖：

- Provider SSE `data` JSON 使用一次 SSE event 生命周期的 `ArenaAllocator`。
- 优先用 `std.json.Value` 做宽松读取，忽略未知字段。
- 不解析 partial tool-call argument delta。
- 在 `tool_call_end` / Anthropic `content_block_stop` 时统一用 `std.json.parseFromSlice(std.json.Value, ...)` 校验 assembled `arguments_json` 是完整 JSON；如果 provider 没有提供参数，先规范化为 `{}` 再校验。
- JSON 校验失败时 emit `ProviderEvent.error(category=StreamParseError)` 并返回 `error.StreamParseError`。

### 5.6 Transport ownership

`transport.Request` owned by request builder：

```text
Request.deinit(allocator) frees url/body/headers allocated by builder.
Header name/value slices are owned by Request unless explicitly marked borrowed.
ResponseStream.nextChunk(buffer) returns a slice valid until next nextChunk/deinit.
Transport never logs Authorization header.
```

### 5.7 Live HTTP fallback decision

M1 必须完成 transport interface、fake/recorded transport、request builder、recorded parsers。`StdHttpTransport` 应首先尝试实现。

如果 Zig 0.16 stdlib HTTP/TLS 无法可靠完成 live streaming：

- 允许在 M1 中实现窄 `CurlTransport` 作为 fallback，前提是不引入复杂 dependency 管理。
- 如果没有 curl fallback，`zig build provider-live` 在 `PIG_PROVIDER_LIVE=1` 时必须 nonzero，并输出明确诊断：`live transport unsupported on this platform/build`。
- 不能让默认 `zig build test` 或 `zig build provider-fixtures` 依赖 live transport。

Roadmap 的 live endpoint 验收仍是 M1 目标；如果 stdlib HTTP 阻塞，应优先评估 curl fallback，而不是扩大 provider parser scope。

## 6. Transport 抽象

### 6.1 `provider.transport`

M1 不应该让 OpenAI provider 直接依赖 app CLI 或硬编码 stdlib HTTP。定义窄接口：

```text
Request:
  method
  url
  headers
  body
  timeout_ms

ResponseStream:
  nextChunk(buffer) -> ?[]const u8
  deinit()

Transport:
  sendStreaming(request) -> ResponseStream
```

Zig 0.16 的 HTTP API 可能继续变化；M1 应把具体 stdlib 调用收敛在 `src/provider/transport.zig`，避免污染 provider parser 和 request builder。

### 6.2 实现优先级

1. `RecordedTransport` / `FakeTransport`：读取 fixture chunks，默认测试使用。
2. `StdHttpTransport`：真实 HTTP streaming，用于 live smoke。
3. `CurlTransport`：M1 只留接口和文档，不实现，除非 Zig stdlib HTTP/TLS 阻塞 live smoke。

### 6.3 Live smoke 开关

默认 `zig build test` 不访问网络。

建议增加 build step：

```bash
zig build provider-live
```

只有同时满足以下条件才执行 live request：

```text
PIG_PROVIDER_LIVE=1
PIG_OPENAI_COMPAT_BASE_URL is set
PIG_OPENAI_COMPAT_API_KEY is set
PIG_OPENAI_COMPAT_MODEL is set
```

`provider-live` 行为必须固定：

```text
PIG_PROVIDER_LIVE != 1
  -> print "provider-live: skipped", exit 0

PIG_PROVIDER_LIVE = 1 but any required live env is missing
  -> print skipped with missing variable names, exit 0

PIG_PROVIDER_LIVE = 1 and all live env exists, but live transport unsupported
  -> print actionable diagnostic, exit nonzero

PIG_PROVIDER_LIVE = 1 and all live env exists, provider/API error
  -> print actionable diagnostic without API key, exit nonzero
```

## 7. SSE / Chunk Parser

### 7.1 `provider.sse`

M1 必须实现通用 SSE parser，不绑定 OpenAI/Anthropic。

输入是任意 chunk：

```text
"data: {json}\n\n"
"event: content_block_delta\n"
"data: {json}\n\n"
```

必须支持：

- chunk 边界落在行中间。
- `\r\n` 和 `\n`。
- comment line：以 `:` 开头。
- 多行 `data:` 合并，行间用 `\n`。
- event name 可选。
- OpenAI `[DONE]` sentinel。
- 最后一行没有换行时的 flush 行为。

API 建议：

```text
SseParser.init(allocator)
SseParser.feed(chunk, event_sink)
SseParser.finish(event_sink)
SseParser.deinit()

SseEvent:
  event: ?[]const u8
  data: []const u8
```

Parser 只产出 SSE event，不解析 provider JSON。

## 8. OpenAI-compatible provider

### 8.1 范围

M1 P0 只实现 Chat Completions streaming：

```http
POST {base_url}/chat/completions
Authorization: Bearer <key>
Content-Type: application/json
Accept: text/event-stream
```

Request body 最小字段：

```json
{
  "model": "...",
  "stream": true,
  "messages": [
    {"role": "user", "content": "hello"}
  ]
}
```

后续字段只保留类型空间，不在 M1 中扩展：temperature、max_tokens、tools、tool_choice、response_format。

### 8.2 Event mapping

OpenAI SSE chunk 示例：

```json
{"choices":[{"delta":{"role":"assistant","content":"hel"}}]}
```

映射：

```text
first assistant role delta -> message_start(role=assistant)
if role is omitted, first content/tool delta -> message_start(role=assistant)
delta.content -> text_delta
delta.tool_calls[].function.arguments -> tool_call_delta
finish_reason -> message_delta(stop_reason) + message_end
usage chunk -> usage
error JSON or SSE error data -> error
[DONE] -> done exactly once
```

Tool call assembly：

- 按 `index` 聚合。
- `id` / `function.name` 可能在 start chunk 出现。
- `function.arguments` 可能分多段到达。
- M1 只组装 `arguments_json` 字符串，不执行和不 schema validate。
- 结束时如果 assembled arguments 为空，规范化为 `{}`；如果非空但不是完整 JSON，先 emit `ProviderEvent.error(category=StreamParseError)`，再返回 `error.StreamParseError`，不要 panic。

### 8.3 Request builder

`src/provider/openai_compatible.zig` 应提供：

```text
OpenAiCompatibleConfig:
  base_url
  api_key
  model

buildChatCompletionsRequest(allocator, config, messages) -> transport.Request
parseStream(allocator, response_stream, event_sink) -> (ProviderParseError || EventSinkError)!void
```

M1 不需要支持 non-streaming completion，除非 stdlib HTTP 调试需要。

## 9. Anthropic parser

M1 不要求 live Anthropic request，但要建立 Messages stream parser 的 event mapping。

### 9.1 Recorded stream 支持

使用 `fixtures/provider/anthropic/*.sse` 测试：

```text
event: message_start
data: {...}

event: content_block_start
data: {...}

event: content_block_delta
data: {...}

event: content_block_stop
data: {...}

event: message_delta
data: {...}

event: message_stop
data: {...}
```

### 9.2 Event mapping

Malformed Anthropic event sequence 处理：unknown index delta、duplicate active `content_block_start`、unknown index stop、`message_stop` 时仍有 active tool block，都必须 emit `ProviderEvent.error(category=StreamParseError)` 并返回 `error.StreamParseError`。

- `message_start` -> `ProviderEvent.message_start`
- text `content_block_delta` -> `ProviderEvent.text_delta`
- thinking delta -> `ProviderEvent.thinking_delta`
- `tool_use` block start -> `tool_call_start`，并按 content block `index` 记录 id/name/state
- `input_json_delta.partial_json` -> `tool_call_delta`，按 `index` 追加 arguments bytes
- content block stop for tool -> 校验并 emit `tool_call_end`，然后清理该 `index` 的状态
- `message_delta.usage` -> `usage`
- `message_stop` -> `message_end` + `done`

## 10. Auth resolution

M1 的 auth resolution 是 provider-local，不做完整 M7 config hierarchy。

### 10.1 Auth sources

优先级：

1. Explicit provider config：调用方直接传入 `api_key`。
2. Explicit auth JSON file path：测试或后续资源层传入文件路径。
3. Environment：
   - OpenAI-compatible：`PIG_OPENAI_COMPAT_API_KEY`
   - Anthropic：`ANTHROPIC_API_KEY` 或 `PIG_ANTHROPIC_API_KEY`
   - Gemini：`GEMINI_API_KEY` 或 `PIG_GEMINI_API_KEY`

注意：explicit config 和 explicit auth JSON 都排在 env 前面，避免测试被本机真实环境变量污染。live smoke 的 `base_url` 和 `model` 只来自 explicit config 或 live env；auth JSON 只负责 secret，不负责 endpoint/model 默认值。

### 10.2 Auth JSON 最小格式

```json
{
  "providers": {
    "openai_compatible": {
      "api_key": "test-key"
    },
    "anthropic": {
      "api_key": "test-key"
    }
  }
}
```

M1 测试必须只使用 fake/test key，不读取 `~/.pi/agent/auth.json`。

`fixtures/provider/auth/provider-config.json` 只包含非 secret 配置，最小格式：

```json
{
  "openai_compatible": {
    "base_url": "https://example.invalid/v1",
    "model": "test-model"
  }
}
```

### 10.3 安全规则

- API key 不进入 logs。
- API key 不进入 test failure expected output。
- Auth fixture 只能包含 fake key，例如 `test-openai-key`。
- `docs/fixtures.md` 应补充 provider fixture/auth fixture 规则。

## 11. Tool-call 参数组装边界

M1 只负责 provider stream 中 tool call 参数的字节级组装。

M1 做：

- 按 provider-specific index/id 聚合 tool-call chunks。
- 输出统一 `tool_call_start/delta/end` events。
- 对明显不完整的 JSON 参数返回 provider parse error。

M1 不做：

- 不根据 tool schema 校验参数。
- 不执行 tool。
- 不调用确认 UI。
- 不把 tool result 发送回 provider。

这些属于 M2/M3。

## 12. Build system 更新

M1 应更新 `build.zig`：

- 把 provider test 文件加入 `zig build test`；建议在 `build.zig` 中加小 helper 注册 test 文件，避免手写重复步骤遗漏。
- 增加 `zig build provider-fixtures` 可选 step，用于只跑 provider recorded fixtures。
- 增加 `zig build provider-live` 可选 step，用于显式 live smoke。
- `zig build smoke` 仍保持 M0 CLI smoke，不访问网络。
- `zig build fmt-check` 继续覆盖 `build.zig`、`build.zig.zon`、`src`、`test`。

建议 steps：

```text
test               全量 offline unit tests
provider-fixtures  provider recorded fixtures tests，offline
provider-live      显式开启时访问 live OpenAI-compatible endpoint，否则 skip
smoke              CLI local smoke，offline
fmt-check          Zig formatting check
```

## 13. 测试计划

所有默认测试必须离线可跑。

### 13.1 Unit tests

`test/provider_types.zig`：

- role enum/string conversion。
- provider kind enum/string conversion。
- content block construction/deinit。
- usage aggregation。
- error category mapping。

`test/provider_auth.zig`：

- explicit config wins over env。
- env resolution works with injected environment map / test resolver。
- auth JSON fake key can be parsed。
- missing key returns user-fixable auth error。
- key never appears in formatted error message。

`test/provider_sse.zig`：

- complete single SSE event。
- chunk split in middle of line。
- multiple data lines。
- comments ignored。
- CRLF supported。
- `[DONE]` sentinel preserved as data。
- finish handles trailing buffered line。

### 13.2 Recorded provider tests

`test/provider_openai.zig`：

- `fixtures/provider/openai-compatible/text-stream.sse` maps to:
  - message_start
  - text_delta(s)
  - message_end
  - done
- `tool-call-stream.sse` maps to tool_call_start/delta/end。
- `usage-final-chunk.sse` maps usage。
- malformed/incomplete tool args returns parse error event, not panic。
- `missing-done.sse`：允许先因 `finish_reason` emit `message_end`，随后 EOF 时 emit `error(StreamParseError)` 并返回 `StreamParseError`，但绝不 emit `done`。

`test/provider_anthropic.zig`：

- text stream maps to unified events。
- tool use stream maps to tool_call events。
- usage maps to unified usage。

### 13.3 Live provider smoke

`test/provider_live.zig` 或 `src/provider/live_smoke.zig`：

`zig build test` 可以包含 `test/provider_live.zig`，但只能测试 skip/config parsing 行为，不允许发起网络请求。真实 live request 只能从 `zig build provider-live` 触发。

- 如果 `PIG_PROVIDER_LIVE != 1`，print `provider-live: skipped`，exit 0。
- 如果 `PIG_PROVIDER_LIVE=1` 但 live env 不完整，print skipped 和缺失变量名，exit 0。
- 如果 env 完整，发起 OpenAI-compatible streaming request。
- 验证至少收到一个 `text_delta` 和最终 `done`。
- 不打印 API key。

### 13.4 Regression tests for M0

M1 不应破坏：

```bash
zig build run -- --version
zig build run -- --help
zig build run -- doctor
zig build run -- paths
zig build smoke
```

## 14. 文档交付

M1 至少新增：

```text
docs/provider-events.md
docs/provider-auth.md
docs/provider-transport.md
fixtures/provider/README.md
```

并更新：

```text
docs/architecture.md
docs/error-model.md
docs/fixtures.md
docs/allocator-policy.md
README.md
```

内容要求保持“最小有用”，不要写成长篇 provider 手册；先记录 M1 API contract、fixtures 和 live smoke 运行方式即可。

- `provider-events.md`：统一 event schema、provider-specific mapping、event 顺序保证。
- `provider-auth.md`：auth source 优先级、env vars、auth JSON fake fixture 格式、安全规则。
- `provider-transport.md`：transport interface、stdlib HTTP 限制、curl fallback 决策点、live smoke env。
- `fixtures/provider/README.md`：recorded fixture 格式、禁止 secrets、如何新增 provider fixtures。
- `architecture.md`：补充 M1 provider 层与 M2 agent runtime 的关系。
- `error-model.md`：补充 provider/auth/stream parse error 的 retry/user-fixable 行为。
- `allocator-policy.md`：补充 stream parser、event ownership、request/response buffer 生命周期。
- `README.md`：补充 M1 provider fixture/live smoke 命令。

## 15. 执行顺序

建议按以下顺序实现，严格 TDD：

1. 添加 provider model tests：role/provider kind/content/message/usage。
2. 实现 `provider.types/content/messages/usage/errors` 最小 API。
3. 添加 event model tests。
4. 实现 `provider.events` 和 event formatting/debug helper。
5. 添加 SSE parser red tests。
6. 实现 `provider.sse`，直到 partial-line/multiline/CRLF tests 全绿。
7. 添加 OpenAI recorded text stream fixture 和 failing parser test。
8. 实现 OpenAI text delta parser。
9. 添加 OpenAI usage/error/tool-call fixtures 和 tests。
10. 实现 OpenAI usage/error/tool-call assembly。
11. 添加 Anthropic recorded text/tool fixtures 和 failing parser tests。
12. 实现 Anthropic recorded stream parser。
13. 添加 auth resolver tests。
14. 实现 explicit/env/auth-json resolver。
15. 添加 transport interface tests 和 fake transport。
16. 实现 `provider.transport` interface + recorded/fake transport。
17. 实现 OpenAI-compatible request builder。
18. 添加 live smoke harness，默认 skip。
19. 更新 `build.zig`，加入 provider tests、provider-fixtures、provider-live。
20. 新增 provider docs 和 fixtures README。
21. 更新 README 和已有 docs。
22. 跑完整 M1 验收命令。
23. 请求代码审查，修复 Critical/Important 问题。
24. 重新跑完整验收命令并提交。

## 16. 推荐任务拆分

### Task 1：Provider 基础类型

**Files:**

- Modify: `src/provider/mod.zig`
- Create: `src/provider/types.zig`
- Create: `src/provider/content.zig`
- Create: `src/provider/messages.zig`
- Create: `src/provider/usage.zig`
- Create: `src/provider/errors.zig`
- Create: `test/provider_types.zig`

验收：

```bash
zig build test
```

Task 1 必须保持 M0 compatibility imports：

```zig
@import("pig").provider.ProviderKind
@import("pig").provider.ProviderStatus
```

### Task 2：统一 Provider Events 和 API contract

**Files:**

- Create: `src/provider/events.zig`
- Create: `test/provider_events.zig`
- Update: `docs/provider-events.md` draft

验收：

```bash
zig build test
```

### Task 3：SSE parser

**Files:**

- Create: `src/provider/sse.zig`
- Create: `test/provider_sse.zig`
- Create: `fixtures/provider/README.md`

验收：

```bash
zig build test --summary all
```

### Task 4：OpenAI-compatible recorded parser

**Files:**

- Create: `src/provider/openai_compatible.zig`
- Create: `fixtures/provider/openai-compatible/text-stream.sse`
- Create: `fixtures/provider/openai-compatible/tool-call-stream.sse`
- Create: `fixtures/provider/openai-compatible/usage-final-chunk.sse`
- Create: `fixtures/provider/openai-compatible/missing-done.sse`
- Create: `fixtures/provider/openai-compatible/stream-error.sse`
- Create: `fixtures/provider/openai-compatible/response-error.json`
- Create: `test/provider_openai.zig`

验收：

```bash
zig build test
zig build provider-fixtures
```

### Task 5：Anthropic recorded parser

**Files:**

- Create: `src/provider/anthropic.zig`
- Create: `fixtures/provider/anthropic/text-stream.sse`
- Create: `fixtures/provider/anthropic/tool-use-stream.sse`
- Create: `fixtures/provider/anthropic/stream-error.sse`
- Create: `fixtures/provider/anthropic/response-error.json`
- Create: `test/provider_anthropic.zig`

验收：

```bash
zig build test
zig build provider-fixtures
```

### Task 6：Auth resolver

**Files:**

- Create: `src/provider/auth.zig`
- Create: `src/provider/config.zig`
- Create: `fixtures/provider/auth/auth-openai.json`
- Create: `fixtures/provider/auth/provider-config.json`
- Create: `test/provider_auth.zig`
- Create: `docs/provider-auth.md`

验收：

```bash
zig build test
```

### Task 7：Transport interface 和 live smoke harness

**Files:**

- Create: `src/provider/transport.zig`
- Create: `src/provider/request.zig`
- Create: `src/provider/response.zig`
- Create: `src/provider/fake.zig`
- Create: `src/provider/testing.zig`
- Create: `test/provider_live.zig` or `src/provider/live_smoke.zig`
- Modify: `build.zig`
- Create: `docs/provider-transport.md`

验收：

```bash
zig build test
zig build provider-live
PIG_PROVIDER_LIVE=1 \
PIG_OPENAI_COMPAT_BASE_URL=... \
PIG_OPENAI_COMPAT_API_KEY=... \
PIG_OPENAI_COMPAT_MODEL=... \
zig build provider-live
```

未设置 env 时，`zig build provider-live` 必须 skip 且 exit 0。

### Task 8：Docs、README、回归验收

**Files:**

- Modify: `README.md`
- Modify: `docs/architecture.md`
- Modify: `docs/error-model.md`
- Modify: `docs/fixtures.md`
- Modify: `docs/allocator-policy.md`
- Finalize: `docs/provider-events.md`
- Create: `docs/provider-auth.md`
- Create: `docs/provider-transport.md`

验收：

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
zig build provider-live
zig build fmt-check
```

## 17. 验收命令

M1 完成时必须通过：

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
zig build provider-live
zig build fmt-check
```

默认情况下：

- `zig build test` 不访问网络。
- `zig build smoke` 不访问网络。
- `zig build provider-fixtures` 不访问网络。
- `zig build provider-live` 在 `PIG_PROVIDER_LIVE != 1` 或 live env 缺失时 skip 并 exit 0。

可选 live 验证：

```bash
PIG_PROVIDER_LIVE=1 \
PIG_OPENAI_COMPAT_BASE_URL="https://..." \
PIG_OPENAI_COMPAT_API_KEY="..." \
PIG_OPENAI_COMPAT_MODEL="..." \
zig build provider-live
```

live 输出要求：

- 至少显示收到 `text_delta`。
- 显示 `done`。
- 不显示 API key。
- provider/API 错误返回 nonzero，错误信息可操作。

## 18. Done Definition

M1 完成条件：

- Provider message/content/event 类型稳定可用。
- OpenAI-compatible recorded streaming text fixture 可以解析成统一 events。
- OpenAI-compatible recorded tool-call fixture 可以组装为 unified tool-call events。
- Anthropic recorded text/tool-use stream 可以解析成统一 events。
- SSE parser 支持 partial-line buffering、多行 data、CRLF、comments、finish flush。
- Auth resolver 支持 explicit config、env、explicit auth JSON。
- Transport interface 与 provider parser 解耦。
- 默认测试全部离线通过。
- Live smoke 需要显式 env，且没有 env 时 skip。
- 文档说明 provider events、auth、transport、fixtures、安全规则。
- 没有 API key、auth token、真实 provider response、真实用户 session 写入仓库。
- `zig build test`、`zig build smoke`、`zig build provider-fixtures`、`zig build provider-live`、`zig build fmt-check` 全部通过。

## 19. 主要风险

- Zig 0.16 stdlib HTTP/TLS 对部分 provider endpoint 的 streaming/SSE 兼容性可能不足；必须把 transport 抽象做窄，必要时 M1 后半段切 curl transport。
- SSE parser 如果与 provider JSON parser 混在一起，后续 Gemini/Anthropic/OpenAI Responses 会难以复用；必须分层。
- Tool-call arguments 是 partial JSON，不能假设每个 delta 都是合法 JSON。
- Auth tests 容易被本机真实 env 污染；resolver tests 必须使用注入式 env/config。
- Live smoke 不能默认启用，否则 CI/local default tests 会变慢且不稳定。
- API key 不能出现在 logs、fixtures、错误消息、snapshots 中。
- 如果 M1 顺手实现 agent loop，会把 provider event API 和 app mode 耦合，必须留到 M2。

## 20. 后续衔接

M1 结束后，M2 可以直接消费：

```text
provider.Message
provider.ContentBlock
provider.ProviderEvent
provider.OpenAiCompatibleProvider.stream(request, sink)
provider.AnthropicParser.parseRecordedStream(...)
provider.AuthResolver
provider.Transport
```

M2 不应该再解析 provider-specific SSE/JSON；它只处理统一 `ProviderEvent`。
