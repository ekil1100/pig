# M7 Config、Auth、Models 和 Resource Loading 实现方案

M7 在 M4 session foundation、M5 runtime assembly 和 M6 terminal UI foundation 之上，实现 Pig 的产品级配置与资源加载层。目标是让 CLI 不再依赖硬编码的 provider/model/system prompt 行为，而是能从全局和项目资源中稳定解析 settings、auth、models、context files 和基础资源清单，并为 M8 slash commands、M9 skills/prompts/themes/packages 打好数据结构边界。

M7 的重点不是做完整工作流命令体系；`/model`、`/resume`、`/compact`、`/tree` 等属于 M8。M7 只实现配置解析、资源发现、模型选择基础、auth resolution 接入，以及 interactive 下最小 `/reload` 行为。

## 目标

- 建立 `resources` 模块的真实加载边界：settings、models、context files、resource manifest/source tracking。
- 实现稳定的配置层级：内置默认值 < global `~/.pig/agent/settings.json` < project `.pig/settings.json` < CLI flags。
- 将 M1 的 provider auth resolver 接入 M5/M6 runtime assembly，使 print/interactive 能通过 resolved config 构造 provider model client。
- 支持 global/project `models.json` 合并和模型选择，提供 enabled/scoped model 数据结构。
- 发现并合并 context files：`AGENTS.md`、`CLAUDE.md`、`SYSTEM.md`、`APPEND_SYSTEM.md`。
- 将发现到的 system prompt 注入 `AgentConfig.system_prompt`，保持 core.agent 不依赖资源系统。
- 支持 resource source info 和 collision warnings，便于 CLI diagnostics 和后续 TUI settings UI 展示。
- interactive 模式支持最小 `/reload`：重新加载 settings/models/context resources，并显示结果。
- 默认测试离线，不访问网络、不读取真实 API key；live provider 仍走 opt-in smoke。

## 非目标

- 不实现完整 slash command 框架；M7 只识别 `/reload` 作为资源刷新入口。
- 不实现 OAuth login；`/login`、`/logout` 只保留数据和错误语义设计，具体交互属于 M8 或后续。
- 不实现 full theme rendering；M7 只发现 theme resource metadata，不把主题 JSON 完整接入 TUI。
- 不实现 prompt template expansion；M7 只发现 prompt_template resource metadata，模板执行属于 M9。
- 不实现 executable skills 或 plugin packages；M7 只建立 discovery 和 source/collision 模型。
- 不让 `resources` 依赖 `app`、`tui`、`core.agent`、`provider transport` 或 `tools` 实现。
- 不改变 `.pig` namespace；所有全局资源必须继续落在 `~/.pig/agent`，项目资源继续落在 `<cwd>/.pig`。

## 当前前提和缺口

当前 main 已有：

- `src/util/paths.zig` 能解析：
  - `global_config`: `~/.pig/agent/settings.json`
  - `global_auth`: `~/.pig/agent/auth.json`
  - `global_models`: `~/.pig/agent/models.json`
  - `global_sessions`: `~/.pig/agent/sessions`
  - `project_config`: `<cwd>/.pig/settings.json`
  - `project_resources`: `<cwd>/.pig`
- `src/provider/auth.zig` 已有 provider-local auth resolution，支持 env/auth JSON。
- `src/provider/config.zig` 有 provider request config DTO，但还没有产品级 settings/model registry。
- `src/resources/mod.zig` 目前只有 placeholder enum。
- `src/app/runtime.zig` 和 `src/app/interactive.zig` 仍通过 injected `model_client` 运行；真实 provider client assembly 尚未从 settings/auth/models 创建。
- M6 interactive 只支持 scripted input runner，真实 terminal input 尚未接通；M7 不扩大 terminal 范围，但 `/reload` 的行为应在 scripted harness 中可测。

因此 M7 需要先补 resource/config/model 的纯数据层，再在 `app` 层接入 runtime assembly。不要把 provider-specific JSON parsing 放进 `app/cli.zig`；不要让 `resources` 构造 HTTP transport。

## 模块边界

计划依赖方向：

```text
app -> resources/provider/core/session/tools/tui/util
resources -> util
provider -> util
core.agent -/-> resources/app/tui
tui -/-> resources/app/core/provider/session/tools
session -/-> resources/app/tui
```

