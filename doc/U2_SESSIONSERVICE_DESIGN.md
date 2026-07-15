# U2: SessionService 抽取 — 中立命令面设计

> 状态: 设计草案，待 Linus review 接口边界后实现。
> 依赖: U3(已完成，activeModel/syncModelMirrors 单一真理源模式)。解锁: U4(配置变更事件族)、U5(附着协议)。

## 0. 问题（调查实证 explore-commands）

- 命令 dispatch 全内联在 `loop.zig run()` 主循环（无 `handleSlashCommand` 函数），命令识别+状态操作+渲染三者揉在一起。
- `web/session.zig execCommand`(@77) 是**独立第二套实现**，只支持 4 条（/mode /compact /model），与 loop.zig 逐字重复。
- **无统一 CommandResult 类型**：loop.zig handler 一律 void+`std.debug.print`；web 用 `{ok,message}` 字符串，不携带"哪些状态变了"语义 → U4 事件族**无源头**。
- **App 不持 UiBackend 句柄**：backend 每轮生成期栈上临时构造，命令处理在生成期之外 → 配置变更事件无出口。

## 1. 设计原则

1. **只收敛 mutation，不收敛渲染**：SessionService 是所有"改 session 状态"的**唯一 mutation 入口**（对齐 U3 的 syncModelMirrors choke-point 思想）。纯展示命令（/help /tools /skills /doctor /mcp /agents /cost /permissions）**不 mutate，留各 UI 自行渲染**，不进本次 scope。
2. **命令返回结构化 CommandOutcome**：携带 (what-changed 枚举 + 人类可读 message)，渲染归各 UI。web 的 `{ok,message}` 是雏形，升级成带 changed-kind。
3. **web execCommand 整体废弃**，其 4 条命令改调共享命令面。loop.zig mutation 命令同样改调。
4. **CommandOutcome 携带 changed-kind 供 U4 派生事件**（本次不 emit，只结构就位；U4 加 event_sink + emit）。

## 1.5 Scope 声明（Linus review 补：别让"完整"静默 drop）

本表 **只覆盖 config/settings 轴 mutation**（model/mode/dirs/reasoning/theme/vim/compact/skill）。
**会话轴 mutation 显式排除出 U2/U4 config-event scope**，归其它任务：
- `/resume`(loop.zig:402→handleResume)：重载 conversation + 恢复 model/compact boundary → **U5 附着协议 + U8 suspend-resume**。
- `/retry`(loop.zig:368→retryLast)：改 conversation → **U5**（session 生命周期）。
- `/goal`(loop.zig:358→handleGoal)：设 session goal（可能写 tinykg）→ 待核实是否算 session 态；暂归 **U5**。
- `/clear`(loop.zig:229)：**已核实只是 `\x1b[2J\x1b[H` 清屏，不动 conversation → 非 mutation，不列**。

U4 的 config-change 事件族只覆盖本表 config 轴；会话生命周期事件是 U5 的 session_created/loaded/switched。

## 2. 完整 config/settings 轴 mutation 清单 × 收敛去向（Linus guardrail #1）

