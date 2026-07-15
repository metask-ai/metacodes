# U5: session 生命周期事件 + 附着协议设计

> 状态：设计草案，待 Linus boundary review 后实现。
> 依赖：U2(SessionService)、U4(config_changed 已进 journal seq 流)。解锁：U10 daemon 多 session 宿主。
> 调查：explore-session-lifecycle（现状实证，见下引用）。

## 0. 现状净账（调查实证）

**已生产就绪（可直接复用）**：EventJournal seq(数组下标)+ `count()`(下一个 seq) + `waitSince(since)` + SSE `?since=N`/`Last-Event-ID` 重放（journal.zig + server.zig:280-311）。**"从 seq 订阅事件流"这半完整**。

**缺的一半（附着 gap 核心）**：`/state` 快照(session.zig:59)**不返回 seq** → 无原子 snapshot↔subscribe 握手。现状能跑是因为客户端 `since=0` 全量重放整条 journal 重建对话——**依赖 journal 无界**（journal.zig:11 MVP）。**U7 环形淘汰一上 `since=0` 即失效**，这正是附着必须 snapshot+seq 的原因。

**全新增量**：session 生命周期事件（session_created/loaded/closed）现无一存在；`session_closed` 只是 SSE 传输帧(server.zig:304)非可重放事件；`/resume`(loop.zig:3509)不发事件、**不改 session_id**(漂移 bug task#16)。

**留 U10**：per-session journal 隔离 + session 路由（现零基础）。

## 1. 附着协议：snapshot + seq 握手（Linus 核心约束 — gap/dup 无缝）

### 1.1 边界一致性不变式（Linus 定，本设计首要约束）

不变式 = **「快照自报它反映到的 seq，客户端订阅严格大于它」**，**不是**「快照冻结在某点」。三步原子关系：
1. **锁内取 seq**（便宜）：snapshot 内 `const seq = journal.count()`（journal 锁内或原子读；count 是"下一个待分配 seq"=已存在事件数）。
2. **锁外读态/序列化**：释放锁后从容读 App 态（态 **≥ seq 反映的点**）+ 序列化。**不持锁跨整个 state 序列化**（否则阻塞所有 emitter 含 driver mutation，快照越大停顿越久）。
3. **信封写死 seq + 客户端订阅 `?since=seq`**：客户端从 seq 起订阅（严格大于快照已吸收的更早事件）。

### 1.2 为什么 gap/dup-free（幂等性论据 + 分层）

- **config 事件是幂等 state-set**（model_changed=set model=X，mode/dirs/reasoning 同理）。故 seq..实际读态点 之间产生的 config 事件，即使既进快照态又被 `since=seq` 重放，客户端**重放=同值再 set 一遍，无害**。这是 config 附着能用「态 ≥seq + 订阅 >seq-1」的根因。
- **非幂等 append 类**（text_chunk/tool_result 进 scrollback）重放会 dup → 靠**每条 journal 行的 seq 去重**（客户端 last-applied seq，忽略 ≤ 已应用）。journal 本就每行带 seq（Last-Event-ID）。
- **两层正交**：① 快照承载**幂等 config/status 态**（用 seq 语义）；② append 重放靠 seq 去重。**字段撕裂**（读新 model + 旧 usage）是第三层，用 U3 值快照 / 接受良性 skew，与 seq 边界正交。

### 1.2.1 **边界规则（Linus 定，防两层串味 — 我审时对着它查快照 payload）**

**快照信封只准装第①类（幂等 config/status 镜像：model/mode/dirs/reasoning/session_id/usage）；
第②类 append 内容（scrollback/text_chunk/tool_result）绝不进快照，只从 >seq 的 journal 流重放。**
两者内容集**不相交**。一旦快照混进 append 内容、客户端又重放 >seq 的同类事件 → dup。
边界 = 「快照 = 幂等态镜像；append = 纯 journal 重放」。**B1 实现后对着快照 payload 查：无 append 类字段。**

### 1.2.2 usage 特例（Linus flag：累加非幂等 set）

usage 是**累加计数**（`CoreEvent.usage` 是 delta），不是幂等 set——若 delta 事件也被重放 apply
会**双算**（快照拍的是当前累计 X，重放 >seq 的 delta 又加一遍）。**现状已避开**（实证）：
- WebBackend.emitThunk（backend.zig:100-111）：usage 事件 → `usage_totals.apply(delta)` 累加进
  app.usage **且** journal.append（usage 行进 journal seq 流）。
- **但客户端（index.html:183）收到 usage 事件只 `refreshStateSoon()`（re-poll /state）——从不 sum delta**，
  始终读 /state 的**权威累计值**。故 usage 是 **poll-based**：快照带当前累计（display baseline），
  usage 事件只当"变了，重新拉 /state"信号。
- **裁定（U5）**：usage 保持 poll-based——快照装当前累计 X（幂等镜像语义:客户端直接显示不 sum），
  usage 事件触发 re-poll 不 delta-apply。**不双算**，与现状一致。文档化此契约:usage 事件是
  live re-poll 信号，非 attach 重建的 delta 源。

### 1.3 seq 语义 = 下界；**必须锁内 count()，不能裸原子（Linus ① 定死）**

snapshot 返回的 seq 语义定为**下界**：保证 seq 之前(0..seq-1)的状态已反映在快照里；seq 及之后仍在 journal，客户端 `?since=seq` 精确续订。① 不漏(seq 后全经 SSE 补齐) ② 不重(config 幂等 + append seq 去重)。

**必须用锁内 `journal.count()`（现实现），绝不换裸原子计数器（Linus 读 journal 锁定死）**：
mutex 同时干两件事——**seq 定序 + 跨线程内存可见性**。happens-before 链：
1. append(seq 分配)在 mutex 内(journal.zig:51-58)，count() 也在 mutex 内读 lines.len(:62-66)
   → count() 返回 N ⟹ seq<N 的 append 全完成且 happens-before count() 返回（append 的 unlock
   synchronizes-with count 的 lock）。
2. **U4/U5 的 emit 一律在 mutation 之后**（setMode 先 store 再 emit；switchModel syncModelMirrors 后
   才 emitConfig）→ 事件 k 的 mutation happens-before append-k。
串起来：mutation-k(k<N) happens-before count()返回 happens-before 锁外读态 → 快照态必反映
0..N-1 全部 mutation（无 gap）。**裸原子读 seq 给不了第 2 条可见性**（mutation 是普通字段写，
不在原子变量上）→ HTTP 线程读到 N 但看不见 mutation-(N-1) = gap。故锁内 count() 是硬要求。

**U5 新事件约束（Linus 补）**：session_lifecycle 的 created/loaded/closed emit **也必须在对应
mutation 之后**（loaded 在 handleResume swap + 改 session_id 之后 emit），否则破坏边 2、gap 重现。

### 1.4 **slice 字段撕裂 = UAF 不是良性 skew（Linus 新抓，correctness-critical）**

§1.2 说字段撕裂"良性 skew"——**只对标量(u64 usage)成立，对 slice 字段(model/dirs/session_id)错**：
slice 撕裂读到半新半旧 ptr+len = **野指针/越界 = UAF/垃圾，不是陈旧值**。
- `.model`=api_client.model：torn-slice pre-existing（task#13）。
- **`.additional_dirs`=slice-of-slices：SessionSnapshot 新引入的跨线程读**。HTTP 线程读它时，
  driver 若在 addDirectory→rebuildAdditionalDirs（**free 旧 additional_dirs_abs**，U1 实证）→
  跨线程读已 free 的 slice = **UAF。这是 SessionSnapshot 新增暴露面，非 pre-existing**。
- session_id：若 task#16 修 /resume 改 session_id，则也变可变 slice → 同款。

**解法（Linus 倾向 A，我权衡）**：
- **(A) snapshot 在 driver 线程取**：/state 像 slash 命令入 cmdbox，driver 空闲点取 count+读态 →
  driver 独占 App，slice 无竞争 + seq 可见性天然（同线程 mutation-then-read）+ U10 多 session
  路由都在 driver 侧干净。**代价**：/state 加一跳延迟等 driver 空闲；**且生成期 driver 在
  agent_loop.run 不空闲 → /state 阻塞到 run 结束**（状态条生成期陈旧，长 run 尤甚）。
- **(A') driver 发布快照缓存(我推荐)**：driver 在**已有的 mutation choke point**（App 方法 emit
  路径 + setMode + addDirectory + resume）刷新一份 **mutex 守护的 owned 快照缓存**（slice 全 dup）；
  /state 在 HTTP 线程读缓存**只在 mutex 内 dup 出**——无 torn read、无 driver-idle 阻塞（生成期
  照样响应）、复用 U2/U3/U4 已收敛的 choke point。usage(标量,benign)仍直读 app.usage。seq 仍锁内
  count()。**比 (A) 多一个缓存 + 锁，换来生成期 /state 不阻塞**。
- **(B) slice 字段 dup 但仍 HTTP 线程读原 slice**：不解决 torn READ（读 free 中的 ptr 本身就崩），
  ✗ 无效。

**定案 (A')（Linus 拍板）+ 关键约束**：driver 发布 mutex 缓存。(A) 毙掉（生成期 driver 在
agent_loop.run 不空闲，/state 入 cmdbox 会**挂死到 run 结束**，非"一跳延迟"）。

**核心不变式（Linus）**：`model_switch_owned`/`additional_dirs_abs` 的 **free+reassign 必须与任何
跨线程 读+dup 互斥**。绝不能：HTTP 线程读 live slice 而 driver 可能无锁 free 它。

**关键约束——refresh 必须骑 emit，不是手工 per-mutation refreshCache()（否则枚举坑重来，
同 scoped off-by-4）**：cache refresh 挂在 **emit 路径**上——emit ⟺ refresh 一个不变式。因"所有
mutation 都 emit"（U4 已 grep-guard 的单写侧）自动保证"所有 mutation 都刷 cache"，零新增枚举义务。
- **slice 字段进 cache**（UAF-critical）：model（emitConfig(.model) 时刷）、dirs（emitConfig(.dirs) 时刷）、
  session_id（session_lifecycle.loaded emit 时刷，骑同款）。cache 用 mutex 守护 owned dup。
- **标量直读不进 cache**：mode/reasoning（enum 值）、usage（u64，poll-based）、generating（atomic bool）——
  值语义无 UAF，跨字段 skew 是 §1.2 已接受的第三层良性 skew（display 用）。
- **seed**：setConfigEventSink 装配时锁内 dup 当前 slice 值播种 cache（首个 emit 前也有值）。
- /state：读 cache slice 在 mutex 内 dup 出 + 读标量直取 + seq 锁内 count()。

**范围说明**：cache 只覆 UAF-critical slice（不做全字段 cross-field 一致快照——那是 U10 多 session
若需要再扩；U5 只保证每 slice 读安全 + emit-rides-refresh 不留枚举债）。

## 2. SessionSnapshot：中立类型（半 B，供 TUI/daemon 复用）

现状 snapshot 是 web 独有(session.zig:59)，TUI 无等价。提成**中立 `SessionSnapshot`**（读 App，不绑 web）：
```zig
pub const SessionSnapshot = struct {
    seq: usize,          // ← 核心新增(半 A)：journal.count() 快照点
    session_id: []const u8,
    model: []const u8,
    permission_mode: PermissionMode,
    additional_dirs: []const []const u8,
    reasoning_effort: ?ReasoningEffort,
    usage: struct { input_tokens: u64, output_tokens: u64, cost_usd: f64 },
    generating: bool,
    // conversation/tasks 概览 → U7 有界化/多 session 后补(现客户端 since=0 全重放,暂不需)
};
```
web /state 序列化它 + seq；TUI/daemon 同源读。conversation/tasks 概览留到 U7（journal 有界后成硬需求）。

## 3. session 生命周期事件族（全新增量）

CoreEvent 加单 `session_lifecycle: SessionLifecycle` union（同 config_changed 模式，exhaustive switch 编译期强制消费者）：
```zig
pub const SessionLifecycle = union(enum) {
    created: []const u8,  // session_id(新 session 开始)
    loaded: []const u8,   // session_id(/resume 加载)
    closed: []const u8,   // session_id(session 结束)
};
```
- **created（Linus ④ 定：挂事件流建立点作 seq 0，不挂 App 装配/attach）**：session 事件流一建立
  （web run() 里 journal init 之后、开始服务之前）emit created 作 **journal 第一条(seq 0)** →
  任何后来 attach 的客户端(since=0 或快照重放)都见 session 边界起点。**App 装配时 emit 会丢**
  (sink/journal 没接，到不了 seq 0)；**首次附着时 emit 语义错**(那是 attach 非 create，re-attach 重复)。
  created 是"session 诞生"一次性事件，挂事件流建立点。TUI 无 journal → created 驱动 statusline/no-op。
- **loaded**：`handleResume` 成功 swap **+ 改 session_id 之后** emit（emit-after-mutation，§1.3）+
  **修 session_id 漂移**(task#16：更新 app.session_id 到 resume 目录 id)。
- **closed**：session 结束（web session.run 收尾 / TUI 退出）。与 SSE `session_closed` 传输帧区分——这是可重放 journal 事件。
- 进 journal seq 流（同 config_changed），附着重放可见 session 边界。

## 4. 多 session（U10 前置，本设计只留接口不实现）

App 恒"一进程一 session"(app.zig:73 READY 非 DONE)；journal/state 非 per-session-keyed。U5 **不做**多 session 宿主（U10 的活），但 SessionSnapshot/生命周期事件设计成 **session_id-scoped**，为 U10 `map[session_id]→journal` + `/state?session=<id>` 路由铺路。

## 5. 分阶段
- **B1**：SessionSnapshot 中立类型 + web /state 返回它 + **seq 字段**(半 A 核心)。客户端 index.html 用 snapshot.seq 做订阅起点(替 since=0)。
- **B2**：session_lifecycle CoreEvent union + emit(created/loaded/closed) + handleResume 修 session_id 漂移(task#16)。
- **B3**：测试——**attach 期间并发 mutation 不丢不重**(attach 拿 snapshot@seq，期间狂 setModel/switchModel，客户端从 seq 订阅，断言最终态==服务端态)；session_lifecycle emit(resume→loaded)。

## 6. Linus 拍板结论（已定）
1. **锁内 count()（定死，删"或原子读"）**：mutex 兼管 seq 定序 + 跨线程可见性；裸原子给不了
   plain-field mutation 的可见性 → gap。U5 新事件 emit-after-mutation（§1.3）。
2. **SessionSnapshot 提中立（定，UI-free 干净）**：字段全 core 类型无 UI 类型，不破 lib 边界。
   **但 slice 安全发布要一起定（§1.4）**。
3. **session_lifecycle 单 union（定，同 U4 exhaustive switch 编译期强制）**。
4. **session_created 挂事件流建立点作 seq 0（定，非 App 装配/attach）**（§3）。

**唯一待定**：§1.4 slice 安全发布 (A) driver 侧取 snapshot vs (A') driver 发布 mutex 缓存——
我推荐 (A')（避开生成期阻塞）。Linus 拍板后进 B1。

## 7. B3 测试要求（Linus 补）
并发 mutation 测试**必须真起 HTTP 线程读 /state** 才能暴露 slice 竞争（纯单线程测不出 UAF）。
attach 拿 snapshot@seq，另起线程狂 setModel/switchModel/addDirectory，客户端从 seq 订阅，断言
最终态==服务端态（不丢不重）+ 无 UAF（附带验 slice 安全发布真生效）。
