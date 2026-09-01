# 历史测试报告

外部基准评测的历史归档。每轮一个目录,约定:

- `data/` — 该轮全部明细数据(逐题结果、环境与判分配置 `meta.json`),是唯一事实来源;
- `generate_report.py` — 从 `data/` 计算并生成 `report.md`,报告内容不得手改;
- `report.md` — 生成产物,重跑生成器即可复现。

数据只增不改:补测/复判作为新数据文件或新一轮目录加入,不覆盖历史。

## 索引

| 轮次 | 基准 | 被测系统 | 主结果 |
|---|---|---|---|
| [2026-08-31-frontierchallenge-glm52](2026-08-31-frontierchallenge-glm52/report.md) | FrontierChallenge open(80/97 题)+ FrontierScience-Olympiad | metacodes(main@59dd28c)+ glm-5.2,对照 claude-code 2.1.251 + glm-5.2 | metacodes Pass 55.7%/Mean 68.7 vs claude-code 64.1%/71.9(判分口径,glm-5.2 自评 judge,不可对标官方榜) |
