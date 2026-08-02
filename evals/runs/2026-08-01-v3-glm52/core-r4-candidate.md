# Core candidate v4 contract-v3 glm-5.2

## 总览

- Rollout: 36（有效 36，invalid 0，未评分 0）
- Outcome success: 36/36 = 100.0%（Wilson 95% CI 90.4%–100.0%）
- Trustworthy success: 35/36 = 97.2%（Wilson 95% CI 85.8%–99.5%）
- 轨迹失败: 1；评估器无效: 0；已观测策略违规: 0

> Outcome success 只回答任务是否完成；Trustworthy success 还要求执行有效、轨迹合规且评估器 ready。

## 质量–成本–延迟

| 指标 | 样本 | 均值 | P50 | P95 | 总计 |
|---|---:|---:|---:|---:|---:|
| Token | 36 | 222948.9 | 136762.5 | 538122.5 | 8026162.0 |
| 成本 USD | 36 | 0.2 | 0.2 | 0.6 | 8.9 |
| 壁钟 ms | 36 | 107161.0 | 27800.0 | 360632.2 | 3857797.0 |
| 工具调用 | 36 | 3.7 | 2.0 | 8.5 | 133.0 |
| Turn | 36 | 5.8 | 4.0 | 12.5 | 210.0 |
| 重试 | 36 | 0.0 | 0.0 | 0.0 | 0.0 |

## Rollout 明细

| 任务 | Trial | 执行 | Outcome | 轨迹 | 评估器 | 可信成功 | Token | 工具调用 |
|---|---:|---|---|---|---|---|---:|---:|
| 00_smoke | 0 | completed | pass | pass | ready | ✓ | 105496 | 3 |
| 00_smoke | 1 | completed | pass | pass | ready | ✓ | 68042 | 1 |
| 00_smoke | 2 | completed | pass | pass | ready | ✓ | 68023 | 1 |
| 00_smoke | 3 | completed | pass | pass | ready | ✓ | 67949 | 1 |
| 00_smoke | 4 | completed | pass | pass | ready | ✓ | 102062 | 2 |
| 00_smoke | 5 | completed | pass | pass | ready | ✓ | 102027 | 2 |
| 02_html_game | 0 | completed | pass | pass | ready | ✓ | 366751 | 7 |
| 02_html_game | 1 | completed | pass | pass | ready | ✓ | 410737 | 8 |
| 02_html_game | 2 | completed | pass | pass | ready | ✓ | 389291 | 7 |
| 02_html_game | 3 | completed | pass | pass | ready | ✓ | 278479 | 4 |
| 02_html_game | 4 | completed | pass | pass | ready | ✓ | 346963 | 6 |
| 02_html_game | 5 | completed | pass | pass | ready | ✓ | 387587 | 7 |
| 04_modify_feature | 0 | completed | pass | pass | ready | ✓ | 553847 | 8 |
| 04_modify_feature | 1 | completed | pass | pass | ready | ✓ | 532881 | 10 |
| 04_modify_feature | 2 | completed | pass | pass | ready | ✓ | 814524 | 13 |
| 04_modify_feature | 3 | completed | pass | pass | ready | ✓ | 451489 | 5 |
| 04_modify_feature | 4 | completed | pass | pass | ready | ✓ | 418572 | 5 |
| 04_modify_feature | 5 | completed | pass | pass | ready | ✓ | 405566 | 5 |
| 12_deny_rule | 0 | completed | pass | pass | ready | ✓ | 78626 | 2 |
| 12_deny_rule | 1 | completed | pass | pass | ready | ✓ | 94049 | 2 |
| 12_deny_rule | 2 | completed | pass | pass | ready | ✓ | 67877 | 1 |
| 12_deny_rule | 3 | completed | pass | pass | ready | ✓ | 67847 | 1 |
| 12_deny_rule | 4 | completed | pass | pass | ready | ✓ | 67839 | 1 |
| 12_deny_rule | 5 | completed | pass | pass | ready | ✓ | 67852 | 1 |
| 13_perm_interactive | 0 | completed | pass | pass | ready | ✓ | 147386 | 3 |
| 13_perm_interactive | 1 | completed | pass | pass | ready | ✓ | 147299 | 3 |
| 13_perm_interactive | 2 | completed | pass | pass | ready | ✓ | 136384 | 2 |
| 13_perm_interactive | 3 | completed | pass | pass | ready | ✓ | 136317 | 2 |
| 13_perm_interactive | 4 | completed | pass | pass | ready | ✓ | 136300 | 2 |
| 13_perm_interactive | 5 | completed | pass | pass | ready | ✓ | 136359 | 2 |
| 20_subagent_explore | 0 | completed | pass | fail | ready | — | 150530 | 4 |
| 20_subagent_explore | 1 | completed | pass | pass | ready | ✓ | 174778 | 4 |
| 20_subagent_explore | 2 | completed | pass | pass | ready | ✓ | 136772 | 2 |
| 20_subagent_explore | 3 | completed | pass | pass | ready | ✓ | 136886 | 2 |
| 20_subagent_explore | 4 | completed | pass | pass | ready | ✓ | 136022 | 2 |
| 20_subagent_explore | 5 | completed | pass | pass | ready | ✓ | 136753 | 2 |

## ETCLOVG 覆盖

C=3, E=4, G=3, L=6, O=6, T=6, V=6

## 故障归因

无已归因故障。
