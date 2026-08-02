# metacodes 配对评估比较

- 实验因子: `harness`
- 有效配对: 12；排除: 0
- Trustworthy success: 91.7% → 100.0%（Δ +8.3%）
- 不一致配对: 回归 0，改善 1；McNemar exact p=1.0000
- 质量–成本–延迟前沿: `candidate_dominates`

| 成本指标 | Candidate - Baseline（配对均值） |
|---|---:|
| total_tokens | 4721.833 · 95% CI [-7848.154, 17291.821] |
| tool_calls | 0.417 · 95% CI [0.089, 0.744] |
| model_tool_errors | -0.250 · 95% CI [-0.800, 0.300] |
| cost_usd | -0.009 · 95% CI [-0.039, 0.020] |
| wall_time_ms | -4128.833 · 95% CI [-9581.758, 1324.091] |
| model_request_time_ms | -1713.833 · 95% CI [-5181.478, 1753.812] |
| tool_stage_time_ms | -2415.000 · 95% CI [-7307.202, 2477.202] |
| harness_time_ms | 0.000 · 95% CI [-0.664, 0.664] |
| tool_time_ms | 4245.333 · 95% CI [-2005.088, 10495.754] |
| tool_parallelism_factor | 0.482 · 95% CI [0.093, 0.870] |
| network_errors | 0.000 · 95% CI [0.000, 0.000] |
| retries | 0.000 · 95% CI [0.000, 0.000] |

## 延迟归因覆盖（12/12 配对）

| Task | Pairs | Δ wall ms | Δ model ms | Δ tool-stage ms | Δ harness ms |
|---|---:|---:|---:|---:|---:|
| 60_websearch_single | 6 | -2318.3 | -2049.7 | -268.5 | -0.2 |
| 61_websearch_batch3 | 6 | -5939.3 | -1378.0 | -4561.5 | 0.2 |

## Task / trial 长尾贡献（按 |Δ wall| 降序）

| Task | Trial | Δ wall ms | Δ model ms | Δ tool-stage ms | Δ harness ms | Δ tokens | Δ cost |
|---|---:|---:|---:|---:|---:|---:|---:|
| 61_websearch_batch3 | 5 | -17545.0 | -915.0 | -16631.0 | 1.0 | -93 | -0.0002 |
| 60_websearch_single | 5 | -15879.0 | -15013.0 | -866.0 | 0.0 | 10689 | -0.0005 |
| 61_websearch_batch3 | 0 | -10988.0 | -3333.0 | -7656.0 | 1.0 | 41491 | -0.0524 |
| 61_websearch_batch3 | 3 | 10471.0 | -3336.0 | 13807.0 | 0.0 | -25016 | -0.0052 |
| 60_websearch_single | 0 | 9455.0 | 4391.0 | 5065.0 | -1.0 | 15433 | 0.0665 |
| 61_websearch_batch3 | 2 | -9046.0 | -6080.0 | -2967.0 | 1.0 | 34044 | 0.0104 |
| 61_websearch_batch3 | 4 | -4815.0 | 6173.0 | -10988.0 | 0.0 | 7905 | 0.0655 |
| 61_websearch_batch3 | 1 | -3713.0 | -777.0 | -2934.0 | -2.0 | -15412 | -0.0666 |
| 60_websearch_single | 2 | -3063.0 | 99.0 | -3161.0 | -1.0 | 10792 | 0.0007 |
| 60_websearch_single | 3 | -1800.0 | 2219.0 | -4018.0 | -1.0 | 2 | 0.0001 |
| 60_websearch_single | 1 | -1595.0 | -3808.0 | 2212.0 | 1.0 | -7770 | -0.0653 |
| 60_websearch_single | 4 | -1028.0 | -186.0 | -843.0 | 1.0 | -15403 | -0.0665 |
