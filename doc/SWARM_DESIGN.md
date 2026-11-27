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

`packages/coding/src/swarm/{team,mailbox}.zig` + `packages/base/src/util/file_lock.zig`(通用工具,已有 swarm 之外的消费者)

- **磁盘**:`{home}/.metacodes/teams/<team>/config.json`(TeamFile)+ `inboxes/<name>.json`(邮箱)。
- **身份**:`name@team`(确定性,lead 可推算任何 teammate id,重启不变)。`team-lead` 保留名。
- **会话归属**:`TeamFile.leadSessionId` 记录创建该队伍的 lead session；每个 member
  的 `sessionId` 必须等于它所属的 lead session。进程外 member 另外保存每次 spawn 生成的
  `leaseId`；恢复、轮换 session、删除后重建同名成员或启动进程外 teammate 时都以父 session
  和 lease 双重校验。缺少字段的旧配置按不属于当前 session 处理并拒绝操作。
- **file_lock**(`packages/base/src/util/file_lock.zig`):`<path>.lock` O_EXCL 哨兵 + mtime 兜底陈旧检测 + **每条陈旧记录单赢家的接管**(防双持有):抢锁者先 O_EXCL 建这条记录专属的认领文件 `<path>.lock.claim.<指纹>.<代>`,持认领后确认锁文件仍是它观测到的那条陈旧记录才删除重建,别人刚抢到的新锁不会被挪走或删掉。
- **mailbox**:锁内读-改-写;消息 `{from,text,timestamp,read,color?,summary?,session_id?,lease_id?}`。生产 SendMessage、idle 和 shutdown 回执都写入发送者的父 session 与 spawn lease；lead、线程 teammate、进程 teammate 消费普通消息时按当前 TeamFile 成员身份校验，缺少或过期身份的旧消息消费后丢弃，防同名替换后的延迟消息注入。`classify` 真顶层 JSON parse 认协议类型(非 substring,防误判);`markReadAt` 选择性标读(协议消息留给消费者);软顶 500(裁最旧已读)+ 硬顶 5000(丢最旧未读 + log.warn)。
- **updateTeam**:一切 team 变更的唯一锁内 RMW 入口(防丢更新)。

## 2. 进程内 teammate 运行时(SW1)

`packages/coding/src/swarm/teammate.zig`

- 每 teammate = 一根 `std.Thread`,跑**持久多轮 agent_loop**(conversation/TaskStore/agent_ident 跨 turn 存活)。
- 循环:spawn → run → idle(config `is_active=false` + idle_notification→lead 邮箱)→ waitForMail(500ms:shutdown 优先 > lead > peer FIFO;协议消息选择性标读留未读)→ 下一 turn。
- **铁律**:c_allocator(线程侧,App GPA 非线程安全)/ entry 堆分配指针存储 / 独立 AbortSignal(中断 lead 不杀 teammate)/ deinit abort→join→free。
- idle 通知按 stop_reason 分流:`available`(end_turn)/ `needs_continuation`(软截断)/ `failed`(错误,带 failureReason)——**绝不把截断/失败洗成 available**。
- `reapTerminated`:spawn 前回收死尸体(防 entries 无界累积)。

## 3. 工具面 + lead 接线(SW2)

`packages/coding/src/swarm/{context,tools}.zig`

- 工具:**TeamCreate**(一 lead 一队,lead 非成员)/ **TeamDelete**(拒活跃成员)/ **SendMessage**(name 直达 / `*` 广播;裸文本对 peer 不可见的纪律)。
- **Task(name=…)** → spawn teammate 分支(对齐 cc AgentTool)。
- **pollLeadInbox**:REPL turn 边界拉 teammate 消息/通知注入对话。
- **SWARM_ADDENDUM**:有 team 时每轮注入 system prompt("裸文本对 teammate 不可见,必须用 SendMessage;TaskCreate 任务成团队 backlog")。
- **门控**:`--agent-teams` 才广告 3 工具(不污染单 agent 会话工具菜单,对齐 cc agentSwarmsEnabled)。

## 4. tinykg DAG 协调面(SW3,差异化优势)

`packages/coding/src/swarm/teammate.zig::tryClaimFrontierTask`

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
- **register SW7**:permission 代理(teammate→lead 弹框)/ mode 响应 from-gate(消费者建时补)。plan 审批随 plan 模式移除,不再登记。

## 6. UX + 资源边界(SW5)

