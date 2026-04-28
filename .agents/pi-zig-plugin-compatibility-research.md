# Pi Zig 插件兼容方案调研

> 目标：在“不照搬 TS extension 机制”的前提下，评估 **如何兼容现有 pi 插件 / extension / package 生态**，并给出适合 Zig Core 的技术方案。

---

## 1. 结论先行

如果你的目标是：

> Zig 实现 Pi Core，同时尽量兼容现有 pi 插件生态

那最现实、性价比最高的方案不是：

- 在 Zig 内部直接解释/加载 TypeScript
- 也不是把现有 extension API 全量翻译成 Zig ABI 插件接口

而是：

> **采用“双轨插件架构”**
>
> 1. **原生 Zig 插件协议**：给未来 Zig/多语言插件用
> 2. **Node 兼容宿主（compat host）**：专门运行现有 pi 的 TS 插件

也就是说：

- **Zig Core 负责 agent、session、provider、tool、TUI、RPC**
- **Node Compat Host 负责加载 TS extension / npm 依赖 / pi package manifest / jiti 风格模块运行**
- Zig 和 Node 之间通过 **JSON-RPC / JSONL 事件总线** 对接

这是唯一一个既能保持 Zig 核心干净、又能最大程度兼容现有 pi 插件的路径。

---

## 2. 现有 pi 插件系统的事实基础

下面的结论基于 `pi-mono` 当前代码与文档：

- `packages/coding-agent/src/core/extensions/types.ts`
- `packages/coding-agent/src/core/extensions/loader.ts`
- `packages/coding-agent/src/core/extensions/runner.ts`
- `packages/coding-agent/examples/extensions/`*
- `packages/coding-agent/docs/extensions.md`
- `packages/coding-agent/docs/packages.md`

### 2.1 现有 extension 本质是什么

pi extension 不是简单“工具脚本”，而是一个 **可执行的 TypeScript 模块**，它可以：

1. 监听生命周期事件
2. 注册 LLM 可调用工具
3. 注册 slash command
4. 注册 shortcut / flag
5. 操作 UI
6. 发送消息给 agent
7. 修改 model / thinking / active tools
8. 注册 provider，甚至自己实现 `streamSimple`
9. 通过 npm 依赖引入第三方库

也就是说，现有 extension 系统其实是一个完整的 **可编程宿主运行时**。

### 2.2 现有 extension 是怎么加载的

根据 `loader.ts`：

- 通过 `@mariozechner/jiti` 动态加载 TS/JS 模块
- 支持从本地目录、package manifest、auto-discovery 位置发现 extension
- extension 可以依赖：
  - `@mariozechner/pi-coding-agent`
  - `@mariozechner/pi-agent-core`
  - `@mariozechner/pi-ai`
  - `@mariozechner/pi-tui`
  - `@sinclair/typebox`
  - 任意 npm package

这意味着：

> **现有插件兼容的关键不是“API 名字相同”而已，而是要兼容 Node + TS + npm + 动态模块加载这一整套运行环境。**

### 2.3 现有 extension API 的能力边界

从 `types.ts` 可以看出，extension API 主要分四类：

#### A. 注册类 API

- `pi.on(...)`
- `pi.registerTool(...)`
- `pi.registerCommand(...)`
- `pi.registerShortcut(...)`
- `pi.registerFlag(...)`
- `pi.registerMessageRenderer(...)`
- `pi.registerProvider(...)`

#### B. 动作类 API

- `pi.sendMessage(...)`
- `pi.sendUserMessage(...)`
- `pi.appendEntry(...)`
- `pi.setSessionName(...)`
- `pi.setLabel(...)`
- `pi.exec(...)`
- `pi.setModel(...)`
- `pi.setThinkingLevel(...)`
- `pi.setActiveTools(...)`

#### C. 查询类 API

- `pi.getFlag(...)`
- `pi.getActiveTools()`
- `pi.getAllTools()`
- `pi.getCommands()`
- `pi.getSessionName()`
- `pi.getThinkingLevel()`

