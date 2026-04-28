# Pi Monorepo 需求分析 / 功能文档

> 基于 `/home/like/workspace/pi-mono` 当前代码、README、各 package README 与 `packages/coding-agent/docs/*` 整理。
> 目标：为“从 0 实现一个 Pi / pi-mono 同类系统”提供完整功能边界、模块拆分、优先级与实现路线。

---

## 1. 文档目标

这份文档回答三个问题：

1. **Pi 到底是什么？**
2. **如果从 0 开始做，应该做哪些功能？**
3. **这些功能之间的依赖关系和实现优先级是什么？**

本文不是源码设计说明，而是偏 **产品需求分析 + 系统功能拆解 + 实施路线图**。

---

## 2. 一句话定义

**Pi 是一个“极简但高度可扩展”的 AI 编码终端代理系统。**

它的核心不是“内置尽可能多的产品功能”，而是：

- 提供一个可工作的默认编码代理
- 提供跨模型/跨厂商 LLM 抽象
- 提供稳定的 agent loop 和工具调用机制
- 提供终端 UI / RPC / SDK 等多种接入方式
- 把技能、扩展、主题、提示模板、第三方包做成可插拔生态

`pi-mono` 则是围绕这个目标的一整套 monorepo，包括：

- `pi-ai`：多模型/多厂商统一 LLM 层
- `pi-agent-core`：agent loop 与工具执行核心
- `pi-coding-agent`：面向用户的 CLI 编码代理
- `pi-tui`：终端 UI 组件库
- `pi-web-ui`：Web 端聊天 UI 组件
- `pi-mom`：Slack bot 形态
- `pi`（pods）：GPU pod/vLLM 部署管理工具

---

## 3. 产品愿景与设计原则

### 3.1 产品愿景

构建一个：

- 可以直接在终端中使用的编码代理
- 支持多模型、多鉴权方式、多运行模式
- 不强行绑定单一工作流
- 默认功能足够强，但核心保持小而稳
- 通过扩展生态覆盖复杂需求

### 3.2 设计原则

从文档与 README 中，Pi 的原则非常明确：

1. **最小内核**
  - 核心只保留高频且稳定的能力
  - 不把所有 workflow 都内建进主程序
2. **强扩展性优先于大而全**
  - 子代理、计划模式、权限弹窗、MCP 等不是强绑定内置能力
  - 建议通过 extension / skill / package 自己扩展
3. **多入口一致能力**
  - 交互式 TUI、print 模式、JSON 事件流、RPC、SDK 都应共享同一 agent 核心
4. **会话可持续、可分叉、可压缩**
  - session 不是简单线性聊天记录，而是可树状分支与恢复的工作上下文
5. **模型层与产品层解耦**
  - provider / model / auth / transport 变化，不应破坏上层 agent 与 UI
6. **默认可用，按需增强**
  - 初始提供 `read/write/edit/bash` 等工具即可完成大量编码任务
  - 高级能力通过插件化提供

---

## 4. 范围界定

如果你说“从 0 实现 pi-mono”，实际有两个层次：

### 4.1 核心产品范围（建议优先做）

这是最像“Pi 本体”的部分：

- `pi-ai`
- `pi-agent-core`
- `pi-tui`
- `pi-coding-agent`

### 4.2 生态扩展范围（第二阶段做）

这些不是最小闭环必需，但属于完整 pi-mono 生态：

- `pi-web-ui`
- `pi-mom`
- `pi-pods`

**建议：如果你要从 0 复刻，第一阶段只做核心产品范围。**

---

## 5. 用户角色与典型场景

### 5.1 主要用户

1. **个人开发者**
  - 在终端中让 AI 看代码、改代码、跑命令、解释问题
2. **AI 工具链开发者**
  - 想把 Pi 嵌入自己的产品，使用 SDK / RPC / web-ui
3. **团队平台工程师**
  - 需要接公司代理、SSO、自定义 provider、权限控制
4. **高级工作流用户**
  - 想通过 extension/skill/package 定制 plan mode、审批流、远程执行等
5. **运维/平台团队**
  - 用 pods 管理 GPU 上的模型部署
