# Pi Zig 实现方案

> 目标：基于前一份《pi-mono 需求分析》输出一份“可实施的 Zig 技术方案”。
> 重点不是 1:1 复刻 monorepo 的所有实现细节，而是：**如何用 Zig 从 0 做出一个 Pi 风格的核心系统**。

---

## 1. 总体判断

**Zig 很适合实现 Pi 的核心闭环，但不适合第一阶段复刻整个 pi-mono 生态。**

### 1.1 适合用 Zig 做的部分
- CLI 与命令分发
- LLM provider 抽象层
- agent loop
- session / JSONL / branch tree
- 文件工具与 bash 工具
- TUI
- JSON mode / RPC mode
- 配置与资源发现

### 1.2 不适合第一阶段硬做的部分
- 浏览器 UI（`pi-web-ui`）
- TS/npm 风格动态扩展系统
- Slack bot 高层适配
- 复杂 OAuth 浏览器登录流程

### 1.3 一句话目标
把目标收敛为：

> 用 Zig 实现一个 Pi Core：一个可扩展的终端编码代理运行时和 CLI 产品。

---

## 2. 第一阶段实现边界

第一阶段只覆盖 Pi 的核心四层：

- `pi-ai` 等价物：provider 与统一流式事件
- `pi-agent-core` 等价物：agent loop 与工具执行
- `pi-coding-agent` 等价物：CLI、session、modes、资源加载
- `pi-tui` 等价物：交互式终端界面

明确不纳入第一阶段：

- `pi-web-ui`
- `pi-mom`
- `pi-pods`

这样可以先做出一个真正可用的 Zig 版 Pi，而不是过早扩张范围。

---

## 3. 实现策略

### 3.1 架构策略
- **单仓但模块化**，先不要做 monorepo
- **先实现 Pi Core**，不急着复刻全生态
- **优先 pure Zig MVP**，必要时再引入 C 依赖（如 curl）

### 3.2 扩展策略
- 不照搬 TS extension 机制
- 优先采用 **外部进程插件协议**
- `skills / prompts / themes` 先保持数据驱动

### 3.3 协议策略
- 配置、会话、RPC、事件流统一使用 **JSON / JSONL**
- 避免自定义二进制协议或嵌入式脚本运行时

---

## 4. 建议的仓库结构

我建议你先 **不要做 monorepo**，而是做一个单仓、模块化目录结构：

```text
pig-zig/
├── build.zig
├── build.zig.zon
├── README.md
├── docs/
│   ├── requirements.md
│   ├── architecture.md
│   ├── rpc.md
│   └── session-format.md
├── src/
│   ├── main.zig
│   ├── app/
│   │   ├── cli.zig
│   │   ├── interactive_mode.zig
│   │   ├── print_mode.zig
│   │   ├── json_mode.zig
│   │   └── rpc_mode.zig
│   ├── core/
│   │   ├── agent.zig
│   │   ├── agent_loop.zig
│   │   ├── messages.zig
│   │   ├── events.zig
│   │   ├── session.zig
│   │   ├── session_tree.zig
│   │   ├── settings.zig
│   │   ├── resources.zig
│   │   ├── auth.zig
│   │   ├── models.zig
│   │   ├── prompt_templates.zig
│   │   ├── skills.zig
│   │   ├── compaction.zig
│   │   └── system_prompt.zig
│   ├── provider/
│   │   ├── provider.zig
│   │   ├── openai.zig
│   │   ├── anthropic.zig
│   │   ├── google.zig
│   │   ├── registry.zig
│   │   └── stream_parser.zig
│   ├── tools/
│   │   ├── tool.zig
│   │   ├── read.zig
│   │   ├── write.zig
│   │   ├── edit.zig
│   │   ├── bash.zig
│   │   ├── grep.zig
│   │   ├── find.zig
│   │   └── ls.zig
│   ├── tui/
│   │   ├── terminal.zig
│   │   ├── renderer.zig
│   │   ├── layout.zig
│   │   ├── input.zig
│   │   ├── editor.zig
│   │   ├── markdown.zig
│   │   ├── select_list.zig
│   │   ├── settings_list.zig
│   │   └── theme.zig
│   ├── rpc/
│   │   ├── protocol.zig
│   │   ├── commands.zig
│   │   └── extension_ui.zig
│   ├── plugin/
│   │   ├── protocol.zig
│   │   ├── manager.zig
│   │   └── host.zig
│   └── util/
│       ├── json.zig
│       ├── fs.zig
│       ├── shell.zig
│       ├── ansi.zig
│       ├── path.zig
│       ├── tokenizer.zig
│       └── text.zig
└── test/
    ├── provider/
    ├── session/
    ├── tools/
    ├── tui/
    └── rpc/
```