- 资源上限:MAX_TEAMMATES=8 / output_buf 512K / mailbox 软+硬顶 / reapTerminated。
- statusline `N👥 M⚙`(liveCount/workingCount,排除尸体);`snapshotRoster` 数据面(消费者=SW7 switcher)。
- register(tty):agent switcher teammate 视图 / idle 阻塞实时消息提示 / peer-DM summary。

## 7. 进程外 teammate + 隔离(SW6)

`packages/coding/src/swarm/teammate_process.zig`

- **`--teammate` runtime**:身份 CLI args(--agent-name/--team-name/--parent-session-id/--teammate-lease-id/--teammate-cwd);worktree chdir + **同步更新 app.cwd_abs/project_dir**(光 chdir 没用,工具用 cwd_abs 解析路径);mailbox 消息循环(waitForWork 镜像 in-process);fail-closed 权限。
- **lead-spawn**:`--teammate-mode process` → Task(name) 走 `spawnTeammateProcess`(createWorktree `git -C repo` + 登记 member `backend_type=process`/worktree_path + `forkExecTeammate` fork **零分配**只 async-signal-safe + 追踪 `process_teammates` 供 deinit kill+removeWorktree)。
- **任务 prompt**:`spawnTeammateProcess` 在子进程起来之后，把 `Task` 的 prompt 以 lead 的身份(会话 + 租约，和 SendMessage 一样)投进它的收件箱，子进程的消息循环一上线就读到；投递失败时和 spawn 失败一样 kill+reap 子进程、撤销成员登记。
- **线路继承**:子进程不在自己的 worktree 里按启动顺序重新选线路。`SwarmContext.teammate_args` 是宿主往每个进程 teammate 命令行追加参数的口子,只管追加,不认识线路;不设时参数和以前一样。CLI 的 App 在 spawn 时给出 lead 当时生效的线路:`--provider`、`--channel`、`--model`(`/model` 切过就是切过之后的),有推理强度时加 `--reasoning-effort`;交 key 时,lead 当前的端点确实是由命令行 `--base-url` 算出来的(main 只在最终端点由这个参数得出时才记下它,存下的默认把端点换成别家的就不记),再加 `--base-url`。不交 key 就不加,免得 teammate 拿自己找到的凭据发到 lead 的端点。子进程按启动顺序第 1 级(命令行点名)解析,所以 `"global_default": false` 时也能起来。lead 没有线路(unbound)时不加参数。`Task` 点名的模型和推理强度接在这些参数后面(`--model`、`--reasoning-effort`,命令行后出现的为准);只点名模型、没有强度时去掉 lead 的强度,和进程内 teammate 一样用模型自己的默认。
- **key 交接**:lead 当前请求用的 key 还是它启动时经 `--api-key` 或 `METACODES_API_KEY_FD` 拿到的那一把(`/model` 换了厂商、`/login` 换了 key 就不是;换回来又是),而且 teammate 线路点名的厂商(`--provider`)就是这把 key 启动时归属的厂商(启动时没点名厂商的,归 Metask)时,宿主经 `teammate_args.handedKey` 把 key 交给 spawn。线路没点名厂商、或点名的是别家,都不交。`forkExecTeammate` 在 fork 前建一条两端都 CLOEXEC 的 pipe,写进 key 后关掉写端;子进程里把读端 dup2 到 3(新号不带 CLOEXEC),命令行加 `--teammate-key-fd 3`。子进程在 main 里一解析完参数就读完这个描述符、关掉它,然后才起别的进程;读到的 key 当作 `--api-key` 用,所以环境变量或 `.env` 里的 Metask key 盖不过它,子进程的环境也不用再删 `METASK_API_KEY`。key 超过 4096 字节就不交,teammate 照样起、自己找凭据。key 不进命令行,也不进环境变量;子进程的环境里永远没有 `METACODES_API_KEY_FD`,lead 自己用它启动时留下的、已经读完的旧号不再传下去。Windows 不支持进程外 teammate(`forkExecTeammate` 返回 `Unsupported`),也就没有句柄继承。
- **Task 点名的模型**:只在 lead 的线路点名了厂商(`--provider`)或端点(`--base-url`)时才交给进程 teammate。两样都没有时,子进程会按模型名猜厂商和默认端点(`inferProviderKind`),key 可能被发到别家,所以 `spawnTeammateProcess` 在建 worktree、登记成员之前就拒绝,`Task` 工具把原因告诉模型。进程内 teammate 只换模型名、不换厂商和端点,不受影响。Metask 线路上只点名模型、没有强度时,子进程会补上 Metask 登录时存下的强度,不是模型自己的默认。
- **`METACODES_API_KEY_FD` 只在启动顺序第 1 级读**:`--provider`、`--offer`、`METACODES_PROVIDER` 点名 Metask 之外的厂商时,main 读一次,当作命令行给的 key 用,和 `--api-key` 或 `METASK_API_KEY` 同时出现就按二义拒绝。点名 Metask 时由 `auth.zig` 读:`--api-key` 或 `METASK_API_KEY`(默认的 api-key-first 下)排在前面,描述符就不读;存有 Metask 会话又没给 `--base-url` 时,key 发到会话记下的网关。第 5 级(历史路径)照旧由 `auth.zig` 读。preset、目录记住的 preset、存下的默认选出来的厂商用它自己的 key,不读描述符。没读的描述符在 main 一开始就设上 CLOEXEC,工具、MCP、LSP 这些子进程都继承不到。
- **进程启动绑定**:父 session 在 `App.init` 之前注入子进程配置，保证 KG、prompt、权限
  和 transcript 从第一帧就使用同一个 session；子进程另生成独立的 agent identity，避免把
  协调身份和会话路由身份混用。team 名必须是 canonical sanitized 形式，成员从持久化配置
  被删除、换绑或 cwd/worktree 改变后，进程在启动和下一次轮询前 fail closed；指定的
  worktree 无法 chdir/realpath 时也直接退出，绝不降级到 lead cwd。spawn 后尚未登记成功
  时的子进程会被 kill+reap，避免留下无主进程。