职责划分：

- `resources/settings.zig`：settings DTO、默认值、JSON parse、merge、CLI override。
- `resources/models.zig`：model registry DTO、built-in models、custom models JSON、enabled/scoped model selection。
- `resources/context_files.zig`：向上递归发现并合并 `AGENTS.md`/`CLAUDE.md`/`SYSTEM.md`/`APPEND_SYSTEM.md`。
- `resources/discovery.zig`：resource root 扫描、source info、collision warning、reload result。
- `resources/theme.zig`：theme metadata DTO；M7 不负责 TUI style 映射。
- `resources/prompts.zig`：prompt_template resource metadata DTO；M7 不做 template expansion。
- `resources/skills.zig`：skill metadata DTO；M7 不加载完整 `SKILL.md` 内容。
- `app/config_runtime.zig`：将 paths/env/io/CLI flags 解析成 `ResolvedRuntimeConfig`。
- `app/model_factory.zig`：基于 resolved provider/model/auth 构造 `agent.ModelClient`；tests 可继续注入 scripted client 覆盖。
- `app/interactive.zig`：识别 `/reload`，调用 app 层 reload hook，并更新 transcript。

`resources` 只产出普通 DTO，不知道 `RunConfig`、`AgentRuntime`、TUI frame 或 provider HTTP transport。

建议新增文件：

```text
src/resources/settings.zig
src/resources/models.zig
src/resources/context_files.zig
src/resources/discovery.zig
src/resources/theme.zig
src/resources/prompts.zig
src/resources/skills.zig
src/app/config_runtime.zig
src/app/model_factory.zig
test/resources_settings.zig
test/resources_models.zig
test/resources_context_files.zig
test/resources_discovery.zig
test/app_config_runtime.zig
test/model_factory.zig
test/interactive_reload.zig
fixtures/resources/
```

如果某些资源 DTO 在 M7 中很小，可以先合并到 `resources/discovery.zig`，但 public API 应从 `src/resources/mod.zig` 统一导出。

## 配置层级

M7 配置解析顺序：

```text
defaults
  -> global ~/.pig/agent/settings.json
  -> project <cwd>/.pig/settings.json
  -> CLI flags
```

P0 settings schema：

```json
{
  "provider": "openai_compatible",
  "model": "gpt-4.1-mini",
  "thinking": "off",
  "tools": {
    "enabled": true,
    "include_p1": false
  },
  "session": {
    "mode": "default"
  },
  "context": {
    "include": ["AGENTS.md", "CLAUDE.md", "SYSTEM.md", "APPEND_SYSTEM.md"],
    "max_bytes": 65536
  },
  "resources": {
    "warnings": "show"
  }
}
```

Zig DTO 建议：

```zig
pub const Settings = struct {
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    thinking: ?[]const u8 = null,
    tools: ToolSettings = .{},
    session: SessionSettings = .{},
    context: ContextSettings = .{},
    resources: ResourceSettings = .{},
};

pub const ResolvedSettings = struct {
    provider: []const u8,
    model: []const u8,
    thinking: []const u8,
    tools_enabled: bool,
    include_p1_tools: bool,
    context_max_bytes: usize,
};
```

`resources/settings.zig` 不应 import `core.agent`；它只保留 string/本地 enum 形式。`app/config_runtime.zig` 负责把 `thinking` 映射到 `agent.ThinkingLevel`，并把 invalid value 转成 config error。

规则：

- Missing file 不是错误，返回默认值并记录 source missing。
- JSON parse error 是 config error，CLI 应返回 failure，并指出具体 path。
- Unknown keys P0 可忽略并产生 warning；P1 再改成 strict mode。
- 对象字段深度 merge；数组默认 replace，不做 concat，避免 project 配置无法覆盖 global。
- CLI flags 只覆盖对应字段，不清空未指定字段。
- `--no-tools` 覆盖 settings 的 tools enabled。
- `--include-p1-tools` 只在 tools enabled 时有效，沿用 M5 parser 规则。

测试：

- global/project/CLI 覆盖顺序。
- nested object merge 不丢 sibling field。
- invalid JSON 返回带 path 的 config error。
- missing config files 不失败。
- `.pig` 路径保持不变，不能回退到 `.pi`。

