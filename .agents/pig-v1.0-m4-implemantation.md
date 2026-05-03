# M4 Session Store 和 Context Tree 实现方案

M4 在 M2 agent runtime 和 M3 coding tools 之上增加本地持久化 session 与 context tree。目标是让 Pig 在重启后可以恢复最近工作流，可以从历史 entry 分支继续，并且持久化层不耦合终端渲染。

## 目标

- 将 session 存为全局 sessions 目录下的 append-only JSONL 文件。
- 将对话历史表示为树，而不是简单线性 transcript。
- 启动时从 JSONL 重建内存索引。
- 使用稳定 ID 持久化 user、assistant、provider、tool、config、label 和自定义工作流事件。
- 能从进程崩溃和 partial final line 中干净恢复。
- 保持 `session` 独立于 `app`、`tui`、provider-specific parser 和产品 CLI 渲染。

## 非目标

- 不引入数据库依赖。
- 不做 cloud sync 或远程 session 服务。
- 不实现完整的 session tree 浏览 UI；后续 CLI 命令可以先暴露最小诊断能力。
- 第一阶段不实现 compaction，只定义 entry 类型和可接入 compaction 的 hook 位置。
- M4 不做加密或 secret store。Session 记录不能包含 API key 或 auth material。

## 模块边界

计划依赖方向：

```text
app -> session
core.agent -> session adapter interfaces only
session -> util/json and util/paths
session -/-> app, tui, provider, provider parsers, tools implementation details
```

`session` 定义自己的持久化 message DTO，覆盖 M4 需要保存的 text、image reference、thinking、tool call、tool result 等 content block。`core.agent` 负责在 `provider.ContentBlockView`/`AgentState` 和 session DTO 之间转换。这样可以保持当前架构中的 `session -> util` 方向，不让 session 直接依赖 provider。`session` 不决定 TUI 如何展示分支，也不解析 provider SSE。

## 文件布局

默认路径：

```text
~/.pig/agent/sessions/
  index.json          可选的后续 cache，不作为权威数据
  <session-id>.jsonl  权威 append-only log
```

M4 中 JSONL 文件是权威数据。任何 cache 都必须可以重建，不能成为正确性前提。

M4 Slice 0 需要迁移 path resolver：全局 config/auth/models/sessions 和 project resources 使用 `.pig` 命名空间，并更新 CLI diagnostics、路径测试和文档，避免 session store 写入旧 `.pi` 命名空间。当前实现已将 `src/util/paths.zig` 和 `src/session/mod.zig` 的默认路径迁到 `.pig`。

Session ID 后续应尽量复用 `core.ids` 的方向；在该模块稳定前，可以先实现一个小型 session-local ID generator，并配套测试和 deterministic fixture 支持。

## JSONL 格式

每一行是一个 JSON object。每个持久化 entry 都有公共字段。Header/root entry 示例：

```json
{
  "schema": 1,
  "id": "entry_root",
  "session_id": "session_...",
  "parent_id": null,
  "kind": "header",
  "created_ms": 1760000000000
}
```

普通 child entry 示例：

```json
{
  "schema": 1,
  "id": "entry_child",
  "session_id": "session_...",
  "parent_id": "entry_root",
  "kind": "message",
  "created_ms": 1760000000000
}
```

规则：

- `id` 在单个 session 内唯一。
- `parent_id` 只有 header/root entry 可以为 null。
- Entry append-only；更新操作用新 entry 表示。
- Reader 必须忽略未知字段。
- Reader 对已知 `kind` 的缺失必需字段或错误 shape 给出清晰错误。
- 恢复时忽略无法解析的 final partial line，除非它能被解析为完整 JSON object。

## Entry 类型

P0 entry kinds：

- `header`：session metadata、cwd、Pig version、schema version。
- `message`：provider-compatible role/content blocks。
- `tool_event`：tool execution start/update/end metadata。
- `tool_result`：和 tool call ID 关联的 canonical tool result JSON。
- `model_change`：provider/model 选择变化。
- `thinking_level_change`：runtime thinking setting 变化。
- `session_info`：title、working directory、timestamps、current leaf。
- `label`：附着到 entry 的用户可见标签。
- `branch_summary`：某个 branch 的 summary text。
- `compaction`：压缩后的 history payload 或 summary placeholder。
- `custom`：向前兼容的扩展 entry。

建议的 P0 payload shape：

```json
{"kind":"message","role":"user","content":[{"type":"text","text":"..."}]}
{"kind":"tool_event","tool_call_id":"call_1","tool_name":"read","phase":"start"}
{"kind":"tool_result","tool_call_id":"call_1","is_error":false,"content_json":"{\"ok\":true}"}
{"kind":"model_change","provider":"openai_compatible","model":"..."}
{"kind":"thinking_level_change","level":"medium"}
{"kind":"label","text":"before refactor"}
```

Content block 使用 session 自己的持久化 DTO 表达同等语义，不直接引用 provider 类型。`core.agent` 负责在 runtime/provider view 和 session DTO 之间转换，这样 replay 到 `AgentState` 仍然直接，同时保持模块边界清晰。

## Context Tree 模型

