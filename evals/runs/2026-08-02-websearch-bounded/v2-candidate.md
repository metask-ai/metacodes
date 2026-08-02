# WebSearch bounded parallel candidate

## 总览

- Rollout: 12（有效 12，invalid 0，未评分 0）
- Outcome success: 12/12 = 100.0%（Wilson 95% CI 75.7%–100.0%）
- Trustworthy success: 12/12 = 100.0%（Wilson 95% CI 75.7%–100.0%）
- 轨迹失败: 0；评估器无效: 0；已观测策略违规: 0

> Outcome success 只回答任务是否完成；Trustworthy success 还要求执行有效、轨迹合规且评估器 ready。

## 质量–成本–延迟

| 指标 | 样本 | 均值 | P50 | P95 | 总计 |
|---|---:|---:|---:|---:|---:|
| Token | 12 | 84769.0 | 80059.5 | 99205.9 | 1017228.0 |
| 成本 USD | 12 | 0.1 | 0.1 | 0.2 | 1.3 |
| 壁钟 ms | 12 | 21493.5 | 20698.5 | 30183.6 | 257922.0 |
| 工具调用 | 12 | 3.0 | 3.0 | 4.0 | 36.0 |
| Turn | 12 | 3.0 | 3.0 | 3.0 | 36.0 |
| 重试 | 12 | 0.0 | 0.0 | 0.0 | 0.0 |

## Rollout 明细

| 任务 | Trial | 执行 | Outcome | 轨迹 | 评估器 | 可信成功 | Token | 工具调用 |
|---|---:|---|---|---|---|---|---:|---:|
| 60_websearch_single | 0 | completed | pass | pass | ready | ✓ | 94744 | 2 |
| 60_websearch_single | 1 | completed | pass | pass | ready | ✓ | 78999 | 2 |
| 60_websearch_single | 2 | completed | pass | pass | ready | ✓ | 79050 | 2 |
| 60_websearch_single | 3 | completed | pass | pass | ready | ✓ | 79031 | 2 |
| 60_websearch_single | 4 | completed | pass | pass | ready | ✓ | 79008 | 2 |
| 60_websearch_single | 5 | completed | pass | pass | ready | ✓ | 79038 | 2 |
| 61_websearch_batch3 | 0 | completed | pass | pass | ready | ✓ | 103525 | 4 |
| 61_websearch_batch3 | 1 | completed | pass | pass | ready | ✓ | 80070 | 4 |
| 61_websearch_batch3 | 2 | completed | pass | pass | ready | ✓ | 95672 | 4 |
| 61_websearch_batch3 | 3 | completed | pass | pass | ready | ✓ | 80116 | 4 |
| 61_websearch_batch3 | 4 | completed | pass | pass | ready | ✓ | 87926 | 4 |
| 61_websearch_batch3 | 5 | completed | pass | pass | ready | ✓ | 80049 | 4 |

## ETCLOVG 覆盖

C=1, E=2, L=2, O=2, T=2, V=2

## 故障归因

无已归因故障。
