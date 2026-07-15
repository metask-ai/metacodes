# U6 设计:agent 生命周期事件 + tasks_changed(DAG 可视化)

> 诉求②末段:「agent 切换」+「任务完成的 DAG 可视化」。U4=配置变更事件族,U5=session 生命周期+附着,
> U6=**agent 生命周期 + 任务 DAG 变更**,补齐事件面最后两个洞。沿用 U4/U5 已定的三条纪律:
> ① 中立 CoreEvent(UI-free,进 metacodes-core,`test:lib` refAllDecls 证隔离);
> ② 穷举 switch 强制每个 backend 消费(tui/writer no-op,web journal);
> ③ 附着可重建(attach 时快照自带当前 agent roster + task frontier,SSE 增量续接)。

## 1. 两个事件族

### 1.1 agent 生命周期(`AgentLifecycle`)

数据源已存在:`AgentJobRegistry` 的 `JobEntry.status`(running/done/failed/…)+ `snapshotJobs`→`JobSnapshot`。
缺的是**父 session 事件流上的生命周期广播**——目前 subagent 的 `JobEntry.backend` 只把 subagent
**内层** CoreEvent(text/tool)转发出去,没有「一个 agent 被 spawn / 状态变了 / 结束了」的**外层**事件
让 UI 画 agent 切换/roster。

```zig
pub const AgentLifecycle = union(enum) {
    spawned: struct {
        id: []const u8,        // job id(borrow;sink 跨线程留存须 dup)
        agent_type: []const u8, // "Explore"/"Plan"/…(borrow)
        desc: []const u8,       // 描述预览(borrow)
        foreground: bool,       // 前台同步 job vs 后台
    },
    status: struct {
        id: []const u8,
        state: []const u8,      // JobStatus tagName(running/done/failed/…),值语义字符串
        turns: u32,
        tool_calls: u32,
    },
    done: struct {
        id: []const u8,
        state: []const u8,      // 终态(done/failed/aborted)
        turns: u32,
        tool_calls: u32,
        tokens: u64,
    },
};
```

**为什么 state 用 tagName 字符串而非 JobStatus enum**:JobStatus 定义在 agent_job_registry(非 core/protocol),
core 事件不能依赖它(会把 registry 拖进 lib UI-free 图)。U4 的 mode 是 `types.PermissionMode`(types 已在 core),
可用值语义;JobStatus 不在 core,故投影成 tagName 字符串(与 diag_run_end 的 `stop_reason_name` 同款处理)。

**emit 点**(AgentJobRegistry 是 choke point,所有 spawn/状态推进都过它):
- `spawned`:`spawnBackground` / 前台 Task 注册 job 后。
- `status`:JobEntry 状态推进处(status 字段赋值的锁内单写侧;抽一个 `setStatus` seam 骑 emit,避免枚举漏点——
  对齐 U3 syncModelMirrors / U4 emitConfig「单写侧骑 emit」)。
- `done`:reap/join 收尾把 status 置终态时(= status 的一个特例,可复用 setStatus seam 判 isTerminal 再补发 done)。

**线程**:emit 在 subagent 自己线程(后台 job 线程 / 前台并发批 worker)调 → sink 必须线程安全
(web journal 用 c_allocator,已线程安全;dup borrow slice)。与 U5 SnapshotCache 同款跨线程纪律。

### 1.2 tasks_changed(`TasksChanged`)

数据源:tinykg task DAG frontier(`core/task_store.zig` + `tinykg task-frontier`)。诉求②要「任务完成的 DAG
可视化」——任一 UI(webui 画看板、tui 画 ▹ 缩进树)需在**任务 claim/complete/frontier 变化时**收到通知去重拉。

```zig
pub const TasksChanged = union(enum) {
    // 轻量信号:frontier 变了,UI 自己去 /tasks 拉全量(避免事件里塞整棵 DAG 每次变都全量序列化)。
    invalidated: void,
    // 可选富载:单任务状态跃迁(pending→in_progress→completed),UI 可增量更新不全拉。
    task: struct {
        id: []const u8,      // task 节点 id
        state: []const u8,   // pending/in_progress/completed/…(tagName)
        claimed_by: []const u8, // agent_ident 或空
    },
};
```

