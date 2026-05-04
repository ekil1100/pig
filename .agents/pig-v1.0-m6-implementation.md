# M6 Terminal UI 实现方案

M6 在 M2 `core.agent` runtime、M3 coding tools、M4 session JSONL foundation 和 M5 CLI mode assembly 之上，实现 Pig 的 native terminal interactive experience。目标不是一次性复刻完整 Pi TUI，而是先建立可测试、可恢复、可扩展的 terminal UI 基础，使 `pig --interactive` 能进入一个稳定的本地交互界面，并且后续 M7 slash commands、resources、themes、model switching 可以自然接入。

## 目标

- 实现最小可用 interactive terminal mode：用户输入、多轮 agent turn、流式 assistant 输出、工具进度、错误展示。
- 建立 `tui` 模块的真实边界：terminal IO、input decoding、layout、renderer、components、editor 都在 `tui` 内，agent/session/provider 业务组装仍在 `app`。
- 支持 cooked fallback 和 raw-mode TUI 两层运行策略；测试默认使用 in-memory terminal，不依赖真实 tty。
- 让 assistant 流式输出不会破坏输入框，工具进度和错误不会混入用户正在编辑的内容。
- 支持 resize 后重新 layout，窄终端仍可读可操作。
- 将 M5 的 `--interactive` unsupported skeleton 接到 M6 interactive runner。
- 默认测试离线，通过 injected/scripted model client 验证 interactive behavior，不访问网络、不读取真实 API key。

## 非目标

- 不实现完整 slash command 体系；`/model`、`/resume`、`/compact`、`/theme` 属于 M7/M8。
- 不实现 terminal image protocol；M6 只提供 image placeholder component。
- 不实现 web UI、Slack、plugin ecosystem、multi-agent workflow。
- 不实现完整 mouse support；键盘输入优先。
- 不在 `tui` 中直接依赖 provider、tools implementation、session store 或 app runtime 细节。
- 不把 raw terminal 状态切换散落在 app 层；terminal lifecycle 必须集中封装，确保异常退出时能恢复。

## 当前前提和缺口

当前 main 已有：

- `src/tui/mod.zig` 只有 `TerminalMode` 和 `Capabilities` placeholder。
- M5 已有 `src/app/args.zig`、`runtime.zig`、text/json sinks、session recorder fanout。
- `pig --print` 和 `pig --json --print` 可通过 injected model 离线测试。
- `pig --interactive` 和 `pig --rpc` 当前仍由 `app_runtime.unsupportedMode` 返回明确 unsupported。
- `core.agent` 已提供 streaming `AgentEvent`，但 runtime 当前是同步 `runUserText()`；M6 需要在 app interactive 层用 worker/event queue 包装同步 runtime，才能满足 agent 忙时用户仍能输入的 roadmap 验收。

因此 M6 需要先补 terminal-independent 的 render/input foundation，再接 app interactive runner。不要直接把 renderer 写进 `src/app/cli.zig`；也不要让 `tui` 反向调用 `core.agent`。

## 模块边界

计划依赖方向：

```text
app -> tui/core/session/tools/provider/util
tui -> util
tui -/-> app/core/provider/session/tools
core.agent -/-> tui/app
session -/-> tui/app
provider -/-> tui/app
```

职责划分：

- `app/interactive.zig`：解析 `RunConfig`，组装 model client/tool registry/session recorder，驱动 turns，维护 transcript view model，连接 `tui` input/output。
- `tui/terminal.zig`：terminal capabilities、raw mode lifecycle、alternate screen policy、restore guard。
- `tui/input.zig`：byte stream 到 key events 的 decoder。
- `tui/editor.zig`：multiline input buffer、cursor、history、basic keybindings。
- `tui/layout.zig`：width-aware wrapping、viewport、scroll math。
- `tui/render.zig`：virtual screen、full render、diff render、cursor positioning。
- `tui/components.zig`：text/markdown subset/box/spacer/loader/cancellable loader/select/settings list/overlay/image placeholder。
- `tui/theme.zig`：先提供 hardcoded minimal palette，M7 再接资源主题。

`tui` 只消费普通 DTO，例如 `Frame`, `KeyEvent`, `Component`, `RenderTree`, `EditorState`。它不应该知道 “agent turn”、“tool call”、“provider event” 是什么。

建议新增文件：

