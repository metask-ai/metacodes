# AgentCore ABI v1 RunContext 调整方案：统一已准入 Run 上下文

> 状态：**方案通过，进入实现；暂不复冻**（2026-07-18，消费端与评审方均已签字）。
> 设计打磨停止；除非实现中出现 UAF、所有权冲突、ABI 布局或 wire 不可迁移问题，
> 不再重新开启架构讨论。实现以测试 30a/30b、37-40 及既有矩阵为约束。
>
> 前提：v1 为实验版（冻结已于 2026-07-17 撤回，无稳定承诺，消费者 pin bundle），
> 故本轮为 **v1 原地 breaking 变更**，不新发 `get_api(2)`。版本号留给冻结事件之后。

## 0. 修复目标与已否决方案

修复 v1 冻结被撤回的病灶——回调身份面缺口：

- Host 工具回调收到 `session_id` 关联键，但 v1 无任何 API 让 Host 获得该值（悬空引用）；
- 三类回调身份形状互异（event: 句柄+run_id / ui: 仅句柄 / 工具: 仅 session_id 字符串）。

**已否决**：`run_token` 层（含 out 参数投递与 Host 生成两个变体）。判据归档：

1. run_id 本就是 Host 分配、调用前自持——跨线程投递问题不存在；
2. 锁内严格递增的 run_id 已提供 anti-ABA generation；
3. Host 即信任边界，token 与 (session, run_id) 同抽屉存放，对 Host 内部路由错误零鉴别力。

**token 重引入判据**（任一成立前免谈）：run_id 允许复用；abort 授权走出 Host 之外；
Renderer 获得直接触达 ABI 的能力（信任边界移动）。

**已否决**：opaque per-Run 句柄（堆分配/地址复用/UAF 校验负担；borrowed 值语义全部规避）。

## 1. Wire 层变更

### 1.1 新类型 `mc_run_context_v1`

```c
typedef struct {
    uint32_t struct_size;        /* = sizeof(mc_run_context_v1)，库填充 */
    uint32_t reserved0;          /* 0 */
    mc_session *session;         /* session_create 发布的原始句柄 */
    uint64_t run_id;             /* 本次 session_run 传入的准入 Run ID，非零 */
    mc_bytes_view_v1 session_id; /* core 会话身份，borrowed UTF-8，非空 */
    uint64_t reserved[2];        /* 0 */
} mc_run_context_v1;
```

64 位平台 `sizeof == 56`。Zig 侧 `RunContextV1` 镜像定义，双侧 layout assertion
（`@sizeOf`/`@offsetOf` + C 端 `_Static_assert`）为测试矩阵第 1 项。

新增常量 `MC_MAX_SESSION_ID_BYTES_V1`（取宽松上限如 64，**不冻结当前 24 字节
实现格式**）。validator 对 `session_id` 的校验顺序：先
`0 < len <= MC_MAX_SESSION_ID_BYTES_V1`，**通过后才**构造 slice 做 UTF-8 校验——
否则坏 bundle 给个巨大 len，validator 自己先越界。

### 1.2 回调签名统一（breaking）

三个 per-Run 回调的身份参数统一为 `const mc_run_context_v1 *`：

```c
/* 原 (ctx, session, run_id, event_json) */
typedef uint32_t (*mc_on_event_fn_v1)(
    void *session_ctx, const mc_run_context_v1 *run, mc_bytes_view_v1 event_json);

/* 原 (ctx, session, request_json, out_response) */
typedef uint32_t (*mc_on_ui_request_fn_v1)(
    void *session_ctx, const mc_run_context_v1 *run,
    mc_bytes_view_v1 request_json, mc_owned_bytes_v1 *out_response);

/* 原 (host_ctx, session_id, arguments_json, out_result) */
typedef uint32_t (*mc_host_execute_fn_v1)(
    void *host_ctx, const mc_run_context_v1 *run,
    mc_bytes_view_v1 arguments_json, mc_owned_bytes_v1 *out_result);
```

`release_response` / Host 工具 `release_result` 为纯释放配对、无路由需求，**签名不动**。
`session_run` / `session_abort` **签名不动**（无 token；abort 维持 `(session, run_id)`）。

### 1.3 Host 工具状态码新增：`MC_HOST_FATAL`

```c
#define MC_HOST_OK 0u        /* 不变：成功，结果模型可见 */
#define MC_HOST_FAILED 1u    /* 不变：业务失败，转模型可见 tool error */
#define MC_HOST_REJECTED 2u  /* 不变：业务拒绝，转模型可见 tool error */
#define MC_HOST_FATAL 3u     /* 新增：不可恢复的 Host 基础设施/契约失败，fail closed */
```

`MC_HOST_FATAL` 是与 event fatal、UI fatal 对称的通用 Host 工具 fatal 通道；
身份失配只是其来源之一。分层原则（normative）：**fatal 与否由有语境的一方声明；
库只自动升级"无法安全继续"的情形**。

进入本通道的情形：

- Host 显式返回 `MC_HOST_FATAL`（身份失配、registry/lifecycle invariant 失败、
  Host 回调自身不可恢复的 infrastructure failure——由 Host 判定）；
- 库自动升级：Host 返回**未定义状态码**（>3，状态词汇表失效）；
  `HOST_OK` 携带**非法 buffer descriptor**（所有权语义已不可信，遏制无保证）。

**保持遏制（不自动 fatal）**：result 超限、非 UTF-8 属数据形状违规，库可安全遏制
（按 ownership 规则释放、转模型可见 tool error）——维持现状。视其为 fatal 的 Host
（如 MetaWork）在返回前自检并主动返回 `MC_HOST_FATAL`，严格政策是 Host 侧的一行代码，
SDK 不为单一消费端的政策偏好升级全体默认。
（此处为对消费端反馈的**有理偏离**，待其确认——见 §8。）

端到端语义（normative）：不生成模型可见 tool_result → 不进入下一轮 → 置 callback
failure → 中止当前 Run → `session_run` 返回 `MC_STATUS_CALLBACK_FAILED` →
RunResult 不可读 → Session poisoned。

**Behavior delta（明示）**：未知状态码从"折成模型可见 tool error"升级为 fatal。
`HOST_FAILED`/`HOST_REJECTED`、超限、非 UTF-8 保持模型可见（回归测试钉死）。

