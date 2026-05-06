# M8 Slash Commands 和 Workflow Features 实现方案

M8 在 M4 session store/context tree、M5 CLI mode assembly、M6 interactive TUI foundation 和 M7 config/auth/models/resources loading 之上，实现 Pig 的交互式工作流层。目标是把当前 interactive 从“可输入的 chat loop”推进到可发现、可恢复、可切换模型、可导航历史、可压缩长会话的本地 coding-agent CLI。

M8 的重点是 command framework、session workflow、message queue、manual/automatic compaction 的数据路径，以及为 M9 prompt/skill/theme commands 留出注册接口。M8 不应该把 command system 做成 plugin runtime，也不应该让 session/tree 逻辑泄漏进 TUI renderer。

## 目标

- 建立稳定的 slash command framework：解析、metadata、help/autocomplete 数据、handler 调度、错误呈现。
- 完整接管 M7 的 `/reload`，从特殊字符串判断迁移到 command registry。
- 实现 roadmap 内置 commands：`/login`、`/logout`、`/model`、`/scoped-models`、`/settings`、`/resume`、`/new`、`/name`、`/session`、`/tree`、`/fork`、`/compact`、`/copy`、`/export`、`/reload`、`/hotkeys`、`/changelog`、`/quit`、`/exit`。
- 为 `/login`、`/logout` 提供 local-first auth helper 入口，但不实现 OAuth/browser login。
- 支持 `/scoped-models`，基于 M7 model registry 展示 enabled/scoped model，并为 `/model` selector/autocomplete 提供同一份数据。
- 支持 shell shortcuts：`!command` 执行并把结果追加到上下文，`!!command` 执行但只显示结果、不进入上下文。
- 实现 interactive message queue：busy turn 期间保留 queued user input、steering message、follow-up message，并支持 abort 后恢复未发送输入。
- 实现 session workflow：resume latest/open by id/path/new/name/session summary/tree/fork/export。
- 实现 compaction workflow：manual `/compact`、context-window threshold 检测和可配置触发、structured compaction entry。
- 默认测试离线，不读取真实 API key，不访问网络，不依赖真实 tty。

## 非目标

- 不实现 M9 skills/prompt templates/themes/packages 的执行；M8 只为 command registration/autocomplete 留扩展点。
- 不实现 M10 external plugin command registration。
- 不实现 OAuth、browser login、secure keychain；`/login` P0 只做 env/auth JSON guidance 或受控 auth JSON helper。
- 不实现 Web UI、Slack、pods、多 agent workflow。
- 不把 command handler 放进 `tui`，也不让 `session` import `app`。
- 不把 compaction 做成高质量长期记忆系统；M8 只实现可测试的 summary request、entry 写入和继续对话路径。
- 不把 shell shortcut 结果默认当作 tool result；它是用户上下文注入，真实 bash tool 仍走 M3 工具和 approval 策略。

## 当前前提和缺口

当前 main 已有：

- `src/app/interactive.zig` 支持 scripted/live interactive、agent worker、event queue、Ctrl+C abort，以及 M7 的硬编码 `/reload`。
- `src/app/runtime.zig` 已能创建新 session 或显式打开 session，但 print mode resume 仍返回 `session resume is not implemented in M7 print mode`。
- `src/app/session_runtime.zig` 能把 agent events fanout 到 session recorder，turn end 后追加 message/tool entries。
- `src/session/entry.zig` 已有 `model_change`、`thinking_level_change`、`session_info`、`label`、`branch_summary`、`compaction` entry 类型。
- `src/session/store.zig` 支持 create/open/append/current leaf，`src/session/tree.zig` 支持 rebuild 和 branchFrom。
- `src/resources/models.zig` 和 `src/app/config_runtime.zig` 已提供 model registry/runtime config 基础。
- `tui/components.zig` 已有 select/settings 类组件基础，但 interactive frame 当前仍是简单 transcript 行输出。

M8 需要补齐：

- command registry 和 parser，替换 interactive 中对 `/reload` 的特判。
- session listing/resume latest/export/name/tree/fork helpers。
- command 对 session recorder/current leaf/model state 的可控写入。
- model switching 后的 `model_change` session entry 和下一 turn model client replacement。
- compaction request 构造、summary entry 写入、state rewrite 策略。
- busy turn 期间 queued input 的一致语义。

