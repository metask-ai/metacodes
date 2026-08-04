# AgentCore ABI v1 实验期工作台账

> 来源：2026-07-18 评审方 v1 整体审计（RunContext 之外的解冻期应修项）。
> RunContext 批次（`AGENTCORE_RUN_CONTEXT_DESIGN.md`）已作为 ABI v1 revision 2
> 实施；仓内 source-free Zig/C/C++ 消费端已通过迁移门禁，但它们仍由库作者维护，
> 不冒充下述“真实消费者门禁”。本台账继续记录复冻前尚未关闭的整体问题。
> 复冻前置条件（全部满足才形成候选）：
> ① A 组四项关闭；② B 组**逐项形成明确 disposition**，其中 **B1、B3 必须修复或给出
> 不修的正式论证**（歧义 wire format 与 schema 静默吞字段冻结后再修就是 breaking，
> "修复队列"的名字不降低其严重性）；③ 引用闭包审查；④ 真实消费者门禁。
>
> **Revision 6 disposition（2026-08-04）**：A1、A3、A4、B1、B2、B3、C8、E2、
> E6、E7、E11 已由 Revision 6 canonical seam、public wire 与 conformance tests
> 关闭；E4 已形成明确的 hard-cut/单代 MCP compatibility window 处置但继续作为
> 发布治理项；E5、E8、E9、E10 继续作为显式开放债务跟踪。

## A 组：复冻前必须正面解决（评审方点名四项）

| # | 问题 | 事实锚点 | 处置方向 |
|---|------|----------|----------|
| A1 | 成功 Run 可能无任何可取得的最终输出（on_event 可空且事件被丢弃，RunResult 无文本/usage） | `.h` on_event optional 条款；`abi_v1.zig` emit 丢弃路径 | **已关闭（Revision 6，纯事件流）**：`on_event` 成为 Session create/restore 必填 callback；ABI 文档固定 closed-segment 最终文本重建算法与 usage checked-add 规则，不给 POD `RunResult` 增加 owned buffer。L2 拒绝缺失 callback，并用独立 Host reconstruction oracle 覆盖 tool boundary、stream completion 与 usage；source-free consumer 通过必填事件面取得最终文本 |
| A2 | Host 工具 FAILED/REJECTED 丢失错误详情，模型无法自纠 | revision 2 前的 `AbiHostTool.execute` 释放并忽略非 OK 内容 | **已关闭（revision 2）**：FAILED/REJECTED 可携带 16 MiB 内原始 UTF-8 detail；统一 serializer 在转义后按 1 MiB 完整 payload 限额，超限降级为有界通用业务错误；错误 payload 绕过通用结果落盘与 aggregate budget；原文、控制字符、近界、release、真实回调链路与大错误详情保真均有测试 |
| A3 | allow_always 隐藏持久化副作用（写 `<ws>/.claude/settings.local.json` 或 `~/.claude/settings.json`），且 core Session 创建**只建 SessionRules 不读盘**——只写不读 = 制造垃圾文件，不是 persistence | `permission/prompt.zig:63`、`settings_writer.zig`、`agent_session.zig` SessionRules 创建路径 | **已关闭（Revision 6，Host 全责）**：公开 response 只有 `allow_once / allow_session / deny_once / deny_session`，不存在 `allow_always`；AgentCore grant 只属于 logical Session，可经 Host checkpoint 恢复但不写产品 settings。`Revision 6 AgentCore Permission callback binds grants and preserves typed unavailable` 在真实临时 Workspace 中断言 `.claude`/`.metacodes` 均未创建，并创建同 Runtime/Workspace 的 fresh Session 断言零 grant、重新进入 ask；rules replacement/restore 另有 generation 与 authority 测试。CLI/App 的 settings writer 不在 AgentCore 调用图中，长期授权仍由 Host 自存并在后续 Session 导入明确规则 |
| A4 | MC_SHELL_SANDBOXED 跨平台承诺不真实（仅 macOS，非 macOS 到首次 Bash 才暴露） | `sandbox/exec.zig:69` 平台分支与运行期探测 | **已关闭（Revision 6，双层准入）**：bundle capability 只声明“编译了该实现”；`session_create(SANDBOXED)` 运行期探测当前机器实际可用性，不可用立即失败，绝不拖到首次 Bash。`L2 sandbox admission is eager while unrestricted skips the probe` 同时证明 sandboxed eager admission 与 unrestricted 不触发探测 |

## B 组：解冻期修复队列（协议/硬化）

