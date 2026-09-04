# metacodes 插件机制评估与发布状态

日期：2026-08-23。当前结论是：插件内核、数据包、静态 Host 扩展、Provider
dialect、嵌入面和零 provider 性能/安全门禁已经通过。上一代 `1.1.0` coding
quality paired evaluation 已作为本地 development cohort 完成全部 18 对、36
rollouts；candidate 与 baseline 的可信成功率相同，但因预注册的成本与延迟门禁被拒绝。
当前 `1.2.0` 增加 typed `required-first` Skill route；首个付费 attempt 在 9/36 rows 后因
provider 轨迹无效而 fail closed，随后已把激活约束提升到 AgentLoop。最终重新冻结的
18 对/36 rollout 已完整执行；candidate 与 baseline 可信成功率持平，但 candidate 因
预注册成本门禁被拒绝。
统计显著的本地 improvement **仍未建立**；
因此仍不存在“插件提升一般 coding benchmark”“达到/超过 DSH coding 成绩”或
WorkBuddy 排名结论。

## 1. 证据层级

必须区分三类证据：

1. **源码与契约证据**：能证明边界、所有权和支持矩阵；不能证明运行质量。
2. **确定性运行证据**：编译、L2、ABI、inventory 和微基准；能证明接线、隔离与
   开销门禁；不能证明模型完成 coding task 的能力。
3. **付费配对证据**：冻结同一模型、任务、grader、预算和二进制，只改变插件
   treatment；才可判断该插件在本地 development cohort 上的质量/成本/延迟影响。

公开 benchmark 或一般化优势还需要外部 WorkBuddy development cohort 和正式发布
契约。本仓库既没有从 DSH 找到公开 coding leaderboard receipt，也不会用内部三题
pilot 代替公开结果。

## 2. 与 DSH 的灵活性对标

| 维度 | DeepSeek Harness | metacodes 当前状态 | 判断 |
|---|---|---|---|
| 组合根 | Cordis Context/Profile/Bundle | `plugin.Runtime` immutable snapshot + Host-owned layers | 核心组合语义已具备 |
| 身份/依赖 | service key、plugin dependencies | strict `PluginId`、SemVer、minimum dependency、cycle/collision rejection | 已具备，失败关闭 |
| 生命周期 | Fiber effect ownership、reload/revert | typed `EffectScope` + `RuntimeHost`：依赖序 activation、逆序幂等 cleanup、失败回滚、原子代际替换、旧/新 Session pinning 与自动 drain | 完整 Runtime 的 immutable replacement 已具备；有意不做单插件原地 HMR/dylib reload |
| AgentLoop | 可由 profile 装配 | 固定 kernel owner | 有意偏离：保留因果账本、形式化与自迭代真相源 |
| Tool 扩展 | scoped registry + pipeline | builtin/Host plugin ToolCatalog + native admission/permission guard | 静态可信工具已具备；插件不能放宽 native deny |
| Service graph | stable service key、provider/consumer、Fiber ownership | static `service` capability + provider/local key + exact type + declared dependency + EffectScope | activation-time typed graph已具备；无 live mutation/kernel service injection |
| Skill/Agent | bundle/plugin | namespaced strict data package + typed `advisory`/`required-first` model activation | 已具备；provider request、真实 Skill dispatch、执行后 route release 均有 L2 |
| Provider/Hook/UI | Cordis plugin services | static advisory policy 已 descriptor-activated；Provider dialect 已进入 immutable Runtime snapshot，并接收真实工具面导出的 typed visible-capability/route；transport 与 typed UI event/request 仍为 Host seam | hook 可隐藏/按参数拒绝但不能授权；方言可按 provider/model 最长前缀覆盖模型画像、能力路由与 wire projection，不能替换认证/HTTP/SSE transport；UI 尚未插件化 |
| 进程插件 | Node package/worker/VM 组合丰富 | strict one-shot `host_tool` 已启用：hash/handshake/frame/abort/timeout/cap/reap；其余 capability fail closed | 已有安全的工具扩展纵切面；typed service graph 目前只属于静态可信进程内插件 |
| 嵌入 | CLI/SDK/server | Zig source API、C/C++/Zig/Rust AgentCore、Web SSE/HTTP、CLI inventory | metacodes 更广的 native/embed 交付面 |
| 形式化/本体 | 非核心目标 | Lean verdict、TinyKG provenance/CAS、native budget/checkpoint | metacodes 的差异化内核优势 |
| 自我迭代 | workflow/Ralph/code mode | candidate → TinyKG → paired eval → Lean/native verdict → CAS promotion | 保留为治理管线，不允许 live auto-install |

因此准确说法是：metacodes 已吸收 DSH 最重要的“组合与所有权”设计，包括真实的
静态插件 effect owner、事务回滚、typed provider/consumer service graph、Provider
dialect 和完整 Runtime 的 immutable generation replacement，同时通过固定 AgentLoop
保住 Lean/TinyKG/自我迭代内核，并已启用受控的进程工具纵切面；但尚不能宣称覆盖
DSH 的全部动态 plugin capability、全新 provider transport、UI 插件或单插件原地 HMR。

## 3. 原始目标完成矩阵

