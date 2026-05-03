# M5 Coding-Agent CLI Modes 实现方案

M5 在 M2 `core.agent` runtime、M3 built-in tools 和 M4 session foundation 之上，增加用户可见的 coding-agent 产品模式。目标是让 `pig --print "..."`、`pig --json --print "..."`、基础 interactive prompt loop 和 stdin/stdout RPC mode 复用同一个 runtime 组装路径，而不是为每种输出形态复制 agent loop。

## 目标

- 增加最小但稳定的产品 CLI parser，支持 print/json/interactive/rpc mode。
- `pig --print "..."` 能运行一次 agent turn，不依赖 TUI。
- `pig --json --print "..."` 只向 stdout 输出 JSONL events，适合外部程序消费。
- 基础 interactive mode 使用普通 stdin/stdout prompt loop，先不进入 raw terminal 或 TUI。
- RPC mode 使用 stdin/stdout JSONL protocol，暴露 start/send/abort/list/switch 和 inline event frames 的可测试骨架。
- CLI mode、JSON mode、RPC mode 共享同一个 runtime assembly：model client、tool registry、session recorder、event sinks、abort flag。
- M5 默认测试仍离线，不访问网络，不读取真实 API key。
- P0 CLI-mode integration tests 通过 test harness 注入 scripted model；真实 `zig build smoke` 不依赖这种注入。

## 非目标

- 不实现 M6 TUI：不进入 raw mode、不做 alternate screen、不做全屏 renderer。
- 不实现完整 slash command 体系；`/resume`、`/model` 等工作流命令属于 M7。
- 不做 cloud sync、web UI、Slack、plugin ecosystem 或 multi-agent workflow。
- 不把 provider parser/transport 细节放进 `app` 的输出 renderer。
- 不在 JSON/RPC 输出中泄露 API key、auth file 内容或 approval preview 以外的敏感配置。

## 当前前提和缺口

当前 main 已有：

- M2 runtime：`src/core/agent/runtime.zig`、state、events、model client、tool registry。
- M3 tools：`src/tools/registry.zig` 可把 built-in tools 适配给 `core.agent.ToolRegistry`。
- M4 foundation：`src/session/entry.zig`、`store.zig`、`tree.zig`，但还没有完整 session operations 和 runtime recorder adapter。
- Provider transport：request builder 和 recorded/parser harness 已有，live HTTP streaming transport 仍是 unsupported。

因此 M5 的实现不能假设完整 session resume/recorder 或 live transport 已存在。M5 需要先补一个最小 runtime assembly 层和最小 session adapter，再把产品模式接上。Live provider 可以作为 P1/optional；P0 必须用 scripted/recorded model client 保证离线验收可跑通。

## 模块边界

计划依赖方向：

```text
app -> core/provider/session/tools/rpc/util
app/modes -> app/runtime assembly -> core.agent
app/rpc_mode -> rpc protocol DTOs + core.agent events DTOs
rpc -> util
session -> util
tools -> util
core.agent -/-> app/tui/session/provider-specific transport
tui -/-> app modes for M5
```

`app` 可以负责 CLI 参数解析、模式选择、runtime 组装和 stdout/stderr 输出。`core.agent` 继续只暴露 provider-independent runtime contract。`session` 仍不依赖 `app`、`provider` 或 `tools` implementation details；M5 若需要持久化 runtime events，应通过 adapter 在 `app` 或 `core.agent` 附近转换。

建议新增文件：

```text
src/app/args.zig           M5 CLI parser
src/app/modes.zig          mode dispatcher
src/app/runtime.zig        runtime assembly/factory
src/app/output_text.zig    print/interactive text sink
src/app/output_json.zig    JSONL event sink
src/app/rpc_mode.zig       stdin/stdout RPC mode loop
src/app/session_runtime.zig session recorder adapter
src/rpc/messages.zig       RPC request/response DTOs and JSON helpers
test/cli_modes.zig
test/json_mode.zig
test/rpc_mode.zig
fixtures/app/*.jsonl       offline CLI/RPC fixtures
```

