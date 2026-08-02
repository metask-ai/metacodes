# WebSearch serial baseline

## 总览

- Rollout: 12（有效 12，invalid 0，未评分 0）
- Outcome success: 12/12 = 100.0%（Wilson 95% CI 75.7%–100.0%）
- Trustworthy success: 11/12 = 91.7%（Wilson 95% CI 64.6%–98.5%）
- 轨迹失败: 1；评估器无效: 0；已观测策略违规: 0

> Outcome success 只回答任务是否完成；Trustworthy success 还要求执行有效、轨迹合规且评估器 ready。

## 质量–成本–延迟

| 指标 | 样本 | 均值 | P50 | P95 | 总计 |
|---|---:|---:|---:|---:|---:|
| Token | 12 | 80047.2 | 79666.0 | 99824.5 | 960566.0 |
| 成本 USD | 12 | 0.1 | 0.1 | 0.2 | 1.4 |
| 壁钟 ms | 12 | 25622.3 | 24650.5 | 37660.4 | 307468.0 |
| 工具调用 | 12 | 2.6 | 2.5 | 4.0 | 31.0 |
| Turn | 12 | 2.8 | 3.0 | 3.4 | 33.0 |
| 重试 | 12 | 0.0 | 0.0 | 0.0 | 0.0 |

## Rollout 明细

| 任务 | Trial | 执行 | Outcome | 轨迹 | 评估器 | 可信成功 | Token | 工具调用 |
|---|---:|---|---|---|---|---|---:|---:|
| 60_websearch_single | 0 | completed | pass | pass | ready | ✓ | 79311 | 2 |
| 60_websearch_single | 1 | completed | pass | pass | ready | ✓ | 86769 | 2 |
| 60_websearch_single | 2 | completed | pass | pass | ready | ✓ | 68258 | 1 |
| 60_websearch_single | 3 | completed | pass | pass | ready | ✓ | 79029 | 2 |
| 60_websearch_single | 4 | completed | pass | pass | ready | ✓ | 94411 | 2 |
| 60_websearch_single | 5 | completed | pass | pass | ready | ✓ | 68349 | 1 |
| 61_websearch_batch3 | 0 | completed | pass | pass | ready | ✓ | 62034 | 3 |
| 61_websearch_batch3 | 1 | completed | pass | pass | ready | ✓ | 95482 | 4 |
| 61_websearch_batch3 | 2 | completed | pass | pass | ready | ✓ | 61628 | 3 |
| 61_websearch_batch3 | 3 | completed | pass | fail | ready | — | 105132 | 3 |
| 61_websearch_batch3 | 4 | completed | pass | pass | ready | ✓ | 80021 | 4 |
| 61_websearch_batch3 | 5 | completed | pass | pass | ready | ✓ | 80142 | 4 |

## ETCLOVG 覆盖

C=1, E=2, L=2, O=2, T=2, V=2

## 故障归因

| 来源 | 代码 | 次数 |
|---|---|---:|
| model | invalid_tool_arguments | 3 |