6. **团队协作场景用户**
  - 通过 mom 把代理接入 Slack

### 5.2 核心场景

1. 在项目目录启动 pi，直接让 AI 分析/修改代码
2. 切换模型、切换 thinking level
3. 运行 bash 命令并把结果纳入上下文
4. 会话保存、恢复、分叉、压缩
5. 扩展自定义命令/工具/界面
6. 通过 SDK / RPC 集成到其他应用
7. 在浏览器里构建基于相同核心能力的 chat UI
8. 在 Slack 中让代理长期工作
9. 在 GPU pod 上部署兼容 OpenAI 的本地/远程模型

---

## 6. 系统总体架构

## 6.1 分层结构

### A. 模型与协议层：`pi-ai`

职责：

- 封装不同 LLM provider 的 API 差异
- 统一流式事件模型
- 支持 tool calling、thinking、image、usage/cost、abort、cross-provider handoff

### B. Agent Runtime 层：`pi-agent-core`

职责：

- 管理消息状态
- 执行 agent loop
- 处理工具调用
- 发出统一事件

### C. 界面基础层：`pi-tui`

职责：

- 提供终端渲染、输入、选择器、Markdown、编辑器、图片等 UI 能力

### D. 产品层：`pi-coding-agent`

职责：

- CLI、交互模式、session 管理、资源发现
- 默认工具、命令、配置、模型选择、压缩、分支
- extension/skill/theme/package 生态

### E. 集成层

- `pi-web-ui`：浏览器 UI
- `pi-mom`：Slack 代理
- `pi-pods`：部署侧工具

---

## 7. 功能总览（按 package）

## 7.1 `@mariozechner/pi-ai` 需求

### 目标

为上层所有 agent 提供统一的 LLM 调用接口。

### 核心能力

1. **统一模型注册与查询**
  - `getProviders()`
  - `getModels(provider)`
  - `getModel(provider, id)`
2. **统一流式调用接口**
  - `stream()`
  - `complete()`
  - `streamSimple()`
  - `completeSimple()`
3. **统一消息模型**
  - user / assistant / toolResult
  - text / image / thinking / toolCall content blocks
4. **工具调用支持**
  - 定义工具 schema
  - 流式 tool call 参数解析
  - 参数校验与错误回传
5. **Thinking/Reasoning 支持**
  - 简化级别：off/minimal/low/medium/high/xhigh
  - 各厂商 provider-specific 映射
6. **多 provider 支持**
  - OpenAI
  - Anthropic
  - Google
  - Vertex
  - Mistral
  - Azure OpenAI
  - Bedrock
  - Groq / xAI / Cerebras / OpenRouter / Vercel AI Gateway / MiniMax / Kimi 等
  - OpenAI-compatible 自定义端点
7. **认证能力**
  - API key
  - OAuth
  - 环境变量
  - auth.json
8. **跨 provider 上下文接力**
  - 一个 provider 生成的消息，可继续交给另一 provider 使用
9. **上下文序列化**
  - Context 可 JSON 序列化/反序列化
10. **成本与 token 统计**
  - input/output/cache read/cache write/total/cost
11. **错误与中断处理**
  - abort signal
    - 错误消息保留 partial content

### 非功能要求

- provider 增加成本应低
- 上层不应感知底层厂商协议差异
- 事件格式稳定

---

## 7.2 `@mariozechner/pi-agent-core` 需求

### 目标

提供可复用的 agent runtime。

### 核心能力

1. **Agent 类**
  - 初始化 state
  - prompt / continue
  - abort / waitForIdle
  - subscribe
2. **Agent 状态管理**
  - systemPrompt
  - model
  - thinkingLevel
  - tools
  - messages
  - streamMessage
  - pendingToolCalls
  - error
3. **Agent loop**
  - 用户输入 → LLM → 工具调用 → 工具结果 → LLM continuation
4. **事件系统**
  - agent_start / agent_end
  - turn_start / turn_end
  - message_start / update / end
  - tool_execution_start / update / end
5. **工具执行模式**
  - parallel
  - sequential
