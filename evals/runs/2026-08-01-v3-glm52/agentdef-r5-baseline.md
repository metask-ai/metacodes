# AgentDef baseline contract-v3 glm-5.2 R5

## 总览

- Rollout: 30（有效 30，invalid 0，未评分 0）
- Outcome success: 0/30 = 0.0%（Wilson 95% CI 0.0%–11.4%）
- Trustworthy success: 0/30 = 0.0%（Wilson 95% CI 0.0%–11.4%）
- 轨迹失败: 17；评估器无效: 0；已观测策略违规: 0

> Outcome success 只回答任务是否完成；Trustworthy success 还要求执行有效、轨迹合规且评估器 ready。

## 质量–成本–延迟

| 指标 | 样本 | 均值 | P50 | P95 | 总计 |
|---|---:|---:|---:|---:|---:|
| Token | 30 | 165573.8 | 132655.5 | 334050.2 | 4967215.0 |
| 成本 USD | 30 | 0.2 | 0.2 | 0.3 | 5.3 |
| 壁钟 ms | 30 | 74819.5 | 67927.0 | 199424.3 | 2244585.0 |
| 工具调用 | 30 | 3.6 | 2.0 | 9.5 | 109.0 |
| Turn | 30 | 5.2 | 4.0 | 10.5 | 157.0 |
| 重试 | 30 | 0.0 | 0.0 | 0.0 | 0.0 |

## Rollout 明细

| 任务 | Trial | 执行 | Outcome | 轨迹 | 评估器 | 可信成功 | Token | 工具调用 |
|---|---:|---|---|---|---|---|---:|---:|
| 40_agentdef_background | 0 | completed | fail | fail | ready | — | 94318 | 1 |
| 40_agentdef_background | 1 | completed | fail | fail | ready | — | 106013 | 2 |
| 40_agentdef_background | 2 | completed | fail | fail | ready | — | 116024 | 2 |
| 40_agentdef_background | 3 | completed | fail | fail | ready | — | 114245 | 2 |
| 40_agentdef_background | 4 | completed | fail | fail | ready | — | 103148 | 1 |
| 40_agentdef_background | 5 | completed | fail | fail | ready | — | 103528 | 1 |
| 41_agentdef_memory | 0 | completed | fail | pass | ready | — | 133241 | 3 |
| 41_agentdef_memory | 1 | completed | fail | pass | ready | — | 148910 | 3 |
| 41_agentdef_memory | 2 | completed | fail | pass | ready | — | 138018 | 2 |
| 41_agentdef_memory | 3 | completed | fail | pass | ready | — | 137493 | 2 |
| 41_agentdef_memory | 4 | completed | fail | pass | ready | — | 149011 | 3 |
| 41_agentdef_memory | 5 | completed | fail | pass | ready | — | 148788 | 3 |
| 42_agentdef_isolation | 0 | completed | fail | fail | ready | — | 763586 | 19 |
| 42_agentdef_isolation | 1 | completed | fail | fail | ready | — | 114446 | 2 |
| 42_agentdef_isolation | 2 | completed | fail | fail | ready | — | 287753 | 10 |
| 42_agentdef_isolation | 3 | completed | fail | pass | ready | — | 343516 | 9 |
| 42_agentdef_isolation | 4 | completed | fail | fail | ready | — | 322481 | 8 |
| 42_agentdef_isolation | 5 | completed | fail | fail | ready | — | 222459 | 7 |
| 43_agentdef_effort | 0 | completed | fail | pass | ready | — | 102105 | 2 |
| 43_agentdef_effort | 1 | completed | fail | pass | ready | — | 102262 | 2 |
| 43_agentdef_effort | 2 | completed | fail | pass | ready | — | 132606 | 4 |
| 43_agentdef_effort | 3 | completed | fail | pass | ready | — | 102304 | 2 |
| 43_agentdef_effort | 4 | completed | fail | pass | ready | — | 132705 | 4 |
| 43_agentdef_effort | 5 | completed | fail | pass | ready | — | 132753 | 4 |
| 44_agentdef_mcp | 0 | completed | fail | fail | ready | — | 170975 | 4 |
| 44_agentdef_mcp | 1 | completed | fail | fail | ready | — | 104541 | 1 |
| 44_agentdef_mcp | 2 | completed | fail | fail | ready | — | 104192 | 1 |
| 44_agentdef_mcp | 3 | completed | fail | fail | ready | — | 142305 | 3 |
| 44_agentdef_mcp | 4 | completed | fail | fail | ready | — | 96258 | 1 |
| 44_agentdef_mcp | 5 | completed | fail | fail | ready | — | 97231 | 1 |

## ETCLOVG 覆盖

C=3, E=4, G=2, L=5, O=5, T=5, V=5

## 故障归因

| 来源 | 代码 | 次数 |
|---|---|---:|
| unattributed | outcome_check_failed | 63 |
