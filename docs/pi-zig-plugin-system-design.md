# Pi Zig 插件系统设计

> 前提调整：**不以兼容现有 pi TS 插件为目标**。
> 目标改为：为 Zig 版 Pi 设计一个更合理、更稳定、更容易实现和演进的插件系统；同时提供一个“迁移旧插件”的 skill，帮助把旧 pi 插件迁移到新体系。

---

## 1. 新前提下的设计目标

既然“不强求兼容现有 pi 插件”，那插件系统就不该再围着 TS runtime、jiti、npm 动态模块加载去设计。

新的目标应该是：

1. **核心稳定**
  - Zig Core 不依赖 JS runtime
  - 插件崩溃不拖垮主进程
2. **多语言友好**
  - 插件可以用 Zig、Go、Rust、Python、Node 来写
  - 插件边界是协议，不是 ABI
3. **能力分层清晰**
  - 不是所有插件都能随便接管一切
  - 从“资源插件”到“运行时插件”逐层开放
4. **可测试、可调试**
  - 插件交互全部走 JSON/JSONL 协议
  - 可以录制、回放、mock
5. **易迁移**
  - 老的 pi extension 不直接兼容，但可以半自动迁移
  - 通过 skill 帮助把旧插件改造成新插件

---

## 2. 总体结论

推荐采用 **三层插件体系**：

### Layer 1: 数据型插件

纯文件资源，不执行代码：

- skills
- prompt templates
- themes
- model/provider config fragments

### Layer 2: 声明式插件

通过 manifest + action 声明能力，不直接执行任意逻辑：

- commands
- tool metadata
- menu entries
- settings panels
- simple guards / rules

### Layer 3: 进程型插件

独立进程，通过 JSON-RPC/JSONL 与 Zig Core 通信：

- 自定义工具
- 自定义命令
- hook/middleware
- provider bridge
- 自定义工作流

> 不做进程内动态脚本插件。

这是最合理的方向。

---

## 3. 为什么这种设计更适合 Zig

## 3.1 不做进程内插件的理由

进程内插件的问题：

- ABI 不稳定
- 跨平台动态库复杂
- 版本耦合强
- 崩溃隔离差
- 多语言生态差

而 Pi 这类工具的插件，本质上更像：

- 一个能收事件、发命令、注册工具的“外部智能模块”

所以更适合 **外部进程协议**，而不是进程内 ABI。

## 3.2 JSON 协议天然适配 Pi

Pi 的核心边界本来就偏文本：

- session.jsonl
- rpc jsonl
- settings/auth/models json
- skills/prompt/theme 文件

插件系统继续走 JSON/JSONL，整体会非常统一。

---

## 4. 插件系统总体架构

```text
+--------------------------------+
|           Zig Pi Core          |
|--------------------------------|
| agent / provider / session     |
| tools / tui / rpc / settings   |
| plugin manager                 |
+---------------+----------------+
                |
                | JSON-RPC / JSONL
                v
+--------------------------------+
|        External Plugin         |
|--------------------------------|
| commands / tools / hooks       |
| provider bridge / workflow     |
+--------------------------------+
```

---

## 5. 插件类型设计

## 5.1 数据型插件（Data Plugin）

### 适用对象

- skills
- prompts
- themes
- provider/model presets
- command presets

### 形式

一个目录，里面只有数据文件与 manifest：

```text
my-plugin/
├── plugin.json
├── skills/
├── prompts/
├── themes/
└── models/
```

### 适用场景

- 团队共享 prompt/skill/theme
- 不需要执行代码
- 安全需求更高

### 好处

- 零运行时依赖
- 易安装
- 易审计

---

## 5.2 声明式插件（Declarative Plugin）

### 目标

覆盖最常见的“轻逻辑插件”，让很多插件不需要写代码。

### 可以支持的能力

- 注册命令
- 配置命令模板
- 提供工具定义（转发到 shell/HTTP）
- 添加前置规则
- 添加简单 path protection / command allowlist
- 定义 settings UI

### 例子

