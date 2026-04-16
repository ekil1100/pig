# Pig v0.2 技术设计文档

## 1. 文档目标

这份文档回答四个问题：

1. Pig v0.2 的代码应该怎么拆
2. 各模块之间怎么协作
3. 关键数据结构和接口怎么定
4. 第一版实现时有哪些边界和取舍

本文基于当前的 `agent.ts` 单文件实现，以及 `pig-v0.2-prd.md` 中定义的 MVP 范围。

---

## 2. 当前状态

当前版本的 Pig 具备一个最小可运行的 agent loop：

- 从终端读取用户输入
- 调用 Gemini `generateContent`
- 处理 function call
- 本地执行工具
- 将工具结果回传给模型
- 输出最终文本

当前实现的问题也很明确：

1. 所有逻辑集中在一个文件里
2. 没有会话持久化
3. 没有命令执行确认
4. 没有文件编辑确认
5. 没有本地 slash commands
6. 没有显式的日志和状态模型
7. 工具实现和 CLI/UI 紧耦合

v0.2 的任务不是推翻重写，而是在保留现有核心 loop 的基础上，把它整理成可持续演进的结构。

---

## 3. 设计目标

v0.2 的技术设计遵循下面几条原则：

1. **先拆清边界，再补功能**
   - 优先把模型调用、会话、工具执行、CLI 交互拆开

2. **保留现有思路，不做过度抽象**
   - 仍然保持一个简单的 agent loop
   - 不引入复杂框架

3. **交互安全优先于自动化**
   - `run_bash` 和 `edit_file` 都要走用户确认

4. **所有关键行为都可记录、可恢复**
   - 会话、工具事件、确认结果都要有落盘表示

5. **模块设计要给 v0.3 留扩展位**
   - 比如 future patch engine、更多工具、模型参数、权限策略

---

## 4. 总体架构

建议将 v0.2 拆成五层：

```text
CLI 输入层
  -> slash commands
  -> 普通用户消息

Agent Runtime 层
  -> 组织消息上下文
  -> 驱动模型调用
  -> 调度工具执行

Model Adapter 层
  -> 封装 Gemini HTTP API

Tool Runtime 层
  -> list_files
  -> read_file
  -> run_bash
  -> edit_file

Persistence / UI 层
  -> session 存储
  -> tool event 存储
  -> confirm prompt
  -> 渲染输出
```

### 4.1 运行流程

主流程如下：

1. CLI 启动
2. 加载环境变量和运行配置
3. 创建或恢复 session
4. 收集项目上下文
5. 进入输入循环
6. 如果输入是 slash command，本地处理
7. 如果输入是普通消息，追加到 session messages
8. 进入 agent loop：
   - 调用模型
   - 如果返回文本，输出并写入 session
   - 如果返回 tool call，进入工具调度流程
9. 工具调度流程：
   - 记录 tool event
   - 如需确认，显示 prompt
   - 执行工具或拒绝执行
   - 把 tool result 写回消息上下文
   - 持久化 session
10. 继续 agent loop，直到模型返回最终文本

---

## 5. 目录结构

建议目录如下：

```text
agent.ts
src/
  cli/
    repl.ts
    commands.ts
  core/
    agent-loop.ts
    model.ts
    session.ts
    context-loader.ts
    types.ts
  tools/
    index.ts
    list-files.ts
    read-file.ts
    run-bash.ts
    edit-file.ts
  ui/
    confirm.ts
    render.ts
    format.ts
sessions/
```

### 5.1 模块职责

#### `agent.ts`
- 进程入口
- 加载 env
- 初始化依赖
- 启动 REPL

#### `src/cli/repl.ts`
- 负责用户输入循环
- 识别 slash commands
- 将普通输入交给 `agent-loop`

#### `src/cli/commands.ts`
- 定义 `/help`、`/tools`、`/history`、`/resume`、`/clear`、`/exit`
- 这些命令直接本地执行，不进入模型上下文

#### `src/core/agent-loop.ts`
- 驱动模型与工具的主循环
- 接收 session、用户输入和依赖对象
- 输出最终 assistant 文本或错误

#### `src/core/model.ts`
- 负责 Gemini API 请求
- 屏蔽 HTTP 细节
- 暴露统一的 `generate` 接口