```text
src/tui/terminal.zig
src/tui/input.zig
src/tui/editor.zig
src/tui/layout.zig
src/tui/render.zig
src/tui/components.zig
src/tui/markdown.zig
src/tui/theme.zig
src/tui/testing.zig
src/app/interactive.zig
test/tui_input.zig
test/tui_editor.zig
test/tui_layout.zig
test/tui_render.zig
test/interactive_mode.zig
fixtures/tui/*.txt
```

如果 M6 中 `src/tui/mod.zig` 过大，只保留 public exports。

## CLI 语义

M6 改变 `--interactive` 行为：

```text
pig --interactive
pig --interactive --cwd <path>
pig --interactive --model <model>
pig --interactive --thinking <off|low|medium|high|xhigh|max>
pig --interactive --no-tools
pig --interactive --include-p1-tools
pig --interactive --session <session-id-or-path>
pig --interactive --new-session
pig --interactive --ephemeral
```

兼容性规则：

- 无 mode flag 仍显示 help；不要在 M6 把默认行为改成 interactive，避免破坏 smoke 和脚本预期。
- `--json --interactive` 继续 usage error；machine-readable interactive 后续独立设计。
- `--interactive` 和 `--print`/`--rpc` 互斥。
- `--interactive --resume` 如果 M5 session resume 尚未实现，应明确返回 failure 或在 M6 Slice 7 补齐 resume latest 后再启用。
- 非 tty 环境下：
  - 如果显式 `--interactive`，优先使用 cooked fallback prompt loop 或返回清晰错误，不能进入 raw mode 后卡死。
  - 测试通过 in-memory terminal context，不依赖系统 tty。
- `exit`/`quit` 作为 P0 退出命令；slash commands 留到 M7。

## Terminal Layer

P0 terminal contract：

```zig
Terminal {
    input: *std.Io.Reader,
    output: *std.Io.Writer,
    capabilities: Capabilities,
    mode: TerminalMode,
}
```

需要提供：

- `enterRawMode()` / `restore()` guard。
- `enterAlternateScreen()` / `leaveAlternateScreen()`，由 policy 控制。
- `hideCursor()` / `showCursor()`，必须在 deinit/errdefer 恢复。
- `enableSynchronizedOutput()` / `disableSynchronizedOutput()`，capability 不支持时 no-op。
- `querySize()`，测试可注入固定 size。
- `TerminalLifecycle` 或 `TerminalSession`，集中恢复 terminal 状态。

Raw mode 风险：

- Zig stdlib 对跨平台 terminal raw mode 的直接支持可能不足。M6 P0 可以先实现 POSIX/macOS 路径，并保留 Windows unsupported/fallback。
- 所有 raw mode tests 必须隔离为 unit-level state tests；不要在 CI 中实际切真实 terminal。
- 真实 raw mode smoke 应是 opt-in，不进入默认 `zig build smoke`。

## Input Decoder

输入事件 DTO：

```zig
KeyEvent {
    kind: enum { char, enter, escape, backspace, delete, arrow, home, end, page, tab, paste_start, paste_end, ctrl, unknown },
    text: ?[]const u8,
    ctrl: ?u8,
    arrow: ?Direction,
}
```

P0 支持：

- UTF-8 text input。
- Enter submit 当前 input；Ctrl+J 插入换行。若 terminal 能区分 Shift/Alt Enter，M6 也把它们映射为换行。
- Backspace/Delete。
- Arrow left/right/up/down。
- Home/End。
- Ctrl+C：当前没有 active turn 时退出；active turn 时向 `AgentWorker` 发送 abort request，并设置 shared abort flag。
- Ctrl+D：空输入退出。
- Tab：P0 可插入 tab 或 no-op；autocomplete 到 M7。
- Bracketed paste detection：至少识别 start/end，并把 paste 内容按文本插入。

测试：

- 单字节 ASCII。
- 多字节 UTF-8。
- ANSI escape sequences。
- Enter submit、Ctrl+J newline。
- partial escape sequence buffering。
- paste sequence。

## Editor

P0 editor state：

```zig
EditorState {
    buffer: []u8,
    cursor_byte: usize,
    history: []const []const u8,
    history_index: ?usize,
}
```

行为：

