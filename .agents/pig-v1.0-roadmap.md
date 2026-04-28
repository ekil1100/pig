# Pig v1.0 Roadmap：用 Zig 0.16 完整实现 pi-mono

> 目标：基于 `/home/like/workspace/pi-mono` 当前源码，用 Zig 0.16 实现一个完整的 Pi 风格系统。
>
> 这份 roadmap 的优先级是：先做出可用的本地 coding-agent CLI，再逐步补齐 `pi-mono` 的完整产品边界，包括 AI provider 层、agent runtime、coding-agent 产品、TUI、SDK/RPC、插件与资源系统、Web UI 桥接、Slack bot 和 pods 管理。

## 1. 范围和优先级

### 1.1 固定输入

- 语言和版本：Zig 0.16
- 参考实现：`/home/like/workspace/pi-mono`
- 目标形态：local-first native CLI，优先单仓内部模块化
- 第一产品目标：Pi-compatible coding agent，而不是逐字复刻 TypeScript runtime

### 1.2 总体优先级

1. 建立稳定的 Zig 0.16 工程基础和兼容性测试框架。
2. 实现最小 Pi Core：provider streaming、agent loop、工具系统、session 持久化。
3. 让 coding-agent CLI 真正可用：interactive mode、print mode、JSON mode、命令、配置、上下文加载。
4. 实现 Pi 级别 TUI：renderer、editor、markdown、selector、流式输出。
5. 补齐 session tree、fork、compaction、模型切换、resources、skills、prompts、themes。
6. 加扩展能力：外部进程插件、RPC、SDK embedding。
7. 覆盖完整生态：Web UI bridge、mom/Slack adapter、pods/vLLM 管理。
8. 做 v1.0 硬化：测试、fixtures、对照 `pi-mono` 的兼容性检查、打包、文档。

## 2. 架构方向

先用一个 Zig 仓库实现，不要一开始照搬 TypeScript monorepo。内部模块边界对齐 Pi 的 package 语义：

```text
src/
  app/        CLI modes: interactive, print, json, rpc
  provider/   pi-ai 等价层
  core/       pi-agent-core 等价层
  tools/      coding-agent 内置工具
  session/    JSONL session tree 和持久化
  resources/  AGENTS、settings、skills、prompts、themes、packages
  tui/        pi-tui 等价层
  rpc/        JSONL 协议和 SDK bridge
  plugin/     外部进程 plugin host
  integrations/
    web_ui/
    mom/
    pods/
  util/
```

依赖方向必须保持简单：

```text
app -> core -> provider
app -> tui
core -> tools
core -> session
core -> resources
provider -> util
integrations -> core/rpc
```

不要出现反向依赖。Provider 不能依赖 app 或 TUI。TUI 不能知道 coding-agent 的业务语义。

## 3. Milestones

## M0. Zig 0.16 工程基础

优先级：P0

目的：先确保项目可以稳定构建、测试，并能承受 Zig 0.16 标准库变化，再开始堆产品功能。

交付物：

- `build.zig` 和 `build.zig.zon`，明确面向 Zig 0.16。
- `zig build`、`zig build test`、`zig build run` 可用。
- 建立 `app`、`core`、`provider`、`tools`、`session`、`resources`、`tui`、`rpc`、`plugin`、`util` 模块骨架。
- 写清 allocator 策略，并在子系统内保持一致。
- 建立错误分类：config、auth、provider、stream parsing、tools、sessions、terminal。
- 准备 golden fixtures，来源可以是 `/home/like/workspace/pi-mono` 的行为样本。

验收标准：

- 干净 checkout 后可用 Zig 0.16 构建。
- 单元测试不依赖 API key。
- 基础 CLI 能输出版本、build 信息、配置路径和当前工作目录。

## M1. Provider Layer（`pi-ai` Core）

优先级：P0

目的：在 agent loop 依赖具体模型 API 前，先建立 Zig 版 provider 抽象。

交付物：

- 统一 message/content 模型：
  - text
  - image reference
  - thinking block
  - tool call
  - tool result