| # | 状态 | 现状 | file:line | 收敛去向 |
|---|------|------|-----------|---------|
| ① | model | ✅ 单入口 App.switchModel | app.zig:633 | SessionService.setModel → App.switchModel |
| ② | **permission_mode** | ⚠️ **双存储**(config + ctx)手动 sync-back，web 漏 sync 致 /state 陈旧 bug(task#14) | **完整双写点(Linus 补全)**：app.zig:940(cyclePermMode) / **app.zig:1110,1115(settings 禁用 bypass/auto 强制降级 default)** / loop.zig:641-642(sync-back hack) / plan_mode.zig:55,158,165(只写 ctx) | **收敛单一源(选 A，Linus 定)**：ctx.mode 为唯一真理源，config.permission_mode 降级**启动快照**(套 U3 config.model 模式)，运行时读走 `fn permMode()=ctx.modeValue()`(atomic load)。删 loop.zig:641 sync-back。所有上述双写点改只写 ctx。SessionService.setPermMode/cyclePermMode |
| ③ | add_dirs | ✅ 单入口 App.addDirectory (web 缺命令) | app.zig:1228 | SessionService.addDirectory；web 经命令面获得 /add-dir |
| ④ | reasoning_effort | ✅ 单入口 App.setReasoningEffort | app.zig:702 | SessionService.setReasoningEffort |
| ⑤ | **theme** | ⚠️ 无 App 方法，inline 写 + init 各一份 | loop.zig:3029 / app.zig:277 | **先抽 App.setTheme(variant)**，再 SessionService.setTheme |
| ⑥ | **vim_mode** | ⚠️ 无 App 方法，inline flip | loop.zig:437 | **先抽 App.toggleVim()**，再 SessionService.toggleVim |
| ⑦ | **compact** | ⚠️ **真重复**(loop.zig + web 逐字) | loop.zig:354 / session.zig:89 | **抽 App.compactWindow()→{dropped,before,after}** 结构化，两源共用 |
| ⑧ | active_skill | ✅ 单入口 App.activateSkill/clear | app.zig:959,971 | 保持(每 user-msg 前 clear 是 loop 生命周期，非命令；不进命令面) |

**非 mutation（不抽）**：ui_requester 接线(loop.zig:589 / web:154，per-frontend 请求通道，跟 backend 生命周期)；scoped setMode 值拷贝(subagent/teammate override，不动 session 态)。

## 3. 接口签名（草案）

```zig
/// 中立命令面：所有 session 状态 mutation 的唯一入口。持有 *App(借用，App 生命周期 > SessionService)。
/// **不持 backend**——事件出口是 U4 的 event_sink(本设计只把 CommandOutcome 结构就位)。
/// 线程契约:所有方法在 driver 线程调用(TUI run 循环 / web driver 空闲点 popFront)。
/// App arena 非线程安全 → SessionService 方法绝不跨线程调；web 经 cmdbox 交接到 driver 后才调。
pub const SessionService = struct {
    app: *App,

    /// 分派一条命令。verb=已去 `/` 的动词(如 "model")，args=其余(如 "opus")。
    /// 返回结构化结果，渲染归调用方(各 UI)。未知/纯展示命令 → .unhandled(调用方自渲染)。
    pub fn exec(self: *SessionService, verb: []const u8, args: []const u8) !CommandOutcome { ... }

    // 直接 mutation API(exec 内部调；也供非命令触发点如 Shift+Tab/model-picker 键直调)
    pub fn setModel(self: *SessionService, model_id: []const u8) !CommandOutcome { ... }
    pub fn cyclePermMode(self: *SessionService) CommandOutcome { ... }
    pub fn setPermMode(self: *SessionService, mode: PermissionMode) CommandOutcome { ... }
    pub fn addDirectory(self: *SessionService, dir: []const u8) !CommandOutcome { ... }
    pub fn setReasoningEffort(self: *SessionService, effort: ReasoningEffort) CommandOutcome { ... }
    pub fn setTheme(self: *SessionService, variant: ThemeVariant) !CommandOutcome { ... }
    pub fn toggleVim(self: *SessionService) CommandOutcome { ... }
    pub fn compactWindow(self: *SessionService) !CommandOutcome { ... }
};

/// 命令执行结果。changed 携带"哪些状态变了"供 U4 派生事件；message 供 UI 渲染；
/// data 携带命令特定结构化数据(如 compact 的 dropped/before/after，model 的候选列表)。
pub const CommandOutcome = struct {
    kind: Kind,           // 变更类别(U4 据此 emit)
    ok: bool,
    message: []const u8,  // 人类可读(owned by SessionService scratch 或静态)
    data: Data = .none,   // 命令特定结构化载荷

    pub const Kind = enum {
        model_changed, mode_changed, dirs_changed, theme_changed,
        vim_changed, reasoning_changed, compacted,
        unhandled,       // 非本命令面负责(纯展示命令 → UI 自渲染)
        noop,            // 已处理但无状态变更(如 /model 无参回显)
        err,
    };
    pub const Data = union(enum) {
        none,
        compact: struct { dropped: usize, before: usize, after: usize },
        model_list: []const model_command.Candidate,
        // …按需扩展
    };
};
```

## 4. Backend 句柄 / event 线程模型（Linus guardrail #2）

- **U2 不持 backend、不 emit**。SessionService 只 mutate + 返回 CommandOutcome。
- **U4 增量**：SessionService 加 `event_sink: ?EventSink`（**持有**，非借生成期 backend——避免 U3 那种跨线程读写模型串的坑）。mutation 方法在 driver 线程**同步** emit config-change 事件进 sink。
- **生产者单线程**（driver：TUI run 循环 / web driver popFront）。**消费者**走各自 backend 既有线程模型：
  - TUI：进程内直连（driver 线程 = 渲染线程，直接重绘 statusline/banner）。
  - web：emit → journal.append（journal 已有 mutex+condvar，SSE 线程消费），与生成期解耦——**web 已有此范式**。
  - headless：no-op sink。
- **web 陈旧 bug 顺带修**(task#14)：permission_mode 收敛单一源后，web plan 模式切换不再有 config/ctx 两份，/state 读单一源即最新。

## 5. 迁移分阶段（Linus 定序 S2→S1→S3→S4，可增量 commit）

- **S2**（permission_mode 单一源，**先做**）：ctx.mode 为唯一源，config.permission_mode 降启动快照 + `fn permMode()` 派生读；删 loop.zig:641 sync-back；全部双写点(app.zig:940/1110/1115、plan_mode 三处)改只写 ctx。**修 task#14 web 陈旧 bug**。高风险(碰权限决策链)，单独 commit + review。
- **S1**（抽 theme/vim/compact 成 App 方法）：setTheme/toggleVim/compactWindow，loop.zig 内联改调，行为不变。可独立 commit + review。
- **S3**（SessionService + CommandOutcome）：建 SessionService，mutation 命令(model/mode/compact/add-dir/theme/vim/reasoning)迁入 exec；loop.zig dispatch 与 web execCommand 都改调；废弃 web 独立 execCommand。
- **S4**（测试 + grep-guard）：SessionService.exec 的 L2（每条 mutation 命令 → 断言 App 状态变更 + CommandOutcome.kind 正确）；web/loop 双源经同一命令面的一致性测试；**grep-guard：全仓 mutation 写侧除 SessionService/App-seam 外应为 0**（choke point 约定的兜底）。

U4 在 S3 之后接 event_sink（本设计不含），emit 只放 mutation 方法（不在 exec 再 emit，防双发）。

## 7. S3 实现结论（App 方法=真 choke point）

实现时确认：**真正的 mutation 单一入口是 App 方法**（switchModel/cyclePermMode/compactWindow/
addDirectory/setTheme/toggleVim/setReasoningEffort）。loop.zig 富 dispatch（/model 查询解析、
/theme 列变体）与 web（经 svc.exec）**都汇聚到同一批 App 方法**。SessionService 是"命令字符串
路由 façade"给 web/daemon/GUI；TUI 保留自己的富 dispatch 调同一批 App 方法（不强搬进 svc，
否则丢 /model 查询等富功能）。
- **grep-guard PASS**：config.vim_mode/theme/conversation.compact() 写侧各只在对应 App 方法；
  switchModel/cyclePermMode/addDirectory/setReasoningEffort 直调点全在 loop.zig/tui_backend/svc，
  无一绕过 App 方法。不变式"所有 session mutation 汇 App 方法"grep 可验且成立。
- **web 主交付**：execCommand 手抄 4 命令实现整体废弃 → svc.exec；web 白捡 /add-dir /theme /vim
  + /model provider 守卫（旧 web 漏）。
- **U4 emit 放 App 方法**（两 UI 都经过的真 choke point），不放 svc（否则 loop.zig 直调 mutation 不 emit）。

## 6. Linus 拍板结论（已定）

1. **借 *App（定）**。host 层命令路由天然摸 App 多子系统，穿单字段指针只适合叶子 seam。**caveat**：choke point 是**约定非类型强制**，任何拿 *App 的代码仍能绕过 → **S4 必加 grep-guard**：全仓 mutation 写侧除 SessionService/App-seam 外应为 0。
2. **permission_mode 选 A（定）**：ctx.mode 为唯一源 + config 派生读，**套 U3 config.model 模式**（config.permission_mode 降启动快照，运行时 `fn permMode()=ctx.modeValue()`）。B(强制双写)是 task#14 病根，A 让 desync 构造上不可能。caveat：(a) ctx.mode 是 atomic → permMode() 是 atomic load；(b) 核实 permission_mode 是否被持久化(saveDefault 存 model/effort)——若存 mode，派生读要从 ctx 序列化。
3. **message 所有权：不用共享 scratch buffer（定）**。U4 会把 message 随事件跨线程 emit（web SSE 消费）→ 借瞬态 buffer = U3 freed-read/torn-slice 同类。选：固定消息**静态串**，动态消息 **outcome 自持(带 allocator，outcome free)**，emit 带 owned 拷贝。
4. **顺序 S2→S1→S3→S4（定）**：先修 bug(S2 是唯一真 bug task#14)再重构(S1 纯 refactor)；S2 风险最高(碰 U1/B1 加固的决策链)单独隔离早审；S3 的 setPermMode 在单一源之后建才干净(只写 ctx)。

**实现节奏**：S2 与 S3 各审一轮，S2 因碰权限链重点看。
