# Pig v1.0 M3 Implementation Plan：Built-in Coding Tools（`pi-coding-tools`）

> 本文是 `.agents/pig-v1.0-roadmap.md` 中 M3 的执行计划。
>
> M3 的目标是在 M2 `core.agent` runtime 之上实现最小可用的本地 coding tools：`read`、`write`、`edit`、`bash`，以及 P1 的 `grep`、`find`、`ls`。M3 让 runtime 能通过 fake/scripted model 调用真实本地工具检查、修改、测试一个小型 repo，但仍不实现完整产品 CLI/TUI/session。

## 1. M3 目标

M3 要解决的问题：

1. 在 `src/tools` 下建立真实 coding-tool 模块边界，复用 M2 `core.agent.tool.ToolRegistry` / `ToolExecutor`。
2. 实现 P0 工具：
   - `read`
   - `write`
   - `edit`
   - `bash`
3. 实现 P1 工具：
   - `grep`
   - `find`
   - `ls`
4. 定义 tool metadata/schema：name、description、JSON schema、display label、risk、access classification。
5. 实现路径 normalize 和 workspace boundary check。
6. 实现 approval/confirmation 抽象：bash 和 write/edit 默认需要 approval；M3 用测试 approval policy，不做交互式 UI。
7. 实现 write/edit preview 模型：执行前可生成 deterministic preview；M3 测试 preview，不做 TUI rendering。
8. 实现 bash timeout、stdout/stderr capture、exit code、输出截断和完整输出 spill file。
9. 实现 edit 精确替换：single/multiple disjoint edits、missing/repeated match 错误、overlap/collision detection。
10. 建立 offline deterministic tests，证明 M2 runtime 可通过 fake model 调用真实 coding tools 完成 read/edit/bash loop。
11. 更新 build steps/docs/README，使 M3 验收命令默认离线、无 secrets。

M3 不做：

- 不实现 product CLI modes：`pig --print`、interactive、JSON、RPC；M5 负责。
- 不实现 durable session JSONL；M4 负责。
- 不实现 TUI/editor/preview rendering；M6 负责。
- 不实现 plugin/runtime ecosystem；M10 以后再做。
- 不实现 complex patch engine 或 AST-aware edits；M3 只做 exact old-text replacement。
- 不接 live model provider by default；tests must stay offline。
- 不做 parallel tool execution；M2 runtime 当前是 sequential。

Roadmap note: M3 acceptance says “Tool results 会持久化为 session entries.” Since durable session store belongs to M4, M3 interprets this as: tool execution emits structured `AgentEvent.tool_execution_*` events and returns JSON results that M4 can persist without re-parsing human text. Actual append-only JSONL persistence starts in M4.

## 2. 当前基础

M0/M1/M2 已完成并推送：

```text
3772d3a feat: add zig m0 foundation
0c22936 feat: add m1 provider layer
0526f3a feat: add m2 agent runtime
```

M2 提供 M3 可复用的 runtime API：

```zig
pig.core.agent.ToolRegistry
pig.core.agent.tool.ToolRegistration
pig.core.agent.tool.ToolExecutor
pig.core.agent.tool.ToolExecutionContext
pig.core.agent.tool.ToolExecutionResult
pig.core.agent.AgentRuntime
pig.core.agent.AgentEventSink
```

当前 `src/tools/mod.zig` 只有占位分类：

```zig
pub const ToolRisk = enum {
    safe,
    confirmation_required,
    destructive,
};

pub const ToolAccess = enum {
    read_only,
    write_files,
    execute_process,
    network,
};
```

M3 应保持依赖方向：

```text
app/test -> tools.registry -> core.agent.tool
src/tools/registry.zig -> core.agent.tool allowed as adapter only
src/tools/{read,write,edit,bash,grep,find,ls,...} -> stdlib + util only
src/tools/{read,write,edit,bash,grep,find,ls,...} -/-> core.agent/app/tui/session/provider
```