- 统一 streaming event 模型：
  - message start/update/end
  - text delta
  - thinking delta
  - tool call start/delta/end
  - usage/cost
  - error/done
- HTTP transport 抽象：
  - 先用 Zig stdlib HTTP
  - 保留切换到 curl 的窄接口，以防 TLS/SSE 兼容性不足
- Provider 实现优先级：
  - P0：OpenAI-compatible chat completions
  - P0：Anthropic Messages
  - P1：Google Gemini
  - P1：OpenAI Responses
  - P2：Azure OpenAI、Bedrock、OpenRouter/custom providers
- SSE/chunked stream parser，支持 partial-line buffering。
- Tool-call 参数组装；严格校验放到工具执行前。
- Auth resolution：
  - 环境变量
  - auth JSON
  - model/provider config

验收标准：

- 至少能从一个 OpenAI-compatible endpoint 流式输出文本。
- Anthropic text 和 tool call 可以被解析成统一事件。
- Provider event 与 app mode 解耦。
- Provider 测试使用 recorded fixtures，不依赖 live network。

## M2. Agent Runtime（`pi-agent-core`）

优先级：P0

目的：实现 interactive、print、JSON、RPC、SDK 共用的核心 agent loop。

交付物：

- `Agent` state：
  - system prompt
  - model/provider
  - thinking level
  - tools
  - messages
  - pending tool calls
  - stream message
  - error/abort state
- 标准 agent loop：
  - append user input
  - stream assistant
  - detect tool calls
  - execute tools
  - append tool results
  - continue until final text
- Event bus：
  - agent start/end
  - turn start/end
  - message start/update/end
  - tool execution start/update/end
  - retry/abort/error
- Tool execution：
  - P0：sequential execution
  - P1：parallel execution，保持 event 顺序可预测
- Middleware hooks：
  - before input
  - before provider request
  - before tool call
  - after tool result
  - before compaction
  - before tree navigation

验收标准：

- Print mode 可以完成一个无工具调用的 prompt。
- Tool-call loop 可以用 fixture provider 跑通。
- 每个关键状态变化都有 event。
- Agent core 不依赖 terminal rendering。

## M3. 内置 Coding Tools

优先级：P0

目的：达到最小可用本地 coding-agent 能力。

交付物：

- P0 工具：
  - `read`
  - `write`
  - `edit`
  - `bash`
- P1 工具：
  - `grep`
  - `find`
  - `ls`
- Tool schema/metadata：
  - name
  - description
  - JSON schema
  - display label
  - risk level
  - read/write classification
- 安全机制：
  - bash 和文件写入确认策略
  - edit/write 执行前 preview
  - bash timeout 和输出截断
  - 截断时保存完整输出到文件
  - 路径 normalize，可配置 workspace boundary check
- Edit 行为：
  - 精确 old-text replacement
  - multiple disjoint edits
  - collision detection
  - 对 missing/repeated match 给出清晰错误

验收标准：

- Agent 能检查、修改、测试一个小型 repo。
- 文件变更工具执行前展示 preview。
- 策略要求确认时，bash 不能静默执行。
- Tool results 会持久化为 session entries。

## M4. Session Store 和 Context Tree

优先级：P0

目的：实现 Pi 的 durable workflow model，而不是简单线性聊天记录。

交付物：

- JSONL append-only session format。
- Session entries：
  - header
  - message
  - model change
  - thinking level change
  - tool event/result
  - compaction
  - branch summary
  - custom
  - label
  - session info
- Tree model：
  - 每个 entry 有 `id` 和 `parentId`
  - current leaf pointer
  - 启动时从 JSONL 重建 in-memory tree index
- Session operations：
  - create
  - resume latest
  - open by id/path
  - list by working directory
  - rename
  - export
  - ephemeral mode
- Crash safety：
  - append 和 fsync 策略
  - 从 partial final line 恢复

验收标准：

- 重启后能恢复最近 session。
- 可以从历史 entry 分支继续。
- Session 文件仍是可读 JSONL。