## 模块边界

计划依赖方向：

```text
app -> resources/provider/core/session/tools/tui/util
session -> util
resources -> util
tui -> util
core.agent -/-> app/tui/resources
session -/-> app/tui/resources/provider/tools
tui -/-> app/core/provider/session/tools/resources
```

职责划分：

- `app/commands.zig`：command metadata、registry、parser、dispatch DTO。
- `app/command_handlers.zig`：通用 command handler glue，调用 session/model/resources/shell/compaction 子模块。
- `app/session_commands.zig`：resume/list/name/tree/fork/export 相关 app-level helper。
- `app/model_commands.zig`：`/model`、`/scoped-models`、model switch 和 model client replacement。
- `app/auth_commands.zig`：`/login`、`/logout` 的 local auth helper 和非 secret diagnostics。
- `app/compaction.zig`：manual/auto compaction planner、summary prompt、state/session rewrite helper。
- `app/message_queue.zig`：busy turn queue、steering/follow-up/abort restore 状态机。
- `app/shell_shortcuts.zig`：`!`/`!!` 解析、approval、执行、result-to-context mapping。
- `session/query.zig`：list latest/open ref/title/export/tree summary 的纯 session helper。
- `tui/components.zig`：仅扩展 command picker/select/settings list 渲染 DTO，不 import app command handler。

建议新增文件：

```text
src/app/commands.zig
src/app/command_handlers.zig
src/app/session_commands.zig
src/app/model_commands.zig
src/app/auth_commands.zig
src/app/compaction.zig
src/app/message_queue.zig
src/app/shell_shortcuts.zig
src/session/query.zig
test/commands_parse.zig
test/commands_registry.zig
test/interactive_commands.zig
test/interactive_message_queue.zig
test/session_query.zig
test/session_workflow_commands.zig
test/model_commands.zig
test/shell_shortcuts.zig
test/compaction.zig
```

如果早期实现切片需要收敛文件数量，可以先把 `command_handlers.zig` 和 `session_commands.zig` 合并；但 command parser/registry 应独立，避免 interactive runner 继续膨胀。

## Command Framework

Command registry 是 M8 的中心数据结构。它既服务 dispatch，也服务 `/hotkeys`、help、autocomplete 和 M9 后续动态 prompt commands。

建议 DTO：

```zig
pub const CommandKind = enum {
    login,
    logout,
    model,
    scoped_models,
    settings,
    resume,
    new_session,
    name,
    session,
    tree,
    fork,
    compact,
    copy,
    export,
    reload,
    hotkeys,
    changelog,
    quit,
    exit,
};

pub const CommandSpec = struct {
    name: []const u8,
    aliases: []const []const u8 = &.{},
    summary: []const u8,
    usage: []const u8,
    category: CommandCategory,
    available_when_busy: bool = false,
    hidden: bool = false,
};

pub const ParsedCommand = struct {
    name: []const u8,
    argv: []const []const u8,
    raw: []const u8,
};
```

解析规则：

- 只有 trim 后第一个字符是 `/` 的输入才进入 slash parser。
- `//text` 作为普通 user message，内容为 `/text`，避免无法发送以 slash 开头的消息。
- command name 到第一个 whitespace 结束，大小写敏感，P0 全小写。
- 参数 P0 支持 shell-like quotes 和 backslash escape；不要引入外部 parser。
- Unknown command 显示可修复错误，并建议 `/hotkeys` 或最接近命令。
- Handler 返回 `CommandResult`，由 interactive runner 统一渲染和决定是否发起 agent turn。

`CommandResult` 建议：

```zig
pub const CommandResult = union(enum) {
    status: []const u8,
    error_message: []const u8,
    exit,
    reload_resources,
    switch_model: ModelSwitch,
    open_session: SessionOpenResult,
    start_new_session: SessionOpenResult,
    replace_transcript: TranscriptSnapshot,
    append_user_context: []const u8,
    compacted: CompactionResult,
};
```

command framework 不直接写 terminal。它只返回普通结果；`app/interactive.zig` 决定如何追加 transcript、刷新 frame、替换 current runtime state。

## Command 语义

### `/model`

用途：

- 无参数：展示当前 model 和可选 models。
- 有参数：切换当前 interactive model，下一 turn 使用新 model client。