```json
{
  "name": "safe-mode",
  "version": "0.1.0",
  "commands": [
    {
      "name": "review",
      "description": "Review current changes",
      "promptTemplate": "Review the current diff for bugs and risks."
    }
  ],
  "guards": [
    {
      "on": "tool_call",
      "tool": "bash",
      "match": "rm -rf",
      "action": "block",
      "reason": "Dangerous command blocked by safe-mode"
    }
  ]
}
```

### 适用场景

- preset
- protected-paths
- permission rules
- simple command packs

### 好处

- 很多轻插件不用写程序
- Zig Core 直接可执行
- 可验证、可静态分析

---

## 5.3 进程型插件（Process Plugin）

### 目标

承载真正复杂的扩展逻辑。

### 能力范围

- 注册工具
- 注册命令
- 订阅事件
- 返回 hook 结果
- 请求 UI 交互
- 执行外部命令
- 提供 provider bridge

### 形式

```text
my-plugin/
├── plugin.json
├── bin/
│   └── plugin
└── README.md
```

或者：

```json
{
  "name": "my-plugin",
  "runtime": {
    "type": "process",
    "command": ["python3", "main.py"]
  }
}
```

### 为什么不是语言绑定 SDK 起步

因为协议优先：

- SDK 可以后面补
- 协议先定下来，谁都能实现

---

## 6. 插件清单文件设计

建议统一使用 `plugin.json`。

## 6.1 最小结构

```json
{
  "name": "my-plugin",
  "version": "0.1.0",
  "description": "Adds workflow helpers",
  "kind": "process",
  "entry": {
    "command": ["./bin/plugin"]
  }
}
```

## 6.2 完整结构建议

```json
{
  "name": "my-plugin",
  "version": "0.1.0",
  "description": "Adds workflow helpers",
  "kind": "process",
  "capabilities": {
    "commands": true,
    "tools": true,
    "hooks": ["before_agent_start", "tool_call", "tool_result"],
    "ui": ["select", "confirm", "input", "editor", "notify", "status", "widget"]
  },
  "entry": {
    "command": ["./bin/plugin"]
  },
  "resources": {
    "skills": ["./skills"],
    "prompts": ["./prompts"],
    "themes": ["./themes"]
  },
  "permissions": {
    "network": true,
    "shell": true,
    "filesystem": "plugin-dir"
  }
}
```

---

## 7. 核心协议设计

## 7.1 生命周期

### 启动阶段

1. Zig Core 扫描插件目录
2. 读取 `plugin.json`
3. 若为 process plugin，则启动外部进程
4. 发送 `initialize`
5. 插件返回它要注册的 commands/tools/hooks

### 运行阶段

- Zig Core 向插件广播事件
- 插件按需返回结果
- 命令和工具由 Zig Core 调度执行

### 关闭阶段

- Zig Core 发 `shutdown`
- 插件优雅退出

---

## 7.2 初始化协议

### Core -> Plugin

```json
{
  "type": "initialize",
  "protocolVersion": 1,
  "pluginRoot": "/path/to/plugin",
  "cwd": "/current/project",
  "session": {
    "id": "...",
    "file": "..."
  },
  "core": {
    "version": "0.1.0"
  }
}
```

### Plugin -> Core

```json
{
  "type": "initialize_result",
  "commands": [
    { "name": "todos", "description": "Show todos" }
  ],
  "tools": [
    {
      "name": "todo",
      "description": "Manage todos",
      "inputSchema": {
        "type": "object",
        "properties": {
          "action": { "type": "string", "enum": ["list", "add"] }
        },
        "required": ["action"]
      }
    }
  ],
  "hooks": [
    "tool_call",
    "session_start"
  ]
}
```

---

## 7.3 事件协议

### Core -> Plugin

```json
{
  "type": "event",
  "event": "tool_call",
  "payload": {
    "toolName": "bash",
    "toolCallId": "abc",
    "input": { "command": "rm -rf build" }
  }
}
```

### Plugin -> Core

```json
{
  "type": "event_result",
  "event": "tool_call",
  "result": {
    "block": true,
    "reason": "blocked by plugin"
  }
}
```

### 规则

- 某些 hook 是 observation-only
- 某些 hook 是 interceptable
- Zig Core 负责决定如何合并多个插件结果

---

## 7.4 工具协议