## Auth 接入

M7 不重写 provider auth resolver，而是在 app runtime assembly 中使用 M1 `provider.auth`：

输入来源：

- explicit api key 或测试注入值。
- `~/.pig/agent/auth.json`。
- process env，测试中通过 explicit env reader 注入，避免读取真实环境。

Provider/model config 只保存 non-secret endpoint metadata，例如 `base_url` 和 provider/model id；不要把它当作 secret 来源。

规则：

- secrets 只来自 env 或 auth JSON，不写入 session，不出现在 diagnostics full output。
- auth JSON path 默认使用 `paths.global_auth`。
- project settings 不允许直接存 API key；如果用户写了类似 key 字段，解析时返回 config warning 或 error。
- provider missing key 时，print/interactive 显示可操作错误：需要设置哪个 env 或 auth JSON。

Auth JSON P0 示例：

```json
{
  "providers": {
    "openai_compatible": {
      "api_key": "..."
    },
    "anthropic": {
      "api_key": "..."
    }
  }
}
```

测试：

- explicit/test api key 优先，其次 auth JSON，最后 env；这沿用当前 `provider.auth.resolveApiKey()` contract，M7 不应静默改变优先级。
- auth JSON 可解析 OpenAI-compatible/Anthropic。
- missing auth 返回 provider/auth category error。
- diagnostics 不输出 secret value。

## Models Registry

M7 model registry 解决三个问题：

1. CLI `--provider`/`--model` 有明确 fallback。
2. settings 可以定义默认模型和自定义 endpoint。
3. interactive/session resume 能知道当前模型标签并为 M8 `/model` 做选择列表。

P0 model entry：

```zig
pub const ModelEntry = struct {
    id: []const u8,
    provider_id: []const u8,
    display_name: []const u8,
    model: []const u8,
    base_url: ?[]const u8 = null,
    enabled: bool = true,
    scope: ModelScope = .global,
    source: ResourceSourceInfo,
};
```

`resources/models.zig` 不应 import `provider`。它只保存 `provider_id` 字符串；`app/model_factory.zig` 负责把 `provider_id` 映射成 `provider.ProviderKind` 并返回 unknown provider config error。

Custom `models.json` 示例：

```json
{
  "models": [
    {
      "id": "local-qwen",
      "provider_id": "openai_compatible",
      "display_name": "Local Qwen",
      "model": "qwen3-coder",
      "base_url": "http://127.0.0.1:8000/v1",
      "enabled": true,
      "scope": "project"
    }
  ],
  "default_model": "local-qwen"
}
```

Settings 中的 `model` 字段默认解释为 registry model id，例如 `local-qwen`。Model entry 内部的 `model` 字段才是传给 provider API 的真实 model name，例如 `qwen3-coder`。如果 CLI 同时提供 `--provider` 和 `--model`，`--model` 被解释为 provider model name，并构造 transient model entry；如果只提供 `--model`，优先按 registry id 查找，找不到时返回明确 config error。

合并规则：

- Built-in registry 最低优先级。
- Global `~/.pig/agent/models.json` 覆盖 built-in 同 id。
- Project `<cwd>/.pig/models.json` 覆盖 global 同 id。
- CLI `--provider` + `--model` 可以构造 transient model entry，不必写回 models.json。
- disabled model 不参与默认选择，但显式 CLI 指定时返回清晰错误，不静默 fallback。
- resume session 中记录的 model 如果不存在，使用当前 default，并记录 warning；不要崩溃。

测试：

- built-in + global + project 合并。
- duplicate id 产生 source/collision warning。
- disabled model 不被默认选择。
- CLI override 构造 transient entry。
- unknown provider/model 返回清晰 config error。

## Context Files

M7 支持 context files 作为 system prompt 的来源。发现顺序要可预测，并且不能越过 workspace/root 策略。

默认文件：

- `AGENTS.md`
- `CLAUDE.md`
- `SYSTEM.md`
- `APPEND_SYSTEM.md`

发现策略：