规则：

- 使用 M7 `ResourceSnapshot`/`ResolvedRuntimeConfig` 中的 enabled model list。
- 切换时调用 `app/model_factory.zig` 创建新 model client；auth 缺失返回可读错误，不改变当前 model。
- 成功切换后追加 `model_change` session entry。
- 当前 active turn 忙时不允许切换；返回 `model switch unavailable while turn is running`。
- `/model <id>` 优先按 registry id 查找；`/model --provider <provider> --model <name>` 可构造 transient entry，但不写入 models.json。

### `/scoped-models`

用途：

- 展示 global/project/transient 可用模型和 disabled/collision warnings。
- P0 可以只输出文本列表；TUI selector 后续可复用同一个 DTO。

规则：

- 不读取 provider auth secret。
- disabled models 默认显示为 disabled，不允许选择。
- collision warning 带 source path。

### `/settings`

用途：

- 展示 effective settings、resource paths、warnings。

规则：

- 不输出 API key、完整 system prompt、完整 context file 内容。
- 可以输出 context file path、byte count、selected model、thinking level、tools enabled。
- P0 不实现 settings edit UI。

### `/reload`

M8 把 M7 `/reload` 迁入 command registry。

规则沿用 M7：

- 不发起 agent turn。
- 重新读取 settings/models/context/resource metadata。
- 更新下一 turn 的 system prompt 和 model selection。
- 如果当前模型被删除或 disabled，保留旧模型并显示 warning，除非用户显式 `/model`。

### `/resume`

用途：

- 无参数：resume 当前 cwd 最近 session。
- 有参数：按 session id 或 JSONL path 打开 session。

规则：

- 使用 `session/query.zig` 扫描 `~/.pig/agent/sessions`。
- 只按 header/session_info 中 cwd 匹配当前 workspace；`/resume --all` 才显示其他 cwd。
- 打开 session 后重建 `AgentState` 和 transcript view。
- 如果 session 中的 model 不存在，使用当前 default model 并显示 warning，同时追加 `model_change` entry。
- active turn 忙时不允许 resume。

### `/new`

用途：

- 创建新 session 并清空当前 transcript/agent state。

规则：

- 当前 session 如果有未 flush turn，先 finishTurn。
- 新 session header 写入 cwd、version、created time。
- 不删除旧 session。
- 支持 `/new --ephemeral` 只清空状态，不创建 store。

### `/name`

用途：

- `/name <title>` 设置当前 session title。
- 无参数显示当前 title。

规则：

- 写入 `label` 或 `session_info.title` entry；M8 应选择一种权威 entry。建议 P0 用 `session_info.title`，`label` 留给节点标签。
- title 不参与路径，不需要 sanitize 成文件名。

### `/session`

用途：

- 展示当前 session id/path/title/cwd/current leaf/model/message count。

规则：

- 不输出完整消息内容。
- ephemeral session 显示 `ephemeral`。

### `/tree`

用途：

- 展示当前 session tree 的 compact outline。

规则：

- 输出 entry id、kind、role/title/summary 的短摘要、当前 leaf marker。
- P0 文本 outline 即可，后续 TUI tree selector 复用 `TreeViewRow` DTO。
- 支持 `/tree <entry-id>` 展示该节点附近上下文。

### `/fork`

用途：

- 从当前 leaf 或指定 entry fork 到新 session 或当前 session 新分支。

规则：

- `/fork <entry-id>`：在当前 session 中把 current leaf 指向该 entry，下一条 user message 从该 entry 追加。
- `/fork <entry-id> --new-session`：复制从 root 到 entry 的路径到新 JSONL session，后续写入新文件。
- 放弃原分支时如果存在未合并分支，必须追加 `branch_summary`。P0 可以先生成 deterministic summary，例如 abandoned branch 的 entry range、message count 和最后一条短摘要；`--summarize` 或后续 compaction 再升级为 model-generated summary。
- active turn 忙时不允许 fork。

### `/compact`

用途：

- 对当前 session 到 current leaf 的上下文生成结构化 summary，并用 compacted state 继续。

规则：

