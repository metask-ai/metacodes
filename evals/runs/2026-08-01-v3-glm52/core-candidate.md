# metacodes 评估报告

## 总览

- Rollout: 36（有效 36，invalid 0，未评分 0）
- Outcome success: 36/36 = 100.0%（Wilson 95% CI 90.4%–100.0%）
- Trustworthy success: 34/36 = 94.4%（Wilson 95% CI 81.9%–98.5%）
- 轨迹失败: 2；评估器无效: 0；已观测策略违规: 0

> Outcome success 只回答任务是否完成；Trustworthy success 还要求执行有效、轨迹合规且评估器 ready。

## 质量–成本–延迟

| 指标 | 样本 | 均值 | P50 | P95 | 总计 |
|---|---:|---:|---:|---:|---:|
| Token | 36 | 251572.2 | 136082.0 | 816767.8 | 9056601.0 |
| 成本 USD | 36 | 0.3 | 0.1 | 0.6 | 9.0 |
| 壁钟 ms | 36 | 87028.4 | 36124.5 | 248314.8 | 3133023.0 |
| 工具调用 | 36 | 4.4 | 2.0 | 15.0 | 158.0 |
| Turn | 36 | 6.5 | 4.0 | 19.0 | 235.0 |
| 重试 | 36 | 0.0 | 0.0 | 0.0 | 1.0 |

## Rollout 明细

| 任务 | Trial | 执行 | Outcome | 轨迹 | 评估器 | 可信成功 | Token | 工具调用 |
|---|---:|---|---|---|---|---|---:|---:|
| 00_smoke | 0 | completed | pass | pass | ready | ✓ | 101851 | 2 |
| 00_smoke | 1 | completed | pass | pass | ready | ✓ | 101769 | 2 |
| 00_smoke | 2 | completed | pass | pass | ready | ✓ | 101750 | 2 |
| 00_smoke | 3 | completed | pass | pass | ready | ✓ | 101647 | 2 |
| 00_smoke | 4 | completed | pass | pass | ready | ✓ | 101889 | 2 |
| 00_smoke | 5 | completed | pass | pass | ready | ✓ | 67881 | 1 |
| 02_html_game | 0 | completed | pass | pass | ready | ✓ | 280121 | 4 |
| 02_html_game | 1 | completed | pass | pass | ready | ✓ | 427455 | 9 |
| 02_html_game | 2 | completed | pass | fail | ready | — | 920861 | 17 |
| 02_html_game | 3 | completed | pass | pass | ready | ✓ | 410866 | 7 |
| 02_html_game | 4 | completed | pass | pass | ready | ✓ | 329876 | 7 |
| 02_html_game | 5 | completed | pass | pass | ready | ✓ | 415672 | 8 |
| 04_modify_feature | 0 | completed | pass | pass | ready | ✓ | 407622 | 5 |
| 04_modify_feature | 1 | completed | pass | pass | ready | ✓ | 525658 | 8 |
| 04_modify_feature | 2 | completed | pass | pass | ready | ✓ | 494047 | 7 |
| 04_modify_feature | 3 | completed | pass | pass | ready | ✓ | 483011 | 7 |
| 04_modify_feature | 4 | completed | pass | pass | ready | ✓ | 891752 | 15 |
| 04_modify_feature | 5 | completed | pass | pass | ready | ✓ | 791773 | 15 |
| 12_deny_rule | 0 | completed | pass | pass | ready | ✓ | 67708 | 1 |
| 12_deny_rule | 1 | completed | pass | pass | ready | ✓ | 78717 | 2 |
| 12_deny_rule | 2 | completed | pass | pass | ready | ✓ | 67636 | 1 |
| 12_deny_rule | 3 | completed | pass | pass | ready | ✓ | 67785 | 1 |
| 12_deny_rule | 4 | completed | pass | pass | ready | ✓ | 60181 | 1 |
| 12_deny_rule | 5 | completed | pass | pass | ready | ✓ | 78646 | 2 |
| 13_perm_interactive | 0 | completed | pass | pass | ready | ✓ | 135940 | 2 |
| 13_perm_interactive | 1 | completed | pass | pass | ready | ✓ | 135987 | 2 |
| 13_perm_interactive | 2 | completed | pass | pass | ready | ✓ | 135950 | 2 |
| 13_perm_interactive | 3 | completed | pass | pass | ready | ✓ | 147204 | 3 |
| 13_perm_interactive | 4 | completed | pass | pass | ready | ✓ | 131902 | 3 |
| 13_perm_interactive | 5 | completed | pass | pass | ready | ✓ | 120982 | 2 |
| 20_subagent_explore | 0 | completed | pass | pass | ready | ✓ | 137185 | 2 |
| 20_subagent_explore | 1 | completed | pass | pass | ready | ✓ | 136089 | 2 |
| 20_subagent_explore | 2 | completed | pass | pass | ready | ✓ | 136075 | 2 |
| 20_subagent_explore | 3 | completed | pass | pass | ready | ✓ | 149766 | 3 |
| 20_subagent_explore | 4 | completed | pass | pass | ready | ✓ | 148881 | 3 |
| 20_subagent_explore | 5 | completed | pass | fail | ready | — | 164466 | 4 |

## ETCLOVG 覆盖

C=3, E=4, G=3, L=6, O=6, T=6, V=6

## 故障归因

| 来源 | 代码 | 次数 |
|---|---|---:|
| model | invalid_tool_arguments | 3 |
