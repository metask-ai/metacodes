# metacodes 配对评估比较

- 实验因子: `harness`
- 有效配对: 2；排除: 0
- Trustworthy success: 0.0% → 100.0%（Δ +100.0%）
- 不一致配对: 回归 0，改善 2；McNemar exact p=0.5000
- 质量–成本–延迟前沿: `candidate_dominates`

| 成本指标 | Candidate - Baseline（配对均值） |
|---|---:|
| total_tokens | -32619.500 · 95% CI [-569378.117, 504139.117] |
| tool_calls | -2.000 · 95% CI [-27.412, 23.412] |
| model_tool_errors | 0.000 · 95% CI [0.000, 0.000] |
| cost_usd | -0.005 · 95% CI [-0.262, 0.251] |
| wall_time_ms | -5024.500 · 95% CI [-82435.805, 72386.805] |
| model_request_time_ms | -4979.500 · 95% CI [-82200.215, 72241.215] |
| tool_stage_time_ms | -40.500 · 95% CI [-262.855, 181.855] |
| harness_time_ms | -4.500 · 95% CI [-36.265, 27.265] |
| tool_time_ms | -40.500 · 95% CI [-262.855, 181.855] |
| tool_parallelism_factor | 0.000 · 95% CI [0.000, 0.000] |
| network_errors | 0.000 · 95% CI [0.000, 0.000] |
| retries | 0.000 · 95% CI [0.000, 0.000] |

## 延迟归因覆盖（2/2 配对）

| Task | Pairs | Δ wall ms | Δ model ms | Δ tool-stage ms | Δ harness ms |
|---|---:|---:|---:|---:|---:|
| 70_kg_lexical_bridge | 2 | -5024.5 | -4979.5 | -40.5 | -4.5 |

## Task / trial 长尾贡献（按 |Δ wall| 降序）

| Task | Trial | Δ wall ms | Δ model ms | Δ tool-stage ms | Δ harness ms | Δ tokens | Δ cost |
|---|---:|---:|---:|---:|---:|---:|---:|
| 70_kg_lexical_bridge | 1 | -11117.0 | -11057.0 | -58.0 | -2.0 | -74864 | -0.0256 |
| 70_kg_lexical_bridge | 0 | 1068.0 | 1098.0 | -23.0 | -7.0 | 9625 | 0.0148 |