## M5. Coding-Agent CLI Modes

优先级：P0/P1

目的：通过用户可见的产品模式暴露 agent core。

交付物：

- CLI parser：
  - working directory
  - model/provider
  - thinking level
  - session selection
  - print/json/rpc/interactive mode
  - config override flags
- Print mode：
  - one-shot prompt
  - optional tool use
  - plain text output
  - agent/tool 失败时返回 nonzero exit
- JSON mode：
  - JSONL event stream
  - 稳定 event schema
  - machine-readable tool/error events
- Interactive mode：
  - 先实现基础 prompt loop
  - M6 就绪后接入完整 TUI
- RPC mode：
  - stdin/stdout JSONL protocol
  - start session
  - send message
  - abort
  - list/switch sessions
  - read event stream

验收标准：

- `pig --print "..."` 不依赖 TUI 可用。
- `pig --json --print "..."` 只输出 JSONL events。
- RPC mode 可由外部进程驱动。
- 所有 mode 复用同一个 agent runtime。

## M6. Terminal UI（`pi-tui` 等价层）

优先级：P1

目的：实现接近 Pi interactive mode 的 native terminal 体验。

交付物：

- Terminal layer：
  - raw mode
  - alternate screen policy
  - resize handling
  - synchronized output where supported
  - ANSI capability fallback
- Renderer：
  - full render
  - differential render
  - cursor positioning
  - width-aware line layout
- Components：
  - text
  - markdown
  - box/container/spacer
  - loader
  - cancellable loader
  - select list
  - settings list
  - overlay
  - image placeholder first，后续支持 terminal image protocol
- Editor：
  - multiline input
  - history
  - undo/kill ring 可后置
  - paste detection
  - keybindings
  - command autocomplete
  - path autocomplete
  - `@file` reference search

验收标准：

- Assistant 流式输出不会破坏输入框。
- 终端 resize 后 layout 不乱。
- Agent 忙时用户仍能输入。
- 窄终端可用。

## M7. Config、Auth、Models 和 Resource Loading

优先级：P1

目的：实现 Pi 的产品级资源系统，避免硬编码本地行为。

交付物：

- Config hierarchy：
  - global `~/.pi/agent/settings.json`
  - project `.pi/settings.json`
  - CLI flags
  - nested object merge
- Auth：
  - env vars
  - auth JSON
  - `/login` placeholder flow，OAuth 可后置
  - `/logout`
- Models：
  - built-in registry
  - custom `models.json`
  - enabled/scoped models
  - resume 时 model fallback
- Context files：
  - `AGENTS.md`
  - `CLAUDE.md`
  - `SYSTEM.md`
  - `APPEND_SYSTEM.md`
  - upward recursive discovery
- Resources：
  - skills
  - prompt templates
  - themes
  - packages
  - source info 和 collision warnings
  - reload support

验收标准：

- 项目配置稳定覆盖全局配置。
- System prompt 包含发现到的 context files。
- Interactive mode 下 `/reload` 能更新 resources。
- 模型选择在 session resume 后保留。

## M8. Slash Commands 和 Workflow Features

优先级：P1

目的：让 CLI 具备 Pi 的工作流体验，而不是裸 chat loop。

交付物：

- Commands：
  - `/login`
  - `/logout`
  - `/model`
  - `/scoped-models`
  - `/settings`
  - `/resume`
  - `/new`
  - `/name`
  - `/session`
  - `/tree`
  - `/fork`
  - `/compact`
  - `/copy`
  - `/export`
  - `/reload`
  - `/hotkeys`
  - `/changelog`
  - `/quit`
  - `/exit`
- Shell shortcuts：
  - `!command` 执行并把结果送入上下文
  - `!!command` 执行但不进入上下文
- Message queue：
  - steering messages
  - follow-up messages
  - abort and restore queued input
- Tree/fork：
  - session tree navigation
  - 从历史节点继续
  - fork 到新 session
  - 放弃分支时生成 branch summary
- Compaction：
  - manual `/compact`
  - automatic context-window threshold
  - structured summary entry

