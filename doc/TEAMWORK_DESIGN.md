# metacodes Teamwork — 设计文档

> 状态:阶段 0(共享类型、配置、运行目录、预算账本)、内置 reviewer(评审结果契约、证据核验、
> open-issues 台账,§6)与 seat 驱动(metacodes 子 agent、Claude Code 子进程、写入隔离,§7)已落地于
> `src/teamwork/`;runtime 编排、独立完成审计与合回已接入,见 §10。用户入口与 MCP Manager 的
> 使用方式以 [API.md](API.md) 与 [TEAMWORK_MCP.md](TEAMWORK_MCP.md) 为准。
> 来源:umbrella issue #514 及子 issue #515–#525。工作方式借鉴 Google Antigravity 的
> `/teamwork` 预览功能(先批准再开跑、写的人不验、完成必须审计、状态全部落盘);本文与代码中的
> 角色定义、契约和文字均为原创,未复制其任何提示词或文本。

## 0. 定位

teamwork 是一个**显式开启**的运行模式:用户批准一份任务说明后,Manager 把工作派给若干
**seat**(interviewer、implementer、reviewer、verifier),每个 seat 可以由不同的 harness 承担。

Teamwork 属于统一 **preview** 特性,默认关闭。使用 `--preview` 或状态根 `config.json` 根键
`"preview": true` 开启;`--no-preview` 覆盖保存值,最后一个 CLI preview flag 生效。它与
ExecuteCode 共用 `PreviewSetting`、`FileConfig` 与 `resolvePreview`,没有单独的 teamwork
preview 开关。`--preview` 不代替原任务的 `--approve`、预算、权限或沙箱授权。

宿主当前的 `runtime.Deps.preview` 默认 false,不写入已批准任务配置,也不从 checkpoint 恢复。
`start/reopen/dispatch/requestCompletion` 在执行前检查;关闭时不得创建或恢复运行、启动 seat
或其探测、调用模型、花费预算、审计或合回。模型与 MCP 的同名字段不能恢复授权。
只读状态、已有句柄的取消与销毁/清理继续可用;并发停止仍经原有 abort 信号。CLI 在 App
初始化前也使用同一配置解析,当前关闭设置优先于旧运行的批准记录。

与 swarm([SWARM_DESIGN.md](SWARM_DESIGN.md))的区别:swarm 是一组对等 teammate 经邮箱和
任务 DAG 自组织;teamwork 是一条固定流水线(面试 → 批准 → 实现 ⇄ 评审 → 审计 → 合回),
由 metacodes runtime 掌控每一步的输入、输出、预算和完成判定。

## 1. runtime 与 seat 的分工

| 层 | 承担者 | 拥有 |
|---|---|---|
| **runtime** | 永远是 metacodes | 运行目录、`ORIGINAL_REQUEST.md`、预算账本、权限与沙箱、完成审计、宣布完成、合回工作区 |
| **seat** | 任一 harness(`metacodes` 进程内子 agent,或 `claude_code` 外部 CLI 子进程) | 只产出产物:`handoff.md`、`progress.md`、工作区里的改动 |

Manager 也是一个 seat:它只能"提议完成",宣布完成的只有 runtime,而且在审计通过之后。
任何 seat 都不能绕过 kernel 边界(权限、沙箱、预算、formal verdicts、TinyKG admission、
artifact CAS)。

## 2. worker 契约

`src/teamwork/types.zig` 中的 `SeatDriver` 是所有 harness 的统一接口:

```zig
pub const SeatPaths = struct { packet: []const u8, handoff: []const u8, workspace: []const u8 };

pub const SeatDriver = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const Error = error{OutOfMemory};
    pub fn run(self: SeatDriver, gpa: Allocator, spec: *const SeatSpec,
               paths: SeatPaths, abort: *const AbortSignal) Error!SeatOutcome;
};

pub const SeatOutcome = union(enum) { finished: Handoff, failed: SeatError, budget_exhausted, aborted };
```

- **输入**:packet 文件路径 + workspace 目录(实现者是独立 worktree)。
- **输出**:固定路径的 `handoff.md` + 退出状态;git diff 由 runtime 自己采集。
- harness 层的一切失败(起不来、非零退出、被信号杀、handoff 缺失或不合格、预算耗尽、中止)
  都是 `SeatOutcome`,不是 Zig error;唯一的 error 是内存不足。
- **runtime 从不解析任何 harness 的 transcript**,只看产物。驱动在 harness 正常退出后调用
  `run_dir.collectHandoff`,所以各 harness 对"正常退出"的报告方式完全一致。

`handoff.md` 必须恰好包含五个二级标题段,各出现一次且非空:

```markdown
## Observation
## Reasoning
## Caveats
## Conclusion
## Verification
```

`Handoff.parse` 是严格解析:缺哪段就返回对应的 `MissingObservation` … `MissingVerification`;
重复段 `DuplicateSection`;空段 `EmptySection`;其他二级标题 `UnknownSection`(标题区分大小写)。
代码围栏内的 `##` 行是正文;第一个段之前的文字(如 `# Handoff` 标题)被忽略。

真实驱动是 `drivers/metacodes.zig`(进程内子 agent)与 `drivers/claude_code.zig`(外部 CLI
子进程),见 §7;`stub_driver.zig` 是仅供测试的驱动,按脚本扮演 harness。

## 3. 配置

`src/teamwork/config.zig`,三步都是纯函数:

1. `parse(arena, text, diag) ParseError!Layer` / `parseValue(arena, std.json.Value, diag)`:
   把一个来源的 `teamwork` 对象解析成 `Layer`(每个字段都可缺省)。
2. `merge(lower: Layer, upper: Layer) Layer`:后者覆盖前者,不分配内存。
3. `validate(layer: Layer, diag) ValidateError!Config`:得到 `Config = union(enum) { disabled, enabled: Enabled }`,
   其中每个角色是一个 `types.SeatSpec`。

```json
{
  "teamwork": {
    "enabled": true,
    "budget_usd": 5,
    "check_command": "zig build test",
    "seats": {
      "implementer": { "harness": "claude_code", "command": "/opt/claude/bin/claude", "model": "m", "effort": "high" },
      "reviewer":    { "harness": "metacodes" },
      "verifier":    { "harness": "claude_code", "command": "/opt/claude/bin/claude", "demote_only": true,
                       "budget_enforcement": "wallclock_only", "wallclock_seconds": 900 }
    }
  }
}
```

**分层**(低 → 高):`<state root>/config.json` 的 `teamwork` 段 →
项目的 `.metacodes/teamwork.json` → 命令行覆盖(如 `--teamwork-budget-usd`)。逐字段覆盖;
例外是高层把某个 seat 换成另一种 harness 时,低层为旧 harness 写的 `command`、
`budget_enforcement`、`wallclock_seconds`、`demote_only` 先被丢弃(`model`、`effort` 保留)。

**默认值**:没写的角色一律是 `metacodes` seat;外部 seat 的 `budget_enforcement` 默认 `cost`。

`check_command`(可选,顶层)是宿主钉住的检查命令,`Config.Enabled.check_command: ?CheckCommand`。
runtime 用它核验 reviewer 的批准(§6.2);各层逐字段覆盖,与其他标量相同。