**业务失败携带详情（并入自 v1 审计 A2，同一回调面一次 breaking）**：
`MC_HOST_FAILED` / `MC_HOST_REJECTED` 的 `out_result` 不再被释放并忽略，而是作为
**受限错误详情**消费：合法 UTF-8 且不超过 `MC_MAX_HOST_TOOL_RESULT_BYTES_V1` 时，
其内容进入模型可见 tool error（模型据此自纠："字段无效"≠"资源不存在"≠"策略拒绝"）；
空 descriptor 或形状违规退回通用错误文案。杜绝 Host 用 `HOST_OK` 伪装业务失败来
夹带信息的歪路。

**编码安全（原则：任意外部字节进入结构化格式必须走 serializer + 编码后边界）**：
详情是任意 UTF-8（可含引号、反斜线、换行、控制字符、伪造 JSON 字段），**禁止
字符串拼接进 JSON**。承诺的等式是 `decoded tool error detail == Host 原始 UTF-8`
（经 JSON serializer 字符串编码），而不是"encoded bytes 包含原文"。

**编码后边界的完整合同**（双常量 + 失败语义，不留"有界"空话）：

```c
raw detail    <= MC_MAX_HOST_TOOL_RESULT_BYTES_V1        /* 既有，16 MiB */
encoded error <= MC_MAX_TOOL_ERROR_PAYLOAD_BYTES_V1      /* 新增，1 MiB */
```

- 编码用 **capped writer 或 overflow-safe preflight**——先算/边写边限，**不得
  先无界分配再检查**（近上限控制字符会先制造数十 MiB 临时分配）；
- 编码后超限：释放 Host descriptor（恰好一次），**回退通用错误文案**；
- **不截断**——截断会破坏 UTF-8/JSON；
- 超限仍按普通 `HOST_FAILED`/`HOST_REJECTED` 处理，**不自动 fatal**；
- 编码完成的错误 payload 是模型自纠所需的语义输入，**不得**被通用 tool-result
  persistence 或 per-message aggregate budget 替换为 persisted/truncated 信封；
- Host 侧义务：详情不得含 credential；模型可见错误本应紧凑，超 1 MiB 的
  "详情"自身就是异味。

**内部类型通道（详情必须有类型承载——Zig error 不携带 payload，
`HostToolError!HostToolResult` 传不过去，"对齐 err_detail 槽"不是设计）**：

```zig
pub const HostToolOutcome = union(enum) {
    ok: HostToolResult,        // 所有权：转移给调用方，经 result.release() 归还
    failed: ?HostToolResult,   // 详情（可空）：借出至 tool error 组装完成，随后释放
    rejected: ?HostToolResult, // 同 failed
    fatal,                     // 无 payload；六条 fatal 规则接管
};
// executor 签名：HostToolError!HostToolResult → error{OutOfMemory}!HostToolOutcome
```

**Dispatcher 边界的第二个类型层**（`dispatchFn(...) anyerror![]u8` 承载不了
outcome，`HostToolOutcome` 到 `Selection.dispatch` 就断——两层都要有类型）：

```zig
pub const ToolDispatchOutcome = union(enum) {
    ok: []u8,            // tool_ctx.allocator-owned（勿在类型上暗示 arena 生命周期）
    host_failed: ?[]u8,  // tool_ctx.allocator-owned 详情副本（可空）
    host_rejected: ?[]u8,
    host_fatal,
    // deinit(allocator) 释放后将 self 置空态/undefined——重复 deinit 是 bug，
    // 让它在 Debug 下必炸而不是静默双释放。
};
```

**签名冻结**（防"定义了 union 但 dispatchFn 忘换"的假实现）：

```zig
// src/tools/context.zig — ToolDispatcher
dispatchFn: *const fn (...) anyerror!ToolDispatchOutcome,  // 原 anyerror![]u8
// src/tools.zig
pub fn dispatch(...) anyerror!ToolDispatchOutcome;
// builtin/dynamic 成功结果一律包装为 .ok
pub fn deinit(self: *ToolDispatchOutcome, allocator: Allocator) void; // 类型自带
```

完整所有权链（每段一个 owner，不制造第三种生命周期）：
ABI descriptor（Host-owned）→ `HostToolOutcome`（仍 Host-owned）→
`Selection.dispatch` **复制必要内容（`tool_ctx.allocator` 分配）并当场 release
Host descriptor（恰好一次）** → `ToolDispatchOutcome`（**tool_ctx.allocator-owned**，
caller 经 `deinit(allocator)` 释放；`ToolDispatcher` 是可独立调用的 core 接口，
调用方不一定用 arena——`tool_exec` 用 arena 时 deinit 统一退化为 arena 生命周期，
但 ownership 规则以 allocator 为准，不以 arena 为准）→ `tool_exec` 就地组装
error JSON / 走 fatal 控制流。

**复制失败路径（所有权代码最容易死在中间失败上）**：合法 detail + 本地
`allocator.dupe` OOM 时：Host descriptor 仍恰好 release 一次；不返回半初始化
outcome；admitted Run 按 OOM 合同毒化；**不生成模型可见的截断 detail**。
`fatal` 无内容。禁止任何隐式 side channel——不采用"写 `ToolContext.error_detail`
后返回 error"的替代方案，类型链与宣言保持一致。

**释放规则（normative）**：无论回调返回何种状态，凡携带需要释放的 result
descriptor，库按既有 ownership 规则**恰好释放一次**（消费详情后同样释放）——
fatal 路径不例外。

### 1.4 discovery 错配防线 `abi_revision`

```c
#define MC_AGENTCORE_ABI_REVISION 2u
```

完整新表布局（这是 C ABI，字段不存在"随便塞进去"）：

