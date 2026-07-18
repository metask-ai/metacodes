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
| A2 | Host 工具 FAILED/REJECTED 丢失错误详情，模型无法自纠 | revision 2 前的 `AbiHostTool.execute` 释放并忽略非 OK 内容 | **已关闭（revision 2）**：FAILED/REJECTED 可携带 16 MiB 内原始 UTF-8 detail；统一 serializer 在转义后按 1 MiB 完整 payload 限额，超限降级为有界通用业务错误；原文、控制字符、近界、release 与真实回调链路均有测试 |
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
但没有提供独立产品负载反馈；以下五项仍全部开放，等待真实消费者数据：

1. RunResult 是否需要最终文本与累计 usage（联动 A1）；
2. Provider 封闭品牌枚举 vs 协议族/字符串；API key 强制非空排除了无认证本地 endpoint（SDK 通用性问题）；
3. UI 是否需要显式 cancelled（联动 B2）；
4. 内置工具 schema/错误格式/行为是否入 ABI 稳定范围，还是独立版本化；
5. prompt/event 合理硬上限（联动 B4）。

## D 组：文档卫生（随最近批次清理）

- [x] `types.zig` 顶部 frozen 残留（2026-07-18 已修，撤冻批次第五处）；
- [x] `workspace_home` 对齐实现：空值回退 canonical `workspace_root`，非空必须绝对路径；
- [x] 改为“不暴露 ABI 级异步 operation”，并明确 Bash 后台作业/BashOutput/KillShell 仍是工具级能力；
- [x] 明确 revision 2 依赖 64 位指针布局，header 对 32 位消费端编译期拒绝；
- [x] 明确禁止 C++ exception / longjmp 等非局部跳转跨越回调与 release 边界。