- 插入文本、删除前一个 grapheme 的简化版本：P0 可按 UTF-8 codepoint 删除，grapheme cluster 完整支持后置。
- 左右移动按 codepoint 边界。
- Up/Down 在多行 buffer 内移动；光标位于首/末行时可进入 history navigation。
- Enter submit 当前 buffer，清空 editor；Ctrl+J 或可识别的 Shift/Alt Enter 插入换行。
- 空输入不提交。
- `exit`/`quit` 退出 interactive。
- 历史不落盘；M7/M8 可接 session/resources。

P1：

- undo/redo。
- kill ring。
- path autocomplete。
- command autocomplete。
- `@file` reference search。

## Layout 和 Renderer

P0 采用 virtual screen：

```zig
Cell { ch: u21, style: Style }
Frame { width: u16, height: u16, cells: []Cell, cursor: ?Position }
```

Renderer 流程：

1. App 把 transcript/editor/status 转成 `RenderModel`。
2. `tui/components` 生成 render tree。
3. `layout` 根据 terminal width/height 计算 lines。
4. `render` 生成 `Frame`。
5. `diff` 对比 previous frame，输出 ANSI cursor moves + changed cells。
6. resize 或 first render 使用 full render。

P0 rendering rules：

- 宽度必须按 display width 计算；ASCII 先正确，CJK/wide char 至少不 panic，必要时按 conservative width 处理。
- 不使用负宽度、不越界写 cells。
- 窄终端最小宽度小于 20 时仍输出降级布局。
- 输入框固定在底部；transcript viewport 在上方滚动。
- agent busy 时显示 loader/status line，但用户输入框仍可编辑。
- tool progress 写入 transcript/status，不直接写 stdout 破坏 frame。

Diff renderer acceptance：

- 初次 render 清屏并绘制完整 frame。
- 后续 render 只输出变化区域。
- resize 后重新 full render。
- cursor 最终位置在 editor cursor。

## Components

P0 components：

- `Text`：plain text wrapping。
- `Markdown`：最小子集，支持 paragraph、code fence、inline code、list、blockquote 的 plain rendering。
- `Box` / `Container`：用于 input/status；不要过度依赖装饰。
- `Spacer`。
- `Loader`：spinner 或 deterministic textual indicator，测试可冻结 frame index。
- `CancellableLoader`：busy state 下显示可取消状态，与 Ctrl+C abort request 文案一致。
- `SelectList`：M7 slash/model selector 的基础，M6 可只做 unit tests。
- `SettingsList`：M7 settings/model/resource 面板的基础，M6 先实现静态 row/section 渲染。
- `Overlay`：M7 command palette 基础，M6 可只做 static render。
- `ImagePlaceholder`：显示 `[image: mime/type uri]`，不实现图片协议。

Style：

- P0 支持 bold、dim、fg color enum。
- capability 不支持 color 时输出无色。
- 不在 M6 引入 theme resource loading；只内置 minimal theme。

## Interactive App Runner

`src/app/interactive.zig` 负责业务 glue：

```text
CLI RunConfig
  -> RuntimeContext / session setup / tool registry
  -> TUI session
  -> loop:
       read key events
       update editor
       on submit: run one agent turn
       AgentEvent -> transcript view model
       render after input/event/resize
```

M6 P0 需要使用 event pump 驱动 interactive turn：

- 用户提交后创建一个 `AgentWorker`，由 worker 调用 `AgentRuntime.runUserText()`。
- runtime streaming event 进入 interactive event sink，再写入 connection-owned event queue。
- 主 UI loop 同时处理 terminal input、resize signal 和 event queue，不直接在 input loop 中阻塞 provider/tool execution。
- 用户在 busy state 下可以继续编辑下一条输入；M6 P0 可以先不发送第二个 turn，但必须保留输入内容并保持 editor 可用。
- Ctrl+C 在 busy state 下设置 shared abort flag；runtime 通过现有 cooperative abort path 退出，UI 显示 abort requested/aborted。
- tests 使用 deterministic fake queue，不依赖 sleep 或真实线程调度；真实 threaded path 可另有 integration test。

需要新增或抽象：

- `AgentWorker`：拥有 `AgentRuntime` 或运行闭包。
- `InteractiveEventQueue`：从 worker 到 UI loop 的 bounded queue；队列满时必须返回明确错误，不能静默丢 event。
- shared abort flag：至少是可安全跨线程访问的 atomic/bool wrapper。
- busy-state editor model：允许编辑但不 submit 新 turn，或明确排队一个 pending prompt。