#### D. Context / UI API

- `ctx.ui.select / confirm / input / editor`
- `ctx.ui.notify`
- `ctx.ui.setStatus / setWidget / setFooter / setHeader / setTitle`
- `ctx.ui.custom(...)`
- `ctx.ui.setEditorText / getEditorText / setEditorComponent`
- `ctx.sessionManager.`*
- `ctx.compact()`
- `ctx.shutdown()`

这说明现有插件兼容不是“只要支持工具”那么简单。

---

## 3. 现有插件生态使用了哪些能力

我对 `packages/coding-agent/examples/extensions/*` 做了一个快速扫描，结论很明确：

### 3.1 最常用能力

出现频率最高的是：

1. `pi.registerCommand`
2. `pi.on(...)`
3. `pi.registerTool`
4. `pi.sendUserMessage`
5. `pi.setActiveTools`
6. `pi.exec`
7. `pi.appendEntry`
8. `pi.registerProvider`

### 3.2 最常用事件

高频事件主要是：

- `session_start`
- `tool_call`
- `before_agent_start`
- `turn_start` / `turn_end`
- `agent_end`
- `session_before_switch` / `session_before_fork`
- `input`
- `before_provider_request`
- `tool_result`
- `model_select`
- `user_bash`

### 3.3 插件生态的真实分层

现有插件大概可分成 5 类：

#### 1. 轻量策略插件

例如：

- permission gate
- protected paths
- destructive confirm
- dirty repo guard

特点：

- 只监听事件
- 少量 UI confirm/select
- 几乎不需要复杂渲染

#### 2. 工具/命令类插件

例如：

- todo
- tools
- preset
- qna
- send-user-message

特点：

- 注册工具或命令
- 可能有 session state
- 可能有简单 custom UI

#### 3. 工作流插件

例如：

- plan-mode
- handoff
- git-checkpoint
- custom-compaction

特点：

- 深度使用 session、messages、tool hooks
- 需要较强的上下文一致性

#### 4. UI 插件

例如：

- modal-editor
- overlay-test
- doom-overlay
- custom-footer
- custom-header
- message-renderer

特点：

- 深度依赖 `@mariozechner/pi-tui`
- 对 UI 接口耦合高

#### 5. Provider 插件

例如：

- `custom-provider-anthropic`
- `custom-provider-gitlab-duo`
- `custom-provider-qwen-cli`

特点：

- 不只是注册 metadata
- 有的会自己实现 `streamSimple`
- 甚至带 OAuth 流程

结论：

> 如果你要“兼容 pi 插件”，真正要兼容的是一个 **事件驱动 + 工具注册 + UI 桥接 + provider 注入** 的运行时。

---

## 4. 直接在 Zig 里重做 TS extension 机制，为什么不划算

## 4.1 你要重做的不是 API，而是一整套宿主

如果直接在 Zig 里兼容现有 TS 插件，理论上你需要：

1. 支持动态加载 TS/JS
2. 支持 npm 依赖解析
3. 提供 `@mariozechner/pi-coding-agent` 等包的兼容实现
4. 提供 TypeBox / pi-ai / pi-tui 相关能力或 shim
5. 支持 async handler 执行
6. 支持 provider 自定义流式实现
7. 支持 custom UI component 运行

这几乎相当于：

> 在 Zig 里再内嵌一个 Node/JS 宿主。

这和“用 Zig 做干净的 Pi Core”的方向是冲突的。

## 4.2 动态链接 ABI 插件也不解决现有兼容问题

就算你改成 Zig 动态库插件：

- 现有 TS 插件不能直接复用
- npm package 生态不能复用
- 包管理方式完全变了
- `ctx.ui.custom` 这类高阶能力依旧难做

所以 Zig ABI 插件更适合“未来原生插件”，不适合“兼容现有 pi 插件”。

---