```c
typedef struct {
    uint32_t struct_size;   /* offset 0：稳定前缀，跨 revision 不动 */
    uint32_t abi_version;   /* offset 4：稳定前缀，恒为 1 */
    uint32_t abi_revision;  /* offset 8：新增，本批取值 2（撤冻时形状 = legacy
                               pre-revision shape，无此字段——不称其为 revision 1） */
    uint32_t reserved0;     /* offset 12：0 */
    uint64_t capabilities;  /* offset 16（原 8，+8） */
    mc_runtime_create_fn_v1 runtime_create;   /* offset 24（原 16，全部函数指针 +8） */
    /* ... 其余 6 个函数指针顺序不变 ... */
    uint64_t reserved[4];
} mc_agentcore_api_v1;      /* sizeof: 104 → 112；STATIC_ASSERT 全部同步更新 */
```

消费者 validation 顺序（normative）：先读**稳定前缀**（offset 0-7：struct_size、
abi_version）并校验 `struct_size == 112` 与 `abi_version == 1`，通过后才读
`abi_revision` 及后续字段。实验期每次 breaking 变更 revision +1。消费者 **MUST**
做**精确相等**校验、不做范围兼容：`abi_revision == 当前锁定 revision`、required
capabilities 满足——不匹配即拒绝，header/lib 错配从"运行到回调才 UB"降级为确定性
拒绝。消费端只实现当前 revision，不保留旧 revision 兼容。
manifest 同步记录（additive 字段，schema_version 1 不变）：

```json
{ "binary_abi_version": 1, "binary_abi_revision": 2 }
```

冻结后 revision 封存，后续扩展回归 `get_api(2)` 通道。
**消费端已确认采用（2026-07-18）。**

### 1.5 回调状态族命名规范化（breaking，随本批执行）

三类回调的返回状态族应平行命名为 `EVENT / UI / HOST`。现状中 event 族占用了泛化词
`CALLBACK_`（`31e9b33`，2026-07-15 三族同一 commit 起名的随手选择，非历史包袱）：

```c
/* 旧 */                          /* 新 */
#define MC_CALLBACK_CONTINUE 0u   #define MC_EVENT_CONTINUE 0u
#define MC_CALLBACK_FATAL 1u      #define MC_EVENT_FATAL 1u
```

Zig 镜像 `CALLBACK_CONTINUE/FATAL → EVENT_CONTINUE/FATAL` 同步。数值不变，仅改名；
旧宏**删除不保留别名**（实验版，错配由 §1.4 abi_revision 在 discovery 拒绝）。
落成后三条 fatal 通道为 `MC_EVENT_FATAL` / `MC_UI_FATAL` / `MC_HOST_FATAL`。

**明确不改**：`MC_STATUS_CALLBACK_FAILED` 保持原名——它是库侧 API 状态，语义覆盖
全部三类回调的失败，泛化词在此处是正确用法。

本项为提供方整体规范化决策（2026-07-18），随本批 breaking 变更零额外成本执行，
经迁移说明告知消费端。

## 2. Identity invariants（冻结候选，消费端文本）

1. `run->session` == 本 Session 由 `session_create` 发布的**原始句柄**（指针相等）；
2. `run->run_id` == 本回调所属 `session_run` 调用**传入**的 run_id；
3. `run->session_id` 在整个 Session 生命周期内字节稳定（该 Session 所有 Run 的所有回调观察到相同字节）；
4. 同时存活的不同 Session 不共享 session 句柄或 session_id；
5. 同一 Session 连续两个 Run：相同 session、相同 session_id、严格递增的 run_id。

Host 据此可采用注册模式：`session_create` 后登记句柄，即可安全路由后续任意 Run 回调。

## 3. 生命周期合同

### 3.1 terminal 定义与线性链（normative）

**terminal := `session_run` 返回且 Session 生命周期状态落定**——不是任何 JSON observation
（observation 本身是回调，不可能排在 quiescence 之后）。线性链：

```
admission 线性化（beginRun 锁下）
→ RunContext tuple 固定
→ per-Run 回调（全部携带同一 tuple）
→ 最后一个回调返回 → 回调 quiescent
→ AgentSession 完成 Run 状态转换
→ session_run 返回
→ 之后才可能发生：下一 Run admission / session destroy
```

保证：admission 前绝不发生 per-Run 回调；`session_run(N)` 返回后不再有 Run N 的任何
回调**或 paired release 回调**；下一 Run 的回调不与旧 Run 回调重叠；destroy 不与回调
并发（Host 义务：串行化 destroy 与 run/abort，沿用现有条款）。

**并发模型（与已发布 header 对齐，不新造承诺）**：同一 Session 内 **Host 工具回调
可能并发**（header 现行契约："A Host tool may also be invoked concurrently within
one Session"，工具批并发执行是既有能力）；event 交付经 `callback_mutex` 串行化；
UI 请求同步发生。**本合同不承诺"同一 Run 回调不并发"**——承诺的是 quiescence：
terminal 前所有并发 worker join、所有回调（含 `release_result`/`release_response`
等 paired release 回调）已返回。

**实现基础的诚实边界**：core 侧顺序已有机制（`finishRunLifecycle`/`poisonRun` 以
`callback_mutex → mutex` 次序保证状态转换排在在飞 event 交付之后；工具 worker 在
Run 内 join）。但 **facade epilogue 是承诺缺口**：core 置 idle 后，facade 还要处理
stop reason、填写 RunResult 才真正返回——此窗口内第二个 `session_run` 会看到 core
idle 而**提前 admission**，`session_destroy` 会成功销毁仍被 epilogue 使用的
AbiSession（UAF）。core 的 `active_run_id` 和 `callback_mutex` 挡不住这一层。

**Facade call gate（新增机制，承诺时序的层自己持有执行机制）**：

```
AbiSession 状态机（mutex 保护，杜绝 check-then-act）：
idle → session_run 独占 running → Core Run → facade epilogue
     → session_run 即将返回处才释放回 idle
```

**Linearization 合同**（不承诺物理返回时序——mutex 不可能持有到 C 函数返回之后，
"返回前始终 BUSY"是不可实现的写法）：

- **completion linearization point** 位于本次调用对 AbiSession 的**最后一次访问
  之后**（gate 释放处）；
- 在该点**之前**进入的重叠 `session_run` / `session_destroy` 得到 `MC_STATUS_BUSY`；
- 该点**之后**的新调用可以成功——即使旧调用的 caller 尚未观察到函数返回；
- gate 释放后，旧调用**绝不再读写 AbiSession**（这条消灭 UAF，与物理返回时刻无关）；
- 非重叠调用（caller 已观察到旧调用返回后再调）自然看到 idle；
- `session_abort` **不经过 gate**，保持并发可入（回调内 abort 依赖此性质）；
- gate 用 mutex + 状态实现，**禁止裸 atomic bool**（check-then-act 竞态原样复活）。