- 从 resolved cwd 开始向上递归，但不能越过 resolved workspace root。
- Workspace root 解析规则：显式 `--cwd` 优先；否则从 process cwd 向上查找最近的 `.git` 或 `.pig` marker，找到则以该目录为 root；找不到 marker 时只使用 process cwd，不继续扫描父目录。
- 如果 resolved cwd 位于 workspace root 子目录内，按路径从 workspace root 到 resolved cwd 合并；如果二者相同，只读取该目录。
- Project-local `<cwd>/.pig/settings.json` 可配置 include list 和 max bytes。
- 默认总大小上限 64 KiB；超限时截断并记录 warning。
- `SYSTEM.md` 用于主 system prompt fragment。
- `APPEND_SYSTEM.md` 在最后追加。
- `AGENTS.md` 和 `CLAUDE.md` 按路径从上到下合并，越靠近 cwd 越后出现。
- 发现顺序必须稳定，避免同一 checkout 下 prompt 抖动。

合成 system prompt：

```text
[Built-in Pig system prompt]

[Context: /repo/AGENTS.md]
...

[Context: /repo/subdir/AGENTS.md]
...

[System: /repo/SYSTEM.md]
...

[Append System: /repo/APPEND_SYSTEM.md]
...
```

规则：

- system prompt 合成发生在 `app/config_runtime.zig` 或相邻 app 层，不在 `core.agent` 内。
- context file read failure 对普通 missing 不报错；权限/编码/超限产生 warning 或 ResourceError。
- 不把完整 system prompt 输出到默认 doctor，避免泄漏项目上下文；可以输出文件列表和字节数。

测试：

- upward discovery 顺序稳定。
- discovery 不读取 workspace root 之外的父目录 context files。
- nested AGENTS 合并顺序正确。
- SYSTEM/APPEND_SYSTEM 位置正确。
- max bytes 截断产生 warning。
- missing files 不失败。

## Resource Discovery

M7 的 resource discovery 先做 metadata，不做执行。

资源类型：

- settings
- model_registry
- context_file
- skill
- prompt_template
- theme
- package

当前 `src/resources/mod.zig` 已有 `agents_file` 和 `prompt_template` placeholder。M7 Slice 0 需要把 `agents_file` 泛化为 `context_file`，以覆盖 `AGENTS.md`、`CLAUDE.md`、`SYSTEM.md` 和 `APPEND_SYSTEM.md`；`prompt_template` 名称继续沿用，避免 prompt resource 和普通 user prompt 混淆。

Resource source：

```zig
pub const ResourceSourceInfo = struct {
    source: ResourceSource,
    path: []const u8,
    priority: u8,
};

pub const ResourceWarning = struct {
    kind: enum { collision, invalid_json, ignored_unknown_key, truncated, secret_in_config, unsupported },
    path: []const u8,
    message: []const u8,
};
```

目录约定：

```text
~/.pig/agent/
  settings.json
  auth.json
  models.json
  skills/
  prompts/
  themes/
  packages/

<cwd>/.pig/
  settings.json
  models.json
  skills/
  prompts/
  themes/
  packages/
```

M7 discovery 行为：

- 扫描 global 和 project roots。
- 只读取 metadata 所需的文件名和小 JSON/Markdown front matter。
- 对同名 skill/prompt/theme/package 记录 collision warning，并按 project 覆盖 global。
- `resources reload` 返回完整 snapshot，旧 snapshot 在 app 层替换。
- 不执行 package/plugin 脚本。

测试：

- global/project source priority。
- collision warning。
- invalid metadata 不影响其他资源加载。
- reload snapshot 不复用已释放内存。

## Runtime Assembly 接入

M7 需要把 M5/M6 的 runtime assembly 从 injected-only 推进到真实 config-driven：

```text
CLI args
  -> paths.resolveDefaultPathsFrom
  -> resources.loadSnapshot
  -> app.resolveRuntimeConfig
  -> app.model_factory.createModelClient
  -> app.runtime / app.interactive
```

重要边界：

- Tests 仍可通过 `Context.model_client` 注入 scripted client，注入值优先于 model factory。
- 没有 injected model 且 provider/auth 可用时，app 尝试创建真实 provider client。
- 没有 injected model 且 provider/auth 不可用时，返回现有 `model client unavailable` 或更具体 auth/config 错误。
- Tool registry/session recorder 继续沿用 M5 assembly；M7 不把 resources 写进 tool implementation。
- `AgentConfig.system_prompt` 使用合成后的 context prompt。