#### `src/core/session.ts`
- 创建、加载、保存、列出会话
- 负责 session 文件命名和 JSON 序列化

#### `src/core/context-loader.ts`
- 启动时读取项目基础上下文
- 如存在则读取 `README.md`、`AGENTS.md`、`package.json`

#### `src/core/types.ts`
- 统一定义 message、tool event、session、tool result 等类型

#### `src/tools/*`
- 各工具独立实现
- 不直接负责与模型交互
- 通过统一接口被调度

#### `src/ui/confirm.ts`
- 统一处理确认交互
- 支持 `y/n` 风格确认

#### `src/ui/render.ts`
- 输出工具状态、结果摘要、错误信息

#### `src/ui/format.ts`
- 负责改动预览、命令展示等格式化输出

---

## 6. 核心数据模型

### 6.1 Message 模型

延续现有 Gemini message 结构，但需要显式类型化：

```ts
type FunctionCall = {
  name: string;
  args: Record<string, unknown>;
};

type FunctionResponsePart = {
  name: string;
  response: {
    name: string;
    content: string;
  };
};

type MessagePart = {
  text?: string;
  functionCall?: FunctionCall;
  functionResponse?: FunctionResponsePart;
};

type CtxMessage = {
  role: "user" | "model" | "function" | "system";
  parts: MessagePart[];
};
```

说明：
- v0.2 沿用现有 Gemini 所需格式即可
- 不额外做 provider-agnostic 抽象
- `system` 是否真正进入 `contents` 可由 model adapter 处理

### 6.2 Session 模型

```ts
type Session = {
  id: string;
  createdAt: string;
  updatedAt: string;
  cwd: string;
  model: string;
  title?: string;
  messages: CtxMessage[];
  toolEvents: ToolEvent[];
  projectContext?: ProjectContext;
};
```

### 6.3 ToolEvent 模型

```ts
type ToolEventStatus =
  | "pending"
  | "confirmed"
  | "rejected"
  | "success"
  | "error";

type ToolEvent = {
  id: string;
  name: string;
  args: Record<string, unknown>;
  status: ToolEventStatus;
  startedAt: string;
  finishedAt?: string;
  summary?: string;
  error?: string;
};
```

### 6.4 ProjectContext 模型

```ts
type ProjectContext = {
  rootPath: string;
  topLevelEntries: string[];
  readme?: string;
  agentsMd?: string;
  packageJson?: string;
  loadedAt: string;
};
```

### 6.5 ToolResult 模型

```ts
type ToolResult = {
  ok: boolean;
  content: string;
  summary: string;
};
```

说明：
- `content` 给模型看
- `summary` 给人看，也用于日志
- 这样可以避免 CLI 原样打印长输出

---

## 7. 模型适配层设计

### 7.1 接口定义

`src/core/model.ts` 提供统一函数：

```ts
type ModelRequest = {
  messages: CtxMessage[];
  systemPrompt: string;
  tools: GeminiToolDeclaration[];
  model: string;
};

type ModelResponse = {
  parts: MessagePart[];
  raw: unknown;
};

async function generate(request: ModelRequest): Promise<ModelResponse>
```

### 7.2 实现要点

1. 继续使用 Gemini HTTP API
2. API key 从环境变量读取
3. 默认模型可以保留为 `gemini-2.5-flash`
4. 错误分为：
   - 配置错误
   - 网络错误
   - API 非 2xx 错误
   - 响应结构错误

### 7.3 为什么单独抽出 model adapter

因为当前版本把 HTTP 请求直接写在 agent loop 里，后续一旦：
- 改模型名
- 加模型参数
- 换 provider
- 做测试 mock

都会变得很难处理。

v0.2 不需要多模型支持，但需要先把边界留出来。

---

## 8. Agent Loop 设计

### 8.1 接口定义

```ts
type AgentDependencies = {
  model: {
    generate(request: ModelRequest): Promise<ModelResponse>;
  };
  toolRegistry: ToolRegistry;
  sessionStore: SessionStore;
  ui: UI;
};

async function runAgentTurn(
  session: Session,
  userText: string,
  deps: AgentDependencies,
): Promise<{ session: Session; output: string }>
```

### 8.2 行为定义