6. **Hook 机制**
  - beforeToolCall
  - afterToolCall
7. **上下文转换能力**
  - transformContext
  - convertToLlm
  - 支持自定义消息类型
8. **消息队列**
  - steering
  - follow-up
9. **proxy 场景支持**
  - 可替换 streamFn

### 产品意义

`pi-agent-core` 是把 “LLM 通信” 和 “真正产品形态” 解耦的关键。

---

## 7.3 `@mariozechner/pi-tui` 需求

### 目标

支撑交互式终端产品。

### 核心能力

1. **TUI 容器与渲染器**
  - differential rendering
  - synchronized output
  - flicker-free 更新
2. **输入组件**
  - Input
  - Editor（多行）
  - autocomplete
  - kill ring / undo
3. **展示组件**
  - Text
  - Markdown
  - Box / Container / Spacer
  - Loader / CancellableLoader
  - SelectList / SettingsList
  - Image
  - overlay
4. **键盘输入处理**
  - 键位识别
  - keybinding 抽象
  - IME 支持
5. **终端图片支持**
  - Kitty / iTerm2 等协议

### 非功能要求

- 大量流式输出时仍稳定
- 光标定位正确
- 支持窄终端与窗口缩放

---

## 7.4 `@mariozechner/pi-coding-agent` 需求（主产品）

这是你从 0 实现时最应重点拆解的模块。

### 7.4.1 产品定位

Pi Coding Agent 是：

- 面向终端用户的 AI coding harness
- 基于 `pi-ai + pi-agent-core + pi-tui`
- 提供默认编码工具、会话、资源发现、交互命令与扩展生态

### 7.4.2 运行模式

必须支持四类模式：

1. **Interactive mode**
  - 全量 TUI 交互式界面
2. **Print mode**
  - 一次性问答，输出文本后退出
3. **JSON mode**
  - 以 JSONL 输出所有事件
4. **RPC mode**
  - 通过 stdin/stdout JSON 协议控制 agent
5. **SDK mode**
  - 作为库嵌入应用

> 实际落地优先级可设为：Interactive + Print → JSON → RPC → SDK。

---

## 8. Pi Coding Agent 详细需求

## 8.1 启动与初始化

### 功能要求

1. 启动时识别当前工作目录
2. 加载全局与项目级配置
3. 加载 AGENTS.md / CLAUDE.md / SYSTEM.md / APPEND_SYSTEM.md
4. 加载扩展、技能、提示模板、主题、包
5. 解析模型、provider、thinking level
6. 恢复最近会话或创建新会话
7. 启动后展示当前环境信息

### 必要输入源

- CLI flags
- `~/.pi/agent/settings.json`
- `.pi/settings.json`
- `~/.pi/agent/auth.json`
- `~/.pi/agent/models.json`
- session 文件
- AGENTS / SYSTEM 文件

### 验收标准

- 冷启动可进入默认模型与默认会话
- 配置优先级清晰且稳定

---

## 8.2 模型与 Provider 管理

### 功能要求

1. 选择 provider 和 model
2. 支持模型搜索、切换、循环切换
3. 支持 thinking level 切换
4. 支持 scoped models / enabledModels
5. 支持默认 provider/model
6. 支持会话恢复时恢复模型
7. 若恢复模型不可用，自动 fallback 并给出提示

### 自定义能力

1. 通过 `models.json` 增加自定义 provider/model
2. 通过 extension 注册/覆盖 provider
3. 支持代理地址、兼容参数、header、自定义 API key

### 鉴权要求

1. `/login` OAuth 登录
2. `/logout` 清理登录态
3. 环境变量读取
4. auth.json 持久化
5. API key resolution 优先级明确

---

## 8.3 消息输入与编辑器

### 功能要求

1. 多行输入
2. `@` 文件引用搜索
3. Tab 路径补全
4. `/` 命令补全
5. 粘贴图片
6. 终端拖拽图片
7. `!command` 执行 bash 并发送结果给 LLM
8. `!!command` 执行 bash 但不进入上下文
9. 外部编辑器打开（`$VISUAL` / `$EDITOR`）