如果 `src/app/cli.zig` 过大，应只保留顶层 dispatch，把 parser、modes 和 output 拆出。

## CLI 语义

P0 flags：

```text
pig --print "prompt"
pig --json --print "prompt"
pig --interactive
pig --rpc
pig --cwd <path>
pig --provider <provider>
pig --model <model>
pig --thinking <off|low|medium|high|xhigh|max>
pig --no-tools
pig --include-p1-tools
pig --session <session-id-or-path>
pig --resume
pig --new-session
pig --ephemeral
```

兼容性规则：

- 没有 mode flag 时继续显示 help，直到 interactive 成为默认行为前不要改变现有 smoke 预期。
- `--json` 不是单独 mode；M5 P0 只允许它修饰 `--print`。
- `--print` 和 `--interactive`/`--rpc` 互斥。
- `--rpc` stdout 本身就是 JSONL protocol，不接受 `--json` 修饰，避免出现两层 JSON mode。
- `--json --interactive` 在 M5 P0 返回 usage error；后续如需 machine-readable interactive，应作为单独设计。
- `--resume`、`--new-session`、`--session` 互斥；`--ephemeral` 表示不写 session file。
- `--cwd` 必须 resolve 成绝对路径，并作为 tools workspace root 和 session cwd。
- `--thinking` 映射到 `core.agent.state.ThinkingLevel`。
- `--no-tools` 创建空 `ToolRegistry`；默认启用 P0 tools，`--include-p1-tools` 启用 grep/find/ls 等 P1 tools。

P1 flags：

```text
pig --system-prompt <text>
pig --config <path>
pig --max-iterations <n>
pig --approval <never|on-request|strict>
pig --provider-live
```

P1 可以后置，但 parser 设计不要阻塞这些 flag。

## Runtime Assembly

新增一个窄的 `RunConfig`：

```zig
RunConfig {
    cwd: []const u8,
    mode: Mode,
    output: OutputMode,
    provider: ProviderSelection,
    model: ?[]const u8,
    thinking: ThinkingLevel,
    session: SessionSelection,
    tools: ToolSelection,
    max_iterations: u32,
}
```

组装步骤：

1. 解析 CLI/RPC config。
2. resolve cwd/home/default paths。
3. resolve provider/model/auth。
4. 创建 `AgentState`。
5. 创建 model client：
   - P0 tests 使用 `ScriptedModelClient` 或 recorded provider fixtures。
   - P1 optional live 使用 provider request builder + transport + parser。
6. 创建 tool context 和 `BuiltinToolSet`。
7. 创建 event sink：
   - print mode：text sink + error sink。
   - JSON mode：JSONL event sink。
   - RPC mode：connection-owned event queue/sink。
   - session recorder：fanout sink 的一个分支。
8. 调用 `AgentRuntime.runUserText()`。
9. 按 runtime status 映射 exit code。

M5 应增加一个 fanout sink：

```zig
AgentEventFanout {
    sinks: []AgentEventSink,
}
```

任一 sink 拒绝事件时，runtime 仍应返回明确错误；session recorder 的失败不能静默吞掉。

## Provider/Model 策略

P0：

- 默认测试使用 scripted model，不读取 env。
- CLI integration test 可以通过 test-only context 注入 `ModelClient`，不需要网络。
- 如果用户运行真实 CLI 且没有配置 live provider，输出 actionable error：
  - text mode 写 stderr。
  - JSON mode 输出 `error` event 后 exit nonzero。

P1：

- 增加 `ProviderModelClient`，把 `ModelRequest` 转成 provider request。
- OpenAI-compatible request builder 必须补 tool definitions、tool result message、multi-block text/thinking/image ref 的最小可用序列化，否则 M3 tools 无法在真实 provider 下工作。
- 只有 `PIG_PROVIDER_LIVE=1` 或明确 flag 时才访问网络。
- Authorization header 绝不进入 logs、JSON events、session entries。