### 原因
这比 monorepo 更适合 Zig 的开发方式：

- 一个 `build.zig`
- 一个主二进制
- 内部模块化即可
- 以后如果稳定了，再拆成多个 package

---

## 5. 技术选型建议

## 5.1 Zig 版本

建议：

- **优先选择一个稳定版本线**，例如 `0.14.x` 稳定版
- 不建议一上来追 nightly

### 原则
Pi 这种工具：
- 终端交互复杂
- 网络流式解析复杂
- JSON / 文件 / 进程控制复杂

所以你需要语言和标准库行为尽可能稳定。

---

## 5.2 HTTP 方案

这是 Zig 实现 Pi 的一个关键决策。

### 方案 A：先用 Zig 标准库 HTTP
适合：
- MVP
- OpenAI/Anthropic SSE 流式实现
- 尽量纯 Zig

### 方案 B：必要时只为网络层引入 libcurl
适合：
- 某些 provider SSE / HTTP2 / TLS 兼容性不好
- 后期要做更稳的多 provider 支持

### 我的建议

**先纯 Zig，保留 transport 抽象，必要时切到 curl。**

也就是 provider 层不要直接依赖某一种具体 HTTP 实现，而是抽象成：

```text
HttpTransport
- request()
- stream()
- websocket()   // 后续可选
```

这样未来切换实现时，不会伤到 agent/core。

---

## 5.3 JSON 方案

建议：
- 配置、会话、RPC、事件流一律 JSON / JSONL
- 不做自定义序列化协议

### 原因
Pi 的关键边界都是文本协议：
- session.jsonl
- rpc jsonl
- auth/settings/models json
- skill/prompt/theme 文件

这很适合 Zig：
- 读写简单
- 调试方便
- 与外部插件兼容性高

---

## 5.4 并发模型

Zig 版 Pi 不建议一开始依赖“语言级 async 花活”，而建议：

### 推荐模型
- 主线程：TUI / CLI 事件循环
- Agent 工作线程：LLM 调用与工具执行
- 可选 I/O 线程：stdin / transport streaming
- 线程间通过 channel/queue 传事件

### 原因
Pi 本质上是事件系统：
- 用户输入事件
- provider 流式事件
- 工具执行事件
- session 持久化事件
- RPC 命令事件

所以比起 async/await，**线程 + 事件队列** 更清晰、可测。

---

## 6. 核心架构方案

## 6.1 分层架构

### 第一层：Provider 层
职责：
- 把 LLM API 差异统一起来
- 输出统一 assistant streaming events

### 第二层：Agent 层
职责：
- 管消息状态
- 运行 tool loop
- 对外发 AgentEvent

### 第三层：Session/Resources 层
职责：
- 会话树
- compaction
- 配置
- skills/templates/themes 发现

### 第四层：Product 层
职责：
- interactive/print/json/rpc
- CLI 参数
- 模型选择
- 用户交互

---

## 6.2 模块依赖方向

必须遵守：

```text
app -> core -> provider
app -> tui
core -> tools
core -> util
provider -> util

不能反向依赖：
provider 不依赖 app
tui 不依赖 core 业务语义
tools 不依赖 app
```

### 原因
避免未来：
- RPC 模式复用不了 core
- print mode 复用不了 interactive 逻辑
- provider 层被 UI 绑死

---

## 7. 关键数据模型设计

## 7.1 Message 模型

Zig 里建议用 tagged union。

### 设计建议

```zig
pub const ContentBlock = union(enum) {
    text: TextBlock,
    image: ImageBlock,
    thinking: ThinkingBlock,
    tool_call: ToolCallBlock,
};

pub const Message = union(enum) {
    user: UserMessage,
    assistant: AssistantMessage,
    tool_result: ToolResultMessage,
    bash_execution: BashExecutionMessage,
    custom: CustomMessage,
    branch_summary: BranchSummaryMessage,
    compaction_summary: CompactionSummaryMessage,
};
```