| # | 问题 | 处置方向 |
|---|------|----------|
| B1 | AskQuestion 多选用 ", " 拼接（label 含逗号即歧义） | **已关闭（Revision 6）**：response 固定为 per-question 字符串数组 `{"answers":[{"values":[...]}]}`；SDK encoder/decoder 校验问题数、单选/多选 cardinality、自由文本与资源上限，逗号只作为普通 label 内容，不再参与 framing |
| B2 | UI 缺"用户主动取消"与 UNAVAILABLE 的区分 | **已关闭（Revision 6）**：Permission canonical outcome 固定为 `answered / user_cancelled / unavailable / contract_failure`，并进入 `permission_provenance`；`UI_CANCELLED` 与 `UI_UNAVAILABLE` 保持独立 ABI status。Permission callback 测试逐一断言四态及 release，AskQuestion L2 另断言 cancelled 与 unavailable 都不 poison Session |
| B3 | Host 工具 schema 非严格子集（未知顶层字段静默忽略） | **已关闭（Revision 6）**：Runtime admission 只接受 `type/properties/required` 顶层集合，拒绝未知或重复字段；`required` 必须引用现有 property 且不得重复；Tool 名固定为 1..64 bytes 的 provider-safe 交集语法。size/depth、ambiguous object contract 与 tool-name grammar 测试均在 Runtime 创建前闭合 |
| B4 | prompt 无硬上限（RESOURCE_LIMIT 防御模型不完整） | 加宽松硬上限，阈值待消费端负载数据 |

## C 组：消费端观测清单（consumer gate 收集，不拍脑袋）

仓内 source-free Zig/C/C++ 探针证明了 revision 2 的可编译、可链接与基础运行迁移，
但没有提供独立产品负载反馈。C1–C8 是开放观测项；C9 是已经取得并可供
revision 4 准入引用的真实消费者证据：

1. **C1（开放）**：RunResult 是否需要最终文本与累计 usage（联动 A1）；
2. **C2（开放）**：Provider 封闭品牌枚举 vs 协议族/字符串；API key 强制非空排除了无认证本地 endpoint（SDK 通用性问题）；
3. **C3（开放）**：UI 是否需要显式 cancelled（联动 B2）；
4. **C4（开放）**：内置工具 schema/错误格式/行为是否入 ABI 稳定范围，还是独立版本化；
5. **C5（开放）**：prompt/event 合理硬上限（联动 B4）；
6. **C6（开放）**：Runtime/Session config 的后续扩展机制；
7. **C7（开放）**：异步/流式 Run；
8. **C8（已关闭，Revision 6）**：通过 Host-owned bounded checkpoint sink/source 导出并恢复 canonical Conversation；不增加无 authority envelope 的裸 transcript 导出。长 Conversation/chunk/budget、Runtime 重建、degraded restore 与 continued Run 均有测试；
9. **C9（已验证，2026-07-27）— MetaWork pre-session Skill discovery 与 typed invocation**：
   - 消费方证据固定在 MetaWork commit
     `4e0f30dfe44fea29288f35d334f2532ecf8df071`；
   - `docs/workbench-ui-design.md` §5.1/§5.3 规定 New task 只打开 Renderer draft，
     第一次发送才创建真实 Task；选择 Workspace 也只更新 draft，不得提前创建 Task；
   - `docs/agentcore-abi-v1.md` §2/§4 记录当前 revision 3 只有 text-only 同步
     `session_run`，没有 pre-session Skill catalog 或 typed Skill invocation；
   - 因此 MetaWork 若不复制/绕过 AgentCore Skill loader，就无法在首次发送前列出
     Skill，也无法通过 source-free bundle ABI 提交稳定的 Skill identity、catalog
     revision 与 typed arguments。该阻塞构成 revision 4 S1 的消费者准入证据。

## D 组：文档卫生（随最近批次清理）

- [x] `types.zig` 顶部 frozen 残留（2026-07-18 已修，撤冻批次第五处）；
- [x] `workspace_home` 对齐实现：空值回退 canonical `workspace_root`，非空必须绝对路径；
- [x] 改为“不暴露 ABI 级异步 operation”，并明确 Bash 后台作业/BashOutput/KillShell 仍是工具级能力；
- [x] 明确 revision 2 依赖 64 位指针布局，header 对 32 位消费端编译期拒绝；
- [x] 明确禁止 C++ exception / longjmp 等非局部跳转跨越回调与 release 边界。

## E 组：Revision 5 后续架构观测与 Revision 6 disposition

以下项目来自 2026-08-01 的外部 Host 视角评审。它们是后续证据收集项，不因为消费场景
本身成为 ABI 演进依据，也不得绕过“Core 先于 ABI”或借 reserved storage 在任一已发布
revision 内增加语义：