## Session 接入

M5 P0 需要补齐 M4 的最小可用操作：

- `session.openByIdOrPath`
- `session.resumeLatest(cwd)`
- `session.listByWorkingDirectory(cwd)`
- `session.createForCwd(cwd)`
- `session.ephemeral`

M5 不需要完整 session tree UI，但 print/json/rpc mode 应能：

- 新建 session 并写 header/user/assistant/tool entries。
- `--resume` 当前 cwd latest session。
- `--session` 按 ID/path 打开。
- `--ephemeral` 完全不写文件，测试和短命令可用。

Recorder adapter 必须持有 `AgentState` 指针或等价 state reader；单纯 `AgentEventSink` 参数不包含完整消息状态，无法在 turn end 做 message diff。

```zig
SessionRecorderSink {
    state: *AgentState,
    store: ?*SessionStore,
    onToolExecutionStart(...) -> tool_event(start)
    onToolExecutionDelta(...) -> tool_event(update)
    onToolExecutionEnd(...) -> tool_event(end) + tool_result
    onTurnEnd(state_before_count, AgentState.messages) -> message entries for newly appended user/assistant/tool messages
    onAgentEnd(...) -> session_info(current_leaf_id)
}
```

注意：不要仅从 event delta 重建 assistant message；这样容易丢 thinking/tool call block。P0 recorder 应记录 turn 开始前的 `AgentState.messages.len`，在 turn end 读取新增 owned messages，并由 adapter 转换 provider-owned message 到 session DTO。tool progress/result event 仍可以即时追加为 `tool_event`/`tool_result`。

`--ephemeral` 时不要创建落盘 `SessionStore`；可以使用 no-op recorder 或 in-memory recorder。这样 JSON/RPC events 仍正常输出，但不会在 `~/.pig/agent/sessions` 下创建文件。

## Print Mode

行为：

- stdout 只输出 assistant final text。
- stderr 输出 diagnostics、tool progress 和 errors。
- tool result JSON 不直接打印到 stdout，除非后续 flag 要求 verbose。
- runtime 成功 exit 0；provider/tool/parse/max-iteration/abort exit nonzero。
- `--json` 修饰时 stdout 只输出 JSONL events，不输出 plain text。

P0 text sink：

- 收集 `message_delta.text_delta` 到 stdout，或在 turn end 从 final assistant message 输出。
- 避免 JSON mode 和 text mode 同时写 stdout。
- 如果 assistant 没有 text block 但有 tool call，继续 runtime loop，不提前结束。

## JSON Mode

JSONL 每行一个 object。P0 event schema：

```json
{"schema":1,"type":"agent_start","session_id":"..."}
{"schema":1,"type":"turn_start","session_id":"...","text":"..."}
{"schema":1,"type":"message_delta","role":"assistant","text_delta":"..."}
{"schema":1,"type":"tool_start","id":"call_1","name":"read","arguments_json":"{}"}
{"schema":1,"type":"tool_end","id":"call_1","name":"read","is_error":false,"content_json":"{\"ok\":true}"}
{"schema":1,"type":"error","category":"provider","message":"...","retryable":false}
{"schema":1,"type":"turn_end","status":"completed"}
{"schema":1,"type":"agent_end","status":"completed"}
```

规则：

- stdout 只能包含 JSONL，不混入 help、warnings 或 progress。
- 每行必须是 parseable JSON object。
- `arguments_json` 和 `content_json` 作为 JSON string 保存，避免重新解释工具私有 schema。
- 错误也输出 JSON event，再返回 nonzero。
- schema version 从 1 开始，未知字段允许消费者忽略。

## Interactive Mode

P0 是普通 prompt loop：

```text
pig> user input
assistant output
pig> ...
```

规则：