- **沙箱**:teammate 进程用同 App/同 Bash 工具,settings 开沙箱则自然套 `wrapCommand`:macOS 走
  Seatbelt,Linux 走 bubblewrap(`packages/guard/src/sandbox/bwrap.zig`;此前"Linux bubblewrap 不做"的用户指令已由用户
  撤回,后端已实现)。
- register SW7:真 fork+exec e2e / 进程外 teammate 的沙箱包裹验证。

## 7b. 宿主调度 teammate(AgentCore,issue #277)

`packages/coding/src/swarm/context.zig`(`Scheduler`/`SpawnRequest`/`pending_spawns`)、
`packages/coding/src/swarm/tools.zig`(`executeSpawnTeammate`/`writeTeamDescription`/`pollLeadInbox`)、
`packages/session/src/core/agent_session.zig`(`RuntimeConfig.enable_teams`/`SessionConfig.team`)。

CLI 的 teammate 是进程内线程或进程外 worktree(SW1/SW6),由 metacodes 进程自己调度。
嵌入式 AgentCore Host 不一样:它自己掌握进程与会话生命周期,AgentCore **不替它起任何
teammate**。于是引入第二种 `SwarmContext.scheduler`:

- **`.in_process`**(CLI 默认):`Task(name=…)` 起线程/进程,维持 `teammates` registry。
- **`.host`**(AgentCore):`SpawnTeammate`(新 team 原生工具)不起线程,只把一条
  `SpawnRequest{name,prompt,agent_type,effort}` 记进 `pending_spawns`(按 name 去重、原位
  替换),然后返回 `{"teammate","backend":"host","status":"requested"}`。lead 不持
  registry(`teammates == null`)。