`src/tools/registry.zig` may import `core.agent.tool` as a thin adapter that converts built-in tool executors into M2 `ToolRegistration` values. Individual tool implementation modules (`read.zig`, `write.zig`, `edit.zig`, `bash.zig`, etc.) must not depend on `core.agent` runtime, provider, terminal rendering, or session storage.

## 3. 建议目录结构

M3 后建议 `src/tools` 结构：

```text
src/tools/
├── mod.zig
├── metadata.zig
├── registry.zig
├── context.zig
├── approval.zig
├── path.zig
├── output.zig
├── json.zig
├── read.zig
├── write.zig
├── edit.zig
├── bash.zig
├── grep.zig
├── find.zig
├── ls.zig
└── testing.zig
```

测试和 fixtures：

```text
test/
├── tools_metadata.zig
├── tools_path.zig
├── tools_read_write.zig
├── tools_edit.zig
├── tools_bash.zig
├── tools_search.zig
├── tools_registry.zig
└── agent_runtime_coding_tools.zig

fixtures/tools/
├── README.md
├── sample-project/
│   ├── README.md
│   ├── src/main.txt
│   └── nested/data.json
└── expected/
```

Docs：

```text
docs/coding-tools.md
docs/tool-approval.md
```

If a file becomes tiny, it can be folded into `metadata.zig` or `context.zig`, but keep `edit.zig` and `bash.zig` separate because their behavior is riskier and test-heavy.

## 4. M3 API 合约

### 4.1 Tool result JSON contract

All M3 tools return `ToolExecutionResult.content_json` as valid JSON.

Recommended success shapes:

```json
{"ok":true,"path":"...","content":"...","truncated":false}
{"ok":true,"exit_code":0,"stdout":"...","stderr":"...","truncated":false}
{"ok":true,"matches":[...]}
```

Recommended error shape:

```json
{"ok":false,"error":{"code":"missing_file","message":"file not found"}}
```

Rules:

- `content_json` must always be valid JSON, including failures.
- Do not include secrets from environment variables in tool results.
- Paths in results should be workspace-relative when possible.
- If output is truncated, include `truncated: true` and optionally `full_output_path` for spill file.
- `ToolExecutionResult.is_error` must match `ok == false` for tool-generated errors.

### 4.2 Tool error policy

M3 tools should prefer returning structured error JSON with `is_error=true` over throwing `ToolFailed` for expected user/tool errors:

- file not found
- old string missing
- old string repeated
- edit collision
- approval denied
- command nonzero exit code
- invalid arguments that prevent constructing a normal tool result

Use Zig errors for infrastructure/runtime failures:

- `OutOfMemory`
- unexpected I/O failure preventing result construction
- approval backend failure
- spill file write failure if no safe fallback exists

This lets M2 runtime append tool result messages for recoverable tool errors and continue if the model can respond.

### 4.3 Tool metadata/schema

`src/tools/metadata.zig` should define:

```zig
pub const ToolRisk = enum {
    safe,
    confirmation_required,
    destructive,
};

pub const ToolAccess = enum {
    read_only,
    write_files,
    execute_process,
    network,
};

pub const JsonSchema = struct {
    // M3 stores compact schema JSON as a static string.
    value: []const u8,
};

pub const BuiltinToolSpec = struct {
    name: []const u8,
    display_label: []const u8,
    description: []const u8,
    schema_json: []const u8,
    risk: ToolRisk,
    access: ToolAccess,
};
```

`src/tools/mod.zig` should re-export the metadata types and built-in registrations.

Schema validation in M3 can be minimal:

- Parse tool arguments JSON into `std.json.Value`.
- Validate required fields and primitive types manually per tool.
- Do not implement a full JSON Schema validator in M3.

### 4.4 Tool context

`src/tools/context.zig` should define per-run environment independent of app/TUI/session:

```zig
pub const ToolContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    workspace_root: []const u8,
    spill_dir: []const u8,
    approval: approval.ApprovalPolicy,
    limits: ToolLimits = .{},
};

pub const ToolLimits = struct {
    max_read_bytes: usize = 256 * 1024,
    max_result_bytes: usize = 64 * 1024,
    max_bash_output_bytes: usize = 64 * 1024,
    bash_timeout_ms: u64 = 30_000,
};
```