| 原始要求 | 可复验证据 | 当前结论 |
|---|---|---|
| 下载并分析 DSH | 固定提交、246 workspace build/typecheck、821 tests、源码级 Cordis/Profile/AgentLoop/Tool pipeline 分析 | 已完成 |
| 获得 DSH 式插件灵活性 | strict data/static/process forms、layer/dependency、EffectScope、typed service graph、static advisory hook、Provider dialect、`RuntimeHost` 代际替换 | 核心组合/所有权语义已完成；全新 provider transport、UI/evidence/eval process projector、around/post hook 与单插件 HMR 不在 v1 已启用面 |
| 完全保留 metacodes 内核精髓 | 插件支持矩阵不包含 AgentLoop、Permission grant、Lean verifier、TinyKG writer、budget/checkpoint；插件工具仍走 native admission | 已完成并失败关闭 |
| Lean + TinyKG 形式化/本体 | 候选只能提交 inert evidence；Lean/native verdict、TinyKG provenance/CAS 仍是 kernel-owned | 边界已保留；不是插件可替换服务 |
| 自我迭代 | candidate → TinyKG → frozen paired eval → Lean/native verdict → CAS → 新 immutable generation | 治理路径与发布机制已具备；自动自批明确禁止 |
| 嵌入各种软件/场景 | Zig source API、C/C++/Zig/Rust AgentCore v1 revision 15、CLI、Web SSE/HTTP、typed Event/UI seam | 多宿主基础已完成；Host/process/MCP Tool Result 均进入同一 CAS/spool 数据面；静态 service/`RuntimeHost` 尚未扩入 C ABI |
| coding 高 benchmark 表现 | `1.2.0` 以同模型/任务/grader/预算完整执行 18 对、36 rollouts | 两臂可信成功率均为 17/18；candidate 因平均成本增加 US$0.0648145 超过 US$0.02 门禁而拒绝，显著 improvement 未建立；外部 WorkBuddy 未运行 |

## 4. 已通过的确定性门禁

规范：`evals/plugin-v1/protocol.json`。

下列 `91e959b…` 身份、零-provider 收据和付费收据严格绑定历史实现提交
`c3399bb7cdd3e4ea7e9b1bf8a6db015ab4b63ad0`。后续 artifact/CAS 与 Host-stream
复审实现不得复用这份质量证据；它只生成独立的
`zero-provider-receipt-review-v2.json`，且不重跑付费 pair 或外部 WorkBuddy。

当前零-provider 收据名为 `zero-provider-receipt-91e959b2.json`。运行工件含开发机
路径与内部评测数据，不随开源源码分发；下面保留内容/文件哈希供私有证据库核对。

- protocol SHA-256：
  `91e959b22a813995a9b9675649098961a1dee57dff350e4266bacd328fd52050`
- implementation fingerprint：
  `de963f39fb471d4e118e3647120d7a94ed278bf1b062120134169630e2b3ea5c`
- ReleaseSmall binary SHA-256：
  `471650a06284f82e3388b7d5d8045c829d79a5a7025d086b74951e97eddcd7e0`
- receipt content SHA-256：
  `1aa1cc2c65f23656fe68230be51c8f5ac55d20a0e5500f04a2e3417cb6e33813`
- receipt file SHA-256：
  `52260fa2866b401a43899ed2b5c3611a3d59bf02d12b78eb860aa687fa011bf2`
- provider requests：0；quality evidence：false。

门禁覆盖：plugin component L2、静态 effect lifecycle/rollback L2、typed service graph
真实 Host-tool L2、advisory hook deny/native-plan non-bypass L2、`RuntimeHost`
失败保持/代际 pinning/自动 drain L2、`test:lib`
隔离、独立 Zig Host、无凭证 CLI
inventory、空 baseline 与 namespaced candidate 对照、5 次 ReleaseSafe snapshot
微基准。AgentCore v1 revision 13 native gate 还验证了 source-free C/C++/Zig/Rust consumer；
独立 Host L2 从公共 ABI 配置真实 hash-pinned 进程包，并观察到非零
executable/package/schema 权限绑定、审批 provenance、子进程执行与工具结果回流。

5 次微基准结果：

| 指标 | 中位数 | 最大值 | 冻结阈值 |
|---|---:|---:|---:|
| 单个静态插件 snapshot p95 增量 | 5,668 ns | 6,573 ns | 50,000 ns |
| inventory 序列化平均耗时 | 2,624 ns | 2,656 ns | 100,000 ns |

这是 Runtime generation 创建/清单开销，不是每 turn AgentLoop 热路径，也不是模型
质量指标。

2026-08-23 当前代际另完成：ReleaseSafe `test:lib` 1,561 项（1,552 pass / 9 skip）、
`test:integration-monolithic` 672 项（624 pass / 48 skip）、Provider dialect 的真实
request-body/cache L2、required-first 首请求/真实 canonical Skill dispatch/执行后释放 L2、
ReleaseSafe 构建、13/13 schema-to-L2 coverage audit。方言替换
测试直接比较实际 provider request bytes：等价 Runtime generation 不把插件 ID、版本、
路径、时间戳或 generation 写入请求，因此不破坏 prompt cache；真实 tool/dialect/model/
system 变化则有意形成新的 cache boundary。