### 消息队列要求

1. Enter：steering message
2. Alt+Enter：follow-up message
3. Escape：abort 并恢复排队消息
4. Alt+Up：取回已排队消息

### 验收标准

- 用户在 agent 正忙时也可继续输入
- 排队行为可配置（one-at-a-time / all）

---

## 8.4 内置工具系统

### 默认内置工具

P0：

- `read`
- `write`
- `edit`
- `bash`

P1：

- `grep`
- `find`
- `ls`

### 工具通用能力要求

1. 工具有 schema、描述、label
2. 工具调用可流式显示
3. 工具结果进入会话上下文
4. 工具可被扩展覆盖
5. 工具可动态启停
6. 工具调用前可拦截，调用后可改写结果
7. 文件变更型工具要支持并发保护

### 内置工具需求

#### `read`

- 读取文件内容
- 支持 offset / limit
- 支持图片读入
- 限制输出大小并标记截断

#### `write`

- 新建或覆盖文件
- 自动创建父目录

#### `edit`

- 精确替换文本
- 支持单段替换和多个 disjoint edits
- 强依赖 oldText 精确匹配

#### `bash`

- 执行命令
- 支持 timeout
- 返回 stdout/stderr/exitCode
- 输出超长时截断并保存 fullOutputPath

#### `grep/find/ls`

- 面向代码导航的只读能力

---

## 8.5 Agent 会话与上下文管理

### 会话要求

1. 会话持久化到 JSONL 文件
2. 会话按工作目录归档
3. 支持新会话、继续最近会话、打开指定会话
4. 支持无会话模式（ephemeral）
5. 支持设置 session name
6. 支持 session export/share

### 会话结构要求

1. 使用树结构，而非线性聊天记录
2. 每个 entry 有 `id` 与 `parentId`
3. 当前工作位置是 leaf 指针
4. 支持 branch/fork/tree navigation

### 需要持久化的实体

- SessionHeader
- message
- model_change
- thinking_level_change
- compaction
- branch_summary
- custom
- custom_message
- label
- session_info

### 设计价值

这决定 Pi 不是简单聊天工具，而是“可回溯工作流系统”。

---

## 8.6 分支、树导航与 Fork

### `/tree` 需求

1. 展示当前 session tree
2. 支持搜索、过滤、折叠/展开
3. 支持选择任一历史节点
4. 选择 user message 时，把文本放回 editor 重提
5. 选择非 user message 时，从该节点继续
6. 支持放弃当前分支时生成 branch summary

### `/fork` 需求

1. 从某个历史节点提取到新 session 文件
2. 保留来源 session 信息
3. 可选恢复该节点文本到编辑器

### branch summary 需求

1. 识别 common ancestor
2. 总结被放弃分支
3. 将 summary 以新 entry 注入新路径
4. 可带文件读写轨迹信息

---

## 8.7 Compaction（上下文压缩）

### 触发要求

1. 自动触发：接近 context window 上限
2. 溢出后自动恢复触发
3. 手动触发：`/compact [prompt]`

### 行为要求

1. 保留最近消息（按 token 预算）
2. 总结较老消息
3. 生成结构化 summary
4. 写入 compaction entry
5. 重建当前上下文
6. 失败时给出错误而不是静默

### 配置要求

- `compaction.enabled`
- `reserveTokens`
- `keepRecentTokens`

### 验收标准

- 长对话不会因为上下文溢出直接不可恢复
- 历史仍保存在 session 文件中

---

## 8.8 命令系统

### 内置命令需求

至少包括：

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
- `/share`
- `/reload`
- `/hotkeys`
- `/changelog`
- `/quit`
- `/exit`

### 命令能力要求

1. 命令支持 autocomplete
2. 命令可由 extension 注册
3. prompt template 映射为命令
4. skill 也可注册为 `/skill:name`

---

## 8.9 配置系统

### 配置层级

1. 全局：`~/.pi/agent/settings.json`
2. 项目：`.pi/settings.json`
3. CLI flags

### 配置类别