1. **E1 — goal-directed compact**：用真实 Host 验证切换到更小上下文模型的完整流程。
   当前 R5 manual compact 是无 target budget 的 canonical default best-effort 操作，不承诺
   适配目标模型。只有证明 Host 必须控制稳定输入、且 Core 能定义达到/未达到目标的
   canonical 结果后，才评估新 revision；不得直接投影全部 `CompactKernel.Options`。
2. **E2 — permission decision provenance（已关闭，Revision 6）**：公开
   `permission_provenance` CoreEvent 使用稳定的 decision/source、matched `rule_id`、logical
   Session/Run/tool-call/request identity、Tool binding、argument digest、policy generation、
   Session-rule 标记和 typed callback outcome；不暴露三数组索引、可解析英文文本、raw
   arguments 或凭证。callback response 与 final authorization 分离：owned audit receipt 在
   Session grant 前准备，在 authoritative `policy_decision` 到达后以实际执行结果无分配提交；
   durable budget/grant 失败保留 response 事实但 final decision 为 deny，不允许 audit/public
   provenance 分叉。public Host Tool callback/provenance L2 与内部四态矩阵均已通过。
3. **E3 — compact degraded reason**：当前 Core 在 ABI 投影前已折叠具体失败原因。若真实运维
   证据要求区分原因，先定义稳定的小型 Core taxonomy，再通过新 revision 显式投影；不得
   复用 R5 reserved 字段规避 revision cut。
4. **E4 — stability horizon（Revision 6 disposition 已完成，治理项继续开放）**：AgentCore
   ABI 在 experimental 阶段对 R6 执行一次完全 hard cut，不保留旧 table、shim、alias 或双分派；
   真实 C/Zig/Rust source-free consumer matrix 与 archive gate 是当前交付基线。MCP 外部协议只
   维护 `2026-07-28` primary + `2025-11-25` 单代 compatibility window。下一稳定 MCP revision
   进入时，以新 revision 为 primary、`2026-07-28` 为唯一 compatibility candidate，并默认移除
   `2025-11-25`；退场必须走新的显式 AgentCore ABI revision、old -> new 说明、adapter conformance
   和 consumer/server matrix，不得静默滚动。何时从 experimental hard cut 转为长期 ABI
   compatibility window，仍由真实外部消费者数量、支持期限和弃用承诺决定，不预埋 shim。
5. **E5 — CLI/App 与 AgentCore 并行语义路径（Revision 6 已登记，开放债务）**：Revision 6 为控制变更范围，明确不迁移
   现有 CLI/App，因此仓内将暂时并存两条 Permission 路径和两套 MCP 协议栈：CLI/App
   保留现有 SessionRules、settings persistence 与 `2025-06-18` MCP client；AgentCore
   使用 Revision 6 的 specifier-scoped Session rules、policy generation、零写盘和双 era
   MCP Runtime。这是已接受但必须显式维护的架构债务，不得被描述成已共享 canonical
   semantics。**Owner**：AgentCore/Runtime 架构负责人；CLI/App 负责人参加联合影响评审。
   **触发条件**：任一路径发生 Permission/MCP 的安全、authority、identity 或协议语义修复；
   MCP compatibility window 滚动或 legacy adapter 退场；AgentCore 进入稳定支持候选。
   任一条件触发时必须对两条路径执行影响审计与对应回归，避免单边安全修复。长期收敛路径
   在“CLI 迁移到 AgentCore Runtime”与“共同下沉到窄 canonical seam”之间待定；本条目
   不扩大 Revision 6 范围，也不授权修改 `src/core/agent_loop.zig`。
6. **E6 — MCP freshness 与 schema capability honesty（已关闭，Revision 6）**：Runtime
   snapshot 现在携带 clocked expiry/cache scope；modern TTL 受 5 分钟 cap 约束，legacy
   使用 30 秒保守 TTL。fresh Session view 拒绝过期 server，restore 降级失效相关
   authority，已 admitted Run 的 immutable Environment 不漂移。MCP schema 明确是有节点、
   容器项和 work-unit 预算的本地 profile；schema/instance 在动态树分配前经过 O(depth) 流式
   结构准入，instance number 保留 exact lexeme 并按数学整数语义验证。`uniqueItems: true`、
   数值约束/数值 enum、引用和 header projection typed unavailable，不再以浮点近似或
   “完整 2020-12 validator”宣传掩盖本地 profile 边界。
