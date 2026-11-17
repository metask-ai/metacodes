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

CLI 使用确定性 SWE manager 和请求文件,不执行 interviewer;未接线的角色配置明确拒绝。
`command.Host` 向 worker、pinned check 和 verifier 提供强制沙箱,state root 必须在仓库外。
`approved-config.json` 保存批准配置并固定 native seat 的继承模型;`teamwork resume <id>
--approve` 只用这份 policy。`teamwork status <id> [--json]` 只读运行文件,缺失账本为空,
pending receipt 只展示不结算。`teamwork mcp` 复用批准门禁,由
`McpHost.serveFn(gpa, run)` 接管 live Run 的管理。完整 CLI 合约见 [API.md](API.md),
真实 CLI consumer 测试见 `tests/component/teamwork_command_test.zig`(假 harness / 本地 mock)。

## 4. 运行目录

`src/teamwork/run_dir.zig`,根在**工作区之外**:

```
<state_root>/teamwork/<run_id>/
  ORIGINAL_REQUEST.md     只写一次;审计的基准
  budget.jsonl            预算账本(§5)
  open_issues.json        评审发现台账(#517),初始为 []
  seats/<seat_id>/
    packet.md             runtime 写
    handoff.md            seat 写
    progress.md           seat 写
    status.json           runtime 写:{seat_id, role, harness, status}
    review.json           reviewer seat 写(§6.1)
    open_issues.json      runtime 写给本 seat 的台账只读副本(§6.3)
    harness.log           Claude Code 驱动写:CLI 的 stderr 与兼容性诊断(§7.4)
```

- `RunId` / `SeatId` 是互不相同的类型,字符集 `[a-z0-9][a-z0-9_-]*`(≤ 64 字节),直接当目录名,
  不可能含分隔符或 `..`。约定的 seat id 由 `seatIdFor(role, n)` 生成(`implementer-1`)。
- `RunDir.create` 拒绝接管已存在的目录(`RunExists`);`RunDir.open` 用于重启后重新进入。
- `writeOriginalRequest`:先写临时文件并 fsync,再以不覆盖方式安装(`pfs.installNoReplace`);
  第二次写返回 `OriginalRequestExists`,崩溃不会留下半截请求。
- `status.json` 经临时文件 + rename 原子替换。`SeatStatus` 为
  `queued / working / needs_you / waiting / done / failed`。
- `recover()` 只凭目录内容重建 seat 表:每个名字合法的 `seats/<id>/`,读得出记录的给出
  `recorded`(含 `has_handoff`),读不出的(建目录后、首次写 status 前崩溃,或记录被破坏、
  记录里的 seat_id 与目录不符)给出 `damaged`,由 runtime 决定重新登记还是放弃;临时文件和
  非法名字忽略。结果按 seat id 排序。
- 所有带路径的文件操作都经 `src/platform/fs.zig` 与 `src/platform/dir.zig`。

**缓存契约**:run id、时间戳和运行目录的绝对路径都不进入 metacodes 发给 provider 的字节。
packet 引用同一运行里的其他文件时,用相对于 seat 目录的路径(`seat_relative_original_request`
= `../../ORIGINAL_REQUEST.md`、`seat_relative_open_issues`);seat 目录的绝对路径只作为环境事实
交给 harness(§7.1),不进入宪章、bootstrap 或 Manager 的提示词。写入隔离(seat 只能写工作区和
自己的 seat 目录)由执行策略、权限层和沙箱保证,不靠提示词(§7.3)。

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
`budget.jsonl.pending`,记录该 seat 获准使用的剩余额度。正常结束的 durable charge 清理该记录。
控制器崩溃后,`Ledger.load` 若只找到预留而没有该 seat 的完成记账,就把预留作为 `reserved`
入账并停止继续花费;若完成记账已落盘则只清理旧预留,不重复扣除。显式 `wallclock_only` 仍然
只承诺时间上限。成本模式下,缺少有效结果/花费报告不会被当作零花费后继续重试。

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
`git write-tree`,不动工作区的 index 和文件,唯一副作用是对象库里的 blob。

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
  环境段告诉模型);metacodes 子 agent 经首条用户消息里 bootstrap 之后的 `<seat-environment>` 块
  (工作区与 seat 目录的绝对路径)——与 Claude Code `--exclude-dynamic-system-prompt-sections`
  把机器相关段放进首条用户消息同一做法。所以宪章(系统提示词)和 bootstrap 跨 seat、跨运行
  逐字节稳定;含 run id 的 seat 目录路径只出现在环境块里。