## 5. 冻结的 coding paired evaluation

唯一 treatment 是一个 namespaced `skill_bundle` 数据包
`metacodes.benchmark-coding`（历史运行是 `1.0.0`/`1.1.0`；当前零-provider candidate 为
带 `model-activation: required-first` 的 `1.2.0`）。每个冻结 protocol 的两臂都使用同一个 ReleaseSmall metacodes 二进制、
同一 `anthropic/glm-5.2`、同一任务与 grader；baseline 不加载插件，candidate 只多
一个 `verify-change` Skill。

- 任务：`00_smoke`、`02_html_game`、`04_modify_feature`；
- 6 trials，交替 arm 顺序；18 对、36 rollouts；
- 每 rollout 最多 $2.00、2,000,000 metered tokens；
- 本次冻结调度最多 $72、72,000,000 metered tokens；用户跨尝试总费用上限为 $1,000；
- 一次 task/arm/trial；连接/响应头阶段最多 3 次指数退避尝试；进入流后若本轮残片未提交，
  最多作 2 次同 turn 重放，所有 provider request/retry 都计入同一预算与轨迹；
- AgentLoop、Lean native boundary、TinyKG ontology/provenance boundary、权限与预算
  都在两臂保持不变；本 pilot 不把 Lean 或 TinyKG 当 treatment，自动 promotion 关闭。

指标包括 trustworthy/outcome success、invalid、input/output/cache tokens、成本、壁钟
与 model/tool/harness 延迟拆分、tool calls、model tool errors、policy violations 和
retries。预注册门禁要求 candidate trustworthy success 至少 80%，成功率回归不超过
2pp，平均成本增加不超过 $0.02，平均延迟增加不超过 5 秒，model tool error 不增加，
policy violation 为 0。

`scripts/eval/plugin_pair_runner.py` 默认只打印 0-provider 计划。付费执行同时要求：

1. `--allow-paid-rollouts`；
2. `--frozen-manifest <manifest.json>`：先用 `--freeze` 写出的冻结清单（§7.1）；
3. 0600 私有用户授权文件（`metacodes.plugin-paid-authority/v2`），绑定精确 protocol hash、
   该清单的 `manifest_sha256` 和预算；
4. 0600 provider auth 文件；
5. 位于输出目录之外的独占、崩溃保守 budget journal；
6. `--runtime-binary <path>` 显式指定与 protocol SHA-256 pin 一致的
   ReleaseSmall artifact；不得从环境中的 `zig-out` 隐式选择。

无 `--runtime-binary` 的计划使用 `metacodes.plugin-paid-plan/v2` 的
`runtime.state = not_attested`，只报告期望 hash，不读取本机构建目录。传入 artifact 后
才变为 `attested`。零-provider release receipt 和付费结果 analysis 同样要求显式
`--runtime-binary`；静态 `--validate-only` 不需要二进制。

每个 rollout 在请求前持久化 authorization，运行时再由 metacodes 原生 evaluation
backend 强制 token/cost 双限额。任何已授权但未形成 checkpoint 的请求都会阻止自动
恢复，避免隐式重复付费。`scripts/eval/plugin_pair_analysis.py` 只接受完整 18 对、
committed budget receipt、treatment attestation，以及能整体回放、authority 绑定同一
冻结清单、每笔已授权交易都有对应 rollout 的 budget journal（§7.1）；即使门禁通过，也只输出
`development_gate_passed`。只有成功率改善且 McNemar exact `p <= 0.05` 时才记录
本地 paired improvement，公开 benchmark claim 始终为 `not_permitted`。

### 5.1 2026-08-22 历史付费执行结果

用户最初授权 US$30，早期冻结尝试按 fail-closed 暴露并修复了 inventory 投影、
原生 request reserve、tool ceiling、thinking-only assistant continuation、实现/二进制
身份绑定和连接阶段 retry policy 等问题。历史失败收据保留在私有证据库，名称为
`paid-pair-failure-receipt-33d34042.json`，其 SHA-256
为 `cd67951a54858579e1cc748f03710f3a9bd399a07faafd75783b639b1e2a4795`；旧协议已授权
请求均未被静默重放。用户随后把跨尝试费用上限提高到 US$1,000。

最终冻结运行绑定：

- protocol SHA-256：
  `df04fb0f5badd87e6499a30b4dafd07f662b9249910ebb8e87a370e50bc56764`；
- ReleaseSmall binary SHA-256：
  `fc15e0fc7e436e79252488b6d992db7379338681cfc0d341ea9838b661acbf17`；
- 18 个 baseline 与 18 个 candidate rollout 全部有效、可评分，policy violation 为 0；
- 两臂 outcome success 均为 18/18，trustworthy success 均为 17/18（94.44%）；
- discordant pair 为 1 improvement / 1 regression，McNemar exact `p = 1.0`，所以
  `local_paired_improvement = not_established`；
- candidate 相对 baseline 的配对均值为成本 -US$0.116737/rollout、壁钟
  -49.005 秒/rollout、model tool error -0.111/rollout；这些方向性结果通过预注册
  non-regression 门，但置信区间较宽，不解释为一般化效率优势；