1. 模型与 thinking
2. UI 与显示
3. compaction
4. branch summary
5. retry
6. message delivery
7. terminal / images
8. shell
9. model cycling
10. markdown
11. resources（extensions/skills/prompts/themes/packages）

### 关键要求

- 项目配置覆盖全局配置
- 嵌套对象 merge
- 设置变更可热加载（至少交互模式下通过 `/reload`）

---

## 8.10 资源发现系统

这是 Pi 与普通命令行 agent 最大的差异之一。

### 需要发现的资源类型

1. Extensions
2. Skills
3. Prompt Templates
4. Themes
5. Packages
6. Context Files（AGENTS/SYSTEM）

### 发现来源

- 用户目录
- 项目目录
- 父目录向上递归
- package manifest
- settings
- CLI 显式指定路径

### 关键要求

- 统一的 `ResourceLoader`
- 支持 reload
- 每类资源都有来源信息 sourceInfo

---

## 8.11 Skills

### 目标

将复杂任务说明延迟加载为“能力包”。

### 功能要求

1. 启动时只暴露 skill name + description
2. 需要时用 `read` 加载完整 `SKILL.md`
3. 支持 `/skill:name` 强制调用
4. 支持标准 frontmatter
5. 支持 project/global/package/CLI 多来源
6. 支持 validation 与 collision warning

### 价值

- 降低系统 prompt 长度
- 提升特定任务质量
- 能携带脚本、参考资料与 setup 指令

---

## 8.12 Prompt Templates

### 功能要求

1. Markdown 文件定义模板
2. 文件名映射为 `/command`
3. 支持参数 `$1`、`$@`、`${@:N}`
4. 支持 description
5. 支持全局/项目/package/settings/CLI 多来源

### 价值

- 把高频提示词产品化
- 与 extension 命令形成互补

---

## 8.13 Extensions

### 定位

Extensions 是 Pi 最核心的“高级能力注入点”。

### 功能要求

1. TS 模块直接加载（无需预编译）
2. 可注册工具
3. 可注册命令
4. 可注册快捷键
5. 可注册 CLI flag
6. 可监听全生命周期事件
7. 可拦截输入、工具调用、provider request
8. 可注入消息与系统提示
9. 可自定义 compaction / branch summary
10. 可操作 UI（通知、状态栏、widget、footer、editor、自定义组件）
11. 可持久化自己的 session entry
12. 可注册/覆盖 provider

### 需要覆盖的事件面

- session_start / switch / fork / compact / tree / shutdown
- before_agent_start / agent_start / agent_end
- turn_start / turn_end
- message_start / update / end
- tool_call / tool_result / tool_execution_*
- input
- before_provider_request
- user_bash
- model_select

### 非功能要求

- 扩展错误不能直接拖垮整个主程序
- 需要错误隔离与 extension_error 事件

---

## 8.14 Themes 与 Keybindings

### Themes 需求

1. 支持内置 dark/light
2. 支持 JSON 自定义主题
3. 支持 51 个 color tokens
4. 支持主题热更新
5. 支持 HTML export 颜色配置

### Keybindings 需求

1. 所有动作有 namespaced id
2. 可由 `keybindings.json` 重绑定
3. `/reload` 后生效
4. 扩展可注册快捷键

---

## 8.15 交互式 UI

### 界面组成

1. Header：快捷键、已加载资源等
2. Messages：用户消息 / assistant / tool / 自定义消息
3. Editor：输入区
4. Footer：cwd / session / token / cost / context / model

### UI 能力要求

1. thinking block 可折叠
2. tool output 可折叠
3. 图片可内联显示
4. 状态栏可被扩展写入
5. editor 可被扩展替换
6. overlay/dialog 支持
7. 树导航、设置、模型选择等 TUI 界面

---

## 8.16 非交互模式

### Print Mode

- 输入 prompt
- 输出最终结果
- 结束进程

### JSON Mode

- 输出完整事件流 JSONL
- 适合脚本或管道接入

### RPC Mode

- stdin/stdout JSON 协议
- 支持 prompt / steer / follow_up / abort / set_model / get_state / compact 等命令
- 支持 extension UI request/response 子协议

### SDK Mode

