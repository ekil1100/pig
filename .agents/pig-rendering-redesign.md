# Pig interactive renderer redesign

## 背景

当前 Pig 的 live interactive 渲染已经出现同一类问题的多种表现：

- assistant 内容流式输出时，旧快照留在 scrollback，导致内容重复。
- `... running (Ctrl+C to abort)` 和 `>` 输入行被插入到 assistant markdown 中间。
- 复杂 markdown、表格、目录树在 streaming 中被拆散并横向偏移。
- 底部输入行有时消失，因为 incremental streaming 分支直接写 stdout，绕过了 prompt/footer 的统一重绘。

这些不是单个 ANSI 序列写错，而是渲染模型冲突。`src/app/interactive.zig` 现在同时存在：

- transcript append 输出。
- streaming delta 直接写 stdout。
- footer/prompt 用 save/restore cursor 伪固定到底部。
- scripted path 的 full-frame renderer。

只要这些路径继续共存，resize、wrap、tool output、markdown streaming、busy input 都会不断互相覆盖。

## Pi-mono 参考结论

本设计参考本机 `/Users/like/workspace/pi-mono` 的实现，而不是文档描述。

关键文件：

- `/Users/like/workspace/pi-mono/packages/tui/src/tui.ts`
- `/Users/like/workspace/pi-mono/packages/tui/src/terminal.ts`
- `/Users/like/workspace/pi-mono/packages/tui/src/utils.ts`
- `/Users/like/workspace/pi-mono/packages/tui/test/tui-render.test.ts`
- `/Users/like/workspace/pi-mono/packages/tui/test/viewport-overwrite-repro.ts`
- `/Users/like/workspace/pi-mono/packages/coding-agent/src/modes/interactive/interactive-mode.ts`
- `/Users/like/workspace/pi-mono/packages/coding-agent/src/modes/interactive/components/assistant-message.ts`
- `/Users/like/workspace/pi-mono/packages/coding-agent/src/modes/interactive/components/footer.ts`

Pi 的核心思路：

1. UI 是组件树。每个 component 只暴露 `render(width) -> []line`，不直接写 terminal。
2. App 收到 agent/session event 后只更新 component/model，然后调用 `requestRender()`。
3. Renderer 维护 `previousLines`、terminal width/height、`previousViewportTop`、`hardwareCursorRow`。
4. 每次 render 都从组件树重新生成完整 logical lines，再由 renderer 决定 full redraw 或 diff redraw。
5. Streaming text 不是 stdout delta。它只是 assistant component 的 content 变更。
6. 渲染写入被 coalesce/throttle，Pi 默认最小间隔约 16ms。
7. 对 resize、content shrink、viewport 上移、changed line above viewport 直接 full redraw。
8. 输入组件用 zero-width cursor marker 标出 logical cursor，renderer 提取后再定位硬件光标。
9. 测试用 headless xterm 复现真实 viewport/scrollback 行为，专门有 viewport overwrite regression。

注意：Pi 的 interactive 主路径并不是 alternate screen 固定全屏 UI。它更像 scrollback-preserving document renderer：chat、status、editor、footer 都是同一个 logical document 的连续 lines，终端显示底部 viewport。这个选择非常适合 coding-agent transcript，因为历史内容天然应该留在 scrollback。

## 设计决策

Pig 应该采用 Pi-style scrollback-preserving document renderer，而不是继续修补 `LiveRenderer`。

核心原则：

- live TTY 模式只有一个 writer：renderer。
- provider/tool/agent event 永远不直接写 ANSI。
- streaming delta 只修改 AppState/ViewModel。
- prompt、busy status、tool progress、footer 都是组件/行模型的一部分，不用 save/restore cursor 维护。
- renderer 对 terminal 位置负责；app 只表达要显示什么。
- scripted interactive 和 live interactive 共用同一个 render model，输出策略不同。

## 目标架构

```text
provider/tool events
        |
        v
core.agent events
        |
        v
app interactive reducer
        |
        v
InteractiveState
        |
        v
ViewModel / Component tree
        |
        v
logical lines
        |
        v
tui renderer: full/diff/viewport/cursor
        |
        v
Terminal
```

模块边界：

- `app` 负责业务状态：turn、transcript、tool state、busy、commands、session。
- `app` 把业务状态转换为普通 view model 或 component tree。
- `tui` 负责 terminal、input、layout、width、component render、diff render。
- `tui` 不知道 `AgentEvent`、provider、tool registry、session store。

## 新模块建议

建议把当前 `src/app/interactive.zig` 中的渲染职责拆出去。