- 最终 cohort 观测成本 US$14.134387 / 13,087,972 metered tokens；包括所有早期
  fail-closed 尝试的预算 journal 总计 US$25.927915 / 23,559,954 tokens，远低于
  US$1,000 上限。

付费质量收据 `paid-pair-receipt-df04fb0f.json` 不随源码分发；文件 SHA-256
`ac6a93ac10be5a36b25a10c1e082937ab42ece8e0791d91f0acc3fdd08717b7e`，内容 SHA-256
`6db6307a4060c4398cbe3510050d5677f87d54b902dec06789d47a3bdabceda7`。原始 rollout、
授权文件和 budget journal 保存在私有 `~/.metacodes/evals/plugin-v1-df04fb0f/`，
公开源码树只保存这里列出的 hash pin。

### 5.2 2026-08-23 当前实现重新冻结结果

Provider dialect、工具/核心能力提示词投影和 cache contract 落地后，旧收据不再被当作
当前实现证据。当前实现执行了两次完整的 18 对/36 rollout 冻结 cohort；第二次是依据
第一次失败证据做的一次且仅一次通用 Skill 描述/触发迭代，随后停止继续付费追逐样本
噪声。

第一次重新冻结（Skill `1.0.0`）：

- protocol SHA-256：
  `c5e73a99bb43411484e990af895be261c9a07e162a1172c9821257e806a44491`；
- baseline 18/18、candidate 17/18 trustworthy success，candidate 被拒绝；
- 失败门：成功率回归 5.56pp、配对成本 +US$0.041464/rollout、model tool error
  +0.055556/rollout；
- 观测成本 US$13.531737 / 13,757,059 metered tokens；
- 私有收据 `paid-pair-receipt-c5e73a99.json`，文件
  SHA-256 `9513279a6ea189d49d74a9131a5029eea7c8956e4dd1c7f98b5c2f20a2ae32a1`，
  内容 SHA-256 `bea9ec17e51974d8e3eed1e83de3a3bfce79d38131b1ce39e73a377a71a066f6`。

第二次重新冻结（Skill `1.1.0`，后被方言接线审计取代）：

- protocol SHA-256：
  `8833622a7fdff137f0e6f5705e27139d3feea545f9b5ac4f43351ab180bce0b9`；
- implementation fingerprint：
  `131a5a40cb9c8be2c714bab5e9206bafc8e7e645f20812c720315542a04e9802`；
- ReleaseSmall binary SHA-256：
  `cfc394013abd97c7e9889e48bd5e7e82e871598d9bf3698ffd655d45f88b55ca`；
- 18 个 baseline 与 18 个 candidate 全部 outcome pass、有效且无 policy violation；
  两臂 trustworthy success 均为 17/18；
- discordant pair 为 1 improvement / 1 regression，McNemar exact `p = 1.0`，所以
  `local_paired_improvement = not_established`；
- candidate 相对 baseline 的配对均值为成本 -US$0.022155/rollout、壁钟
  -14.198 秒/rollout、metered tokens -9,327/rollout、model tool error 无变化；这些
  点估计通过 non-regression 门，但不能解释为一般化效率优势；
- candidate 的工具遥测中 `Skill` 调用为 **0**。因此结果只能归因于“加载该插件未造成
  净回退”，不能归因于 `verify-change` 工作流实际改善了编码；
- 观测成本 US$14.635418 / 14,324,212 metered tokens；
- 私有收据 `paid-pair-receipt-8833622a.json`，文件
  SHA-256 `a89eb8f0103b341d1c36b9c04c4c528be66868c1721717f86cd42ea9195472a6`，
  内容 SHA-256 `fc5bc589cde8ff9c09fa3e8c14b8f72d0467c811c8ec3072897ccaba469872c9`。

随后审计发现 CLI、后台 Agent 与 Swarm 的 provider client 尚未全部绑定到 immutable
Runtime snapshot 的 dialect resolver，Anthropic serializer 也没有消费 dialect system
modifier。因此 `8833622a…` 只保留为历史结果，不能证明静态 dialect 插件 treatment。
完成 resolver 全路径接线、typed visible-capability 激活和真实 provider-request L2 后，
再次冻结的**当前实现**结果为：

- protocol SHA-256：
  `6ae5738030db59cbb5f331e3ebbec72f71a93a3b05b0209cef0d21695acd7849`；
- implementation fingerprint：
  `bfdaa9f4fb4e7f3db853454490be632ce477eec1d2052a5ded5a12101bcc0bac`；
- ReleaseSmall binary SHA-256：
  `0142b09da02952d202e760d62b4938e10921eb1a7af7cac4ffec39fb98606899`；
- 18 个 baseline 与 18 个 candidate 全部 outcome/trustworthy pass、有效且无 policy
  violation；discordant improvement/regression 均为 0，McNemar exact `p = 1.0`；
- candidate 相对 baseline 的配对均值为成本 **+US$0.023438/rollout**、壁钟
  **+16.359 秒/rollout**、metered tokens -5,451/rollout、model tool error
  -0.111/rollout；成本和延迟分别超过预注册的 +US$0.02 与 +5 秒门限，故
  `release_status = candidate_rejected`、`local_paired_improvement = not_established`；