- 在 Node/TS 里直接创建 `AgentSession`
- 可自定义 auth、resourceLoader、settings、sessionManager、tools

---

## 8.17 认证与安全边界

### 认证要求

1. OAuth providers
2. API key providers
3. auth.json 存储
4. environment variables
5. shell command 取 key
6. runtime override

### 安全原则

Pi 本身是“强能力工具”，默认并不以内置弹窗限制为核心特征。
因此从需求上要明确：

- 默认不做强侵入式 permission popup
- 安全策略通过 extension / sandbox / 自定义工具体系实现
- 第三方 package/skill/extension 都有高权限风险

---

## 9. `pi-web-ui` 需求

### 目标

把相同 agent 能力提供给浏览器/前端。

### 功能要求

1. ChatPanel 高层聊天组件
2. AgentInterface 低层组件
3. session 存储到 IndexedDB
4. provider key 存储
5. settings 存储
6. 自定义 provider 管理
7. artifact 面板
8. attachment 加载与预处理
9. JavaScript REPL 工具
10. extract-document 工具
11. tool renderer / message renderer 注册
12. CORS proxy 支持

### 定位

不是把 CLI 搬到 Web，而是提供 Web 端“同核心不同 UI”的构件库。

---

## 10. `pi-mom` 需求

### 目标

把 Pi agent 能力转成 Slack bot 工作形态。

### 功能要求

1. Slack Socket Mode 接入
2. 支持 channel / DM
3. 每个 channel 独立上下文
4. 持久化 log.jsonl / context.jsonl / MEMORY.md / skills /
5. 支持附件下载与分析
6. 支持 sandbox（Docker / host）
7. 支持事件唤醒（immediate / one-shot / periodic）
8. 可 attach 文件回 Slack
9. 上下文超长时 compaction
10. 可 grep 无限历史 log

### 产品特点

它更像“长驻型、自管理代理”，而不是一次性问答 CLI。

---

## 11. `pi` Pods 需求

### 目标

管理 GPU pod 上的 vLLM 模型部署。

### 功能要求

1. pod setup
2. pod active / remove / shell / ssh
3. 模型 start / stop / list / logs
4. 预置模型配置
5. 自动 GPU 分配
6. context / memory 参数映射
7. tool parser 自动配置
8. OpenAI-compatible endpoint 暴露
9. 自带测试 agent

### 定位

这是部署与推理基础设施工具，不是 coding agent 主功能，但在 monorepo 中构成完整自托管闭环。

---

## 12. 数据与文件格式需求

## 12.1 必要配置/数据文件

1. `settings.json`
2. `auth.json`
3. `models.json`
4. `keybindings.json`
5. `AGENTS.md`
6. `SYSTEM.md` / `APPEND_SYSTEM.md`
7. prompt template `.md`
8. skill `SKILL.md`
9. theme `.json`
10. session `.jsonl`

## 12.2 Session JSONL 必须支持

- 树结构 entry
- message entry
- compaction entry
- branch_summary entry
- custom entry
- label entry
- session_info entry

---

## 13. 非功能需求

## 13.1 可扩展性

- 新 provider、工具、命令、扩展应易于增加
- 资源系统支持动态发现与热重载

## 13.2 稳定性

- 流式输出不能频繁闪屏
- 扩展出错不能直接破坏主循环
- 工具执行失败要能恢复

## 13.3 性能

- 长 session 下仍可工作
- 文件读取和渲染要有截断/缓存策略
- 自动 compaction 降低上下文成本

## 13.4 可移植性

- 至少支持 macOS / Linux / Windows Terminal
- 不同 provider transport 差异要被抽象

## 13.5 可观测性

- JSON 模式输出完整事件
- RPC 模式可编程接入
- session 文件保留完整历史

## 13.6 安全性

- 配置文件权限合理（如 auth.json 0600）
- 明确第三方 package/skill/extension 风险
- 支持将实际安全约束外置到扩展/沙箱

---

## 14. 从 0 实现的推荐优先级

## 阶段 0：最小技术闭环

**目标：先跑通一个真正可用的编码 agent。**

### P0