### Core -> Plugin

```json
{
  "type": "tool_execute",
  "tool": "todo",
  "toolCallId": "call_123",
  "input": {
    "action": "list"
  }
}
```

### Plugin -> Core（流式更新）

```json
{
  "type": "tool_update",
  "toolCallId": "call_123",
  "partialResult": {
    "content": [{ "type": "text", "text": "loading..." }]
  }
}
```

### Plugin -> Core（结束）

```json
{
  "type": "tool_result",
  "toolCallId": "call_123",
  "result": {
    "content": [{ "type": "text", "text": "done" }],
    "details": {}
  },
  "isError": false
}
```

---

## 7.5 命令协议

### Core -> Plugin

```json
{
  "type": "command_execute",
  "command": "todos",
  "args": ""
}
```

### Plugin -> Core

命令执行过程中可以继续发送：

- `ui_request`
- `send_message`
- `set_status`
- `set_widget`

最终：

```json
{
  "type": "command_result",
  "command": "todos",
  "success": true
}
```

---

## 8. UI 设计边界

## 8.1 插件不直接操作 TUI 组件对象

这条非常重要。

不要让插件返回某种“可执行组件对象”给 Zig。因为这会把 Zig TUI 和插件语言运行时绑死。

### 正确做法

插件只能调用 **声明式 UI API**：

- `select`
- `confirm`
- `input`
- `editor`
- `notify`
- `set_status`
- `set_widget`
- `set_title`
- `set_editor_text`

### Widget 也应声明式

例如：

```json
{
  "type": "ui_widget_set",
  "key": "plan-todos",
  "placement": "aboveEditor",
  "lines": [
    "☐ task 1",
    "☑ task 2"
  ]
}
```

## 8.2 不支持任意 custom component

这意味着新插件系统里：

- 不提供原版 `ctx.ui.custom(factory)` 这种无限制接口
- 而是提供受控 UI primitives

这是合理收敛，不是能力退化。

因为 Pi 的可维护性比无限制 UI 注入更重要。

---

## 9. 新插件 API 设计建议

如果后面你要给插件作者提供 SDK，建议先做一个语言无关的抽象，再做各语言 SDK。

## 9.1 API 分组

### Registration API

- registerCommand
- registerTool
- subscribe(event)

### Action API

- sendMessage
- sendUserMessage
- appendEntry
- setSessionName
- setLabel
- setActiveTools
- exec
- compact
- shutdown

### UI API

- select
- confirm
- input
- editor
- notify
- setStatus
- setWidget
- setTitle
- setEditorText

### Query API

- getSessionInfo
- getContextUsage
- getModel
- getThinkingLevel
- getActiveTools
- getCommands

### 注意

不要设计成“回调地狱式对象 API”，而应设计成简单的 request/response 协议。

---

## 10. 事件模型建议

建议保留与 Pi 接近的事件语义，但做少量收敛。

## 10.1 第一阶段开放的 hook

- `session_start`
- `session_switch`
- `before_agent_start`
- `agent_start`
- `agent_end`
- `turn_start`
- `turn_end`
- `tool_call`
- `tool_result`
- `input`
- `model_select`

## 10.2 第二阶段开放的 hook

- `before_provider_request`
- `session_before_compact`
- `session_compact`
- `session_before_tree`
- `session_tree`
- `user_bash`

## 10.3 为什么不一开始全开放

因为每开放一个 hook，都会增加：

- 协议复杂度
- 状态一致性成本
- 调试难度

所以应按价值分批开放。

---

## 11. 安全模型建议

## 11.1 插件权限声明

建议 `plugin.json` 强制声明权限：

```json
{
  "permissions": {
    "filesystem": "plugin-dir",
    "network": true,
    "shell": false,
    "providerBridge": false
  }
}
```

## 11.2 Core 侧执行策略

- 默认不给插件直接文件系统全权限
- 默认不给插件任意 TUI 注入能力
- 默认不给插件任意 provider 接管能力
- 高权限能力要显式声明

## 11.3 为什么这次可以比原版更收敛

因为你已经明确：

- 不需要完全兼容旧插件
- 所以新系统可以在安全边界上设计得更合理

---

## 12. 安装与分发建议