一次 `runAgentTurn` 负责：

1. 把用户输入追加到 `session.messages`
2. 调用模型
3. 如果是普通文本：
   - 追加 assistant message
   - 保存 session
   - 返回输出
4. 如果包含 tool call：
   - 顺序处理每一个 tool call
   - 为每次调用生成 `ToolEvent`
   - 执行工具
   - 把工具结果追加为 function message
   - 保存 session
   - 再次调用模型
5. 直到得到最终文本响应

### 8.3 顺序执行策略

v0.2 采取顺序执行，不做并行工具调用。

原因：
1. 当前工具都很轻量
2. CLI 中并行确认交互复杂度高
3. 顺序执行更容易调试和记录

---

## 9. Tool Runtime 设计

### 9.1 统一工具接口

```ts
type ToolContext = {
  cwd: string;
  ui: UI;
};

type ToolDefinition<TArgs = Record<string, unknown>> = {
  name: string;
  description: string;
  parameters: unknown;
  requiresConfirmation?: boolean;
  execute(args: TArgs, ctx: ToolContext): Promise<ToolResult>;
};
```

### 9.2 工具注册表

```ts
type ToolRegistry = {
  declarations: unknown[];
  get(name: string): ToolDefinition | undefined;
  list(): ToolDefinition[];
};
```

`declarations` 用于传给 Gemini 的 `functionDeclarations`。

### 9.3 `list_files`

职责：
- 列出指定目录内容

要求：
- 默认基于当前 `cwd`
- 错误时返回明确提示
- 输出做长度控制，避免一次性返回超长列表

### 9.4 `read_file`

职责：
- 读取文件内容

要求：
- 不存在时给出明确错误
- 大文件时应考虑截断策略
- 返回内容时保留原文，不擅自格式化

### 9.5 `run_bash`

职责：
- 运行 shell 命令

设计：
- `requiresConfirmation = true`
- 执行前显示命令
- 用户确认后再执行
- 默认使用 `bash -lc`
- 记录 exit code、stdout、stderr
- 需要 timeout

结果摘要建议：
- 成功：`command succeeded (exit 0)`
- 失败：`command failed (exit X)`
- 拒绝：`command rejected by user`

### 9.6 `edit_file`

职责：
- 通过字符串替换编辑文件

设计：
- `requiresConfirmation = true`
- 分三种模式：
  1. 创建文件
  2. 唯一匹配替换
  3. 失败
- 多匹配和零匹配必须显式报错
- 写入前显示 old/new 预览

v0.2 不做 patch 模式，仍保留简单实现。

---

## 10. 确认交互设计

### 10.1 接口定义

```ts
type ConfirmationRequest =
  | {
      kind: "run_bash";
      command: string;
    }
  | {
      kind: "edit_file";
      path: string;
      oldString: string;
      newString: string;
      mode: "create" | "replace";
    };

async function confirm(request: ConfirmationRequest): Promise<boolean>
```

### 10.2 交互原则

1. 确认信息必须是本地生成，不交给模型决定
2. 默认选项为拒绝
3. 输入非 `y/yes` 时按拒绝处理
4. 用户拒绝应写入 `ToolEvent`

---

## 11. Session Store 设计

### 11.1 存储方式

v0.2 使用本地 JSON 文件存储，不引入数据库。

目录：

```text
sessions/
  <session-id>.json
```

### 11.2 文件命名

建议 session id 使用：

```text
YYYYMMDD-HHmmss-<random>
```

例如：

```text
20260414-201530-a1b2c3
```

优点：
- 人眼可读
- 文件按时间自然排序
- 不依赖额外库也好实现

### 11.3 接口定义

```ts
type SessionStore = {
  create(initial: Partial<Session>): Promise<Session>;
  save(session: Session): Promise<void>;
  load(id: string): Promise<Session>;
  list(): Promise<Array<Pick<Session, "id" | "createdAt" | "updatedAt" | "cwd" | "title">>>;
  latest(): Promise<Session | null>;
};
```

### 11.4 写盘策略

1. 每次 turn 结束后保存一次
2. 每次工具调用结束后保存一次
3. 使用临时文件写入后再 rename，尽量避免写坏

---

## 12. 项目上下文加载设计

### 12.1 目标

