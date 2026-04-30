# Pig v1.0 M0 Implementation Plan：Zig 0.16 工程基础

> 本文是 `pig-v1.0-roadmap.md` 中 M0 的执行计划。
>
> M0 的目标不是实现 agent 功能，而是建立一个稳定、可测试、可演进的 Zig 0.16 工程骨架，让后续 M1 provider、M2 agent runtime、M3 tools 可以直接落地。

## 1. M0 目标

M0 要解决的问题：

1. 明确 Pig v1.0 Zig 版的工程入口。
2. 固定 Zig 0.16 的构建方式。
3. 建立模块边界和依赖方向。
4. 建立最小 CLI、版本信息、配置路径检测。
5. 建立测试、fixtures、错误分类、allocator 策略。
6. 确保所有后续 milestone 都能在同一套基础上开发。

M0 不做：

- 不接真实 LLM provider。
- 不实现 agent loop。
- 不实现文件编辑、bash 执行等 tools。
- 不实现完整 TUI。
- 不实现 session JSONL 正式格式。
- 不引入 plugin/RPC/web/slack/pods 功能。

## 2. 目录结构

当前 Pig v1.0 Zig 实现位于 repo root。不要再创建 `zig/` 子目录，也不要恢复旧的 demo 入口。

```text
.
├── build.zig
├── build.zig.zon
├── README.md
├── docs/
│   ├── architecture.md
│   ├── error-model.md
│   ├── fixtures.md
│   └── allocator-policy.md
├── fixtures/
│   ├── README.md
│   ├── pi-mono/
│   │   ├── package-list.json
│   │   ├── package-readmes.json
│   │   └── cli-samples.jsonl
│   └── fake-provider/
│       └── empty-turn.jsonl
├── src/
│   ├── main.zig
│   ├── version.zig
│   ├── app/
│   │   ├── cli.zig
│   │   └── build_info.zig
│   ├── core/
│   │   ├── mod.zig
│   │   ├── errors.zig
│   │   └── ids.zig
│   ├── provider/
│   │   └── mod.zig
│   ├── tools/
│   │   └── mod.zig
│   ├── session/
│   │   └── mod.zig
│   ├── resources/
│   │   └── mod.zig
│   ├── tui/
│   │   └── mod.zig
│   ├── rpc/
│   │   └── mod.zig
│   ├── plugin/
│   │   └── mod.zig
│   └── util/
│       ├── mod.zig
│       ├── paths.zig
│       ├── json.zig
│       └── testing.zig
└── test/
    ├── smoke.zig
    ├── cli.zig
    └── fixtures.zig
```

M0 只需要让这些模块能编译，并提供最小公开 API。模块内部可以先是空实现或 placeholder，但依赖方向必须从第一天保持正确。

## 3. 构建系统

### 3.1 `build.zig`

M0 的 `build.zig` 需要支持：

- `zig build`
- `zig build run`
- `zig build test`
- `zig build smoke`
- `zig build fmt-check`

建议 build steps：

```text
install       构建主二进制
run           运行主二进制
test          运行单元测试
smoke         运行不依赖网络、不依赖 API key 的 smoke tests
fmt-check     检查 Zig 格式
```

主二进制名称固定为 `pig`。后续不使用 `pig-zig` 作为临时名称；Zig 实现是 repo root 的唯一当前实现。

### 3.2 `build.zig.zon`

M0 阶段尽量不要加第三方依赖。

原则：

- 优先 pure Zig stdlib。
- 不引入 HTTP、CLI parser、JSON 第三方库。
- 后续 M1 如果 stdlib HTTP/TLS 不够，再单独评估 curl transport。

### 3.3 Zig 版本检测

M0 需要在 README 或 docs 中写明：

```bash
zig version
```

必须是 Zig 0.16 系列。

如果 Zig build API 能读取版本信息，则在 `zig build` 时做软提示；如果不方便，不要为了版本检测写复杂逻辑，先以文档和 CI 检查为准。

## 4. 最小 CLI 行为

M0 的 CLI 只做诊断和基础信息展示。

### 4.1 支持命令

```bash
pig --version
pig --help
pig doctor
pig paths
```

行为：

- `--version`：输出 Pig 版本、Zig 版本、build mode、target。
- `--help`：输出当前可用命令，并明确说明 agent 功能尚未实现。
- `doctor`：检查当前运行环境。
- `paths`：输出 Pig 后续会使用的关键路径。

### 4.2 `doctor` 检查项

M0 只做本地基础检查：