### 要点
- 不要过度 OO
- 用 union(enum) + 明确生命周期
- content block 和 message 分离

---

## 7.2 Event 模型

Pi 本质是事件驱动，事件模型必须一开始就定好。

### 建议事件分类

```text
AgentEvent
- agent_start
- agent_end
- turn_start
- turn_end
- message_start
- message_update
- message_end
- tool_execution_start
- tool_execution_update
- tool_execution_end
- auto_compaction_start
- auto_compaction_end
- auto_retry_start
- auto_retry_end
- extension_error   // 后续插件化时使用
```

### 设计原则
- UI、JSON mode、RPC mode 都订阅同一套事件
- 不要在每个 mode 里各搞一套逻辑

---

## 7.3 Session Entry 模型

建议直接按 `pi-mono` 的 session 结构去做，不要简化成纯线性对话，否则后面补 tree/fork 会很痛。

### 入口类型
- session header
- message
- model_change
- thinking_level_change
- compaction
- branch_summary
- custom
- label
- session_info

### 存储格式
- 一行一个 JSON object
- append-only
- 启动时 build in-memory tree index

### 内存结构建议
```text
SessionManager
- entries: HashMap<EntryId, SessionEntry>
- children: HashMap<EntryId, ArrayList<EntryId>>
- leaf_id: ?EntryId
- header
```

---

## 8. Provider 层实现方案

## 8.1 抽象目标

你需要一个 Zig 版“pi-ai”。

### 最小 Provider 接口
建议不是做传统 interface，而是做 **vtable + context pointer**：

```text
Provider
- name
- api_kind
- stream(context, model, options, sink)
- complete(...)   // 可选，由 stream 聚合实现
- resolve_auth(...)
```

### 事件输出方式
两种可选：

1. provider 返回一个 stream 对象
2. provider 接受一个 event sink callback，把事件推给 agent

### 我的建议
**用 sink callback**。

原因：
- Zig 手工管理 stream 对象更啰嗦
- Agent 本来就要接流式事件
- callback/sink 更符合 provider push 事件的本质

---

## 8.2 Provider 优先级

### P0 只做两个
1. OpenAI-compatible (`openai-completions`)
2. Anthropic (`anthropic-messages`)

### P1 再做
3. OpenAI Responses
4. Google

### P2 再做
- Azure
- Bedrock
- 其它兼容 provider

### 原因
大部分自定义 provider、ollama、vllm、OpenRouter 早期都能先挂在 OpenAI-compatible 上。

---

## 8.3 流式解析方案

### OpenAI / Anthropic
都可以抽象成：
- 发请求
- 读取 chunk/SSE line
- 解析 line
- 转成统一 event

### 建议模块化
```text
provider/openai.zig
- build payload
- send request
- parse sse lines
- emit text/toolcall/usage/done

provider/anthropic.zig
- build payload
- parse anthropic stream event
```

### 核心建议
把“流式行解析器”单独抽出去：

```text
stream_parser.zig
- read chunked bytes
- split SSE events
- assemble partial lines
```

否则 provider 文件会很快变成巨型 spaghetti。

---

## 8.4 Tool Calling 解析

### 建议
在 provider 层统一输出：
- `toolcall_start`
- `toolcall_delta`
- `toolcall_end`

### 实现原则
- 维护 partial JSON buffer
- 尽量做 best-effort parse
- toolcall_end 时再做严格 parse/validate

### 验证层位置
- schema validation 不放 provider 层
- 放 agent/tool execution 前

这样 provider 只负责“还原模型意图”，不负责“执行业务规则”。

---

## 9. Agent 层实现方案

## 9.1 Agent 结构

建议 `Agent` 结构体内部持有：

```text
Agent
- allocator
- state
- tool_registry
- provider_registry
- subscribers
- abort_flag
- work_queue
```

### 状态字段
- system prompt
- current model
- thinking level
- tools
- messages
- is_streaming
- current partial assistant message
- pending tool calls
- last error

---

## 9.2 Agent Loop

标准循环：

