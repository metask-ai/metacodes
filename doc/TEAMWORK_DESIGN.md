# metacodes Teamwork — 设计文档

> 状态:阶段 0(共享类型、配置、运行目录、预算账本)与内置 reviewer(评审结果契约、证据核验、
> open-issues 台账,§6)已落地于 `src/teamwork/`;runtime、驱动、命令入口尚未实现,见 §9。
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

`stub_driver.zig` 是仅供测试的驱动,按脚本扮演 harness;真实驱动(metacodes 子 agent、
Claude Code 子进程)在后续分支(#515 余下部分、#521)实现。

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

**接线点(尚未接)**:`<state root>/config.json` 目前由两处读取——`src/app/config.zig` 的
`loadFromHome`(`FileConfig`:model、permission_mode 等)和 provider 控制面的
`src/provider/config_store.zig` `Store.load`(经 `config_doc.zig`,只拥有自己的键并保留其他键)。
teamwork 段将在 `src/app/config.zig` 旁接入:读出 `teamwork` 成员后交给 `config.parseValue`,
项目层读 `.metacodes/teamwork.json`,命令行层由 `main.zig` 的参数解析构造 `Layer`,三者经
`merge` 后 `validate`,在 `/teamwork` 启动前报错。该接线随 #518 落地。

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
= `../../ORIGINAL_REQUEST.md`、`seat_relative_open_issues`);packet 的绝对路径只出现在驱动启动
seat 的参数里,不进入 Manager 的提示词。写入隔离(seat 只能写自己的目录)由权限层和沙箱在
#519 余下部分保证,不靠提示词。

## 5. 预算账本

`src/teamwork/ledger.zig`,`budget.jsonl` 每行一条:

```json
{"seat_id":"implementer-1","harness":"claude_code","usd":0.42,"wallclock_ms":61000,"source":"harness_reported"}
```

- `source` 为 `provider_estimate`(metacodes 自己的估算)、`harness_reported`(外部 harness 结果
  事件里的花费)或 `wallclock_only`(读不到花费,`usd` 为 null)。类型上 `Cost = union(Source)`,
  有金额当且仅当来源有金额。
- `Ledger.charge` 先追加并 fsync,再更新合计;合计达到上限(`spent >= cap`)时返回
  `BudgetExhausted`,但这笔仍然入账(钱已经花了),之后每一笔都返回 `BudgetExhausted`。
  负数、NaN、无穷拒收(`InvalidAmount`),不入账。
- `Ledger.load` 从磁盘重新求和。最后一行没有换行符说明追加时崩溃:丢弃并把文件截断到最后一个
  完整行,保证下一次追加从新行开始;**完整行**解析失败则不是崩溃产物,返回 `CorruptLedger`
  (预算数据宁可停也不猜)。
- `remainingUsd()` 将作为 metacodes seat 子 agent 的 `cost_budget_usd`(`src/core/subagent.zig`)。
- 账本只有 runtime 写,不是线程安全的,由 runtime 串行化。

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

## 7. 公共面

`src/lib.zig` 导出 `teamwork_types`、`teamwork_config`、`teamwork_run_dir`、`teamwork_ledger`、
`teamwork_issues`、`teamwork_reviewer`(与 swarm 子系统相同的方式);`stub_driver.zig` 只由测试引用。单元测试同时进入
`zig build test:units`(`src/main.zig` 的测试根)与 `zig build test:lib`。

## 8. 不做

锦标赛树、数学证明管线、文档评审路线、大规模角色组合(见 #514"不做")。

## 9. 实现状态

| Issue | 内容 | 状态 |
|---|---|---|
| #515 | runtime / seat 分层、角色配置、worker 契约 | 本分支:类型、`SeatDriver` 接口、handoff 解析、配置 parse/merge/validate、测试用 stub 驱动。待做:真实 metacodes 驱动、接入配置加载、L2(改 harness 即改子进程) |
| #516 | 独立 verifier / 完成审计 | 待做 |
| #517 | reviewer 角色与 open-issues 台账 | 已做(§6):宪章与工具表、`review.json` 解析、观测比对(`BashCallLog`)、钉住检查重跑(`check_command`)、零修改与过期批准(树 id)、台账与跨轮 packet。待做:metacodes 驱动接上 `BashCallLog` 与 `charters.forRole(.reviewer)`、编排器的再开一轮;Windows 上 `workspaceTree` 返回 `Unsupported`,批准无法确认 |
| #518 | `/teamwork` 命令、面试与批准 | 待做(含配置接线,§3) |
| #519 | 运行状态目录与写入隔离 | 本分支:目录布局、只写一次的原始请求、seat 状态、崩溃恢复。待做:权限层与沙箱的写入隔离、provider 字节不含运行路径的 L2 断言 |
| #520 | 运行级预算 | 本分支:账本、上限、崩溃安全重载。待做:接 `cost_budget_usd`、停止所有 seat、外部 harness 花费采集 |
| #521 | Claude Code 作为 worker | 待做 |
| #522 | Claude Code 作为 Manager(MCP) | 待做 |
| #523 | worktree 合回 | 待做 |
| #524 | 进度面板与 AgentCore 事件 | 待做 |
| #525 | 并行候选与择优 | 待做 |