建议 `ResolvedRuntimeConfig`：

```zig
pub const ResolvedRuntimeConfig = struct {
    settings: resources.settings.ResolvedSettings,
    model: resources.models.ModelEntry,
    system_prompt: ?[]const u8,
    warnings: []resources.discovery.ResourceWarning,
};
```

测试：

- print mode 无 injected model 时，missing auth 给出明确错误。
- print mode 有 injected model 时不读取真实 env/auth。
- `AgentConfig.system_prompt` 包含 context file 内容。
- CLI `--model` 覆盖 settings default。

## Interactive `/reload`

M7 只实现 `/reload`，用于验证 resource snapshot 可热更新。

行为：

- 用户输入 `/reload` 时不发起 agent turn。
- app 调用 reload hook，重新读取 settings/models/context/resource metadata。
- 成功时 transcript 显示简短 status，例如 `resources reloaded: 3 context files, 2 models, 0 warnings`。
- 失败时 transcript 显示 error，但 interactive loop 继续。
- reload 不强制重建当前 running turn；如果 agent busy，M7 可以返回 `reload deferred while agent is running`，或只允许空闲时 reload。

边界：

- `/reload` 不等同 M8 slash command framework；M7 可以用简单字符串识别。
- `/reload` 不改变已经发送给当前 turn 的 system prompt；下一 turn 使用新 snapshot。
- 如果模型配置改变，下一 turn 使用新的 model entry；当前 session 应记录 model_change entry 的设计，但 M7 可以先只更新 app state 并为 M8 补 session command 做准备。

测试：

- scripted interactive 输入 `/reload` 不调用 model。
- reload 成功显示 status。
- reload 失败显示 error 并继续响应下一条 prompt。
- reload 后下一条 prompt 使用新的 system prompt 或 model label。

## CLI Diagnostics

M7 建议扩展 `doctor`，但保持输出不泄漏 secret：

```text
settings: ok /Users/.../.pig/settings.json
auth: missing openai_compatible api key
models: ok 3 enabled
context: ok 2 files 1432 bytes
resources: warnings 1
```

规则：

- `paths` 继续只输出路径。
- `doctor` 可以读取 settings/models/context metadata，但不输出 API key 和完整 system prompt。
- JSON diagnostics 后置；M7 不必新增 machine-readable doctor。

测试：

- doctor 在 missing files 时仍 ok 或明确 warning。
- doctor 不包含 secret。
- invalid settings 返回 failure 或 warning 的策略必须稳定并测试。

## 错误模型

沿用 `docs/error-model.md` 分类：

- `ConfigError`：settings/models JSON parse、invalid enum、unknown provider/model。
- `AuthError`：missing API key、invalid auth JSON。
- `ResourceError`：context/resource discovery failure、collision warning、truncation warning。
- `ProviderError`：真实 provider request/stream failure。

原则：

- Missing optional resource 是 warning，不是 failure。
- Invalid selected model 是 failure。
- Invalid unrelated resource metadata 是 warning，不阻塞 agent。
- Secret leakage 是 P0 bug，测试要覆盖。
- CLI stderr 要指向用户可修复动作，例如 env var 名或文件路径。

## 测试和 Build Steps

新增 build steps：

```zig
zig build resources
zig build config-runtime
```

默认 `zig build test` 包含 M7 新测试。

必跑验证：

```bash
zig build test
zig build resources
zig build config-runtime
zig build cli-modes
zig build interactive-mode
zig build smoke
zig build fmt-check
```

Fixtures：

```text
fixtures/resources/
  global/settings.json
  global/models.json
  project/settings.json
  project/models.json
  project/AGENTS.md
  project/SYSTEM.md
  invalid/settings.json
  collisions/
```

Fixtures 不能包含真实用户路径、API key 或真实 session 内容。

## Slice 计划

### Slice 0: Resource DTO 和路径基线

- 扩展 `src/resources/mod.zig` exports。
- 增加 `ResourceSourceInfo`、`ResourceWarning`、`ResourceSnapshot`。
- 添加 `.pig` path namespace regression tests。

验收：

- `zig build resources` 可跑空 snapshot tests。
- 所有路径仍指向 `.pig`，没有 `.pi` 回归。

### Slice 1: Settings 解析和 merge