`candidates`(可选,顶层,#525)开启并行候选:整数 N(1–4,1 即不开启)让每个候选都用
`seats.implementer`;数组(2–4 项,每项与 seat 对象同格式)给每个候选单独的 implementer seat,
可以混用 harness。开启时必须同时给 `candidate_estimate_usd`(一个候选的预估花费),runtime 在
启动前检查 N 倍预估不超过剩余预算(§10.1)。`seats.judge` 配置择优的 judge seat,默认 metacodes。
两个字段由高层整体覆盖低层。结果是 `Config.Enabled.candidates`(`slice()` 给出每个候选的
`SeatSpec`)与 `candidate_estimate_usd`。没有候选的配置,配置指纹与引入候选之前逐字节相同,
旧运行照常恢复。

`manager_budget_usd`(可选,顶层,#545)是外部 Manager 的美元额度,从 `budget_usd` 中划出。
`seats.manager` 配成 `claude_code` 时必须给出,且只能用 `cost` 预算;此时 runtime 自己启动这个
Manager(§10.2)。Manager 为默认 `metacodes` 时即内置确定性 SWE loop,不能写这个字段。没有这个
字段的配置,配置指纹与引入它之前逐字节相同。

**校验规则**(每条一个 error,各有单元测试):

| 规则 | error |
|---|---|
| 未知字段 / 角色 / harness / effort / budget_enforcement | `UnknownField` / `UnknownRole` / `UnknownHarness` / `UnknownEffort` / `UnknownBudgetEnforcement`(解析阶段) |
| 类型错误、空字符串、负数 | `WrongType` |
| `claude_code` 没有 `command` | `ExternalCommandMissing` |
| `command` 不是绝对路径(从不查 `PATH`) | `ExternalCommandNotAbsolute` |
| `metacodes` seat 带 `command` | `MetacodesSeatHasCommand` |
| `metacodes` seat 带 `budget_enforcement` / `wallclock_seconds` / `demote_only` | `ExternalOnlyField` |
| 外部 harness 的 verifier 没有 `demote_only: true` | `ExternalVerifierNotDemoteOnly` |
| 非 verifier 写了 `demote_only` | `DemoteOnlyOutsideVerifier` |
| `wallclock_only` 没有 `wallclock_seconds` / 为 0 | `WallclockLimitMissing` / `InvalidWallclock` |
| 有 `wallclock_seconds` 却不是 `wallclock_only`(否则静默无效) | `WallclockWithoutWallclockOnly` |
| `enabled: true` 没有 `budget_usd`(付费运行必须有美元上限) | `BudgetMissing` |
| `budget_usd` 不是有限正数 | `InvalidBudget` |
| `check_command` 为空白、超过 1024 字节或含 NUL | `InvalidCheckCommand`(空字符串在解析阶段即 `WrongType`) |
| reviewer 是外部 harness 却没有 `check_command`(其工具调用不可观测,批准将永远无法核验) | `ExternalReviewerWithoutCheck` |
| `candidates` 为 0 或大于 4,或数组少于 2 项、多于 4 项 | `InvalidCandidates` |
| 有两个以上候选却没有 `candidate_estimate_usd` / 有它却没有候选 / 它不是有限正数 | `CandidateEstimateMissing` / `CandidateEstimateWithoutCandidates` / `InvalidCandidateEstimate` |
| 外部 Manager 没有 `manager_budget_usd` / 内置 Manager 却有它 / 它不是小于 `budget_usd` 的有限正数 | `ManagerBudgetMissing` / `ManagerBudgetWithoutExternalManager` / `InvalidManagerBudget` |
| 外部 Manager 是 `wallclock_only`(花费未知,不能当作零) | `ExternalManagerWallclockOnly` |

即使 `enabled` 为假,所有 seat 也照样校验,坏配置在启动时就报错。`Diagnostic` 记录出错的
角色和字段。类型层面同样排除了非法状态:`HarnessConfig = union(Harness) { metacodes, claude_code: ExternalHarness }`,
metacodes seat 根本没有放 `command` 的位置;`BudgetEnforcement.wallclock_only` 自带
`WallclockLimit`。

**CLI 接线**:`src/teamwork/command.zig` 从 `<state root>/config.json` 读出
`teamwork` 成员交给 `config.parseValue`,仓库根目录 `.metacodes/teamwork.json`
交给 `config.parse`,再叠加 CLI Layer,经 `merge` / `validate` 后才启动 App。
入口是 `metacodes teamwork run --request-file <file> --approve --budget-usd <cap>`;
配置及请求没有显式批准时,不启动 provider、不建运行目录或 worktree。
`--config-json` 可覆盖 seat 的 harness/model/effort;`--max-rounds` 与
`--check-command` 接入 runtime 的真实 dispatch cap / pinned check。

CLI 使用请求文件,`--approve` 直接批准请求文件,不执行 interviewer。Manager 默认是确定性
SWE loop(不接受 model/effort);`seats.manager` 为 `claude_code` 时由 runtime 启动外部 Manager
(§10.2)。`teamwork mcp` 拒绝外部 `seats.manager`(`UnsupportedManager`):那里 MCP 客户端就是 Manager。

**请求参数段与面试(#518)**:`src/teamwork/interview.zig`。请求开头可以有若干方括号参数段:
`[skip-interview]` 与 `[seats=<role>:<harness>[:<model>],...]`。`parseSegments` 去掉参数段,
其余文本即待批准文本;没有前导 `[` 时原样使用。`seats` 是只对本次运行生效的配置层,位于
项目配置之上、CLI 覆盖之下。未知、重复、未闭合或格式错误的参数段直接报错,不当作请求文本。
REPL `/teamwork <请求>` 先检查 `teamwork` preview 特性(关闭时明确报错,不退化成普通对话),再按同样的分层
加载配置;未带 `[skip-interview]` 时由 `interview.draft` 在运行目录里以 `interviewer-1` 运行
interviewer seat(任意 harness):工作目录是工作区快照的临时 worktree(`interview/`,结束即删),
花费记入同一运行的预算账本,packet 只含固定文本与用户请求。草稿是 handoff 的 Conclusion 加
Verification。REPL 把 `app.abort` 转发给面试(Ctrl+C 取消 interviewer,结束后复位,不影响下一条消息)。
`interview.approve` 连同批准所授权的预算、seats、固定检查与合回目标一起展示,让用户批准、修改(替换全文后再次确认)
或拒绝;`[skip-interview]` 同样经过这一步,只是展示的是原始请求;批准的字节
原样交给 `Run.start` 写入 `ORIGINAL_REQUEST.md`,之后才派任何 implementer/reviewer。
`ApprovedRequest.source`(`request_file` / `skip_interview` / `interview` / `user_edited`)
写入 `run.json` 的 `request_source`,恢复时保留,`teamwork status` 一并输出。REPL 用
`AgentJobRegistry.makeProvider` 给运行单独的 provider client,在后台线程驱动 SWE loop,
提示用户“已开始,可随时用 `/teamwork status` 询问进度”;退出 REPL 会取消未结束的运行,
可用 `teamwork resume` 继续。
`command.Host` 向 worker、pinned check 和 verifier 提供强制沙箱,state root 必须在仓库外。
`run.json` 在创建候选 worktree 前原子保存批准配置、继承模型和宿主权限指纹。`teamwork resume <id>
--approve` 使用这份配置,拒绝权限和沙箱策略发生变化的恢复请求。`teamwork status <id> [--json]` 只读运行文件,缺失账本为空,
pending receipt 只展示不结算。`teamwork mcp` 复用批准门禁,由
`McpHost.serveFn(gpa, run)` 接管 live Run 的管理。完整 CLI 合约见 [API.md](API.md),
真实 CLI consumer 测试见 `tests/component/teamwork_command_test.zig`(假 harness / 本地 mock)。

## 4. 运行目录

`src/teamwork/run_dir.zig`,根在**工作区之外**:

```
<state_root>/teamwork/<run_id>/
  ORIGINAL_REQUEST.md     只写一次;审计的基准(用户批准后才写)
  interview/              面试期间的临时快照 worktree,面试结束即删(#518)
  budget.jsonl            预算账本(§5)
  budget.jsonl.hold       外部 Manager 的额度保留(§5、§10.2),结算后删除
  manager-relay.sh        外部 Manager 的 MCP 中继脚本(§10.2),runtime 写
  open_issues.json        评审发现台账(#517),初始为 []
  candidates/candidate-<n>/  并行候选各自的 worktree(#525);选中后只留选中的那个
  judging/                judge 的工作目录:合格候选的 candidate-<n>.diff 与 candidate-<n>.review.json
  seats/<seat_id>/
    packet.md             runtime 写
    handoff.md            seat 写
    progress.md           seat 写
  seat-status/<id>.json   runtime 写:{seat_id, role, harness, status}，不在 worker 可写目录内
    review.json           reviewer seat 写(§6.1)
    judgment.json         judge seat 写(§10.1)
    open_issues.json      runtime 写给本 seat 的台账只读副本(§6.3)
    harness.log           Claude Code 驱动写:CLI 的 stderr 与兼容性诊断(§7.4)
```

- `RunId` / `SeatId` 是互不相同的类型,字符集 `[a-z0-9][a-z0-9_-]*`(≤ 64 字节),直接当目录名,
  不可能含分隔符或 `..`。约定的 seat id 由 `seatIdFor(role, n)` 生成(`implementer-1`)。
- `RunDir.create` 拒绝接管已存在的目录(`RunExists`);`RunDir.open` 用于重启后重新进入。
- `writeOriginalRequest`:先写临时文件并 fsync,再以不覆盖方式安装(`pfs.installNoReplace`);
  第二次写返回 `OriginalRequestExists`,崩溃不会留下半截请求。
- seat 状态经独占创建临时文件后 rename 原子替换。评审索引也放在控制器目录中。
  `SeatStatus` 为
  `queued / working / needs_you / waiting / done / failed`。
- `recover()` 只凭目录内容重建 seat 表:每个名字合法的 `seats/<id>/`,读得出记录的给出
  `recorded`(含 `has_handoff`),读不出的(建目录后、首次写 status 前崩溃,或记录被破坏、
  记录里的 seat_id 与目录不符)给出 `damaged`,由 runtime 决定重新登记还是放弃;临时文件和
  非法名字忽略。结果按 seat id 排序。
- 所有带路径的文件操作都经 `src/platform/fs.zig` 与 `src/platform/dir.zig`。

**缓存契约**:run id、时间戳和运行目录的绝对路径都不进入 metacodes 发给 provider 的字节。
packet 引用同一运行里的其他文件时,用相对于 seat 目录的路径(`seat_relative_original_request`
= `../../ORIGINAL_REQUEST.md`、`seat_relative_open_issues`);metacodes seat 只看到稳定别名
`$WORKSPACE` 与 `$SEAT`,真实路径由工具准入层解析(§7.1),不进入宪章、首条消息或 Manager 的
提示词。宿主日志、状态文件与诊断照常记录真实路径。写入隔离(seat 只能写工作区和自己的 seat
目录)由执行策略、权限层和沙箱保证,不靠提示词(§7.3)。

## 5. 预算账本

`src/teamwork/ledger.zig`,`budget.jsonl` 每行一条:

```json
{"seat_id":"implementer-1","harness":"claude_code","usd":0.42,"wallclock_ms":61000,"source":"harness_reported"}
```

- `source` 为 `provider_estimate`(metacodes 自己的估算)、`harness_reported`(外部 harness 结果
  事件里的花费)或 `wallclock_only`(读不到花费,`usd` 为 null)。类型上 `Cost = union(Source)`,
  有金额当且仅当来源有金额。另有 `reserved` 金额:成本报告丢失时保守消耗剩余额度,
  它是预留额度,不能解释为实际账单。
- `Ledger.charge` 先追加并 fsync,再更新合计;合计达到上限(`spent >= cap`)时返回
  `BudgetExhausted`,但这笔仍然入账(钱已经花了),之后每一笔都返回 `BudgetExhausted`。
  负数、NaN、无穷拒收(`InvalidAmount`),不入账。
- `Ledger.load` 从磁盘重新求和。最后一行没有换行符说明追加时崩溃:丢弃并把文件截断到最后一个
  完整行,保证下一次追加从新行开始;**完整行**解析失败则不是崩溃产物,返回 `CorruptLedger`
  (预算数据宁可停也不猜)。
- `remainingUsd()` 是 metacodes seat 子 agent 的 `cost_budget_usd`(`src/core/subagent.zig`),也是
  Claude Code seat 的 `--max-budget-usd`(§7)。
- 账本只有 runtime 写,不是线程安全的,由 runtime 串行化。

在 metacodes、成本受限的 Claude Code seat 或 verifier 开始付费工作前,runtime 先写入并 fsync
`budget.jsonl.pending`,记录该 seat 获准使用的剩余额度。预留先写临时文件并 fsync,再以不覆盖方式
原子安装;写临时文件时中断不会留下半份有效预留,重试也不会覆盖旧预留。正常结束的 durable charge 清理该记录。
控制器崩溃后,`Ledger.load` 若只找到预留而没有该 seat 的完成记账,就把预留作为 `reserved`
入账并停止继续花费;若完成记账已落盘则只清理旧预留,不重复扣除。显式 `wallclock_only` 仍然
只承诺时间上限。成本模式下,缺少有效结果/花费报告不会被当作零花费后继续重试。

外部 Manager(§10.2)与 worker 同时运行,所以它的额度是另一份回执 `budget.jsonl.hold`
(`Ledger.hold`),写法与 pending 相同(临时文件 fsync 后不覆盖地安装)。持有期间这笔额度不计入
`remainingUsd()`,worker 和审计都用不到;`isExhausted()` 按已花加保留计算。Manager 的记账结算并
删除它;重开时没有结算的保留按 `reserved` 全额入账一次,之后的重开不再重复扣除。额度必须给其他
seat 留下余量,否则 `BudgetExhausted`。

## 6. 内置 reviewer 与 open-issues 台账(#517)

`src/teamwork/reviewer.zig` 与 `src/teamwork/issues.zig`。reviewer seat 可以是任何 harness;
评审是否成立由 runtime 按机制判定,不看 seat 自己怎么说。

**内置、不可被遮蔽**:宪章 `reviewer.charter` 是编译期常量(原创文本),`charterSha256()` 供运行
记录;工具为 `Read`、`Grep`、`Glob`、`Bash`(`reviewer.tools`)。teamwork seat 从不经过
`AgentDef` 查找(同 [ISOLATED_VERIFIER_DESIGN.md](ISOLATED_VERIFIER_DESIGN.md) §2),所以项目里
名为 `reviewer` 的 agent 只影响 `Agent` 工具,不影响 teamwork 评审;有单元测试固定这一点。

### 6.1 评审结果契约

reviewer seat 除 `handoff.md` 外,在自己的 seat 目录写 `review.json`:

```json
{
  "verdict": "approve" | "request_changes",
  "evidence": [{"command": "zig build test", "exit_code": 0,
                "output_digest": "<64 位小写十六进制 sha256>", "output_excerpt": "..."}],
  "issues": {
    "opened": [{"id": "可选", "title": "...", "detail": "...", "file": "可选", "line": 12}],
    "closed": ["issue-1"],
    "still_open": ["issue-2"]
  }
}
```

`Review.parse` 严格解析(上限 256 KiB):未知键 `UnknownField`、缺键 `MissingField`、类型或范围
错误 `WrongType`、`UnknownVerdict`、`InvalidDigest`、`InvalidIssueId`、`LineWithoutFile`、
同一列表内重复 `DuplicateIssueId`、同一 id 既关闭又未解决 `ConflictingIssueStatus`。矛盾的评审在
类型上不可表示:`Verdict.approve` 只有 `NonEmptyEvidence`(首项 + 其余)和 `closed`,没有
`opened` / `still_open` 的位置,所以无证据的批准是 `ApproveWithoutEvidence`,开新问题或留问题的
批准是 `ApproveWithOpenIssues`;`request_changes` 既不开也不留问题是 `RequestChangesWithoutIssues`。
`opened[].id` 给出时即成为该问题的稳定 id,否则 runtime 分配 `issue-<n>`。

### 6.2 证据核验

`judge` / `judgeSeat` 给出 `ReviewOutcome = approved: Approval | changes_requested: Summary |
review_rejected: RejectReason`;`review_rejected` 由编排器再开一轮。顺序:

1. **零修改**:runtime 在 seat 运行前后各取一次工作区树 id(`workspaceTree`),不同即
   `reviewer_edited_workspace`。
2. **台账引用**:`closed` / `still_open` 必须是台账里仍打开的 id,`opened` 的 id 不得已存在,
   否则 `issues_invalid`;批准后仍有打开的问题为 `open_issues_remain`(没提到的旧问题保持打开)。
3. 仅对 approve 核验证据:
   - **metacodes seat**:每条证据必须对应 seat 真正跑完的一次 `Bash`(命令逐字节相同,只忽略首尾
     空白;退出码相同),否则 `evidence_not_observed{index}`。来源是 `BashCallLog`:它的 `sink()`
     接到 seat 的 `SpawnOptions.tool_observer`,事件原样转发给 `next`(运行 journal)。观测走
     `tool_exec` 的分派缝:`ToolObservationSink` 新增可选 `tapFn`,在 `dispatch_finished` 被接受后
     收到本次分派的明文输入与结果(`DispatchTap`)。它不是 `Event`,journal 不设 `tapFn`,所以
     journal 仍只记哈希。被自动转后台、结果里没有 `exit_code` 的 Bash 调用不记录。
   - **任意 seat**:配置了 `check_command` 时,证据里必须有这条命令(否则 `check_not_in_evidence`),
     其声称的退出码必须为 0(否则 `check_failing`);runtime 再用 `CheckRunner` 在工作区重跑**这一条**
     命令——与 Bash 工具同一路径:启用沙箱时经 `sandbox/exec.zig` 包裹(`failIfUnavailable` 时拒跑,
     绝不降级裸跑),经平台 shell 执行,cwd 为工作区——退出码不同即 `check_disagrees{claimed, actual}`,
     跑不起来、超时或沙箱不可用即 `check_unavailable`。runtime 从不执行 seat 给出的命令。
   - 不可观测的 seat 且没有 `check_command`:`unverifiable`(配置校验已拒绝外部 reviewer 缺
     `check_command`,这里是 runtime 的兜底)。
4. 通过后应用台账,`judgeSeat` 原子写回 `open_issues.json`;被拒的评审不改台账。

**批准绑定最终 diff**:`Approval.tree` 记录评审看到的工作区树 id。宣布完成前 runtime 调
`confirmApproval`,树变了(含新增未跟踪文件;`.gitignore` 忽略的构建产物不算)即 `stale`,批准作废。
`workspaceTree` 用临时索引(先复制工作区的 index,放在运行目录里)执行 `git add -A` 与
`git write-tree`,不动工作区的 index 和文件,唯一副作用是对象库里的 blob。复制索引后先重新读取
所有已跟踪文件,避免复制后的新索引时间戳让 Git 的 stat 缓存漏掉同大小修改。控制器的 Git 调用通过
`util/controller_git.zig` 逐次禁用 hooks、fsmonitor 和所有已配置的 clean/smudge/process filter
(含 include 引入的配置),不改仓库配置;过滤器不转换候选文件内容,也不会执行工作区里的过滤脚本。
配置查询失败、结果被截断或过滤器过多时拒绝计算,不降级到未受限的 Git 调用。

### 6.3 open-issues 台账

`open_issues.json` 只有 runtime 写,是一个数组,每个开过的问题一项:

```json
[{"id":"issue-1","state":"open","title":"...","detail":"...","file":"src/a.zig","line":12,
  "round_opened":1,"round_closed":null}]
```

关闭的问题保留为墓碑,id 永不复用。`Ledger.check` 只校验不修改,`Ledger.apply` 全有或全无;
`Ledger.load` / `save` 读写运行目录;`writeSeatCopy` 在 seat 目录放一份只读(0444)副本,packet 用
`run_dir.seat_relative_open_issues_copy` 指向它;`renderOpen` 把仍打开的问题渲染成 packet 段落
(按开出顺序,不含路径、run id、时间,是稳定的提示前缀)。`reviewer.renderPacket` 组装 reviewer
packet:原始请求的相对路径、钉住的检查命令、未解决问题、`review.json` 格式。因为每轮都从磁盘台账
渲染,换了 reviewer seat 或 harness,上一轮没解决的问题照样出现在下一轮。

## 7. seat 驱动(#515、#519、#520、#521)

`src/teamwork/drivers/`。`factory.zig` 是唯一按 harness 分派的地方:

```zig
pub const Deps = struct { metacodes: metacodes.Deps, claude_code: claude_code.Options };
pub const Driver = union(Harness) { metacodes: MetacodesDriver, claude_code: ClaudeCodeDriver,
                                    pub fn driver(self: *Driver) SeatDriver };
pub fn forSeat(spec: *const SeatSpec, deps: Deps, binding: common.Binding) Driver;
// common.Binding = struct { ledger: *Ledger, seat: SeatId }
```

`spec` 来自校验过的 `config.Config`;一个 `Driver` 服务一个 seat,向 `binding` 的账本记这个 seat 的账。

### 7.1 两种 harness 共用的部分

- **bootstrap**(`common.bootstrap`):编译期常量,两种 harness 逐字节相同(metacodes 的首条用户
  消息开头、Claude Code 的 `-p` 提示词)。它只用相对 seat 目录的文件名:读 `packet.md`,写
  `handoff.md`(五段)。没有 run id、路径、时间戳。
- **seat 目录在哪是环境事实,不是指令**:Claude Code 经 `--add-dir <seat 目录>` 得知(由它自己的
  环境段告诉模型);metacodes 子 agent 经首条用户消息里 bootstrap 之后的 `<seat-environment>` 块,
  块里只写别名 `$WORKSPACE`(工作区,也是当前目录)与 `$SEAT`(seat 目录),首条消息是编译期常量
  `metacodes.first_message`。
- **路径别名(#544)**:`spawnAgentSink` 的 `path_aliases` 进入 agent_loop。工具调用参数经
  `canonicalizeArgsWithAliases` 准入时,顶层 `file_path`、`path`、`notebook_path` 若是 `$NAME` 或以
  `$NAME/` 开头,就换成真实目录;`$SEATS/x`、`a/$SEAT`、嵌套对象和其他参数(如 Write 的
  `content`)不动。PreToolUse hook、权限判定、执行策略、流式预取、工具本身和观测 sink 读的都是
  这同一份参数,所以 `$SEAT/../<别的 seat>`、`$WORKSPACE/..`、经符号链接的路径和直接写真实路径
  受到完全相同的检查。模型的 transcript 保留它写的别名。Bash 命令文本不改写,工具在命令前加
  `export WORKSPACE='…' SEAT='…'`,沙箱照旧按物理路径限制写入;reviewer 证据比对的仍是模型
  写的命令。隔离 verifier 的 packet 写 `path: $WORKSPACE`,`$WORKSPACE` 解析到候选快照。
  于是同一请求、角色和文件内容,换 state root 与 run id 后,metacodes seat 的首个 provider 请求
  (system、tools、首条 user message)逐字节相同(`drivers_test` 有断言)。
- **外部 harness 的边界**:Claude Code seat 中 runtime 控制且跨运行稳定的输入是 `-p` 的
  bootstrap、`--append-system-prompt` 的宪章,以及 argv 里除 `--add-dir` 取值以外的全部参数
  (`drivers_test` 断言两次运行只有这一项不同)。seat 目录的真实路径和 cwd 由 CLI 自己写进它生成的
  环境消息,再加上它自己的日期、git 状态等;这些内容和 CLI 的 transcript 由 Claude Code 生成,
  runtime 不控制,也不保证它们跨运行稳定。
- **宪章**(`charters.forRole(role)`):interviewer、implementer、manager、judge 为原创文本;reviewer 即
  `reviewer.charter`(§6);verifier 是标明的占位,真正的宪章在 verifier 模块(#516)。
  两种 harness 都收到同一角色宪章(Claude Code 通过 `--append-system-prompt`)。
  `charters.digest(role)` 是编译期 SHA-256,runtime 将其写入控制器的 seat 状态文件,恢复时保留。
- **判定顺序**:中止 → `aborted`;预算停(子 agent 因 `cost_budget_usd` 停、Claude Code 报
  `error_max_budget_usd`、wallclock_only seat 到时、账本写不进)→ `budget_exhausted`;硬超时 →
  `failed.timed_out`;被信号杀 → `failed.signaled`;非零退出 → `failed.exited`;否则
  `run_dir.collectHandoff` 按 handoff 判定。一笔钱只要花了就先记账再判定;记账让总额到顶时,
  已完成的 handoff 照样返回,停不停所有 seat 由 runtime 看 `Ledger.isExhausted()` 决定。

### 7.2 metacodes 驱动

`MetacodesDriver.init(deps: metacodes.Deps, binding)`,`Deps` 显式给出 provider、Anthropic
client(可空)、宿主工具定义、宿主权限上下文、宿主沙箱设置(可空)、home、state root、artifact
root、session、`max_turns`。可选字段 `tool_observer` 接一个额外的工具观测 sink(reviewer seat 接
`reviewer.BashCallLog.sink()`)。经 `subagent.spawnAgentSink` 运行:系统提示词 = 宪章加 preview 注释指导
(`COMMENT_GUIDANCE`);cwd =
工作区且 `resolve_relative_paths = true`;额外目录 = seat 目录;`cost_budget_usd =
ledger.remainingUsd()`;`spec.model`/`spec.effort` 作为覆盖。用量经 `WriterBackend` 的 usage
累加器收集,结束后按模型单价折算,以 `provider_estimate` 入账。

### 7.3 写入隔离(metacodes seat)

`write_scope.zig`,三层各自成立:

| 层 | 机制 | 管什么 |
|---|---|---|
| 执行策略 | `Scope.executionPolicy()` 作为 `SpawnOptions.execution_policy`,agent_loop/tool_exec 在工具运行前最后一道检查,与权限模式、allow 规则无关 | 只提供该角色的工具(`toolsFor`:implementer = Read/Grep/Glob/Write/Edit/Bash;reviewer = `reviewer.tools` + Write;其余角色 = Read/Grep/Glob/Bash/Write);Write/Edit 的目标按工具自己的解析方式求出后**物理**落在写根内(符号链接解析,含尚不存在的尾部;悬空链接拒绝);写根 = seat 目录,implementer 另加工作区;Bash 必须只读或确实在沙箱内运行 |
| 权限 | 宿主权限上下文派生:`acceptEdits`、工作目录集 = 工作区 + seat 目录、`no_interactive_prompt`、无 UI 请求器、无会话记忆、无 memdir 豁免 | 需要询问的一律拒绝;宿主 deny 规则、settings、hooks 照样生效 |
| 沙箱 | `seatSandbox`:始终要求后端(macOS Seatbelt;Linux bubblewrap + seccomp)、`failIfUnavailable`、不可绕过(`allowUnsandboxedCommands = false`),丢弃宿主的 `allowWrite` 与 `excludedCommands` | Bash 和原生文件执行器只能写工作区和 seat 目录。`TMPDIR` 指向本 seat 目录。后端不可用即拒绝 seat |

Linux 上 implementer seat 的 Bash 跑在 bubblewrap 里:根目录只读挂载,工作区和 seat 目录按物理路径可写绑定。
macOS 和 Linux 均只提供本次调用的私有临时目录。原仓库和控制器文件位于系统临时目录时也受保护。

Windows 上 teamwork 不启动:`teamwork run`/`resume`/`mcp`、REPL `/teamwork` 与
`Run.start`/`Run.reopen` 在写入任何运行状态前返回 `UnsupportedPlatform`(Windows 没有 seat
沙箱后端,也不计算批准、审计与合回所绑定的工作区树 id)。没有可用 bwrap(未安装、或内核/容器
不允许所需命名空间)的 Linux,在模型请求前即拒绝 seat,不会因探测失败而把原生文件操作切换成无沙箱模式。Read/Write/Edit 等原生文件工具
经 `metacodes-fs-helper` 在沙箱内打开文件;Grep/Glob 的搜索命令也经过相同边界。
两个后端都允许写工作区(构建缓存),所以对非 implementer seat,Bash 挡不住对工作区
的改动;reviewer 仍由工作区树 id 检查兜底。完整边界见 [沙箱执行](SANDBOX_DESIGN.md)。

### 7.4 Claude Code 驱动

`ClaudeCodeDriver.init(options: claude_code.Options, binding)`,`Options` = 运行时环境变量
(`KEY=VALUE`,按白名单过滤)、home、可选硬超时 `timeout_ms`、探测超时、是否用沙箱。

- **可执行文件**:只用配置里的绝对路径 `command`,从不查 `PATH`。
- **兼容性探测**(每个驱动实例首次运行前):`--version` 必须是 `<x.y.z> (Claude Code)`,`--help`
  必须列出所用的每个参数(`required_help_text`);不满足即 `failed.spawn_failed`,原因写进 seat
  目录的 `harness.log` 并记日志。参数按 Claude Code 2.1.323(`pinned_version`)的 `--help` 写死:

  ```
  <command> -p <bootstrap> --output-format stream-json --verbose --add-dir <seat 目录>
    --permission-mode acceptEdits --permission-prompts none --no-session-persistence
    [--model <m>] [--effort <low|medium|high|xhigh|max>] [--max-budget-usd <剩余预算>]
    --append-system-prompt <该角色的固定宪章>
    --strict-mcp-config --mcp-config '{"mcpServers":{}}'
  ```

  `acceptEdits` + `--permission-prompts none`:工作目录内的编辑自动接受,其余需要询问的一律拒绝
  (与 teammate 的 fail-closed 一致)。`--add-dir` 接多个值,所以它后面紧跟另一个选项。
  `effort` 的 `none`/`minimal` 映射为 `low`。`cost` seat 传 `--max-budget-usd`,`wallclock_only`
  seat 不传。
  Worker 不继承用户的 MCP 配置,避免把 Manager 的编排入口或其他未预算的模型调用引入 seat。
- **cwd** = 工作区;**环境变量**只传白名单(`env_allowlist`:HOME、PATH、语言、临时目录、XDG、
  CA 证书、`CLAUDE_CONFIG_DIR` 等),任何 provider 密钥(含 `ANTHROPIC_API_KEY`)都不传;Claude
  Code 用它自己的登录。stdin 立即关闭,stderr 写入 `harness.log`。
- **进程组**:子进程自成进程组。中止、硬超时、wallclock 预算到时整组 SIGTERM→SIGKILL;正常退出
  后也清扫一次整组,不留后代进程。Windows 只杀 CLI 本身。
- **沙箱**:探测(`--version`、`--help`)和正式调用都经通用的 `sandbox/worker.zig`
  包进宿主后端(macOS Seatbelt,Linux bubblewrap + seccomp),
  可写根 = 工作区、seat 目录和 Claude Code 自己的状态(`~/.claude`、`~/.claude.json*`;
  bwrap 只能绑定启动时已存在的条目)。继承宿主的读写拒绝与网络列表,不继承额外写权限;
  无网络列表时网络开放(CLI 要连 API)。工厂把同一宿主限制转交给两种 harness。bwrap 下 CLI 被信号 N
  杀死表现为 bwrap 退出码 128+N,驱动换算回信号(`WrappedCommand.childExitCode`)。
  **启用沙箱而后端不可用时,在兼容性探测前即拒绝启动**;仅可信宿主显式设置
  `Options.sandbox=false` 可以不受限运行。
  真实 CLI 在该配置下的运行尚未用真模型验证。
- **结果**:stdout 只解析最后一个 `result` 事件(`subtype`、`total_cost_usd`),不解析对话。
  正常交付需要成功的结果事件和 handoff。`cost` seat 以 `harness_reported` 记报告的花费;
  没有有效花费报告时保守以 `reserved` 消耗剩余额度。只有显式 `wallclock_only` seat 仅记时间。

### 7.5 测试(L2)

`drivers/drivers_test.zig`(POSIX;假 `claude` 是 `/bin/sh` 脚本,记录 argv、cwd、环境并输出
预录的 stream-json;metacodes 侧用脚本化 provider 驱动真实的子 agent 循环和真实工具):

- 同一角色先配 `metacodes` 再配 `claude_code`(经 `config.parse`/`validate`),工厂给出不同驱动:
  前者不起子进程、以 `provider_estimate` 记账,后者起假 CLI,断言完整 argv、cwd = 工作区、
  白名单环境(密钥不在)、$0.25 以 `harness_reported` 入账;同一份 packet 两边都得到 `finished`
  且 handoff 各段相同。
- 非零退出 → `failed.exited`、被 SIGKILL → `failed.signaled`、无 handoff → `failed.handoff_missing`、
  CLI 自报预算停 → `budget_exhausted`、`--help` 缺参数 → `failed.spawn_failed`(`harness.log` 写明
  缺哪个参数与钉住的版本)。
- 硬超时 → `failed.timed_out`、wallclock 预算 → `budget_exhausted`、中止 → `aborted`;三种情况下
  CLI 留下的孙进程都随进程组消失,花费以 `wallclock_only` 入账。
- metacodes seat 写工作区/seat 目录之外(绝对路径、`../` 相对路径、`ORIGINAL_REQUEST.md`、别的
  seat 的 handoff)全部被拒且磁盘上不存在;系统提示词恰为宪章、一个空行和注释指导;首条用户消息以 bootstrap 开头,
  bootstrap 部分不含 run id 与状态路径。
- 路径别名:两次运行换 state root 与 run id,metacodes seat 的首个 provider 请求序列化后逐字节相同;
  经 `$SEAT/packet.md` 读 packet、经 `$WORKSPACE`/`$SEAT` 在 Bash 里跑检查并写输出、经 `$SEAT/handoff.md`
  写 handoff,文件都落在真实目录;`$SEAT/../reviewer-1/…`(Write 与 Bash)、`$WORKSPACE/../…`、
  `$SEAT/<指向外部的符号链接>/…` 都被拒且磁盘上不存在。Claude Code seat 两次运行的 argv 只有
  `--add-dir` 的取值不同。
- metacodes reviewer seat:系统提示词为 `reviewer.charter` 加注释指导,外接观测 sink 收到 Bash 分派,Write/Edit
  进不了工作区。

## 8. 公共面

`src/lib.zig` 导出 `teamwork_types`、`teamwork_config`、`teamwork_run_dir`、`teamwork_ledger`、
`teamwork_issues`、`teamwork_reviewer`、`teamwork_charters`、`teamwork_drivers`(`drivers/factory.zig`)、
`teamwork_runtime`、`teamwork_swe_loop`、`teamwork_audit`、`teamwork_merge_back`、
`teamwork_verifier_auditor`、`teamwork_mcp_server`、`teamwork_progress`、`teamwork_interview` 与 `teamwork_judge`
(与 swarm 子系统相同的方式);`stub_driver.zig` 与 `drivers/drivers_test.zig` 只由测试引用。单元测试同时进入
`zig build test:units`(`src/main.zig` 的测试根)与 `zig build test:lib`。

## 9. 不做

锦标赛树、数学证明管线、文档评审路线、大规模角色组合(见 #514"不做")。

## 10. runtime、审计与合回

`runtime.Run.start` 只接受宿主已经批准的 `ApprovedRequest`。runtime 记录原始请求,对工作区
创建包含未提交与未忽略文件的快照,再在运行目录中创建 detached worktree。用户的 HEAD、索引与
文件不变。控制器创建 worktree、生成审计快照和合回时均禁用仓库钩子、fsmonitor 与内容过滤器;
seat 的沙箱额外拒绝写入 `.git` 和 linked worktree 的
公共 git 目录,防止子 agent 改动用户的 refs、配置或钩子。

Manager 只驱动 `dispatch(implementer/reviewer)`、`status`、`requestCompletion`、`cancel`。
`swe_loop.drive` 是默认的确定性 Manager,复用同一组操作。状态顺序为:

```text
approved -> implementing -> reviewing -> review_approved -> auditing -> merging -> done
               ^               |              |               |
               +-- 修改/拒绝 ---+              +-- 过期 -> reviewing
               +------------------- 第一次审计 FAIL / UNVERIFIED ---+
```

每个角色最多派 `max_rounds` 个 seat(默认 3)。reviewer 的结论经过工具调用记录、台账与固定
检查命令核验;批准绑定工作区树 id。审计前树变了就重新评审,审计后树变了就终止。
`VerifierAuditor` 在与批准树一致的独立快照上执行固定检查,然后调用 `core/isolated_verifier.verify`。
审计请求用 `$WORKSPACE` 标识候选快照,不会包含生成的快照路径。只有绑定到批准树的 PASS 才合回,
FAIL 第一次进入修复轮;UNVERIFIED 第一次进入 leads 轮:报告里 verifier 收集的证据和未能确认的项
作为线索写进下一轮 implementer 与 reviewer 的 packet。两种情况下第二次审计仍不是 PASS 都终止
(`audit_failed` / `audit_unverified`),不合回;unavailable 直接终止。UNVERIFIED 与 unavailable
均不会放行。审计花费必须成功写入预算账本。

`merge_back.mergeBack` 生成二进制补丁,比较用户从启动以来的改动与候选改动。两者修改相同或
包含关系的路径时停在 `merge_conflict`,保留工作区、worktree、`merge.patch` 与冲突列表。
通过时用基于原始树的临时索引执行 `git apply --index`，写入前复核目标文件的完整内容与模式。
子模块指针变更会拒绝合回并保留补丁。成功时改动留为未提交修改，真实索引保持原状。

`runtime.lock` 的内核锁保证同一个运行只有一个控制进程,第二次恢复返回 `RunBusy`。
`run.json` 原子记录批准配置、状态、树 id、轮数、审计次数与配置 SHA-256。首次 checkout 中断时可以用同一运行 ID 恢复。
恢复时必须提供相同的预算、seat/harness/model、固定检查和有效权限配置,否则 `ConfigurationChanged`。
控制器的 seat 状态文件记录宪章 SHA-256 并在恢复后保留。崩溃时未完成的 seat
记为 interrupted;如果丢失了付费结果,先按预算预留规则停止。中断的审计可以在预算允许时重跑,
中断的合回停下交由用户检查。

L2 测试在临时 git 仓库驱动真实 worktree、账本与合回,覆盖成功交付、跨轮问题、过期批准、两次
审计失败、预算中止、冲突保留、恢复与配置变更拒绝。模型调用均用脚本化 provider/假 CLI。

### 10.1 并行候选与择优(#525)

配置了 `candidates` 的运行在 `Run.start` 时不建单线 worktree。`start` 在写任何文件前读出运行目录
里的预算账本(面试的花费也在其中),候选数乘以 `candidate_estimate_usd` 超过剩余额度即返回
`CandidateBudgetExceeded`,不写 `ORIGINAL_REQUEST.md`、`run.json`,不启动任何 seat。

`Run.runCandidates()` 只能在 `approved` 调用(之前 `dispatch` 返回 `CandidatesPending`),再检查
一次预估,然后进入 `candidates` 阶段,按顺序处理每个候选:

1. 在 `candidates/candidate-<n>` 从启动快照建 worktree;
2. 以该候选的 seat 跑 implementer,再跑 reviewer。评审照常核验(观测到的 Bash、固定检查重跑、
   零修改),但用候选自己的空台账,不写运行的 `open_issues.json`;
3. 批准且核验通过的候选为 `approved`(记下批准的树),其余为 `rejected`。

seat 按顺序运行:预算账本一次只预留一个付费 seat(§5)。候选的 implementer 与 reviewer 共用
`implementer-<k>` / `reviewer-<k>` 序号;每个角色的派发上限因此是 `max_rounds + N - 1`,即全部
候选算作一轮。预算耗尽或取消时运行照常结束。

没有候选通过时运行以 `no_candidate_approved` 结束,不跑 judge,候选 worktree 保留。否则 runtime
在 `judging/` 放入每个合格候选的 `candidate-<n>.diff`(相对启动快照)和 review 副本,派出
judge seat(宪章原创,工具同其他只读角色)。packet 列出每个候选和 runtime 核验过的事实,
只写 `candidate-<n>` 与相对文件名,不含 run id、路径和时间。judge 写 `judgment.json`:

```json
{"selected": "candidate-2", "eliminated": [{"candidate": "candidate-1", "reason": "..."}]}
```

`judge.parse` 严格校验:`selected` 必须是合格候选;其余每个候选恰好出现一次,理由非空且不超过
1000 字节。不合格的 judgment 记为 `judgment.invalid`,在 judge 的派发上限内换新 judge seat 重来;
到上限即 `rounds_exhausted`。

选中后,未选中的已批准候选记为 `eliminated`,其余 worktree 都删除,选中的 worktree 成为运行的
worktree,运行进入 `review_approved`(批准的树)。之后与单线运行相同:`requestCompletion` 复核
批准、审计(#516)、合回(#523)。所以只有选中的候选会被审计和合回;审计失败的修复轮也在它的
worktree 里进行。

每个未选中的候选生成一条 TinyKG `lesson`(`kg/lesson.zig`):头部 `verdict=failed task=- run=<run id>`,
`holds_when` 是请求首行,`uncertain` 写 runtime 核验过的事实,`lesson` 写 judge 的理由。runtime
按 `KgRemember` 对学习轮的同一条准入规则检查:信封可解析、头部与宿主绑定一致、单次至多 4 条,
通过后才交给 `Deps.pitfalls`。CLI 与 REPL 接到 `App.kg`;KG 不可用时跳过,不影响运行。

`run.json` 记录每个候选的状态和批准的树。选中后恢复时,worktree 指向选中的候选;在 `candidates`
阶段崩溃的运行恢复为 `failed(candidates_interrupted)`。快照的 `candidates` 字段(MCP、
`teamwork.snapshot`、TUI 面板)显示每个候选的状态。MCP manager 用 `teamwork_run_candidates`。

### 10.2 外部 Manager(#545)

`seats.manager` 为 `claude_code` 时,`manager.drive(run, options)` 代替 `swe_loop.drive`;CLI 的
`teamwork run` / `resume` 与 REPL 的 `/teamwork` 都经这个入口。worker 各 seat 的 harness 照常
独立配置,与 Manager 的 harness 无关。顺序:

1. `Run.openManager` 登记 `manager-<n>` seat,写 packet(固定说明加批准的请求原文,不含 run id、
   路径和时间)。剩余额度不大于 `manager_budget_usd` 时运行以 `budget_exhausted` 结束;Manager
   seat 数同样受 `max_rounds` 限制。
2. 在 Manager 的沙箱里做兼容性探测(`--version`、`--help` 含 `manager_required_help_text`)。
   不通过时 seat 为 `failed`,运行以 `failed(manager_unavailable)` 结束,不花钱。
3. 在 seat 目录建两个 FIFO `mcp.in` / `mcp.out`,控制器以读写方式打开,在运行目录写
   `manager-relay.sh`。Manager 的 MCP 配置只有一个 stdio 服务 `teamwork`:`/bin/sh
   manager-relay.sh <mcp.in> <mcp.out>`,中继把 Manager 的请求原样送进 FIFO、把应答送回。
4. `Run.holdManager` 写入额度保留(§5),之后才启动 Manager:
   ```
   <command> -p <manager_bootstrap> --output-format stream-json --verbose
     --permission-mode default --permission-prompts none --no-session-persistence
     [--model <m>] [--effort <e>] --max-budget-usd <manager_budget_usd>
     --append-system-prompt <manager 宪章> --strict-mcp-config --mcp-config <上面的配置>
     --allowedTools mcp__teamwork
   ```
   cwd 与唯一可写根是 Manager 自己的 seat 目录(另有 Claude Code 自己的状态目录),沙箱与 worker
   相同(macOS Seatbelt / Linux bubblewrap,不可用即拒绝);环境变量按同一白名单过滤。默认权限
   加 `--permission-prompts none`:编辑和 Bash 需要询问,一律拒绝;只有 teamwork 工具预先放行。
   所以 Manager 改不了 `ORIGINAL_REQUEST.md`、账本、`run.json`、审计报告、worktree 或用户工作区,
   也无从直接合回。
5. 控制器在宿主进程里用 `mcp_server.Server.serveFds` 服务这对 FIFO,不在 Manager 的进程树里;
   dispatch、审计、合回都由它执行,Manager 只能调用 TEAMWORK_MCP.md 的五个工具,`done` 仍只经
   `requestCompletion`。另一个线程监督 Manager 进程:Manager 退出时触发运行的 abort,服务循环随之
   结束,未结束的运行转为 `cancelled`;运行的 abort(宿主 Ctrl+C、预算触顶、`teamwork_cancel`)
   让服务循环结束,正在跑的 worker 也经同一信号停止,不合回。监督线程不直接看运行的 abort,只看
   控制器的停止信号:服务循环结束后,控制器先等中继读走 `mcp.out` 里已写出的应答(只读探测描述符上
   `FIONREAD` 为 0,或 Manager 已退出,至多 `reply_delivery_ms` 即 2 秒;macOS 上读写方式打开的 FIFO
   描述符 `FIONREAD` 恒为 0,所以另开一个只读的),再发停止信号杀掉 Manager 整个进程组。
   所以停掉 Manager 之前,中继已从 `mcp.out` 取走全部已写出的应答(`teamwork_cancel` 的应答在内),
   除非 Manager 已经退出或等满 2 秒。这不等于 Manager 一定收到:`cat` 读出之后、写进中继 stdout
   之前被停,应答仍会丢(监督线程 0–50 ms 的停止检查只是余量,不是上界);运行中止之后,超过
   FIFO 缓冲的应答在 `writeFrame` 第一次遇到 EAGAIN 时就被放弃。
6. Manager 结束后由主线程记账:结果事件里有花费按 `harness_reported` 记,否则(被停止、崩溃、
   超时、没有报告)按 `reserved` 记满额度。这笔记账结算保留。

Manager 外面还包了一层 `lifeline_script`:它的 stdin 是只有控制器持有写端的管道,控制器进程一旦
死掉,读到 EOF 就杀掉整个进程组,所以不会留下孤儿 Manager。控制器崩溃后保留由重开消费(§5),
Manager seat 标为 interrupted;重开后 `teamwork resume` 启动新的 `manager-<n+1>`,它只能看到快照,
runtime 不会自行重放任何 dispatch。

缓存契约:`-p` 提示词、宪章与 packet 都不含 run id、路径和时间;MCP 配置里的 FIFO 与中继路径
随运行变化,但它们只交给 Claude Code 启动中继进程,不进入模型请求;Claude Code 自己生成的环境
消息与 transcript 不受 runtime 控制(同 §7.1)。Windows 没有外部 Manager(`UnsupportedPlatform`)。

L2(`runtime_test.zig` 的 `teamwork manager L2`,`teamwork_command_test.zig`):假 Manager CLI 读取
自己的 `--mcp-config`,经真实中继发 MCP 请求派活并完成交付;在沙箱里改受保护文件全部失败;
先请求完成得到 `NotApproved`;切换 Manager harness 决定是否启动 Manager 进程,切换 implementer
harness 独立生效;预算触顶与宿主取消都会停掉 Manager 与 worker 且不合回;Manager 调
`teamwork_cancel` 后,即使中继读端慢半秒,也先收到全部应答再被停掉、按 `reserved` 记满额度;崩溃后重开只扣一次
保留;控制器关闭 lifeline 后 Manager 的整个进程组消失。`mcp_server_test.zig` 单独覆盖只用外部
MCP 客户端时的预算边界(`budget.manager` 为 `outside_ledger`,花费只含 worker)。

## 11. 实现状态

| Issue | 内容 | 状态 |
|---|---|---|
| #515 | runtime / seat 分层、角色配置、worker 契约 | 类型、配置、驱动、runtime、确定性 SWE Manager 已接通(§7、§10)。 |
| #516 | 独立 verifier / 完成审计 | 已完成:`VerifierAuditor` 已接隔离 verifier,最多两次审计;第一次 FAIL 反馈修复轮,第一次 UNVERIFIED 把证据与未确认项作为线索反馈 leads 轮,第二次仍非 PASS 即终止且不合回;只有 PASS 交付。 |
| #517 | reviewer 角色与 open-issues 台账 | 已完成:runtime 已接证据观测、跨轮台账、固定检查重跑与过期批准检查。Windows 不计算 `workspaceTree`(`Unsupported`),teamwork 在 Windows 上启动前即以 `UnsupportedPlatform` 拒绝(§7.3),Windows CI 腿有测试覆盖。 |
| #518 | `/teamwork` 命令、面试与批准 | 已完成:CLI 显式批准入口、配置加载、状态和恢复;请求参数段 `[skip-interview]` / `[seats=...]`(CLI 与 REPL);REPL `/teamwork` 的 interviewer 面试、批准/修改/拒绝与后台运行;`request_source` 记录批准来源(§3)。 |
| #519 | 运行状态目录与写入隔离 | 原生工具与外部 Worker 均使用 Sandbox Foundations;无后端就拒绝。增加 `.git` 拒写、宪章摘要、运行锁。稳定路径别名已由 #544 完成。 |
| #544 | seat 稳定路径别名 | 已做(§7.1):`$WORKSPACE` / `$SEAT` 在工具准入层解析,隔离 verifier 的快照同样用 `$WORKSPACE`;metacodes seat 的首个 provider 请求跨运行逐字节相同;Claude Code seat 只有 `--add-dir` 取值随运行变化。 |
| #520 | 运行级预算 | 付费调用前预留、退出记账、丢失报告/崩溃时消耗预留、恢复固定原策略、预算触顶停止且不合回。 |
| #521 | Claude Code 作为 worker | 已做(§7.4):钉住的 argv 与版本/参数探测、环境白名单、进程组、macOS Seatbelt / Linux bubblewrap 沙箱、结果事件记账、失败映射及 L2(假 CLI)。待做:真实 CLI 的手动 e2e job(需预算上限,不进默认 gate) |
| #522 | Claude Code 作为 Manager(MCP) | stdio MCP 接口驱动用户预先批准的 Run,复用独立审计和预算规则。详见 [TEAMWORK_MCP.md](TEAMWORK_MCP.md)。 |
| #545 | 自动启动外部 Manager | 已做(§10.2):`seats.manager` 为 `claude_code` 时 runtime 在沙箱里启动 Manager,经 FIFO 中继服务同一 MCP 接口,控制器留在宿主进程;`manager_budget_usd` 额度启动前 durable 保留、结束结算、丢失结果全额消耗,重开不重复发放;宿主取消、预算触顶停掉 Manager 与 worker 且不合回;lifeline 防止孤儿 Manager;快照 `budget.manager` 标明 Manager 花费是否在账本内。 |
| #523 | worktree 合回 | 审计通过后补丁合回,保留用户并发修改,冲突时保留两边内容(§10)。 |
| #524 | 进度面板与 AgentCore 事件 | 已做:runtime 每次 seat 状态或阶段变化都把变化和之后的快照发给 `Deps.observer`;interviewer 在等待批准时为 `needs_you`;REPL 用线程安全的 `progress.Board` 驱动输入框上方的面板与 `/teamwork status` 摘要;`teamwork run/resume --events` 输出 `teamwork.snapshot` / `teamwork.event` 线协议行(WIRE_PROTOCOL §1.6)。AgentCore C ABI 没有 teamwork 入口,不带这些事件。 |
| #525 | 并行候选与择优 | 已做(§10.1):`candidates`(至多 4 个,可混用 harness)各用独立 worktree 并经 reviewer 核验;judge seat 按核验过的测试证据择一,只有选中的进入审计与合回;未选中的理由按 TinyKG lesson 准入写入 KG;启动前按 N 倍预估检查剩余预算;快照显示各候选状态。候选 seat 按顺序运行(账本一次只预留一个付费 seat)。 |
