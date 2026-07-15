# U4: 配置变更事件族设计

> 状态：设计草案，待 Linus boundary review 后实现。
> 依赖：U2（SessionService/App 方法 = mutation choke point，已完成）、U3（syncModelMirrors model 单写侧）。
> 解锁：多 UI 一致性（附着同一 session 的 TUI+web 状态同步）；U5 附着协议的事件流。

## 0. 问题

多 UI 附着同一 session 时，任一状态变更必须广播，否则其它 UI 陈旧。现状：config 变更（/model /mode /theme…）只 mutate，无事件出口（App 命令处理在生成期之外，手里没 backend）。

## 1. 事件变体（CoreEvent 扩展）

CoreEvent（`core/protocol/ui_event.zig`）加 config-change 族：
```zig
config_changed: ConfigChange,  // 单变体裹 union，避免 CoreEvent 膨胀 6 个
pub const ConfigChange = union(enum) {
    model: []const u8,          // 新 model(emit 侧 dup owned；见 §4 生命周期)
    mode: PermissionMode,       // 值语义
    dirs: []const u8,           // 新增目录(**dup owned**，借瞬态 arg 会悬挂——Linus S3 flag)
    theme: Variant,             // 值语义
    vim: bool,                  // 值语义
    reasoning: ?ReasoningEffort,// 值语义
};
```
**phase_change 死变体处置**：grep 确认零生产者（三 backend 全 no-op 消费）。U4 一并删除（要么真发要么删，别留假信号）——它本是 loop 编排的相位，不走事件。

## 2. event_sink：所有权 + 生命周期（Linus guardrail）

- **App 持有** `?ConfigEventSink`（非借生成期 backend——那是 per-run 栈对象，config 变更在 run 外）。
- Sink 生命周期 = session（driver 装配时设，deinit 时清）。
```zig
pub const ConfigEventSink = struct {
    ctx: *anyopaque,
    emitFn: *const fn (ctx: *anyopaque, ev: ConfigChange) void,
    pub fn emit(self: ConfigEventSink, ev: ConfigChange) void { self.emitFn(self.ctx, ev); }
};
```
- 消费者：TUI sink → 立即重绘 statusline/banner（driver 线程=渲染线程，进程内直连）；web sink → journal.append（journal 已有 mutex+condvar，SSE 线程消费）；headless → 不设 sink（no-op）。

## 3. emit 挂载点：**每个轴挂它的单写侧**（Linus 铁律，非统一放 App 方法）

| 轴 | 单写侧 | emit 点 |
|----|--------|---------|
| model | `App.syncModelMirrors`(U3) | syncModelMirrors 末尾 emit .model=activeModel() |
| **permission_mode** | **`permission_ctx.setMode()`** | 见 §3.1（**不是 App.cyclePermMode**——工具 plan_mode.zig 直写 ctx.setMode 绕过它） |
| add_dirs | `App.addDirectory` | emit .dirs=新增目录(dup) |
| reasoning | `App.setReasoningEffort` | emit .reasoning |
| theme | `App.setTheme` | emit .theme |
| vim | `App.toggleVim` | emit .vim |

**不在 exec/svc 再 emit**（防双发）——键盘触发（Shift+Tab/model-picker 键）也经单写侧 → 也 emit。

### 3.1 permission_mode 的陷阱（scoped 拷贝）——改单 seam（Linus review 修正）