Host 侧闭环:`RuntimeConfig.enable_teams` 把 team 工具(`TeamCreate`/`TeamDelete`/
`SendMessage`/`SpawnTeammate`)放进目录;lead 和 member 都用 `SessionConfig.team`
(`TeamConfig`,lead/member 角色)加入——member 在创建时即幂等加入名册并建收件箱。lead 跑完一轮后,
Host 用 `writeTeamDescription` 读 `pending_spawns`、为每个待处理请求创建并运行一个 member
Session,再用 `pollLeadInbox` 把 lead 收件箱的下一条消息喂给它的下一轮 Run。team 成员由
Host 在 create/restore 时提供,不进 checkpoint(与 model_capabilities 同理)。AgentCore 的
`team` 表(`describe`/`poll`)就是这一对操作的 C ABI 封装(见 `AGENTCORE_BINARY_ABI.md`
"Teams")。`core/session_host.zig` 的 `SessionHost` 替宿主做了后半件(#445):lead 空闲且
team 已建时,driver 至多每 `lead_inbox_poll_ms`(500 ms,与 daemon 的 `LeadMail` 同)
`pollLeadInbox` 一次,把回信排成 lead 的下一轮 Run。配了 `Options.teammates`
(`TeammateFactory`)时它也做前半件,对应 daemon `App` 的 `.in_process` 调度:lead 每跑完
一项,driver 按先后取出 `pending_spawns`(`SwarmContext.popPendingSpawn`),向宿主的
`configure` 要 member 的 `SessionConfig`(provider/工作区/工具/权限归宿主,`team` 必须为
null),以 lead 的 session id 和新 lease 作为该 team 的 member 在同一个 SessionHost 上
`open`,并把请求的 prompt 作为它的第一轮 Run 提交;同名且仍开着的 member 收到的是下一轮
Run。lead `close` 时一并关闭它开的 member。未配 factory 时请求照旧挂起,由宿主自己 `open`。
`TeammateSpawn` 同时带上 lead 当前的 `lead_model`/`lead_permission_mode`/
`lead_reasoning_effort`(lead driver 上读取,已含此前排队的命令);`InheritLead`
就是 daemon 要用的 factory:宿主给出开 lead 用的 base 配置,member 取 lead 当前的 model
与权限模式,effort 取请求的 `effort`,否则沿用 lead 的,与 `App` teammate 继承 lead 的
provider/model/权限上下文一致(`agent_type` 不解释)。同名 member 若已被宿主关闭,driver
先按 lead session + 旧 lease 把名册里的旧条目摘掉(否则新 lease 入册被拒),再以新 lease
重开,旧 member 的迟到邮件仍不可寻址,对应 `App` 回收已终止 teammate。spawn 失败不再只记
日志:失败以 `<teammate-status from="<name>" state="failed">teammate was not started:
<error></teammate-status>` 作为 lead 的下一轮 Run(`user_message` 带 `source`
`session_host`、`kind` `teammate_spawn_failed`),对应 `App` 下该失败就是 spawn 工具的结果;
同名 member 仍开着却拒收 prompt 时文字为 `teammate did not take the prompt: <error>`。
`App` 下这类失败是同一轮 Run 内的工具结果,受 `max_turns` 约束;这里每次报告都是新一轮
Run,所以报告不链式触发:履行"失败报告 Run"自身的 spawn 时再失败只记日志,模型反复
spawn 一个起不来的名字最多多花一轮。

与 in-process 共用同一套文件邮箱与名册语义,两条路径逐份核对安全属性(SW1 `waitForWork`
vs host `pollLeadInbox`)。

## 8. 真模型 e2e(SW7)

- 真 glm 模型 headless e2e:`TeamCreate`(→ team demo 建成)+ `Task(name=helper)`(→ 真 teammate 线程 `helper@demo` spawn),两工具 `tool.exec done` 成功。**e2e 抓到并修真 bug**:headless 未接 `.swarm`(只 REPL 接)→ SwarmUnavailable;修后端到端 PASS。
- 每阶段:MockServer 确定性组件测试 + 真 tinykg(租约互斥/worktree)+ 真 git(worktree)+ Linus/PM 双 review。

## 9. 与 cc/codex 对照

- **cc(teams)**:同款 name@team 身份 + 文件邮箱 + 结构化协议信封 + 共享任务列表自领。metacodes 邮箱格式与 cc interop(camelCase)。差异:metacodes 用 tinykg DAG 替代 cc 的平面任务文件(原子租约 + readiness)。
- **codex(多 agent)**:线程 + 单 AgentControl + 语义 = 进程内。metacodes 进程内(SW1)对齐;额外做进程外(SW6)为 cwd/worktree 隔离(codex 靠 environments,不做 worktree)。

## 10. 已知边界 / 差距矩阵

| 项 | 状态 |
|----|------|
| Linux bubblewrap 沙箱 | 已实现(`packages/guard/src/sandbox/bwrap.zig`,与 Seatbelt 同一份 `SandboxSettings`;原"排除"指令已撤回) |
| permission 代理(teammate→lead 弹框) | register SW7(当前 fail-closed 安全) |
| mode 响应 from-gate | register(消费者建时补) |
| 真 fork+exec 进程外完整 e2e | register SW7(干净进程 harness) |
| agent switcher teammate 视图 | register(tty) |
| lease TTL 续期(长任务>7200s) | register |
