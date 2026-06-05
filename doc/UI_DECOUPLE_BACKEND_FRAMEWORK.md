# UI 解耦框架:UiBackend vtable + CoreEvent 协议

> 状态:已实现(2026-06-05,commit acb21c4)。阶段 A–E 全部落地。
> 关联:[[TUI_STATE_ARCHITECTURE]](状态驱动渲染,本框架的下游消费者之一)、
> [[PERF_MEMORY_PRINCIPLES]](热路径零堆分配约束)、[[TUI_ALIGNMENT_CC]](TUI 表现层对齐)。

## 1. 动机

把 **TUI / agent_loop / loop 机制解耦**,通过统一机制通信(输出/输入/定期激活),
以便在 TUI 之外再接 **GUI / 语音 / 跨进程**前端。

**改造前**:`agent_loop.run` 用 `stdout_writer: anytype` + comptime `@hasDecl` 探测方法
(print/setCurrentTool/addToolCard/setToolProgress/…)——半个鸭子类型接口。差距:
① 不是显式契约(GUI 要照隐式方法集猜);② 颜色转义和工具卡都在 agent_loop 内预渲染、
经 print 输出,表达层和逻辑层耦合;③ 输入端(watcher 键盘)写死在 loop.zig,GUI/语音无处接。

**改造后**:agent_loop **只发语义 CoreEvent**,所有表达(ANSI 颜色 / 工具卡渲染 / 键盘输入)
下沉到 backend。接新前端 = 新增一个 UiBackend 实现,agent_loop 和 loop 编排层一行不改。

## 2. 目标架构

```
agent_loop(纯逻辑,0 依赖 UI 实现)
   │ ↓ CoreEvent (text_chunk/stream_begin/tool_start/set_current_tool/tool_progress/
   │             clear_current_tool/tool_result/usage/auto_compact/retry_notice/stream_done)
   │ ↑ UiEvent   (interrupt / queue_message)
[UiBackend vtable 接口]  ← 显式契约
   ├─ TuiBackend     ── 终端渲染 + owns 生成期键盘 watcher + spinner tick
   ├─ WriterBackend  ── print-only sink(headless/subagent/cron/job buffer)
   ├─ HeadlessBackend── CoreEvent → JSON 行(机器消费 / 跨进程隧道)
   └─ (未来) GuiBackend / VoiceBackend / WsBackend
```

## 3. 核心设计原则

### 3.1 协议是逻辑层,传输是实现层(可序列化硬约束)

`CoreEvent`/`UiEvent` 必须**可 JSON 序列化**:字段全是值类型/slice,无裸指针、无函数指针、
无共享内存依赖。这样**同一套协议**:
- **进程内**:vtable `backend.emit(CoreEvent)` 直传(零序列化,TUI 现用)。
- **进程外(未来)**:`WsBackend.emit = ws.send(json(CoreEvent))`;`poll = parse(ws.recv())→UiEvent`。
  core 进程化 + 加 WsBackend 实现即跨进程,agent_loop/loop 不改(对齐 Claude Code SSETransport:
  本地进程内直调、远程隧道,同一消息协议)。

含义:emit 消费 CoreEvent 时,**backend 实现决定**"直接渲染(TUI)"还是"序列化发出(WS)"。

### 3.2 表达层归 backend,逻辑层只发语义

agent_loop **不碰**任何 ANSI 字节或工具卡渲染:
- 颜色括号:`emit(.stream_begin)` / `emit(.stream_done)` → backend 决定是否 `\x1b[32m`…`\x1b[0m`。
- 工具卡:`emit(.tool_start{name,input,card})` / `emit(.tool_result{...,content,elapsed_ms})`
  → TuiBackend 内部调 `tool_card.renderStart/renderResult` 渲染;WriterBackend no-op;
  HeadlessBackend 转 JSON。
- `text_chunk` 只承载**纯 assistant 文本**(不含 ANSI)。