7. **E7 — Text/Skill root-input budget symmetry（已关闭，Revision 6）**：两类输入都按
   admission 前可确定的 canonical root record 精确预留。typed Skill 预留 canonical
   invocation record，不再预留整块 `input_cap_bytes`；effectful body rendering 仍严格位于
   admitted Run 内，并在 Conversation mutation 前原子对账精确 delta。这样既保留
   materialization/shell 执行的 Run lifecycle 归属，也消除长 Session 的伪保守拒绝。
8. **E8 — Permission outcome 的模型可见投影（开放，shared seam）**：Revision 6 public
   request/provenance 已严格区分 `answered`、`user_cancelled`、`unavailable` 与
   `contract_failure`，final authorization 也全部 fail closed；但 shared
   `PermissionContext.ui_requester` 到 `agent_loop` 仍是 bool seam，non-answered 路径在普通
   Tool result 中使用同一 legacy deny 文案。该缺口不允许通过 AgentCore event 重写或字符串
   patch 掩盖。**Owner**：shared Core/Permission 架构负责人。**触发条件**：修改
   `agent_loop`、引入 typed prompt outcome，或真实消费方要求模型按 cancelled/unavailable
   采取不同恢复策略。处置必须同时覆盖 CLI/TUI/Web/child 与 AgentCore，未经独立设计批准
   不得借 Revision 6 修改 `src/core/agent_loop.zig`。
9. **E9 — budgeted Provider stream 的 bounded spool 时序（开放，行为债务）**：为保证超限
   provider tail 不把 partial response 提交进 Conversation，Revision 6 在 AgentCore facade
   内有界缓存完整 stream 后再向 shared loop 释放事件。这保持 durable-state invariant，
   但 AgentCore 消费方观察到的 chunk 时序不同于直接 provider streaming。**Owner**：
   AgentCore Runtime。**触发条件**：公开异步 Run/低延迟 streaming SLA，或引入能够回滚
   partial projection 的 transaction seam。当前不得为追求早到 chunk 放松 checkpointability。
10. **E10 — durable reservation 可用性标定（开放，参数治理）**：operation reservation 以
    实际 request bytes 加该 operation 的配置 result cap 计算，安全但 cap 过松会提前拒绝长
    Session。默认 cap/soft threshold 需要持续用真实 provider、Host Tool 与 MCP workload
    校准；任何调整必须保持 payload 超限的有界 outcome、pre-side-effect reservation 和
    source-free durable-budget 回归，不得用协议理论最大值替代运行配置。**Owner**：
    AgentCore Runtime/容量治理负责人；Provider、Host Tool 与 MCP owner 提供 workload 样本。
11. **E11 — `InvalidBudget` status 映射（已关闭，Revision 6）**：该内部错误只表示
    checkpoint limits 或 durable profile 在结构上无效，统一映射 public
    `STATUS_INVALID_ARGUMENT`，不新增同义 status token；合法配置下的运行容量不足必须使用
    `STATUS_CHECKPOINT_BUDGET_REQUIRED`，不得重新折回 `InvalidBudget`。

## F 组：SDK 生成卫生

- [ ] **Rust bindgen capability 常量位宽**：`bindgen 0.72.1` 当前把 C header 中的
  `1ULL << n` capability macros 生成为 `u32` 常量，而 wire field 是 `u64`。数值和布局
  不受影响，现有 Rust consumer 显式转换；下次重新生成 SDK 时应从 header 或 bindgen
  配置统一为 `u64`，并保持 drift gate。不得手改自动生成的 `raw.rs`。

## G 组：发布合同治理

1. **G1 — Header/参考文档镜像审查（持续规则）**：任何修改 public function table、DTO、
   enum/status/stop code、capability bit、CoreEvent tag 或资源限制的提交，必须在同一主题批次
   同步审查 `sdk/metask/agentcore.h`、跨语言 SDK、`AGENTCORE_BINARY_ABI.md` 与 artifact
   consumer。Header 是机器合同，ABI 参考文档是消费方语义合同，二者不得分批收口。若未来
   增加自动 drift gate，它只能补充人工语义审查，不能把“文本存在”冒充“语义一致”。

## H 组：Revision 6 非阻塞 conformance 债务

1. **H1 — 收口审计的 PARTIAL 测试项**：sandbox/Permission 正交性、background activity
   导出 `BUSY`、HTTP negotiation 的 401/403/5xx 分场景、跨 Session poison 隔离，以及
   checksum 不代表来源真实性。**Owner**：AgentCore conformance。相关 seam 变更时补最窄
   的故障注入测试；本条不重新打开 Revision 6 架构，也不授权扩大实现范围。