- Manual `/compact` 调用当前 model 生成 summary；测试中使用 scripted model。
- 写入 `compaction` entry，包含 `target_id` 和 summary。
- AgentState 重建为：system prompt + compact summary as assistant/system context + recent uncompressed tail。
- Session JSONL 不删除历史 entry；compaction 是 append-only entry。
- 如果 model unavailable，返回错误，不修改 state。

P0 summary prompt 应稳定、短小、provider-agnostic。不要把 provider-specific SSE 或 raw tool logs 直接塞进 prompt；从 `AgentState` 或 session DTO 构造简洁 transcript。

### `/copy`

用途：

- 复制最近 assistant response、当前 session id、或指定 entry 摘要。

规则：

- 因 Zig/terminal clipboard 跨平台复杂，P0 可以提供 OSC 52 opt-in，并在不支持时显示文本 fallback。
- 不默认复制 secret/system prompt。
- 测试验证 payload 构造，不依赖系统 clipboard。

### `/export`

用途：

- 导出当前 session 为 JSONL 或 Markdown。

规则：

- 默认写到用户指定路径：`/export path.md` 或 `/export path.jsonl`。
- 不覆盖已有文件，除非 `--force`。
- Markdown export 包含 messages、tool summary、compaction summary、model changes。
- JSONL export 可复制原 session file 或从 store entries 重写。
- 不导出 auth/config secret。

### `/hotkeys`

用途：

- 展示 commands、shell shortcuts、keyboard behavior。

规则：

- 内容来自 `CommandSpec` 和 keybinding metadata，不能手写散落在 UI。

### `/changelog`

用途：

- 展示 Pig v1.0 当前 milestone 摘要或最近内置 changelog。

规则：

- P0 可读取内置静态文本，或显示 README 中当前 milestone 摘要的短版本。
- 不访问网络。

### `/quit` 和 `/exit`

规则：

- 没有 active turn 时退出 interactive。
- 有 active turn 时第一次请求 abort，第二次确认退出可以直接退出；P0 可先要求用户等待 abort 完成。
- 退出前 flush session store。

### `/login` 和 `/logout`

M8 不实现 OAuth。P0 local-first 行为：

- `/login` 展示当前 provider 需要的 env var 和 auth JSON path。
- `/login <provider>` 展示指定 provider 的 env/auth JSON guidance。
- `/login <provider> --api-key-stdin` 可以在测试和非 echo secret input 完成后写入 auth JSON；如果没有 hidden input 支持，真实 TUI 先返回 unsupported，避免 API key 出现在 transcript。
- `/logout <provider>` 从 auth JSON 删除该 provider key，或显示需要手动删除的路径。

规则：

- API key 不写入 session，不出现在 transcript、doctor、export。
- 测试只使用 tmp HOME/auth JSON。
- 如果实现 auth JSON writer，必须 preserve 其他 providers，并用 restricted file permissions where supported。

## Shell Shortcuts

解析：

- `!command`：执行 shell command，并把 stdout/stderr summary 作为 user context 追加到当前 turn 或 queued follow-up。
- `!!command`：执行 shell command，只显示结果，不进入 agent context。
- `!` 后空命令返回 usage error。
- `!!!` 不做特殊扩展，按 `!!` + command `!` 处理或返回 invalid，行为必须测试固定。

执行边界：

- 使用 M3 `tools.bash` 的 path policy、timeout、output truncation、approval preview。
- interactive 下如果 approval policy 是 deny-all，则返回 approval required，不静默执行 risky command。
- `!` result-to-context 格式稳定：

```text
Shell command: <command>
Exit code: <code>
Output:
<truncated output>
```

Session 行为：

- `!command` 追加为 user message 或 custom `shell_context` entry；建议 P0 追加 user message，保持 core runtime 简单。
- `!!command` 只追加 transcript status，不写入 agent messages；是否写 session custom entry 可后置。

## Message Queue

M6 已有 active turn worker 和 event queue；M8 需要定义用户输入在 busy turn 期间的语义。

队列类型：

- `queued_prompt`：用户在 busy turn 时提交的普通 prompt，当前 turn 结束后自动作为下一 turn 执行。
- `steering`：用户在 busy turn 时提交的短 steering message，作为当前 turn abort/next-turn instruction 的候选。M8 P0 可以先排队到下一 turn，不尝试注入正在运行的 provider request。
- `command`：busy-safe command，例如 `/hotkeys`、`/session`、`/tree` 可立即执行；非 busy-safe command 返回错误。
- `restored_input`：abort 后恢复到 editor 的未发送输入。