判定门控(`showStartCard`/`hasProgressCard` 等纯分类器)留在 agent_loop;只把**渲染**移走。

### 3.3 slice 是 borrow,emit 同步消费

CoreEvent 携带的 text/id/name 是借用切片,emit **必须同步消费**(TuiBackend.emit 立即拷进
定长卡 / 写 scrollback,不持有跨调用)。生命周期由 producer(agent_loop)保证在 emit 返回前有效。

### 3.4 中断机制不走 vtable(AbortSignal 保持原语)

**关键反模式规避**:不要让 `backend.poll()` 取代 AbortSignal 做中断。原因:
- **SIGINT handler(Ctrl+C)**signal-safe 只能 atomic store,**走不了 vtable**(分配/加锁/IO 都禁)。
- **动中断点在 `stream.next()` 的逐行读循环里**(`throwIfAborted` 每读一行查 AbortSignal),
  agent_loop 的轮间检查点根本到不了那里,且 API 层不该认识 UiBackend(层次错)。

→ `poll-as-interrupt` 会与 AbortSignal **双轨冗余 + 引入新时序窗口**(高风险)。
**正确做法**:AbortSignal 仍是中断原语(SIGINT handler + watcher esc 都直戳它,
stream.next 仍 throwIfAborted);backend 的输入端(watcher)收到 esc 时**也直戳 AbortSignal**。
`poll()` 只用于轮间拉取 queue_message 这类非紧急事件,不承担动中断。

### 3.5 输入采集归 backend,但中断原语共享

生成期键盘 watcher(读 stdin、回车入队、esc 中断、超时 tickSpinner)是 **TUI 专属**,
归 TuiBackend(`startInput`/`stopInput`),loop.zig 不再硬编码。GUI/语音后端各自实现 startInput
(GUI=窗口事件,语音=STT),无 stdin 线程。但 AbortSignal/MsgQueue 仍是 backend↔loop 的共享通道。

### 3.6 定期激活(tick)归 backend,单线程 poll-timeout

spinner tick 不另起线程:在 watcher 的 **poll 超时分支**驱动(100ms 超时既当 tick 又当键盘读)。
**反模式规避**:独立 tick timer 线程会让两个线程都争 RenderRegion 锁,纯增风险零收益。
GUI/语音后端各自决定 tick(GUI=requestAnimationFrame,语音=无 tick)。

### 3.7 多 writer 塌缩成一个 vtable

改造前有 5 种 writer(RegionWriter 全方法集 + DebugWriter/SilentWriter/NullWriter/SinkWriter
仅 print)。只有 RegionWriter 需要富方法集;其余 4 个区别仅在字节去向(std.debug.print/丢弃/
丢弃/追加 buffer)→ 塌缩成一个 **WriterBackend**(参数化 sink fn-ptr)。结果:二进制**反而变小**
(消除了 anytype 单态化的多份 agent_loop.run + 4 个 writer struct)。

## 4. 协议定义

### CoreEvent(core→UI)

| 变体 | 语义 | TuiBackend 映射 |
|---|---|---|
| `stream_begin` | 一轮流式开始 | colorize ? writeGenText("\x1b[32m") |
| `text_chunk: []const u8` | 纯 assistant 文本 | writeGenText(t) |
| `tool_start{id,name,input,card}` | 工具开始 | card ? addToolCard : (verbose 行 + renderStart→scrollback) |
| `set_current_tool{name}` | 喂底部 spinner | setCurrentTool |
| `tool_progress{id,text}` | 执行中进度刷新 | setToolProgress |
| `clear_current_tool` | 清 spinner | clearCurrentTool |
| `tool_result{id,name,input,content,is_error,card,elapsed_ms}` | 工具完成 | card ? clearToolCard : renderResult→scrollback |
| `usage: UsageDelta` | token 计数 | 累加 usage_acc(主路径 null,走 usage_sink) |
| `auto_compact{dropped,kept}` | 历史压缩提示 | writeGenText(格式化行) |
| `retry_notice{attempt,max,delay_ms}` | 建连重试提示 | 门控(show_retry/attempt≥3)+ writeGenText |
| `stream_done` | 一轮结束 | writeGenText(colorize ? "\x1b[0m\n" : "\n") |

