# AgentCore ABI v1 实验期工作台账

> 来源：2026-07-18 评审方 v1 整体审计（RunContext 之外的解冻期应修项）。
> RunContext 批次（`AGENTCORE_RUN_CONTEXT_DESIGN.md`）已作为 ABI v1 revision 2
> 实施；仓内 source-free Zig/C/C++ 消费端已通过迁移门禁，但它们仍由库作者维护，
> 不冒充下述“真实消费者门禁”。本台账继续记录复冻前尚未关闭的整体问题。
> 复冻前置条件（全部满足才形成候选）：
> ① A 组四项关闭；② B 组**逐项形成明确 disposition**，其中 **B1、B3 必须修复或给出
> 不修的正式论证**（歧义 wire format 与 schema 静默吞字段冻结后再修就是 breaking，
> "修复队列"的名字不降低其严重性）；③ 引用闭包审查；④ 真实消费者门禁。

## A 组：复冻前必须正面解决（评审方点名四项）

| # | 问题 | 事实锚点 | 处置方向 |
|---|------|----------|----------|
| A1 | 成功 Run 可能无任何可取得的最终输出（on_event 可空且事件被丢弃，RunResult 无文本/usage） | `.h` on_event optional 条款；`abi_v1.zig` emit 丢弃路径 | 三选一进消费端观测（强制 on_event / RunResult 带 final snapshot / 明文纯事件流 API）。实现方倾向：明文纯事件流 + on_event 必填（RunResult 带 owned 文本会把 POD 摘要变成带释放义务的资源，代价大） |
| A2 | Host 工具 FAILED/REJECTED 丢失错误详情，模型无法自纠 | revision 2 前的 `AbiHostTool.execute` 释放并忽略非 OK 内容 | **已关闭（revision 2）**：FAILED/REJECTED 可携带 16 MiB 内原始 UTF-8 detail；统一 serializer 在转义后按 1 MiB 完整 payload 限额，超限降级为有界通用业务错误；错误 payload 绕过通用结果落盘与 aggregate budget；原文、控制字符、近界、release、真实回调链路与大错误详情保真均有测试 |
| A3 | allow_always 隐藏持久化副作用（写 `<ws>/.claude/settings.local.json` 或 `~/.claude/settings.json`），且 core Session 创建**只建 SessionRules 不读盘**——只写不读 = 制造垃圾文件，不是 persistence | `permission/prompt.zig:63`、`settings_writer.zig`、`agent_session.zig` SessionRules 创建路径 | **推荐方案一（Host 全责）**：ABI 模式下 core 不写盘，作用域仅限当前 Session；Host 本就通过 UI 回调产出每个 permission 决定，长期持久化 = Host 自存并对后续同类 prompt 自动作答，零新增 wire token。**wire 词汇同步改名以免撒谎**：core 只记 Session 的语义下 `allow_always` 名不副实，实验期改为 `allow_once / allow_session / deny_once / deny_session`；若保留 `allow_always` 则必须写明 Host 返回它之前已承担持久化义务、持久化失败不得返回该值。测试：ABI 模式零写盘 + 新 Session 重新 prompt。若改选方案二（AgentCore 全责）则须定义完整 load/write 格式/优先级/错误语义 + round-trip L2。**无零写盘或 round-trip 测试，A3 不关闭** |
| A4 | MC_SHELL_SANDBOXED 跨平台承诺不真实（仅 macOS，非 macOS 到首次 Bash 才暴露） | `sandbox/exec.zig:69` 平台分支与运行期探测 | **双层且 Session 校验不可省**：bundle capability 只声明"编译了该实现"；`session_create(SANDBOXED)` **必须运行期探测**当前机器实际可用（macOS bundle ≠ sandbox-exec 存在），不可用即创建失败——绝不拖到首次 Bash。"target OS 猜可用性"是同一个错误换衣服 |

## B 组：解冻期修复队列（协议/硬化）

| # | 问题 | 处置方向 |
|---|------|----------|
| B1 | AskQuestion 多选用 ", " 拼接（label 含逗号即歧义） | 改为 per-question 字符串数组 `{"answers":[{"values":[...]}]}`；实验期 breaking 许可 |
| B2 | UI 缺"用户主动取消"与 UNAVAILABLE 的区分 | 与 B1 同批设计（用户决定 ≠ 基础设施不可用） |
| B3 | Host 工具 schema 非严格子集（未知顶层字段静默忽略） | 拒绝未知顶层关键字；required 引用必须存在且不重复；定义工具名长度与 provider-safe 字符集；Runtime 创建时失败，不留到 provider 请求 |
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
8. **C8（开放）**：Conversation 导出；
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

## E 组：Revision 5 后续架构观测（不自动扩入当前 revision）

以下项目来自 2026-08-01 的外部 Host 视角评审。它们是后续证据收集项，不因为消费场景
本身成为 ABI 演进依据，也不得绕过“Core 先于 ABI”或借 reserved storage 在 Revision 5
内增加语义：

1. **E1 — goal-directed compact**：用真实 Host 验证切换到更小上下文模型的完整流程。
   当前 R5 manual compact 是无 target budget 的 canonical default best-effort 操作，不承诺
   适配目标模型。只有证明 Host 必须控制稳定输入、且 Core 能定义达到/未达到目标的
   canonical 结果后，才评估新 revision；不得直接投影全部 `CompactKernel.Options`。
2. **E2 — permission decision provenance**：评估 Host 是否需要结构化回答“哪条规则或哪层
   安全边界导致该决定”。若需要，Core 先统一 imported rules、Session 临时记忆、protected
   paths、permission mode 与 Skill policy 的来源模型；不得由 AgentCore adapter 返回脆弱的
   三数组索引或可解析英文文本。
3. **E3 — compact degraded reason**：当前 Core 在 ABI 投影前已折叠具体失败原因。若真实运维
   证据要求区分原因，先定义稳定的小型 Core taxonomy，再通过新 revision 显式投影；不得
   复用 R5 reserved 字段规避 revision cut。
4. **E4 — stability horizon**：外部消费方出现后，连续 hard cut 的协调成本会改变。达到何种
   外部消费数量、支持期限、consumer matrix 与弃用周期时进入兼容窗口，留待真实交付数据
   决定；当前不预设 revision 编号、shim 或双分派。
5. **E5 — CLI/App 与 AgentCore 并行语义路径**：Revision 6 为控制变更范围，明确不迁移
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

## F 组：SDK 生成卫生

- [ ] **Rust bindgen capability 常量位宽**：`bindgen 0.72.1` 当前把 C header 中的
  `1ULL << n` capability macros 生成为 `u32` 常量，而 wire field 是 `u64`。数值和布局
  不受影响，现有 Rust consumer 显式转换；下次重新生成 SDK 时应从 header 或 bindgen
  配置统一为 `u64`，并保持 drift gate。不得手改自动生成的 `raw.rs`。
