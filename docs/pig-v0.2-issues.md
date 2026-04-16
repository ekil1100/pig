# Pig v0.2 issue 拆解

## 1. 文档目标

这份文档把 `pig-v0.2-prd.md` 和 `pig-v0.2-technical-design.md` 拆成可执行的实现任务。

目标不是列一个很长的愿望清单，而是给出：

1. 每个 issue 要解决什么问题
2. 它依赖什么
3. 完成标准是什么
4. 建议的实现顺序是什么

---

## 2. 里程碑划分

建议把 v0.2 拆成 4 个 milestone：

### M1. Runtime 拆分
目标：把单文件实现拆成基本模块，保证后续功能有地方落。

### M2. 可恢复会话
目标：让 Pig 具备本地会话创建、保存、恢复能力。

### M3. 安全交互
目标：给命令执行和文件修改加确认机制。

### M4. CLI 可用性
目标：补 slash commands、上下文加载、README 和验收用例。

---

## 3. Issue 列表

## Issue 1：提取共享类型定义

### 背景
当前 `agent.ts` 中的类型定义和实现逻辑耦合在一起，后续拆模块时会出现重复定义和循环依赖。

### 目标
建立 `src/core/types.ts`，集中定义运行时共享类型。

### 交付物
- `src/core/types.ts`
- 所有旧类型从 `agent.ts` 挪走或重定向引用

### 需要包含的类型
- `FunctionCall`
- `MessagePart`
- `CtxMessage`
- `Session`
- `ToolEvent`
- `ToolResult`
- `ProjectContext`

### 依赖
- 无

### 完成标准
1. `agent.ts` 不再持有大段内联类型定义
2. 其余模块可直接从 `types.ts` 引用共享类型

---

## Issue 2：提取 Gemini model adapter

### 背景
当前 Gemini HTTP 调用直接写在 agent loop 里，后续加配置、测试、错误处理都会很乱。

### 目标
建立 `src/core/model.ts`，统一封装模型调用。

### 交付物
- `src/core/model.ts`
- 暴露 `generate()` 或同等接口

### 需要解决的问题
- API key 读取
- 请求 body 构建
- 非 2xx 错误处理
- 响应结构校验

### 依赖
- Issue 1

### 完成标准
1. `agent.ts` 或后续 `agent-loop.ts` 不再直接拼 HTTP 请求
2. 模型错误能分成配置错误、请求错误和响应错误

---

## Issue 3：建立 session store

### 背景
当前会话只存在内存里，CLI 一退出上下文就丢了。

### 目标
建立 `src/core/session.ts`，支持本地 JSON 会话存储。

### 交付物
- `src/core/session.ts`
- `sessions/` 目录的创建逻辑

### 功能要求
- 创建新 session
- 保存 session
- 加载指定 session
- 列出历史 session
- 获取最新 session

### 依赖
- Issue 1

### 完成标准
1. 新会话能落盘
2. 退出后重启能恢复
3. session 文件结构清晰可读

---

## Issue 4：拆出工具模块和工具注册表

### 背景
当前工具定义写在 `call()` 的 switch 里，不利于扩展，也不方便做统一确认和日志。

### 目标
把四个工具拆成独立模块，并提供统一注册表。

### 交付物
- `src/tools/index.ts`
- `src/tools/list-files.ts`
- `src/tools/read-file.ts`
- `src/tools/run-bash.ts`
- `src/tools/edit-file.ts`

### 功能要求
- 每个工具独立导出 definition
- 提供 Gemini 需要的 declaration
- 提供统一的 `execute()`

### 依赖
- Issue 1

### 完成标准
1. `switch` 风格的工具分发被移除
2. 新增工具不需要改核心 loop 的控制流

---

## Issue 5：实现确认交互组件

### 背景
命令执行和文件写入当前是直接执行，缺少最基本的安全边界。

### 目标
建立统一确认入口，供 `run_bash` 和 `edit_file` 使用。

### 交付物
- `src/ui/confirm.ts`
- 统一的确认请求和确认结果结构

### 功能要求
- 支持 `run_bash` 确认
- 支持 `edit_file` 确认
- 默认拒绝
- 非 `y/yes` 视为拒绝

### 依赖
- Issue 4

### 完成标准
1. 未确认前不会执行命令
2. 未确认前不会写文件
3. 用户拒绝结果可进入日志和 session

---

## Issue 6：实现 tool event 日志模型

### 背景
当前工具执行只有即时打印，没有结构化日志，不方便恢复和排错。

### 目标
让每次工具调用都生成结构化 `ToolEvent`。

### 交付物
- `ToolEvent` 写入 session
- 事件状态流转：`pending -> confirmed/rejected -> success/error`

### 依赖
- Issue 1
- Issue 3
- Issue 4
- Issue 5

### 完成标准
1. 每次工具调用都能在 session 文件里找到事件记录
2. 拒绝、失败、成功能区分开

---

## Issue 7：重构 agent loop

### 背景
当前主循环把输入、模型调用、工具处理、输出混在一起，不方便继续加能力。

### 目标
建立 `src/core/agent-loop.ts`，负责单轮 agent 执行。

### 交付物
- `src/core/agent-loop.ts`
- 一个清晰的 `runAgentTurn()` 接口

