# TUI_STATE_ARCHITECTURE — cc-zig TUI 状态驱动架构(UiState + Event + dispatch + 纯函数 render)

> 来源:2026-06-05 session。用户连续指出 cc-zig TUI 的架构病根(Ctrl+O 是旁路非视图、状态流转无法测试、加 CC 功能靠散点硬接线),决策做**状态驱动架构重构**。本文是目标架构设计 + 分阶段迁移计划。
> 关联设计文档:[UI_DECOUPLE_BACKEND_FRAMEWORK](UI_DECOUPLE_BACKEND_FRAMEWORK.md)、[CORE_REFERENCE](CORE_REFERENCE.md)。早期 TUI 设计稿(TUI_DESIGN、UI_LAYER_DESIGN、TUI_ALIGNMENT 等)已随过程文档清理移出仓库,见 git 历史。
> 状态:设计稿(2026-06-05),供逐阶段实施依据。

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
- 几何:cols/rows(resize 改)
- 决策面:phase(input/generating)、overlay(none/help/transcript)
- editor:view/cursor(LineEditor 的**投影** borrow,LineEditor 本体不并入)
- spinner:frame/verb/start_ms(elapsed=now-start,now 注入)
- tools:current(定长)+ cards[]( MAX 6,定长拷贝防跨线程撕裂)
- footer:mode/total_tokens/cost/bg_count/cron_count(快照,收口跨线程裸读)
- panel:task_list_visible 等 toggle 位
- transcript_top(Ctrl+O 滚动)、hint(瞬时提示)
- **不进 UiState**:prev_rows/region_drawn/cursor_in_region_row/mutex/line_buf/pending 快照——属 Renderer(是"上一帧物理痕迹",非逻辑状态)。

### render 的大数据靠注入(纯函数)
`RenderInputs{ state, now_ms, theme, use_unicode, agent_snaps[], tasks?, queue_preview[], transcript_lines[] }`——时间注入、大数据只读借用,不拷进 UiState。测试传空/mock 即可。

### Event union + Effect
- Event:key/tool_progress/text_chunk/spinner_tick/resize/usage/job_progress/set_current_tool/add_tool_card/clear_tool_card/phase_change/editor_view
- Effect(dispatch 返回):redraw_region:bool / emit_scroll:?[]u8(文本进 scrollback)/ immediate:bool(工具进度快速路径,当帧画)/ action:?LoopAction(非渲染语义上抛主循环,如 commit/cancel/pass_to_editor)
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

1. **dispatch 状态转移**(纯 state):`dispatch(空editor,'?')→overlay==help`;`dispatch(ctrl_o)→overlay main↔transcript 切换`(**Ctrl+O 现可纯单测,现状只能 pty**);spinner_tick 推进帧;tool_progress→Effect.immediate。
2. **render 帧内容**(CaptureWriter+stripAnsi):`render(overlay=help) 含 Ctrl+O/Shift+Tab`;`render(input) 不含 \x1b[2J`(不碰 scrollback);`render(spinner,now_ms=3000) 含 "(3s"`(时间注入→确定)。
3. **全链路 事件→状态→帧**(不起终端/不连模型):送 `?`→render 出 help 帧→送任意键→render 回输入帧。
挂 tests/component/ui_state_test.zig + ui_render_test.zig,经 main.zig 导出 tui_ui_state/tui_ui/tui_event。pty 测只留机制断言(光标/erase 不破 scrollback/resize),内容断言全下沉。

## §3 线程模型(保留并发,mutex 直接 dispatch,不引队列)

权衡:队列方案最干净但与"tool progress 必须当帧渲染"低延迟冲突 + 改动大风险高 → **选 mutex 直接 dispatch**(贴现状)。UiState 由 Renderer mutex 保护(锁归 Renderer)。
- 各事件源在自己线程 `renderer.applyEvent(in, ev)`:锁内 dispatch→据 Effect erase+draw。
- 工具进度立即重画:Effect.immediate → 同锁内同步执行(等价现状 setToolProgress,延迟=拿锁时间)。
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
