# metacodes Agent Swarm — 设计文档

> 状态:SW0–SW7 全部落地(2026-07-15)。每阶段 Linus review + PM 成熟度 review 双通过。
> 参考:Claude Code teams(cc/src)、codex 多 agent(codex-rs)、tinykg 任务控制平面。

## 0. 定位与差异化

metacodes swarm = **一组对等 teammate agent + lead**,经**文件邮箱**通信、经**tinykg 任务 DAG**协调。

核心架构判断(区别 cc/codex 的关键):

| 关注点 | 载体 | 理由 |
|--------|------|------|
| **消息传递** | 文件邮箱(锁保护 JSON 数组) | 低延迟、有序、跨进程;每 500ms 轮询 |
| **任务协调** | tinykg 任务 DAG(claim/lease/frontier) | 图数据库封顶原子租约、readiness 门控、看板 |

**为什么不用图数据库当邮箱**:tinykg 是 subprocess CLI(每调 fork+exec + 35s 超时),无原生有序/读写位;500ms 轮询 × N teammate × 子进程 = 灾难。文件 append 是正确工具。
**图数据库真正简化的**:任务分派——lead 不用发 `task_assignment` 邮件,把任务留在 DAG,空闲 teammate 从 frontier 自领(原子租约互斥)。这是 metacodes 的 DAG 优势。

## 1. 数据模型(SW0)

`src/swarm/{team,mailbox}.zig` + `src/util/file_lock.zig`(通用工具,已有 swarm 之外的消费者)

- **磁盘**:`{home}/.metacodes/teams/<team>/config.json`(TeamFile)+ `inboxes/<name>.json`(邮箱)。
- **身份**:`name@team`(确定性,lead 可推算任何 teammate id,重启不变)。`team-lead` 保留名。
- **会话归属**:`TeamFile.leadSessionId` 记录创建该队伍的 lead session；每个 member
  的 `sessionId` 必须等于它所属的 lead session。进程外 member 另外保存每次 spawn 生成的
  `leaseId`；恢复、轮换 session、删除后重建同名成员或启动进程外 teammate 时都以父 session
  和 lease 双重校验。缺少字段的旧配置按不属于当前 session 处理并拒绝操作。
- **file_lock**(`src/util/file_lock.zig`):`<path>.lock` O_EXCL 哨兵 + **原子 rename 两阶段抢占**(防双持有)+ mtime 兜底陈旧检测。
- **mailbox**:锁内读-改-写;消息 `{from,text,timestamp,read,color?,summary?,session_id?,lease_id?}`。生产 SendMessage、idle 和 shutdown 回执都写入发送者的父 session 与 spawn lease；lead、线程 teammate、进程 teammate 消费普通消息时按当前 TeamFile 成员身份校验，缺少或过期身份的旧消息消费后丢弃，防同名替换后的延迟消息注入。`classify` 真顶层 JSON parse 认协议类型(非 substring,防误判);`markReadAt` 选择性标读(协议消息留给消费者);软顶 500(裁最旧已读)+ 硬顶 5000(丢最旧未读 + log.warn)。
- **updateTeam**:一切 team 变更的唯一锁内 RMW 入口(防丢更新)。

## 2. 进程内 teammate 运行时(SW1)

`src/swarm/teammate.zig`

- 每 teammate = 一根 `std.Thread`,跑**持久多轮 agent_loop**(conversation/TaskStore/agent_ident 跨 turn 存活)。
- 循环:spawn → run → idle(config `is_active=false` + idle_notification→lead 邮箱)→ waitForMail(500ms:shutdown 优先 > lead > peer FIFO;协议消息选择性标读留未读)→ 下一 turn。
- **铁律**:c_allocator(线程侧,App GPA 非线程安全)/ entry 堆分配指针存储 / 独立 AbortSignal(中断 lead 不杀 teammate)/ deinit abort→join→free。
- idle 通知按 stop_reason 分流:`available`(end_turn)/ `needs_continuation`(软截断)/ `failed`(错误,带 failureReason)——**绝不把截断/失败洗成 available**。
- `reapTerminated`:spawn 前回收死尸体(防 entries 无界累积)。

## 3. 工具面 + lead 接线(SW2)

`src/swarm/{context,tools}.zig`

- 工具:**TeamCreate**(一 lead 一队,lead 非成员)/ **TeamDelete**(拒活跃成员)/ **SendMessage**(name 直达 / `*` 广播;裸文本对 peer 不可见的纪律)。
- **Task(name=…)** → spawn teammate 分支(对齐 cc AgentTool)。
- **pollLeadInbox**:REPL turn 边界拉 teammate 消息/通知注入对话。
- **SWARM_ADDENDUM**:有 team 时每轮注入 system prompt("裸文本对 teammate 不可见,必须用 SendMessage;TaskCreate 任务成团队 backlog")。
- **门控**:`--agent-teams` 才广告 3 工具(不污染单 agent 会话工具菜单,对齐 cc agentSwarmsEnabled)。

## 4. tinykg DAG 协调面(SW3,差异化优势)

`src/swarm/teammate.zig::tryClaimFrontierTask`