规则：

- Busy turn 期间普通 Enter 不丢输入；显示 `queued after current turn`。
- Ctrl+C request abort 后，queued prompt 不自动发送，先恢复到 editor 或保留 queue 并显示状态。
- `/quit` busy 时优先 abort，不强杀 worker。
- 队列有容量上限，超限返回清晰错误。
- Scripted tests 必须覆盖 busy submit、abort restore、command while busy。

建议状态：

```zig
pub const PendingInput = union(enum) {
    prompt: []const u8,
    shell_context: []const u8,
    command: commands.ParsedCommand,
};

pub const MessageQueue = struct {
    items: std.ArrayList(PendingInput),
    capacity: usize = 32,
    paused_after_abort: bool = false,
};
```

## Session Resume 和 State Rebuild

M8 需要从 session entries 重建 runtime state，供 `/resume`、`--resume`、`/fork` 和 compaction 使用。

重建规则：

- 从 root 到 selected leaf 取 path entries，不读取 sibling branch。
- `message` entries 映射到 `AgentState.messages`。
- `model_change` 最后一个值决定 session preferred model。
- `thinking_level_change` 最后一个值决定 preferred thinking level。
- `compaction` entry 表示在对应 target 后追加 summary context；P0 可以把 compaction summary 作为 synthetic system/user-visible context block 加入 state。
- `tool_event` 只用于 transcript/tree diagnostics；`tool_result` 如果已经包含在 tool message 中，不重复加入 model context。
- Unknown `custom` entry 忽略或显示 warning，不阻塞 resume。

Session lookup：

- ID lookup：`session_<id>.jsonl` 或完整 session id。
- Path lookup：绝对路径、相对路径、以 `.jsonl` 结尾的 ref。
- Latest lookup：按 file mtime 或 header/session_info timestamp；如果 timestamp 缺失，用 mtime。
- CWD filter：默认只列当前 workspace 相关 session，`--all` 才跨 cwd。

## Compaction

M8 compaction 分两层：

1. Planner：判断是否需要 compact，选择 target/tail window。
2. Executor：构造 summary prompt，调用 model，写 session entry，重建 AgentState。

Manual `/compact`：

- 默认 compact 到当前 leaf，保留最近 N 条 user/assistant/tool message 作为 tail。
- 支持 `/compact --before <entry-id>` 选择 target。
- Summary 失败不修改 state，不写 partial compaction entry。

Automatic compaction：

- M8 P0 必须实现 threshold 检测；默认行为可以是 status warning，例如 `context is near limit; run /compact`。
- M8 P0 应支持 opt-in automatic trigger：settings 明确开启时，在 turn 边界自动运行 compaction；默认不开启，避免用户意外产生模型调用。
- 自动执行只能发生在 turn 边界，失败时不修改 state/session，并显示可恢复错误。
- Settings 可预留：

```json
{
  "session": {
    "auto_compact": false,
    "compact_after_messages": 80,
    "compact_tail_messages": 12
  }
}
```

`resources.settings` 如果 M8 扩 schema，应保持 backwards-compatible missing defaults。

## TUI/UX 集成

M8 不要求完整 Pi selector UI，但要让数据结构可接：

- Command palette DTO：name、usage、summary、category、enabled/busy reason。
- Model selector DTO：id、display name、provider、scope、enabled、current。
- Tree view DTO：entry id、depth、kind、short label、current marker。
- Settings view DTO：key、value、source、secret redacted flag。

P0 scripted/live rendering可以继续用 transcript lines，但 command handlers 返回这些 DTO 时应有 text formatter，后续可替换为组件渲染。

## 错误模型

沿用 `docs/error-model.md` 分类：

- `ConfigError`：invalid command args、unknown model、disabled model、invalid settings update。
- `AuthError`：missing key、invalid auth JSON、unsupported login mode。
- `SessionError`：session not found、invalid JSONL、missing parent、fork target missing、export collision。
- `ToolError`：shell shortcut approval denied、timeout、nonzero command where policy requires failure。
- `ProviderError`：compaction/model switch validation 时 provider client 创建或 summary request 失败。

原则：

