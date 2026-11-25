# metacodes-core — 内部架构参考

> 面向 metacodes 仓库内部维护者，说明 TUI、Web、daemon 等 frontend 与 core 的模块边界。
> 本文是**内部架构契约 + 设计不变式**参考；第三方接入见 `doc/LIB_API.md`。
>
> 字段级 API 以源码为准（本次审计更新于 2026-08-24）；模块名 `metacodes-core`,
> 本文仅描述仓库内部模块边界，不是第三方稳定源码 API。外部 Host 可选择源码级
> `metacodes-core` 或预编译 AgentCore bundle；交付契约见 `doc/LIB_API.md`。
> 版本常量 `lib.VERSION` 单源自 `src/version.zig`,与 `build.zig.zon` 的一致性
> 由 `zig build test` 用真实二进制的 `--version` 输出强制。

---

## 1. 定位:core 是 agent 平台内核

metacodes-core 是一个**无 UI、无 CLI** 的 LLM 编码-agent 引擎。它把"对话 → 调 Claude API →
执行工具 → 回灌结果 → 再对话"这个循环连同工具集、权限、subagent、持久化封装成库,**所有前端
表达(终端/GUI/语音/IM/…)都由 core 之外的 backend 提供**。

一句话契约:**你实现一个 `UiBackend`(2 个函数指针),把它 + 一个 `Conversation` + 一个
`Client` 交给 `agent_loop.run()`,core 就跑完整 agent 回合,所有"该显示什么/该问用户什么"
经协议事件交给你的 backend。**

### 1.1 四条 load-bearing 设计不变式(前端开发者必须知道)