Implementation note: `ToolContext.io` is required, not optional. Tests should pass `std.testing.io`; app/product modes later pass their runtime I/O value. Zig 0.16 std APIs often take `std.Io`; follow existing code style (`std.Io.Dir.cwd().readFileAlloc(std.testing.io, ...)`) in tests.

### 4.5 Workspace path policy

`src/tools/path.zig` should define:

```zig
pub const PathPolicyError = error{
    OutOfMemory,
    EmptyPath,
    AbsolutePathRejected,
    PathEscapesWorkspace,
    PathContainsNul,
};

pub const NormalizedPath = struct {
    relative: []const u8,
    absolute: []const u8,
    pub fn deinit(self: *NormalizedPath, allocator: std.mem.Allocator) void { ... }
};

pub fn normalizeWorkspacePath(allocator: std.mem.Allocator, workspace_root: []const u8, input: []const u8) PathPolicyError!NormalizedPath;
```

M3 default path policy:

- Reject empty paths.
- Reject NUL bytes.
- Reject absolute input paths unless explicitly enabled later.
- Normalize `.` and `..` segments.
- Reject paths that escape `workspace_root`.
- Preserve relative result with `/` separators for JSON output.
- Do not follow symlinks in M3 unless it stays small; document symlink behavior. If symlink resolution is not implemented, avoid claiming symlink-safe sandboxing.

### 4.6 Approval and preview

`src/tools/approval.zig` should define a minimal non-UI policy:

```zig
pub const ApprovalDecision = enum { allow, deny };

pub const ApprovalError = error{
    OutOfMemory,
    ApprovalBackendFailed,
};

pub const ApprovalRequestKind = enum {
    run_bash,
    write_file,
    edit_file,
};

pub const ApprovalRequest = struct {
    kind: ApprovalRequestKind,
    tool_name: []const u8,
    summary: []const u8,
    preview_json: []const u8,
    risk: ToolRisk,
    access: ToolAccess,
};

pub const ApprovalPolicy = struct {
    ptr: *anyopaque,
    decide_fn: *const fn (ptr: *anyopaque, request: ApprovalRequest) ApprovalError!ApprovalDecision,
    pub fn decide(self: ApprovalPolicy, request: ApprovalRequest) ApprovalError!ApprovalDecision { ... }
};
```

Deny is a normal `ApprovalDecision`, not an error. Use `ApprovalError` only for allocation failures or approval backend failures.

Built-in policies for tests:

```zig
pub const AllowAllApproval = struct { ... };
pub const DenyAllApproval = struct { ... };
pub const RecordingApproval = struct { ... };
```

Approval rules:

- `read`, `grep`, `find`, `ls` do not require approval by default.
- `write`, `edit`, `bash` require approval by default.
- Approval denied returns tool result JSON with `is_error=true`, not a Zig runtime error.
- Preview JSON must be deterministic and include path/command/risk and changed byte/line counts where applicable.

### 4.7 Output truncation and spill files

`src/tools/output.zig` should provide helpers:

```zig
pub const TruncatedOutput = struct {
    visible: []const u8,
    truncated: bool,
    full_output_path: ?[]const u8 = null,
    pub fn deinit(self: *TruncatedOutput, allocator: std.mem.Allocator) void { ... }
};

pub fn truncateAndMaybeSpill(... ) !TruncatedOutput;
```

Rules:

- Keep visible result under `ToolLimits.max_result_bytes` or `max_bash_output_bytes`.
- If truncated, write full output to `spill_dir` using deterministic-ish safe file names in tests.
- Result JSON should mention `full_output_path` relative to workspace/session spill root if possible.
- Never truncate in the middle of invalid UTF-8 if the input is known text; if preserving UTF-8 becomes complex, document byte truncation and test it.

## 5. Built-in tool behavior

### 5.1 `read`

Arguments:

```json
{"path":"src/main.zig","offset":1,"limit":200}
```

