# TUI_STATE_ARCHITECTURE — cc-zig TUI 状态驱动架构(UiState + Event + dispatch + 纯函数 render)

> 来源:2026-06-05 session。用户连续指出 cc-zig TUI 的架构病根(Ctrl+O 是旁路非视图、状态流转无法测试、加 CC 功能靠散点硬接线),决策做**状态驱动架构重构**。本文是目标架构设计 + 分阶段迁移计划。
> 关联设计文档:[UI_DECOUPLE_BACKEND_FRAMEWORK](UI_DECOUPLE_BACKEND_FRAMEWORK.md)、[CORE_REFERENCE](CORE_REFERENCE.md)。早期 TUI 设计稿(TUI_DESIGN、UI_LAYER_DESIGN、TUI_ALIGNMENT 等)已随过程文档清理移出仓库,见 git 历史。
> 本文管"UI 状态怎么算";"屏幕和 scrollback 上每个字节归谁、谁能擦"(Renderer 独占 scrollback 写入、erase/print/redraw 成对、半行续接快照、只用 ED 0、不用 DECSC/DECRC)见 ADR [TUI_VIEWPORT_OWNERSHIP](TUI_VIEWPORT_OWNERSHIP.md),由 `zig build test:scrollback` 执行。
> 状态:设计稿(2026-06-05),供逐阶段实施依据;§8 阶段所有权(#330)已落地(2026-10-28),§1 字段树按现状更新。

## §0 病根(为何重构)

cc-zig UI 现状 = **命令式 + 散点重绘**:
- 15+ 处直接改 RenderRegion 字段,每处自己手动 erase+redraw;无统一脏标记。
- 状态与 fd=2 IO 耦合在 drawGenRegion(既算状态又写终端)→ 无法内存级测试。
- 加一个状态就加一条手接线(footer/`?`/Ctrl+O 都是新旁路)。
- Ctrl+O 现状:退 raw mode → 跑 alt-screen transcript viewer → 回来(旁路,非视图状态,只能 pty 测)。
- `?` help 现状:错放 loop.zig 命令派发(需回车)。
- 跨线程裸读:app.usage/tasks 多线程读未全保护。

**好的部分(要复用不重写)**:status_bar/tool_card/agent_tree 已是纯函数 widget(state→string);test_capture.zig 的 CaptureWriter+stripAnsi 是现成内存断言设施;eraseRegion 用 prev_rows 精确擦不碰 scrollback 的机制贴实。

**两个设计目标(用户定)**:① 面向可测试(状态与 IO 解耦,纯内存断言)② 方便对齐 Claude Code(用 CC 心智:state→投影、事件改 state;加 CC 功能=加状态位+投影分支,非散点接线)。

## §1 架构核心(4 件套 + 硬边界)

**硬边界**:`ui_state.zig`/`event.zig`/`ui.zig` **不 import std.c、不碰 fd、不持 mutex**——编译期保证可测性(想写 IO 必 import std.c,review 一眼可见)。

| 件 | 文件 | 职责 | 碰 IO? |
|----|------|------|--------|
| **UiState** | ui_state.zig(新) | 集中所有 UI 逻辑状态(纯数据) | 否 |
| **Event + Effect** | event.zig(新) | 事件 tagged union + dispatch 返回的副作用描述 | 否 |
| **dispatch + render** | ui.zig(新) | dispatch(state,ev)→Effect 改 state;render(w,inputs)→Frame 投影帧 | 否(纯函数) |
| **Renderer** | render_region.zig(瘦身) | 唯一碰 IO:持 mutex+机制态,applyEvent 锁内 dispatch+erase+draw 到 fd | **是(唯一)** |

### UiState 字段树(逻辑状态,机制态不进)
现状(#330 之后;完整的归属表与规则见 §8):
- **会话拥有**(顶层字段,跨阶段存活,每个都在 `UiState.session_owned` 写明原因):cols/rows(几何)、footer(usage/mode 快照,收口跨线程裸读)、panel(Ctrl+T 偏好)、agent_count(registry 镜像)。
- **阶段拥有**:`phase: PhaseState = union(Phase){ idle, input: InputPhase, generating: GeneratingPhase }`。
  - 两个交互阶段共有 `Interaction`:editor(LineEditor 的**投影** borrow,LineEditor 本体不并入)、help_open、ctrl_x_armed、agents(switcher)、picker_open。
  - `InputPhase`:slash_catalog(借用本次读取的 arena)、slash_sel、paste_hint、press(双击窗口)、menu_dismissal。
  - `GeneratingPhase`:spinner(frame/verb/start_ms,elapsed=now-start,now 注入)、tools(current 定长 + cards[] MAX 6,定长拷贝防跨线程撕裂)。
- **不进 UiState**:prev_rows/region_drawn/anchor(回顶支点,见 `tui/reflow.zig`)/mutex/line_buf/pending 快照/gen_app/gen_queue——属 Renderer(是"上一帧物理痕迹"或绘制用的借用指针,非逻辑状态)。

### render 的大数据靠注入(纯函数)
`RenderInputs{ state, now_ms, theme, use_unicode, agent_snaps[], tasks?, queue_preview[], transcript_lines[] }`——时间注入、大数据只读借用,不拷进 UiState。测试传空/mock 即可。

### Event union + Effect
- Event:key/tool_progress/text_chunk/spinner_tick/resize/usage/job_progress/set_current_tool/add_tool_card/clear_tool_card/phase_change/editor_view
- Effect(dispatch 返回):redraw_region:bool / emit_scroll:?[]u8(文本进 scrollback)/ action:?LoopAction(非渲染语义上抛主循环,如 commit/cancel/pass_to_editor)
- **LineEditor 不并入 UiState**:编辑键 dispatch 返回 action=.pass_to_editor → 主循环喂 LineEditor → 新 view → 发 editor_view 事件 → 更新投影。不重写已被 60+ 单测覆盖的编辑器。

### render 投影:overlay→phase 两层
```
render: switch overlay {
  help → renderHelp(多列快捷键)
  transcript → renderTranscript(复用 transcript_viewer.renderToLinesWithTheme + 窗口切片)
  none → switch phase { input → renderInputFrame; generating → renderGenFrame }
}
```
renderInput/GenFrame = 把现 renderFrameInner/drawGenRegion 的**纯计算行内容**部分照搬(调现有 widget),**不做光标移动/erase**——只产帧字符串 + Frame{rows,cursor_row,cursor_col}。光标定位/erase/收缩擦除留 Renderer。

## §2 可测试性(三层,绝大多数下沉 L2 内存级)

1. **dispatch 状态转移**(纯 state):`dispatch(空editor,'?')→overlay==help`;`dispatch(ctrl_o)→overlay main↔transcript 切换`(**Ctrl+O 现可纯单测,现状只能 pty**);spinner_tick 推进帧;tool_progress 更新卡片并要求重画。
2. **render 帧内容**(CaptureWriter+stripAnsi):`render(overlay=help) 含 Ctrl+O/Shift+Tab`;`render(input) 不含 \x1b[2J`(不碰 scrollback);`render(spinner,now_ms=3000) 含 "(3s"`(时间注入→确定)。
3. **全链路 事件→状态→帧**(不起终端/不连模型):送 `?`→render 出 help 帧→送任意键→render 回输入帧。
挂 apps/cli/tests/component/ui_state_test.zig + ui_render_test.zig,经 main.zig 导出 tui_ui_state/tui_ui/tui_event。pty 测只留机制断言(光标/erase 不破 scrollback/resize),内容断言全下沉。

## §3 线程模型(保留并发,mutex 直接 dispatch,不引队列)

权衡:队列方案最干净但与"tool progress 必须当帧渲染"低延迟冲突 + 改动大风险高 → **选 mutex 直接 dispatch**(贴现状)。UiState 由 Renderer mutex 保护(锁归 Renderer)。
- 各事件源在自己线程 `renderer.applyEvent(in, ev)`:锁内 dispatch→据 Effect erase+draw。
- 工具进度立即重画(当时的设计:Effect.immediate → 同锁内同步执行)。**#328 起**:Effect.immediate 删除(声明后从未被读),dispatch 仍在事件线程锁内同步改 UiState,只有绘制经合并窗口调度(§9);生成期多一个事件源——合并窗口的定时线程(会话级,惰性启动,deinit join)。
- 跨线程裸读收口:usage/mode→快照进 UiState.footer(发 .usage 事件);agent_jobs/tasks→render 经 RenderInputs 只读借用(调用方先持 registry 锁 snapshotJobs)。
- SIGWINCH handler 仍只 atomic-store flag,poll 超时观察→发 .resize。
- 5 事件源:主线程 readLineRaw / 主线程 agent_loop / watcher 线程 / tool 执行线程 / 后台 subagent。

## §4 分阶段落地(增量,每阶段编译+测试绿,新旧并存)

**机制态始终单份**(在 Renderer),新旧方法都读写它,迁移不因"两套机制态"错位。迁移=把"旧方法拼字节"换成"旧方法调 applyEvent→dispatch→render",机制态不动。

- **阶段0 骨架+纯测试**(零接线零风险):建 ui_state/event/ui.zig(render 调现有纯函数)+ main.zig 导出 + 写 §2.1/2.2 测试。验收:zig build test 绿,主循环未用它。
- **阶段1 第一个完整视图=`?` help + Ctrl+O transcript**(集中验收三诉求):Renderer 加 state+applyEvent,input 期接管 overlay;`?`(空框即时)/Ctrl+O 走 dispatch 切 overlay;transcript 复用 renderToLinesWithTheme **不进 alt screen**;删 loop.zig `?` 命令分支 + Ctrl+O 退 raw mode 旁路。验收:L2 全链路 + L3 pty 验真终端即时切换不进 alt screen。
- **阶段2 footer+usage**:drawFooter 投影 UiState.footer;usage_sink 发 .usage。
- **阶段3 spinner+phase**:enter/leaveGenerating 发 .phase_change;tick 发 .spinner_tick;drawGenRegion 纯部分搬进 renderGenFrame。
- **阶段4 tools**:set/add/clear/progress 转事件;多卡不互盖单测平移 dispatch 层;Effect.immediate 测试。
- **阶段5 文本+收尾**:text_chunk→emitToScroll(行缓冲/半行续接/pending 快照平移);RegionWriter 发事件;RenderRegion 收敛 Renderer。全量 test + test:e2e-tty 绿。

风险:迁移期每阶段只迁一个视图/一类事件;eraseRegion/emitToScroll 字节逻辑逐行照搬不重写,每阶段 pty 跑 test_shrink_jitter 守"收缩擦除/不碰 scrollback";Event 闭合 union → dispatch/render 漏分支编译报错(漏接线编译失败非运行时静默)。

## §5 对齐 CC 可扩展性(加功能=四点闭环,编译期防漏)

加 CC 功能 = 加 Event 变体 + UiState 字段 + dispatch 分支 + render 分支,四处闭环。
- 例1 loading footer hint(esc to interrupt / stop agents / ? for shortcuts 优先级):加纯函数 footerHint(s),render 调它,无新事件。
- 例2 agent stopped 瞬时提示:加 .job_done 事件→dispatch 设 state.hint→render 多投影一行→tick 过期清。全内存级可测。
对比现状(散点硬接线+跨线程裸读),新架构声明式、每点可单测。

## §6 关键文件

新建:ui_state.zig / event.zig / ui.zig / tests/component/{ui_state,ui_render}_test.zig。
瘦身:render_region.zig→Renderer(mutex+机制态+applyEvent,平移 eraseRegion/emitToScroll/行缓冲)。
改接线:loop.zig(readLineRaw/stdinAbortWatcher 走 applyEvent,删 `?` 命令分支+Ctrl+O 旁路)。
保留:input.zig(LineEditor 作 editor 子系统产 Action)、transcript_viewer.zig(renderToLinesWithTheme 复用为 transcript overlay 纯投影源)。
复用纯 widget:status_bar/tool_card/agent_tree;测试设施:test_capture.zig。

## §7 实施进度(2026-06-05 落地)

逐阶段实施→测试→改 bug→下一阶段。每阶段编译+全量单测绿。

- **阶段0 骨架+纯测试 ✅**:新建 ui_state.zig/event.zig/ui.zig + main.zig 导出 + tests/component/{ui_state,ui_render}_test.zig(23 内存级测试:dispatch 状态转移 + render 帧内容 + 全链路)。反向破坏验证(禁 `?` 拦截→测试红)证明真锚定。主循环未接线(零风险增量)。
- **阶段1 ? help + Ctrl+O transcript ✅**:RenderRegion 加 `ui:UiState`+`applyEvent`+`renderOverlayInner`(复用 renderFrameInner 的 erase/prev_rows 骨架,中段换 ui.render);readLineRaw 非 vim 路径 key 先经 applyEvent 分流(overlay 消费/pass_to_editor)。Ctrl+O **从退 raw mode 旁路改成视图态**(overlay=.transcript,复用 renderToLinesWithTheme,不进 alt screen)。`?` 空框即时切 help。5 个 pty 测试。**修 1 真 bug**:ui.render 末行带 \r\n 致光标回顶偏移、help 关闭后标题残留——renderOverlayInner 画完先 up(1) 回区最后一行对齐 renderFrameInner 约定。
- **阶段2 footer ✅**:drawFooter 改读 self.ui.footer(app fallback);ui.renderFooterLine 升级完整版(左+右 tokens 两端对齐)pub 复用。诚实范围:输入期 footer 单线程裸读本安全,未强行接 usage_sink(无净收益);多线程 usage 事件归后续。
- **阶段3 spinner+phase ✅**:enterGenerating/tickSpinner/leaveGenerating 同步写 self.ui.{spinner,phase}(双写过渡)。渲染零风险(drawGenRegion 暂仍读旧字段)。
- **阶段4 tools ✅**:setCurrentTool/clearCurrentTool/addToolCard/clearToolCard/setToolProgress 同步写 self.ui.tools(双写过渡)。
- **阶段5 文本+收尾**:**诚实范围收缩(L0:不为架构纯粹破坏正常工作的东西)**。文本/scrollback 协议(writeGenText/emitToScroll/半行续接/行缓冲)现工作正常+pty 覆盖(test_shrink_jitter/wrap_resize),改成事件流**无功能收益、高风险**(半行续接快照极易破)→**不做**。"删双写消除技术债"需 drawGenRegion 整体搬进 ui.renderGenFrame(独立大重构)→**登记后续迭代**。当前双写无 bug、UiState 状态已就位(为未来纯 render 铺路)。

**已达成用户三诉求**:① 真 Ctrl+O(视图态,可纯单测,非旁路)② 真测试(23 内存级 dispatch/render,不依赖真模型/key,Ctrl+O/? 现可纯单测)③ 可测+易对齐 CC(UiState/dispatch/render 硬边界不碰 IO;加 CC 功能=加 Event+字段+dispatch+render 四点闭环,闭合 union 漏分支编译报错)。

**遗留(后续迭代)**:drawGenRegion 整体搬进 ui.renderGenFrame + 删 RenderRegion 双写字段(spinner_frame/verb/tool_cards 等)+ 文本事件流。这是把"双写过渡"收敛为"单一真相源"的纯重构,无功能变化,可独立安全推进。

## §8 阶段是 widget 生命周期的唯一驱动(#330,2026-10-28)

**问题**:共享 Renderer(#298 之后整个会话一个 RenderRegion)让每个 widget 状态都可能活过它被打开的那一期——回复里开着的 agent 列表吞掉下一次提示的输入、卡住的 generating 让输入框再也不画。#298 的修法是在每个边界重置一份清单(`resetPhaseUi`:每次读取开头、`enterGenerating` 里),不变式靠构造点打补丁维持:新加的阶段状态得记得登记进清单,忘了就是用户看得见又难查的泄漏。

**现在**:状态放在哪里就归谁所有,边界的 teardown 是全量的。

### 8.1 阶段与合法边

`Phase = enum { idle, input, generating }`。一个阶段实例 = 一次输入读取(`input`)或一次回复/回复前的等待(`generating`);两次之间是 `idle`(固定区不在屏上,没有任何 widget)。

```
          beginInput                  enterGenerating
  idle ─────────────▶ input   idle ─────────────────▶ generating
   ▲   endInput(读取结束)│     ▲  leaveGenerating          │
   └────────────────────┘     └──────────────────────────┘
```

合法边只有 idle↔input、idle↔generating(`ui_state.transitionAllowed`;idle→idle 是幂等收尾)。每个交互阶段都先回到 idle 再开下一个,所以 teardown 点就是这四处入口。Debug 构建在 `UiState.enter` 里对不经 idle 的边 `panic`——那意味着某个阶段没被关闭就开了下一个(ReleaseSafe 不检查,不拿用户会话冒险)。

### 8.2 phase_change 事件与集中 teardown

- 唯一写 `UiState.phase` 的地方是 `UiState.enter(entry)`,经 `ui.dispatch(.{ .phase_change = entry })` 调到;Renderer 的 `changePhaseLocked` 是它在 IO 侧的唯一调用点(`beginInput`/`endInput`/`enterGenerating`/`leaveGenerating`)。
- `PhaseEntry = union(Phase)` 只带边界上合法知道的参数:`input{ slash_catalog }`、`generating{ verb, start_ms }`。旧阶段的任何东西都不在其中——payload 整体替换,旧阶段打开的东西没有一条路能活过边界。
- 阶段外到达的事件:按键与 `editor_view` 在 idle 时无处可去(返回空 Effect);工具事件(`add/clear_tool_card`、`tool_progress`、`set/clear_current_tool`)与 `spinner_tick` 在生成期以外被丢弃且不要求重画——它们的拥有者已经结束,丢弃就是 teardown。
- Renderer 不再另存 `generating: bool`、`input_view`/`gen_view` 等阶段态副本:生成期 ⟺ `ui.phase == .generating`(`inGeneration()`),输入框内容就是当前阶段 `Interaction.editor`。

### 8.3 归属表

| 状态 | 拥有者 | 进入阶段时 | 说明 |
|------|--------|-----------|------|
| cols / rows | 会话 | 保留 | 终端几何 |
| footer | 会话 | 保留 | usage/mode 快照 |
| panel.task_list_visible | 会话 | 保留 | Ctrl+T 偏好,两期共用 |
| agent_count | 会话 | 保留 | registry 镜像,render 回写 |
| Interaction.editor | input / generating | 清空 | 输入期借用 readLineRaw 的 LineEditor 缓冲;生成期借用 region 的副本 `gen_editor`(§9.2),草稿本体是这一轮 TuiBackend 的 `draft`——权限/提问对话框会停掉再重启 watcher 线程,草稿归 backend 才能跨过这次重启(以前归 watcher,对话框一关缓冲就被释放,框里读到已释放内存、下一个键丢掉草稿)。回复结束时没发出的草稿连同光标交给 `loop.zig` 的 `unsent_draft`,由下一次读输入或排队消息起的下一个回复接过(#756);空草稿和读输入的缓冲在阶段结束时释放 |
| Interaction.help_open | input / generating | 关 | `?` 帮助 |
| Interaction.ctrl_x_armed | input / generating | 清 | Ctrl+X 前缀 |
| Interaction.agents | input / generating | closed | switcher list/viewing、sel、viewing_id、视口 |
| Interaction.picker_open | input / generating | 关 | 唯一跨边界的 widget:**只**经 `app.pending_overlay = .model_picker_kept` 显式交接(#220)——`leaveGenerationRegion`、`endInputRegion` 在阶段结束前记下,下一阶段 `picker_host.keep` 兑现 |
| InputPhase.slash_catalog | input | entry 参数 | 借用本次读取的 arena;读取结束随 payload 消失(以前靠 defer 里手动改回 `.builtin`) |
| InputPhase.slash_sel | input | 0 | `/`、`/model`、`/models`、`@` 菜单选中项 |
| InputPhase.paste_hint | input | 关 | `Ctrl+Y to paste deleted text` |
| InputPhase.press | input | 未武装 | Ctrl+C/Ctrl+D/Esc 双击窗口 |
| InputPhase.menu_dismissal | input | 无 | Esc 关掉的建议菜单 |
| GeneratingPhase.spinner | generating | entry 参数 | verb/start_ms 由 enterGenerating 给,frame 从 0 |
| GeneratingPhase.tools | generating | 空 | 当前工具 + 进度卡 |

删掉的死字段:`UiState.hint`、`UiState.prompt`(声明后从未接线)。

### 8.4 编译期与运行期的检查

- **编译期**:`UiState` 的每个顶层字段必须出现在 `UiState.session_owned`(附原因),否则 `@compileError`——阶段内的状态应该放进阶段 payload,而不是悄悄加成会话状态。payload(`Interaction`/`InputPhase`/`GeneratingPhase`)的每个字段必须有默认值,进入阶段才能整份重建。
- **运行期**:Debug 的非法边 panic(§8.1);直接访问非活跃 payload(`ui.phase.input.…` 在生成期)由 Zig 的 union 安全检查在 Debug/ReleaseSafe 里当场失败。常规代码走返回 optional 的访问器(`interaction()`、`inputPhase()`、`generatingPhase()`)。

### 8.5 加一个新 widget

放进它所属阶段的 payload(两期都有就放 `Interaction`),给默认值,完。不用登记任何 reset 列表;它会在阶段结束时随 payload 消失。真要跨阶段存活的,要么是会话状态(加进 `session_owned` 写清理由),要么像 picker 一样走显式交接——不能靠"没人重置它"活下来。

### 8.6 验证

#298 的回归由 parity 测试守住(用例名以 "#298 parity" 开头):`render_region.zig` 的 "#298 parity" 两组用例重放 回复→读取、读取→回复、读取→读取 三种边界(含"agent 列表不吞下一次提示的输入"),`apps/cli/tests/component/ui_state_test.zig` 覆盖 teardown 全量性、会话状态保留、合法边、阶段外事件丢弃;TTY 套件的 #220 picker 用例(`test_model_picker.py`)守显式交接。

## §9 生成期重画合并窗口(#328,2026-10-28)

**问题**:生成期没有帧合并。每个 tool_progress、每个 spinner tick、每一行流式文本(markdown 路径逐行 `emitToScroll`:一个 chunk 里 N 行就是 N 次"擦区→写行→重画区")、生成期的每个按键,都各自是一个完整帧。每帧都包在 DEC 2026 同步输出里,所以不会撕裂;代价是字节量和终端的解析负担,以及 spinner、进度、文本在同一把锁上互相挤。

**做法**(`tui/frame_scheduler.zig` 纯逻辑 + `RenderRegion` 一个绘制入口):

- **dispatch 不变**:事件 → UiState 仍在事件线程锁内同步完成(工具卡、spinner、输入框、行缓冲/markdown 状态立刻是新的)。只有**写终端**被调度。
- **普通通道**:请求时若上一帧已过一个窗口(16 ms)→ 当场画(孤立事件零额外延迟——孤立的 tool progress 仍与以前一样在到达的那次调用里上屏);否则挂一个待画帧,在"上一帧 + 16 ms"由定时线程画。窗口内的请求全部搭这一帧:画的是到点那一刻的 UiState(latest wins),中间态从不上屏;scrollback 文本攒在 `pending_scroll` 里**按序全部**写出(文本只合并、不丢)。普通通道:spinner tick、tool progress、流式文本、生成期打字回显、dispatch 的键盘重画。
- **立即通道**:当场画,攒着的一并画掉,窗口从这一帧重新算——提交入队(Enter)、工具完成(`tool_result` → `flushGen`)、中断(Esc/Ctrl+C)、`stream_done`(`endScrollLine`)、权限模式/picker/杀后台、阶段与独占 overlay 边界(enter/leaveGenerating、enterExclusiveOverlay/exit)。通道由事件来源调用的入口决定(dispatch 只说"要重画");以前 dispatch 给 tool_progress 标的 `Effect.immediate` 声明后从没被读过,已删除。
- **唯一的绘制入口** `paintLocked`:擦区 → 封口 → 按序写出攒下的文本 → 需要时重画区,一次 flush、区在屏时一个同步帧。以前 `emitToScroll`/`redrawFrameLocked`/`endScrollLine` 各写一份;`endScrollLine` 的擦区/换行/重画曾是三次 flush,现在一帧。
- **定时线程**:会话 region 由 loop.zig `enableMergeWindow` 打开;第一次推迟时惰性起线程,条件变量等到期,持 region 锁画,deinit 时 join。起不了线程就关掉合并窗口退回当场画。默认(测试、`/agent-churn-test` 的临时 region)不开:每个请求当场画,行为与以前相同(有意的两处变化:`endScrollLine` 合成一帧;区不在屏时 resize 封口的换行只写一次)。

### 9.1 为什么 tool progress 进普通通道,以及它的保证

`setToolProgress` 的立即重画是 9016b64a 加的:WebSearch 的结果块在子请求的流末尾到达,`Found N results`、流结束、工具完成、完成态覆盖全在一个 100 ms tick 里发生,`Found N` 那帧从没画出来。要的不是"每个进度一帧",而是"进度在被覆盖前至少画出一帧"。合并窗口保住这一点:孤立的进度当场画;窗口内同一张卡接连的进度合并成最新那条(被后来者覆盖的 `Searching: q` 这类中间态允许丢);卡**被移除前**(`clearToolCard`)先画掉还在等的那帧,所以 `Found N` 不会一帧都没画就随卡消失。

### 9.2 竞态

- **shutdown**:leaveGenerating 先把攒下的写出(区擦掉不重画),再回 idle、重置调度器;定时线程醒来无事可做。region deinit 停线程并 join。
- **resize**:每一帧开头 `observeResize`;待画帧到点时按终端当时的尺寸量,续接点作废/封口逻辑与以前同一处。
- **spinner tick**:就是普通请求;tick 与其它请求同窗口时合成一帧(spinner 帧号照样每 tick 前进)。
- **overlay/对话框**:enterExclusiveOverlay 先写出攒着的文本再擦区,overlay 期间持锁,定时线程等锁。
- **借用**:生成期输入框不再借用草稿(TuiBackend 的 `draft`)的缓冲(下一个键会重分配它,而区可能先被别的线程画),改为 region 自有副本 `gen_editor`。
- 修掉的旧问题:区不在屏时 resize 封口的换行曾写出两次(`sealResizedLine` 自己 flush 后 scratch 未清)。
- **panic**:合并窗口最多压着一个窗口(~16 ms)已发出、还没写到终端的文本,而它们常常正是 panic 前最后发生的事。没有钩子时它们要么随进程丢掉(abort 得快),要么更糟:实测 Debug 构建(WSL pty,临时加的 panic 触发点)里默认 handler 打调用栈期间定时线程照常到点画帧——panic 信息打在固定区中间,按过时的锚点擦掉一段调用栈,再把攒着的行和整个区画在调用栈下面。根 panic handler(`main.zig`)先调 `render_region.flushPendingOnPanic`:拿得到 region 锁(`tryLock`,不等)就画一个 `.hidden` 帧——擦区、按序写出攒着的文本、不再画区——然后**不放锁**交给默认 handler 打印信息与调用栈,别的线程不会再画区盖住它(同一实测:攒着的行按序在前,区擦掉,panic 信息与完整调用栈在下面)。钩子里**不分配**:panic 可能正来自分配器(Zig 的 DebugAllocator 持着自己的锁报 invalid free / double free),这时让帧缓冲扩容会永远等那把锁,崩溃变成挂死;擦除字节拼在栈上的固定缓冲里,攒着的文本原样写出。擦之前先量一次终端(与每一帧开头同一步 `observeResize`:一次 ioctl / 控制台查询,不分配,量不到沿用旧值):最后一个窗口里 resize 过,climb 就按现在的宽度数行,否则按旧宽度画的区行重排后会留在 panic 信息上面;过时的半行续接列一并作废、按帧的规矩封口。这条路径上若再 panic,默认 handler 只报 panic 期间又 panic,原信息就丢了,所以它只做 tryLock、量尺寸、拼固定字节、写。锁被占着(panic 的正是持锁画帧的线程,或者别的线程正画到一半)就放弃:那一刻帧状态不可信,宁可丢最后一个窗口的文本也不把屏幕写乱。仍会丢的:持锁时的 panic、外部信号杀进程(SIGKILL、终端关闭)时的那一窗口。会话 region 由 `enableMergeWindow` 登记、deinit 注销;测试与 `/agent-churn-test` 的 region 不登记。
- **picker**:picker 的写者只有一个线程——跑本阶段按键循环的那个(输入循环,或回复期的键盘 watcher);别的线程画的帧(回复期 agent 线程的文本帧、合并窗口的定时线程)只读它。以前 picker_host 不持锁写 `app.model_picker` 与 `picker_open`,而 picker 开着时刷新目录(`poll` 里登录成功、`apply` 遇 `.conflict` 重载)的 `adopt` 先 `clearRetainingCapacity` 再 `appendSlice`(可能换缓冲、原地覆盖条目),正在画的帧还拿上一份的分组行去索引 `offers.items[group.offer_index]`:安全构建里是越界 panic,否则是撕裂的标签或读到已释放的内存。问题从 #220(回复中能开 picker)就有,#328 多了定时线程这个读者。现在 picker_host 的每个入口带一个 `Guard`(region 锁,`RenderRegion.lockUi`):IO 与计算在锁外——列目录(`App.listModelOffers`,可能先建 provider host)、提交路由、登录 worker、起浏览器、join 登录线程;锁内只有内存里的修改——`adopt`/`markFailed`(`publishListing`)、状态机的一步 `onKey`、`setCredentialLines`、notice、凭据阶段切换、`picker_open`。每次持锁是微秒级的内存操作,里面不拿别的锁、不回调 region,所以不卡帧、不引入锁序。写者自己的读不加锁(只有它写)。输入期之外刷新 picker 的调用(`adoptModelCatalogRefresh` 等)都在主线程、两个阶段之间,没有并发的帧。

### 9.3 测量

WSL Ubuntu 22.04 的 POSIX pty(字节即 metacodes 写出的字节),Debug 构建,终端 30×100,离线 slow mock server;每个场景 3 次取中位数,统计从启动到回到空闲提示符的整段输出。"前"=#330 提交(fb6b2c13),"后"=本节改动,二者只差合并窗口。帧 = DEC 2026 同步帧(`ESC[?2026h`)个数。

| 场景 | 帧 前 → 后 | 字节 前 → 后 |
|------|-----------|-------------|
| markdown 突发:40 个 delta、每个 4 行、间隔 10 ms(160 行) | 174 → 36(−79%) | 149,902 → 34,120(−77%) |
| 回复中粘贴/IME 突发:80 键一次写入,4 s 回复 | 127 → 48(−62%) | 113,899 → 44,264(−61%) |
| token 流:300 个 delta 间隔 5 ms,约 60 ms 一行 | 50 → 49 | 44,190 → 43,277 |
| 只有 spinner:首字节前静默 3 s | 37 → 37 | 31,472 → 31,504 |
| WebSearch:进度 + 完成(3 个 turn) | 22 → 24 | 19,389 → 21,012 |

读法:窗口只合并真正挤在 16 ms 内的请求。行间隔大于窗口的 token 流、10 Hz 的 spinner 本来就不挤,不变;WebSearch 多出的 2 帧是工具完成的立即帧和卡离场前的那一帧(前者让完成即时上屏,后者守 `Found N`)。逐键等回显的打字(驱动等上一键的回显才发下一键)仍是一键一帧,同一窗口里第二个键起的回显最多晚 16 ms。测量脚本与原始数据不入库(会话 scratchpad),断言版本在 `tests/tty/cases/test_redraw_coalesce.py`:突发流帧数 < 行数/2,突发打字帧数 < 键数/2——对 #330 的二进制这两条都失败(174 帧/160 行、57 帧/54 键),对本改动通过。

### 9.4 验证

- **逻辑**:`frame_scheduler.zig` 的假时钟单测(窗口、期限、立即通道满足待画帧)。
- **终端所见**(vterm oracle):`apps/cli/tests/component/redraw_window_contract_test.zig` 断言突发一帧写完、resize 时待画帧按新宽度排、`endScrollLine` 一个闭合帧、panic 钩子写出攒着的文本(以及锁被占时不动、region 释放后不再找它、整条路径不经分配器:区的分配器换成计数探针,攒下远超一帧的文本,钩子跑完计数为 0;窗口内终端变窄后 panic,区按新宽度擦干净、重排与截断两种终端都不留区行);`render_region_contract_test.zig` 的全部合约(emit/erase 配对、半行续接、阶段交接、严格自动换行、footer 截断)在合并窗口关、开两种模式下各跑一遍——开窗口时 harness 用假时钟,时钟只在有待画帧时走到它的期限,所以画完一帧后的每个请求都落在窗口里、等下一次 `sync` 画出合并帧;emit/erase 配对那条还断言请求当时没写终端、窗口内一行加一次 tick 只出一帧。`apps/cli/tests/component/picker_frame_race_test.zig`:定时线程那样的帧(`tickSpinner` 画开着的 picker)与目录刷新(全量与只剩一条交替 `publishListing`)并发;picker 写入在别的线程持 region 锁画帧时等着,帧画完才落下。
- **真二进制**:`tests/tty/cases/test_redraw_coalesce.py`。WebSearch 用例让 `Searching` 与 `Found 1 result` 两次进度在同一次写入里到达,所以结果行一定落在某个窗口里、卡离场时还在等,只有 `clearToolCard` 离场前画的那一帧能把它画出来;去掉那一帧,这条用例失败。