## 5. 可选兼容路线对比

## 5.1 方案 A：不兼容现有插件，只做 Zig 原生插件

### 优点

- 架构最干净
- 性能最好
- 没有 Node 依赖

### 缺点

- 现有 pi 插件生态全部失效
- 你需要自己重新建设插件生态
- 与“兼容 pi 插件”的目标冲突

### 结论

不满足需求。

---

## 5.2 方案 B：Zig 内嵌 JS/TS 运行时

### 优点

- 理论上可以直接兼容 TS 插件

### 缺点

- 实现成本极高
- 调试困难
- 仍要解决 npm/ESM/jiti/module resolution
- 最后本质上还是在 Zig 里重做 Node 宿主

### 结论

不推荐。

---

## 5.3 方案 C：Node Compat Host + Zig Core

### 核心思路

- Zig 是主程序
- Node sidecar 负责跑 TS 插件
- 双方通过 JSON 协议通讯

### 优点

- 对现有 pi 插件兼容度最高
- 保留 Zig Core 的边界清晰
- npm/TS/jiti 问题交给 Node 解决
- UI/事件/命令/工具/provider 可以逐步桥接

### 缺点

- 运行时多一个 sidecar
- 插件调用会有 IPC 开销
- UI 自定义能力需要桥接层设计

### 结论

**推荐方案。**

---

## 5.4 方案 D：外部进程插件协议，但不兼容 TS 插件 API

### 优点

- 最通用
- 多语言插件都能写

### 缺点

- 现有 pi TS 插件基本不能直接跑
- 只能说“有插件能力”，不能说“兼容 pi 插件”

### 结论

适合作为未来方向，不适合作为现有插件兼容主方案。

---

## 6. 推荐架构：双轨插件体系

## 6.1 总体结构

```text
+----------------------------+
|        Zig Pi Core         |
|----------------------------|
| provider / agent / tools   |
| session / tui / rpc        |
| resource loader            |
+-------------+--------------+
              |
              | JSON-RPC / JSONL Event Bus
              v
+----------------------------+
|     Node Compat Host       |
|----------------------------|
| jiti loader                |
| npm package resolution     |
| extension runtime shim     |
| pi package manifest loader |
+-------------+--------------+
              |
              v
+----------------------------+
| Existing pi TS Extensions  |
| Existing pi Packages       |
+----------------------------+
```

## 6.2 角色分工

### Zig Core 负责

- 会话与上下文
- provider 调用（默认）
- 内置工具
- TUI 主渲染
- session / compaction / tree / fork
- RPC / JSON mode
- 原生 Zig 插件协议

### Node Compat Host 负责

- 加载现有 TS extension
- 解析 package.json 与 `pi` manifest
- npm 依赖解析
- 事件分发到 extension handlers
- 执行 command/tool/provider hook
- 把 API 调用转发给 Zig Core

---

## 7. 兼容目标要分层，不要追求“一次全兼容”

建议定义 **4 级兼容**。

## 7.1 Level 0：资源兼容

直接兼容这些无需运行 TS 的资源：

- skills
- prompt templates
- themes
- package manifest 中的 `skills/prompts/themes`

### 结论

这部分应该 **原生 Zig 实现，100% 优先支持**。

---

## 7.2 Level 1：行为插件兼容

兼容大部分“事件 + 命令 + 工具”类插件：

- `pi.on(...)`
- `pi.registerCommand(...)`
- `pi.registerTool(...)`
- `pi.sendMessage / sendUserMessage`
- `pi.exec`
- `pi.setActiveTools`
- `pi.appendEntry`
- `pi.setSessionName`
- `pi.setLabel`

### 适用插件

- permission-gate
- protected-paths
- todo
- preset
- tools
- qna
- git-checkpoint
- handoff
- custom-compaction
- dynamic-tools
- file-trigger

### 结论

这部分应作为 **第一优先级的 TS 插件兼容范围**。

---