**设计权衡:事件里塞多少 DAG**。DAG 可能大(几十任务 + 边)。每次变更全量序列化进 journal =
带宽 + journal 膨胀(U7 有界化前尤甚)。故 U6 默认 `invalidated` 轻信号 + UI 拉全量(与 /state 快照对称);
`task` 富载可选(claim/complete 的单跃迁便宜,UI 增量),但**不**在事件里塞整棵树。看板全量走
snapshot(附着)+ 一个 `/tasks` 端点(daemon U10 时补;web 现可复用 /state 扩字段)。

**emit 点**:TaskUpdate 工具(in_progress=claim / completed=release)、task_store 的 frontier 变更写侧。
同样抽单写侧 seam 骑 emit,避免散点漏发。

## 2. 附着(attach)一致性

沿用 U5:客户端 attach 时快照必须自带**当前 agent roster + task frontier**,之后靠 SSE 增量续接。
否则「事件重放从 seq 开始」的客户端拿不到 attach 之前 spawn 的 agent / 已有的 task。

- **agent roster**:snapshot 扩 `agents: []{id,agent_type,state,...}`(= `snapshotJobs` 投影,slice-safe:
  snapshotJobs 已锁内 dup 值语义,天然无 UAF,比 U5 model/dirs 更省心——JobSnapshot 本就是 owned 值拷贝)。
- **task frontier**:snapshot 扩 `tasks: [...]`(task_store frontier 投影)。task_store 的线程模型待核
  (若 driver 单线程独占则直读;若跨线程则同 U5 加锁 dup)。

**seq 锁定**:与 U5 同——snapshot 读 `journal.count()` 在读 roster/tasks **之前**(no-gap 不变式:
attach 之前的 spawned/tasks_changed 已反映在快照,之后的走流)。emit 侧同样「先更新数据源镜像,再 append journal」。
→ 复用 U5 B3 证明的读序/写序不变式,agents/tasks 是新的 slice 轴,同款处理。

## 3. backend 消费

- **tui_backend / writer_backend**:no-op(穷举 switch 强制加 case;TUI 的 agent 进度树/看板走既有
  snapshotJobs 轮询路径,不消费这俩新事件——保持 TUI 现状零回归,新事件纯为进程外 UI 服务)。
- **web(WebBackend + session.zig)**:journal 序列化 `{"agent_lifecycle":…}` / `{"tasks_changed":…}`;
  snapshot 扩 agents/tasks 字段。index.html 可选加 roster/看板渲染(MVP 可只 journal 不画,画留后续)。

## 4. 实施顺序(每步 implement→红灯验证→测试)

1. **A1 中立事件**:ui_event.zig 加 `AgentLifecycle`/`TasksChanged` union + `agent_lifecycle`/`tasks_changed`
   CoreEvent 变体;tui/writer no-op case。build + test:lib 绿(证隔离)。
2. **A2 agent emit seam**:AgentJobRegistry 抽 `setStatus` 单写侧 seam,骑 emit(spawned 在 spawn 后、
   status/done 在 setStatus)。需要一个 sink——registry 已有到父 backend 的通路?核:JobEntry.backend 是
   subagent**内层**转发;外层 spawned/done 要发到**父** session 的 backend。定位父 backend 注入点。
3. **A3 tasks emit**:TaskUpdate/task_store frontier 写侧骑 emit(invalidated + 可选 task 富载)。
4. **A4 附着扩字段**:StateSource.snapshot 加 agents(snapshotJobs 投影)+ tasks(frontier 投影),
   seq 锁定读序(count 先)。L2 web 测试断言 attach 快照含 roster/tasks。
5. **A5 端到端测试**:MockServer 假模型 spawn subagent → journal 见 agent_lifecycle spawned→done;
   TaskUpdate → journal 见 tasks_changed。+ 附着快照含当前 roster。真模型 e2e(可选,Task 系已有 e2e)。

## 实施状态(2026-07-15)

- ✅ **A1**(9a11b76):中立事件 + CoreEvent 变体 + tui/writer no-op + WebBackend 泛型序列化。test:lib 隔离保持。
- ✅ **A2**(916f141):EventReporter(限定子集,两具名方法)+ ToolContext.event_reporter + agent_loop EventTramp
  注入(depth==0)+ agent.zig agent_lifecycle(前台 spawned+done、后台 spawned)+ task_tools.zig tasks_changed
  (全 mutation 出口)。测试:task_tools 单测 + agent_background 全链组件测。