### 3.2 回调重入

- `session_abort(run->session, run->run_id)` 在任意 per-Run 回调内**合法且不阻塞**
  （abort 路径不获取回调派发持有的锁）；
- 回调内调用 `session_run` / `session_destroy` → `MC_STATUS_BUSY`。

### 3.3 RunContext 使用规则

1. `*run` 与 `run->session_id.ptr` 仅在回调动态作用域内有效——**不得保存 run_context 指针**；
2. 标量字段（session 指针值、run_id）可复制留存；
3. 异步保留 session_id 必须在回调返回前深拷贝；
4. `session` 仅作 opaque 身份比较与 API 调用参数，Host 不得解引用；
5. 所有字段在回调期间 immutable；
6. 值语义消除库侧分配与失效校验；Host 侧误用由本合同禁止，不由物理机制消灭。

## 4. 失配 fail-closed（normative）

Host 在回调中检测到以下任一情况，即为 ABI/lifecycle 契约失败，而非业务错误：

- `run->session` 不在 Host registry；
- 该 Session 正在 closing/closed；
- `run_id` 不是该 Session 的 active Run；
- `session_id` 与 registry 绑定值不符（**含跨 Run 漂移**：Host registry 在该 Session
  首个回调时绑定 session_id，此后所有 Run 的所有回调均与绑定值比较——只查"同一 Run
  内变化"会漏过 Run 1 用 A、Run 2 用 B 的违约）。

**首次绑定必须原子化**（Host 工具回调可并发 ⇒ "首个回调"可能是两个并发工具
callback，`if unbound: bind else: compare` 不在同一把锁下就是标准 check-then-set
race）。Host 消费合同：绑定与比较在**同一个 per-Session lock** 内完成；两个相同
ID 的并发首次回调都成功；两个不同 ID 并发时**恰好一个完成绑定、另一个 fatal**；
不得依赖"通常先有 event"这类未写进 ABI 的时序运气。

处理义务（**MUST**，双向）：

| 通道 | Host 动作 | 库承诺 |
|------|-----------|--------|
| `on_event` | 返回 `MC_EVENT_FATAL` | 中止 Run + 毒化 Session（现有机制） |
| `on_ui_request` | 返回 `MC_UI_FATAL` | 同上（现有机制） |
| Host 工具 | 返回 `MC_HOST_FATAL` | 中止 + 毒化，**不注入模型可见 tool_result**（新增通道） |

**UI 状态语义精确化**：`MC_UI_UNAVAILABLE` 是**正常非致命业务状态**（UI 暂不可用），
不进入 fatal 通道；只有 `MC_UI_FATAL` 与库自动升级的**未知 UI 状态码**才 fatal。
实现禁止写成 `status != ANSWERED → poison`。

Host **MUST NOT** 将契约失败伪装为 tool rejected、UI unavailable 或普通业务错误。
三条通道最终均使 `session_run` 返回 `MC_STATUS_CALLBACK_FAILED`，后续调用 `INVALID_STATE`。

**库侧配套义务**：invariant 4（并存 Session 不共享 session_id）由 Runtime 的
session registry 做 **collision detection** 主动保证——"生成两个 ID 然后断言不同"
是测试不是保证。registry 的存储与注销合同：

- key 用 `[24]u8` **值语义**（`SessionId.bytes` 定长拷贝，`std.AutoHashMap([24]u8, void)`），
  **禁止借用 slice key**——本仓吃过 HashMap slice key 悬挂的亏，身份安全边界不重踩；
- Session 创建失败必须回滚注册；destroy 成功必须注销；Runtime destroy 时 registry
  **必须为空**（否则 INVALID_STATE 级内部错误）；
- collision 时重新生成并原子注册，**重试有上限**（超限报不可达级内部错误），
  防生成器故障导致无限循环。

## 5. abort 矩阵补充冻结行

| 情形 | 结果 |
|------|------|
| poisoned + 任何参数 | `INVALID_STATE`（沿用 v1 已冻结优先级：poisoned 先于一切参数校验，明示不推翻） |
| active + 相同 (session, run_id) 重复 abort | 幂等 `OK` |
| pre-admission 拒绝 | 尚未使用且大于 last admitted 的 run_id，因 BUSY/资源/可修复参数问题被拒时不被消耗，修复原因后可复用；**zero/stale 不在此列**（原样重试永远失败，沿用 v1 精确措辞） |
| destroy 并发 | 契约外（Host 串行化义务，沿用） |
| 多参数错误并存 | 返回哪个 unspecified（沿用 v1） |

## 6. 实现要点与改动清单

**内部身份贯穿（normative 内部设计，消费端第 1 条采纳）**：

```zig
/// 库内部专用，随调用链向下传值，admission 处固定，Run 期间 immutable。
const RunIdentity = struct {
    session_id: SessionId,
    run_id: u64,
};
const HostRunIdentity = struct {
    identity: RunIdentity,
    host_session_ctx: *anyopaque,
    // 命名双重约束：① 不叫 session_ctx——公开回调首参已用该名指 Host-owned ctx，
    // 同名必致误 cast；② 不叫 abi_session_ctx——本类型在 core 管线，普通 core
    // 消费者也可注册 Host tool，core 不该在名字里知道消费方是 ABI facade。
    // 类型已擦除，只有注册方 adapter（ABI 场景即 AbiHostTool）知道其真实指向。
};
```

**共享基础设施扩展规则（本设计的边界总则，统摄以下三条链）**：facade 的身份需求
**不得重塑通用接口**。通用接口（`UiRequester` 服务 TUI/Web/daemon/plan tools、
`ToolContext` 服务全部 builtin 工具）只允许"可选字段 + null 默认"式扩展或专用
adapter 旁路，**绝不改通用签名**逼无关调用方编造无意义值。

**三条内部身份链全部闭包**（设计闭包 = 每条链的 run_id 有类型通道）：

