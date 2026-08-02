# AgentDef candidate v4 contract-v3 glm-5.2

## 总览

- Rollout: 30（有效 30，invalid 0，未评分 0）
- Outcome success: 13/30 = 43.3%（Wilson 95% CI 27.4%–60.8%）
- Trustworthy success: 13/30 = 43.3%（Wilson 95% CI 27.4%–60.8%）
- 轨迹失败: 5；评估器无效: 0；已观测策略违规: 0

> Outcome success 只回答任务是否完成；Trustworthy success 还要求执行有效、轨迹合规且评估器 ready。

## 质量–成本–延迟

| 指标 | 样本 | 均值 | P50 | P95 | 总计 |
|---|---:|---:|---:|---:|---:|
| Token | 30 | 159114.6 | 148568.5 | 242349.6 | 4773438.0 |
| 成本 USD | 30 | 0.2 | 0.2 | 0.3 | 6.0 |
| 壁钟 ms | 30 | 53734.6 | 51071.0 | 107343.5 | 1612037.0 |
| 工具调用 | 30 | 3.5 | 3.5 | 6.0 | 105.0 |
| Turn | 30 | 5.3 | 5.0 | 8.0 | 158.0 |
| 重试 | 30 | 0.0 | 0.0 | 0.0 | 0.0 |

## Rollout 明细

| 任务 | Trial | 执行 | Outcome | 轨迹 | 评估器 | 可信成功 | Token | 工具调用 |
|---|---:|---|---|---|---|---|---:|---:|
| 40_agentdef_background | 0 | completed | fail | pass | ready | — | 210262 | 5 |
| 40_agentdef_background | 1 | completed | pass | pass | ready | ✓ | 202445 | 5 |
| 40_agentdef_background | 2 | completed | pass | pass | ready | ✓ | 216602 | 5 |
| 40_agentdef_background | 3 | completed | pass | pass | ready | ✓ | 201957 | 5 |
| 40_agentdef_background | 4 | completed | pass | pass | ready | ✓ | 218244 | 5 |
| 40_agentdef_background | 5 | completed | fail | pass | ready | — | 238047 | 6 |
| 41_agentdef_memory | 0 | completed | fail | pass | ready | — | 165593 | 3 |
| 41_agentdef_memory | 1 | completed | fail | pass | ready | — | 138123 | 2 |
| 41_agentdef_memory | 2 | completed | fail | pass | ready | — | 117601 | 2 |
| 41_agentdef_memory | 3 | completed | fail | pass | ready | — | 116436 | 2 |
| 41_agentdef_memory | 4 | completed | fail | pass | ready | — | 148922 | 3 |
| 41_agentdef_memory | 5 | completed | fail | pass | ready | — | 165270 | 3 |
| 42_agentdef_isolation | 0 | completed | pass | pass | ready | ✓ | 160707 | 4 |
| 42_agentdef_isolation | 1 | completed | fail | pass | ready | — | 149313 | 3 |
| 42_agentdef_isolation | 2 | completed | fail | pass | ready | — | 176869 | 4 |
| 42_agentdef_isolation | 3 | completed | fail | pass | ready | — | 245870 | 6 |
| 42_agentdef_isolation | 4 | completed | pass | pass | ready | ✓ | 255407 | 6 |
| 42_agentdef_isolation | 5 | completed | fail | pass | ready | — | 141591 | 3 |
| 43_agentdef_effort | 0 | completed | pass | pass | ready | ✓ | 148164 | 4 |
| 43_agentdef_effort | 1 | completed | pass | pass | ready | ✓ | 102038 | 2 |
| 43_agentdef_effort | 2 | completed | pass | pass | ready | ✓ | 148215 | 4 |
| 43_agentdef_effort | 3 | completed | pass | pass | ready | ✓ | 148101 | 4 |
| 43_agentdef_effort | 4 | completed | pass | pass | ready | ✓ | 102019 | 2 |
| 43_agentdef_effort | 5 | completed | pass | pass | ready | ✓ | 114045 | 4 |
| 44_agentdef_mcp | 0 | completed | fail | fail | ready | — | 142756 | 3 |
| 44_agentdef_mcp | 1 | completed | fail | fail | ready | — | 115716 | 2 |
| 44_agentdef_mcp | 2 | completed | fail | fail | ready | — | 89930 | 1 |
| 44_agentdef_mcp | 3 | completed | fail | fail | ready | — | 116722 | 2 |
| 44_agentdef_mcp | 4 | completed | pass | pass | ready | ✓ | 178948 | 4 |
| 44_agentdef_mcp | 5 | completed | fail | fail | ready | — | 97525 | 1 |

## ETCLOVG 覆盖

C=3, E=4, G=2, L=5, O=5, T=5, V=5

## 故障归因

| 来源 | 代码 | 次数 |
|---|---|---:|
| unattributed | outcome_check_failed | 22 |