Fields:

- `path` required string.
- `offset` optional 1-indexed line number, default 1.
- `limit` optional max lines, default 200, capped at 2000; byte cap is still enforced by `ToolLimits.max_read_bytes`.

Behavior:

- Normalize path within workspace.
- Read text file.
- Return content, line range, truncated flag.
- If file is missing, return structured tool error JSON.
- Binary detection can be simple: if content contains NUL, return `binary_file` error.

Result example:

```json
{"ok":true,"path":"src/main.zig","offset":1,"line_count":42,"content":"...","truncated":false}
```

### 5.2 `write`

Arguments:

```json
{"path":"notes/todo.txt","content":"hello\n","mode":"overwrite","create_parents":false}
```

Fields:

- `path` required string.
- `content` required string.
- `mode` optional enum: `create_new`, `overwrite`, `append`; default `create_new`.
- `create_parents` optional bool; default false.

Behavior:

- Normalize path.
- Generate preview before write:
  - path
  - mode
  - existing file exists
  - old/new byte counts
- Require approval.
- `create_new` fails if file exists.
- When `create_parents=true`, M3 creates missing parent directories only after path normalization confirms every created directory stays inside workspace. Without `create_parents`, missing parent directories return structured `parent_missing` error.
- Return structured JSON.

### 5.3 `edit`

M3 should support both single replacement and multiple disjoint replacements.

Suggested arguments:

```json
{
  "path":"src/main.zig",
  "edits":[
    {"old_text":"hello","new_text":"world"}
  ]
}
```

Compatibility alias: accept `{old_string,new_string}` only if it stays small; otherwise avoid legacy naming.

Rules:

- `path` required.
- `edits` required non-empty array.
- Every `old_text` must be non-empty for edit; file creation belongs to `write`.
- Each `old_text` must match exactly once unless M3 explicitly supports occurrence selectors. M3 default: exactly once.
- Detect overlapping/colliding replacement regions before writing.
- Apply replacements against the original content, not incrementally.
- Sort ranges descending or build output from slices to avoid offset shift bugs.
- Generate preview with changed range count, old/new byte counts, and optional small unified-diff-like snippet.
- Require approval.

Error codes:

- `file_not_found`
- `old_text_not_found`
- `old_text_repeated`
- `overlapping_edits`
- `empty_old_text`
- `invalid_arguments`

### 5.4 `bash`

Arguments:

```json
{"command":"zig build test","timeout_ms":30000}
```

Behavior:

- Require approval.
- Execute in `workspace_root`.
- Use `bash -lc` on Unix in M3.
- Enforce timeout on Unix/macOS using Zig child-process APIs plus cooperative polling/kill. M3 is Unix-first for `bash`; Windows shell support is deferred.
- Before implementing bash, confirm Zig 0.16 child process timeout/kill behavior on macOS in a small test. If the stdlib API shape requires a helper, keep it inside `bash.zig`/`output.zig` and cover it with deterministic tests.
- Capture stdout/stderr and exit code.
- Truncate/spill output per limits.
- Nonzero exit code returns `ok:true` with `exit_code != 0` because the command executed successfully from the tool's perspective. Runtime should not treat nonzero as infrastructure failure.
- Timeout, spawn failure, and approval denied return structured tool error JSON with `ok:false` and `is_error=true`.

Result example:

```json
{"ok":true,"command":"zig build test","exit_code":0,"stdout":"...","stderr":"...","truncated":false}
```

### 5.5 `grep`

Arguments:

```json
{"pattern":"AgentRuntime","path":"src","literal":true,"ignore_case":false,"context":0,"limit":100}
```

M3 can implement grep in Zig using simple line scanning. Do not shell out to `grep` unless intentionally documented.

Rules:

- `pattern` required.
- `path` optional default `.`.
- M3 grep is literal substring search only. `literal` defaults to true. If `literal=false` is provided, return structured `unsupported_regex` tool error JSON. Regex belongs to a later milestone.
- Respect workspace boundary.
- Skip binary files.
- No matches returns `ok:true` with `matches:[]`, not an error.
- Limit result count and bytes.