验收标准：

- 长 session 可以压缩后继续。
- 用户可以导航和 fork 历史工作。
- Slash commands 可发现，并为 autocomplete 做好数据结构。

## M9. Skills、Prompts、Themes 和 Packages

优先级：P1/P2

目的：先实现 data-driven customization，再实现可执行插件。

交付物：

- Skills：
  - 启动时只发现 name 和 description
  - lazy-load `SKILL.md`
  - `/skill:name`
  - validation 和 collision reporting
- Prompt templates：
  - markdown templates
  - filename 到 slash command 映射
  - `$1`、`$@`、`${@:N}` expansion
  - description metadata
- Themes：
  - JSON theme format
  - active theme selection
  - TUI color mapping
- Packages：
  - package manifest
  - resource contribution
  - enable/disable
  - source tracking

验收标准：

- Project-local skills 和 prompts 可用。
- Global/project resources 合并行为稳定。
- Prompt templates 表现为 slash commands。

## M10. Extension 和 Plugin System

优先级：P2

目的：不把 TypeScript runtime 嵌进 Zig binary，也能提供 Pi-like extensibility。

交付物：

- 基于 JSONL 的 external process plugin protocol。
- Plugin manifest：
  - name
  - version
  - executable
  - permissions
  - contributed tools/commands/providers/resources
- Extension capabilities：
  - register tools
  - register commands
  - register keybindings
  - observe lifecycle events
  - intercept input
  - intercept tool calls
  - intercept provider requests
  - inject system prompt fragments
  - add custom session entries
  - 通过受限协议贡献 UI status/widgets
- Security：
  - explicit permission model
  - per-plugin enablement
  - clear error isolation

验收标准：

- 示例 plugin 可以增加一个 command 和一个 tool。
- Plugin failure 不会 crash agent。
- Plugin activity 能在 events/session logs 中看到。

## M11. SDK 和 RPC 完整性

优先级：P2

目的：支持 embedding 和外部 UI 控制，同时不复制 product logic。

交付物：

- 稳定 RPC command schema。
- 稳定 event schema。
- C ABI 或 Zig library API，用于 embedding。
- Examples：
  - 通过 RPC 驱动 print-mode 等价流程
  - 构建一个最小 custom UI client
  - 从另一个 Zig 程序启动 agent session
- RPC client version negotiation。

验收标准：

- RPC client 可以完整控制一个 session。
- SDK 用户可以配置 providers、tools 和 event subscribers。
- Protocol compatibility tests 基于 fixtures 运行。

## M12. Web UI Bridge

优先级：P3

目的：覆盖 `pi-web-ui` 产品边界。这里不是用 Zig 重写前端组件，而是提供 Zig-native backend protocol。

交付物：

- 面向浏览器客户端的 RPC/WebSocket bridge。
- Static example web client 或 compatibility layer。
- Core AgentEvent 到 web chat event 的映射。
- Session attachment 和 streaming updates。
- Tool approval UI protocol。

验收标准：

- Browser client 可以启动/恢复 session，并流式显示 assistant output。
- Browser client 可以批准或拒绝 risky tools。
- Web UI 使用同一套 core runtime。

## M13. Mom / Slack Integration

优先级：P3

目的：以 core/RPC 上的 integration adapter 覆盖 `pi-mom` package 边界。

交付物：

- Slack app adapter process。
- Message-to-session routing。
- Thread/session mapping。
- Long-running task notifications。
- 适合 Slack 的 approval flow。
- Deployment config。

验收标准：

- Slack thread 可以创建或恢复 coding-agent session。
- Agent events 会被摘要回写到 thread。
- Risky tools 需要显式 approval。

## M14. Pods / vLLM Management

优先级：P3

目的：覆盖 `pi-pods` package 边界，用于管理 OpenAI-compatible 模型部署。

交付物：

- Pod config model。
- Provider endpoint registry integration。
- Commands：
  - list pods
  - start pod
  - stop pod
  - status
  - logs
  - register endpoint as model provider