```text
append user message
-> provider stream assistant
-> if no tool calls: finish
-> validate tool calls
-> execute tools
-> append tool results
-> continue provider
-> until stop reason != toolUse
```

### 设计原则
1. tool execution 与 provider loop 解耦
2. 所有中间状态都 append 到 session
3. UI 不自己推断状态，全部靠订阅事件

---

## 9.3 工具执行策略

### MVP
- 先做 sequential

### P1
- 再做 parallel

### 原因
Pi 虽然默认支持 parallel tool execution，但 Zig 版第一阶段先做顺序执行更稳：
- 更容易保证 session 一致性
- 更容易实现 edit/write 冲突保护
- 更容易调试

后续再加：
- preflight
- beforeToolCall
- afterToolCall
- ordered event emission

---

## 9.4 Hook / Middleware 设计

Zig 版早期不要直接做 `ExtensionAPI` 那种复杂对象模型。

建议先设计为：

```text
AgentMiddleware
- before_input
- before_agent_start
- before_tool_call
- after_tool_result
- before_provider_request
- before_compaction
- before_tree_navigation
```

### 早期实现方式
先支持：
- 内建 middleware 链
- 后续再把 external plugin 接到这些 hook 上

这样核心不依赖插件系统也能成立。

---

## 10. TUI 实现方案

## 10.1 不要依赖 ncurses

建议直接基于：
- raw terminal mode
- ANSI escape sequences
- 自己做 lightweight renderer

### 原因
Pi 的 TUI 需要：
- markdown
- 流式更新
- overlay
- editor
- 图片
- 差分渲染

用 ncurses 反而会束手束脚。

---

## 10.2 渲染器策略

直接复用 `pi-tui` 的思想：

### 三种渲染路径
1. 首屏全量渲染
2. 宽度变化或高位变化时全量重绘
3. 常规情况下局部差分重绘

### 关键模块
- 组件树 render 成 `[]Line`
- 保存上一次 frame
- 找 first changed row
- cursor reposition + clearFromCursor + redraw tail

---

## 10.3 输入系统

需要支持：
- 普通按键
- 特殊键
- ctrl/alt/shift 组合
- 粘贴块
- 终端 resize

### 建议
设计独立输入事件：

```text
InputEvent
- key_press
- paste
- resize
- raw_bytes   // debug / fallback
```

然后 Editor / SelectList / App 各自消费。

---

## 10.4 MVP 组件

P0 组件：
- Text
- Editor
- Markdown（可以先做简化版）
- SelectList
- SettingsList
- Loader
- Container / Box / Spacer

P1 组件：
- Overlay
- 图片显示
- 自定义 footer/widget

### 现实建议
Markdown 不必一开始做完整 CommonMark。
先支持：
- 标题
- 列表
- 引用
- 代码块
- 行内 code

就够支撑 Pi 主界面了。

---

## 11. Session 与 Compaction 方案

## 11.1 Session 文件格式

建议直接采用：
- JSONL
- 第一行 header
- 后续 append-only

### 原因
- 易调试
- 易做 crash recovery
- 易做 tail / export / grep
- 与原版 Pi 设计一致

---

## 11.2 SessionManager 实现建议

职责：
- 读取 session 文件
- 建树索引
- append entry
- 切换 leaf
- build current context
- list sessions
- fork session

### 关键点
`buildSessionContext()` 必须是核心函数，因为：
- interactive mode 要用
- print mode 要用
- rpc mode 要用
- compaction 后也要重建

---

## 11.3 Compaction 实现策略

### P0
先做手动 `/compact`

### P1
再做自动 compaction

### 总结模型
- 找 cut point
- 抽取旧消息
- 调用当前模型或专门 compact model
- 生成 summary
- 追加 compaction entry
- build compacted context

### 一个非常重要的建议
**Compaction 本质上不是 provider 功能，而是 session/core 功能。**
所以应放在 `core/compaction.zig`，不要塞到 agent.zig 里。

---

## 12. 工具系统方案

## 12.1 Tool 抽象

建议统一结构：

```text
Tool
- name
- description
- parameter_schema
- execute()
- render_call()     // P1
- render_result()   // P1
```

### Zig 实现建议
- `ToolDefinition` + function pointers
- 参数 schema 先用 JSON schema-lite
- 或者先简单做“手写参数校验”

