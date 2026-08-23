# DeepSeek Harness 源码分析与 metacodes 取舍

## 1. 固定样本与验证

- 上游：`https://github.com/deepseek-ai/deepseek-harness`
- 本地副本：`/Users/david/prj/deepseek-harness`
- 固定提交：`b150a551b8d465e31e418e1b2eaf5e79bbb7d28e`
- 提交日期：2026-08-21
- package version：`0.1.1-rc.2`
- license：MIT
- 环境：Node `22.22.3`，pnpm `11.7.0`

验证结果：

- `pnpm install --frozen-lockfile` 通过；
- 246 个 workspace 的 typecheck/build 通过；
- Cordis、agent-loop、tools、SDK protocol/server/client 聚焦测试共 36 个文件、
  821 个测试通过；
- 仓库未发现公开 SWE-bench、Terminal-bench 或同类 leaderboard 成绩/receipt。

因此可以确认 DSH 的源码架构与测试质量，不能据此宣称它已有公开 coding benchmark
优势。metacodes 的最终质量结论必须来自冻结的 paired evaluation。

## 2. DSH 的核心架构

### Cordis：上下文、服务与 effect ownership

`vendor/cordis/src/context.ts`、`service.ts`、`fiber.ts` 和 `registry.ts` 构成
插件底座。插件通过稳定 service key 查找依赖，注册服务、事件监听或资源清理 effect；
Fiber 记录所有权，卸载时逆序、幂等地回收 effect。依赖尚未满足的插件等待激活，
配置更新采用校验、重启、失败回滚。

这解决的不是“动态 import”本身，而是四个更重要的问题：

1. 谁拥有一个注册项；
2. 依赖何时满足；
3. 失败时回滚哪些副作用；
4. reload 后旧实例何时安全退出。

### Profile / bundle：有序组合

`docs/architecture.md` 与 `apps/cli/composition.md` 展示了多层 profile/bundle
组合。大部分产品能力都作为插件装配，包括 model adapter、tool registry、session log
和 agent loop。Session 创建时冻结 preset；活跃 Session 不被后续配置任意改写。

### Agent loop：durable boundary 与有序工具提交

`packages/core/agent-loop/src/agent.ts` 和 `tool-calls.ts` 的关键性质是：

- turn/step/tool phase 显式；
- follow-up、steer、inject 在确定边界合并；
- request assembly 与 canonical request logging 对齐；
- 工具可受限并发，但结果按模型调用顺序提交；
- abort 会 drain 已启动任务，并为未启动调用生成配对的 skipped result；
- 只有写进 session log 的内容才可成为后续 model context。

### Tool pipeline：可扩展前置层 + native monotonic guard

`packages/core/tools/src/index.ts` 提供 pre/around/post/final pipeline、scoped
registry、restrict/guard 和 executor。最值得保留的安全结构是：插件可在前置层拒绝或
缩窄，但最终 native guard 仍会执行；插件无法把 native deny 改成 allow。

### 其他重要子系统

- Compaction 保留 append-only log 作为真相源，只替换模型表面，并避免切断 tool pair；
- Subagent descriptor、ownership、cancel/resume 与 delegated policy 可持久重建；
- Workflow、Ralph、goal driver 是 loop 之上的 orchestration plugin，不是隐藏 loop mode；
- Code mode 允许模型生成 TS/Python 调用工具 SDK，但 worker/VM 明确不被视为安全边界；
- SDK 采用 newline JSON-RPC/stdio，并有 client/server/protocol 分层；当前协议版本协商、
  cancel/session-close 仍存在缺口；
- `tool-cordis` 可在 `node:vm` 中创建临时 package，但不持久化、也不自动晋升。

## 3. TypeScript Claude 参考实现的补充价值

`cc/src/utils/plugins/` 与 `cc/src/types/plugin.ts` 更适合作为 package/marketplace
参考：严格 manifest、标准 commands/agents/skills/hooks/MCP/LSP 目录、根目录约束、
cache-only startup、managed policy、依赖 fixed-point demotion 和来源优先级。

