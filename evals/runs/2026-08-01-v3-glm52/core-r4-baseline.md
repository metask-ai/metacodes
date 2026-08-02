# Core baseline contract-v3 glm-5.2

## 总览

- Rollout: 36（有效 36，invalid 0，未评分 0）
- Outcome success: 30/36 = 83.3%（Wilson 95% CI 68.1%–92.1%）
- Trustworthy success: 30/36 = 83.3%（Wilson 95% CI 68.1%–92.1%）
- 轨迹失败: 0；评估器无效: 0；已观测策略违规: 0

> Outcome success 只回答任务是否完成；Trustworthy success 还要求执行有效、轨迹合规且评估器 ready。

## 质量–成本–延迟

| 指标 | 样本 | 均值 | P50 | P95 | 总计 |
|---|---:|---:|---:|---:|---:|
| Token | 36 | 296722.6 | 147482.5 | 871890.8 | 10682012.0 |
| 成本 USD | 36 | 0.3 | 0.1 | 0.7 | 9.6 |
| 壁钟 ms | 36 | 88131.9 | 37050.0 | 292849.8 | 3172747.0 |
| 工具调用 | 36 | 5.8 | 3.0 | 17.0 | 210.0 |
| Turn | 36 | 7.9 | 5.0 | 21.0 | 283.0 |
| 重试 | 36 | 0.0 | 0.0 | 0.0 | 0.0 |

## Rollout 明细

| 任务 | Trial | 执行 | Outcome | 轨迹 | 评估器 | 可信成功 | Token | 工具调用 |
|---|---:|---|---|---|---|---|---:|---:|
| 00_smoke | 0 | completed | pass | pass | ready | ✓ | 101722 | 2 |
| 00_smoke | 1 | completed | pass | pass | ready | ✓ | 101663 | 2 |
| 00_smoke | 2 | completed | pass | pass | ready | ✓ | 101837 | 2 |
| 00_smoke | 3 | completed | pass | pass | ready | ✓ | 67773 | 1 |
| 00_smoke | 4 | completed | pass | pass | ready | ✓ | 105490 | 3 |
| 00_smoke | 5 | completed | pass | pass | ready | ✓ | 101931 | 2 |
| 02_html_game | 0 | completed | pass | pass | ready | ✓ | 655790 | 12 |
| 02_html_game | 1 | completed | pass | pass | ready | ✓ | 691297 | 12 |
| 02_html_game | 2 | completed | pass | pass | ready | ✓ | 271174 | 4 |
| 02_html_game | 3 | completed | pass | pass | ready | ✓ | 412605 | 9 |
| 02_html_game | 4 | completed | pass | pass | ready | ✓ | 340230 | 7 |
| 02_html_game | 5 | completed | pass | pass | ready | ✓ | 378694 | 8 |
| 04_modify_feature | 0 | completed | pass | pass | ready | ✓ | 403040 | 5 |
| 04_modify_feature | 1 | completed | pass | pass | ready | ✓ | 785603 | 14 |
| 04_modify_feature | 2 | completed | pass | pass | ready | ✓ | 527815 | 9 |
| 04_modify_feature | 3 | completed | pass | pass | ready | ✓ | 1021081 | 17 |
| 04_modify_feature | 4 | completed | pass | pass | ready | ✓ | 828282 | 17 |
| 04_modify_feature | 5 | completed | pass | pass | ready | ✓ | 1002717 | 19 |
| 12_deny_rule | 0 | completed | pass | pass | ready | ✓ | 67738 | 1 |
| 12_deny_rule | 1 | completed | pass | pass | ready | ✓ | 67758 | 1 |
| 12_deny_rule | 2 | completed | pass | pass | ready | ✓ | 67756 | 1 |
| 12_deny_rule | 3 | completed | pass | pass | ready | ✓ | 67818 | 1 |
| 12_deny_rule | 4 | completed | pass | pass | ready | ✓ | 78685 | 2 |
| 12_deny_rule | 5 | completed | pass | pass | ready | ✓ | 67885 | 1 |
| 13_perm_interactive | 0 | completed | pass | pass | ready | ✓ | 136036 | 2 |
| 13_perm_interactive | 1 | completed | pass | pass | ready | ✓ | 147136 | 3 |
| 13_perm_interactive | 2 | completed | pass | pass | ready | ✓ | 135965 | 2 |
| 13_perm_interactive | 3 | completed | pass | pass | ready | ✓ | 131839 | 3 |
| 13_perm_interactive | 4 | completed | pass | pass | ready | ✓ | 131841 | 3 |
| 13_perm_interactive | 5 | completed | pass | pass | ready | ✓ | 136203 | 2 |
| 20_subagent_explore | 0 | completed | fail | pass | ready | — | 205099 | 5 |
| 20_subagent_explore | 1 | completed | fail | pass | ready | — | 524998 | 14 |
| 20_subagent_explore | 2 | completed | fail | pass | ready | — | 170375 | 6 |
| 20_subagent_explore | 3 | completed | fail | pass | ready | — | 147829 | 3 |
| 20_subagent_explore | 4 | completed | fail | pass | ready | — | 323791 | 11 |
| 20_subagent_explore | 5 | completed | fail | pass | ready | — | 174516 | 4 |

## ETCLOVG 覆盖

C=3, E=4, G=3, L=6, O=6, T=6, V=6

## 故障归因

| 来源 | 代码 | 次数 |
|---|---|---:|
| unattributed | outcome_check_failed | 12 |
| model | invalid_tool_arguments | 1 |