## 12.1 插件来源

支持三类：

- 本地路径
- git 仓库
- registry（后期）

## 12.2 安装目录

建议统一：

```text
~/.pig/plugins/
.project/.pig/plugins/
```

## 12.3 插件管理命令

建议后续支持：

- `pig plugin list`
- `pig plugin install <source>`
- `pig plugin remove <name>`
- `pig plugin enable <name>`
- `pig plugin disable <name>`
- `pig plugin inspect <name>`

---

## 13. 迁移旧插件的 skill

既然不强求兼容，就很适合提供一个 **migration skill**。

## 13.1 Skill 目标

帮助用户把旧的 pi TS extension：

- 分析结构
- 分类
- 映射到新插件系统
- 生成迁移方案
- 自动产出新插件骨架

## 13.2 Skill 名称建议

- `pi-plugin-migrator`
- 或 `migrate-pi-extension`

我建议用：

```text
migrate-pi-extension
```

---

## 13.3 Skill 触发描述建议

```md
---
name: migrate-pi-extension
description: Analyze an existing pi TypeScript extension and migrate it to the Zig Pi plugin system. Use when the user wants to port an old pi extension, convert hooks/tools/commands to the new plugin protocol, or generate a new plugin skeleton from an old extension.
---
```

---

## 13.4 Skill 的执行步骤

### Step 1: 读取旧插件

- 读取旧 `index.ts` / `.ts` 文件
- 识别：
  - events
  - commands
  - tools
  - provider registration
  - UI API usage
  - session state usage

### Step 2: 分类插件类型

输出它属于哪类：

- 资源型
- 声明式可迁移
- 进程型插件
- 高级 UI 插件
- provider bridge 插件

### Step 3: 输出迁移结论

判断是：

- 直接改成数据型插件
- 改成声明式插件
- 改成进程型插件
- 需要部分重写
- 暂不建议迁移

### Step 4: 生成迁移骨架

自动生成：

- `plugin.json`
- `README.md`
- 新插件入口文件
- 协议处理骨架
- TODO 列表

### Step 5: 输出人工改造点

例如：

- 原 `ctx.ui.custom()` 无法直接迁移
- 原 `registerProvider(streamSimple)` 需改成 provider bridge
- 原 `registerMessageRenderer` 需改成 widget/status/command UI

---

## 13.5 Skill 输出模板建议

```md
## Migration Summary
- Old extension type: workflow plugin
- Recommended target: process plugin
- Migration complexity: medium

## Features detected
- Commands: /todos
- Tools: todo
- Hooks: session_start, session_tree, session_switch
- UI: custom dialog

## Migration mapping
- pi.registerCommand -> plugin command registration
- pi.registerTool -> process tool registration
- pi.on(session_start) -> event subscription
- ctx.ui.custom -> replace with editor/select/widget primitives

## Files to generate
- plugin.json
- src/main.py
- README.md

## Manual rewrite required
- Replace custom TUI component with select/editor flow
```

---

## 14. 推荐实施顺序

## Phase 1

- 数据型插件
- 声明式插件
- 进程型插件协议 v1
- commands/tools/hooks/simple UI

## Phase 2

- provider bridge
- package manager
- migration skill

## Phase 3

- 多语言 SDK
- 更丰富的声明式 UI
- 插件测试工具链

---

## 15. 最终建议

如果你现在已经决定“不强求兼容旧 pi 插件”，那我建议你就彻底放弃“兼容宿主”路线，改成下面这个更干净的方案：

### 新插件系统原则

1. **资源优先**：skills/prompts/themes 原生支持
2. **声明优先**：简单插件尽量不用写代码
3. **协议优先**：复杂插件统一走独立进程协议
4. **UI 收敛**：只提供声明式 UI primitives
5. **多语言友好**：不绑定 JS/TS
6. **迁移靠 skill，不靠 runtime 兼容**

---

## 16. 一句话结论

> Zig 版 Pi 最合理的插件系统，不是“兼容旧 TS extension runtime”，而是“原生支持资源插件 + 声明式插件 + 进程型插件”，再通过一个 `migrate-pi-extension` skill 帮助旧插件迁移到新体系。