- 单 provider（建议 OpenAI 或 Anthropic）
- 文本对话
- tool calling
- 4 个基础工具：read / write / edit / bash
- 简单 session 持久化（线性即可）
- print mode

### 交付标准

- 能读文件、改文件、运行命令并继续多轮对话

---

## 阶段 1：核心框架化

### P0

- 抽象 `pi-ai`
- 抽象 `pi-agent-core`
- 流式事件体系
- thinking level
- 多 provider 基础结构
- token/cost 统计

### 交付标准

- 模型层和 agent 层解耦

---

## 阶段 2：会话系统完善

### P0

- JSONL session
- session continue/new
- model/thinking 变更持久化
- auto compaction

### P1

- 树结构 session
- `/tree`
- `/fork`
- branch summary
- label / session name

---

## 阶段 3：交互式 TUI

### P0

- 消息区 + editor + footer
- 流式更新
- slash commands
- model selector
- settings panel

### P1

- thinking/tool 折叠
- 图片渲染
- overlay / custom component
- keybindings
- themes

---

## 阶段 4：资源与生态

### P0

- prompt templates
- skills
- extension system
- resource loader
- `/reload`

### P1

- pi packages
- 自定义 provider
- 自定义 UI

---

## 阶段 5：对外集成

### P0

- JSON mode
- RPC mode
- SDK

### P1

- web-ui
- Slack bot
- pods

---

## 15. MVP / P1 / P2 建议

## MVP（建议你自己先实现到这里）

- 单 provider
- `pi-ai` 最小版
- `pi-agent-core` 最小版
- `pi-coding-agent` CLI
- print mode + 简易 interactive mode
- read/write/edit/bash
- 简单 session
- 手动模型切换

## P1

- 多 provider
- thinking
- JSONL session tree
- compaction
- `/tree` / `/fork`
- settings
- prompt templates / skills

## P2

- extension system
- custom providers
- RPC / SDK
- themes / keybindings / package system
- web-ui / mom / pods

---

## 16. 明确的“非目标”

如果你想忠实复刻 Pi 的哲学，以下内容 **不应该一开始就硬编码进核心**：

1. 内置 plan mode
2. 内置 todo 管理
3. 内置 sub-agents
4. 内置 permission popup 框架
5. 强绑定 MCP
6. 大量产品 workflow 假设

这些应优先通过 extension 实现。

---

## 17. 最终建议：你应该怎么实现

如果你的目标是“从 0 做一个 Pi”，建议采用以下开发顺序：

1. **先做 `pi-ai` 最小层**
  - 统一消息模型
  - 单 provider streaming
  - tool calling
2. **再做 `pi-agent-core`**
  - agent loop
  - tool execution
  - events
3. **然后做 `pi-coding-agent` 的 print mode**
  - 最快看到产品闭环
4. **再做 interactive TUI**
  - editor / messages / footer
5. **再补 session tree + compaction**
  - 这是 Pi 区别于普通 chat CLI 的关键
6. **最后做扩展生态**
  - extension / skill / template / theme / package
7. **生态产品后置**
  - web-ui / mom / pods

---

## 18. 一页版结论

如果把 `pi-mono` 压缩成一句产品需求：

> 做一个以终端为主入口的可扩展 AI 编码代理平台：
> 上有交互式产品体验，中有稳定的 agent runtime，下有统一的多模型抽象；
> 同时允许通过 extension/skill/package 去定义自己的工作流，而不是把所有 workflow 硬编码进核心。

---

## 19. 我对你当前项目的建议

如果你现在是要在自己的项目里“从 0 实现 Pi”，建议你把工作拆成 3 份文档继续推进：

1. **PRD / 功能需求文档**（这份文档已经覆盖 80%）
2. **技术架构设计文档**
  - 模块关系
  - 数据流
  - session / tool / event 结构
3. **开发任务拆解 backlog**
  - 按周/按阶段拆 P0/P1/P2

如果你愿意，我下一步可以继续帮你补两份：

1. **《Pi 从 0 实现的技术架构设计》**
2. **《Pi MVP 开发任务清单（可直接开工）》**