- 两臂的 `Skill` 调用仍均为 **0**。模型特定方言指令已真实进入 provider request，
  但这个三题 cohort 没有可匹配 `verify-change` 的确定性路由证据，不能把结果归因于
  Skill 工作流；
- baseline/candidate 分别观测到 7/8 次 cache break、5,438,336/5,181,312 cache-read
  tokens。这是随机轨迹观测，不改变请求字节契约：同一 Session pin 的等价 generation
  会生成 byte-identical request；只有真实 tool/dialect/model/system 变化才建立新 cache
  boundary；
- 本 cohort 观测成本 US$13.101860 / 12,809,274 metered tokens；私有付费收据
  `paid-pair-receipt-6ae57380.json` 的文件 SHA-256
  `d1dbdb14d4bcb33e1c824b062603104d656dc625bfc9d000789d4e6c64667962`，内容
  SHA-256 `308aa9186a47c6834b5d10761720023448628860ec1c96c286291bd989382e8c`。

包含 2026-08-22 已记录的全部早期尝试、前两次 2026-08-23 cohort 和 `c316d074` 的
部分 attempt，累计观测费用为 US$71.071064 / 68,284,943 metered tokens，低于用户
US$1,000 总上限。
当前收据没有运行外部 WorkBuddy 全量 benchmark。

### 5.3 `1.2.0` typed route 冻结状态

上一 cohort 暴露“方言指导已发送但 Skill 调用仍为 0”后，当前实现没有继续堆叠全局提示词，
而是新增 host-only typed route：Skill catalog 元数据进入 revision，唯一可见
`required-first` Skill 投影为 exact `Skill(name=verify-change)`；支持指定函数的 GLM
Anthropic 方言在激活完成前发 forced choice，只有 exact 调用的成功配对结果后释放。
advisory、disabled 和多 route 冲突都不会被强制，dispatcher/permission/budget/formal
边界不变。

`c316d07428485aaff58be4492492b5e18eff584bf131ab0e03988b5416b317ca` 已获独立 0600
authority 并启动，但在 9/36 rows 后按冻结协议 fail closed：candidate
`04_modify_feature` trial 1 出现一次最终可见的 `stream_error`，轨迹虽 exit 0 且所有产物检查
通过，仍被判 `valid_for_scoring=false`。该协议每个 arm/task/trial 只允许一次 trial，故不能
删除该行或从中续跑，也没有 paired verdict。私有 failure receipt SHA-256 为
`70a7067713baf4a37f3ec8661a6c699313ddcb36e0e1224a823fcaa403d10007`；本次提交 9 rows，
精确花费 US$3.874134 / 3,834,444 metered tokens。

这次真实 provider 运行还证明：六条 candidate trajectory 的 `Skill` 调用均为 0；网关收到
typed route 与 forced `tool_choice`，但没有服从。当前修复把 `required-first` 提升为
AgentLoop 的 provider-neutral 不变量：激活前禁止其他工具、无工具结束作两次有界修复，且
只在 exact Skill 的成功配对结果后释放。激活态跨 compact boundary 通过 Host-only、非 wire
元数据携带；system/tool schema cache 前缀保持 byte-identical。新冻结身份为 protocol
`cea5553d…` / implementation `1b5cf061…` / ReleaseSafe `bd781374…`，零-provider gate 已通过；
旧 c316 authority 不会复用。

最终冻结身份是 protocol `91e959b…`、implementation `de963f…`、ReleaseSafe
`471650a…`。绑定它的独立 0600 authority 完成了全部 18 对/36 rollout：

- baseline 与 candidate 均为 17/18 trustworthy success、18/18 outcome success；
- 1 个 improvement / 1 个 regression，McNemar exact `p = 1.0`；
- invalid=0、policy violation=0、retry=0；candidate 平均延迟相对 baseline
  `-78.722 ms`，model tool error 均值无增加；
- candidate 平均成本增加 `US$0.0648145/rollout`，超过预注册
  `US$0.02` 上限，故 `release_status = candidate_rejected`；
- candidate 最后一条 `04_modify_feature` 使用 30 次工具调用、34 turns，超过冻结的
  24-turn trajectory 上限；该真实 regression 与 baseline trial 2 的 timeout improvement
  对消，不能删除或后验重跑；
- 观测总成本 `US$14.7192174`、12,461,461 metered tokens。私有质量收据
  `paid-pair-receipt-91e959b2.json` 的文件 SHA-256
  `51c64d7ccea9b4a17335c9436380c4c296521d6cfcbbb3c631d4e795f8283280`，内容 SHA-256
  `a433699cef12026653d069df835dc136e693615c12d4f76b9bf8d05ec54bca13`。

加上此前已记录的尝试，累计观测费用为 `US$85.7902814` / 80,746,404 metered
tokens，低于用户 US$1,000 总上限。尚未运行外部 WorkBuddy。

## 6. 发布结论

历史 benchmark candidate `1.2.0` 已有完整付费质量收据，内部 `release_status` 是
`candidate_rejected`；`c316d074` 仍只是历史 fail-closed 诊断证据：

- 插件内核与 Provider dialect 的确定性契约、隔离、cache-byte stability 和 embedding
  API 门禁已通过，可以继续集成；这不等于当前 benchmark candidate 可晋升；
