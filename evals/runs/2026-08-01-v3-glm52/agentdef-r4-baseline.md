# AgentDef baseline contract-v3 glm-5.2

## 总览

- Rollout: 30（有效 29，invalid 1，未评分 0）
- Outcome success: 0/29 = 0.0%（Wilson 95% CI 0.0%–11.7%）
- Trustworthy success: 0/29 = 0.0%（Wilson 95% CI 0.0%–11.7%）
- 轨迹失败: 13；评估器无效: 0；已观测策略违规: 0

> Outcome success 只回答任务是否完成；Trustworthy success 还要求执行有效、轨迹合规且评估器 ready。

## 质量–成本–延迟

| 指标 | 样本 | 均值 | P50 | P95 | 总计 |
|---|---:|---:|---:|---:|---:|
| Token | 29 | 148198.5 | 132660.0 | 248904.0 | 4297757.0 |
| 成本 USD | 29 | 0.2 | 0.1 | 0.3 | 4.5 |
| 壁钟 ms | 29 | 85027.6 | 66843.0 | 210329.8 | 2465799.0 |
| 工具调用 | 29 | 3.2 | 2.0 | 6.6 | 92.0 |
| Turn | 29 | 4.8 | 4.0 | 8.0 | 140.0 |
| 重试 | 29 | 0.0 | 0.0 | 0.0 | 0.0 |

## Rollout 明细

| 任务 | Trial | 执行 | Outcome | 轨迹 | 评估器 | 可信成功 | Token | 工具调用 |
|---|---:|---|---|---|---|---|---:|---:|
| 40_agentdef_background | 0 | completed | fail | fail | ready | — | 114488 | 2 |
| 40_agentdef_background | 1 | completed | fail | fail | ready | — | 114073 | 2 |
| 40_agentdef_background | 2 | completed | fail | fail | ready | — | 94320 | 1 |
| 40_agentdef_background | 3 | completed | fail | fail | ready | — | 102888 | 1 |
| 40_agentdef_background | 4 | completed | fail | fail | ready | — | 114194 | 2 |
| 40_agentdef_background | 5 | completed | fail | fail | ready | — | 114328 | 2 |
| 41_agentdef_memory | 0 | completed | fail | pass | ready | — | 138759 | 2 |
| 41_agentdef_memory | 1 | completed | fail | pass | ready | — | 137431 | 2 |
| 41_agentdef_memory | 2 | completed | fail | pass | ready | — | 138096 | 2 |
| 41_agentdef_memory | 3 | completed | fail | pass | ready | — | 133417 | 3 |
| 41_agentdef_memory | 4 | completed | fail | pass | ready | — | 133199 | 3 |
| 41_agentdef_memory | 5 | completed | fail | pass | ready | — | 133629 | 3 |
| 42_agentdef_isolation | 0 | completed | fail | fail | ready | — | 173119 | 4 |
| 42_agentdef_isolation | 1 | completed | fail | pass | ready | — | 193799 | 5 |
| 42_agentdef_isolation | 2 | completed | fail | fail | ready | — | 206507 | 4 |
| 42_agentdef_isolation | 3 | completed | fail | pass | ready | — | 214553 | 7 |
| 42_agentdef_isolation | 4 | completed | fail | pass | ready | — | 271270 | 6 |
| 42_agentdef_isolation | 5 | completed | fail | pass | ready | — | 215355 | 6 |
| 43_agentdef_effort | 0 | completed | fail | pass | ready | — | 102287 | 2 |
| 43_agentdef_effort | 1 | completed | fail | pass | ready | — | 106112 | 3 |
| 43_agentdef_effort | 2 | completed | fail | pass | ready | — | 136363 | 3 |
| 43_agentdef_effort | 3 | completed | fail | pass | ready | — | 101990 | 2 |
| 43_agentdef_effort | 4 | completed | fail | pass | ready | — | 132660 | 4 |
| 43_agentdef_effort | 5 | completed | fail | pass | ready | — | 102051 | 2 |
| 44_agentdef_mcp | 0 | completed | fail | fail | ready | — | 96279 | 1 |
| 44_agentdef_mcp | 1 | completed | fail | fail | ready | — | 457017 | 15 |
| 44_agentdef_mcp | 2 | completed | fail | fail | ready | — | 109006 | 1 |
| 44_agentdef_mcp | 3 | completed | fail | fail | ready | — | 104411 | 1 |
| 44_agentdef_mcp | 4 | completed | fail | fail | ready | — | 106156 | 1 |
| 44_agentdef_mcp | 5 | invalid | fail | fail | ready | — | 356624 | 11 |

## ETCLOVG 覆盖

C=3, E=4, G=2, L=5, O=5, T=5, V=5

## 故障归因

| 来源 | 代码 | 次数 |
|---|---|---:|
| unattributed | outcome_check_failed | 61 |