- vLLM/OpenAI-compatible health check。

验收标准：

- Managed endpoint 可以注册为 OpenAI-compatible provider。
- CLI commands 能展示 pod state。
- 失败时输出可操作 diagnostics。

## M15. Compatibility、Quality 和 Release

优先级：P0 到 P3，持续推进

目的：持续对照 `pi-mono` 行为，确保 Zig 实现可以发布为 v1.0。

交付物：

- 使用代表性 `pi-mono` sessions/events/configs 的 fixture tests。
- Session 和 RPC events 的 golden JSONL tests。
- 基于 temp directories 的 tool tests。
- 使用 recorded SSE streams 的 provider parser tests。
- TUI snapshot/line-layout tests。
- End-to-end tests：
  - print mode
  - JSON mode
  - interactive smoke
  - session resume
  - edit/write/bash approval
  - compaction
  - fork/tree
- Packaging：
  - Linux/macOS binaries 优先
  - Windows 等 terminal/process 行为验证后再做
  - release checks
- Documentation：
  - install
  - config
  - providers/auth
  - sessions
  - tools
  - commands
  - plugin protocol
  - RPC protocol

验收标准：

- `zig build test` 无需网络即可通过。
- Smoke suite 可以用 fake provider 运行。
- Live provider tests 只通过环境变量显式开启。
- v1.0 release 有可复现 build instructions。

## 4. 建议实现顺序

### Phase 1：Native Core MVP

1. M0：Zig 0.16 工程基础。
2. M1：OpenAI-compatible provider，先支持 streaming text。
3. M2：基础 agent loop。
4. M3：`read`、`write`、`edit`、`bash`。
5. M4：append-only session JSONL。
6. M5：print mode 和基础 interactive prompt loop。

结果：不依赖完整 TUI 的可用本地 coding agent。

### Phase 2：Pi-Like Coding Agent

1. M1：补 Anthropic 和 Gemini providers。
2. M4：session tree，以及按 working directory resume。
3. M6：TUI renderer 和 editor。
4. M7：config/auth/model/resource loading。
5. M8：slash commands、tree/fork、compaction。
6. M15：常见 coding workflow 的 e2e tests。

结果：具备核心 Pi coding-agent 体验。

### Phase 3：Customization 和 Integration

1. M9：skills、prompts、themes、packages。
2. M10：external process plugin system。
3. M11：RPC 和 SDK 完整性。
4. M6：高级 TUI widgets 和 images。

结果：不嵌入原 TS 生态，也能提供 Pi 风格扩展能力。

### Phase 4：完整 pi-mono 产品边界

1. M12：Web UI bridge。
2. M13：Slack/mom adapter。
3. M14：pods/vLLM management。
4. M15：packaging 和 compatibility hardening。

结果：围绕 Zig core 覆盖完整 `pi-mono` 产品面。

## 5. 立即下一步

1. 创建 Zig 0.16 project skeleton。
2. 编写 `docs/architecture.md`、`docs/session-format.md`、`docs/provider-events.md`。
3. 添加 fake provider fixtures，让 agent-loop tests 不依赖网络。
4. 实现 message/content/event tagged unions。
5. 实现 OpenAI-compatible non-streaming request，再做 streaming SSE。
6. 用 fake provider 和 live provider 各跑通一个 print-mode CLI。
7. 在增加文件编辑工具前，先实现第一版 session JSONL writer。

## 6. 风险和后续决策点

- Zig 0.16 stdlib HTTP/TLS 未必覆盖所有 provider 场景；transport 必须可替换。
- 如果要求直接加载 TypeScript 模块，完整 Pi extension compatibility 不现实；优先 JSONL external plugin protocol。
- TUI 复杂度很高；print/json modes 必须先完整。
- OAuth 可能需要 browser 和 secure storage 支持；API-key auth 应该先发布。
- Web UI、Slack、pods 应该作为 core/RPC 上的 integration adapters，不要 fork agent runtime。
- Session tree format 要早设计。先做线性 log，后面再补 branch/fork 会很贵。