1. **core↔UI 隔离**。`src/lib.zig` 的 import 闭包不得进入应用侧(`repl/`、`web/`、
   `daemon/`、`app/`、`main.zig`、`app.zig`、`session_service.zig`、`session_intent.zig`)。
   `zig build test:lib` 只证明库能单独编译:惰性分析不编译没人调用的 import,证明不了隔离。
   `zig build subsystem:boundary`(`scripts/subsystem_boundary_gate.zig`)在源码层沿每条
   `@import`(含函数体与 test 块)检查这条规则;现存的几条边记在只减不增的 baseline 里,
   `src/core/` 没有 baseline。前端再多,core 不被污染,core 不依赖任何前端。
   同一个 gate 也管反方向的一条(#445):`apps/cli/src/daemon/`、`apps/cli/src/web/` 下的文件不得直接
   import `src/core/agent_loop.zig`(宿主经 `core/session_host.zig` 驱动内核),现存的两条
   (`daemon/app_driver.zig`、`web/session.zig`)记在只减不增的 baseline 里。

2. **窄腰协议(narrow waist)**。core↔UI 全部走 `UiBackend` 的 **emit/poll 两个函数指针** +
   一个**全可序列化**的 `CoreEvent`/`UiEvent` union。无指针、无闭包穿过协议 → 同一协议可进程内
   (直调)也可进程外(序列化经 WebSocket/gRPC,见 §6.4)。

3. **thread-per-session**。`run()` 不假设主线程——调用方在哪个线程跑,它就在哪跑。一个 backend
   实例可多路复用 N 个 session(emit/poll 带 `SessionId` 路由);N 个并发对话 = N 个 `run()`
   线程。同步阻塞(如等用户答话)只阻塞该 session 自己的线程,不影响其他 session。

4. **类型安全的接线面**。core 需要回调到宿主的地方(进度、token、UI 请求、skill 激活、worktree)
   全部是**接口 struct**(`{ctx: *anyopaque, fn}` + method),不是裸函数指针对——接错配对编译失败,
   不会运行时 UAF。

Lean 治理 kernel 是这个边界的固定外部裁决面：发布时放在 `bin/` 旁的
`libexec/metacodes/`，运行时先看环境变量路径与摘要配对，再看相邻文件及编译进二进制的摘要；
`metacodes doctor` 会同时报告 formal kernel 与 project kernel 的路径、摘要和 provenance，两者的
provenance sidecar 各按自己的 artifact schema 校验（formal v4 manifest + build receipt 走
`formal/provenance.zig`，project v6 manifest 走 `formal/project_provenance.zig`），拿错 loader 即 `provenance=false`。tinykg/tinykgd 旁的打包回执（`<name>.provenance.json`）同样被核对：记录的摘要、角色、版本行和存储契约必须对得上这个文件，否则 `provenance=false`，`--strict` 失败。

---

## 2. 模块地图与依赖方向

目标是依赖**单向向下**、包之间无环。**现在还没做到**:除 `agentcore` 外,产品包都在同一个环里。
分层以仓库根目录的 `layers.zon` 为准,从低到高:

| 包 | 现在的路径(按前缀归属,长前缀优先) | 可以 import 的包 |
|----|------------------------------------|------------------|
| `base` | `util/` · `platform/` · `symbols/` · `highlight/` · `code/` · `version*` · `release_contract` · `api/model_name` · `tools/test_tmp` | 无 |
| `ai` | `api/`(`model_name` 除外) · `provider/` · `client` · `types` · `json` · `preview` · `core/` 里的 `auth` · `recorder` · `context_pressure` | base |
| `kernel` | `core/` 里的 `conversation` · `message` · `session_id` · `result_budget` | base、ai |
| `guard` | `permission*` · `sandbox/`(`filesystem` 除外) · `formal/`(`task_audit` 除外) · `core/` 里的 `workspace_policy` · `tool_result_artifact` · `answer_queue` · `shell` · `shutdown` · `memory/memdir` · 工具观测与规则影响证据(`execution_effect` · `run_recovery` · `prompt_sections` · `tool_observation_journal` · `project_rule_spec` · `rule_impact_stats` · `rule_impact_evidence` · `rule_impact_receipt` · `rule_impact_aggregate_receipt`) · `protocol/` 里 `PermissionContext` 的字段用到的 `ui_event` · `ui_request` · `permission_choice` · `tools/` 里的 `common` · `observation` · `mcp/naming` · `skills/active` · `skills/runtime/policy_frame` | 以上各包 |
| `coding` | `core/` 其余文件(含 `agent_loop` · `tool_exec` · `protocol/` 其余文件) · `tools*` · `skills/` · `agents/` · `mcp/` · `kg/` · `lsp/` · `jev/` · `swarm/` · `telemetry/` · `plugin/` · `sandbox/filesystem` · `formal/task_audit` · `api/model_name_consumers_test` | 以上各包 |
| `session` | `core/agent_session` · `core/session_host` | 以上各包 |
| `teamwork` | `teamwork/` | 以上各包 |
| `facade` | `lib.zig`(`metacodes-core` 的对外门面,汇总导出以上各包) · `internal.zig`(cli 访问下层的唯一入口,不对外) | 以上各包 |
| `agentcore` | `agentcore/` | 以上各包 |
| `cli`(前端,不在 core 里) | `repl/` · `web/` · `daemon/` · `app/` · `main` · `app` · `session_service` · `session_intent` | 以上各包 |
| `testing` / `tests` | `tests/_harness/`、`tests/helpers/` / 其余 `tests/` | 产品包;`tests` 还可以用 `testing` |

`zig build layer:check`(在 `gate:static` 里)检查:每个文件都有归属;每条 `@import`(包括 test 块里的,
named module 按写下它的源文件算)和 `build.zig` 里每个 module 的 import 都在 `allowed_dependencies` 里;
包之间无环;不深层 import 别的包的文件;module 根目录不覆盖它不能依赖的包。现状逐条文件边记在
`layer_baseline.zon`,**只减不增**:新违规会失败,已经消失的条目也必须删掉;CI 还会和 PR 的合并基线比较
(`-Dlayer-base=<ref>`),白名单变多、kernel 预算放宽或 `allowed_dependencies` 变宽都会失败。
调整分层(拆包、改归属)的 PR 单独提。拆包后暴露出来的边,只有基线代码里本来就有、而且按基线清单两端在同一个包里,才不算新增;
upward 条目必须在基线的 upward 里,deep 条目可以来自基线的 upward 或 deep。一个包可以新依赖基线里没有的包,
前提是新包依赖的包它原来都能访问,新包的每个文件在基线代码里都已存在于同一路径、在基线清单里有归属,而且它原来就能访问那个包。
从基线以来挪动过的文件(git 识别出的改名)按它在基线里的路径比较:upward 条目必须是基线里的 upward,
deep 条目可以来自基线的 upward 或 deep,也可以是基线代码里两端同包的 import。
`kernel_budget` 限定 kernel 的行数和它依赖的包。检查会打印「包 → 包」的违规数,作为迁移进度表。
建立时(2026-11)的现状:

| 违规 | 数量 |
|------|------|
| 越层 import(文件到文件) | 183:kernel → coding 90、guard → coding 34、session → teamwork 24、ai → coding 14、kernel → guard 7、base → ai 6,其余 8 |
| 深层 import(文件到别的包的文件) | 2133 |
| 包间环 | 1 个:base、ai、kernel、guard、coding、session、teamwork、cli |
| module 接线 | 0 |
| 根目录过宽的 module | 6:`lib.zig` 和 `provider`/`mcp`/`lsp` 的测试隔离根、`sandbox_helper_root`、`release_contract` |
| kernel | 17852 行,依赖 base、ai、guard、coding |

迁移 1.1 把 `lib.zig` 从 `session` 拆成 `facade` 后:越层 import 159(`session → teamwork` 24 条和
`session → cli` 2 条消失,剩 `facade → cli` 2 条),深层 import 2159(`lib.zig` 对 teamwork 和 session 的 26 条导出)。

迁移 1.2 清掉下层指向 `cli` 的 6 条边:`app/config.zig`、`app/doctor.zig` 移到 `core/file_config.zig`、`core/doctor.zig`
(`lib.zig` 仍导出为 `config`、`doctor`);`version_info` 直接读 `release_contract.CONFIG_SCHEMA_VERSION`;
`swarm/teammate_process` 和 `teamwork/command` 改用 cli 注入的窄接口(`teammate_process.Host`、`command.AppHost`)。
越层 import 153,深层 import 2163,包间环缩成 base、ai、kernel、guard、coding。

迁移 1.3a:cli 只经 named module `metacodes-internal` 访问下层。它的根文件 `src/internal.zig` 归 `facade`,
按目录层级重新导出 cli 用到的 371 个下层文件(`@import("metacodes-internal").core.agent_loop`),不进
`metacodes-core`,Zig API 快照不变。cli 里再写相对路径 import 下层文件,同一个文件会落进两个 module,编译不过,
`layer:check` 也会报新的深层 import。下层的 named module(`platform`、`hl`、`code_runtime`)只接在这个 module 上,
cli 用 `platform` 也写成 `@import("metacodes-internal").platform`。cli 的 844 条深层 import 清零,换成 `internal.zig` 的 371 条:越层 import 153,
深层 import 1690,根目录过宽的 module 7 个(新增的 `internal.zig` 和 `lib.zig` 同包、同目录)。下层文件的测试改在
`internal-test` 里跑(根是这个 module),`cc-test` 只跑 cli 自己的测试。

迁移 2.2 清掉 `ai → coding`、`base → ai`、`base → coding`:`types.zig`、`json.zig`、`preview.zig`(消息、请求和
provider 配置的类型)和 `core/auth.zig`、`core/recorder.zig`、`core/context_pressure.zig` 改归 `ai`,纯字符串的
`api/model_name.zig` 改归 `base`,`api/model_name_consumers_test.zig` 改归 `coding`,路径都不变;`file_lock` 用的 stat、
`codex_usage`/`openai_client` 用的日期和时区计算、`controller_git` 用的子进程捕获下沉到 `platform`
(`fs.statFd`/`statPath`、`timezone.civilDate`/`formatOffset`/`boundedLocal`、`process.captureWithSpawnRetry`/`describeArgv`),
`read_state`、`time_context`、`tools/common` 的公开声明不变,改为调用它们。越层 import 130,深层 import 1665,包间环缩成 kernel、guard、coding。

迁移 2.1 清掉 `guard → coding` 的 34 条边,只改归属,不搬文件:一个文件的 import 闭包已经都在目标包或更低的包里,就把它
单个归到那个包,路径和 `lib.zig`、`internal.zig` 的名字都不变,Zig API 快照和测试 ID 不变。归到 `guard` 的有
`tools/common`、`mcp/naming`、`core/shell`、`core/answer_queue`、`core/shutdown`、`memory/memdir`、
`skills/active` 和 `policy_frame`,以及 `project_harness_runtime` 读的工具观测与规则影响证据这 10 个文件;`tools/test_tmp`
只给测试用,归到 `base`。反过来,以 `ToolContext` 为参数的工具实现 `sandbox/filesystem`、`formal/task_audit` 归到 `coding`,
沙箱机制(`exec`、`config`、`filesystem_helper`)和 formal 检查器仍在 `guard`。代码改了两处:`ToolExecutionPolicy`
挪到 `permission/category.zig`,`tools/context.zig` 用别名保留,`policy_frame` 不再 import `tools.zig`;`hashCwd` 的实现挪到
`platform.paths`,`transcript.hashCwd` 签名不变、转调它,`memdir` 直接用它,`transcript` 留在 `coding`。越层 import 94
(`guard → coding` 清零,`kernel` 对 `test_tmp` 的 2 条也随之消失),深层 import 1804(新增的 154 条都是基线代码里已有的 import:147 条原在同一个包里,7 条原是越层 import)。

迁移 3.1 按 pi 的分法重新划定 kernel。pi 的 `pi-agent-core` 只有一个最小的 `agentLoop`,外设靠钩子接入,带全套外设的
`AgentSession` 在 `pi-coding-agent` 里。metacodes 现在的 `agent_loop`(`Options` 带 kg、jev、telemetry、swarm、skills 等全部外设)
和 `tool_exec`(直接调 apply_patch、read_artifact、kg、project_rule)就是这个「全套外设循环」,`protocol/` 是宿主协议,所以它们改归
`coding`,对应 pi 的 `AgentSession`;最小内核循环在 3.2 抽进 kernel,`agent_loop` 再逐步改为调用它,`Options` 不变。kernel 现在只有
`conversation`、`message`、`session_id`,加上 `conversation` 用来算单条工具结果上限的 `result_budget`(它对 artifact 读取上限的
引用改成私有常量,`tools/read_artifact.zig` 里的测试保证两者相等)。`code/`(QuickJS 引擎的 Zig 包装,只依赖 std)改归 `base`。
`protocol/` 里 `ui_event`、`ui_request`、`permission_choice` 是 `PermissionContext` 公开字段的类型,改归 `coding` 会让 `guard`
新增越层边,所以归 `guard`;`AskQuestion`、`AskOption` 挪到 `ui_request.zig` 定义,`tools/context.zig` 用别名保留,`ui_request`
不再依赖 `tools/context`。路径、Zig API 快照、测试 ID 都不变。越层 import 94 → 5,深层 import 1799,kernel 3264 行,依赖 base、ai、coding。
包间环 kernel、guard、coding 还在,剩下的 5 条越层边都卡在 Zig API 快照里的公开类型上:`conversation → result_projection` 1 条
(`Conversation` 的 microcompact、截断等公开方法要认得 artifact 信封),`ui_event → file_change`、`file_reference`、`goal`、
`output_semantics` 4 条(`CoreEvent` 的载荷类型)。在 3.2 抽最小循环时一并处理。

`lib.zig` 是唯一对外面,按命名空间 re-export。分组:引擎 / API·client·配置 / 工具 /
权限 / agents·skills·mcp·sandbox / **协议** / 参考 backend / 工具库。

### 2.1 模块职责速查

| 模块 | 职责 | 关键导出 |
|------|------|----------|
| `agent_loop` | 一个 agent 回合的完整循环(带全套外设,属于 `coding`):流式请求→收 tool_use→执行→回灌→再循环 | `run()`, `Options`, `RunResult`, `StopReason`, `UsageSink`, `ProgressReporter` |
| `conversation` / `message` | 对话状态(messages → blocks);压缩/microcompact | `Conversation`, `Message`, `Block`(text/tool_use/tool_result/thinking/image/reasoning_item) |
| `subagent` | 父 agent spawn 子 agent(隔离 Conversation + TaskStore) | `spawnAgent`, `spawnAgentSink`, `SpawnOptions`, `SubagentResult` |
| `tool_exec` | 工具批量执行(按并发安全分批;每 job 独立 arena + per-worker 值拷贝 ctx) | `executeSlots`, `Slot` |
| `tools` | 工具注册表 + dispatch(静态 + 动态 Skill/MCP) | `dispatch`, `registry`, `isConcurrencySafe(Input)` |
| `tools/context` | `ToolContext`——工具执行时拿到的全部依赖 + 接口回调 | `ToolContext`, `SkillActivator`, `ToolActivator`, `WorktreeHook`, `ToolProgressReporter` |
| `transcript` | 对话持久化(JSONL per-turn)+ 重建 | `Writer`, `loadTranscript`, `sessionDir` |
| `session_id` | session 身份值类型(多 session 基石) | `SessionId`, `.single`, `gen()` |
| `permission*` | 权限决策链(模式 + 规则 + 沙箱 + UI 请求) | `PermissionContext`, decision/settings/session_rules |
| `agents` / `skills` / `mcp` / `sandbox` | subagent 定义 / Skill / MCP 客户端 / Seatbelt / bubblewrap 沙箱 | `AgentSet`, `SkillSet`, `mcp_client`, `sandbox_config` |
| registries | task/job/agent_job/cron 的运行时态 | `TaskStore`, `JobRegistry`, `AgentJobRegistry`, `CronRegistry` |
| `client` / `api/stream` | Anthropic HTTP + SSE 流式 + 重试 | `Client.init(WithBaseUrl)`, `sendMessageStreamFull`, `UsageDelta` |
| 参考 backend | 库自带非-UI 前端(可直接用或当模板) | `WriterBackend`(打印型), `HeadlessBackend`(CoreEvent→JSON) |

---

## 3. 协议契约(前端开发者的核心)

实现一个前端 = 实现一个 `UiBackend`。三个文件就是全部契约:
`core/protocol/{ui_backend, ui_event, ui_request}.zig`。

### 3.1 UiBackend — 窄腰

```zig
pub const UiBackend = struct {
    ctx: *anyopaque,
    /// core→UI:消费一个 CoreEvent(归属 session)。同步——返回时 ev 的 borrow slice 即失效,
    /// 后端必须在返回前拷走需保留的字节。
    emit: *const fn (ctx: *anyopaque, session: SessionId, ev: CoreEvent) void,
    /// UI→core:非阻塞拉取该 session 的一个用户事件;无则返 null。
    poll: *const fn (ctx: *anyopaque, session: SessionId) ?UiEvent,
    pub inline fn emitEvent(self, session, ev) void;
    pub inline fn pollEvent(self, session) ?UiEvent;
};
```

- **emit 是 push(core→UI)**,**poll 是 pull(UI→core)**。tick(spinner 等定期刷新)**不进
  vtable**——前端自己起 timer/线程(TUI=tick 线程,GUI=requestAnimationFrame,语音=无 tick)。
- **借用切片纪律**:emit 的 ev 内所有 `[]const u8` 在 emit 返回后失效。in-process 后端立即拷进
  自己的缓冲;out-of-process 后端在 emit 内同步序列化(CoreEvent 全可序列化,见 §6.4)。
- **线程性**:emit 可能在 agent_loop 线程或工具 worker 线程被调(`tool_progress` 跨线程);后端
  实现自负线程安全(TuiBackend 内部持 RenderRegion 锁)。

### 3.2 CoreEvent — core 告诉前端"发生了什么"(语义事件,非渲染指令)

```zig
pub const CoreEvent = union(enum) {
    text_chunk: []const u8,                      // 助手文本流(增量)
    stream_begin,                                 // 一轮助手输出开始
    stream_done,                                  // 一轮助手输出结束
    tool_start: struct { id, name, input },       // 工具开始执行
    set_current_tool: struct { name },            // 当前工具(喂底部 spinner 语义)
    tool_progress: struct { id, text },           // 工具执行中进度(按 id 路由)
    clear_current_tool,                           // 本轮工具执行完
    tool_result: struct { id, name, input, content, is_error, elapsed_ms }, // 工具完成
    usage: UsageDelta,                            // token 计数增量
    phase_change: Phase,                          // input ↔ generating
    auto_compact: struct { dropped, kept, before_tokens, after_tokens, cause }, // 自动压缩历史;cause 以 context_window_exceeded_ 开头的是恢复,不是压缩
    retry_notice: struct { attempt, max, delay_ms }, // 流式建连重试
    input_adopted: struct { input_id, sequence, turn }, // Session 活动 Run 的 Host 输入已进对话(§3.3,#270)
    ui_request_pending: struct { tool_use_id, request_json }, // 可挂起 UI 请求(异步前端,见 §5.3)

    // 输出语义(见 §3.2.1)
    output_segment_begin: struct { index, turn, group },
    output_segment_end: struct { index, turn, group, disposition, bytes },
    thinking_discarded: struct { index, turn, group, bytes }, // 被重发的尝试流出的 thinking 撤回(#452)
    // 文件修改结果(见 §3.2.2)
    file_changes: struct { id, name, changes, overflow, lost },
};
```

**关键认知:这些是语义事件,不是终端指令**。`stream_begin` = "助手文本开始"(语音前端可据此起
TTS 会话、LED 可亮灯),`set_current_tool` = "正在执行某工具"(语音可播报、按钮设备可亮工作灯)。
命名带历史 TUI 味,但语义中立。**前端只处理自己关心的变体,其余 `=> {}`**(参考 WriterBackend
no-op 了 set_current_tool/tool_progress/usage 等)。新增变体不会破坏现有 backend(各自 no-op)。

#### 3.2.1 输出语义:哪段文本才是答案(`core/output_semantics.zig`)

`text_chunk` 只说"有文本到了";`stream_done` 只说"一次 provider stream 结束"——**它从来不是
完成信号**(每轮工具调用、每次续写、每次流内重试都会发一个)。前端若只看这两者,必须自建
"什么算 final"的状态机,而且每个前端会得出不同答案。

core 因此把它**已经知道**的判定发出来。一个 **段** = 一次 provider stream 的可见文本,
`output_segment_begin` 开、`output_segment_end` 关(严格配对,至多一个打开),关闭时带定性:

| disposition | 含义 |
|-------------|------|
| `commentary` | 可见过程信息(本轮跟着工具调用,或主机拒绝了这次"过早的最终答案") |
| `final` | Run 的完成结果 |
| `continued` | 被 max_tokens 截断,与**同 `group`** 的下一段合成一个结果 |
| `partial` | 可见但未完成(abort / 预算终止 / 二次拒绝 / 续写额度用尽后仍被截断) |
| `discarded` | 从未进入 Conversation(流内失败回滚),前端须丢弃已缓冲的该段字节 |

`index` 在 Run 内单调,**被丢弃的段也占一个索引**("回滚过"与"没发生过"必须可区分)。
`thinking_chunk` 不属于任何段——思考永不进入结果。但它总在本次 stream 的段打开期间到达,所以
同轮重发(请求自带的那一次或 `retractable_stream_retries` 准许的)撤回一个流出过 thinking 的尝试时,在该段 `discarded` 之后
紧跟 `thinking_discarded`(同一段的 index/turn/group 与 thinking 字节数):前端丢弃该段打开期间
到达的 thinking,与丢弃该段文本同理(见 §7 流内重发那一条)。

不想消费事件的调用方挂 `Options.output_ledger: ?*output_semantics.Ledger`,run() 返回后直接
`ledger.finalText()` / `partialText()`(续写组已拼好)。**账本不传给 subagent**:子 agent 的
输出是父 Run 的工具结果,不是父 Run 的答案。

**进度更新义务(#114,`core/progress_updates.zig`)**:定性只回答"这段文本是什么",回答不了
"为什么一段文本都没有"——模型可以一轮接一轮只调工具不说话,用户只剩工具生命周期事件,看不出
阶段、发现与下一步。`run()` 因此观察每一轮:用户看到的模型文本(非空白字节;thinking 与 host
渲染的装饰不算)结束沉默段,只调工具不说话的一轮让沉默段长一轮,沉默段还有一个从上次可见文本起算
的时长。turn 边界上沉默段同时满足 `Options.progress_update_thresholds` 的轮数(`rounds`,默认
`DEFAULT_SILENT_ROUNDS`)与时长(`min_silent_ms`,默认 `DEFAULT_MIN_SILENT_MS`)时,注入一条 host
消息(`[progress update]` 开头)要模型在同一条回复里先用一两句话说明阶段、发现与下一步,再接着干
——每 Run 至多 `MAX_PROGRESS_NUDGES` 次决策,走全局 host 注入计量器(cap = Σ 各门预算,agent_loop
的 comptime 断言钉死),每次决策或任何可见文本之后沉默段归零。回复按上表定性(后面跟工具调用 →
`commentary`;自然 end_turn → `final`),core 不合成任何占位式进度文本,也不触碰最终答案。

它是**宿主契约字段**,与交付节奏门同款:`Options.progress_updates` 默认关,canonical
`buildRunOptions` 不带(宏 run / skill run / AgentCore 不被提醒);有人在看的宿主自己接——REPL 主
run、web 会话、`--stream-json` 的 print 模式(`--no-progress-updates` 关,
`--progress-updates-observe` 只记录不注入);且只对 `event_projection` 认为有人读其 commentary 的
Run 生效(legacy 根 agent、AgentCore 外部 run root)。Run 结束时向 `tool_observer` 发一条
`progress_updates` 终局记录(decisions / nudges / max_silent_rounds / 阈值),评测 trace 据此归因
host 注入。host 注入的 user 记录不是用户原话:agent_loop 的每个注入点(本门、交付节奏、截断续写、
KG/验证/需求账本提醒、后台任务通知、学习轮……)都经 `Conversation.appendHostText` 写入,消息带
`Message.origin = .host`(只进 transcript 的 `"origin":"host"`,从不进请求);
`host_injection_meter.isHostText`(认 origin,也认无此字段的旧记录里的门标记)让 web_search 显示
query、Ctrl+O transcript、resume 回放与 `/recap` 把它们与用户输入分开。策略由
`control-plane/lean/MetaCodesControl/ProgressUpdates.lean` 证明(叙述归零、任一阈值未达不触发、
任意轨迹下决策数有界)。默认系统提示同时新增 "Progress updates on longer tasks" 段,定义多阶段
任务的进度沟通预期(单步任务不要求)。

**停滞闸门(stall gate,`core/stall_gate.zig`,设计说明 [STALL_GATE_DESIGN.md](STALL_GATE_DESIGN.md))**:
进度更新义务管"用户看不到在干什么",管不了"每一步都没带回新东西"。在长上下文、flash 级模型上,
循环不是畸形调用,而是零信息增益的步骤:轮询不出字节的作业、同一命令反复得到同一输出、重读没变的
东西。软提醒在这个区间基本被忽略,所以这道闸门不提醒,而是停。
- **传感**:每个执行过的工具轮次观察一次。真正跑过的 slot 产出调用键 `H(tool,input)`,失败之外还产出
  证据键:落盘的文件改动按动作 `H(tool,input)`,其余按结果 `H(tool,result)`,剔除宿主自己的
  记账数字:BashOutput 的 `waited_ms`,以及轮询守卫每次轮询都会变的 `low_yield_polls` 和
  `min_wait_ms`(字段名保留)。有证据键不在记忆里的轮次是 progress;跑了东西但没新东西的是 stale;
  什么都没跑(拒绝 / 延后 / 挂起)的是 neutral。
- **记忆跟随模型的视野**:每个键锚定到承载它的最新 tool_result 块。块离开视野(压缩移动窗口、
  microcompact 或截断就地改写)即遗忘,重读被清掉的结果算新信息。
- **策略**:连续 `stale_rounds`(默认 8)个 stale 轮,或连续 `repeat_rounds`(默认 4)个 stale 轮且
  其中同一调用出现 `repeat_calls`(默认 4)次,即决策。`stale_rounds == 0` 对任何阈值都不触发,
  每 Run 至多 `MAX_STALL_DECISIONS`(1)次。
- **执行**:enforce 在本轮结果提交进对话之后以 `StopReason.stalled` 结束 Run,不注入任何文本
  (provider 可见字节不变,不走 host 注入计量器)。`RunResult.stall` 带出证据,REPL 打印
  `stall_gate.renderStopNotice`(原因、最常重复的调用、怎么续接)。observe 只记录本该停下的轮次。
- **宿主契约字段**:`Options.stall_gate: ?stall_gate.Mode`,canonical `buildRunOptions` 不带。REPL 主
  run 与 web 会话默认 enforce(有人能一句话续接),headless 默认关(`--stall-gate` /
  `--stall-gate-observe` 开启),`--no-stall-gate` 关闭。
- **记录与证明**:武装时 Run 结束发一条 `stall_gate` 终局记录(`metacodes-stall-gate-v1`)。
  `control-plane/lean/MetaCodesControl/StallGate.lean` 证明任意轮次与遗忘轨迹下决策有界、有新键
  的轮次之后不决策、每轮都带回从未见过的键时永不决策,以及正向:足够长的 stale 段必然恰好决策一次
  (只依赖 propext)。

**学习回合(learning turn,`core/learning_turn.zig` + `kg/lesson.zig`,设计说明
[LEARNING_TURN_DESIGN.md](LEARNING_TURN_DESIGN.md))**:宿主检查门的判定让 Run 结束后,同一段对话把
这次经验写成带条件的 lesson,供下一次同题尝试读取。
- **触发**:根 Run(depth 0)的终局边界,检查门对当前工作区给出 passed / failed 判定时;tainted、
  unavailable、没跑检查都不学;没有就绪的 TinyKG store 时记 `none_unstorable`,不跑任何一段。
  每 Run 至多一次,observe 只记录本该做的决定。
- **两段**:distill 消息带判定、已存的同题 lesson 和宿主绑定的 lesson 头;模型用 `KgRemember`
  kind `lesson` 写至多 4 条(`holds_when:` / `uncertain:` / `lesson:` / 可选 `supersedes:`)。
  只有接受了 lesson 且已有同题 lesson 时才发 reconcile 消息。每段至多 6 个模型轮次。
- **边界**:答案在学习回合开始前已定为 final,学习文本一律是 commentary;学习段里只有
  Read / Grep / Glob / KgRecall / KgContext / KgRemember 能跑,过程传感器与环境故障熔断都不计这些
  轮次。`KgRemember` 在学习回合之外、或 lesson 头与宿主所见不符时拒绝写入;宿主自有、按类型读回的
  其它类型(`kg/reserved_types.zig`:临时规则、撤回、任务义务、结局行、义务遥测、provider 审计、
  本体快照四类)一律拒绝(`ReservedMemoryType`),因为读回方只按类型认节点,分不出作者。
- **宿主契约字段**:`Options.learning_turn: ?learning_turn.Options`(mode、task_hint、run_label),
  canonical `buildRunOptions` 不带。武装时 Run 结束发一条 `learning_turn` 终局记录
  (`metacodes-learning-turn-v1`)。下一次同题尝试(`METACODES_TASK_HINT`)经 scoped recall 看到最新
  且未被取代的 lesson;没有 lesson 时注入逐字节不变。
- **CLI**:`--learning-turn` / `--learning-turn-observe`,print 模式另认
  `METACODES_LEARNING_TURN=enforce|observe`(flag 优先)。必须有判定来源,否则参数错误
  (`main.resolveLearningTurn`):检查门(`--check-gate[-observe]` + `--host-check`,REPL 与
  print 模式的主 Run 武装 in-run 形态,run_label 取 journal run id),或 print 模式下自演化
  host check(`METACODES_HOST_CHECK` + `METACODES_SELF_EVOLUTION=1` + task hint)。
- **收尾形态**(`core/learning_end_of_run.zig`):headless 的 `host_check.runAndIngestWithEvidence`
  之后,仅当尝试自己结束(`end_turn`)且 in-run 回合没有判定(未武装或 `none_unchecked`)时运行:
  一次无工具 provider 请求,受自演化 author 上限约束(max_tokens 先验、usage 与成本后验),
  响应只是证据;宿主按 `KgRemember` 同一套头绑定把信封写成 `lesson` 节点,头不符的信封计入
  refused。distill 与 reconcile 合在这一次请求里,报告记一段。形式化:`LearningTurn.lean`。

**隔离验证者(isolated verifier,`core/isolated_verifier.zig` + `agents/isolation.zig` 的 `Snapshot`,
设计说明 [ISOLATED_VERIFIER_DESIGN.md](ISOLATED_VERIFIER_DESIGN.md))**:钉住检查通过之后,宿主在代码里
起一个全新的子 agent,对照原始任务逐项找证据。它只能降级,不能升级。
- **隔离**:不是 `AgentDef`,同名项目 agent 无法顶替;system prompt 是编译期常量 `CHARTER`(SHA-256
  进记录);唯一的 user 消息是 packet(任务原文、钉住检查与计数、快照路径与 `base`/`candidate` 两个
  ref,第二个边界另带上次 FAIL 的 probe);工具只有 Bash / Read / Grep / Glob;kg、Skills、MCP、宿主
  服务、read state、文件改动账本、后台任务全为 null。工作目录是工作区的 git 快照(临时 index,不碰
  actor 的 index / HEAD / ref / stash;独立仓库经 alternates 读对象;结束后总是删除),绑定树 id **T**,
  返回后重算 T′,不等即 `unavailable`(`workspace_changed`)。
- **判定**:只读最后一条 assistant 消息的最后一个非空行 `VERDICT: PASS|FAIL|UNVERIFIED`;其他以
  `VERDICT:` 开头的行使结果 `unavailable`。每个 `PROBE:` 必须是它真跑过的 Bash 命令的子串,否则 PASS /
  FAIL 降为 UNVERIFIED。基础设施错误(快照失败、spawn 失败、provider 错误、非 `end_turn`、墙钟、无 token)
  一律 `unavailable`,回退到钉住判定。
- **检查门接线**:`Options.isolated_verifier: ?isolated_verifier.Options`(需要 `check_gate`,根 Run,
  canonical `buildRunOptions` 不带)。enforce:FAIL 变成 `failed`(`State.last_source = .verifier`),
  在检查门同一个续跑预算内续跑,续跑消息只引用复现过的证据块;UNVERIFIED 且还有预算时开一轮只读
  leads(至多 3 轮,只跑 Read / Grep / Glob,占一次续跑),再起一个新验证者看同一个 T。observe 只记录。
  每 Run 至多 2 个边界、每边界至多 2 次 spawn,单次 US$0.20、整 Run US$0.60、单次 300 s。
- **收尾形态**:print 模式下检查门未武装时,`host_check.runAndIngestVerified` 在干净通过之后跑一次,
  enforce 在 `host_run` 行上写 `"verifier"` 限定(provenance 不变);`verdict.effectiveRank` 让
  `verifier=fail` 的行同分时排在未受质疑的 `host_run` 之下、`host_run_tainted` 之上。
- **独立入口**:`isolated_verifier.verify(gpa, Deps, VerifyRequest) → VerifyResult`,不依赖检查门
  状态,teamwork 运行时可以直接调用。
- **CLI 与记录**:`--verifier` / `--verifier-observe` / `--verifier-model <model|tier>`,print 模式另认
  `METACODES_VERIFIER=enforce|observe`;没有钉住检查、单独给 `--verifier-model`、或与 `--learning-turn`
  同时开都是参数错误(`main.resolveVerifier`)。武装时 Run 结束发一条 `isolated_verifier` 终局记录
  (`metacodes-isolated-verifier-v1`)。

#### 3.2.1.1 候选响应边界:这条响应能不能进 Conversation(`core/response_candidate.zig`)

段的定性回答"这段文本算什么";候选响应边界回答的是上一个问题——**这条 provider 响应最终
被接受了吗**,以及 runtime policy 有没有机会说不。

一条 provider 响应的生命周期(消费 StreamEvent → 装配 text/thinking/tool_use → 发布可见输出
→ 可能启动 tool 预取 → 组装 assistant message → commit 或丢弃)一直只存在于 AgentLoop 的局部
状态里。外部要在 commit 前设闸,唯一办法是在上游把整条响应缓存下来先判定——AgentCore 的
durable budget 层正是这么做的,代价是首个 content event 必须等整条响应收完(E9)。

`Options.response_observer` 就是那条边界。按顺序:

| 钩子 | 时机 | 语义 |
|------|------|------|
| `begin` | provider 响应开始 | 一个 candidate 打开(`turn` + `attempt`;同轮重发是**不同** candidate) |
| `observe` | 每个 canonical 增量 | text / thinking / reasoning_item / **装配完成的** tool_use;返回 `.reject` 立即停流 |
| `admit` | commit 前最后一问 | 只有收完整条响应才能判定的策略在此回答 |
| `settle` | 决定已作出 | `committed` 或 `discarded`(aborted / stream_error / rejected / empty / run_error) |

`begin` 与 `settle` **严格配对**:任何路径(含 abort、流错误、否决、装配期 OOM)都恰好 settle
一次,所以 observer 可以把 `settle` 当作 `begin` 处预留资源的释放点。

被否决的 candidate 不是错误,走的是与"丢弃的残段"完全相同的路径:可见段以 `discarded` 收尾
(前端丢掉已缓冲字节)、不进 Conversation、**尚未启动的 tool effect 不会启动**(tool_use 在预取
之前就被观察),Run 以 `stop_reason=budget` 结束——policy 否决是确定性的,重发只会再买一次同样
的响应。

observer 为 null 时行为与从前逐字节一致:不观察、不可否决。

#### 3.2.2 文件修改结果:实际改了什么(`core/file_change.zig`)

`file_refs` 只说"碰了哪些文件";`tool_result.content` 里的 `gitDiff` 是**工具私有渲染字段**
(Read 没有、各工具形状不同、结果落盘成 artifact 时会被信封替换)。要展示实际改动请用
`file_changes` 事件,它**无条件发**(证据不是渲染——headless / subagent /
`emit_tool_cards=false` 时同样发)。

**时序**:本轮工具全部执行完后**一次性发**,早于本轮任何 `tool_result`——不是紧邻配对。
挂起(UiPending)、host fatal、结果组装失败都可能发生在盘已经真的改过之后,证据放在所有分支
之前才不会静默丢失。消费者按 `id` 与 tool_result 配对,不靠相邻。

每条 `Record` 带 locator(与 `FileReference` 同一归一化)、`kind`(created/modified/deleted/
moved)、`status`(applied/no_change/failed/rejected/partial)、`tool`+`tool_use_id`(与工具卡
配对)、`agent_depth`(>0 = 子执行)、前后字节数、`unified_diff` 与 `diff_complete`。
事件的 `overflow`/`lost` 表示本次报告不完整;一条记录都没有但报告不完整的调用(复制失败、
Bash 观测没能覆盖)也照发一条空 `changes` 的事件,Run 账本同时标 `truncated`。

`Options.file_change_journal: ?*file_change.Journal` 是 Run 级账本,**经 SpawnOptions 下传给
子执行**(子 agent 的修改仍是本 Run 的修改)。带锁,读用 `acquire()/release()` 成对。
`file_change.writeJsonEnvelope` 是进程外消费者的稳定线格式(`{schema_version, truncated, changes[]}`——版本由模块自己盖,不靠调用方约定)。

**来源有两类。** 类型化文件工具(Write/Edit/NotebookEdit/ApplyPatch)逐文件自报。`Bash`
报不出任意命令碰了什么,所以 Bash 工具对**非只读的前台命令**在执行前后各观测一次工作区
(`core/command_file_changes.zig`),把差异发在同一契约上(`tool = "Bash"`,`status = applied`):

- **怎么观测**:内置 ripgrep 列出工作区文件(它的忽略规则;隐藏文件计入,`.git`/`.hg`/`.svn`/
  `.jj` 排除),逐个 lstat。路径的身份(dev/inode)、大小、mtime、ctime 任一变化即为修改;消失的
  路径与新出现的、inode/大小/mtime 相同的路径配对成 `moved`。Windows 上的 stat 不带文件身份
  (没有 inode,也没有 ctime),只看大小与 mtime,改名报成一条 `deleted` 加一条 `created`。
- **列表的出入不等于文件的出入**:两次列举之间忽略规则可能变了。从列表里消失的路径先 lstat
  确认:文件还在就不是删除(内容变了报修改);新出现的路径若早在观测开始前(留 2 秒时钟余量)
  就没动过——POSIX 看 ctime,Windows 看创建与修改时间——就只是重新可见,不算新建。ripgrep
  遍历出错(退出码 2,例如读不了的子目录)时,列到的照用,并置 `lost`。
- **diff 从哪来**:新建文件读执行后的内容;修改/删除需要"执行前",git 工作区里执行前已与 index
  不同(或未跟踪)的文件预先复制(有上限),与 index 一致的文件事后从 index 取——**仅当命令没动过
  index**(`git add`/`stash`/`checkout` 会把执行后的内容放进 index),且 blob 大小与执行前一致,
  且该路径没有 `filter`、`working-tree-encoding`、`ident` 属性(`git check-attr`;行尾转换与
  `ident` 只要改了字节就改了大小,另外两种可以等长换掉每个字节——UTF-16LE 的 `中\n` 和它的
  UTF-8 blob 都是 4 字节),且命令期间属性与配置的来源都没变(工作区里的 `.gitattributes`、
  根到仓库顶之间各级的 `.gitattributes`、`info/attributes`、`.git/config`)。取不到"执行前"、
  二进制、超大文件:照报这次修改,不带 diff,
  `diff_complete = false`;行 diff 表达不了的末尾换行变化同样如此(只改末尾换行 → 不带 diff;
  任一侧缺末尾换行 → 带 diff 但 `diff_complete = false`)。能证明内容没变的(`touch`、写回
  相同字节)不算修改,也不占单次 64 条的记录上限。
- **git status 不重复问**:哪些文件"执行前已与 index 不同"来自 `git --no-optional-locks status`,
  它从不回写 index,index 的 stat 数据过期时(复制或同步来的工作区)每次都要重新哈希整个工作树
  (#670)。进程记住最近一个工作区上次的答案和当时的 lstat:index、属性来源、工作区里的 `.gitignore`/
  `.gitattributes` 都没变时,lstat 与上次一致、且在上次观测开始前(留 2 秒时钟余量)就没动过的
  文件沿用上次的答案,只把其余文件(最多 256 个、16 KiB 路径)交给 `git status -- <路径>`;一个
  都没有就不调 status。超出上限或上述任一来源变了,照旧问整个工作区。
- **沙箱会话走沙箱**:会话启用沙箱时观测完全不调用 git——沙箱内的命令可以写工作区里的
  `.git/config`,而观测在沙箱外运行 git,被植入的 fsmonitor/clean filter 会越过沙箱执行。此时
  修改照报,只是不带 diff。非沙箱会话里也总带 `-c core.fsmonitor=false`。列举也在沙箱里跑
  (与 Glob/Grep 同一个包装),每条变更发布前先经沙箱文件执行器打开、并核对打开的正是 lstat
  看到的那个文件(bubblewrap 把禁读文件绑成 `/dev/null`),内容也从那个句柄读:沙箱对命令藏起
  来的(`denyRead`),路径、大小、内容都不进事件和账本,打不开的变更不发布并置 `lost`。命令删掉
  或移走的文件已无从再打开,改按观测开始时解析好的 `denyRead` 规则判定(两种后端各自的 `~`、相对
  路径、物理路径解析都算,宁宽勿漏):新旧路径任一落在其下的变更同样不发布并置 `lost`。
  Seatbelt 拒读的目录让列举出错,同样置 `lost`;bubblewrap 把它显示为空的只读目录,命令也写
  不进去。沙箱不可用时整次调用 `lost`。每条变更多一次沙箱进程,开销随变更数增长。
- **范围(明说)**:只覆盖工作区根之下 ripgrep 能列出的普通文件;被忽略的文件、symlink、根之外的
  路径不在内。记录说的是**命令执行窗口内**工作区的变化,同窗口里的其他写者(后台 subagent、
  用户的编辑器)也会出现在里面。只读命令(与权限自动放行、并行调度共用同一分类器)不观测。
- **观测不到时说出来**:列举失败、工作区过大(超过文件数/字节上限立即记住、超时连续两次才
  记住,本进程内不再重试)、有路径 stat 失败、超过单次检查上限的路径、命令转入后台仍在运行、
  `run_in_background` 启动的命令——这些都置 `lost`;记录满 64 条后仍有变更则置 `overflow`。
  不让沉默被读成"没改"。

其他进程或工具(MCP 工具、插件、调用返回之后的后台作业)造成的文件系统变化不在本契约内。

### 3.3 UiEvent — 前端告诉 core"用户做了什么"

```zig
pub const UiEvent = union(enum) {
    interrupt: abort.Reason,      // esc/ctrl+c/语音"停"
    queue_message: []const u8,    // 生成期入队的新消息(所有权转调用方,须 free)
};
pub const Phase = enum(u8) { input = 0, generating = 1 };
```

**消费点与语义(#115)**:`run()` 在每个 turn 边界(上一轮 tool_result 已追加、下一次 provider
请求尚未构造)`pollEvent()` 直到 null,流式期间不 poll。`queue_message` 追加为一条 user 消息,
**本 Run 的下一次请求就带上它**(空白消息丢弃;slice 用传给 `run()` 的 allocator 释放,in-process
后端须用同一个 allocator 分配);`interrupt` 在边界结束本 Run(`aborted`,`evaluation_budget` →
`budget`),它补充而不取代 AbortSignal 的动中断;max_tokens 续写边界不 poll(续写段必须仍是同一个
答案)。生产方决定什么可转向:TuiBackend 只交出普通 prompt,`/命令`、`!shell`、`exit` 留在队列由
REPL 在 Run 结束后派发。REPL 里 Run 内的边界由 `run()` 消费,Run 结束时仍留在队列里的由 loop.zig
合并成下一个 Run 的输入。AgentCore Session 的 backend.poll 恒返 null:Session 的活动 Run 输入走
带类型的第二条缝 `Options.run_inputs`(`core/run_input.zig` 的 `Queue`,#270)——同一个边界、同样
跳过续写边界,但每条输入有 Host 给的 id、按接受序采纳(逐条追加原文、不 trim)、每条采纳发
`CoreEvent.input_adopted{input_id, sequence, turn}`,Run 结束时关窗得 accepted/adopted 两个计数
(采纳恒为接受序前缀,计数而非事件是对账依据)。`AgentSession.submitInput` / 二进制
`session->submit_input` 是它的入口,见 AGENTCORE_BINARY_ABI.md "Active-Run input"。

### 3.4 UiRequest — core 向前端**请求一个回答**(交互式)

工具(AskUserQuestion / 权限门 / custom 动态 UI)需要用户当场回答时,经
`ToolContext.requestUi` / `PermissionContext.ui_requester` 发出:

```zig
pub const UiRequest = union(enum) {
    ask_question: []const AskQuestion,                    // 多选问答(可多选 + preview)
    permission: struct { tool, args },                    // 权限确认
    custom: struct { kind, payload_json },                // 宿主自定义 UI(core 只转发)
};
pub const UiResponse = union(enum) {
    answers: []const []const u8,                          // 选中的 label(s)
    permission: PermissionChoice,                         // allow_once/allow_always/deny_once/deny_tool_session
    custom: []const u8,                                   // custom 请求的结果 JSON
};
pub const RequestOutcome = enum { answered, pending, unavailable, unrenderable };
pub const UiRequester = struct {
    ctx: *anyopaque,
    requestFn: UiRequestFn, // fn(ctx, session, allocator, *const UiRequest, *UiResponse) anyerror!RequestOutcome
    pub fn request(self, session, allocator, req, out) anyerror!RequestOutcome;
};
pub fn serializeUiRequest(allocator, req) ![]u8; // 给异步前端投递用
```

`RequestOutcome` 的 answered/pending 是同步/异步前端的分水岭(见 §5);unavailable 是没有 UI,
unrenderable 是连着的前端声明了渲染不了这个请求(见下)。

跨进程或网络投递(SSE、WebSocket、队列)用 `protocol.wire`:带版本号的事件行、请求行、
请求关闭行，以及把前端应答解析回 `UiResponse` 的 `parseResponse`(坏应答一律按取消处理，
绝不放行)。格式见 [API.md](API.md#wire-lines-for-out-of-process-hosts)，逐行钉在
`tests/fixtures/wire/v1`。`serializeUiRequest` 只是内部 struct 的直译，供挂起持久化使用，
不是对外契约。

跨进程前端可先发一帧能力声明(`protocol.wire.acceptCapabilities`,规范见
[WIRE_PROTOCOL.md](WIRE_PROTOCOL.md)):列出它能渲染的 UiRequest kind 和带版本的
custom kind(`name@major`)。Host 把它装进每个 Session 的 `protocol.frontend_capabilities.Slot`,
requester 通告前先 `route`:声明里没有的请求不通告，记 `ui_request_unavailable` 并立即返
`.unrenderable`——工具照没有 UI 时兜底(权限照样拒绝，且不落终端 prompt)，但告诉模型的是"前端渲染不了",
不是用户拒绝。从未声明的前端照旧收到全部请求；进程内 backend 从不声明，行为不变。

---

## 4. 主循环契约:agent_loop.run()

```zig
// `api_provider` is the `mc.api_provider` namespace exported by `src/lib.zig`.
pub fn run(
    conversation: *Conversation,
    provider: api_provider.Provider,
    tool_defs: []const ToolDefinition,
    permission_ctx: *const PermissionContext,
    opts: Options,
    backend: *const UiBackend,
    allocator: std.mem.Allocator,
) !RunResult

pub const RunResult = struct {
    stop_reason: StopReason,
    turns: u32,
    tool_calls: u32,
    suspend_info: ?SuspendInfo = null,
    stall: ?stall_gate.Report = null, // 非空 ⇔ stop_reason == .stalled
    continuations: u32 = 0, // 本次 run 的 max_tokens 续写总次数(MAX_CONTINUATIONS 只限连续续写)
    learning: ?learning_turn.Report = null, // 学习回合武装且 Run 走到终局边界时非空
};
pub const StopReason = enum {
    end_turn, max_turns, aborted, tool_error, api_error, tool_loop,
    suspended, backgrounded, budget, max_tokens_exhausted, stalled,
};
```

`provider` 是按值传递的轻量 vtable；它借用具体 client 的 context，client 必须活到
本次 `run` 以及所有并发工具工作结束。源码 Host 通常使用
`agent_session.RuntimeHost`/`AgentSession`（见 §6 和 `example/main.zig`）；只有需要
直接驱动低层循环时，才从具体 client 取得 `client.provider()`。
当 `stop_reason == .suspended` 时，`suspend_info` 由调用方拥有；写入持久状态或完成
投递后调用其 `deinit()`。
`tool_defs`(含 `Options.tool_defs`)里出现 provider server tool(`server_type` 非空,如
Anthropic `web_search_20250305`)时 `run` 直接返回 `error.ServerToolsUnsupported`,不发任何请求
(`resumeRun` / `resumeRunWithResults` 在追加恢复的 tool_result 之前就拒绝,对话保持原样):
本循环不保存 server_tool_use / 结果块,服务端暂停的回合(`pause_turn`)只能靠原样回送这些块续跑,
放行只会静默截断。WebSearch 的 server tool 只出现在它自己的隔离子请求里;Sealed Skill 网关对
非空 `provider_tools` 的 `runs.start` 回 `invalid params`(SEALED_SKILL_PROTOCOL §3.4)。
日期与时区(issue #276):`Options.inject_user_context` 是 CLI 的首条 user-context 消息,总带会话
开始那天的日期与时区(`core.time_context`,不再依赖 CLAUDE.md/记忆/KG 是否存在);
`Options.time_announcer` 非 null 时,本地日期晚于模型能看到的日期的第一个 run 在本轮输入之后
追加一条"The date has changed"提示,随这一轮进入历史,系统提示词与首条消息字节不动;提示被压缩、
裁剪或清掉后会再给一次。AgentCore 不用它,而是把日期作为每个 Run 的 `currentDate` context block。
Session 目标(issue #277):`Options.goal_meter` 非 null 时,run 开始时目标为 active 才计账,
每个 provider 响应(含自动压缩)累加非缓存输入 + 输出,run 结束(任何退出路径,含错误)累加
耗时并发 `goal_updated`;中途用完预算则目标转 `budget_limited`、立即发 `goal_updated`,并在下一
回合边界追加一次收尾提醒(不截断 run)。嵌套 run 共用同一 Meter 时只按最外层计一次。
子 agent(`subagent.SpawnOptions.goal_meter` 默认 null)不计;只有作为 Run 本身、在 Run 线程上
同步执行的子循环(AgentCore 自带上下文的 Skill 调用 Run)才传入 Meter——可能与其他工具并行的
子循环共用 Meter 会产生数据竞争。规则在
`core.goal`;CLI 的 App、`AgentSession` 各持一个 Meter,所以 REPL/web/daemon/headless/AgentCore
同口径计账。

**一回合做什么**:流式发当前 conversation → 收集 assistant 文本 + tool_use blocks(经 backend
emit `text_chunk`/`tool_start`)→ 按权限决策 + 并发安全分批执行工具(`tool_exec.executeSlots`)→
tool_result 回灌为 user 消息 → 下一轮。直到无 tool_use(`end_turn`)/ 达 max_turns / abort /
挂起(`suspended`,见 §5)。`tool_loop` 是受控熔断:环境故障累计达 `MAX_ENVIRONMENT_FAULTS`,
或插件契约 / KG 枚举修复 fail-closed。`stalled` 是停滞闸门(见 §3.2.1 末"停滞闸门")停下的 run;
AgentCore v1 把它投影为 `tool_loop`(冻结的线上枚举不增值)。

### 4.1 工具结果如何进入上下文

本节先给心智模型和数字,后面的段落是每条决定背后的缺陷史。**读顺序:先这里,再往下。**

**从来不是摘要。** 结果级路径全程确定性,不调模型、同输入同字节。会调模型做摘要的只有
**对话级** auto-compact(付费的 summary 压缩),那是整段历史的事,与单条结果无关。模型能
看到的结果有四态:

| 形态 | 何时 | 内容 | 可恢复 |
|---|---|---|---|
| **原文** | 结果 ≤ 本轮**水位线** | 逐字节原样 | — |
| **artifact 信封** | 超水位线,且发布成功 | head + tail 摘录 + `artifact_id` + sha256 + 读取指令 | ✅ `ReadArtifact` / `Grep(artifact_id)` |
| **fallback 信封** | 超水位线,但**发布失败**(会话配额满、存储错误),且捕获完整并 ≤ `PER_RESULT_MAX_BYTES` | head + tail + `storage_error` 如实命名原因,无 `artifact_id` | ❌,但说得出为什么 |
| **清空桩** | 仅压缩期,且**该结果没有 artifact** | `[tool result cleared to save context]` + 承诺行(`original_bytes` + sha256) | ❌ |

fallback 那一行的限定条件不是修辞:发布失败后要渲染 head/tail 就得把字节拿回内存,
所以只有完整且 ≤ `PER_RESULT_MAX_BYTES`(64KB)的捕获退得回来。更大的捕获、不完整的
捕获、以及 OOM,发布失败时仍然上抛成工具错误——那也正是阈值改动之前的行为。

水位线在无 turn 压力时**就是** per-result 预算;兄弟结果多到装不下 `per_turn` 时它会被二分
压低,那时 ≤ per-result 的结果**也会**被溢出(见下方水位线一节与 T2)。所以判据是水位线,
不是 per-result——这里最早写成后者,而本仓自己的 T2 就是反例。

信封的实际形状(`renderArtifactEnvelope`):

```json
{"schema_version":"metacodes.tool-result-projection.v1","projection":"artifact",
 "artifact_id":"sha256:…","media_type":"text/plain; charset=utf-8",
 "original_bytes":412903,"sha256":"…","capture_complete":true,"recoverable":true,
 "preview_encoding":"utf-8","preview_head":"…","preview_tail":"…",
 "preview_head_bytes":12000,"preview_tail_bytes":12000,"omitted_bytes":388903,
 "read":{"tool":"ReadArtifact","offset":0,"limit_max":32768}}
```

头尾都留,不是只留头:日志类输出的信息通常同时在头部(跑了什么)和尾部(怎么失败的)。
读取指令**内联在信封里**,不指望模型记得工具目录里有 `ReadArtifact`——这一条直接对应
issue #29 的行为(不知道能取回,就改命令重跑)。

**预算在字节存在之前就生效。** `ToolEntry.result_production` 把生产方式分三类,其中
`byte_zero_spool`(Glob/Grep/CodeMap/FindSymbol/Bash/两个 MCP 读取/WebFetch)在第一个字节前
就重定向到内核 Spool,**全量内容从不进内核内存**。所以这不是"先拿到 40MB 再截断"。

**artifact 有两个产生点,但只有一个阈值。** 工具层(`result_spool.finishCaptureAsBody`)在捕获
完成时决定"这些字节要不要进内存":完整且 ≤ `per_result_bytes` 的抬回 inline,否则**封存**
(`Spool.seal` → `SealedSpool`:私有临时文件留在 spool 目录,receipt 已知,不进 CAS、不计
quota)并返回 `ToolResultBody.sealed`,由 agent loop 在批次提交边界发布(见下段);
projection 层在本轮结果就绪后决定"模型该看到多少"。两层分开是信息时序决定的——工具不知道
兄弟结果,projection 不能把已进内存的字节反物化——但**判定用同一个数**:工具层按值接收
`ctx.result_budget`,只读 `per_result_bytes`(`result_spool.zig` 内的守卫测试禁止它碰
`per_turn` 等不属于它的字段,并断言六个调用方逐字传 `ctx.result_budget`)。两个 MCP producer
也不另起阈值:classic client 的 `mcp/client.zig` `requestBodyUnlocked` 与 AgentCore 的
`mcp/result_stream.project` 分别把 `ctx.result_budget` / `tool_ctx.result_budget` 原样传下,
用同一个数做决定。三条发布路径还共用 `result_budget.retainInlineAfterFailedPublish`:非 OOM 的 CAS
发布失败后,完整且不超过该发布点自己物化上限的结果退回 inline,让 projection 仍能生成带
`storage_error` 的有界 fallback。上限由各发布点自报:原生 spool 与 AgentCore 投影器是
`PER_RESULT_MAX_BYTES`(64KB,它们得从盘上读回),classic client 是它本就已物化的 1MB 帧上限
(`CONTROL_FRAME_MATERIALIZE_BYTES`)——各自恰好等于阈值改动前那条路径内联过的最大值;不完整或
越过上限的结果仍然失败。此前工具层用的是
常量 64KB(`PER_RESULT_MAX_BYTES` 抄了一遍),在 window < 524,288 的每个模型上留下
`[per_result, 64KB]` 死区:落入其中的结果先被抬进内存,再被 projection 写回 CAS,同一份字节搬
两次。统一后无 turn 压力时两层严格一致;有压力时(兄弟结果压低水位线)工具层正确内联的结果仍会
被 projection 溢出——这不可避免且有界(≤ per_result),`tests/component/inline_threshold_test.zig`
的 T2 验证这类二次转存零丢失、小结果零牵连、压完恰在预算内。

**发布发生在批次提交边界,不在执行期(#45)。** 封存的句柄随渲染好的信封一起走
(`tool_exec.OneResult.done.sealed` → `Slot.sealed`,流式预取的 `Entry` 同样携带);从封存
receipt 渲染的信封与发布后渲染的逐字节相同,所以模型看到的字节不因发布时机而变。
MCP client 超出 frame limit 的结果、host stream 工具的产物,以及声明 `supports_artifact_spool` 的 process plugin 写入的外部 spool(`ExternalSpool.seal`),现在也遵循这一提交边界发布规则(#65)。Bash 的两个通道亦然(#73):结果体仍是内联 JSON,但被截断通道的字节在执行期只**封存**为该内联体的附件(`InlineResult.attachments`,至多 stdout、stderr 两个 `SealedArtifact`,带 `attachment_label`),JSON 里的 `<channel>_artifact_id` 就是封存时已知的 receipt;`publishSealedResults` 在提交边界发布附件,某个附件发布失败时把该通道的 id 从 JSON 里撤回(`withdrawAttachmentFromJson`:`_artifact_id` 置 null、补 `_storage_error`、`_recoverable` 置 false、去掉 `_read` 提示),而不是让模型拿着一个不存在的 blob 的 id。没有批次边界的调用方(`session_service` 的 `!cmd`、嵌入方)走 `bash.execute`,它在执行期就地做同一套解析。MCP 投影器超出 frame limit 的结果区间(`mcp_result_stream.publishRange`,所有入口共用同一 MCP client)与 AgentCore durable budget 的 `promoteInline` 提升也改为封存(#73):两者的结果都经内核的 `tool_exec` 到达同一个提交边界,不需要 ABI 可见的新边界;至此不再有生产者在执行期把工具结果发布进 CAS。唯一的例外是 `promoteInline` 遇到带附件的内联体(Bash 结果本身超出 AgentCore 的原始上限)时先就地解析附件,因为封存体只携带一个句柄。
`executeSlots` 无 fatal 地完成就是提交边界:`tool_exec.publishSealedResults` 在这里发布每个
句柄,发布与为它作证的 Conversation 引用落在同一轮;更早的退出(host 工具 fatal、被拒的
dispatch 观测)只是释放 slots——`Slot.deinit` 丢弃临时文件,CAS 里不会留下无人引用的 blob。
不能在 fatal 路径上删 blob 的原因没变:CAS 按内容寻址,同一 id 可能已被更早的结果、同批兄弟或
共用根目录的其它 session 引用。提交边界上发布失败沿用工具层原先在执行期的策略
(`retainInlineAfterFailedPublish` 允许则退回 inline,否则给出有界的 `ArtifactPublishFailed`
工具错误)。仍在执行期发布的生产者——MCP 超帧结果、process plugin 的 `ExternalSpool`、Bash
spool import、host stream 工具、AgentCore 投影器——见 #65。

**两个预算,都是 context window 的纯函数**(`result_budget.perResultBytes`/`perTurnBytes`):

```
per_result = clamp(window / 8,     8KB, 64KB)     单条结果
per_turn   = clamp(window * 6 / 5, 16KB, 200KB)   本轮所有结果合计
```

`6/5` = 4 字节/token × 分给工具结果的 30%。落到实际:

| window | per_result | per_turn |
|---|---|---|
| 未知(0) | 8,192 | 16,384 |
| 128K | 16,000 | 153,600 |
| 200K | 25,000 | 204,800 |
| 1M | 65,536(封顶) | 204,800(封顶) |

**一轮的处理顺序**(`result_projection.project`,每轮一次,只作用于本轮新结果):

1. **regrow** — 在更小预算下落成的信封,若现在额度够就读回 artifact 重新内联/扩大 preview。
   这是唯一会把结果**变大**的一步,所以先按整轮定价(`regrowCeiling`)再执行。
2. **定 plan** — 标记豁免:图片(按 token 计价,不按字节)、错误、已是信封的、`ReadArtifact`
   (它自己再溢出就递归了)。
3. **水位线** — 二分搜出"全轮能装进 `per_turn` 的最大单条上限"。低于水位线的一个字节不动,
   只削高于它的;**不是逐出最大的那条**。
4. **溢出** — 全量写进 session CAS,换成信封。`Allowance.cost` 里的 `@min(len, spillCost)` 让
   "用 ~640 字节脚手架的信封换掉一条 700 字节结果"这种既丢内容又撑大请求的负和交易不可表示。

**历史走另一条路。** projection 只在提交那一刻生效,**从不重投历史**——重写历史字节会让
provider 的 prompt cache 前缀失效。因此 `/resume` 载入的旧记录、或中途换成小 window 模型,
只由 `Conversation.truncateLargeToolResults` 这一趟兜底(详见下方"压力阀不得毁掉唯一的恢复能力")。

**provider 只提供一个数字,而这个数字并不可靠。** 整条链路从 provider 拿的就是
`maxInputTokens`,其余全是它的纯函数。但它有三个来源:`/v1/models` catalog 的
`max_input_tokens`;各 client 的硬编码默认(OpenAI 128K、Gemini 1M——各持**一个**常量,
不区分 model,所以这两家的 per-model 解析实际退化成 client 默认);都拿不到就是 0。
`catalog.nonZero` 把 0 当**未知**而不是"窗口为零"(Anthropic 官方 `/v1/models` 常把
`max_input_tokens` 返成占位 0),于是退到地板值 8KB/16KB,而不是把所有预算塌成 0。
subagent 与父共享 Provider、只差 `model_override`,故必须走 `maxInputTokensFor` ——
见下方"预算按真正会被请求的模型解析"。

**为什么这块牵扯面宽**,一句话版:决定"一条结果值多少字节"要同时满足互不相干的五个约束——
prompt cache 不许改历史(所以历史必须另开一趟)、图片按 token 计价而文本按字节(所以字节
记账里必须挖掉图片)、JSON 转义/base64 让"字节"有两种含义(所以有 `Source`/`Encoded` 两个
单位)、subagent 与父同 Provider 不同 window(所以窗口必须按 override 解析)、以及最后一环
在模型自己身上(它不知道能恢复就会重跑,而这一环 code review 看不出来,只能靠轨迹审计量)。

**大结果提交协议**:工具统一返回 `ToolResultBody`。旧工具经 `legacy_inline` adapter 仍先产生
完整 bytes；byte-zero 原生工具和 process plugin 则在产生第一字节前取得 kernel Spool，最终直接
返回 artifact receipt。`executeSlots`、PostToolUse hook 和 backend 观察该类型的确定性模型投影：
inline 路径保持原始结果，artifact 路径观察 bounded recovery envelope（全文从未进入内核内存）。
随后 `result_projection` 只做一次确定性 Conversation 提交。结构化工具应优先返回合法的 bounded
envelope（`rows/cursor/total/truncated`）；其余超限 inline 结果写入 Session 内容寻址 artifact，
模型只看到稳定 SHA-256、head/tail 预览和 `ReadArtifact(offset,limit)` 指令。最后的通用字节截断
仅是失存储时的显式不可恢复兜底。已提交的 recovery envelope 不在后续 provider 请求前重新
投影；`ReadArtifact` 从首个请求就属于冻结工具目录，避免因溢出动态改 schema 而破坏 prompt cache。
图像形态结果（`Read` 读图返回的 `{"type":"image",...}`，`result_projection.isImageResult`）豁免两轮投影：
vision 路由的方言原生消费它（image block / data URL / inlineData），非 vision 路由收到有界占位文本
（能力真相三层,强者在前:Host 声明(`SessionConfig.model_capabilities`)> provider `/v1/models` 目录的
`image_input` 声明 > `model_adapter.familyImageInput` 家族表;都没说 = `image_input_source == .unknown`,
按不支持拒绝(issue #273)。三个 client 的 `dialectFor` 都经 `Dialect.declareImageInput` 叠加,
`Provider.imageInput` 连同来源一起答;`Read` 在执行期按 `ToolContext.image_input_supported` 先门控——活动模型收不了图就
返回 `capability_unsupported` 错误并点名目录里能看图的模型，图片根本不进历史；占位文本只剩给读后换模型 /
fail-closed 方言这类序列化期才发现的情况），
信封只会把图片变成 base64 预览文本；轮预算按 `IMAGE_RESULT_BUDGET_BYTES`（= `IMAGE_TOKEN_ESTIMATE` × 4
字节/token）计入，`Stats.projected_bytes` 仍是真实字节数。microcompact 对**未送达**的图片同样豁免：
送达是 `Message.delivered` 显式水位，只由 agent_loop 在 provider 接受请求并返回流句柄后 `markDelivered` 推进
（被 HTTP 错误拒绝的请求不算送达；不支持图像输入的模型只收到占位文本，这样的请求不算送达含图消息——
这个判断由序列化器定案并随 `StreamHandle.image_placeholder_ids`（走占位的 tool_use_id 列表，null = 未知按全占位处理）
回传、按 `ToolResult.delivered` 逐块记录并随 transcript 持久化，不在 agent_loop 重算；压缩边界之后
和被规范化器剥掉的孤儿图片则一律标记送达，因为没有后续请求能再携带它们），
本地追加的 assistant 消息（如 AgentCore 预算终止标记）不算送达，
transcript resume 恢复持久化的水位（没有该字段的旧记录一律未送达、下一次被接受的请求后自愈）；compact 预览提交时把 live 的水位按索引合并进
替换集（仅 CAS 路径），在途的送达不会被过期预览覆盖。
这避免 Read(image) 带并行兄弟时在 provider 看到之前就被 recent-N 阀清掉；已送达的图片照常清，阀对图片密集的
历史仍有效（未送达的文本沿用历史行为——按数量保留，这是既有的通用问题，不在图像契约内）。图片永不被 `truncateLargeToolResults` 截断。AgentCore 的
`ToolEnvironment` 不 `promoteInline` 图片，payload cap 按视觉估算记，耐久预算按实际字节记，且
`settleSuccess` 把仍存活的兄弟预留计入硬预算，结算不能吃掉并行工具已预留的空间。
子 agent（Task / fork / 模型调用的 Skill）的 `BudgetedProvider` 与 `ToolEnvironment` 以
`DurableScope.transient` 结算：在途仍预留请求与 payload cap、超限仍是 resource limit，但不累加
`estimated_usage_bytes`——子对话在返回时即被丢弃，只有最终文本会进入 Session（fork 根路径由
`Controller.commitDurable` 一次性计入；model-tool 路径由父 `ToolEnvironment` 按工具结果计入）。
Task/subagent 的 reasoning effort 解析顺序与 Codex 子代理对齐：AgentDef `effort` > Task `model`
档位带出的 effort > 未换模型时继承父当前 effort（`/effort` 修改立即生效） > 换模型且未指定
effort 时使用该模型默认值。

**读代码给存在性,审计轨迹给频率**:`scripts/audit_trajectories.py` 扫已落盘的
`transcript.jsonl`,报告各工具的结果大小分布、超预算条数、溢出后**有没有人来取**、以及
Bash 结果被截断后模型改命令**重跑**的次数(issue #29 那个行为)。只出尺寸/计数/工具名——
结果内容、命令文本、路径一律不进输出(有测试钉住)。不进任何 gate(它读 `~/.metacodes`,
CI 没有),但它的解析逻辑有单测且已接 `zig build test`。

存在这个脚本的理由是记录在案的教训:本轮把 `BashOutput` 的缺陷描述成"每次都发生",而审计
314 条真实结果给出的是中位 164 字节、仅 1 条超预算——**缺陷为真,频率是编的**。构造探针
证明存在性,审计校准量级,两者不能互相替代(只发生过 1 次的东西,光看审计会判它不存在)。

**单位是类型,只在跨越处强制**:`result_budget.Source`(内容缓冲区里的字节)与
`result_budget.Encoded`(渲染进信封后占的字节)是两个 non-exhaustive enum,零表示开销。
切割原语因此签名为"吃 `Encoded` 预算、吐 `Source` 长度"——那次换算正是反复被跳过的一步。
一个 base64 字符串本身是 `Encoded`,它解码出来的才是 `Source`,所以不需要第三个单位。

**范围是量出来的,不是凭感觉划的**:只有发生**换算**的地方强制单位(cut/cost 原语、
`payloadAllowance`、preview 计数)。`Budget` 的字段刻意保持 `usize`——它们几乎只与结果自身
长度比较,同单位、无从混淆;试着把它们也类型化后 `.raw()` 从 42 涨到 73,十七处新增全在从无
危险的边界上、一个缺陷也抓不到,遂回退。**类型在没有防止混淆的地方就是纯税。**
另注:`Source.head(buf)/.tail(buf)` 只是省掉 `.raw()` 的人体工程学,**不保证**长度与缓冲区
配对(`head(错缓冲区)` 照样编译),那需要 phantom 参数,缓冲区错配仍归测试管。

**编码后字节是唯一记账单位**:凡是"这条结果值多少字节"的判断,量的都是**渲染进信封之后**
的字节——preview 经 JSON 转义最多翻倍、经 base64 涨 4:3。三处都踩过同一个坑(Bash 通道按
整条通道选编码却按 preview 渲染、`regrowCommittedEnvelope` 按源字节下刀、`ReadArtifact`
按源字节 clamp),共同后果都是"信封比它被派生自的预算大 1.4~2 倍",而这三种结果又都对
projection 的溢出趟豁免,下游没有任何一层会把它们收回来。cut/cost 原语因此只有一份
(`result_budget.encodedCost`/`headCut`/`tailCut`),做预算的那次决定(含 utf-8 还是 base64)
必须**带着**传给渲染方,不允许渲染方自己再判一次。

**字节预算的单一真相**:`core.result_budget.Budget` 由 provider 的 context window 派生
(`per_result_bytes` 8..64KB、`per_turn_bytes` 16..200KB),`agent_loop` 每轮算一次,同时交给
`ToolContext.result_budget` 和 `result_projection.project`。自己限界的工具(Bash 的
stdout/stderr 双通道)从这里取额度并按 max-min 公平切分——空 stderr 不再白占一半;预算按
**编码后**字节计(`encodedPrefixLen`/`encodedSuffixLen`),否则引号密集的输出经 JSON 转义可能
渲染成额度的两倍。projection 的 preview 默认也由预算派生而非常量:溢出意味着内容超过了额度,
不意味着额度消失。turn 预算用水位线(二分)统一下调每条的上限,而不是逐出最大的一条;当封装
本身比内容还大时**拒绝**溢出,避免"丢了正文还把请求撑大"。流式 capture 路径的
`artifact.Preview` 是编译期定长数组(1536 字节,在字节流过时就填好,那时既不知道结果多大也
没有 provider),`project` 因此在提交前按当前预算重渲染该信封——原文放得下就整条回内联
(`envelope_reinlined_count`),放不下就把 head/tail 扩到额度(`envelope_regrown_count`)。
这一趟是**唯一会把结果变大**的一步,而它的产物又对溢出趟豁免,所以额度必须先按整轮定价
(`regrowCeiling`):否则要么一条信封按 per-result 内联完再被 turn 水位线原样溢出去(读一遍
artifact、写一遍、同时报"整条回给模型"和"已溢出"),要么并行 10 个工具调用各自涨到
per_result_bytes,合计十倍于单条预算、且下游没有任何一层收得回来。
`ReadArtifact` 对投影豁免(否则恢复自身会递归溢出),改由 `min(MAX_READ_BYTES,
per_result_bytes)` 限界——同样按**编码后**字节,并扣掉自身信封开销:chunk 是 JSON 转义
(或 base64)进 `data` 的,按源字节限界会让引号密集内容渲染成预算的两倍,即"给超预算结果
的恢复,比结果本身更超预算"。余量走 `next_offset`,一个字节都不丢。

豁免仍然保留,但成本按 turn 限界(#40):agent loop 在执行前按 slot 顺序为每个 `ReadArtifact`
调用计入其上界 `result_budget.recoveryReadCost`(= `min(MAX_READ_BYTES, per_result_bytes)`),
超过 `recoveryAllowanceBytes`(= `per_turn_bytes / 2`)的调用一律 deferred:不执行,结果是有界的
`{"error":"recovery_allowance_exhausted","artifact_id":…,"offset":…,"allowance_bytes":…,
"charged_bytes":…,"hint":…}`(`is_error`),并发出 source 为 `recovery_allowance` 的
`policy_decision` 事件。200K 窗口服务 4 个完整 chunk、第 5 个 deferred,而过去 9 个并行读会
超出整个 turn 预算且投影无从裁剪。决策在任何线程运行之前按 slot 顺序、按上界完成,因此哪个
调用被 deferred 不依赖调度时序,provider-visible bytes 始终是请求的纯函数。

**压力阀不得毁掉唯一的恢复能力**:`microcompact` 的 clear 趟明确跳过带 recoverable
artifact 的结果(那是被省略字节的唯一取回途径),`truncateLargeToolResults` 必须守同一条
承诺——它的通用头尾截断是**文本**操作,套到信封上会切出不可解析的 JSON,artifact_id /
sha256 / read 指令一起没,而且下一轮 clear 因为再也看不到 recoverable artifact,会把残骸
清成 stub。因此该趟先走 `result_projection.shrinkRecoverableEnvelope`:由拥有信封形状的
那一层原地重渲染 preview(不碰 store,head/tail 从信封自带的 preview 里重切),身份字段
一个不动、记账数字跟着重算;其余结构化结果(`metacodes.bash-result.v2`、不可恢复的
fallback 信封、任意工具的大 JSON)走通用的**只裁长字符串**:短字段(exit_code、
storage_error、各种 id 与 flag)从来不是超限的原因,却是结果可用的全部依据,必须原样留下;
描述被裁字符串的计数器(`<ch>_truncated`、`preview_*_bytes`)在写出时一并改对,否则就是
另一种"悄悄撒谎"(`omitted_bytes` 必须继续满足 head+tail+omitted==original)。裁剪递归到
任意深度——`{"rows":[{"text":<40KB>}]}` 顶层没有长字符串,只裁顶层等于没裁。**连裁都裁不动的
(体量不在字符串里,如超大数值数组)一律留着超限,通用文本截断只用于本来就不是结构化的内容**:
多花一次请求可以恢复,切成不可解析的散文不能。

**staging 路径在 Bash 一侧全面不可见**:已完成信封、auto-backgrounded 快照、显式
`run_in_background` 三条路径都不再交出 `stdout_path`/`stderr_path`,统一改用 `job_id`
(BashOutput 本来就按它读,还支持 `*_since_byte` 增量),能力不减。

**bytes/text 边界**:外部进程和文档内容先按 raw bytes 捕获。只有经过明确
编码策略并验证的内容才进入文本字段；文本页按 UTF-8 code-point 边界截断，
`TaskOutput.output_next_offset` 是原始缓冲的下一字节游标，不能用替换、JSON
转义或 base64 后的长度代替。二进制必须通过 artifact 或显式编码 envelope
传递；JSON、XML-like notification、Markdown 和 terminal 各自负责 escaping。

**已登记的缺口(别当成已解决)**:`job_id` 自身由随机字节生成,按 contract 的定义它就是
random id,所以后台命令跨 run 仍不逐字节一致。它不能简单换成序号——同一个值同时用作
`/tmp/metacodes-jobs/<uid>/<id>.out` 的文件名,而该目录跨进程共享,序号会撞。真正修法是把
**文件标识**与**模型可见句柄**分开,属于 JobRegistry 所有权议题(与 spool 清理同源)。删掉
路径把暴露面收窄到每条后台命令一个短不透明 token,并且不再泄露宿主临时目录,但没有做完。

**预算按真正会被请求的模型解析**：subagent 的 per-call provider 通过
`ModelLimitsSource` 由 App 在父 catalog 变化后主动发布到 registry；registry 持有 owned catalog
快照（避免 `/model` 切换 deinit/rebuild 或并发 probe 造成 worker UAF），并借用 App 生命周期内
只读的 ModelContext 与 max-tokens override；子仍按
`model_override` 解析 `Provider.maxInputTokensFor(model_override)` / `maxTokensFor`，因此它们
成为**所有**窗口/输出
派生量的唯一入口——per-result 预算、turn 预算、auto-compact 阈值、请求估算体、request gate
的准入、agentcore 的预算预留,一处都不能落。答不了 per-model 的 provider 回退到自身窗口
(即历史行为)。拿父窗口给子算,就是把 200K 的历史发给 32K 端点。

这条规则最容易漏在"同一个字面量里 model 用了 override、maxTokens 没用"——`serializeForEstimation`、
request gate、`canonicalRequestBytes` 三处都这么漏过。`agent_loop.zig` 里有一条守卫测试直接
钉住规则本身:生产函数中不得出现无参的 `provider.maxTokens()` / `maxInputTokens()`(判断
每次出现前最近的顶层声明是 `test` 还是 `fn`,因为测试块在该文件里是穿插的)。

**窗口是上界,墙是测出来的(`core/context_caps.zig`)**。catalog 的 `max_input_tokens` 是服务端的
自述;真正的拒绝点只有服务端知道,而且同一个模型换一个网关就是另一堵墙(2026-09-22 Metask
glm-5.3-flash:catalog 推出的可用输入 917,504,实测 ≈883K 就拒)。所以 `agent_loop` 里所有阈值
都经 `pressureFor` 派生:`effective = min(catalog 可用输入, 学到的上限)`。catalog 可用输入 = 窗口
减去请求真正要的输出:服务端校验 输入 + max_tokens ≤ 窗口,所以预留的就是请求发的 max_tokens,
而它取 `min(catalog 输出上限, 窗口 / 2)`(`Client.resolveMaxTokensFor`;显式 `--max-tokens` 原样发)。
输出上限和窗口一样大的模型(2026-11-23 Metask 网关的 kimi-k3.1-pro,都是 1,048,576)若全额预留,
可用输入就是 0,每条消息都在本地被拦下。三个 buffer 按
`effective/200K` 线性放大(`context_pressure.scaledBuffer`,1M 窗口上仍是 6.5%/10%/1.5%,而不是
1.3%/2%/0.3%)。学到的上限按 (endpoint, model) 记在 `~/.metacodes/context_caps.json`
(`METACODES_CONTEXT_CAPS_FILE` 覆盖,置空则不落盘;测试构建默认不落盘),下个 session 从第一轮起就
在墙内。

**撞墙是一次测量,不是一个要绕过的坑**。采样请求被拒为 context-window-exceeded 时
(`recoverContextWindowExceeded`):① 从错误正文解析数字(`error_class.parseContextWindowNumbers`,
多方言尽力而为),有则记 `.server_message`,没有则用上次被接受的 prompt 大小记 `.observed`(任何后端
都提供的下界);② 把 usage 锚点写成"已满"(Codex `set_total_tokens_full`);③ 强制走一次摘要压缩并
在同一 turn 重试,每 turn 限 1 次(mecode `PRE_SEND_CONTEXT_COMPACT_RETRY_LIMIT`);④ 只有压缩无物可丢时
才退到"删最老一对"——Rust 参考里那个一条条削的循环包的是**摘要请求**,从来不是采样请求。之后被
接受的 prompt 若大于学到的上限:服务端自述作废、观测下界抬高(`context_caps.noteAccepted`)。
**自动**压缩的摘要末尾附带用户原话(`compact_kernel.Options.preserve_user_prompts_tokens`,agent loop
传 20K token;预算再按被丢前缀的 1/4 收紧,第一条请求必留),没有模型摘要时也至少保留这一段;
手动 `/compact` 与 AgentCore 公共 compact 不开这项,契约不变。UI 事件仍是 `auto_compact`,但 cause 为
`context_window_exceeded_recovery`(压缩应答了拒绝)或 `context_window_exceeded_trim`(退到削一对)
时,两个前端都渲染成 recovery 而非压缩。

**恢复面的两个原语**:`ReadArtifact` 只能取字节区间,恢复一个 N 字节结果要
O(N/32KiB) 次完整往返,而且回答不了"这段输出里哪儿出错了"。`Grep` 因此接受
`artifact_id` 替代 `path`:blob 本来就是普通文件,一次 ripgrep 就能定位。CAS 路径
**不得**进入模型可见结果(泄漏它等于让任意文件工具绕过有界恢复契约),故 artifact
模式强制 `--no-filename`,并拒绝 `files_with_matches`——该模式的全部输出就是路径。
`path` 与 `artifact_id` 互斥;无 artifact store 时传 `artifact_id` 报
`ArtifactStoreRequired`,不会静默退化成 cwd 搜索。

**配额与可见性**:`MAX_SESSION_BYTES` 检查每次发布都做一次全目录扫描,**刻意保持精确**
——session root 由子 agent 与跨进程 swarm teammate 共享,缓存总量只能是下界,信它就会
在别的写者活跃时越过配额;那次扫描的代价(最坏几千次 syscall)相对一次模型往返是噪声。
扫描顺带写入 `sessionUsage(session_root)`(纯遥测,不参与准入;按 store 键控,一个进程会
往多个 session root 发布——每个子 agent、每个 swarm teammate 一个——所以没测量过的 root
读出来是"未知"而不是别人的总量),经 `Stats.session_artifact_bytes` 进 projection 日志行,
让"逼近配额"在变成永久不可恢复之前可见。发布失败的原因由
`artifact.storageErrorCode` 统一命名,generic 信封与 Bash 通道
(`<channel>_storage_error`)共用同一套码,不再出现"只说 recoverable:false 不说为什么"。
**没有淘汰策略**:artifact id 已经写进 conversation/transcript 并对模型承诺过
`recoverable:true`,盲目删除会让该承诺变成悬空指针;安全的淘汰需要一份跨会话的存活
引用集,artifact 层拿不到,属于独立议题。

静态 `ToolEntry.result_production` 把生产方式收成三种不可混淆的状态：`bounded_inline`、
`input_derived`、`byte_zero_spool`；comptime 断言禁止 `byte_zero_spool` 工具接回
`legacy_inline` executor。当前原生 byte-zero 清单是 `Glob`、`Grep`、`CodeMap`、
`FindSymbol`、`Bash`、`ListMcpResourcesTool`、`ReadMcpResourceTool`、`WebFetch`。
其中 Bash 在第一个 stdout/stderr 字节前重定向到 JobRegistry 文件；没有长生命周期
JobRegistry 的源码嵌入者只要提供 `artifact_root`，内核就为该次同步调用建立临时 registry，
不会退回 pipe 全量捕获。已完成的 Bash 信封**不**给出 spool 路径:`<channel>_path` 曾经存在
并被 `hasRecoverableArtifact` 当作恢复句柄,后按上方 prompt-cache contract 一并移除(staging
path + 随机 id,两条都踩)。恢复面只有内容寻址的 `<channel>_artifact_id`(配 `Grep(artifact_id)`
就地搜索);捕获超过 `MAX_ARTIFACT_BYTES` 无法发布时就是**真的不可恢复**,由
`<channel>_storage_error` 如实命名原因,而不是靠一条违约的句柄把它装成可恢复。后台作业则用
稳定的 `job_id` + `BashOutput`(`*_next_offset` 是续读游标;运行中的作业默认最多等 30 秒直到退出,未读输出按渲染成本已填满一页时立即返回(`returned_on: backlog`);`until` 可改为任一未读字节 `output`、有输出后停顿 `quiet`(`quiet_ms`)或出现字面子串 `pattern`(`pattern_match` 给出通道与偏移,快照与已退出作业同样报告;在时限内搜不完时给出 `pattern_searched_to` 供续搜;命中 pattern 不计入轮询守卫),`wait_ms=0` 为快照;同一作业背靠背的等待调用连续只拿到零星进度字节时,轮询守卫 `poll_guard` 让后续等待忽略进度输出,等待上限取 `wait_ms` 与守卫下限(30 秒起逐次倍增,下限封顶 300 秒)中的较大者,作业结束或命中 pattern 仍立即返回,非 pattern 等待遇到整页输出也立即返回;守卫生效时小于 256 字节的页(很小的 `max_bytes`)不算整页,翻积压请用 `wait_ms=0`)。MCP stdio、AgentCore MCP
connector、process plugin 与公开 Host stream ABI 都复用同一 CAS/receipt/`ReadArtifact`
恢复面。

后台作业退出通过 core 的第二输入通道送回会话：通知是 metadata-only 的 user 消息（只含 job id、状态、退出码、耗时和各通道未读字节，避免把任意进程输出从 tool_result 提升成 user-role 提示注入），按 owner 隔离且每个退出最多通知一次。它在 turn boundary 投递，也会在自然 end_turn 时按 `job_wait` 等待并继续运行；`job_wait.max_wakeups` 默认 20，`timeout_ms` 默认 null（headless 设为 30 分钟），`poll_slice_ms` 默认 200，`pending_input` 探针、abort、超时和 wakeup cap 都会结束等待而把事件留给下一轮边界。

真实 rollout 的非敏感证据用 `scripts/eval/tool_result_projection_eval.py <cassette>
--headless-result <result.ndjson> --time-file <time.txt>` 导出；报告只含尺寸、hash、usage、
恢复/前缀判定和时延，原始 cassette、artifact 与模型文本必须留在隔离本地目录。

### 4.2 Options(全可选,`.{}` 即最简跑)

字段较多,分四类——理解分类比记字段重要:

- **CONFIG(纯标量旋钮)**:`max_turns=400` `cost_budget_usd` `system_prompt` `verbose`
  `auto_compact_threshold`
  `auto_compact_keep_recent=10` `agent_depth=0` `colorize=true` `emit_tool_cards=false`
  `model_override` `explicit_invocation` …
- **DEPS(注入的依赖句柄)**:`abort` `read_state` `edit_hl_cache` `jobs` `agent_jobs` `tasks`
  `api_client`(仅 Anthropic `web_search` 专用) `provider_factory` `tool_defs` `dyn_registry`
  `agents` `skills_set` `cron_registry` `sandbox`
  `mcp_sessions` `mcp_unavailable` `output_ledger`(§3.2.1) `file_change_journal`(§3.2.2) …
- **SESSION/身份**:`session: SessionId` `session_id` `project_dir` `cwd_abs` `home_dir`
  `parent_model` `artifact_root` …
- **接口回调/观察(类型安全,见 §4.3)**:`ui_requester` `host_services` `tool_observer`
  `spawn_tick_fn`；usage/progress 由 `CoreEvent`/`EventSink` 投影，不再注入私有 sink。

### 4.3 接口/事件结构(宿主接 core 的类型安全面)

回调接口统一把 context 与函数指针收进类型安全的 value；usage/progress 则走
`CoreEvent`，不是已经移除的私有 `UsageSink`/`ProgressReporter` 回调:

| 接口 | 定义于 | 作用 |
|------|--------|------|
| `EventSink` | `agent_session` | Session 级 `CoreEvent` 消费（文本、工具、usage、progress、诊断） |
| `UiBackend` | `protocol/ui_backend` | 低层 `agent_loop.run` 的 emit/poll 事件面 |
| `UiRequester` | `protocol/ui_request` | 交互式 UI 请求(§3.4)，可返回 answered/pending/unavailable/unrenderable |
| `HostServices` | `tools/context` | Skill/ToolSearch 激活、Worktree push/pop 与当前工作根(`workingRoot`)的宿主 RPC;工具每次调用从 `workingRoot` 开始,EnterWorktree/ExitWorktree 中途切换它 |
| `ToolProgressReporter` | `tools/context` | 工具执行内进度(id, phase, text, count;WebSearch 用) |
| `ToolObservationSink` | `tools/observation` | UI-independent 的实际 dispatch 观察 |

---

## 5. 同步 vs 异步前端(thread-per-session 的边界)

这是多前端最关键的分野。

### 5.1 同步前端(TUI / GUI / 带长连接的 Web)— 默认路径

人类响应秒级、session = 活线程生命。`UiRequester.request` **阻塞**该 session 线程直到用户答完,
返回 `.answered`(out 已写)。一个慢 session 只阻塞自己的线程,不影响其他 session(thread-per-
session)。这是 `requestUi`/`promptUser` 当前的全部行为。

### 5.2 无交互前端(headless / 批处理 / 后台 subagent)

无 requester(`ui_requester == null`)→ requestUi 返 `.unavailable` → 工具按语义兜底
(AskUserQuestion→NotATty;plan→answer_queue/reject)。参考 `WriterBackend.initNull()` /
`HeadlessBackend`。

权限 prompt 没人答时(`promptUser` 返 `permission.PromptUnanswered` 错误：无人可问、
`.pending`/`.unavailable`、requester 失败、超时、被中断/关闭取消、应答读不懂、前端渲染不了),
照样拒绝，但告诉模型的是原因，不是"user declined"。requester 用 `ui_request.Unanswered`
(`UiRequestTimedOut`/`UiRequestCancelled`/`UiAnswerUnreadable`)报告超时、取消与读不懂。
文本与 `recoverable` 见 [WIRE_PROTOCOL.md §1.4](WIRE_PROTOCOL.md#14-requests-nobody-answered)。

### 5.3 异步前端(IM / 邮件 / 工作流)— 可挂起路径

人类响应延迟 >> 进程寿命(几小时 + 跨重启),活线程无法存活那么久。**协议层已预留**:
- `RequestOutcome.pending`:异步 requester 不阻塞——stash 请求、out-of-band 投递、返回 `.pending`。
- `CoreEvent.ui_request_pending`:core 据此把"待回答的请求"交给异步 backend 投递(Slack/邮件)。
- `StopReason.suspended`:run() 检测到 pending 即挂起返回(不再调 API)。
- `serializeUiRequest`:把 UiRequest 序列化给前端渲染。

当前同步 requester 仍返回 `.answered`；异步 requester 可以返回 `.pending`，由
`run()` 产出 `.suspended` 和 `RunResult.suspend_info`。CLI/headless 已把该信息写入
`suspend.json`，`--resume-response` 通过 `resumeSuspended` 读取 transcript 与挂起状态，
调用 `resumeRun` 注入成对的 `tool_result` 并继续运行（再次挂起时链式重写状态）。真正的
Slack/邮件投递器仍属于宿主职责，core 不负责网络传输。

`.pending` 只对工具执行时发起的请求生效（AskUserQuestion、custom UI）。权限请求不在此列：
权限门在 `executeSlots` 之前同步询问，`permission/prompt.zig` 把 `.pending` 当成没有回答，
在 `no_interactive_prompt` 下直接拒绝该工具，Run 不会挂起。所以 `SessionHost` 的挂起模式
（`Options.ui_request_wait = .suspend`，#446）只挂起问答和 custom 请求，权限请求仍同步等待；
它用 `AdmittedRun.resumeWithResults`（内部即 `agent_loop.resumeRunWithResults`）恢复挂起的
Run。挂起状态只落在会话目录的 `ui_requests.json`（临时文件 + fsync + rename，自带同轮其余调用的结果），
不用 `suspend.json`：后者原地覆写、不 fsync，也不保留被拒绝或推迟的兄弟调用。

---

## 6. 构建一个前端的最小路径

### 6.1 实现 backend(in-process)

```zig
const mc = @import("metacodes-core");
const MyBackend = struct {
    fn emitImpl(ctx: *anyopaque, _: mc.session_id.SessionId, ev: mc.protocol.ui_event.CoreEvent) void {
        const self: *MyBackend = @ptrCast(@alignCast(ctx));
        switch (ev) {
            .text_chunk => |t| self.render(t),       // 你关心的
            .tool_start => |s| self.showTool(s.name),
            else => {},                               // 其余 no-op
        }
    }
    fn pollImpl(_: *anyopaque, _: mc.session_id.SessionId) ?mc.protocol.ui_event.UiEvent {
        return null; // 或返回用户事件(interrupt / queue_message)
    }
    fn backend(self: *MyBackend) mc.protocol.ui_backend.UiBackend {
        return .{ .ctx = @ptrCast(self), .emit = emitImpl, .poll = pollImpl };
    }
};
```

### 6.2 跑一回合(对齐 `example/main.zig`)

```zig
var client = mc.client.Client.init(a, init.io, api_key, "claude-3-5-haiku-20241022");
defer client.deinit();
const provider = client.provider(); // value vtable; client/context must outlive run()
var conv = mc.conversation.Conversation.init(a);
defer conv.deinit();
try conv.appendText(.user, "Reply with a single word: hello");
var be = MyBackend{};
const backend = be.backend();
const result = try mc.agent_loop.run(&conv, provider, tool_defs, &perm_ctx, .{}, &backend, a);
```

### 6.3 多 session(GUI 多视图 / IM 多对话)

N 个 session = N 个 `run()` 线程,共用一个 backend 实例;emit/poll 按 `SessionId` 参数路由到
对应视图/对话。`SessionId.gen()` 造新身份,`.single` 是 N=1 哨兵。每 session 自己的
`Conversation` + `PermissionContext`(per-instance,无进程全局串台)。

### 6.4 进程外前端(WebSocket / gRPC)

CoreEvent/UiEvent/UiRequest 全可序列化(无指针/闭包)。emit 内 `serialize → 发送`、poll 内
`接收 → parse`。`HeadlessBackend` 已示范 emit→NDJSON,可作进程外传输的起点。

### 6.5 宿主调度 team(issue #277)

`RuntimeConfig.enable_teams` 打开后,`SessionConfig.team`(`TeamConfig`,lead/member)把一个
Session 加入宿主调度的 team。lead 的 `SpawnTeammate` 不起线程,只在
`SwarmContext.pending_spawns` 记一条请求,由 Host 创建并运行对应 member Session
(`SwarmContext.scheduler == .host`)。`swarm_tools.writeTeamDescription` 给名册与待处理请求,
`swarm_tools.pollLeadInbox` 取 lead 收件箱的下一条输入。team 成员 Host 在 create/restore 时
提供,不进 checkpoint。设计见 `SWARM_DESIGN.md` §7b,C ABI 封装见 `AGENTCORE_BINARY_ABI.md`
"Teams"。

`RuntimeConfig.enable_cron`(issue #445)把 cron 工具(`CronCreate`/`CronDelete`/`CronList`)
放进目录;选了它们的 Session 自带 `CronRegistry`(不落盘)。到期 prompt 由 Host 在空闲时经
`AgentSession.takeDueCronPrompts` 取走;`SessionHost` 的 driver 把每条变成一个
`cron_fired` Run,只取队列 `max_queued` 容得下的条数,其余仍到期留待下次;Host 经
`Snapshot.cron_jobs` 看任务、经 `cancel_cron_job`/`cancel_all_cron_jobs` 命令删任务
(#493,见 `API.md` 的 SessionHost 一节)。C ABI 不提供 cron 工具。

`SessionConfig.run_control`(issue #445)让 durable Session 的每个 Run 打开 daemon 那一套
`project_rule_activation.RunControl`:`project_rules = .enforced` 时由
`<dirname(run journal 根)>/project-rules` 的 active bundle 门控工具调用(加载失败、或仍有
后台 Bash job / team 时 Run 在 provider 请求前失败),`abandoned_run = .record_abandoned`
把死掉的 owner 留下的 Run 记为 abandoned 后继续。ephemeral Session 设置非默认值被拒
(`RunControlRequiresRunJournal`)。C ABI 不暴露它。

---

## 7. 已知约束与边界(诚实清单)

- **tree-sitter 已移除**(2026-07-13):不再有对应文档;`doc/TREE_SITTER.md` 已删除,历史见 git。
- **剩余进程全局态**:`core/answer_queue.zig`(headless 应答兜底)、`core/recorder.zig`
  (record-replay 测试)仍是进程全局。**非多租户路径**——真要并发多租户 IM 服务前,需 session
  化 answer_queue(参考权限模块 M2 的全局态搬迁手法)。其余 session 态已 per-instance。
- **跨进程恢复**:`transcript` 持久化对话(含 tool_use/tool_result),`loadTranscript` 可重建,
  但**不**持久化 in-memory registry(read_state / 后台 job / cron / activated tools)。同步前端
  无影响;异步可挂起路径(§5.3)的完整恢复需补这部分(已知,待实施)。
- **能力协商缺失**:协议未让 backend 声明能力(最大选项数 / 输入模态)。3 按钮设备如何映射 4 选项
  multi-select、语音如何表达 preview——需在接受限输入前端时加 `BackendCapabilities`(加性扩展)。
- **输出粒度**:`text_chunk` 按 token 流。语音要整句、IM 要整条(限流)、LED 要终态——backend 可
  缓冲当前段到 `output_segment_end`，再按 disposition 决定展示、合并或丢弃；`stream_done` 不是
  输出终态。
- **流存活性靠客户端自己保证**(2026-09-10 起):对端"连接活着、字节不来"时,std.http 的读没有
  超时,abort 标志只在事件之间被检查,卡在 `readv` 里的线程谁也叫不醒——一次真实故障让 TaskBatch
  的 join 和整个 TUI 冻了 40 分钟。现在每个在飞请求都登记进 `RequestAbortRegistry` 并带空闲上限:
  监视线程超时 shutdown 连接,收头阶段归为 TransientNetwork 重试,正文阶段以 `StreamStalled` 结束
  本轮(`stop_reason=api_error`);TaskBatch 看门狗、TUI 的 Esc/Ctrl+C、`abortAllRunning` 现在都真的
  调 `provider.cancel`。**两个阶段、两个上限、按字节计**(2026-09-11 起):收头阶段用严上限
  (`METACODES_STREAM_IDLE_TIMEOUT_MS`,默认 120s);响应头一到就切到正文阶段上限
  (`METACODES_STREAM_BODY_IDLE_TIMEOUT_MS`,默认按 max_tokens 放大:clamp(max_tokens × 100ms,
  10min, 30min))——napi 这类网关把整个 tool_use 参数攒成一条 `input_json_delta`,生成期间零字节,
  一个 20-40KB 的 Write/Bash 调用就是 120-200s 的真实线路沉默,平的 120s 会**确定性**杀掉
  合法长工具调用。**进展按 SSE 行计,保活不算**(2026-09-23 起):`EventIterator` 每拿到一条
  非保活行(`api/stream.zig isKeepaliveLine`:`event: ping` / `data: {"type":"ping"}` / `:` 注释
  之外的任何行,含被 `continue` 掉的 input_json_delta / unknown 事件)就 `touch` 续正文空闲时钟;
  `LivenessReader` 在传输层每次读到字节只更新"最近字节"时间戳(`touchTransport`),不续时钟。
  两者分开是因为网关在上游沉默期间照样每 15s 发 ping:2026-09-23 一条零产出的流靠 ping 活了
  55 分钟,监视线程从未开火。(旧法先是按语义事件续命——126s 的合法工具调用在字节每秒都到的情况
  下被判 stall;改成按字节续命后又把 ping 当活着。)正文 stall 经 `client.reportBodyStall` 写
  last_error,TUI 打"正文空闲超时: N ms 内无任何字节(上限 M ms)"(连接死了)或"N ms 内无模型输出,
  但网关 keepalive 仍在到达(最近字节 K ms 前)"(上游/网关卡住)而不是猜谜文案。用户 Ctrl+C/Esc
  经 `provider.cancel` 关掉 socket 后,阻塞的读以 ReadFailed/干净 EOF 醒来——三个 provider client
  与 agent_loop 都先查 abort 标志,归为 Aborted(保留已流出的 partial 文本),绝不归 api_error;
  REPL 在每个 run 边界无条件复位 abort 标志。
  **死连接按学到的保活节奏判**(2026-10-24 起):正文进展上限最长 30 分钟,一条没有 FIN/RST 就死掉的
  连接也要等满它(实录:响应头 + message_start 之后 1801 s 零字节,连网关平时 ≤15 s 一次的 ping 都
  没有)。`RequestAbortRegistry` 每个 client 一份,`touchKeepalive` 记录端点在流中途(SSE 正文、本流
  已有进展之后)用一条保活行打破了多长的沉默(≥2 s 才算样本,同一次读只算一次);攒够 3 个样本后,
  SSE 正文在传输层(含保活)沉默超过 max(4 × 最长间隔, 2 min) 且小于进展上限时,判
  `Stall.cause = .transport_dead`,TUI 打"连接已断: N ms 内无任何字节,连 keepalive 也没有…"。判死即
  清空已学证据,端点不再发保活时退回只按进展上限判;从未在流中途发过保活的端点行为不变。非流式整包
  正文与收头阶段不受此规则影响(`setIdleLimit(.., .whole)`)。
  **流中途错误的名字约定**(`api/stream.zig midStreamReadError`,三个 provider client 共用):
  `RequestFailed` 只表示连接在流中途断了;服务端在流里声明的失败一律 `ApiError`(Anthropic 错误帧、
  OpenAI chat 兼容端与 Gemini 的顶层 `error` 对象、Responses 的 `response.failed` / `error` 事件,
  经 `client.reportServerError` 写"API 错误帧"现场);`StreamStalled` / `StreamIncomplete` /
  `ContextWindowExceeded` / `Aborted` 各有专名;本地或解析类失败(`StreamTooLong`、`OutOfMemory`…)
  保留原名。
  **每个模型请求自带一次同轮重发**(#461):`agent_loop.STREAM_RETRIES_PER_REQUEST`(1)——失败是
  `StreamStalled`、`StreamIncomplete` 或 `RequestFailed`(`isSilentRetryFailure`),且失败的响应**没有
  开始任何工具调用**时,不论 Options 怎么配(TUI、headless、AgentCore 一样)都重发一次同一请求(同
  provider / wire / 模型 / 绑定,逐字节相同);失败尝试流出的文本与 thinking 一并丢弃,不进 Conversation。
  "开始了工具调用"包括参数还在流的半截调用:loop 只在块收口时才收到 `tool_use_start`,所以由各 client
  的解析器经 `StreamHandle.toolCallStarted()` 报告(Anthropic 的 `tool_use` 块开头、chat 的
  `delta.tool_calls`、Responses 的 `function_call` item 或参数增量、Bedrock 的 `toolUse` 块开头;
  Gemini 的调用整块到达,loop 自己看得到)。额度按请求计(每个 turn 重置),前面的 turn 用不掉后面的。
  `ApiError` 是服务端的答复,本地失败重发也不会变,都不重发。
  **额度之外的重发**:`max_stream_turn_retries`(headless 为 2,任何流内失败,`ApiError` 也算)与
  `Options.retractable_stream_retries`(#452,AgentCore `RunOptionsV1.stream_retry_budget`,默认 0,只限
  上面那三种失败,开始了工具调用也可以)按 Run 计、共用一个计数,在请求自己那一次用完之后才用;
  每次重发各有自己的建连重试。重发一个已流出内容的尝试时,不论用的是哪一份额度,都先告诉宿主撤回什么:
  该段照常以 `discarded` 收口;流出过 thinking 时紧跟 `thinking_discarded`(同一段的 index/turn/group
  与 thinking 字节数);再发 `retry_notice`(`attempt` = 本请求已断的流数,含本次;`max` = 本请求至多
  几次尝试:首次 + 自带一次 + Run 额度余量;`delay_ms` = `Options.stream_retry_backoff_ms`,默认
  `STREAM_RETRY_BACKOFF_MS` 500 ms),然后等这段退避再重发。退避期间 abort → Run 以 `aborted` 收口,
  不再发请求。零可见输出的重发不发这些事件、也不等。
  被丢弃尝试流式预取的只读工具结果在 `Prefetch.joinAll` 之后不可再取:重发的尝试即使复用同一个
  工具调用 id,也会真正执行该调用。仍然成立的边界:TaskBatch 的 join 有界于空闲上限,
  不会 detach 卡死的 worker;TUI 每个 provider 回合结束就刷 transcript,但一个回合内的内容仍只在
  内存里。
- **流必须报告它是怎么停的,否则不是收尾**(issue #269):四条 wire 各有一个停止报告——Anthropic
  的 `message_delta.stop_reason`、OpenAI chat 的非 null `finish_reason`、Responses 的
  `response.completed` / `response.incomplete`、Gemini 的 `finishReason`(或整条 prompt 被拒的
  `promptFeedback.blockReason`)。干净 EOF 或只有 `[DONE]` 而没有它,解析器抛
  `error.StreamIncomplete`,由 `client.reportStreamIncomplete` 写 last_error 与 Run 级的
  `api/model_error.zig` 明细(`stream_interrupted` / `retryable`,带该响应头的 status 与 request id,
  #451;明细经线程局部 Scope 归属到具体 Run,`Options.model_error_out` 取走,#408)。agent_loop 流循环里
  的兜底 `model_error.noteStreamReadError` 不覆盖已写的明细,只给没人描述过的失败定性(`RequestFailed`
  归 `stream_interrupted`,本地或解析类失败归 `unknown`)。agent_loop 把它当
  流内失败:丢弃残片,按 `Options.max_stream_turn_retries` 同轮重发,额度用尽 `stop_reason=api_error`。
  此前它被归一成 `end_turn`——丢的字节恰好是 `max_tokens` / `length` 时,截断的回答读起来是完整的,
  续写安全网不开火。报告过停止原因、只丢了帧尾(`message_stop`、`[DONE]`、其后的 usage 块)的流
  照常收尾:帧尾不携带回答的任何内容,停止原因(含 `max_tokens`)照样驱动续写。反过来,帧尾到了
  而没有停止报告(只有 `message_stop`、只有 `[DONE]`)同样是未完成。值不认识的停止原因也算
  "报告过"(`StopReason.unknown` 只用于分支,不再兼任"没报");空串、Gemini 的
  `FINISH_REASON_UNSPECIFIED` 不算。Anthropic 流里仍开着的 tool_use 块(EOF 或 `message_stop`
  时)一律算未完成——参数可能残缺,而它要在本地执行;其它没收到 `content_block_stop` 的块不拦
  (stop_reason 之后文本已完整;server_tool_use 无结果块即收尾是合法的 `pause_turn`)。Gemini 的
  停止报告按结构读(`candidates[i].finishReason`、`promptFeedback.blockReason`):`functionCall.args`
  是未转义的 JSON 对象,子串扫描会把参数里的同名键当成停止报告。取消与 stall 先于"未完成"判定。
  `RunResult.continuations` 记本次 `run` 的
  max_tokens 续写次数,headless `--json` 结果行同名字段携带它:续写后的正文是无缝拼接,只看结果
  的消费者没有别的办法知道回答被截断过。
- **续写额度用尽后仍被截断 = 显式未完成**(issue #394):一个 `run` 至多**连续**续写
  `MAX_CONTINUATIONS`(3)次;某轮不再以 max-token 收尾或带了 tool_use(模型已恢复)时连续计数
  归零,所以长任务里分散的截断不会累计耗尽额度(`RunResult.continuations` 仍记总数)。额度用尽后,没有 tool_use 的一轮仍以 max-token 终止(Anthropic `max_tokens`、chat
  `length`、Responses `response.incomplete` + `max_output_tokens`、Gemini `MAX_TOKENS`)→
  `stop_reason=max_tokens_exhausted`,该段定性 `partial`,不再走主机门、Stop hook 与 `final`
  收尾。有没有可见正文都一样:正文照样交付(`Ledger.partialText()` 是整个续写组的拼接),
  headless 结果行 `text_kind=partial`、退出码 1,不带 `--json` 时 stdout 只有已有正文、
  stderr 说明原因(#417),`--stream-json` 时间线是
  `continued → … → partial`;AgentCore ABI v1 报 `api_error`(RunState `failed`),Session
  可接着跑下一个 Run(`AGENTCORE_BINARY_ABI.md`)。此前只有无正文的一轮走这里,带正文的被当成完成的回答
  (`end_turn` / `final`,退出码 0)。完整的 tool_use 照常执行,不算耗尽;续写中途正常收尾
  的仍是一个 `final` 回答。
- **permission 门不可挂起**:权限确认是 `executeSlots` 前的同步门,异步挂起暂不覆盖(out of scope)。
- **Bash 的文件修改是工作区观测,不是命令自报**(§3.2.2)。被忽略的文件、symlink、工作区根之外
  的路径看不见;同一执行窗口里其他写者的修改会算进这次调用(包括此前转入后台、仍在运行的作业);
  只读分类器放行的命令不观测;同长度改写依赖文件系统时间戳粒度,若该文件恰在观测前同一时钟刻内
  刚被写过,可能漏报。命令里若有刷新 index 的 git 操作(`git status`/`diff`/`add`),干净文件
  的"执行前"不再可信,这次调用的修改只报不带 diff。观测本身没能覆盖调用时报 `lost`,不会静默。
  每次非只读 Bash 约多 75 ms(2 千文件的仓库,ReleaseSafe 实测)。MCP 工具、插件等其他来源的
  文件修改仍不产生 `file_changes`。
- **输出段兜底定性排在 `diag_run_end` 之后**(§3.2.1)。所有显式定性路径都在 run 收口前关闭段;
  兜底(`defer` 把仍打开的段记为 `partial`)只在遗漏时生效,顺序因此靠后。
- **`--stream-json` 已投影输出段定性**(`output_segment_begin/end` 行),但**未投影 file_changes**
  ——那条事件带整段 diff,塞进逐行时间线会把流撑爆;需要文件修改的消费者走 `--json` 结果行的
  `file_changes` 数组或直接消费 CoreEvent。TUI 对两组事件都 no-op(边流边渲染,不需要事后重标)。
- **AgentCore 的既有 `on_event` JSON 观察流已导出 `output_segment_begin/end` 与
  `file_changes`**。前者完整携带段标识、定性和字节数；后者直接保留 Core 的批次、逐文件
  结果、定位符、字节数和有界 diff。它们都是 Revision 14 下可前向兼容的新增观察 tag；旧
  SDK 会把它们保留为 `unknown`。
- **ApplyPatch phase-1 校验失败**(解析错/定位不到/Add 撞已存在)只对**已建好计划**的文件报
  `rejected`;触发失败的那个文件还没进计划表,只出现在工具错误 detail 里。整批零落盘,故没有
  谎报,但目标清单不完整——登记而非假装完整。

---

## 8. 验证 core 健康的命令

```bash
zig build                 # 主二进制(含 TUI 前端)
zig build test            # 全单测(含协议/工具/权限)
zig build test:lib        # refAllDecls 编 core 的公开声明 = 库能单独编译
zig build subsystem:boundary  # ★ core 的 import 闭包够不到应用侧(源码层检查)
zig build example         # 跑 example/ 最小前端(真端点;离线见 LIB_API.md §1)
```

**`zig build subsystem:boundary` 绿 = core 不依赖任何前端**——这是平台内核最该守的不变式,每次改 core 后必跑
(`zig build test` 经 `test:units` 也会跑它)。

---

## 9. 导航

- 第三方 AgentCore 二进制接入:`doc/LIB_API.md`
- 最小前端示例:`example/main.zig`(`zig build example`)
- 多 session 设计:`doc/history/MULTI_SESSION_REFACTOR.md`(历史快照;metaknow scope metask_business `MULTI_SESSION_REFACTOR`)
- 设计文档总入口:metaknow scope `metask_business`(PLAN/SUBAGENT/PERMISSION/TOOLS 等根)
- 操作命令/API 规范:`doc/API.md`