## 7.3 Level 2：UI 兼容

兼容这些 UI API：

- `ctx.ui.select / confirm / input / editor`
- `ctx.ui.notify`
- `ctx.ui.setStatus`
- `ctx.ui.setWidget`
- `ctx.ui.setTitle`
- `ctx.ui.setEditorText`

### 适用插件

- rpc-demo
- tools
- qna
- preset
- plan-mode
- timed-confirm
- questionnaire

### 结论

这部分可做，但要 **桥接成“远程 UI 协议”**，不能照搬 `@mariozechner/pi-tui` 组件对象模型。

---

## 7.4 Level 3：高级 UI / provider 兼容

这是最难的一层：

- `ctx.ui.custom(...)`
- `ctx.ui.setFooter / setHeader / setEditorComponent`
- `registerMessageRenderer`
- tool `renderCall / renderResult`
- `registerProvider(... streamSimple ...)`
- 自定义 OAuth

### 结论

这一层不要承诺“完全兼容”，而要分两类处理：

#### A. Provider 扩展

可以兼容，但要设计成 **remote provider bridge**

#### B. TUI 组件扩展

只能做“兼容子集”，不能完全兼容原始 TS 组件对象

---

## 8. Node Compat Host 应该怎么设计

## 8.1 Host 的目标

Node Compat Host 不应该再实现 agent 逻辑，它只做两件事：

1. **运行现有 pi extension**
2. **把 extension API 调用映射到 Zig Core 协议**

换句话说，它是一个：

> “pi TS extension 运行时兼容层”

而不是第二个 agent。

---

## 8.2 Host 对 extension 暴露什么 API

Compat Host 需要提供一个 shim 包，例如：

- `@mariozechner/pi-coding-agent`
- `@mariozechner/pi-ai`
- `@mariozechner/pi-tui`
- `@sinclair/typebox`

其中：

### `@sinclair/typebox`

直接用真实 npm 包即可。

### `@mariozechner/pi-ai`

优先只暴露 extension 常用的类型/辅助函数，比如：

- `StringEnum`
- provider 类型
- message/content 类型

### `@mariozechner/pi-tui`

只暴露兼容层能支持的 API；高级组件可先标记 unsupported。

### `@mariozechner/pi-coding-agent`

最关键，需提供：

- `ExtensionAPI`
- `ExtensionContext`
- `Theme` shim
- key helpers
- tool/result type guards

但它背后不再直接调 TS 主程序，而是通过 RPC 调 Zig Core。

---

## 8.3 Registration Phase 协议

插件加载时，现有 TS extension 会执行：

- `pi.on(...)`
- `pi.registerTool(...)`
- `pi.registerCommand(...)`
- `pi.registerProvider(...)`

所以 Compat Host 启动后应该：

1. 加载 extension
2. 收集注册信息
3. 发送给 Zig Core

### 示例协议

```json
{ "type": "register_command", "name": "todos", "description": "Show todos" }
{ "type": "register_tool", "name": "todo", "schema": {...} }
{ "type": "register_handler", "event": "tool_call" }
{ "type": "register_provider", "name": "custom-anthropic", "meta": {...} }
```

### 注意

真正的函数体仍在 Node Host 里，不会传给 Zig。
Zig 只记录：

- 哪个 extension 订阅了什么事件
- 哪个 command/tool/provider 由哪个 host-side handler 负责

---

## 8.4 Runtime Event 协议

当 Zig Core 有事件时，例如：

- `session_start`
- `before_agent_start`
- `tool_call`
- `tool_result`
- `turn_end`

它把事件发给 Compat Host：

```json
{
  "type": "event",
  "event": "tool_call",
  "payload": {
    "toolName": "bash",
    "toolCallId": "abc",
    "input": { "command": "rm -rf /tmp/x" }
  }
}
```

Compat Host 把事件分发给已注册的 TS handler，收集结果后回传：