- 当前工作目录。
- home 目录是否可解析。
- 全局配置目录候选路径。
- 项目配置目录候选路径。
- session 目录候选路径。
- fixtures 目录是否存在。
- 是否能创建临时测试目录。

不检查：

- API key。
- provider 连通性。
- git 状态。
- shell 安全策略。

### 4.3 `paths` 输出

建议输出 machine-readable 友好的文本，后续可扩展为 JSON：

```text
cwd: /path/to/project
home: /home/user
global_config: /home/user/.pi/agent/settings.json
global_auth: /home/user/.pi/agent/auth.json
global_models: /home/user/.pi/agent/models.json
global_sessions: /home/user/.pi/agent/sessions
project_config: /path/to/project/.pi/settings.json
project_resources: /path/to/project/.pi
```

## 5. 模块边界

M0 建立模块，但不实现业务。

### 5.1 `app`

职责：

- CLI 参数分发。
- 调用 `doctor` 和 `paths`。
- 输出 build info。

M0 API：

```text
app.cli.run(args, stdout, stderr) -> ExitCode
app.build_info.write(stdout)
```

### 5.2 `core`

职责：

- 放全局错误类型。
- 放基础 ID 类型。
- 后续承载 Agent runtime。

M0 API：

```text
core.errors.PigError
core.ids.EntryId
core.ids.SessionId
```

### 5.3 `provider`

职责：

- 后续承载 `pi-ai` 等价层。
- M0 只放模块占位和接口设计注释。

M0 API：

```text
provider.ProviderKind
provider.ProviderStatus
```

### 5.4 `tools`

职责：

- 后续承载 read/write/edit/bash 等工具。
- M0 只定义工具风险级别和分类。

M0 API：

```text
tools.ToolRisk
tools.ToolAccess
```

### 5.5 `session`

职责：

- 后续承载 JSONL session tree。
- M0 只定义 session 路径解析和 placeholder 类型。

M0 API：

```text
session.SessionPathSet
session.resolveDefaultPaths()
```

### 5.6 `resources`

职责：

- 后续承载 AGENTS、settings、skills、prompts、themes、packages discovery。
- M0 只定义资源类型枚举。

M0 API：

```text
resources.ResourceKind
resources.ResourceSource
```

### 5.7 `tui`

职责：

- 后续承载 terminal renderer。
- M0 只放 terminal capability placeholder。

M0 API：

```text
tui.TerminalMode
tui.Capabilities
```

### 5.8 `rpc` 和 `plugin`

职责：

- 后续承载 JSONL RPC 和外部进程插件。
- M0 只定义协议版本常量。

M0 API：

```text
rpc.PROTOCOL_VERSION
plugin.PROTOCOL_VERSION
```

### 5.9 `util`

职责：

- 路径、JSON、测试工具。
- 不放业务语义。

M0 API：

```text
util.paths.homeDir()
util.paths.cwd()
util.paths.join()
util.testing.tempDir()
```

## 6. 错误模型

M0 要先建立统一错误分类，避免后续各模块随意返回字符串。

建议分类：

```text
ConfigError
AuthError
ProviderError
StreamParseError
ToolError
SessionError
ResourceError
TerminalError
RpcError
PluginError
InternalError
```

M0 不需要每类都实现完整细节，但要在 `docs/error-model.md` 中写清：

- 哪类错误属于用户可修复。
- 哪类错误应该进入 JSON event。
- 哪类错误应该导致 nonzero exit。
- 哪类错误可以 retry。

最小原则：

- CLI 参数错误：exit code 2。
- 环境/路径错误：exit code 1。
- 内部 bug：exit code 70 或直接使用 1，文档中先固定一种。

## 7. Allocator 策略

M0 必须写 `docs/allocator-policy.md`。

建议策略：

- CLI 短生命周期命令使用 `GeneralPurposeAllocator`。
- 测试使用 `std.testing.allocator`。
- 解析临时数据可使用 `ArenaAllocator`，但 arena 生命周期必须绑定到一次命令、一次 request 或一次 test。
- 长期状态对象必须显式 `deinit()`。
- 所有拥有内存的 struct 都遵循 `init/deinit`。
- 模块 API 必须明确 allocator 由调用方传入，避免全局 allocator。

验收：

- `zig build test` 在 debug 模式下不报告 allocator leak。
- M0 所有测试使用 `std.testing.allocator` 或明确 deinit。

## 8. Fixtures 策略

M0 需要建立 fixtures 目录，但不需要大量真实样本。

### 8.1 `fixtures/pi-mono`

从 `/home/like/workspace/pi-mono` 提取只读元数据，避免复制大量源码：