- 使用 cooked terminal/stdin line input，不进入 raw mode。
- EOF 正常退出 0。
- 空输入跳过。
- 每个 user input 运行一个 turn，复用同一个 session 和 AgentState。
- 支持 `exit`/`quit` 作为 P0 退出命令；slash commands 后续 M7 再扩展。
- `--json --interactive` 在 M5 P0 不支持，parser 返回 usage error。machine-readable interactive 输出后续单独设计。

## RPC Mode

stdin/stdout JSONL protocol。P0 request：

```json
{"id":"1","method":"start","params":{"cwd":"/repo","ephemeral":true}}
{"id":"2","method":"send_message","params":{"text":"hello"}}
{"id":"3","method":"abort","params":{}}
{"id":"4","method":"list_sessions","params":{"cwd":"/repo"}}
{"id":"5","method":"switch_session","params":{"session_id":"session_..."}}
```

P0 response：

```json
{"id":"1","ok":true,"result":{"session_id":"session_..."}}
{"id":"2","ok":true,"result":{"status":"completed"}}
{"id":"2","event":{"schema":1,"type":"message_delta","text_delta":"hi"}}
{"id":"3","ok":false,"error":{"code":"not_running","message":"no active turn"}}
```

规则：

- stdout 只输出 JSONL。
- 每个 request 必须有 string `id`。
- `event` frames 关联原 request id。
- M5 P0 不增加单独 `read_event_stream` 方法；`send_message` 运行期间直接向 stdout 发送关联同一 request id 的 `event` frames。独立事件订阅/回放可以留到 M11 RPC 完整性。
- P0 可以串行处理请求；并发 turn 后置。
- `abort` P0 可以设置 abort flag；如果没有 active run，返回 `not_running`。
- malformed JSON 返回 `invalid_request` frame，不 panic。

## 错误和 Exit Code

沿用 `docs/error-model.md`：

- `0`：成功。
- `1`：agent/provider/tool/session 运行失败。
- `2`：CLI usage。
- `70`：内部错误。

M5 应增加统一映射：

```zig
AgentRunError -> ExitCode
SessionError -> ExitCode.failure
ArgParseError -> ExitCode.usage
AllocatorError unexpected -> ExitCode.internal
```

JSON/RPC mode 的错误需要同时进入 machine-readable event/frame。

## 实现切片

### Slice 0: 补 M4 最小可用 Session Operations

- 增加 open by ID/path、resume latest、list by cwd、create for cwd、ephemeral。
- 增加 deterministic session ID/entry ID generator，测试可注入 seed/counter。
- 增加 `SessionRecorderSink` 或等价 adapter。
- 测试：create/resume/list、recorder 持久化 user/assistant/tool result、ephemeral 不写文件。

### Slice 1: CLI Parser 和 Mode Dispatch

- 新增 `src/app/args.zig`。
- 解析 `--print`、`--json`、`--interactive`、`--rpc`、`--cwd`、provider/model/thinking/session/tools flags。
- 保持 `--version`、`--help`、`doctor`、`paths` 兼容。
- 测试互斥 flags、usage errors、default help。

### Slice 2: Runtime Assembly

- 新增 `src/app/runtime.zig`。
- 建立 `RunConfig`、`RunContext`、tool registry setup、event sink fanout。
- P0 支持 test/scripted model injection。
- P1 增加 provider model client factory。
- 测试：print/json/rpc 都使用同一个 assembly path。

### Slice 3: Print Mode

- 实现 `pig --print "..."`。
- 支持 tools on/off。
- stdout plain assistant text；stderr diagnostics。
- exit code 映射。
- 离线 integration test：scripted provider 返回文本；scripted provider 触发 tool call 并继续。

### Slice 4: JSON Mode

- 实现 `--json --print` JSONL event sink。
- 定义 event schema 1。
- 确保 stdout 无非 JSON 内容。
- 测试每行 parseable、tool/error/status events 机器可读。

