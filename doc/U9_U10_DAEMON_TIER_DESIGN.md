# U9 + U10 设计:daemon 层(进程隔离 + 多 SessionService 宿主)

> 诉求③:「尽可能稳定 … 多进程隔离 … 统一双向通讯(websocket/http2)」。前序 U1-U8 把 agent_loop
> 做成**无状态内核 + 中立事件面 + 附着协议 + 有界 journal + 挂起恢复**;U9/U10 是把它**装进一个能同时
> 宿主多个 session 的常驻进程**——这才兑现"多进程隔离 + 统一双向通讯"。U9/U10 强耦合,合并设计。
>
> **设计定案(前序 roadmap)**:daemon 进程隔离,**UDS + NDJSON 本地绑定 + 保留 SSE web 绑定,
> HTTP/2 否决**(自写 HTTP/1.1+SSE 已够,HTTP/2 多路复用/HPACK 不值当;WebSocket 亦不引入——
> SSE(下行)+ POST(上行)已覆盖 web,UDS+NDJSON 覆盖本地进程间)。

## 1. 为什么先要 U9(SIGINT/abort 解耦)

现状(app.zig:137 `g_abort_signal: ?*AbortSignal`):**单进程全局指针**,SIGINT handler
(onSigint)把它 `.abort(.user_ctrl_c)`。`installSigintHandler` 绑**一个** app.abort。注释明说这对
TUI(N=1)正确、GUI 旁路它(每 session 直接 `app.abort.abort()`)。

**daemon 的冲突**:一个进程宿主 N 个 SessionService。SIGINT 打进来:
- 若 g_abort_signal 绑某**一个** session 的 abort → SIGINT 只中断那个 session 的 run(错:应关**整个
  daemon**)。
- 若不绑 → SIGINT 默认 terminate 进程(不优雅:不 flush transcript、不 close journal、SSE 连接硬断)。