```json
{
  "type": "event_result",
  "event": "tool_call",
  "results": [
    { "block": true, "reason": "Blocked by extension" }
  ]
}
```

---

## 8.5 Tool Execution 协议

对于 `registerTool` 注册的 TS 工具，Zig Core 不直接执行，而是代理给 Compat Host。

### 流程

1. LLM 调用某个 extension tool
2. Zig Core 识别该工具由 compat host 提供
3. 发 `execute_tool` 给 Host
4. Host 调用 extension 的 `execute(...)`
5. 若有 `onUpdate`，Host 持续回传 partial result
6. Zig Core 将其转成标准 tool_execution_update / end 事件

### 这意味着

- 现有 TS 工具可继续用
- session 仍由 Zig Core 主持
- tool result 最终仍进入 Zig session

---

## 8.6 Command 调用协议

slash command 同理：

1. 用户输入 `/xxx`
2. Zig Core 查到这是 compat host 的 command
3. 调 `execute_command`
4. Host 执行 `handler(args, ctx)`
5. 过程中调用 `ctx.ui.*` / `pi.sendMessage` 等，再转回 Zig

---

## 8.7 UI 兼容桥

这是兼容现有插件的关键折中点。

## 8.7.1 简单 UI：完全适合远程桥接

这些 API 非常适合做成 RPC：

- `select`
- `confirm`
- `input`
- `editor`
- `notify`
- `setStatus`
- `setWidget`
- `setTitle`
- `setEditorText`

本质上它们都是：

- 请求一个用户交互
- 或设置一段文本/状态

Zig TUI 完全可以实现。

## 8.7.2 高级 UI：不要承诺原样兼容

难点在于：

- `ctx.ui.custom(factory => Component)`
- `setFooter(factory)`
- `setHeader(factory)`
- `setEditorComponent(factory)`
- `registerMessageRenderer`
- tool `renderCall/renderResult`

因为这些都依赖 TS 里的对象模型和 `@mariozechner/pi-tui` 组件协议。

### 推荐做法

定义 **兼容子集**：

#### 方案 A：远程声明式 UI

Host 不返回可执行组件，而返回一个声明式 UI tree：

```json
{
  "type": "ui_tree",
  "kind": "list",
  "title": "Todos",
  "items": [...]
}
```

但这要求改写现有插件，不能“无修改兼容”。

#### 方案 B：高级 UI 交给 Compat Host 自己渲染

如果你未来允许 Node sidecar 直接接管一部分终端 UI，可以做 mixed rendering，但复杂度很高。

#### 方案 C：兼容策略降级

我建议明确：

- **简单 UI 全兼容**
- **高级组件 UI 做兼容白名单 / 降级策略**

例如：

- `ctx.ui.custom()` 在 compat mode 下只支持 select/list/form/dialog 几类模板
- `doom-overlay`、`modal-editor` 这类插件标记为“不完全兼容”

这是现实路线。

---

## 8.8 Provider 兼容桥

这是最容易被低估的难点。

现有插件里，`custom-provider-anthropic` 这类例子不只是注册 provider metadata，
它还可能：

- 实现自定义 `streamSimple`
- 自己做 OAuth
- 自己决定如何与上游 API 通讯

如果你要兼容这类插件，不能只把 provider 当配置项。

### 推荐做法：Remote Provider Bridge

让 Zig Core 允许 provider 的实现来源有两种：

1. **native provider**（Zig 实现）
2. **remote provider**（由 compat host 托管）

### 运行方式

当用户选择某个 compat-provider 模型时：

- Zig Core 把 `context + options` 发给 Host
- Host 执行 TS provider `streamSimple`
- Host 将流式事件回传给 Zig
- Zig 再把这些事件并入统一 AgentEvent 流

### 好处

- 自定义 provider 插件可以继续用
- Zig 不需要为每个特殊 provider 重写一次

### 代价

- provider 调用多一层 IPC
- 需要定义稳定的 assistant event protocol

但这是可控的。