- event：`emit(ctx, SessionId, run_id, event)` — 现有签名已含 run_id ✓；
- Host tool：`?HostRunIdentity` 经 ToolContext **可选字段**贯穿（非 ABI 调用方
  为 null，通用消费者无感）✓；
- **UI：通用 `UiRequester` 签名不动**，`AgentSession` 增专用 run-aware adapter：

```zig
const AgentSessionUiRequester = struct {
    ctx: *anyopaque,
    requestFn: *const fn (ctx: *anyopaque, identity: RunIdentity,
        allocator: Allocator, req: *const UiRequest,
        out: *UiResponse) anyerror!RequestOutcome,
};
// 链：PermissionContext 通用 UiRequester → AgentSession.requestHostUi adapter
//    → 锁内 snapshot {session_id, active_run_id} → 释放锁
//    → AgentSessionUiRequester → AbiSession.requestUi → mc_run_context_v1
```

**"锁内 snapshot"与禁令的精确边界**：禁止的是**无锁回查全局 mutable 状态**；
在 admission 状态的唯一真理源（`AgentSession`，每 Session 至多一个 active Run）
的**锁内做一次 snapshot、随后显式传值**，是显式传递的合法起点，二者不混同。
snapshot 后、调用 Host 前必须已释放 mutex（abort 重入依赖此序）。
idle/poisoned 状态下 adapter **不得触发 Host callback**（防御性短路）。

**incoming SessionId 校验（不许静默"修正"上游串线）**：通用 `UiRequester` 会传入
SessionId，adapter **禁止忽略它并用 `self.session_id` 覆盖**——那是替串线擦屁股，
统一 RunContext 的目的恰恰是暴露串线。锁内 snapshot 时同步校验
`incoming_session_id == self.session_id`，失配即 infrastructure failure：
不触发 Host callback → 置 callback failure → abort 当前 Run → Session 毒化。

**host_identity_ctx / host_session_ctx 的合法状态（消除"随时 null/乱 cast"的裸指针）**：core `SessionInit`
增显式可选配置 `host_identity_ctx: ?*anyopaque = null`。规则：

- 未选任何 Host tool 的 Session：允许为 null（普通 core 消费者、无 Host tool 场景）；
- 选择了 Host tool 但 `host_identity_ctx == null`：`session_create` 在 admission 校验
  处**拒绝**（`INVALID_ARGUMENT` 族），不留"理论上不可能"的运行期空态；
- 所有权：ctx 由创建方（facade/宿主）持有，必须存活至该 Session destroy 成功；
- 解释权：**只有注册该 ctx 的 executor**（ABI 场景即 `AbiHostTool` 包装层）可以
  cast 这个 type-erased 指针，core 只透传、永不解引用。

贯穿链：`session_create` 时 core `AgentSession` 保存 `host_identity_ctx` →
`beginRun` 固定 run_id → `ToolContext` 携带 `HostRunIdentity` →
`AbiHostTool.execute` 就地构造 `mc_run_context_v1`。

**四条禁令**：不借用 event sink 的 ctx；不用 TLS；不设全局 current-Session；
**不按 session_id 反查**（那是把刚修好的断链在库内部重造一遍）。

**fatal 传播的类型闭环（控制流设计，非实现细节）**：现状 `executeOne` 返回普通
`OneResult`、`executeSlots` 与并发 worker 返回 void——不存在"上抛"的类型通道，
一句"catch 豁免"过不了本仓的 Type-First 原则。签名先行：

```zig
const OneResult = union(enum) {
    done: DoneResult,
    pending: PendingResult,
    host_fatal,            // 新增：类型化 fatal 信号，逐层显式传递
};
// executeSlots 将 host_fatal 汇聚为错误返回，agent loop 显式处理：
fn executeSlots(...) error{HostToolFatal}!void;
```

fatal 发生后的六条强制规则：① 不再启动后续 slot；② 已启动的并发 worker 全部 join；
③ 已取得的 Host buffer 按 ownership 规则**恰好 release 一次**；④ 不组装任何
tool_result；⑤ 最终经 `poisonRun` 映射为 `CallbackFailed` → `MC_STATUS_CALLBACK_FAILED`；
⑥ **fatal 返回前销毁所有已完成/prefetched/pending slot 的 owned payload**
（`slot.content`、`pending_kind`/`pending_payload`、prefetch 结果），已转移 ownership
的字段先置 null——现状 `defer slots.deinit()` 只释放列表存储不管内部指针，正常路径
靠转移给 result_blocks 续命，fatal 在转移前返回即泄漏。

配套结构（覆盖所有退出路径，不靠人肉记）：

```zig
fn Slot.deinit(self: *Slot, allocator: Allocator) void;  // 释放全部 owned payload
fn Slot.takeContent(self: *Slot) ?[]u8;                  // 转移即置 null
```

agent loop 以单个 defer 遍历 `slots` 调 `Slot.deinit`，转移过的字段已 null 则天然跳过。
对已由 `maybePersist()` 落盘但尚未产生引用的 transient result：**persistence 延迟到
batch 确认无 fatal 之后**（首选），或追踪并在 fatal 清理时删除——不制造孤儿文件。

**Host 工具并发判定去猜名化（诚实的生产路径）**：现状 `slotSafe` 按工具名判定并发
安全（`isConcurrencySafeInput(s.name, ...)`），不区分 builtin 与 host_sync——Host 工具
叫 "Read" 就碰巧并发、叫别的就默默串行，这是事故不是设计。本批修正：dispatcher 增加
显式 concurrency metadata，**`.host_sync` 条目一律判定为可并发**（与已发布 header
"A Host tool may also be invoked concurrently within one Session" 及 tool_catalog
"Host owns ctx locking" 的既有契约对齐）；builtin 维持现有名字/输入判定。
**禁止**用"注册一个叫 Read 的 Host tool"骗过并发测试——测试必须走 metadata 路径。