它主要是数据包加载器，不等同于 Cordis 的通用 service runtime。metacodes 需要同时
吸收两者：TS 参考的包管理安全性，以及 DSH 的生命周期/作用域/回滚语义。

## 4. metacodes 已有优势

metacodes 并非从零开始：

- `core/agent_loop.zig` 已是 provider/UI-neutral 的固定内核；
- `core/agent_session.zig` 已有 immutable Runtime catalog 与 per-Session selection；
- `core/tool_catalog.zig` 已有 builtin/Host tool 统一的 advertise/admit/dispatch 目录；
- `plugin/process.zig` 现已提供 hash-pinned one-shot 工具进程、严格握手/帧、
  abort/timeout/output cap/reap，并通过同一 native admission 目录；
- `skills/runtime/` 已有 immutable catalog、来源、namespace、priority 与 materialization；
- Agent、MCP、hooks、UiBackend/CoreEvent/UiRequest 都已有独立边界；
- `src/agentcore/`、Zig SDK、C header、Rust SDK 和 Web backend 已提供成熟嵌入面；
- TinyKG snapshot/CAS/provenance、Lean sidecar、rule lifecycle、evaluation budget journal
  构成 DSH 没有的形式化治理与可审计自我迭代基础；
- WorkBuddy/paired runner 已能冻结数据集、模型、预算、缓存、grader 与原始 receipt。

首轮改造已补统一 PluginId/Version/Capability、strict manifest、显式发现、依赖、
generation、inventory 和静态/数据/进程工具组合根；进程包也已进入 AgentCore rev10，
可被 source-free C/C++/Zig/Rust Host 显式配置。静态可信插件现已有通用 EffectScope：
依赖序 activation、逆序幂等 cleanup、失败原子回滚，并由 Runtime/Session 所有权约束。
其 typed service graph 又补齐 provider/local key、精确类型、声明依赖访问和
activation-time injection；它不允许注册内核 service。源码级 `RuntimeHost` 进一步
实现完整候选代的事务构造、原子发布、旧 Session pinning 与自动 drain。它有意不做
单插件原地 HMR 或任意 dylib reload。静态 `advisory_hook` 已接成只能隐藏/拒绝的
同步执行上限；剩余主要缺口是 provider/UI/evidence/eval 的逐类 native projector、
输入改写/around/post hooks，以及进程插件的有状态 service runtime。

## 5. 采用与拒绝

采用：

- service definition/provider/consumer 分离；
- plugin-owned effect 与 transactional publish；
- scoped、host-owned layered composition；
- active Session 的 immutable generation；
- “model-visible iff durably logged”；
- 可扩展 advisory layer 后仍执行 native monotonic guard；
- 静态可信快路径与进程外故障隔离协议并存；process v1 不是 OS sandbox。

拒绝：

- 不把 AgentLoop、权限、Lean verdict、TinyKG writer、budget/checkpoint 变成插件；
- 不加载任意 Zig dylib；
- 不把 worker、VM 或同用户进程当成唯一安全边界；
- 不允许模型生成的候选插件自动安装/晋升；
- 不用缺乏公开 receipt 的说法替代 benchmark。

## 6. 目标形态

最终 metacodes 分为：

1. immutable kernel：单一 AgentLoop 和治理真相；
2. extension plane：静态可信插件、严格数据包、进程外插件；
3. host plane：Zig/C/Rust/stdio/Web/GUI 等宿主复用同一 CoreEvent/UiRequest/Session
   契约；
4. improvement plane：candidate → TinyKG provenance → paired eval → Lean verdict →
   CAS promotion → new generation → drain/rollback。

实现规范见 `doc/PLUGIN_ARCHITECTURE.md`；可复验门禁、DSH 对标矩阵和当前发布
结论见 `doc/PLUGIN_EVALUATION.md`。