### 5.6 `find`

Arguments:

```json
{"pattern":"*.zig","path":"src","limit":1000}
```

Rules:

- Walk under workspace path.
- M3 supports simple basename wildcards `*` and `?`. Recursive `**` and full glob semantics belong to a later milestone.
- Respect `.gitignore` is P1/P2. M3 can skip `.git` and common build/cache dirs (`.zig-cache`, `zig-out`, `node_modules`) by default.
- Return sorted paths for deterministic tests.

### 5.7 `ls`

Arguments:

```json
{"path":".","limit":500}
```

Rules:

- List directory entries sorted alphabetically.
- Include `/` suffix for directories.
- Return workspace-relative paths or entry names plus type.
- Respect limit.

## 6. Registry integration

`src/tools/registry.zig` should expose a function to build M2-compatible registrations:

```zig
pub const BuiltinToolSet = struct {
    context: *ToolContext,
    registrations: []agent_tool.ToolRegistration,
    pub fn deinit(self: *BuiltinToolSet, allocator: std.mem.Allocator) void { ... }
};

pub fn initBuiltinToolSet(allocator: std.mem.Allocator, context: *ToolContext, options: BuiltinToolOptions) !BuiltinToolSet;
```

The returned `ToolRegistration` values should wrap tool-specific executors whose `ptr` points to a struct containing `*ToolContext`.

M3 tests can instantiate:

```zig
var context = try tools.testing.initTempToolContext(...);
var set = try tools.registry.initBuiltinToolSet(allocator, &context, .{ .include_p1 = true });
var runtime = agent.runtime.AgentRuntime{ .tools = .{ .registrations = set.registrations }, ... };
```

## 7. Security boundaries

M3 security is local-first and conservative, not a complete sandbox.

Must-have:

- Workspace path normalization and escape rejection for file tools.
- Approval required for write/edit/bash.
- Bash timeout.
- No environment secrets in logs/results.
- Output truncation.
- Tests for path traversal attempts.

Not promised in M3:

- OS sandboxing.
- Symlink-safe jail unless explicitly implemented.
- Network blocking for commands.
- Full `.gitignore` semantics.
- Permission-mode UI.

Docs must state these limitations clearly.

## 8. Build system updates

Update `build.zig`:

- Add tool tests to `zig build test`.
- Add `zig build tools-fixtures` step for offline coding-tool fixture tests.
- Keep `agent-fixtures`, `provider-fixtures`, `provider-live`, `smoke`, `fmt-check` unchanged.

Suggested new step:

```bash
zig build tools-fixtures
```

Concrete M3 behavior:

- `tools-fixtures` runs fixture-backed tests only.
- It creates temp copies of fixture sample projects before mutating them.
- It does not modify checked-in fixtures.
- It does not execute live provider/model calls.

## 9. Testing plan

All default tests must be offline and deterministic.

### 9.1 `test/tools_metadata.zig`

Test cases:

- All built-in tools have unique names.
- Metadata includes display label, description, schema JSON, risk, access.
- Schema JSON parses as JSON.
- P0 tools are present by default.
- P1 tools can be enabled by options or are present if M3 includes all by default.

### 9.2 `test/tools_path.zig`

Test cases:

- Normal relative path resolves inside workspace.
- `.` and nested paths normalize deterministically.
- Empty path rejected.
- NUL path rejected.
- Absolute path rejected by default.
- `../outside` rejected.
- Result contains both workspace-relative and absolute path.

### 9.3 `test/tools_read_write.zig`

Test cases:

- `read` returns file content and line range.
- `read` missing file returns structured JSON error.
- `read` respects offset/limit/truncation.
- `write create_new` creates file after approval allow.
- `write create_new` fails if file exists.
- `write overwrite` requires approval and changes content.
- approval deny returns structured tool error and does not modify file.
- write preview JSON is captured by `RecordingApproval`.

### 9.4 `test/tools_edit.zig`

Test cases:

- Single exact replacement.
- Multiple disjoint replacements applied against original content.
- Missing old text returns `old_text_not_found`.
- Repeated old text returns `old_text_repeated`.
- Empty old text rejected.
- Overlapping edits rejected.
- Approval deny leaves file unchanged.
- Preview includes path and counts.

### 9.5 `test/tools_bash.zig`

Test cases:

- Approval deny prevents execution.
- Successful command captures stdout/stderr/exit code.
- Nonzero exit code is captured as command result, not runtime `ToolFailed`.
- Timeout returns structured error.
- Unix/macOS timeout behavior is covered by deterministic tests or a small helper test before full bash implementation.
- Large output truncates and writes spill file.
- Command executes with workspace as cwd.

### 9.6 `test/tools_search.zig`

Test cases:

- `ls` lists sorted entries with directory suffix.
- `find` returns deterministic sorted matches.
- `grep` finds literal matches with file/line content.
- Limits are respected.
- Binary-ish files are skipped or reported deterministically.

### 9.7 `test/tools_registry.zig`

Test cases:

- Builtin registry returns M2 `ToolRegistration` values.
- Tool names in registry match metadata.
- Registry can find every built-in tool.
- Tool executor returns valid JSON for invalid arguments rather than crashing.

### 9.8 `test/agent_runtime_coding_tools.zig`

Use M2 `ScriptedModelClient` with real M3 tool registry against a temp fixture project.

Test cases:

- Model calls `read`, then returns final answer.
- Model calls `edit`, then `bash`, then final answer.
- Approval deny for edit surfaces tool result and does not modify file.
- Tool result messages are appended to `AgentState` with valid JSON content.
- Tool events include start/end with deterministic content.

### 9.9 Regression tests

M3 must not break M0/M1/M2 commands:

```bash
zig build
zig build test
zig build smoke
zig build provider-fixtures
zig build agent-fixtures
zig build tools-fixtures
zig build provider-live
zig build fmt-check
```

## 10. Fixtures

Add `fixtures/tools/README.md` documenting:

- Fixtures are offline.
- Tests must copy fixtures to temp dirs before mutation.
- No secrets, private data, or machine-specific absolute paths.
- Keep files small.

Suggested sample project:

```text
fixtures/tools/sample-project/
├── README.md
├── src/main.txt
├── src/lib.txt
└── nested/data.json
```

Example file content should include repeated strings for edit collision tests and unique strings for successful edit tests.

## 11. Documentation deliverables

Create:

```text
docs/coding-tools.md
docs/tool-approval.md
fixtures/tools/README.md
```

Update:

```text
README.md
docs/architecture.md
docs/error-model.md
docs/allocator-policy.md
docs/fixtures.md
```

Content requirements:

- `docs/coding-tools.md`: tool list, arguments, result JSON, limits, path policy, scope boundaries.
- `docs/tool-approval.md`: approval policy interface, preview JSON, default risk behavior, M3 no-UI limitation.
- `docs/error-model.md`: tool structured error JSON vs runtime Zig errors.
- `docs/allocator-policy.md`: tool context ownership, result JSON ownership, spill output cleanup.
- `docs/fixtures.md`: tools fixture rules and temp-copy mutation policy.
- `README.md`: mention M3 adds built-in coding tool module and `tools-fixtures`; product CLI modes still later.

## 12. Recommended task split

### Task 0：Confirm M3 contracts

Steps:

- [ ] Confirm M3 returns valid JSON for every tool result.
- [ ] Confirm expected tool errors are returned as `ToolExecutionResult.is_error=true`, not runtime `ToolFailed`.
- [ ] Confirm `write`/`edit`/`bash` require approval by default.
- [ ] Confirm `tools.registry` is the only `src/tools` module allowed to import `core.agent.tool`; individual tool implementations stay runtime-independent.
- [ ] Confirm path policy does not promise symlink-safe sandboxing unless implemented.
- [ ] Confirm M3 grep is literal-only and `literal=false` returns `unsupported_regex`.
- [ ] Confirm M3 does not add product CLI modes.

### Task 1：Tool metadata and context