- Command parse error 不退出 interactive。
- Session open/fork/new 失败不能破坏当前 active state。
- Model switch 失败不能丢失旧 model client。
- Compaction 失败不能写入 session entry。
- Secret redaction 是 P0 测试项。

## 测试和 Build Steps

新增 build steps：

```bash
zig build commands
zig build session-workflows
zig build compaction
```

默认 `zig build test` 包含 M8 新测试。

必跑验证：

```bash
zig build test
zig build commands
zig build session-workflows
zig build compaction
zig build cli-modes
zig build interactive-mode
zig build session-fixtures
zig build resources
zig build smoke
zig build fmt-check
```

Fixture 策略：

- command parser/registry 不需要静态 fixtures。
- session workflow tests 优先用 `std.testing.tmpDir()` 动态生成 JSONL，避免提交真实 session。
- 可新增少量 `fixtures/session/m8-*.jsonl` 覆盖 tree/fork/compaction golden shape。
- shell shortcut tests 使用 temp workspace 和 deny/allow approval fake，不执行危险命令。
- compaction tests 使用 scripted model client，不访问 live provider。

## Slice 计划

### Slice 0: Command Registry 和 Parser

- 新增 `app/commands.zig`。
- 定义 command specs、categories、aliases、parser、help formatter。
- 把 `/reload` 从 interactive 特判迁到 registry，但 handler 可以先沿用现有 reload hook。

验收：

- `/reload` scripted interactive 行为不回退。
- Unknown command、quoted args、`//literal` 有测试。
- `/hotkeys` 能从 registry 输出命令列表。

### Slice 1: Interactive Dispatch 和 Busy-safe Commands

- 新增 command dispatch result。
- 在 `app/interactive.zig` 中统一处理 slash command。
- 标记 busy-safe commands：`/hotkeys`、`/session`、`/tree`、`/quit`、`/exit`。

验收：

- Command 不发起 model turn。
- Busy 状态下非 safe command 返回可读错误。
- `/quit`/`/exit` 保持现有退出语义。

### Slice 2: Session Query 和 Resume

- 新增 `session/query.zig`。
- 实现 list latest、open by id/path、cwd filter。
- 实现 `AgentState`/transcript 从 session path 到 selected leaf 的重建。
- 接入 `/resume` 和 CLI `--resume`。

验收：

- `/resume` latest 可恢复 message history。
- `--resume --print` 不再返回 M7 unsupported。
- Invalid session 不破坏当前 interactive state。

### Slice 3: New/Name/Session/Tree/Fork

- 实现 `/new`、`/name`、`/session`、`/tree`、`/fork`。
- `session_info` 写 current leaf/title。
- Tree outline 使用 session tree index。

验收：

- `/new` 创建新 JSONL store。
- `/name` 写入并 resume 后可见。
- `/fork <entry-id>` 后下一 message parent 指向 fork target。
- 放弃原分支时写入 `branch_summary` entry，即使 P0 summary 只是 deterministic metadata。

### Slice 4: Model 和 Settings Commands

- 实现 `/model`、`/scoped-models`、`/settings`。
- model switch 成功后替换当前 model client，并写 `model_change` entry。
- settings 输出 redacted effective config 和 source info。

验收：

- 切换 enabled model 后下一 turn 使用新 model。
- Missing auth/unknown model 不改变旧 model。
- `/settings` 不输出 secret 或完整 system prompt。

### Slice 5: Message Queue

- 新增 `app/message_queue.zig`。
- Busy turn 期间普通 prompt 进入 queue。
- Turn 完成后自动执行下一个 queued prompt。
- Abort 后暂停自动发送并恢复输入。

验收：

- Busy submit 不丢输入。
- Ctrl+C 后 queued input 不被意外发送。
- Queue capacity 超限有稳定错误。

### Slice 6: Shell Shortcuts

- 新增 `app/shell_shortcuts.zig`。
- 复用 M3 bash tool policy 执行 `!`/`!!`。
- `!` 结果可进入下一 agent context，`!!` 只显示。

验收：

- `!pwd` 追加 context 并触发/排队 agent turn。
- `!!pwd` 不修改 AgentState messages。
- Approval denied/timeout/truncation tests 稳定。

### Slice 7: Compaction

