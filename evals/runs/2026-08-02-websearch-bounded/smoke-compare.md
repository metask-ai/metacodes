# metacodes 配对评估比较

- 实验因子: `harness`
- 有效配对: 2；排除: 0
- Trustworthy success: 100.0% → 100.0%（Δ +0.0%）
- 不一致配对: 回归 0，改善 0；McNemar exact p=1.0000
- 质量–成本–延迟前沿: `tradeoff`

| 成本指标 | Candidate - Baseline（配对均值） |
|---|---:|
| total_tokens | 28462.000 · 95% CI [-137084.474, 194008.474] |
| tool_calls | 0.500 · 95% CI [-5.853, 6.853] |
| model_tool_errors | 0.000 · 95% CI [0.000, 0.000] |
| cost_usd | 0.007 · 95% CI [-0.748, 0.762] |
| wall_time_ms | -766.500 · 95% CI [-130640.879, 129107.879] |
| model_request_time_ms | 529.000 · 95% CI [-48541.572, 49599.572] |
| tool_stage_time_ms | -1295.500 · 95% CI [-82112.013, 79521.013] |
| harness_time_ms | 0.000 · 95% CI [-12.706, 12.706] |
| tool_time_ms | 6153.000 · 95% CI [-7671.128, 19977.128] |
| tool_parallelism_factor | 0.706 · 95% CI [-8.266, 9.679] |
| network_errors | 0.000 · 95% CI [0.000, 0.000] |
| retries | 0.000 · 95% CI [0.000, 0.000] |

## 延迟归因覆盖（2/2 配对）

| Task | Pairs | Δ wall ms | Δ model ms | Δ tool-stage ms | Δ harness ms |
|---|---:|---:|---:|---:|---:|
| 60_websearch_single | 1 | 9455.0 | 4391.0 | 5065.0 | -1.0 |
| 61_websearch_batch3 | 1 | -10988.0 | -3333.0 | -7656.0 | 1.0 |

## Task / trial 长尾贡献（按 |Δ wall| 降序）

| Task | Trial | Δ wall ms | Δ model ms | Δ tool-stage ms | Δ harness ms | Δ tokens | Δ cost |
|---|---:|---:|---:|---:|---:|---:|---:|
| 61_websearch_batch3 | 0 | -10988.0 | -3333.0 | -7656.0 | 1.0 | 41491 | -0.0524 |
| 60_websearch_single | 0 | 9455.0 | 4391.0 | 5065.0 | -1.0 | 15433 | 0.0665 |