## Event 到 UI 的映射

Interactive sink 不直接渲染 ANSI。它只更新 view model：

```zig
TranscriptItem {
    kind: enum { user, assistant, tool, error, status },
    text: []const u8,
    is_streaming: bool,
}
```

Mapping：

- `turn_start`：append user item。
- `message_start`：start assistant item。
- `message_delta.text_delta`：append to current assistant item。
- `tool_start`：append/update tool item `running read ...`。
- `tool_delta`：append tool progress summary。
- `tool_end`：mark tool item success/error。
- `error`：append error item。
- `abort`：append status/error item。
- `turn_end`：mark current turn status。

不要让 `tui` 认识 `AgentEvent`；mapping 在 `app/interactive.zig` 或 `app/tui_model.zig`。

## Session 接入

沿用 M5 `app/session_runtime.zig` recorder fanout：

- interactive 默认写 session，除非 `--ephemeral`。
- 每个 submitted input 是一个 turn。
- recorder 仍从 `AgentState.messages` 读取完整 provider-independent messages，避免从 UI text delta 重建。
- `--session` 可打开已有 file/path。
- `--new-session` 创建新 session。
- `--resume` 如果 M6 不补 latest lookup，保持 clear failure；不要 silently create new session。

M6 可以新增 `session.listLatestByCwd` 作为 Slice 7，给 `--resume` 和后续 `/resume` 铺路；但不要让 `tui` 直接依赖 `session`。

## 错误处理和恢复

必须保证：

- raw mode/alternate screen/cursor hide 任意错误路径都恢复。
- render error 返回 `ExitCode.internal`。
- agent/provider/tool/session failure 在 UI 中显示，并让 interactive loop 继续可用，除非 session open/create 本身失败。
- Ctrl+C：
  - idle：退出，恢复 terminal。
  - running：设置 abort flag；若当前 M2 runtime 只 cooperative abort，则显示 abort requested。
- panic 不能保证恢复，但所有显式 error return path 必须用 guard。

## 实现切片

### Slice 0: TUI 基础类型和测试 harness

- 扩展 `src/tui/mod.zig` exports。
- 新增 terminal/input/render/editor/layout/component DTO。
- 新增 in-memory terminal test harness。
- 测试不写真实 terminal。

验收：

- `zig build tui` 可运行基础 TUI unit tests。
- `zig build test` 纳入 TUI tests。

### Slice 1: Input Decoder

- 实现 byte stream 到 `KeyEvent`。
- 支持 ASCII、UTF-8、Enter、Backspace、Arrow、Home/End、Ctrl+C/D、paste markers。
- partial escape sequence 不 panic。

验收：

- `test/tui_input.zig` 覆盖 key sequences。

### Slice 2: Editor

- 实现 multiline buffer model。
- 插入、删除、左右移动、history up/down、submit、empty skip、exit/quit detection。
- 不依赖 terminal。

验收：

- `test/tui_editor.zig` 覆盖 cursor、history、多行输入和多行内移动。

### Slice 3: Layout 和 Components

- Plain text wrapping。
- Minimal markdown rendering。
- Multiline input/status/transcript layout。
- Narrow terminal fallback。
- Loader 和 cancellable loader deterministic frame。
- Select/settings list static layout。

验收：

- `test/tui_layout.zig` 覆盖宽度、窄终端、CJK conservative handling。
- component layout tests 覆盖 loader、cancellable loader、select list、settings list。

### Slice 4: Virtual Screen 和 Renderer

- 实现 `Frame` 和 `Cell`。
- Full render 输出 ANSI。
- Diff render 输出最小变化。
- Cursor positioning。
- Resize full redraw。

验收：

- `test/tui_render.zig` golden ANSI 或 structured frame assertions。

### Slice 5: Terminal Lifecycle

- POSIX/macOS raw mode guard。
- alternate screen policy。
- cursor/sync output guard。
- cooked fallback。

验收：

- Unit tests 覆盖 lifecycle state machine。
- 真实 raw mode smoke 默认不跑；可提供 `zig build tui-live` opt-in。

### Slice 6: Interactive Mode 接入