- 可以显式启用 hash-pinned process `host_tool`；它不是不可信代码 sandbox，其他
  process capability 仍保持 fail closed；
- 不应宣称 coding benchmark 提升；本次完整 pilot 的可信成功率持平，但 candidate
  触发了预注册成本回归门；
- typed route 已用真实 L2 与完整付费 cohort 证明首轮选择、canonical Skill 执行和
  执行后释放；它证明机制可用，不证明该 Skill 候选值得晋升；
- 下一步如需一般化 coding 证据，应单独冻结并授权外部 WorkBuddy development
  cohort；本次没有运行 WorkBuddy 全量 benchmark；
- 任何候选晋升仍必须走 TinyKG provenance、Lean/native verdict 与 CAS promotion，
  不能由生成候选的 agent 自批。

## 7. 三个钉住集合,以及什么时候 repin

`evals/plugin-v1/protocol.json` 钉住三类东西,校验时机各不相同——混淆它们正是
2026-09 之前"每次提交都要 repin"的根源(main 上连续 30 次提交全都改了这个文件,
两条并行分支各自 repin 后合并树上两个值都错,auto-merge 被卡死)。

| 集合 | 字段 | 钉的是什么 | 谁校验、何时 |
|---|---|---|---|
| **实现** | `implementation_paths` + `coding_pair.implementation_fingerprint` | ~130 条源码/测试/SDK/文档路径的内容摘要,即"这次评测对着哪份实现冻结" | **只在执行、测量、判定时**:`run_gate`(开头**一次读取**协议字节:运行用的对象与 receipt 携带的哈希出自同一份字节;随后把捕获的 git HEAD 用 `git archive` 物化到私有临时目录,每一条 pin 都在那棵树里哈希、每个子进程都在那棵树里运行,活树无法触达它——这就是 #49 关掉的"改了又改回"(ABA)缺口;钉住输入在工作树里有未提交修改时开头即拒绝,因为 receipt 记的是 HEAD;写 receipt 前要求协议文件仍是这份字节、这份字节仍对物化树通过完整严格校验(子进程若改了 checkout 会被发现)、活仓库 HEAD 未变。runtime binary 与 DeepSeek Harness checkout 仍是外部输入,分别按哈希与 commit 证明)、`plugin_pair_runner.build_plan`,以及 freeze、`run_paid_pair` 起点与每次请求前后、`plugin_pair_analysis.analyze` 共用的同一次观测 `_observe`(§7.1)。它们与 `run_gate` 一样经 `validate_protocol_payload`(哈希自己校验过的那份字节),但仍观测活树(#61)。没有布尔开关,严格是**构造出来的** |
| **评测器** | `pinned_evaluator_files` | 做测量与判定的代码(gate、runner、analysis、e2e 脚本、门禁阈值)以及 Lean 形式化证据(它们由 CI 单独编译、被评测脚本消费,**不链接进运行时二进制**) | **每次加载**都校验,包括日常测试;**永远不由工具自动 repin**——一个门禁给自己的代码重钉哈希是自证漏洞(c7c2aa9) |
| **场景与候选** | `suite_sha256`、`scenario_sha256`、`candidate.root` + `candidate.files`、`*_executable_sha256` | 评测的定义:任务、场景、被测插件、两个 arm 的可执行文件。`candidate.root` 下的文件集合必须**恰好**等于 `candidate.files`,目录集合恰好等于这些文件蕴含的父目录,无符号链接、无可执行位、无特殊文件:哈希证明钉住的文件还是原样,集合相等证明它们就是全部——否则在被钉 Skill 旁边放一个文件、加一个空目录或 `chmod +x` 都不需要改协议,而运行时把目录名和可执行位哈希进 Skill 身份(`computeContentRevision`),任何 pin、指纹或清单字段都不会察觉 | 每次加载都校验 |

**日常提交不 repin。** 测试与巡检(含 `--validate-only`)用 `load_protocol_structure`:除实现指纹
相等以外全部照旧 fail-closed;`--validate-only` 打印 pinned / observed 两个值和
`implementation_pin: current|stale`,退出码 0 只表示协议格式与其余 pin 成立,**不**表示已冻结。两次冻结之间实现指纹**按设计陈旧**,这不是漂移事故,是正常状态。

**冻结时 repin。** 要发布(`run_gate` 出 receipt)或授权付费运行(创建 user authority)
之前,跑一次:

```bash
python3 scripts/eval/plugin_release_gate.py --refresh-implementation-fingerprint
```

它宽松读入、重算、只替换那一个值、再用严格加载复核结果。repin 提交就是"冻结"这个
动作在 git 里的痕迹,应当单独成 commit、写明冻结的是哪次评测。

**列表本身的变动要显式。** 摘要包含路径名,删一条路径会让旧 pin 对不上;但 repin 之后
就没有任何东西记得列表曾经更长。改 `implementation_paths` 成员必须在 commit message
里说明增删了什么、为什么——把某条路径归到错误的集合是真实发生过的错误(两个 Lean 文件
曾被当作"实现"钉住,而它们不链接进运行时二进制、属于形式化证据,2026-09 移入评测器集合;
`sdk/zig/protocol.zig` 与 `sdk/zig/build.zig` 被 `agentcore:test` 编译却一直不在列表里)。
路径集合的独立摘要与授权绑定的冻结清单见下一小节。

### 7.1 冻结清单:付费运行的预注册

付费运行之前必须先**冻结**:

```bash
python3 scripts/eval/plugin_pair_runner.py --freeze \
  --runtime-binary <ReleaseSmall 二进制> --frozen-manifest <manifest.json>
```

产出 `metacodes.plugin-frozen-run/v1`:协议字节哈希、git HEAD、**完整**实现指纹、
**路径集摘要**(`implementation_paths` 与 `pinned_evaluator_files` 的成员名集合,
与内容无关)、运行时/两个 wrapper/两个 inventory 的哈希、schedule 哈希、模型指纹、**运行环境**
(`platform` 与 `python` 版本——rollout 的 `environment_fingerprint` 记录的就是这两项——外加
解释器实现、cache tag、`sys.executable` 的 realpath 与哈希、`sys.prefix`/`exec_prefix`/
`base_prefix`,用来区分同版本的不同安装/venv),以及对以上字段的规范化哈希 `manifest_sha256`。
运行环境**不是主机身份**(两台配置、路径、哈希全同的机器在这里分不出来),也不是"钉住解释器":
解释器、它的 prefix 和加载的库同 PATH 上的二进制一样在操作者的信任边界之内;记录它的意义是
让**观测结果不同**的 OS/解释器环境——另一个 OS 构建、另一个解释器安装或 venv——成为授权之前
的一条**具名** `environment` 拒绝,而不是花完钱后整批诚实行过不了指纹。`platform.platform()` 含内核构建串,
OS 补丁也会触发它——重新冻结是一个要看着 diff 做的动作,不是可以顺手跳过的告警。文件以 0600 创建,**拒绝覆盖**。

用户 authority 升到 `metacodes.plugin-paid-authority/v2`,在 v1 字段之上**必须**携带
`manifest_sha256`:用户签的是这份清单,而不只是协议。

`run_paid_pair` 的顺序是**先校验清单、再打开 authority**:对着活树重算每一个字段
(`_observe`:协议字节只读一次,解析与哈希出自同一份字节),任何一项不等即以
`frozen-run manifest drifted: <全部不等字段>` 拒绝,此时 authority 文件根本没有被打开;
随后要求 authority 的 `manifest_sha256` 等于校验通过的清单哈希。

**每次 provider 请求前后各做一次同样的整体校验**(`_require_still_frozen`,错误尾缀
`(before request)` / `(after request)`),而不是只重载磁盘上的协议:一份冻结之后被改写又
自洽 repin 的协议(换掉候选 Skill、更新它的哈希)能通过严格加载,却通不过与清单的逐字段
比对。请求后的校验发生在导入该次证据之前;未通过则该笔交易停留在 `request_authorized`、
没有 checkpoint,续跑被既有的孤儿交易规则挡住,不会隐式重付。括号内"改了又改回"的变动
在付费路径上仍然看不见:`run_gate` 已改为在物化 checkout 里运行(#49),`run_paid_pair` 的
前后观测与 rollout 仍消费活树,见 #61。

清单哈希进入预算日志的 `BudgetAuthority`(其 `manifest_sha256` 由 `_authority_manifest`
唯一构造:协议哈希、运行时、wrapper、inventory、revision、冻结清单哈希、授权总额)和每条
rollout 记录的 `plugin_treatment`。

**证据正文封入日志。** runner 在 commit 之前先挂上 `plugin_treatment`,再对整行(除
`budget_transaction` 外的一切:outcome、trajectory、judgement、metrics、artifacts、attestation)
取规范化摘要,以 `evidence_sha256` 封入 committed 事件——它在事件哈希链之内。没有它,
日志只能证明"这笔钱花在了某个 arm/task/trial 上",证明不了付的是哪份正文:同一冻结的两次
运行 journal_id、交易 id 集合完全相同,把 B 的 receipt 移植到 A 的行上、或把一行的 outcome
与 judgement 一起翻转,都过得了 receipt 校验。续跑和 analysis 都要求每行正文的摘要等于日志
里封的那个;memory benchmark 的 runner 不封该字段,回放对它保持可选。

**预授权失败可回滚。** reserve 之后、`authorize_request` 尚未落盘就失败(信号、异常),
runner 试图 `abort_pre_request`:日志仍是 `reserved` 则中止落账、续跑不被一笔没花的预留
挡住;若授权其实已落盘(包括写已落地、异常恰好打在内存态更新之前:`abort_pre_request` 先
重读磁盘,恰好多出本笔 `request_authorized` 一个事件就认领它),日志以
`TransactionNotAbortable` 拒绝中止,交易保持 `request_authorized`——请求可能已被放行,
续跑照旧拒绝;磁盘多出的不止这一步则仍按锁内漂移拒绝。中止本身落盘失败(存储故障)是
第三种情形:预留搁浅在盘上,runner 以原始失败为 cause 报出"abort could not be recorded",
不装作已清理。

**续跑与 analysis 共用一条 receipt 绑定规则**(`_require_receipt_bound`:键集合与投影完全
相同、除 revision/head 外逐字段相等、revision/head 等于 commit 时的、交易身份等于本冻结
应当预留的),两个入口不可能接受不同的 checkpoint。

**inventory 哈希与 checkout 位置无关。** 运行时把插件根目录报告为绝对 realpath;冻结的
`inventory_sha256` 哈希的是 `metacodes.plugin-inventory-identity/v1` 投影:候选插件的
`source_root` 必须与协议声明的 `candidate.root` realpath 相等,并记录为该仓内相对名;
`generation` 是进程计数器,不进身份;id/version/form/layer/lifecycle/capabilities/
contribution_count 全部保留。同一 commit、同一运行时在另一路径的 checkout 上得到同一份清单。
inventory 预检在临时 HOME 下、`METACODES_NO_PROBE=1` 执行:`--dump-plugins` 应答前运行时
会构造完整 App,在真实 HOME 下会留下 session 目录、读 `~/.metacodes/config.json` 并拉起
其中的 MCP server、探测模型目录。

**子进程环境去注入向量。** 预检与 rollout(`paired_runner._runner_env`)共用 `hermetic_env`:
剥掉 `BASH_ENV`/`ENV`/`SHELLOPTS`/`BASHOPTS`/`CDPATH`/`GLOBIGNORE`、导出的 shell 函数
(`BASH_FUNC_*`)、`PYTHON*`、`LD_*`/`DYLD_*`、`NODE_OPTIONS`/`PERL5OPT`/`PERL5LIB`/`RUBYOPT`。
`run_e2e.sh` 是非交互 bash,`BASH_ENV` 指向的钩子能重定义它用来拼装 prompt 的 `awk`,在
不改动树上任何文件的情况下改变候选臂收到的输入。`PATH` 保留:它上面的二进制是操作者的
信任边界,固定工具路径在自托管 runner 上活不下来;唯一例外是 **`python3`**——子进程 PATH
最前面放一个 `exec` 到 runner 自身 `sys.executable` 的启动脚本(`interpreter_shim`;不用
符号链接,CPython 按被调用的路径找 `pyvenv.cfg`,符号链接会悄悄丢掉 runner 的 venv),
harness 的 helper 与 `#!/usr/bin/env python3` 的 wrapper 都用它,rollout 记录的 Python 身份
因此等于冻结与校验所用的那一个。shim 建不出来(`sys.executable` 不可用、临时目录不可写)
即 fail-closed,由于 inventory 预检在 `_observe` 里先跑,它发生在任何授权之前。rollout 侧还剥掉 `METASK_*`:宿主凭证与 runner 的匿名凭证 fd 并存时 lib.sh
判定"ambiguous E2E provider credentials"、请求根本不发,而交易已经授权,留下一笔挡住续跑的
孤儿。

`analyze` 在读取任何证据之前做同样的清单校验,然后**回放 budget journal**:日志的
authority 哈希必须等于用日志自记的总额重建的 `_authority_manifest`(即绑定同一冻结清单),
模型指纹与 provider 一致,总额不超过协议的累计上限;每一行的 `budget_transaction` 必须
命名日志里存在的交易、键集合与 receipt 投影完全相同、除 `journal_revision`/
`journal_head_sha256` 外逐字段相等且这两项等于 commit 时的 revision/head,交易身份
(run_id、harness_fingerprint 等)等于本冻结对该 arm/task/trial 应当预留的身份,正文摘要等于
日志封入的 `evidence_sha256`;日志里任何已预留/已授权/已提交而没有对应 rollout 的交易都导致
拒绝(只有 `aborted_pre_request` 例外)。authority 总额除不超累计上限外,还必须**够覆盖**
`rollouts × max_rollout_*`——runner 拒绝的 authority,analysis 同样不认。每行还要过续跑同款
的落地身份校验(`_validate_checkpoint_rows`:task/model/harness/grader 指纹必须是本 suite、
wrapper、model、revision 产出的那些),不是两臂之间互相一致就行。
receipt 的 `budget_journal_sha256`、`baseline_sha256`、`candidate_sha256` 是**被校验的那份
字节**的哈希,另携带 `frozen_manifest_sha256`、`implementation_fingerprint` 与
`path_set_digest`。这里建立的是**一致性**而非签名:日志和清单都不带签名,能证明的是证据、
日志、冻结描述的是同一次运行,不是"某个用户授权过它"——后者是 runner 的门(authority
文件),不是 analysis 的输入。

**重新冻结。** 清单文件以 `O_EXCL` 创建、拒绝覆盖;树变了要重新冻结时,换一个文件名,或先把
旧清单移走归档,再 `--freeze`;随后 authority 也要重写(它绑定的是旧清单哈希)。v1 authority
会被拒绝,错误信息直接指向这两步。

`path_set_digest` 不提供 `protocol_sha256` 之外的保护——协议字节已经绑定了两张列表——
它提供的是**名字**:删掉一条被钉路径再 repin,协议里没有任何东西记得列表曾经更长,而校验
会把 `path_set_digest` 和 `protocol_sha256` 并列报出,操作者不必 diff 两份协议才知道动的
是列表。它按成员集合计算(排序后),顺序变化对它不可见。