### 强烈建议
MVP 不要先做完整 JSON Schema 引擎。
你可以先支持：
- object
- string
- number
- bool
- enum
- required fields

已经足够支撑 read/write/edit/bash。

---

## 12.2 四个基础工具的实现建议

### `read`
- 文本文件读取
- 图片按 base64 返回
- offset/limit
- truncation 元信息

### `write`
- 原子写入（临时文件 + rename，P1）
- 自动 mkdir parents

### `edit`
- 严格 oldText 替换
- 支持单编辑与多编辑
- 返回 diff 概览

### `bash`
- spawn shell
- stdout/stderr 聚合
- timeout / cancel
- 超长输出截断并落盘

### 非常关键
`edit` 和 `write` 后续都要接“文件 mutation queue”，避免并行覆盖。

---

## 13. 配置与资源系统方案

## 13.1 配置文件

P0：
- `settings.json`
- `auth.json`
- `models.json`

P1：
- `keybindings.json`
- `themes/*.json`

### 设计原则
- 全部 JSON
- 明确全局与项目覆盖规则
- 相对路径解析必须稳定

---

## 13.2 ResourceLoader

这个模块会成为后期可扩展性的关键。

### 职责
- 找到 extensions / skills / prompts / themes / AGENTS
- 合并全局与项目资源
- 记录 source info
- 支持 reload

### MVP 范围
先支持：
- AGENTS.md
- prompt templates
- skills
- themes

扩展系统可以晚一点接进来。

---

## 14. Zig 版扩展机制怎么做

这是 Zig 方案里最需要重新设计的部分。

补充调研见：`docs/pi-zig-plugin-compatibility-research.md`


## 14.1 不建议复刻 TS 动态模块加载

原因：
- 跨平台动态装载 Zig 插件不稳定
- ABI 管理复杂
- 依赖分发复杂
- 不如 TS/npm 灵活

## 14.2 推荐方案：外部进程插件协议

也就是：

- 主程序是 Zig
- 插件可以是 Zig/Go/Python/Node 任意语言
- 主程序与插件通过 JSON-RPC / JSONL 通讯

### 插件能力
插件进程可：
- 注册工具
- 注册命令
- 订阅事件
- 返回 hook 结果

### 优势
1. 语言无关
2. 崩溃隔离
3. 更安全
4. 与未来 SDK/RPC 兼容
5. 容易形成生态

### 这很像什么
本质上你会得到一个“更适合 Zig 的 extension system”，而不是硬套 TS 模型。

---

## 14.3 Skills / Prompt Templates / Themes

这三类完全适合保留为数据驱动：

- `skills/` 目录 + `SKILL.md`
- `prompts/` 目录 + `.md`
- `themes/` 目录 + `.json`

这部分不需要改设计。

---

## 15. 模式实现方案

## 15.1 Print Mode

优先做。

### 流程
- 初始化资源
- 构建 session
- 发送 prompt
- 打印最终 assistant text
- 退出

### 价值
最快形成 MVP。

---

## 15.2 JSON Mode

第二优先级。

### 流程
- 与 print mode 使用同一 AgentSession
- 只是把事件逐条 JSONL 输出

### 价值
调试 provider / session / tool 最方便。

---

## 15.3 Interactive Mode

第三优先级。

### 流程
- App event loop
- TUI renderer
- Agent subscriber
- editor input dispatch

### 风险点
- 渲染闪烁
- resize 行为
- streaming 中输入与队列行为

---

## 15.4 RPC Mode

第四优先级。

### 设计原则
直接复用 JSON mode 的事件模型：
- stdin 收 command
- stdout 发 response/event
- 一律 JSONL

### 原因
这样最容易和 Web / IDE / test harness 对接。

---

## 16. MVP 范围（Zig 版）

## 16.1 必做

### 核心
- OpenAI-compatible provider
- Anthropic provider
- 统一消息模型
- agent loop
- 4 个内置工具
- print mode
- JSON mode
- session 持久化（先支持线性 append + 基础 tree 结构）
- settings/auth/models
- AGENTS + prompt templates + skills 基础加载

### 交互
- 最小 interactive mode
- editor
- message list
- model switch
- abort

## 16.2 可以推迟
- Google provider
- overlay
- 主题热更新
- keybindings 自定义
- 自动 compaction
- branch summary
- RPC extension UI 子协议
- 插件系统
- web-ui
- slack bot
- pods