Files:

- Create: `src/tools/metadata.zig`
- Create: `src/tools/context.zig`
- Create: `src/tools/json.zig`
- Modify: `src/tools/mod.zig`
- Create: `test/tools_metadata.zig`

Steps:

- [ ] Define metadata structs and re-export `ToolRisk` / `ToolAccess` from metadata.
- [ ] Define `ToolContext` / `ToolLimits`, with required `std.Io` in context.
- [ ] Add JSON result helper functions.
- [ ] Add static built-in specs for P0/P1 tools.
- [ ] Test unique names and parseable schema JSON.
- [ ] Run `zig build test` and `zig build fmt-check`.
- [ ] Commit: `feat: add coding tool metadata`.

### Task 2：Path policy and fixture harness

Files:

- Create: `src/tools/path.zig`
- Create: `src/tools/testing.zig`
- Create: `test/tools_path.zig`
- Create: `fixtures/tools/README.md`
- Create: `fixtures/tools/sample-project/...`

Steps:

- [ ] Implement path normalization and escape checks.
- [ ] Implement temp workspace helper that copies fixtures.
- [ ] Test traversal rejection and normal paths.
- [ ] Run `zig build test` and `zig build fmt-check`.
- [ ] Commit: `feat: add tool path policy`.

### Task 3：Approval and preview contract

Files:

- Create: `src/tools/approval.zig`
- Update: `src/tools/testing.zig`
- Create or update: `test/tools_read_write.zig`

Steps:

- [ ] Implement `ApprovalPolicy`, `AllowAllApproval`, `DenyAllApproval`, `RecordingApproval`.
- [ ] Define preview JSON expectations for write/edit/bash.
- [ ] Test allow/deny behavior independent of actual tools if useful.
- [ ] Run `zig build test` and `zig build fmt-check`.
- [ ] Commit: `feat: add tool approval policy`.

### Task 4：Read/write tools

Files:

- Create: `src/tools/read.zig`
- Create: `src/tools/write.zig`
- Update: `test/tools_read_write.zig`

Steps:

- [ ] Implement argument parsing/validation.
- [ ] Implement read with offset/limit/truncation.
- [ ] Implement write modes and approval.
- [ ] Return valid JSON for success and expected errors.
- [ ] Run `zig build test` and `zig build fmt-check`.
- [ ] Commit: `feat: add read and write tools`.

### Task 5：Edit tool

Files:

- Create: `src/tools/edit.zig`
- Create: `test/tools_edit.zig`

Steps:

- [ ] Implement exact single replacement.
- [ ] Implement multiple disjoint replacements against original content.
- [ ] Detect missing/repeated/overlapping edits.
- [ ] Implement preview and approval.
- [ ] Return valid JSON for all expected errors.
- [ ] Run `zig build test` and `zig build fmt-check`.
- [ ] Commit: `feat: add edit tool`.

### Task 6：Bash tool and output truncation

Files:

- Create: `src/tools/output.zig`
- Create: `src/tools/bash.zig`
- Create: `test/tools_bash.zig`

Steps:

- [ ] Implement output truncation/spill helper.
- [ ] Spike/confirm Zig 0.16 child process timeout/kill behavior on macOS.
- [ ] Implement bash execution in workspace root.
- [ ] Enforce approval and Unix/macOS timeout.
- [ ] Capture stdout/stderr/exit code.
- [ ] Test nonzero exit, timeout, truncation/spill.
- [ ] Run `zig build test` and `zig build fmt-check`.
- [ ] Commit: `feat: add bash tool`.

### Task 7：Search/list tools

Files:

- Create: `src/tools/grep.zig`
- Create: `src/tools/find.zig`
- Create: `src/tools/ls.zig`
- Create: `test/tools_search.zig`

Steps:

- [ ] Implement sorted `ls`.
- [ ] Implement deterministic `find`.
- [ ] Implement literal-only `grep`; `literal=false` returns `unsupported_regex`.
- [ ] Respect limits and workspace path policy.
- [ ] Run `zig build test` and `zig build fmt-check`.
- [ ] Commit: `feat: add search and list tools`.