- 新增 `src/app/interactive.zig`。
- `cli.zig` dispatch `.interactive` 到 runner。
- 使用 M5 runtime assembly 或抽出 shared assembly，避免复制 tool/session/model setup。
- 支持 scripted model injection test。
- 实现 event pump：input loop 不被 `AgentRuntime.runUserText()` 阻塞。
- 初版至少支持 submit -> worker turn -> streaming render -> next prompt。

验收：

- `test/interactive_mode.zig` 使用 in-memory terminal 输入两轮，检查 transcript frame。
- `pig --interactive --ephemeral` 在无 live provider 时显示 model unavailable 而不是崩溃。
- busy state 下继续输入不会破坏当前 streaming render。

### Slice 7: Busy/Abort 和 Resize

- 支持 agent busy 时继续编辑。
- Ctrl+C busy 时请求 abort，idle 时退出。
- resize event 触发 full redraw。

验收：

- Busy-state model unit tests。
- Abort request tests。
- Resize layout tests。

### Slice 8: Session Resume Prep

- 可选补 `session.resumeLatest(cwd)` / `listByWorkingDirectory(cwd)`。
- `--resume` interactive 可用或保持明确 unsupported。
- 不实现 tree selector UI。

验收：

- session latest/list tests。

## 测试计划

单元测试：

- input decoder：key sequences、UTF-8、Enter submit、Ctrl+J newline、partial escape、paste。
- editor：insert/delete/move/history/multiline navigation/submit。
- layout：wrap、viewport、narrow terminal。
- components：markdown subset、loader、cancellable loader、box、select list、settings list、overlay placeholder。
- renderer：full render、diff render、cursor position、resize redraw。
- terminal lifecycle：state transitions、restore-on-error guard。

Integration tests：

- `pig --interactive --ephemeral` with injected scripted model renders one assistant response。
- 两轮输入保持 transcript。
- tool call event 显示 tool progress，并继续 assistant final text。
- provider/model unavailable 显示错误并保持 terminal restored。
- non-tty/cooked fallback 行为明确。

Build steps：

- 新增 `zig build tui`。
- 新增 `zig build interactive-mode`。
- 将 deterministic tests 纳入 `zig build test`。
- `zig build smoke` 仍只跑 `--version`、`--help`、`doctor`、`paths`；不进入真实 interactive。
- 可选 `zig build tui-live` 手动 smoke，不进入默认 CI。

Fixtures：

```text
fixtures/tui/input-basic.txt
fixtures/tui/render-basic.ansi
fixtures/tui/render-resize.ansi
fixtures/tui/interactive-basic.txt
```

Fixtures 不能包含真实用户路径、API key 或真实 session 内容。

## 验收清单

- `zig build test` 通过。
- `zig build tui` 通过。
- `zig build interactive-mode` 通过。
- `zig build smoke` 仍离线通过。
- `pig --interactive` 不再返回 unsupported；在缺少 live model 时给出可恢复错误。
- interactive mode 使用 `tui` renderer，不直接向 stdout 写散乱 diagnostics。
- assistant streaming output 不覆盖 input box。
- agent busy 时用户仍能输入，输入内容不丢失。
- resize 后可 full redraw。
- raw mode/alternate screen/cursor hide 在错误路径恢复。
- `tui` 不依赖 `app/core/provider/session/tools`。
- `app` 负责 AgentEvent -> UI view model 映射。

## 风险和防线

- Raw terminal API 跨平台复杂：先封装 lifecycle 和 fallback，默认测试不切真实 tty。
- 如果 `tui` 直接消费 `AgentEvent`，后续 UI 会绑定 agent internals。保持 mapping 在 `app`。
- 如果 renderer 直接 print 而不维护 virtual frame，resize/diff 会很快失控。先做 frame model。
- 如果 streaming event 和 input editing 同线程阻塞，无法满足 busy input 验收。M6 P0 必须通过 worker/event queue 或等价机制避免阻塞 input loop。
- 如果 session recorder 从 UI 文本重建消息，会丢 tool/thinking block。继续复用 M5 recorder。
- 如果默认 smoke 进入 interactive，会挂 CI/脚本。interactive tests 必须通过 injected in-memory terminal。

## M6 完成后的后续承接

- M7 接入 config/auth/models/resources/slash command。
- M8 接 session tree UI、resume selector、compaction。
- M9/M10 可补更完整 markdown、themes、terminal image protocol。
- M11 继续完善 RPC/SDK，与 TUI event/view model 保持分离。