### UiEvent(UI→core)

| 变体 | 语义 | 所有权 |
|---|---|---|
| `interrupt: AbortReason` | 打断当前任务 | 无所有权 |
| `queue_message: []const u8` | 生成期入队消息 | poll 调用方拥有,须 free |

### UiBackend vtable

```zig
pub const UiBackend = struct {
    ctx: *anyopaque,
    emit: *const fn (ctx: *anyopaque, ev: CoreEvent) void,  // core→UI,同步消费 borrow slice
    poll: *const fn (ctx: *anyopaque) ?UiEvent,             // UI→core,非阻塞
    // 便利:emitEvent / pollEvent
};
```

`tick` 不进 vtable —— UI 后端自己起 tick(TuiBackend=watcher poll 超时,GUI=raf)。

## 5. 关键文件

- `src/repl/ui_event.zig` —— CoreEvent / UiEvent
- `src/repl/ui_backend.zig` —— UiBackend vtable
- `src/repl/tui/tui_backend.zig` —— TuiBackend(渲染 + 键盘 + tick)
- `src/core/writer_backend.zig` —— WriterBackend(print-only sink)
- `src/core/headless_backend.zig` —— HeadlessBackend(JSON 行)
- `src/core/agent_loop.zig` —— `run(... backend: *const UiBackend ...)`,只发 CoreEvent
- `src/repl/loop.zig` —— 编排:构造 backend、startInput/stopInput

## 6. 可测试性(本框架最大收益之一)

CoreEvent/UiEvent/UiBackend 纯数据 + 函数指针,不碰 fd。因此:
- **mock backend**(收 CoreEvent 进 ArrayList)→ 跑一轮真 agent_loop(MockServer cassette)→
  断言事件序列。**agent_loop 现在能不起终端、用 mock backend 纯测**。
- **字节锁单测**:喂每个 CoreEvent 给 backend,断言输出 == legacy 串常量(重构时锁死字节精确)。
- 见 `tests/component/ui_backend_test.zig`(字节锁)、`tests/component/ui_multifrontend_test.zig`
  (mock backend 跑 agent_loop + HeadlessBackend JSON 全链)。

## 7. 工程方法论沉淀(本次落地总结)

- **分阶段渐进,每阶段编译+测试绿**:A 定义协议 + 适配器(零接线)→ B agent_loop 改用 backend
  (原子切换,B0 字节锁单测先行)→ C 输入端解耦 → D tick → E 多前端验证。每阶段独立可回退。
- **字节精确验证靠 pty 测试断言粒度**:pty 测试若 strip ANSI 后只验可见 prose、且只验着色
  存在性(非逐字节位置),则把渲染移入 backend 安全。重构前看清测试断言粒度。
- **真假 bug 靠 git stash 基线对照**:真模型 e2e 偶发失败时,stash 全部改动回基线 commit 重测,
  仍失败 = 预存 flaky 非回归。证据链而非推理链。
- **拒绝照文档字面做**:plan 字面要 agent_loop.poll 消费 interrupt,核实后发现会造成
  signal-unsafe vtable 调用 + 双轨中断 → 否决,选"watcher 归 backend、AbortSignal 不动"。
  少写代码、不碰已验证可靠的原语,也是工程能力。
- **共享可变缓冲是坑**:backend 上挂 `line_buf` struct 字段被多分支复用 → 改栈局部
  (`var buf: [256]u8`),物理上消除跨线程撕缓冲的可能,而非靠"恰好只有主线程写"的隐式不变量。