**U9 的本质不是"SIGINT 按 session 路由"**(SIGINT 进程级、daemon 无 TTY、无"Ctrl+C 打到哪个
session"语义)——**而是把两个被 g_abort_signal 混同的概念拆开**:
- **进程关停(process shutdown)**:SIGINT / daemon stop。语义=停止 accept、优雅关所有 session、退出。
  这**天然是进程全局**(单一 shutdown 信号正确,不是缺陷)。
- **单 session run 中断(run abort)**:某 session 的"Stop"。已**协议路由**(web POST /interrupt →
  该 session `app.abort.abort(.user_interrupt)`,session.zig 已实现 user_ctrl_c vs user_interrupt 二义)。

### U9 落地(可独立于 U10 先做,为其铺路)

引入**进程级 shutdown 信号**与"单 session run abort"解耦:
- 新增 `core/shutdown.zig`:`ShutdownSignal`(= 一个 AbortSignal 语义的进程级停机旗标 + 可注册的
  停机观察者列表)。SIGINT handler 只 `shutdown.trigger()`(async-signal-safe:置原子)。
- `g_abort_signal` 语义收窄/改名为 `g_shutdown`:指向进程级 ShutdownSignal,**不再**指向某 session
  的 run-abort。
- **N=1 宿主(TUI/web/headless)兼容**:这些模式下 shutdown ⟺ 唯一 session 退出。让宿主把自己的
  `app.abort` **挂到** shutdown 的观察者(shutdown.trigger 时也 `app.abort.abort(.user_ctrl_c)`)——
  行为与今天逐字节一致(SIGINT 既停 run 又退进程)。**纯重构,零行为变化**(红灯:TUI/web SIGINT
  e2e 不变)。
- **daemon 宿主(U10)**:SIGINT → shutdown.trigger → daemon accept 循环退出 + 遍历所有 session 优雅
  关停(每个 session 自己的 abort 由 daemon 逐个 `.abort` + join)。**不**把 g_shutdown 绑单 session。

**关键不变式**:run-abort(单 session Stop)永远走**协议**(/interrupt),永不走进程信号;进程信号
**只**触发 shutdown。这样 N 个 session 各自的 Stop 互不影响,shutdown 是唯一的全局事件。

## 2. U10:daemon 模式(`metacodes serve`)

### 2.1 形态
`metacodes serve [--uds <path>] [--web <port>]`:常驻进程,宿主 0..N 个 session,每个 session =
一个 App 实例 + 一个 SessionService(U2 中立命令面)+ 一个 EventJournal(U7 有界)。**不进 TUI**。

### 2.2 绑定层(两条,复用现有,不引 HTTP/2/WebSocket)
- **UDS + NDJSON**(本地进程间,新):Unix domain socket,每行一个 JSON 消息(NDJSON)。请求
  `{"session":"<id>","op":"message|command|interrupt|attach","...}`;响应/事件 NDJSON 回推。
  UDS = 本机、文件权限即鉴权(0600)、无 CSRF/Origin 顾虑(非浏览器可达)。这是 gui/imui/语音 UI 的
  首选本地绑定(低延迟、双向、无 HTTP 开销)。
- **SSE + POST**(web,复用 U5-U7 的 WebServer):保留。daemon 下 WebServer 需**按 session 多路**
  (path 带 session id:`/s/<id>/events`、`/s/<id>/message`)。当前 WebServer 是单 session
  (state_ctx/journal 单份)→ U10 需让它按 session id 查 SessionService + journal。

### 2.3 多 SessionService 宿主(核心)
- **SessionRegistry**:`AutoHashMap(SessionId, *SessionHost)`。SessionHost = { App, SessionService,
  EventJournal, driver thread }。加锁(daemon 多绑定线程并发 create/lookup/destroy)。
- **生命周期**:create(op=new 或首次 attach 未知 id)→ 起 driver 线程(跑 U2 的空闲循环:等 inbox →
  agent_loop.run → journal)。destroy(op=close / idle-reap)→ shutdown 该 session 的 abort + join
  driver + 关 journal + 从 registry 摘除。**session_lifecycle 事件(U5)**在此 emit(created/closed)。
- **附着(U5/U6/U7 直接复用)**:attach → SessionService.snapshot(带 seq + config + roster)→ 客户端
  订阅 `since=seq`。journal 有界 + resync(U7)保证长 session 不 OOM。
- **App arena 线程模型**:每 SessionHost 的 App arena 仍单线程(其 driver 独占);跨 session 无共享可变
  态(各自 App/journal)。daemon 层的 registry/绑定用 c_allocator + 锁。**这正是 U1-U3 清进程全局态
  的收益**(permission/model/config 都 per-App,多 App 不串台)。

### 2.4 关停顺序(U9 的 shutdown 驱动)
SIGINT/daemon-stop → g_shutdown.trigger → ① accept 循环停(UDS + web listen fd 关)→ ② 遍历
registry 每个 SessionHost:abort run → join driver → close journal(唤醒该 session 所有 SSE/UDS 附着)→
persist transcript → ③ destroy registry → 退出。**逐 session 优雅**,非进程硬杀。

## 3. 实施顺序

- **U9-A**:`core/shutdown.zig` ShutdownSignal(trigger/isTriggered/观察者)+ SIGINT 改绑它。
- **U9-B**:TUI/web/headless 宿主把 app.abort 挂 shutdown 观察者(N=1 行为不变,红灯 e2e)。
  删 g_abort_signal 单指针语义(改 g_shutdown)。
- **U10-A**:SessionRegistry + SessionHost(create/lookup/destroy + driver 线程 + lifecycle 事件)。
- **U10-B**:UDS + NDJSON 绑定(listen/accept/per-conn 线程/NDJSON 编解码/按 session 路由)。
- **U10-C**:WebServer 多 session 化(path `/s/<id>/*` → registry 查 SessionService/journal)。
- **U10-D**:`metacodes serve` CLI + 关停顺序接 U9 shutdown。
- **U10-E**:e2e(两 session 并发跑、各自 attach/interrupt 互不影响、SIGINT 优雅关全部)。

## 4. 风险 / 待核实
- [ ] WebServer 当前单 session 硬编码 state_ctx/journal → 多 session 化是最大改造面(path 路由 +
  per-session 依赖查表)。评估:抽 `WebServer.Deps` 为"按 session id 解析"的回调,而非单份指针。
- [ ] UDS 在 Windows:AF_UNIX 有 Win10+ 支持但 std 覆盖不确定 → daemon 首版可 POSIX-only(Windows
  走 web 绑定),对齐跨平台 roadmap 的分期。
- [ ] idle-reap 策略(session 空闲多久 destroy)+ 上限(max sessions)——轴A 治理延伸。
- [ ] 鉴权:UDS 靠文件权限(0600);web 绑定在 daemon 下仍 localhost + Origin(U5 已做)。跨机不做
  (本地基座定位)。
- [ ] U9 是否值得独立先落:若 U10 紧接做,U9 可作为 U10-A 的第一步(避免孤儿 shutdown 抽象无消费者)。
  倾向**U9 与 U10 同批**(shutdown 信号第一个消费者 = daemon),TUI/web 兼容重构随之。