### 要求
- 普通文本流程可工作
- tool call 流程可工作
- tool result 可回传模型
- 每个关键节点会保存 session

### 依赖
- Issue 2
- Issue 3
- Issue 4
- Issue 5
- Issue 6

### 完成标准
1. 主流程从 `agent.ts` 中移出
2. loop 逻辑清晰，便于测试

---

## Issue 8：实现 slash commands

### 背景
当前 CLI 只有自由文本输入，没有本地命令体系。

### 目标
建立 `src/cli/commands.ts`，处理基础命令。

### 交付物
- `/help`
- `/tools`
- `/history`
- `/resume`
- `/clear`
- `/exit`

### 依赖
- Issue 3
- Issue 4

### 完成标准
1. slash commands 不进入模型上下文
2. `/help` 能解释主要命令
3. `/history` 和 `/resume` 能访问 session store

---

## Issue 9：实现 REPL 层

### 背景
当前输入循环直接写在 `main()` 里，不适合承接命令和会话切换。

### 目标
建立 `src/cli/repl.ts`，统一处理：
- 用户输入
- slash commands
- 普通消息
- 退出逻辑

### 依赖
- Issue 7
- Issue 8

### 完成标准
1. `agent.ts` 只负责初始化和启动
2. REPL 可以处理普通消息和本地命令两类输入

---

## Issue 10：实现项目上下文加载

### 背景
当前模型每次都是从零开始，不知道当前项目是什么。

### 目标
建立 `src/core/context-loader.ts`，在会话开始时读取基础项目上下文。

### 交付物
- 顶层目录列表
- `README.md` 读取
- `AGENTS.md` 读取
- `package.json` 读取

### 依赖
- Issue 1
- Issue 3

### 完成标准
1. 新 session 启动时可附带项目上下文
2. 缺失文件不会阻断启动

---

## Issue 11：改进 `run_bash` 的结果展示

### 背景
当前 shell 输出直接拼接字符串，exit code、stdout、stderr 混在一起，可读性一般。

### 目标
规范 `run_bash` 的输出结构和 CLI 渲染。

### 交付物
- 标准化 command result
- 长输出截断策略
- timeout 提示

### 依赖
- Issue 4
- Issue 5
- Issue 6

### 完成标准
1. 用户能明确知道命令是否成功
2. 输出过长时 CLI 不会刷屏失控

---

## Issue 12：改进 `edit_file` 的错误与预览

### 背景
当前 `edit_file` 的成功和失败语义比较粗糙，实际用起来不够稳。

### 目标
提高编辑前预览和错误信息质量。

### 交付物
- 创建模式预览
- 替换模式预览
- 多匹配/零匹配错误信息

### 依赖
- Issue 4
- Issue 5
- Issue 6

### 完成标准
1. 写入前用户能看懂要改什么
2. 错误提示能指导下一步修复

---

## Issue 13：更新 README

### 背景
文档需要和 v0.2 的能力对齐，否则别人看不出这个版本已经从 demo 进化到可用 CLI。

### 目标
更新 README，覆盖：
- 安装
- 启动
- slash commands
- 会话保存
- 命令确认
- 文件修改确认

### 依赖
- Issue 8
- Issue 9
- Issue 10

### 完成标准
1. 新用户只看 README 能跑起来
2. README 中的功能描述与实际行为一致

---

## Issue 14：补基础验收脚本或手动验收清单

### 背景
v0.2 的关键是可用性，至少要有固定的验收方法。

### 目标
建立一份可重复执行的验收清单，必要时附最小脚本。

### 验收场景
1. 启动新 session
2. 恢复旧 session
3. 运行 `git status` 并拒绝执行
4. 修改 README 并确认写入
5. 读取不存在文件并返回错误

### 依赖
- 前面所有核心 issue

### 完成标准
1. v0.2 发布前可以按清单验证功能
2. 清单可以作为后续回归依据

---

## 4. 推荐实现顺序

推荐按下面的顺序开工：

1. Issue 1：提取共享类型定义
2. Issue 2：提取 Gemini model adapter
3. Issue 3：建立 session store
4. Issue 4：拆出工具模块和工具注册表
5. Issue 5：实现确认交互组件
6. Issue 6：实现 tool event 日志模型
7. Issue 7：重构 agent loop
8. Issue 8：实现 slash commands
9. Issue 9：实现 REPL 层
10. Issue 10：实现项目上下文加载
11. Issue 11：改进 `run_bash` 的结果展示
12. Issue 12：改进 `edit_file` 的错误与预览
13. Issue 13：更新 README
14. Issue 14：补基础验收清单

---

## 5. 第一批必须完成的 issue

如果你只想先把 v0.2 的骨架立住，第一批最低要求是：

- Issue 1
- Issue 2
- Issue 3
- Issue 4
- Issue 5
- Issue 7
- Issue 8
- Issue 9

完成这批之后，Pig 就已经从“教学 demo”进入“基本可用 CLI”的阶段了。

---

## 6. 一句话结论

v0.2 不需要一口气把所有事情做完。先把 runtime、session、confirmation 和 CLI 命令体系立起来，这个项目就已经值钱很多了。