| 层 | 改动 |
|----|------|
| `src/core/agent_session.zig` / `tool_catalog.zig` | SessionInit 增 `host_identity_ctx: ?*anyopaque`（选 Host tool 时非空校验）；`HostRunIdentity` 贯穿至 host tool 执行点（executor 签名/ToolContext 扩参）；executor 返回类型从 `HostToolError!HostToolResult` 改为 **typed outcome**（Zig error 不携带 payload，A2 详情必须有类型通道，见下）；Runtime session registry 增 session_id collision detection |
| `src/tools/context.zig` / `src/tools.zig` | `dispatchFn` 与 `tools.dispatch` 换签名为 `anyerror!ToolDispatchOutcome`（两层缺一即假实现）；`ToolDispatchOutcome` 定义与 `deinit(allocator)` |
| `src/core/tool_exec.zig` / `agent_loop.zig` | `OneResult` 增 `host_fatal` 分支；`executeSlots` 返回 `error{HostToolFatal}!void`；六条 fatal 规则（停 slot / join / release 一次 / 无 tool_result / 映射 CallbackFailed / slot-owned payload 全销毁）；`error.UiPending` 豁免模式仅作参考先例 |
| `src/core/stream_prefetch.zig` | 适配 `executeOne` typed outcome；speculative OOM/UI/fatal 标记 `skip`，交回 authoritative `executeSlots` 重放并执行完整 Run 失败合同 |
| `src/core/agent_session.zig`（UI adapter） | `AgentSessionUiRequester` + `requestHostUi` 锁内 snapshot adapter；通用 `UiRequester`（TUI/Web/daemon）签名零改动 |
| `src/agentcore/abi_v1.zig` | **不做 session_id 缓存**——canonical 源唯一为 core `AgentSession.session_id`，三类回调各自从 core 送达的身份值（emit 的参数、UI 的 `RunIdentity`、工具的 `HostRunIdentity`）**在各自栈帧构造独立的** `mc_run_context_v1`；**admission 固定的是 tuple 值，不是共享指针**——只保证字段值一致，不保证不同回调收到相同 RunContext 指针（Host tool 可并发，共享指针本就不成立；与测试 6 的按字段比较一致）；三回调签名适配；`AbiHostTool` 经 `HostRunIdentity.host_session_ctx`（cast 回 AbiSession）记录 callback failure；未知 HOST/UI 状态码、非法 descriptor 自动 fatal |
| `sdk/*.h` / `sdk/*_types.zig` | `mc_run_context_v1` + 三签名 + `MC_HOST_FATAL` + `MC_EVENT_*` 改名 + `abi_revision`（API 表新布局 sizeof 112 + 全部 STATIC_ASSERT 更新） |
| typed SDK | RunContext validator：struct_size / reserved 零 / session 非空 / run_id 非零 / session_id **先 len 界（0 < len ≤ MC_MAX_SESSION_ID_BYTES_V1）后 ptr+UTF-8** |
| `src/agentcore/abi_v1.zig`（call gate） | AbiSession 增 mutex 保护的 facade 状态机（idle/running/destroying）；session_run 独占至 **completion linearization point**，释放后**不得再访问 AbiSession**；point 前重叠 run/destroy → BUSY；abort 不经 gate |
| `doc/AGENTCORE_BINARY_ABI.md` | §2–§5 全部条款 normative 化 + token 重引入判据入 Future directions + 迁移说明 |
| manifest / consumer | manifest 记录 abi_revision；artifact consumer（Zig/C/C++）迁移新签名并真实运行；discovery 拒错配探针 |

## 7. 测试矩阵

**Layout/validator**
1. C/Zig 双侧 size/offset 断言（RunContext 56 + API 表 112）；
2. typed validator 全字段双侧测试。

**Identity invariants**
3. 三种回调中 `run->session`==原始句柄、`run_id`==传入值——UI 腿必须走**真实
   permission/AskUserQuestion 路径**断言看到传入 run_id，不许只单测手工构造的回调；
4. 连续两 Run 同 session/session_id、递增 run_id；
5. 双并存 Session 句柄与 session_id 互异、字段互不串扰；
6. 同一 Run 三种回调 Context **完整初始化后按字段值比较**一致（不在含 padding 的
   内存上 memcmp）；
7. 跨 Run session_id 漂移 → 对应回调返回 fatal → 毒化（Host registry 绑定值路径）；
8. Runtime session registry collision detection（库侧主动保证，非仅生成后断言）。

**Lifecycle**
9. quiescence——`session_run` 返回后置 flag，断言零后续回调**且零后续 release 回调**，
   下一 Run 首回调观察新 tuple；
10. admission 前零 per-Run 回调；
11. 回调内 abort 补 `on_ui_request` 腿（`on_event` 腿已有）；
12. 回调内 `session_run` → `BUSY`；
13. 并发 Host 工具 + fatal：fatal 后不启动新 slot、已启动 worker 全部 join 后才 terminal。

**Fail-closed**
14. 工具返回 `MC_HOST_FATAL` → Run 中止、Session 毒化、`session_run` 返回
    `CALLBACK_FAILED`、**无模型可见 tool_result 产生**、RunResult 不可读；
15. 未知 HOST 状态码、非法 descriptor 自动进入同一 fatal 通道（同 14 断言）；
16. `HOST_FAILED`/`HOST_REJECTED`、超限、非 UTF-8 仍模型可见（回归，双侧）；
    且 FAILED/REJECTED 详情经 serializer 编码后**解码等于 Host 原文**（禁拼接）、
    空/违规详情退通用文案、详情 descriptor 消费后仍恰好释放一次（A2 三侧断言）；
    转义膨胀用例：引号/反斜线/换行/控制字符/近上限详情，编码后 payload 仍有界；
17. **UI 双侧**：`MC_UI_UNAVAILABLE` 非致命（Run 正常续行）、`MC_UI_FATAL` 与未知
    UI 状态码毒化——防止 `status != ANSWERED → poison` 的懒实现；
18. fatal 路径上携带 release token 的 Host-owned result **恰好释放一次**。

**abort 矩阵**
19. active 重复 abort 幂等 OK（新增）；
20. 既有 zero/stale/too-late/poisoned 矩阵回归。

**host_identity_ctx 接线（声明=接线=测试，L2）**
21. 无 Host tool + `host_identity_ctx == null` → Session 创建成功；
22. 选 Host tool + null → 创建阶段 `INVALID_ARGUMENT`，**不留 live-session/registry
    条目**（回滚验证）；