### Slice 5: Basic Interactive Mode

- 实现 cooked stdin prompt loop。
- 支持 EOF、empty input、`exit`/`quit`。
- 复用 session 和 AgentState。
- 测试使用 in-memory stdin/stdout fixture，不依赖 terminal raw mode。

### Slice 6: RPC Mode

- 实现 stdin/stdout JSONL request/response loop。
- 协议 DTO 和 JSON 编码放在 `src/rpc/messages.zig`；`src/app/rpc_mode.zig` 只负责进程 IO 和 runtime 调度。
- 支持 start/send_message/abort/list_sessions/switch_session。
- P0 串行处理。
- 测试 malformed request、successful send、event frames、session list。

### Slice 7: Optional Live Provider Path

- 实现或接入 live streaming transport。
- OpenAI-compatible request builder 补 tool definitions/tool result message。
- live smoke 仍必须显式 opt-in。
- 不阻塞 P0 offline acceptance；若 live 未实现，CLI 对真实 provider 给出清晰错误。

## 测试计划

单元测试：

- args parser：mode/flag 组合、互斥、defaults。
- JSON event encoder：每个 event parseable，schema/type/status 字段稳定。
- RPC parser/encoder：valid/malformed request。
- exit code mapping。
- session recorder conversion。

Integration tests：

- `pig --print "hello"` 使用 injected scripted model 输出 plain text。
- `pig --json --print "hello"` stdout 只包含 JSONL。
- print mode tool call：scripted model 调用 `read`，tool result 进入下一轮。
- tool failure/provider failure 返回 nonzero，并在 JSON mode 输出 error event。
- interactive fixture：两行输入、EOF 退出。
- RPC fixture：start + send_message + list_sessions。

Build steps：

- 新增 `zig build cli-modes`。
- 将 mode tests 纳入 `zig build test`。
- 保持 `zig build smoke` 离线，只运行真实 CLI 能自洽完成的命令，例如 `--version`、`--help`、`doctor`、`paths`。`pig --print` 的 scripted/offline 覆盖放在 `zig build cli-modes`，除非 M5 明确增加一个受测试保护的 fixture provider flag。

Fixtures：

```text
fixtures/app/print-text.jsonl
fixtures/app/print-tool-turn.jsonl
fixtures/app/json-mode.golden.jsonl
fixtures/app/rpc-basic.jsonl
```

Fixture 不能包含真实 prompt、API key、用户 session 或机器私有路径。

## 验收清单

- `zig build test` 通过，不访问网络。
- `zig build cli-modes` 通过。
- `zig build smoke` 通过。
- `pig --print "..."` 在 offline/scripted test path 中可完成 no-tool prompt。
- `pig --json --print "..."` stdout 只输出 JSONL events。
- JSON mode 的每一行都能被 `std.json` parse。
- RPC mode 可由外部进程通过 stdin/stdout JSONL 驱动一个 turn。
- print/json/interactive/rpc 复用同一 runtime assembly。
- session recorder 能把 user/assistant/tool result 持久化为 M4 session entries。
- 无 API key、auth headers 或真实用户 session 写入 repo、stdout JSON events 或测试 fixtures。

## 风险和防线

- 如果 print/json modes 各自手写 runtime loop，后续行为会分叉。用 `app/runtime.zig` 统一组装。
- 如果 JSON mode 混入 human diagnostics，会破坏外部集成。JSON mode 下 stderr 和 stdout 必须严格分工。
- 如果 M5 直接依赖未完成的 live transport，会让 P0 无法离线验收。P0 使用 scripted/recorded model；live 放 P1。
- 如果 session recorder 从 delta 拼消息，容易丢 thinking/tool call block。优先在 turn end 从 `AgentState.messages` 转换新增 owned messages。
- 如果 CLI parser 无结构，M7 slash commands 和 M6 TUI 会复用困难。M5 parser 应输出结构化 `RunConfig`。