- package 列表。
- package README 摘要或路径清单。
- CLI sample 结构占位。

建议文件：

```text
fixtures/pi-mono/package-list.json
fixtures/pi-mono/package-readmes.json
fixtures/pi-mono/cli-samples.jsonl
```

M0 可以先手写最小 fixtures：

```json
{
  "packages": ["ai", "agent", "coding-agent", "tui", "web-ui", "mom", "pods"]
}
```

### 8.2 `fixtures/fake-provider`

为 M1/M2 预留 fake provider fixtures：

```text
fixtures/fake-provider/empty-turn.jsonl
```

M0 不解析 provider events，只需要保证 fixtures 能被测试读取。

## 9. 测试计划

M0 测试全部必须离线可跑。

### 9.1 Unit tests

覆盖：

- path resolution。
- build info formatting。
- enum/string conversion。
- fixture 文件存在且可读取。
- CLI 参数分发。

### 9.2 Smoke tests

`zig build smoke` 覆盖：

```bash
pig --version
pig --help
pig doctor
pig paths
```

要求：

- 不访问网络。
- 不读取 API key。
- 不修改用户真实配置。
- 临时文件只写入 test temp dir。

### 9.3 格式检查

`zig build fmt-check` 执行类似：

```bash
zig fmt --check build.zig src test
```

如果 Zig 0.16 的 `zig fmt --check` 行为有变化，以实际 Zig 0.16 命令为准。

## 10. 文档交付

M0 至少新增：

```text
docs/architecture.md
docs/error-model.md
docs/fixtures.md
docs/allocator-policy.md
```

内容要求：

- `architecture.md`：说明模块边界、依赖方向、M0/M1/M2 的演进关系。
- `error-model.md`：说明错误分类、exit code、event 化原则。
- `fixtures.md`：说明 fixtures 来源、格式、禁止包含 secrets。
- `allocator-policy.md`：说明 allocator 生命周期和 deinit 规则。

README 更新：

- 说明项目目标。
- 说明需要 Zig 0.16。
- 说明 M0 阶段可用命令。
- 说明 agent 功能从 M1/M2 开始实现。

## 11. 执行顺序

建议按以下顺序实现：

1. 创建 `build.zig`、`build.zig.zon`、`src/main.zig`。
2. 加 `src/version.zig` 和 `src/app/build_info.zig`。
3. 实现 `pig --version` 和 `pig --help`。
4. 创建所有模块目录和 `mod.zig`。
5. 实现 `util.paths`，支持 cwd/home/config/session 路径计算。
6. 实现 `pig paths`。
7. 实现 `pig doctor`。
8. 增加 `docs/architecture.md` 和 allocator/error/fixtures 文档。
9. 增加 fixtures 目录和最小 fixture 文件。
10. 增加 unit tests。
11. 增加 smoke step。
12. 增加 fmt-check step。
13. 跑完整验收命令。

## 12. 验收命令

M0 完成时必须通过：

```bash
zig version
zig build
zig build run -- --version
zig build run -- --help
zig build run -- doctor
zig build run -- paths
zig build test
zig build smoke
zig build fmt-check
```

验收输出要求：

- `--version` 输出包含 Pig version、Zig version、target、build mode。
- `doctor` 不要求真实配置存在，但要能显示候选路径和基础检查状态。
- `paths` 输出路径稳定，且不创建用户真实配置文件。
- 测试不依赖 `/home/like/workspace/pi-mono` 必须存在；引用该路径的内容只能进入 fixtures 或文档。

## 13. Done Definition

M0 完成条件：

- Zig 0.16 可以构建主二进制。
- CLI skeleton 可运行。
- 模块骨架和依赖方向清晰。
- 错误模型和 allocator 策略有文档。
- fixtures 目录存在，且测试能读取。
- `zig build test`、`zig build smoke`、`zig build fmt-check` 全部通过。
- 没有 API key、auth token、真实用户 session 被写入仓库。

## 14. 主要风险

- Zig 0.16 build API 可能和旧版本差异较大；M0 不要复制旧版 build.zig 模板，要按实际 0.16 调整。
- 如果一开始就实现 provider，会把 M0 拖大；provider 只能留接口和 fixtures。
- 如果把 TUI 提前做进 M0，会影响基础稳定性；M0 只保留 TUI 模块占位。
- 如果 fixtures 直接复制 `pi-mono` 大量源码，会让后续维护困难；M0 只保留最小行为样本。
- 如果 allocator 策略不早定，后面 provider streaming 和 session tree 容易出现生命周期混乱。