- 新增 `app/compaction.zig`。
- 实现 manual `/compact` summary request、entry 写入、state rebuild。
- 增加 threshold detection、默认 warning，以及 settings opt-in automatic trigger。

验收：

- `/compact` 写入 `compaction` entry。
- Compacted 后下一 turn 仍包含 summary context。
- Summary failure 不修改 state/session。
- Threshold warning 可离线测试；settings 开启 automatic trigger 时只在 turn 边界执行。

### Slice 8: Login/Logout Local Auth Helper

- 实现 `/login` guidance 和 `/logout` auth JSON key removal。
- 如果 secret input 未完成 hidden mode，`--api-key-stdin` 在 live interactive 中返回 unsupported，在 tests 中通过 injected reader 覆盖。

验收：

- `/login` 不泄漏 secret。
- `/logout` preserve 其他 providers。
- Auth JSON tests 使用 tmp HOME。

### Slice 9: Export/Copy/Docs

- 实现 `/export` Markdown/JSONL。
- 实现 `/copy` OSC 52 payload builder 和 fallback。
- 新增 `docs/slash-commands.md`、更新 `docs/architecture.md`、`docs/resources.md`、`docs/fixtures.md`、`README.md`。

验收：

- Export 不覆盖文件，除非 `--force`。
- Markdown export 可读且不包含 secret。
- Docs 与命令实际语义一致。

## 验收清单

- Slash commands 由 registry 驱动，interactive 中没有新增散落的字符串特判。
- `/login`、`/logout`、`/model`、`/scoped-models`、`/settings`、`/resume`、`/new`、`/name`、`/session`、`/tree`、`/fork`、`/compact`、`/copy`、`/export`、`/reload`、`/hotkeys`、`/changelog`、`/quit`、`/exit` 至少有 scripted interactive 覆盖。
- `/login`、`/logout` 不泄漏 API key，测试只使用 tmp auth JSON。
- Session resume/latest/open by id/path 可用，`--resume --print` 不再是 unsupported。
- Fork 后 parent/current leaf 正确，session JSONL 仍 append-only。
- 放弃分支时会写入 `branch_summary`，且 summary 不要求 live provider。
- Model switch 写 `model_change` entry，失败时保留旧 model。
- Message queue 在 busy submit 和 abort restore 下行为稳定。
- `/compact` 写 structured `compaction` entry，并能用 summary 继续下一 turn。
- Context-window threshold 检测可测试；automatic trigger 只有 settings opt-in 时执行。
- Shell shortcuts 复用 M3 bash policy，不绕过 approval/path/timeout。
- `/settings`、`/session`、`/export` 不输出 secret 或完整 hidden auth material。
- `zig build test`、`zig build commands`、`zig build session-workflows`、`zig build compaction`、`zig build interactive-mode`、`zig build smoke`、`zig build fmt-check` 通过。

## 风险和约束

- 如果 command handlers 直接操作 TUI frame，会阻塞后续 selector/palette 重构。Handler 只返回 DTO/result。
- 如果 session resume 直接读取 sibling branches 到 model context，会污染 fork 语义。只沿 root-to-leaf path 重建 state。
- 如果 `/model` 在 active turn 中切换，会导致 worker 使用的 model client 生命周期不清晰。M8 P0 禁止 busy switch。
- 如果 compaction 删除或重写旧 JSONL，会破坏 M4 append-only crash safety。Compaction 只能追加 entry。
- 如果 shell shortcut 绕过 M3 bash policy，会扩大本地执行风险。必须复用 approval/timeout/truncation。
- 如果 `/login` 在普通 editor 中收 API key，secret 会进入 transcript/session/export。没有 hidden input 前真实 interactive 不接收明文 secret。
- 如果 command registry 过早允许 packages/plugins 动态注册，会把 M10 scope 拉进 M8。M8 只保留静态注册和后续扩展接口。

## M8 完成后的后续承接

- M9 可以基于 command registry 注册 prompt template 和 skill commands，并复用 autocomplete metadata。
- M9 themes 可以替换 M8 command/model/tree/settings DTO 的渲染层，而不改 handler。
- M10 plugin system 可以在 registry 上增加受限 external command source，但不改变 M8 built-in command contract。
- M11 RPC/SDK 可以复用 session query、compaction、model switch 和 command parser 的非 TUI handler。