23. 选 Host tool + 有效 ctx → 回调真实执行，`run->session` 指向对应 facade Session，
    与双 Session identity 测试（测试 5）结合验证不串线——防止实现者声明了字段却
    继续借用 event sink ctx；
24. fatal slot 清理：并发批中一个 Host tool fatal，其余已完成 slot 的 owned payload
    无泄漏（testing.allocator 泄漏检测）、transient 落盘无孤儿；
25. Host tool 并发判定走 metadata 路径（`.host_sync` 显式可并发），非名字巧合。

**Facade call gate 与原子绑定（epilogue 竞态，必须用真并发测，不许在首调用
返回后做无意义的顺序测试）**
37. 测试钩子把 barrier 插在 **completion point 之前**，第二线程**主动**发起
    session_run → `BUSY`（只证明 completion point 前的重叠调用被拒；"物理返回前"
    的性质不存在，不假装测它）；
38. 同 barrier 下 session_destroy → `BUSY`，无 UAF（testing.allocator + 状态断言）；
39. 同 barrier 下 session_abort 正常进入（gate 不拦 abort 的回归）；
40. Host registry 原子首次绑定：两个**相同** session_id 的并发首次工具回调都成功；
    两个**不同** ID 并发时恰好一个绑定、另一个 fatal（压测重复跑）。

**UI adapter 与所有权失败路径**
26. idle/poisoned 状态调用 UI adapter 不触发 Host callback；
27. snapshot 后、调用 Host 前 mutex 已释放（UI callback 内 `session_abort` 不死锁，
    与既有回调重入测试合并断言）；
28. Web/TUI 的通用 `UiRequester` 签名与行为零变化（编译级 + 现有套件回归）；
29. **复制 OOM 腿**（failing allocator 注入）：合法 detail + dupe OOM → Host
    descriptor 恰好 release 一次、无半初始化 outcome、Run 按 OOM 合同毒化、
    无模型可见截断 detail；
30. `ToolDispatchOutcome.deinit(allocator)` 双侧：direct consumer（非 arena）逐项
    释放无泄漏；tool_exec arena 路径退化正确；释放后置空态，重复 deinit 在
    Debug 下必炸；
30a. **最坏膨胀编码**：大量 `\u0000`/引号/反斜线（6 倍级膨胀）+ 近 raw 上限详情 →
    capped writer 无数十 MiB 临时分配、编码超限走"释放 + 通用文案 + 仍为
    FAILED/REJECTED"路径；
30b. **UI 串线注入**：双 Session 下向 A 的 adapter 注入 B 的 SessionId → 无 Host
    callback、A 的 Run 中止、A 毒化（B 不受影响）。

**Discovery/工具链**
31. `abi_revision` 字段==header 宏；
32. consumer 拒绝路径**拆两条独立测试**（104B 旧表会先死在 struct_size 上，
    只测旧表则 revision 校验忘接线也照样绿）：
    a) 104-byte legacy pre-revision 表 → size-first 确定性拒绝；
    b) **112-byte、version 正确、revision 错误**的表 → 证明 revision 精确校验真的接线；
33. source-free 三语言 consumer 新签名下编译+真实运行；
34. run_id 单调矩阵回归保持绿；
35. 旧宏 `MC_CALLBACK_CONTINUE/FATAL` 已从 header 与 Zig 镜像移除（编译级验证：
    consumer 引用旧名必须编译失败）；
36. Runtime registry 生命周期：创建失败回滚、destroy 注销、Runtime destroy 时为空。

### 7.1 实施证据映射

下表记录每项合同的主要自动化证据。`组合`表示该合同跨两个层级断言，不伪造一个
并不存在的“万能测试”；source-free 项由 `agentcore:gate` 编译或真实运行交付物。