`setMode` 挂在 `PermissionContext`，被 **session-level**（app.permission_ctx：cyclePermMode/
settings 降级/svc.setPermMode/**plan_mode.zig 工具**）和 **scoped 拷贝**（override 用，不动 session 态）共用。
若无脑在 setMode emit → scoped override 也误发。

**"手工 null N 点" 已被证伪**：草案说"3 处"，Linus grep + 我复核实际是——
- **值拷贝**（`= permission_ctx.*` / `perm.*`）：subagent.zig:119、**agent_loop.zig:631(pc_prefetch)**、
  **agent_loop.zig:988(pc_nohooks)**、**agent.zig:163、agent.zig:190** —— 共 **5 处**（草案漏了 4 处！）。
  这些创建**新 PermissionContext**（derived），是要 null sink 的。
- **指针拷贝**（`= p.permission_ctx` / `@constCast(permission_ctx)`）：teammate.zig:563、
  agent_job_registry.zig:443、agent_loop.zig:1066 —— **共享同一 ctx（含 sink）**，语义不同（见下）。

草案的"3 处"清单错了 4 个 → **正是"枚举漏一个"的活证据 → 改单 seam**（同 U3 syncModelMirrors 思想）：

**方案（Linus 定）**：`PermissionContext.scopedDerive(mode_override) → PermissionContext`——**唯一**允许的
值拷贝入口，内部值拷贝 + **null sink**（+ 其它 session-only 字段）。所有 scoped 值拷贝只准走它。
null 逻辑塌成**一处**，不可能漏。
- **grep-guard**：src 里除 scopedDerive 外**无裸 `permission_ctx.*` / `perm.*` 值拷贝**——这条本来就能
  抓出 631/988/163/190（草案手工清单抓不出）。5 处值拷贝全改调 scopedDerive。
- 好处：plan_mode.zig 工具直写 ctx.setMode 自动 emit（无需改工具），正是最该出事件的 plan 转移。

**指针共享 sink 语义（Linus 要显式判）**：teammate/agent_job/agent_loop:1066 用**指针**共享
app.permission_ctx（含 sink）→ 它们的 setMode 会 emit 到 **lead 的 session sink**。
- **裁定（U4）**：**接受**。这些是 pre-existing 的指针共享——background subagent/teammate 本就与 lead
  **共享同一 permission_ctx**（它们改 mode 本就影响 lead 的实际 mode，pre-existing 耦合）。既然 mode 真变了，
  emit 反映真相是**一致**的。实践中 background agent/teammate 极少进 plan（no_interactive_prompt），此路近乎不触发。
- **登记债**：background subagent/teammate 指针共享 lead 的 permission_ctx（mode 变更泄漏到 lead）是
  pre-existing 耦合，理应 derive 独立 ctx，但**超出 U4 scope**，单开条目。U4 不改指针共享行为，只
  如实 emit。

## 4. data 生命周期（Linus S3 flag：跨线程拷贝）

emit 是同步调用（driver 线程），但 sink 可能异步消费（web journal → SSE 线程后读）。故 emit 侧传给 sink 的**借用串必须由 sink 落地时拷贝**，或 emit 侧就 dup：
- `.mode/.theme/.vim/.reasoning`：值语义，安全。
- `.model`：borrow app.activeModel()（App 稳定，但 switchModel 后可能变）→ **emit 侧不 dup，sink 落地时 dup**（web journal.append 本就 dup 进 journal 串；TUI 同步渲染即用即弃）。
- `.dirs`：**借瞬态命令 arg**（非 App 稳定）→ 同上，sink 落地 dup；TUI 同步渲染安全。
- 规则：ConfigChange 借用串**只在 emit 同步窗口有效**；sink 若跨线程留存必须 dup。web sink（journal.append dup）与 TUI sink（同步渲染）都满足。文档化此契约。

## 5. 消费者渲染

- **TUI**：sink 重绘 statusline（model/mode/…）。config 变更本就该反映在状态行。
- **web**：sink → journal.append 一条 `{"config_changed":{...}}` → 浏览器 SSE 收到更新 UI。**与 command_result 分开**（config_changed 是状态广播，任何变更源都发；command_result 是命令 ack）。
- **headless**：无 sink，no-op。

## 6. 分阶段

- **A1**：CoreEvent.config_changed + ConfigChange union；删 phase_change 死变体。
- **A2**：ConfigEventSink 接口 + App/PermissionContext 持有字段 + scoped 拷贝 null sink（+grep-guard 测试）。
- **A3**：6 轴单写侧接 emit（model→syncModelMirrors、mode→setMode、其余→App 方法）。
- **A4**：TUI/web sink 实现 + 装配接线；headless no-op。
- **A5**：测试——每轴 mutation → 断言 sink 收到对应 ConfigChange（含 plan_mode 工具路径 → mode emit）；scoped 拷贝不 emit；web journal 落 config_changed。

## 7. Linus 拍板结论（已定）

1. **单 `config_changed: ConfigChange` union（定）**：内层 exhaustive switch → 将来加轴**编译期强制**所有消费者处理（平铺会被静默忽略），完整性更安全。
2. **scopedDerive 单 seam（定，草案手工 null N 点被证伪——漏了 4 处）**：`PermissionContext.scopedDerive()` 唯一值拷贝入口内部 null sink；grep-guard 查"除 scopedDerive 外无裸 `.*` 值拷贝"。指针共享 sink 语义 = 接受 emit 到 lead（pre-existing 耦合，登记债）。
3. **sink 落地 dup（定）**：与 CoreEvent 现有借用 slice 语义一致；契约写死 ConfigEventSink.emit 注释（借用只在 emit 同步窗口有效）；**A5 必加跨线程留存测试**——web sink emit .model 后再 switchModel(free 旧串)，断言 journal 那条 model 仍旧值不悬挂（证 dup 发生在 emit 内）。别 emit 侧一律 dup。
4. **删 phase_change（定），3 caveat**：① **别误删** TUI 自己的 `repl/tui/event.zig:113 PhaseChangeEvent`（不同类型，只删 CoreEvent.phase_change@ui_event.zig:98）；② 清全消费者（writer_backend.zig:129 / tui_backend.zig:239 no-op case / **web/index.html:171 JS handler** / ui_event.zig:98 声明）；③ 删前确认 web 从没 append 过 phase_change（应=死消费者）。

**A1 实现发现（比"删死变体"更缠）**：CoreEvent.phase_change **无生产者**（仅 ui_backend_test:384 测试 emit），但有**真消费者** `repl/tui/ui.zig:88`（UiState.dispatch 做 spinner/help 重置，prod 不可达=死代码）+ dispatch 测试（ui_state_test:198）。删它要连带清 ui.zig:88 handling + 2 个测试（ui_backend_test:384 emit、ui_state_test:198 dispatch）+ web JS + 2 no-op case。**故 phase_change 删除拆成 A1b 单独小步**（先加 config_changed union=A1a，再删 phase_change=A1b），别混进 union 添加里，减小 diff 面。web 确认：src/web 只 index.html:171 JS 消费，无 journal.append phase_change（死消费者，删 JS 安全）。

## 8. 分阶段（S4 grep-guard 落地）
A2/A3 Linus 重点审（sink 接口 + scoped seam + mode→setMode emit）；grep-guard 必须真抓裸 `.*` 拷贝。