- **宪章**(`charters.forRole(role)`):interviewer、implementer、manager 为原创文本;reviewer 即
  `reviewer.charter`(§6);verifier 是标明的占位,真正的宪章在 verifier 模块(#516)。
  两种 harness 都收到同一角色宪章(Claude Code 通过 `--append-system-prompt`)。
  `charters.digest(role)` 是编译期 SHA-256,runtime 将其写入 seat 的 `status.json`,恢复时保留。
- **判定顺序**:中止 → `aborted`;预算停(子 agent 因 `cost_budget_usd` 停、Claude Code 报
  `error_max_budget_usd`、wallclock_only seat 到时、账本写不进)→ `budget_exhausted`;硬超时 →
  `failed.timed_out`;被信号杀 → `failed.signaled`;非零退出 → `failed.exited`;否则
  `run_dir.collectHandoff` 按 handoff 判定。一笔钱只要花了就先记账再判定;记账让总额到顶时,
  已完成的 handoff 照样返回,停不停所有 seat 由 runtime 看 `Ledger.isExhausted()` 决定。

### 7.2 metacodes 驱动

`MetacodesDriver.init(deps: metacodes.Deps, binding)`,`Deps` 显式给出 provider、Anthropic
client(可空)、宿主工具定义、宿主权限上下文、宿主沙箱设置(可空)、home、state root、artifact
root、session、`max_turns`。可选字段 `tool_observer` 接一个额外的工具观测 sink(reviewer seat 接
`reviewer.BashCallLog.sink()`)。经 `subagent.spawnAgentSink` 运行:系统提示词 = 宪章;cwd =
工作区且 `resolve_relative_paths = true`;额外目录 = seat 目录;`cost_budget_usd =
ledger.remainingUsd()`;`spec.model`/`spec.effort` 作为覆盖。用量经 `WriterBackend` 的 usage
累加器收集,结束后按模型单价折算,以 `provider_estimate` 入账。

### 7.3 写入隔离(metacodes seat)

`write_scope.zig`,三层各自成立:

| 层 | 机制 | 管什么 |
|---|---|---|
| 执行策略 | `Scope.executionPolicy()` 作为 `SpawnOptions.execution_policy`,agent_loop/tool_exec 在工具运行前最后一道检查,与权限模式、allow 规则无关 | 只提供该角色的工具(`toolsFor`:implementer = Read/Grep/Glob/Write/Edit/Bash;reviewer = `reviewer.tools` + Write;其余角色 = Read/Grep/Glob/Bash/Write);Write/Edit 的目标按工具自己的解析方式求出后**物理**落在写根内(符号链接解析,含尚不存在的尾部;悬空链接拒绝);写根 = seat 目录,implementer 另加工作区;Bash 必须只读或确实在沙箱内运行 |
| 权限 | 宿主权限上下文派生:`acceptEdits`、工作目录集 = 工作区 + seat 目录、`no_interactive_prompt`、无 UI 请求器、无会话记忆、无 memdir 豁免 | 需要询问的一律拒绝;宿主 deny 规则、settings、hooks 照样生效 |
| 沙箱 | `seatSandbox`:始终要求后端(macOS Seatbelt;Linux bubblewrap + seccomp)、`failIfUnavailable`、不可绕过(`allowUnsandboxedCommands = false`),丢弃宿主的 `allowWrite` 与 `excludedCommands` | Bash 和原生文件执行器只能写工作区、seat 目录和临时目录;后端不可用即拒绝 seat |

Linux 上 implementer seat 的 Bash 跑在 bubblewrap 里:根目录只读挂载,只把工作区、seat 目录、
临时目录(`/tmp`、`/var/tmp`、`$TMPDIR`)按物理路径可写绑定,所以能在工作区里构建、跑测试,写不到别处
(符号链接改变不了挂载)。

Windows,以及没有可用 bwrap(未安装、或内核/容器不允许所需命名空间)的 Linux,在模型请求前
即拒绝 seat,不会因探测失败而把原生文件操作切换成无沙箱模式。Read/Write/Edit 等原生文件工具
经 `metacodes-fs-helper` 在沙箱内打开文件;Grep/Glob 的搜索命令也经过相同边界。
两个后端都允许写工作区(构建缓存)和临时目录,所以对非 implementer seat,Bash 挡不住对工作区
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
  可写根 = 工作区、seat 目录、临时目录和 Claude Code 自己的状态(`~/.claude`、`~/.claude.json*`;
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
  seat 的 handoff)全部被拒且磁盘上不存在;系统提示词恰为宪章;首条用户消息以 bootstrap 开头,
  bootstrap 部分不含 run id 与状态路径。
- metacodes reviewer seat:系统提示词为 `reviewer.charter`,外接观测 sink 收到 Bash 分派,Write/Edit
  进不了工作区。

## 8. 公共面

`src/lib.zig` 导出 `teamwork_types`、`teamwork_config`、`teamwork_run_dir`、`teamwork_ledger`、
`teamwork_issues`、`teamwork_reviewer`、`teamwork_charters`、`teamwork_drivers`(`drivers/factory.zig`)、
`teamwork_runtime`、`teamwork_swe_loop`、`teamwork_audit`、`teamwork_merge_back`、
`teamwork_verifier_auditor` 与 `teamwork_mcp_server`
(与 swarm 子系统相同的方式);`stub_driver.zig` 与 `drivers/drivers_test.zig` 只由测试引用。单元测试同时进入
`zig build test:units`(`src/main.zig` 的测试根)与 `zig build test:lib`。

## 9. 不做

锦标赛树、数学证明管线、文档评审路线、大规模角色组合(见 #514"不做")。

## 10. runtime、审计与合回

`runtime.Run.start` 只接受宿主已经批准的 `ApprovedRequest`。runtime 记录原始请求,对工作区
创建包含未提交与未忽略文件的快照,再在运行目录中创建 detached worktree。用户的 HEAD、索引与
文件不变。创建 worktree 禁用仓库钩子;seat 的沙箱额外拒绝写入 `.git` 和 linked worktree 的
公共 git 目录,防止子 agent 改动用户的 refs、配置或钩子。

Manager 只驱动 `dispatch(implementer/reviewer)`、`status`、`requestCompletion`、`cancel`。
`swe_loop.drive` 是默认的确定性 Manager,复用同一组操作。状态顺序为:

```text
approved -> implementing -> reviewing -> review_approved -> auditing -> merging -> done
               ^               |              |               |
               +-- 修改/拒绝 ---+              +-- 过期 -> reviewing
               +------------------------- 第一次审计失败 --------+
```

每个角色最多派 `max_rounds` 个 seat(默认 3)。reviewer 的结论经过工具调用记录、台账与固定
检查命令核验;批准绑定工作区树 id。审计前树变了就重新评审,审计后树变了就终止。
`VerifierAuditor` 调用隔离的 `core/isolated_verifier.verify`:它只接收原始请求、候选快照和
检查证据,不接收实现者的对话。只有明确 PASS 才合回,FAIL 第一次进入修复轮、第二次失败终止;
UNVERIFIED 与 unavailable 均不会放行。审计花费必须成功写入预算账本。

`merge_back.mergeBack` 生成二进制补丁,比较用户从启动以来的改动与候选改动。两者修改相同或
包含关系的路径时停在 `merge_conflict`,保留工作区、worktree、`merge.patch` 与冲突列表。
通过时用 `git apply` 合回为未提交修改,不自动 commit。预算耗尽、取消、审计失败时不合回。

`runtime.lock` 的内核锁保证同一个运行只有一个控制进程,第二次恢复返回 `RunBusy`。
`run.json` 原子记录状态、树 id、轮数、审计次数与配置 SHA-256。恢复时必须提供相同的预算、
seat/harness/model 与固定检查配置,否则 `ConfigurationChanged`;修改配置不会悄悄给旧运行
增加权限或预算。seat 的 `status.json` 记录宪章 SHA-256 并在恢复后保留。崩溃时未完成的 seat
记为 interrupted;如果丢失了付费结果,先按预算预留规则停止。中断的审计可以在预算允许时重跑,
中断的合回停下交由用户检查。

L2 测试在临时 git 仓库驱动真实 worktree、账本与合回,覆盖成功交付、跨轮问题、过期批准、两次
审计失败、预算中止、冲突保留、恢复与配置变更拒绝。模型调用均用脚本化 provider/假 CLI。

## 11. 实现状态

| Issue | 内容 | 状态 |
|---|---|---|
| #515 | runtime / seat 分层、角色配置、worker 契约 | 类型、配置、驱动、runtime、确定性 SWE Manager 已接通(§7、§10)。 |
| #516 | 独立 verifier / 完成审计 | `VerifierAuditor` 已接隔离 verifier,最多两次审计,失败反馈修复轮;只有 PASS 交付。UNVERIFIED 后的 leads 轮仍待做。 |
| #517 | reviewer 角色与 open-issues 台账 | runtime 已接证据观测、跨轮台账、固定检查重跑与过期批准检查。Windows `workspaceTree` 尚不支持。 |
| #518 | `/teamwork` 命令、面试与批准 | CLI 显式批准入口、配置加载、状态和恢复。交互式面试与 REPL `/teamwork` 尚待做。 |
| #519 | 运行状态目录与写入隔离 | 原生工具与外部 Worker 均使用 Sandbox Foundations;无后端就拒绝。增加 `.git` 拒写、宪章摘要、运行锁。稳定路径别名仍待做。 |
| #520 | 运行级预算 | 付费调用前预留、退出记账、丢失报告/崩溃时消耗预留、恢复固定原策略、预算触顶停止且不合回。 |
| #521 | Claude Code 作为 worker | 已做(§7.4):钉住的 argv 与版本/参数探测、环境白名单、进程组、macOS Seatbelt / Linux bubblewrap 沙箱、结果事件记账、失败映射及 L2(假 CLI)。待做:真实 CLI 的手动 e2e job(需预算上限,不进默认 gate) |
| #522 | Claude Code 作为 Manager(MCP) | stdio MCP 接口驱动用户预先批准的 Run,复用独立审计和预算规则。详见 [TEAMWORK_MCP.md](TEAMWORK_MCP.md)。 |
| #523 | worktree 合回 | 审计通过后补丁合回,保留用户并发修改,冲突时保留两边内容(§10)。 |
| #524 | 进度面板与 AgentCore 事件 | 待做 |
| #525 | 并行候选与择优 | 待做 |