```text
src/tui/component.zig          Component interface and containers
src/tui/screen.zig             Line/Frame/viewport/cursor primitives
src/tui/renderer.zig           Pi-style logical-line diff renderer
src/tui/terminal.zig           raw mode, bracketed paste, restore guard, size
src/tui/virtual_terminal.zig   test emulator for CSI subset

src/app/interactive/state.zig  InteractiveState reducer
src/app/interactive/view.zig   state -> components/logical lines
src/app/interactive/runner.zig live/scripted event loop
```

如果现在不想大拆目录，可以先保留 `src/app/interactive.zig`，但必须先把 `LiveRenderer` 迁到 `src/tui/renderer.zig` 的替代实现，并删除直接 streaming stdout 路径。

## Renderer 数据结构

建议的 renderer 状态：

```zig
const LogicalFrame = struct {
    width: u16,
    height: u16,
    lines: []const []const u8,
    cursor: ?LogicalCursor,
};

const TerminalRenderer = struct {
    previous_lines: [][]const u8,
    previous_width: u16,
    previous_height: u16,
    previous_viewport_top: usize,
    hardware_cursor_row: usize,
    max_lines_rendered: usize,
    render_requested: bool,
    last_render_ns: i128,
};
```

关键点：

- `lines` 是完整 logical document，不是只包含当前屏幕高度的 frame。
- viewport 默认是 `max(0, lines.len - terminal.height)` 到末尾。
- renderer 可选择只 diff visible/affected lines，但比较依据是完整 logical lines。
- resize、width change、height change、content shrink、changed line above previous viewport 走 full redraw。
- appending beyond viewport 时，renderer 通过 CRLF 推动 scrollback，并更新 `previous_viewport_top`。
- 每次写 terminal 都用一个 buffer，一次 flush，避免半帧可见。
- 支持 synchronized output capability 时包裹 `CSI ? 2026 h/l`。

## 渲染循环

Live mode 事件循环应该变成：

```text
while running:
  drain input events
  drain agent event queue
  apply events to InteractiveState
  if state changed:
    requestRender()
  renderer.renderIfDue(stateToFrame(state))
```

`requestRender()` 只置脏，不立即散写。renderer 可以：

- 立即在 next tick 渲染。
- 或者在 streaming 忙时按 16-33ms coalesce。
- 空闲输入编辑可以立即渲染，保证输入响应。

当前 `pumpActiveTurn()` 可以保留 queue drain 结构，但不再传入 `LiveRenderer` 写 stdout，而是返回 `changed`，由统一 render scheduler 处理。

## 组件模型

P0 组件不需要一次追齐 Pi 的所有能力，只需要先恢复正确性。

最小组件：

- `Container`: children 顺序拼接。
- `Text`: plain wrapped text。
- `Markdown`: 当前已有 markdown subset，可作为 component。
- `TranscriptItem`: user/assistant/thinking/tool/error/status。
- `Editor`: 输入行和 cursor marker。
- `Footer`: cwd/model/token/status，可先简单一行。
- `Loader`: busy/status spinner，可先静态。

重要规则：

- footer/editor/status 是 document 末尾组件，不是独立 terminal overlay。
- 后续 selector/modal 可以做 overlay，但 overlay 仍由 renderer 在同一 frame 中 composite，不直接写 ANSI。
- assistant streaming 更新 `AssistantMessageComponent.text` 后 `requestRender()`。
- tool call start/end 更新 `ToolExecutionComponent.state` 后 `requestRender()`。

## Cursor 和输入行

不要再用 `\x1b7` / `\x1b8` 保存恢复光标来维护输入行。

改用 Pi 的 marker 思路：

- Editor render 时在 cursor 位置插入 zero-width marker，例如 `\x1b_pig:c\x07`。
- Renderer 在 visible lines 中查找 marker，计算 display width，剥掉 marker。
- 渲染完成后定位硬件光标到该位置。
- 默认可以继续隐藏硬件光标；需要 IME 支持时再显示。

这能保证 prompt 永远是 frame 的一部分，streaming markdown 不会把 prompt 插进文本中间。

## 宽度、换行和 ANSI

Pig 目前 `layout.displayWidth` 与 markdown/ANSI 的关系还太薄。需要把 width 处理收敛到 `tui/layout.zig`：

- 所有 component 输出必须保证 visible width 不超过 terminal width。
- tabs 统一转换为 3 或 4 spaces，选一个固定策略。
- ANSI/OSC/APC escape 不计入 visible width。
- CJK/emoji 先采用 conservative width，宁可少放一个字符，不让 terminal auto-wrap 漂移。
- 每个 rendered line 末尾追加 style reset，避免样式泄漏到下一行。

Renderer 应在 debug/dev 模式下 assert：非 image line 的 visible width <= terminal width。失败时写 crash log，附上所有 logical lines。

## Terminal lifecycle

`src/tui/terminal.zig` 应从能力占位升级为真实 terminal abstraction：