- 实现 settings DTO。
- 实现 JSON parse、defaults、deep merge、CLI override。
- 添加 invalid/missing config tests。

验收：

- project 覆盖 global。
- CLI 覆盖 settings。
- nested merge 保留 sibling field。

### Slice 2: Models Registry

- 增加 built-in registry。
- 解析 global/project `models.json`。
- 实现 default/disabled/transient CLI model selection。
- 记录 collision warnings。

验收：

- enabled model 列表稳定。
- duplicate id 按 priority 覆盖并产生 warning。
- unknown model failure 明确。

### Slice 3: Auth 和 Model Factory

- 在 app 层接入 provider auth resolver。
- 增加 provider model client factory。
- 保持 injected scripted model 优先。
- 不在测试中读取真实 env。

验收：

- injected model path 不触碰 auth。
- missing auth failure 可读。
- opt-in live smoke 仍独立。

### Slice 4: Context Files 和 System Prompt

- 实现 upward discovery。
- 合成 system prompt。
- 接入 `AgentConfig.system_prompt`。
- 添加截断和顺序 tests。

验收：

- print mode provider request 带 context system prompt。
- context discovery 顺序稳定。
- 超限产生 warning。

### Slice 5: Resource Discovery Metadata

- 扫描 skills/prompts/themes/packages metadata。
- 记录 source/collision warning。
- 不执行任何资源代码。

验收：

- global/project collision 可见。
- invalid resource metadata 不阻断其他资源。

### Slice 6: Runtime Assembly 接入

- 新增 `app/config_runtime.zig`。
- 修改 print/interactive assembly 使用 `ResolvedRuntimeConfig`。
- 保留测试注入 model client。
- doctor 输出 resources/config 状态。

验收：

- print mode 可通过 settings/model/auth 走真实 factory 或明确失败。
- `doctor` 不泄漏 secret。
- existing M5/M6 tests 不回退。

### Slice 7: Interactive `/reload`

- 在 M6 scripted interactive 中识别 `/reload`。
- 增加 reload hook 和 snapshot replacement。
- 显示 status/warnings。

验收：

- `/reload` 不调用 model。
- reload 后下一 turn 使用新 system prompt snapshot。
- reload failure 不退出 interactive。

### Slice 8: 文档和 Fixtures

- 更新 `docs/architecture.md` M7 描述。
- 新增 `docs/resources.md`。
- 更新 `docs/provider-auth.md`，说明 app-level auth/config assembly。
- 增加 `fixtures/resources`。

验收：

- docs 与实现路径一致。
- 没有 `.pi` 文案回归。

## 验收清单

- `resources` 不依赖 `app/core/provider/session/tools/tui`。
- settings merge 和 CLI override 有单元测试。
- global/project `models.json` 合并稳定。
- auth resolution 接入 app runtime，且 secrets 不输出。
- context files 发现并进入 `AgentConfig.system_prompt`。
- interactive `/reload` 可离线测试。
- `doctor` 能报告 settings/models/context/resources 状态。
- `zig build test`、`zig build resources`、`zig build config-runtime`、`zig build smoke`、`zig build fmt-check` 通过。

## 风险和约束

- 如果 settings schema 过早复杂化，M8/M9 会被配置迁移拖住。M7 schema 保持小而明确。
- 如果 resource discovery 直接加载/执行 skill/package，会引入安全面。M7 只读 metadata。
- 如果 app runtime 仍只支持 injected model，M7 config/auth/models 的验收会落空。必须至少实现 missing-auth 和 provider-client factory 的真实路径。
- 如果 context prompt 合成在 core.agent 内完成，会破坏模块边界。合成必须留在 app/resources 层。
- 如果 warnings 没有 source path，用户无法修复配置问题。所有 warning/error 都带 path/source。

## M7 完成后的后续承接

- M8 基于 M7 的 resource snapshot 实现 `/model`、`/settings`、`/resume`、`/new`、`/tree`、`/compact` 等完整 slash commands。
- M9 扩展 skills/prompts/themes/packages 的执行和 TUI 呈现。
- M10 plugin system 可以复用 M7 的 resource source/collision/warning 模型。
- M11 RPC/SDK 可以复用 `ResolvedRuntimeConfig`，避免重复实现配置加载。
