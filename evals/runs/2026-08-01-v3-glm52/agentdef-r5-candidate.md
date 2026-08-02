# AgentDef candidate v4 contract-v3 glm-5.2 R5

## 总览

- Rollout: 30（有效 30，invalid 0，未评分 0）
- Outcome success: 24/30 = 80.0%（Wilson 95% CI 62.7%–90.5%）
- Trustworthy success: 24/30 = 80.0%（Wilson 95% CI 62.7%–90.5%）
- 轨迹失败: 4；评估器无效: 0；已观测策略违规: 0

> Outcome success 只回答任务是否完成；Trustworthy success 还要求执行有效、轨迹合规且评估器 ready。

## 质量–成本–延迟

| 指标 | 样本 | 均值 | P50 | P95 | 总计 |
|---|---:|---:|---:|---:|---:|
| Token | 30 | 145608.9 | 141063.0 | 210629.3 | 4368268.0 |
| 成本 USD | 30 | 0.2 | 0.2 | 0.2 | 5.1 |
| 壁钟 ms | 30 | 43845.7 | 39076.0 | 87295.0 | 1315371.0 |
| 工具调用 | 30 | 3.0 | 3.0 | 5.0 | 91.0 |
| Turn | 30 | 4.8 | 5.0 | 7.0 | 144.0 |
| 重试 | 30 | 0.0 | 0.0 | 0.0 | 0.0 |

## Rollout 明细

| 任务 | Trial | 执行 | Outcome | 轨迹 | 评估器 | 可信成功 | Token | 工具调用 |
|---|---:|---|---|---|---|---|---:|---:|
| 40_agentdef_background | 0 | completed | pass | pass | ready | ✓ | 210439 | 5 |
| 40_agentdef_background | 1 | completed | fail | pass | ready | — | 200717 | 5 |
| 40_agentdef_background | 2 | completed | pass | pass | ready | ✓ | 210785 | 5 |
| 40_agentdef_background | 3 | completed | pass | pass | ready | ✓ | 175400 | 4 |
| 40_agentdef_background | 4 | completed | pass | pass | ready | ✓ | 210799 | 5 |
| 40_agentdef_background | 5 | completed | pass | pass | ready | ✓ | 183387 | 4 |
| 41_agentdef_memory | 0 | completed | pass | pass | ready | ✓ | 149002 | 3 |
| 41_agentdef_memory | 1 | completed | pass | pass | ready | ✓ | 122602 | 2 |
| 41_agentdef_memory | 2 | completed | pass | pass | ready | ✓ | 148772 | 3 |
| 41_agentdef_memory | 3 | completed | pass | pass | ready | ✓ | 122021 | 2 |
| 41_agentdef_memory | 4 | completed | pass | pass | ready | ✓ | 148912 | 3 |
| 41_agentdef_memory | 5 | completed | pass | pass | ready | ✓ | 133223 | 3 |
| 42_agentdef_isolation | 0 | completed | pass | pass | ready | ✓ | 130817 | 2 |
| 42_agentdef_isolation | 1 | completed | pass | pass | ready | ✓ | 164951 | 3 |
| 42_agentdef_isolation | 2 | completed | pass | pass | ready | ✓ | 149695 | 3 |
| 42_agentdef_isolation | 3 | completed | pass | pass | ready | ✓ | 148929 | 3 |
| 42_agentdef_isolation | 4 | completed | pass | pass | ready | ✓ | 148837 | 3 |
| 42_agentdef_isolation | 5 | completed | fail | pass | ready | — | 149575 | 4 |
| 43_agentdef_effort | 0 | completed | pass | pass | ready | ✓ | 121349 | 3 |
| 43_agentdef_effort | 1 | completed | pass | pass | ready | ✓ | 132700 | 4 |
| 43_agentdef_effort | 2 | completed | pass | pass | ready | ✓ | 102159 | 2 |
| 43_agentdef_effort | 3 | completed | pass | pass | ready | ✓ | 102058 | 2 |
| 43_agentdef_effort | 4 | completed | pass | pass | ready | ✓ | 102054 | 2 |
| 43_agentdef_effort | 5 | completed | pass | pass | ready | ✓ | 132601 | 4 |
| 44_agentdef_mcp | 0 | completed | pass | pass | ready | ✓ | 178790 | 4 |
| 44_agentdef_mcp | 1 | completed | pass | pass | ready | ✓ | 133354 | 2 |
| 44_agentdef_mcp | 2 | completed | fail | fail | ready | — | 106738 | 1 |
| 44_agentdef_mcp | 3 | completed | fail | fail | ready | — | 116469 | 2 |
| 44_agentdef_mcp | 4 | completed | fail | fail | ready | — | 132504 | 2 |
| 44_agentdef_mcp | 5 | completed | fail | fail | ready | — | 98629 | 1 |

## ETCLOVG 覆盖

C=3, E=4, G=2, L=5, O=5, T=5, V=5

## 故障归因

| 来源 | 代码 | 次数 |
|---|---|---:|
| unattributed | outcome_check_failed | 10 |