- ✅ **A4**(1160011):StateSource.snapshot 加 agents roster(snapshotJobs 线程安全)+ session.zig 测试。
- ⬜ **A3 富载 task 变体**:当前只发 invalidated(轻信号);task{id,state,claimed_by} 富载未发(设计说可选)。
- ⬜ **A5 web e2e**:agent_background 组件测已覆盖全链;web SSE JS handler + 真 --web e2e 未做(低优先)。
- **存量债**:task#18(后台 done/status 跨线程)、task#19(task frontier 进快照,需 U5-式发布缓存)。
- ✅ **F1 修**(review MINOR):前台子 agent **失败**也发 done{failed}(errdefer + done_emitted 抑制双发)——
  否则 spawned 无对应 done,SSE 客户端永久卡 running。红灯测试:400 响应逼子 agent 失败,断言 spawned 后
  必有恰一个 done。
- **已知 gap(review F3,登记非修)**:event_reporter 只在 depth==0 注入 → **swarm teammate/subagent(depth>0)
  完成共享 kg_inbox 任务(解锁下游)不发 tasks_changed 到 lead 的 SSE 流**,lead UI 要等下次 /state 重拉才见。
  与"lead 广播"设计一致,但 SSE-驱动看板对 teammate 任务闭合是延迟的。若要实时,需 depth>0 也注入 reporter
  (但 teammate 的父 backend 路由 + 线程安全需另设计,同 task#18 的 cross-thread 顾虑)。
- **NIT(review F4/F5,未修)**:F4=no-op TaskUpdate/吞掉的 release 失败也发 invalidated(幂等无害,"每个成功
  mutation 出口"措辞略宽);F5=snapshotJobs dup 5 串但 A4 只用 id/agent_type(每次 /state 多 dup desc/tool,
  无泄漏,微 churn)。

## 5. 待核实(实施前)

- [x] **父 backend 注入点 → 已定位真正的设计缺口**。核实结论:
  - `spawnAgentSink(…, backend)` 的 backend 是 subagent **内层**事件转发(后台=JobEntry.backend WriterBackend,
    前台=null);**不是**父 session 事件流。外层 spawned/done 要发到**父** backend。
  - 父 backend 在 **Task 工具 execute 站点**可达(ToolContext)——但**关键缺口**:`ToolContext` 目前**没有
    通用 CoreEvent emit 通路**。它只有两类窄通道:① `UiRequester`(请求-响应,非单向通知,L1 有意没收进
    CoreEvent 总线,见 context.zig:57-61);② `ToolProgressReporter`(工具内进度→agent_loop 映射成
    `.tool_progress` 单一变体)。agent_lifecycle 是**单向通知**、该上 CoreEvent 跨进程总线,但没通道发。
  - **A2 的真决策**:给 ToolContext 加一条"工具→父 backend"的 CoreEvent 通知通路。两个候选:
    - (a) 仿 ToolProgressReporter 加一个窄 `AgentLifecycleReporter`(ctx+fn,agent_loop 注入,转发到 be.emit)。
      优点=最小面、与现有 reporter 同构;缺点=又一个专用 reporter。
    - (b) 加通用 `EventReporter`(工具可 emit 任意"通知类"CoreEvent 子集)。优点=tasks_changed 也复用;
      缺点=面更宽,要界定"工具可发哪些变体"(不能让工具乱发 text_chunk/tool_result)。
    倾向 **(b) 限定子集**:定义"工具可发的通知类事件"= {agent_lifecycle, tasks_changed}(未来可扩),
    一个 reporter 覆盖 U6 两个族;A2/A3 共用一条注入线。Task execute 发 agent_lifecycle,TaskUpdate 发 tasks_changed。
  - **Linus 关注点预判**:reporter 注入必须在**前台+后台+子 agent** 三路都接线(漏一路=该路 agent 静默),
    对齐 [[cc-zig-webui-boundary-validation]] 的"新 backend checklist";headless/无 backend 走 no-op reporter。
- [ ] **task_store 线程模型**:frontier 读是否跨线程(决定 snapshot 投影是否要加锁 dup)。
- [ ] **前台 Task**:前台同步 Task 也要发 spawned/done(不只后台 job);核 foreground 路径的注册点。
- [ ] U5 review 若改动 SnapshotCache/attach 读序契约,U6 附着扩字段继承其修法。