---

## 9. 兼容 `pi package` 的策略

## 9.1 哪些 package 特性应原生支持

Zig Core 可以原生支持：

- `package.json` 的 `pi` manifest 读取
- `skills/prompts/themes` 目录规则
- git/npm/local path source 语义
- `sourceInfo` 与 scope 语义

## 9.2 哪些 package 特性交给 Compat Host

如果 package 里包含 `extensions`：

- Zig Core 只负责发现 package 和 manifest
- 真正 extension entrypoint 交给 Compat Host 加载

### 结果

这样一来：

- skills/prompts/themes 不依赖 Node
- TS extensions 依赖 Node compat host
- 对用户来说仍然是一个统一的 “pi package” 体验

---

## 10. 推荐的兼容边界定义

建议你在产品文档中明确声明三档兼容性。

## 10.1 Full Compatible

这些应尽量做到接近原版：

- skills
- prompts
- themes
- package manifest discovery
- command registration
- event hooks
- tool registration/execution
- simple UI dialogs
- session metadata
- sendMessage / sendUserMessage / appendEntry

## 10.2 Compatible with Limits

这些要声明“兼容但有边界”：

- custom provider
- status/widget/footer/header
- message renderer
- tool renderers
- input transform
- user_bash
- model_select / compaction / tree hooks

## 10.3 Not Fully Compatible

这些不要在第一阶段承诺：

- 任意 `ctx.ui.custom()` 组件
- 自定义 editor component
- 复杂 overlay / game / real-time animation
- 强依赖 `@mariozechner/pi-tui` 组件内部行为的插件

---

## 11. 你应该怎么落地实现

## 11.1 第一阶段

只做：

1. Zig Core 原生支持 skills/prompts/themes/packages
2. 定义 plugin IPC 协议
3. 做 Node Compat Host MVP
4. 支持这些 extension API：
  - `pi.on`
  - `pi.registerTool`
  - `pi.registerCommand`
  - `pi.sendMessage`
  - `pi.sendUserMessage`
  - `pi.appendEntry`
  - `pi.setActiveTools`
  - `pi.exec`
  - `ctx.ui.select/confirm/input/editor/notify/setStatus/setWidget/setTitle`

### 这样能跑什么

能覆盖现有大多数“真正有价值”的插件。

---

## 11.2 第二阶段

补齐：

- `registerProvider` + remote provider bridge
- `before_provider_request`
- `model_select`
- `user_bash`
- `session_before_compact` / `session_before_tree`
- `getCommands/getAllTools/getActiveTools`
- package install/update/remove 工作流

---

## 11.3 第三阶段

再考虑：

- 高级 UI 兼容子集
- message renderer/tool renderer 兼容
- custom editor / overlay 降级适配
- Zig 原生插件 SDK

---

## 12. 最终建议

如果你问我：

> Zig 版 Pi 想兼容现有 pi 插件，到底应该怎么做？

我的建议很明确：

### 不要做的事

- 不要在 Zig 内嵌 TS 运行时
- 不要直接把 TS extension API 翻译成 Zig ABI 插件
- 不要第一阶段承诺高级 TUI 组件全兼容

### 要做的事

1. **资源类（skills/prompts/themes/packages）原生 Zig 支持**
2. **TS extension 通过 Node Compat Host 运行**
3. **Zig 与 Host 通过 JSON-RPC / JSONL 协议通信**
4. **优先兼容 command/tool/event/simple UI/provider bridge**
5. **高级 TUI 扩展做兼容子集，不承诺完全透明兼容**

---

## 13. 一句话结论

> Zig 版 Pi 要兼容现有 pi 插件，最合理的方案不是“把 TS extension 系统重写成 Zig”，而是“让 Zig Core 成为主引擎，再用 Node Compat Host 作为现有 pi 插件的兼容运行时”。

这样你既保住了 Zig Core 的边界和性能，也最大化复用了现有 pi extension / package 生态。