内存中重建：

```zig
SessionTree {
    entries_by_id: StringHashMap(EntryIndex),
    children_by_parent: StringHashMap([]EntryId),
    root_id: EntryId,
    current_leaf_id: EntryId,
}
```

校验规则：

- 每个 session 文件必须恰好有一个 header/root entry。
- Unknown parent ID 默认产生可恢复的 load error。
- Duplicate ID 是 load error。
- `current_leaf_id` 优先取最后一个有效 `session_info` entry；否则取最后 append 的 entry。
- 从历史 entry 分支时，新增 child 的 `parent_id` 指向被选择的历史 entry。

## Session 操作

P0 操作：

- `create`：分配 session ID，写入 header，返回 handle。
- `open`：按 path 或 ID 加载 session，并重建 tree index。
- `resumeLatest`：选择当前 cwd 下最新 session。
- `listByWorkingDirectory`：扫描 session header/session_info entries。
- `append`：追加一个 entry，并更新内存索引。
- `branchFrom`：设置下一次 append 的 pending parent/current leaf。
- `export`：导出稳定 JSON 或 JSONL 副本，不包含 secrets。
- `rename`：追加带 title 更新的 `session_info`。
- `ephemeral`：只保留内存 tree，不写文件。

P1 操作：

- `pruneCache`：移除非权威 index cache。
- `repair`：发现 trailing corruption 后，将有效前缀复制到 repaired file。
- `summarizeBranch`：使用调用方提供的文本追加 `branch_summary`。

## Crash Safety

M4 使用保守 append 策略：

1. 以 append mode 打开 session file。
2. 将一个完整 JSON object 序列化到内存。
3. 写入 object bytes。
4. 写入 `\n`。
5. Flush file。
6. 按 policy fsync。

Fsync policy：

- 默认：header 后 fsync，turn end 后 fsync。
- Strict option：每个 entry 后 fsync。
- 测试/ephemeral fast option：只 flush。

恢复策略：

- 逐行读取。
- 只解析完整行。
- 如果 final line 没有 trailing newline 且解析失败，忽略它并报告 `partial_final_line`。
- 如果非 final line 解析失败，返回带 line number 的 corruption error。

## Agent Runtime 接入

第一阶段不要让 `AgentRuntime` 直接持有文件句柄。增加一个窄的 sink/recorder abstraction：

```zig
SessionRecorder {
    onUserMessage(...)
    onAssistantMessage(...)
    onToolEvent(...)
    onToolResult(...)
    onRunEnd(...)
}
```

初始接入路径：

1. 保持 runtime 行为不变。
2. 增加测试，将现有 `AgentEvent` 和 `AgentState` 变化转换为 session entries。
3. session 模块独立测试稳定后，再增加可选 recorder field 或 middleware adapter。

这样可以避免 M4 破坏 M2 runtime 语义。

## 测试计划

单元测试：

- 每个 P0 kind 的 entry JSON round trip。
- 忽略未知字段。
- Duplicate ID load 失败。
- Missing parent load 失败。
- Partial final line recovery。
- Header-only session 可以加载。
- Branch append 能重建正确 child index。
- `current_leaf_id` 跟随最后一个 `session_info`。

Fixture tests：

- `fixtures/session/simple-linear.jsonl`
- `fixtures/session/tool-turn.jsonl`
- `fixtures/session/branched.jsonl`
- `fixtures/session/partial-final-line.jsonl`

Build steps：

- 增加 `zig build session-fixtures`。
- 将 session tests 纳入 `zig build test`。

## 实现切片

### Slice 1: Data Model

- 增加 `src/session/entry.zig`。
- 定义 entry union、common metadata、schema version 和 parse errors。
- 使用 structured `std.json` APIs 序列化/解析 JSON，必要时复用现有 util helpers。
- 为所有 P0 entry kinds 增加单元测试。

### Slice 2: Append Store

- 增加 `src/session/store.zig`。
- 实现 create/open/append，底层使用 append-only JSONL。
- 增加 fsync policy 和适合测试的 flush-only policy。
- 增加 partial final line recovery。

### Slice 3: Tree Index

- 增加 `src/session/tree.zig`。
- 从 entries 重建 indexes。
- 实现 current leaf 和 branch parent selection。
- 增加 branch fixtures。

### Slice 4: Session Operations

- 增加 list/resume latest/open by ID/export/rename/ephemeral。
- 保持 path-based 和 local-first。
- 基于 header/session_info metadata 增加 cwd filtering。

### Slice 5: Runtime Adapter

- 增加用于 agent messages/tool events 的 session recorder adapter。
- 将 M3 tool results 持久化为 `tool_result` entries。
- 增加 scripted provider + built-in tools 的 integration test。

## 验收清单

- `zig build test` 不依赖网络或 API key，并且通过。
- `zig build session-fixtures` 通过。
- Session 可以 create、append、close、reopen，并 replay 成等价 tree。
- 重启后可以 resume 当前 cwd 的 latest session。
- 可以从历史 entry branch 出新路径，且不重写旧行。
- Partial final line 不阻止加载有效前缀。
- M3 registry 的 tool results 会持久化为 session entries。