| # | 主要自动化证据（文件：精确测试名/门禁） |
|---:|---|
| 1 | `sdk/metacodes_agentcore_types.zig`: `ABI v1 public layouts are fixed on supported 64-bit targets`；C header static asserts 由 `agentcore:gate` 编译 |
| 2 | `sdk/metacodes_agentcore.zig`: `RunContext validator bounds length before pointer slicing` |
| 3 | `tests/component/agentcore_abi_test.zig`: `L2 opaque ABI routes Host callbacks and enforces Run admission identifiers` |
| 4 | `tests/component/agent_session_host_tools_test.zig`: `L2 Host identity is admission-fixed across two Runs and distinct across two Sessions` |
| 5 | 同 4；ABI facade 侧由 3 补充句柄相等断言 |
| 6 | 组合：3 的 event/UI/Host callback 共用 `Probe.context` 字段校验；4 校验 core Host identity tuple |
| 7 | 组合：`agentcore_abi_test.zig`: `Host registry first identity binding is atomic under concurrent callbacks`（异 ID 拒绝）+ `L2 Event callback fatal aborts the Run and poisons the ABI Session`（fatal 通道） |
| 8 | `src/core/agent_session.zig`: `Runtime session registry retries an injected collision and registers the next value`；`Runtime session registry bounds repeated collisions without leaking registration or liveness` |
| 9 | 组合：`agentcore_abi_test.zig`: `L2 facade gate covers the core-idle epilogue until sessionRun returns` + `tool_exec.zig`: `concurrent host fatal joins started workers and skips the next window` |
| 10 | `agentcore_abi_test.zig`: `L2 opaque ABI routes Host callbacks and enforces Run admission identifiers`（zero/resource-limit pre-admission） |
| 11 | `agentcore_abi_test.zig`: `L2 Host UI callback may repeat abort while nested run and destroy stay busy` |
| 12 | 同 11（nested `session_run`/`session_destroy` 均断言 `BUSY`） |
| 13 | `src/core/tool_exec.zig`: `concurrent host fatal joins started workers and skips the next window`；`thread spawn fallback observes fatal before starting the next job` |
| 14 | `tests/component/agent_session_host_tools_test.zig`: `L2 Host fatal poisons the Session and maps to CallbackFailed without a tool result turn` |
| 15 | `src/agentcore/abi_v1.zig`: `Host failure detail is transferred while fatal buffers release immediately`；`Host zero-length result must use a null pointer and preserves release descriptor on rejection` |
| 16 | `src/core/tool_exec.zig`: `Host detail JSON is exact when valid and falls back when encoded payload exceeds cap`；`Host error detail bypasses result persistence and aggregate budget`；`agentcore_abi_test.zig`: `L2 invalid UTF-8 Host tool result is released and does not poison Session` |
| 17 | `agentcore_abi_test.zig`: `L2 unavailable Host UI is a reusable business outcome`；`L2 Host UI fatal aborts the Run and poisons the ABI Session`；`L2 unknown Host UI status poisons the ABI Session` |
| 18 | `src/agentcore/abi_v1.zig`: `Host failure detail is transferred while fatal buffers release immediately`；`Host UI descriptor ownership is independent of callback status` |
| 19 | `agentcore_abi_test.zig`: `L2 Host UI callback may repeat abort while nested run and destroy stay busy`；`agent_session.zig`: `AgentSession abort is run-scoped, idempotent and reports late requests` |
| 20 | `agentcore_abi_test.zig`: `L2 opaque ABI routes Host callbacks and enforces Run admission identifiers`；`L2 Event callback may cooperatively abort without poisoning the ABI Session` |
| 21 | `src/core/agent_session.zig`: `AgentSession initializes per-session permission state`（无 Host tool/null anchor 正常创建） |
| 22 | `src/core/agent_session.zig`: `选择 Host tool 而无 host_identity_ctx → 创建拒绝且 registry 无残留` |
| 23 | `tests/component/agent_session_host_tools_test.zig`: `L2 selected Host sync tool is advertised, executed and released exactly once`；ABI facade 句柄断言见 3 |
| 24 | `src/core/tool_exec.zig`: `矩阵24:host fatal 后无泄漏——已完成 slot 的 owned payload 由 Slot.deinit 全部回收`；`fatal batch does not persist a completed transient result` |
| 25 | `src/core/tool_exec.zig`: `矩阵25:Host 工具并发判定走 executor metadata,不按名字猜` |
| 26 | `src/core/agent_session.zig`: `run-aware Host UI adapter snapshots identity and allows callback abort`；`run-aware Host UI adapter rejects cross-Session identity and poisons only the target` |
| 27 | `src/core/agent_session.zig`: `run-aware Host UI adapter snapshots identity and allows callback abort` |
| 28 | 编译/回归门禁：`zig build test:lib` 与既有 TUI/Web UiRequester 测试套件 |
| 29 | 组合：`src/core/tool_catalog.zig`: `Host descriptors release exactly once when dispatch copy runs out of memory` + `agent_session.zig`: `unexpected pre-run allocation failure poisons the Session` |
| 30 | `src/core/tool_catalog.zig`: `Host outcome detail is copied, released once and typed through dispatch`；`tool_exec.zig`: `Slot.takeContent 转移即置空,与 deinit 无双释放` |
| 30a | `src/core/tool_error.zig`: `capped serializer preserves external detail and rejects escaping expansion before allocation`；`tool_exec.zig`: `Host detail JSON is exact when valid and falls back when encoded payload exceeds cap` |
| 30b | `src/core/agent_session.zig`: `run-aware Host UI adapter rejects cross-Session identity and poisons only the target` |
| 31 | `src/agentcore/abi_v1.zig`: `ABI discovery is versioned`；`tests/component/agentcore_abi_test.zig`: `L2 SDK rejects API tables that violate rigid v1 discovery` |
| 32 | `sdk/metacodes_agentcore.zig`: `SDK rejects legacy pre-revision API size from the stable prefix`；`agentcore_abi_test.zig`: `L2 SDK rejects API tables that violate rigid v1 discovery` |
| 33 | `agentcore:gate`: source-free Zig/C/C++ link；native Zig/C consumer 真实运行 |
| 34 | `src/core/agent_session.zig`: `AgentSession enforces one active Run and monotonic nonzero run ids`；ABI facade 回归见 3 |
| 35 | `tests/agentcore_artifact_consumer/consumer.c` 旧宏 compile guard；`agentcore:gate` |
| 36 | `src/core/agent_session.zig`: `Runtime session registry:原子注册、destroy 注销、Runtime destroy 时为空`；`Session creation failure after ID registration rolls the registry and live count back` |
| 37 | `tests/component/agentcore_abi_test.zig`: `L2 facade gate covers the core-idle epilogue until sessionRun returns`（重叠 run） |
| 38 | 同 37（重叠 destroy） |
| 39 | 同 37（abort 绕过 facade gate） |
| 40 | `tests/component/agentcore_abi_test.zig`: `Host registry first identity binding is atomic under concurrent callbacks`（64 轮同 ID/异 ID 竞争） |

## 8. 状态（两根轴分开记，决策关闭 ≠ 技术评审通过）

**消费端决策轴——全部关闭（2026-07-18）**：
1. `abi_revision`：确认采用；
2. §1.3 两项：a) FATAL 自动升级范围支持实现方方案；b) A2 详情同意并入本批
   （serializer / 编码有界 / 无 credential 条件已入 §1.3）；
3. abort 矩阵冻结行：评审方已签字。

**技术评审轴——已通过（2026-07-18 评审方最终签字）**：最后一轮 3 项 change
request（call gate linearization 合同、编码后边界双常量与失败语义、UI incoming
SessionId 校验）折入 §3.1/§1.3/§6 与测试 37/30a/30b 后收口。签字语：
"停止设计打磨，进入实现"；重开架构讨论的唯一条件：实现中出现 UAF、所有权冲突、
ABI 布局或 wire 不可迁移问题。

**实施后整批复审——待复核（2026-07-18）**：评审方发现通用结果落盘会在
50 KiB/200 KiB 两条预算路径改写大体积 Host 错误详情，令 A2 的保真承诺在最终
post-processing 层失效。本工作树已让错误 payload 绕过两条 bulk-result 路径，补充
大错误详情与正常成功结果的对照回归，并补齐 §6 `stream_prefetch.zig` 行及 §7.1
证据映射；在评审方复核前不冒充最终 accept。

确认后实施顺序：core 管线 → facade/SDK → 文档 normative 化 → 测试矩阵 → consumer 迁移，
单批交付；提交拆分届时连同工作区现存的撤冻文档一并规划。