- enter raw mode and restore with guard。
- hide/show cursor。
- bracketed paste enable/disable。
- size query。
- synchronized output enable when available。
- optional input drain on exit，避免 raw key release 泄漏到 shell。

P0 可以不做 Kitty keyboard protocol，但 bracketed paste 和 restore guard 应先做稳。

## Scripted mode 与 live mode

Scripted tests 不应该使用 live ANSI diff。建议分两层：

- `scripted renderer`: 直接 full render final frame 或 plain transcript snapshot，便于 CLI tests。
- `live renderer`: 使用 TerminalRenderer diff/full redraw。

两者必须共用同一个 `state -> logical lines` 路径。这样 scripted tests 能覆盖业务展示，live-only tests 覆盖 ANSI/viewport。

## 迁移计划

### Slice 1: 停止继续扩展 LiveRenderer

- 标记 `LiveRenderer` 为待删除。
- 删除 streaming delta 直接 stdout 的设计方向。
- 保留当前代码能编译，但新修复不再向 `streamTextItem` / `renderStreamingFooter` 里加逻辑。

验收：

- 文档落地。
- 后续 PR 不再增加 `\x1b7` / `\x1b8` footer 修补。

### Slice 2: 引入 logical document renderer

- 新增 `tui/renderer.zig`，维护完整 logical lines 和 viewport state。
- 从 Pi 的 `previousLines`、`previousViewportTop`、`hardwareCursorRow`、`maxLinesRendered` 模型翻译成 Zig。
- 支持 first render、width change、height change、content shrink、diff changed lines。
- 每次输出 single buffer。

验收：

- `test/tui_render.zig` 覆盖 append、middle-line change、shrink、resize、cursor marker。

### Slice 3: 统一 interactive render path

- `InteractiveApp.renderFrame()` 改为生成完整 logical document，不裁剪到 terminal height。
- live mode 使用 `TerminalRenderer.render(frame)`。
- scripted mode 使用同一 frame 的 snapshot/full render。
- 删除 `flushed_items`、`live_height`、`live_after_stream`、`streaming_text_bytes`。

验收：

- streaming assistant 不重复旧内容。
- busy status 和 input line 不插入 markdown 中间。
- 多轮 turn 不丢 prompt。

### Slice 4: Component 化 transcript/status/editor/footer

- 把 transcript line 拼接从 app 中抽成 component/view 层。
- Editor component 输出 cursor marker。
- Tool/status/busy 作为普通 component。
- Footer 可以先简单显示 cwd/model/busy。

验收：

- `app/interactive.zig` 不再直接拼 terminal ANSI。
- `tui` 仍不 import `app/core/provider/session/tools`。

### Slice 5: 真实 viewport regression

- 新增一个 pure Zig virtual terminal，至少支持 Pig renderer 用到的 CSI subset。
- 或者添加 opt-in headless xterm runner，不纳入默认依赖。
- 固化本次截图对应场景：长 markdown streaming、tool lines、running status、prompt/footer。

验收：

- `zig build interactive-mode` 包含 scripted regression。
- opt-in live regression 能复现并防止 viewport overwrite。

## 测试矩阵

必须覆盖：

- assistant markdown streaming 每个 delta 都只出现一次。
- message_end 与最后 delta 同一 pump 时不丢最后内容。
- tool start/end 不重复打印 `tool:` 行。
- busy status 出现和消失不覆盖 assistant 文本。
- editor 在 busy 时可继续输入，输入文本保持可见。
- terminal width resize 后重新 wrap。
- height resize 后 viewport 对齐。
- content shrink 后 stale lines 被清除。
- CJK、emoji、ANSI style、code fence、table-like text 不触发 auto-wrap drift。

建议新增 regression fixture：

```text
fixtures/tui/stream-markdown-with-tools.jsonl
fixtures/tui/viewport-overwrite.jsonl
fixtures/tui/busy-input-preserved.jsonl
```

## 明确不要做的事

- 不要让 provider parser 或 AgentRuntime 直接输出 terminal 文本。
- 不要在 streaming 分支里直接 `writeAll(delta)`。
- 不要用 save/restore cursor 维护主输入行。
- 不要同时维护 scrollback append renderer 和 fixed-bottom renderer。
- 不要让 `is_streaming` 决定 terminal 清屏策略；它只能是 message state。
- 不要把真实 TTY smoke 放进默认 CI，避免挂住构建。

## 推荐落地顺序

1. 先实现 `tui/renderer.zig` 的 Pi-style logical-line diff。
2. 再把 live interactive 切到该 renderer。
3. 最后再做组件化和更漂亮的 markdown/footer。

也就是说，优先修复“谁拥有 terminal”和“frame 如何更新”，再追 UI 表现。当前布局问题的根因在 ownership，不在 markdown renderer 本身。