### Task 8：Registry integration with M2 runtime

Files:

- Create: `src/tools/registry.zig`
- Create: `test/tools_registry.zig`
- Create: `test/agent_runtime_coding_tools.zig`
- Modify: `build.zig`

Steps:

- [ ] Build `ToolRegistration` array for built-ins.
- [ ] Wrap M3 tools as M2 `ToolExecutor` functions.
- [ ] Test runtime with scripted model calling real tools in a temp project.
- [ ] Add tool tests to `zig build test`.
- [ ] Add `zig build tools-fixtures`.
- [ ] Run full M3 validation.
- [ ] Commit: `feat: register builtin coding tools`.

### Task 9：Docs and README

Files:

- Create: `docs/coding-tools.md`
- Create: `docs/tool-approval.md`
- Update: README/docs listed above

Steps:

- [ ] Document tool args/result JSON.
- [ ] Document approval/preview and M3 no-UI limitation.
- [ ] Document security limits.
- [ ] Update README command list with `tools-fixtures`.
- [ ] Run full acceptance.
- [ ] Commit: `docs: document m3 coding tools`.

## 13. Acceptance commands

M3 completion must pass:

```bash
zig version
zig build
zig build run -- --version
zig build run -- --help
zig build run -- doctor
zig build run -- paths
zig build test
zig build smoke
zig build provider-fixtures
zig build agent-fixtures
zig build tools-fixtures
zig build provider-live
zig build fmt-check
```

Default behavior:

- `zig build test` is offline.
- `zig build smoke` is offline.
- `zig build provider-fixtures` is offline.
- `zig build agent-fixtures` is offline.
- `zig build tools-fixtures` is offline and mutates only temp copies.
- `zig build provider-live` skips unless explicitly enabled.

## 14. Done definition

M3 is done when:

- `src/tools` exposes metadata, context, approval, path policy, registry, and built-in tools.
- P0 tools `read`, `write`, `edit`, `bash` work through M2 `ToolRegistry`.
- P1 tools `grep`, `find`, `ls` work or are explicitly documented if deferred.
- All tool results are valid JSON.
- Expected tool errors return structured tool result JSON and do not crash runtime.
- write/edit/bash require approval by default and expose deterministic preview JSON.
- Path traversal outside workspace is rejected.
- Bash has timeout and output truncation/spill behavior.
- Edit supports exact old-text replacement and multiple disjoint edits with collision detection.
- M2 runtime can complete a scripted read/edit/bash coding-tool turn against a temp fixture project.
- Default tests are offline and do not need API keys.
- Docs describe tool contracts, approval, security limits, and M4/M5 handoff.
- Full acceptance commands pass.

## 15. Main risks

- If tools return human text instead of valid JSON, M4 session and M5 JSON mode will need fragile parsing. Keep result JSON strict.
- If expected tool errors throw `ToolFailed`, runtime will stop instead of giving the model a recoverable tool result. Return structured error JSON for user/actionable errors.
- If write/edit/bash bypass approval, M3 violates the safety goal.
- If path normalization is naive, tools can modify files outside the workspace.
- If symlink behavior is undocumented, users may assume a stronger sandbox than M3 provides.
- If bash output is unbounded, large commands can flood memory/context.
- If bash timeout relies on unavailable platform behavior, tests may pass locally but fail elsewhere. Keep M3 timeout Unix/macOS scoped and covered by deterministic tests.
- If edit applies replacements incrementally, offsets can shift and create incorrect changes. Compute ranges on original content.
- If M3 adds product CLI modes, M5 mode design will be prematurely constrained.

## 16. Handoff to M4/M5/M6

After M3:

- M4 can persist tool events/results as session JSONL entries.
- M5 can expose product CLI modes by constructing `AgentRuntime` with real provider clients and M3 tool registry.
- M6 can render approval previews and streaming tool events in TUI.
- Future milestones can strengthen path sandboxing, `.gitignore`, regex/glob behavior, and plugin tools.