---

## 17. P1 范围

- 自动 compaction
- session tree
- `/tree`
- `/fork`
- branch summary
- grep/find/ls
- settings panel
- theme system
- keybindings.json
- RPC mode
- SDK 风格库 API
- 外部进程插件协议 v1

---

## 18. P2 范围

- Google / OpenAI Responses / Azure / Bedrock
- 并行工具执行
- provider transport abstraction 完善
- 图片显示
- OAuth login
- package manager
- web 客户端
- Slack 集成

---

## 19. 关键难点与规避建议

## 19.1 难点：SSE / 流式 HTTP 稳定性

### 风险
不同 provider：
- SSE 行格式不同
- chunk 边界不可预测
- usage 结尾位置不同

### 规避
- 先只做两个 provider
- 提前把 stream parser 独立出来
- 大量 golden tests

---

## 19.2 难点：终端交互复杂

### 风险
- 不同终端键位差异
- 粘贴与 IME
- resize 问题

### 规避
- MVP 先做基础键位
- IME/图片/高级 overlay 后置
- JSON mode 先跑通业务逻辑

---

## 19.3 难点：扩展机制

### 风险
如果你执着于“像 TS 一样动态加载 Zig 扩展”，很容易失控。

### 规避
- MVP 不做内嵌扩展
- P1 做外部进程插件协议
- skills/prompts/themes 先满足大部分 customization

---

## 19.4 难点：会话树与 compaction

### 风险
这两者一旦设计错，后面补救代价很大。

### 规避
- session 一开始就用树结构
- compaction entry 一开始就预留
- context build 逻辑集中到一个模块

---

## 20. 具体开发顺序建议

### 第 1 周：Provider + Print Mode
- OpenAI-compatible provider
- Message/ContentBlock/Event 模型
- agent loop 最小版
- read/write/edit/bash
- print mode

### 第 2 周：Anthropic + Session
- Anthropic provider
- session.jsonl
- auth/settings/models
- AGENTS + prompt templates

### 第 3 周：Interactive TUI 最小版
- editor
- message list
- footer
- abort
- model switch

### 第 4 周：Skills + JSON mode + 稳定性
- skills 加载
- JSON mode
- 事件一致性修复
- 工具输出截断与错误处理

### 第 5~6 周：Session Tree + Compaction
- tree index
- `/tree`
- `/fork`
- manual compact
- auto compact

### 第 7~8 周：RPC + 插件协议草案
- RPC mode
- command set
- external plugin protocol v1

---

## 21. 最终推荐架构决策（我建议你直接采纳）

### 决策 1
**先做单仓模块化，不做 monorepo。**

### 决策 2
**先做 Zig Core，不做全生态复刻。**

### 决策 3
**Provider 只先支持 OpenAI-compatible + Anthropic。**

### 决策 4
**扩展系统不要照搬 TS，改成外部进程插件协议。**

### 决策 5
**TUI 纯 ANSI 自研轻量 renderer，不依赖 ncurses。**

### 决策 6
**Session 从第一天就用 JSONL tree 结构。**

### 决策 7
**所有模式共用一套 AgentEvent。**

### 决策 8
**先完成 Print + JSON + Interactive，再做 RPC。**

---

## 22. 如果你要我继续，我建议下一步做什么

接下来最有价值的是继续补两份落地文档中的一份：

### 方案 A：Zig 技术架构设计图
我帮你把上面方案收敛成：
- 核心模块图
- 调用链图
- 线程模型图
- session / event / provider 数据流图

### 方案 B：Zig 项目初始化与第一阶段任务清单
我直接给你：
- `build.zig` 结构
- `src/` 初始目录树
- 第一批 `.zig` 文件清单
- 每个文件要写什么接口
- 按优先级的 TODO backlog

---

## 23. 一句话结论

**用 Zig 做 Pi 是可行的，而且很适合做“Pi Core”。**

但正确姿势不是把 `pi-mono` 的 TS 生态逐字翻译成 Zig，而是：

> 用 Zig 重做一个更小、更稳、更适合终端和系统编程的 Pi 核心，
> 再用数据驱动资源和外部进程插件协议补上可扩展性。