- TeamCreate 建共享 KG `kg_inbox` root(lead 的 TaskCreate 落此,teammate frontier 自领此)。
- 空闲 teammate 节流(2.5s)poll `frontier` → 领 ready 无主叶子(`claimTask` 原子租约)→ 组装 `<assigned-task>` prompt。
- **租约互斥**:tinykg store 锁保证两 teammate 不撞车(真两线程并发测试验证 no-overlap)。
- **H1 修**:每 teammate 独立 KgClient(c_allocator),不共享 App arena 客户端(多线程定时 poll 撞非线程安全 arena → 堆损坏)。
- claim 身份 = `name@team`(kanban `claimed_by` 显队友名)。退出释放持有租约(防卡 7200s TTL)。

## 5. 审批/安全协议(SW4)

- **伪造防御**:shutdown_request 只认 `from==team-lead`(peer 冒充无效)+ `team-lead` 保留名不可 spawn(防 inbox 碰撞 + 冒充)。
- **shutdown 协议**:lead 发 → teammate 回 `shutdown_approved`(echo request_id)+ 优雅退出(在 idle 处理,不打断进行中 turn,比 cc 模型审批更简洁安全)+ 释放租约。lead pollLeadInbox 消费回执 → 摘牌(**仅当线程确已 terminated**,防仍在跑的 teammate 自摘成不可寻址)。
- **orphan 清理**:lead deinit 删会话 team 目录——**生产安全** `removeTeamDirTree`(护栏:路径须含 `/.metacodes/teams/` + 拒 `..` + symlink 不跟随 lstat)。
- **teammate fail-closed 权限**:`no_interactive_prompt=true` → `.ask` 无 ui_requester 直接 deny,**绝不读 fd 0**(teammate 线程与 lead REPL 共享 fd 0,读会争抢/卡死)。
- **register SW7**:permission 代理(teammate→lead 弹框)/ plan 审批 auto-approve / plan/mode 响应 from-gate(消费者建时补)。

## 6. UX + 资源边界(SW5)

- 资源上限:MAX_TEAMMATES=8 / output_buf 512K / mailbox 软+硬顶 / reapTerminated。
- statusline `N👥 M⚙`(liveCount/workingCount,排除尸体);`snapshotRoster` 数据面(消费者=SW7 switcher)。
- register(tty):agent switcher teammate 视图 / idle 阻塞实时消息提示 / peer-DM summary。

## 7. 进程外 teammate + 隔离(SW6)

`src/swarm/teammate_process.zig`

- **`--teammate` runtime**:身份 CLI args(--agent-name/--team-name/--parent-session-id/--teammate-lease-id/--teammate-cwd);worktree chdir + **同步更新 app.cwd_abs/project_dir**(光 chdir 没用,工具用 cwd_abs 解析路径);mailbox 消息循环(waitForWork 镜像 in-process);fail-closed 权限。
- **lead-spawn**:`--teammate-mode process` → Task(name) 走 `spawnTeammateProcess`(createWorktree `git -C repo` + 登记 member `backend_type=process`/worktree_path + `forkExecTeammate` fork **零分配**只 async-signal-safe + 追踪 `process_teammates` 供 deinit kill+removeWorktree)。
- **进程启动绑定**:父 session 在 `App.init` 之前注入子进程配置，保证 KG、prompt、权限、plan
  和 transcript 从第一帧就使用同一个 session；子进程另生成独立的 agent identity，避免把
  协调身份和会话路由身份混用。team 名必须是 canonical sanitized 形式，成员从持久化配置
  被删除、换绑或 cwd/worktree 改变后，进程在启动和下一次轮询前 fail closed；指定的
  worktree 无法 chdir/realpath 时也直接退出，绝不降级到 lead cwd。spawn 后尚未登记成功
  时的子进程会被 kill+reap，避免留下无主进程。
- **排除(用户指令)**:Linux bubblewrap 沙箱不做。macOS Seatbelt 沙箱复用(同 App/同 Bash 工具,settings 开则自然套 wrapCommand)。
- register SW7:真 fork+exec e2e / plan-mode 非继承显式 guard / Seatbelt 验证。

## 8. 真模型 e2e(SW7)

- 真 glm 模型 headless e2e:`TeamCreate`(→ team demo 建成)+ `Task(name=helper)`(→ 真 teammate 线程 `helper@demo` spawn),两工具 `tool.exec done` 成功。**e2e 抓到并修真 bug**:headless 未接 `.swarm`(只 REPL 接)→ SwarmUnavailable;修后端到端 PASS。
- 每阶段:MockServer 确定性组件测试 + 真 tinykg(租约互斥/worktree)+ 真 git(worktree)+ Linus/PM 双 review。

## 9. 与 cc/codex 对照

- **cc(teams)**:同款 name@team 身份 + 文件邮箱 + 结构化协议信封 + 共享任务列表自领。metacodes 邮箱格式与 cc interop(camelCase)。差异:metacodes 用 tinykg DAG 替代 cc 的平面任务文件(原子租约 + readiness)。
- **codex(多 agent)**:线程 + 单 AgentControl + 语义 = 进程内。metacodes 进程内(SW1)对齐;额外做进程外(SW6)为 cwd/worktree 隔离(codex 靠 environments,不做 worktree)。

## 10. 已知边界 / 差距矩阵

| 项 | 状态 |
|----|------|
| Linux bubblewrap 沙箱 | 排除(用户指令) |
| permission 代理(teammate→lead 弹框) | register SW7(当前 fail-closed 安全) |
| plan 审批 auto-approve | register SW7 |
| plan/mode 响应 from-gate | register(消费者建时补) |
| 真 fork+exec 进程外完整 e2e | register SW7(干净进程 harness) |
| agent switcher teammate 视图 | register(tty) |
| lease TTL 续期(长任务>7200s) | register |
