# TinyKG × Lean 分层归因评估

WorkBuddy 是最终外部验收，不再承担早期控制面接线和机制归因。当前评估顺序固定为：

1. 零付费 native wiring：分别运行 memory native lifecycle、ontology→rule host chain 和 project-gate 四臂校准，证明隔离本地 TinyKG、项目 Lean kernel、observer、journal 和 receipt 真正接线；loopback scripted provider 只用于协议接线，外部网络与付费请求均为零，`quality_evidence=false`。
2. TinyKG 单因素：真实 GLM，在 Lean 关闭时比较 `no_memory` 与 `tinykg_lexical`。
3. Lean 单因素：真实 GLM，在 memory 关闭时比较 `signal_only`、`evolved_shadow` 和 `evolved_enforced`。
4. `2×2` 交互：control、memory-only、Lean-only、combined；报告两个主效应和 difference-in-differences。
5. 冻结候选后才进入 WorkBuddy，不使用 sealed 结果继续调参。

机器可读契约位于 `evals/experiments/tinykg-lean-attribution-v1.json`，由
`scripts.eval.attribution_protocol` fail-closed 校验。现有 memory 和 RuleImpact runner 继续拥有各自的
credential、预算 journal、单物理请求、隔离和 receipt 边界；本协议不复制这些实现。

## Cache 口径

Lean 开关必须对 actor 不可见，因此只改变 Lean 时完整首请求和 cacheable prefix 都必须相同。
TinyKG 开关会合法地增加记忆工具/检索上下文，不能要求完整首请求逐字节相同；应冻结所有 cell
共有的稳定 core prefix，把 TinyKG 增量上下文及 cache read/create、warm hit、compaction 单独计量。

## 当前显式缺口

- `scripts/eval/tinykg_lean_factorial.py` 尚未实现，交互实验不得冒充已经跑通。
- procedural coding fixture 只有两个 intent family，只够 wiring，不够全面质量结论。
- 当前 Lean prospective suite 只覆盖 existing-file source-CAS correction family，不能外推为所有项目规则。

这些缺口应先在 calibration/development 阶段补齐。内部 unseen confirmatory 通过并冻结候选后，才解锁
WorkBuddy roadmap。