启动时给模型最基本的项目认知，但不把上下文塞得过满。

### 12.2 加载策略

默认尝试读取：

1. 顶层目录列表
2. `README.md`
3. `AGENTS.md`
4. `package.json`

### 12.3 注入策略

不建议把这些文件直接塞进 `systemPrompt` 原文里。更合适的方式是：

1. 保存在 `session.projectContext`
2. 启动时生成一条本地整理过的上下文摘要
3. 作为第一条 system-like context 传给模型

例如：

```text
Project context:
- cwd: ...
- top-level entries: ...
- README present: yes
- AGENTS.md present: yes
- package.json present: yes
```

如果文件内容较短，也可以附上节选。

### 12.4 边界

v0.2 不做：
- 递归索引
- embedding 检索
- 自动摘要历史文件

---

## 13. CLI 命令设计

### 13.1 slash commands

支持以下本地命令：

- `/help`
- `/tools`
- `/history`
- `/resume [sessionId]`
- `/clear`
- `/exit`

### 13.2 命令处理接口

```ts
type CommandResult = {
  handled: boolean;
  shouldExit?: boolean;
  nextSession?: Session;
};

async function handleCommand(input: string, ctx: CommandContext): Promise<CommandResult>
```

### 13.3 `/clear` 语义

`/clear` 只清当前对话上下文，不删除当前 session 文件。

建议行为：
- 新建一个空消息列表
- 保留 `cwd`、`model` 和 `projectContext`
- 记录一次 clear event

这样既满足“清空上下文”，也保留调试价值。

---

## 14. UI/输出设计

### 14.1 输出分类

CLI 输出分四种：

1. assistant 文本
2. 工具调用提示
3. 确认提示
4. 错误提示

### 14.2 输出原则

1. assistant 文本尽量干净
2. 工具调用只显示必要信息
3. 长输出可截断，并提示已截断
4. 错误要带上下文，但不要堆栈刷屏

### 14.3 建议格式

工具调用：

```text
[tool] run_bash
command: git status
```

工具结果：

```text
[tool] run_bash completed
exit code: 0
```

---

## 15. 错误处理设计

### 15.1 错误分类

#### 配置错误
- 缺少 `GEMINI_API_KEY`

#### 模型错误
- API 失败
- 响应结构异常

#### 工具错误
- 文件不存在
- 替换失败
- 命令执行失败
- 命令超时

#### 用户拒绝
- command rejected
- edit rejected

### 15.2 错误传播原则

1. 工具错误不应导致整个进程退出
2. 错误应作为工具结果的一部分回传给模型
3. 同时在 CLI 中明确显示给用户

---

## 16. 测试策略

v0.2 不要求一开始就有完善测试，但建议至少覆盖下面几类：

### 16.1 单元测试优先级

1. session store 的保存和加载
2. `edit_file` 的唯一匹配、多匹配、零匹配
3. `run_bash` 的确认拒绝逻辑
4. slash commands 的本地处理逻辑

### 16.2 集成测试场景

1. 启动新会话
2. 恢复旧会话
3. 运行命令并确认
4. 修改文件并确认
5. 读不存在文件

---

## 17. 实现边界与取舍

### 17.1 这版故意不做的东西

1. 并行工具调用
2. 复杂 diff 算法
3. 数据库存储
4. 模型切换 UI
5. 自动权限策略

### 17.2 这样取舍的原因

因为 v0.2 的核心问题不是能力不足，而是结构不稳、交互不安全、状态不可恢复。

先把这些补齐，项目才真的从 demo 跨进工具阶段。

---

## 18. 建议的实现顺序

推荐按这个顺序推进：

1. 抽 `types.ts`
2. 抽 `model.ts`
3. 抽 `session.ts`
4. 抽 `tools/*`
5. 实现 `confirm.ts`
6. 重写 `agent-loop.ts`
7. 加 `commands.ts` 和 `repl.ts`
8. 加 `context-loader.ts`
9. 更新 README

这个顺序的原因很简单：先把骨架立住，再加交互层。

---

## 19. 一句话结论

v0.2 的技术重点不是“让 agent 更聪明”，而是把现在这份单文件实现整理成一个边界清晰、可恢复、可确认、可继续扩展的本地 coding agent CLI。
