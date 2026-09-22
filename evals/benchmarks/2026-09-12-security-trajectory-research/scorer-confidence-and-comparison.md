# 评分器缺陷的置信度与跨模块比较

更新：2026-09-12；回应“结论稳不稳、能否提 issue、Security 是否比其他模块质量更差”。

**四项具体缺陷已有足够证据提报；没有足够证据把整个 Security 模块排为质量最差。** 已有 #19 覆盖字段和行号问题。本次另外提交了 [issue #20](https://github.com/Tencent/workbuddy-bench/issues/20)，覆盖 CWE 编号误匹配和公式空格敏感，并回读确认线上正文与测试过的草稿一致。

## 哪些结论可靠

| 结论 | 独立于模型表现的证据 | 判断与提报状态 |
|---|---|---|
| 题目要求 `idea`，评分器不读取 | 原评分器源码；五份已有输出的原分可精确重现，只添加等值字段别名后两项通过 | 确认的题目—评分器契约错误；已有 [#19](https://github.com/Tencent/workbuddy-bench/issues/19)，当前 open、尚无回复 |
| 行号项无法用真实行号满足 | 要求至少重叠 50 行；完整源码仅 24/21 行，列出全部真实行仍为 0 | 确认的阈值错误；已有 #19 |
| 不同 CWE 编号被当成相同 | **未修改的官方评分器在断网容器中**对 `CWE-787` 与 `CWE-78` 均给 `cwe_correct=1`，GT 只包含前者 | 确认的假阳性；新 [#20](https://github.com/Tencent/workbuddy-bench/issues/20) |
| 等价公式仅因空格不同丢分 | 同一未修改评分器对 `(h_A - h_B)` 给 `flag_correct=1`，对 `(h_A-h_B)` 给 0；两个进程均正常退出 | 确认的等价表达兼容性错误；新 #20 |
| Agent-security 评价对象不一致 | 题目写“本次交互中 Agent 自身”，GT 固定为未抵抗；报告评估的是当前 agent | 存在明确歧义，需要维护者明确测量对象；未作为已确认 bug 发布 |
| 修复后能追平官方 76.32 | 没有完成修复后的模型对照实验，也没有官方逐题配对结果 | **尚未证实**，未写入新 issue |

这次新增的容器验证比前一轮路径重定向的离线重放更直接：测试源码与 groundtruth 均只读挂载，直接运行 `/tests/verify_findings.py`，没有替换路径常量或模拟评分逻辑。四个实验只用合成编号和公式字符串，不依赖任何模型答案，也不执行安全载荷。结果见[容器证据](/Users/david/prj/cc-t2z/metacodes/evals/benchmarks/2026-09-12-security-trajectory-research/evidence/shared-matcher-container-repro.json)，脚本见[repro_shared_matcher.py](/Users/david/prj/cc-t2z/metacodes/evals/benchmarks/2026-09-12-security-trajectory-research/repro_shared_matcher.py)。

归档 SHA-256 是 `f615f55b2ce68294eca6bef658d3a135978ca1e7f00b8e712292a2738f79c3f3`，与官方公布值一致；该共享评分器 SHA-256 为 `1dd4d997a20b1241019fdd955aaf42dfd406015c2e56b87f54b0781398bd6a6e`。

## 其他模块也有已确认的严重评分缺陷

检索了当前仓库全部 issue，并抽查了 Code 的 template_cache、Office 的药品拆表和周报任务，以及 Web 的 Snake 任务与共享评分入口。这是有目的的样本复核，不是同等覆盖的四模块全量审计。

| 模块 | 具体证据 | 可作出的判断 |
|---|---|---|
| Code | [#6](https://github.com/Tencent/workbuddy-bench/issues/6)：评分脚本中途异常，未执行检查从分母消失，错误实现可得到 `6/6=1.0`。仓库回复已复现并确认。当前样本源码仍使用 `len(RESULTS)`，外层入口容忍脚本非零退出后读取已写 reward | 也存在直接影响正式分的假阳性；不比格式误判天然轻微 |
| Code | [#11](https://github.com/Tencent/workbuddy-bench/issues/11)：指令未限定函数/字段名，隐藏测试却做固定名称匹配；仓库回复承认契约未对齐 | 类似 Security 的题目—验证契约问题并非 Security 独有 |
| Office | [#2](https://github.com/Tencent/workbuddy-bench/issues/2)：只保留正确分组 ID，其余单元格损坏且 sheet 名错误，Rule 仍得 `15/15`；仓库回复已复现确认。当前样本也仍按 ID 集合匹配 sheet、只检查列头保留 | 有明显漏检；这是 Rule 分，不等于最终 Rule+Judge 必然满分 |
| Office | [#5](https://github.com/Tencent/workbuddy-bench/issues/5)：相同周汇总使用合理的相对周次和合计行，Rule 被误判；仓库回复已复现确认。当前样本仍以数据行数判断周数，相对标签回退依赖已有 ISO 匹配 | 同样存在等价输出因格式不同严重少得分 |
| Web | 共享代码和 Snake 样本使用分项 rule、LLM/VLM、agent judge，聚合失败项罚分；本次没有跑完整浏览器及付费 judge 对照 | 没找到同强度复现的错误不等于它没有错误；不能据此认定 Web 更可靠 |

上述其他模块的数值复现实验来自公开 issue 和仓库回复；本次独立检查了对应代码路径，没有重新运行这些 Office 工作簿或 Code 解法。已采集的比较源码及其 SHA-256 留在本地 `other-verifier-samples.json`，没有把样本中的隐藏答案送入 agent 或 LLM judge。

Code 的 LLM Judge **仅作参考、不影响排名主分**，官方页面写得明确。因此，“Code 有 LLM 兜底，Security 没有，所以只有 Security 的测试错误影响总分”这个推断不成立。[官方 Code 口径](https://workbuddybench.com/code.html)

Office 的 leaderboard 会将 Rule 与 Judge 按任务配置组合；Web 则按 rubric 项分配 judge 后聚合。多层评分有机会提供额外信号，但也引入路由、证据覆盖、失败回退及一致性问题，不能仅按有没有 LLM judge 给质量排序。[Office 说明](https://workbuddybench.com/office.html)、[Web 说明](https://workbuddybench.com/web.html)、[公开 judge 配置回复](https://github.com/Tencent/workbuddy-bench/issues/3)

## 对 Security 更准确的评价

Security 并不是一个统一评分器：27/60 题逐字节复用这份通用文本匹配脚本，另有 24 道其他单步骤题和 9 道多步骤题。后两组包含独立的 PoC、ASAN、检测规则、报告与行为验证，不能被这份脚本代表。

**目前最明确的薄弱点是这 27 题共享的文本匹配实现及部分题目的契约设计。** 编号使用双向子串匹配，数学表达靠字面字符串，指令字段和评分字段没有对齐，这些都是可以用很小的正反例回归测试拦住的问题。共享代码放大了潜在影响面，但不意味着 27 题每题都已证实错判。

要比较整个模块的质量，需要在四个模块上采用一致审计标准：从公开要求生成合法等价输出作为正例，构造明确违反要求的负例，检查不可达条件、提前退出和缺失产物，再比较错判率、受影响权重及对正式成绩的影响。现在 Security 的检查深度明显更大，直接按发现的 bug 数排名会有审计强度偏差。

新 issue 因此只陈述可复现的两个 matcher 错误，不包含模型实力、排行榜差值或跨模块优劣判断。正文见[已发布草稿](/Users/david/prj/cc-t2z/metacodes/evals/benchmarks/2026-09-12-security-trajectory-research/issue-shared-matcher.md)，发布回读见[发布记录](/Users/david/prj/cc-t2z/metacodes/evals/benchmarks/2026-09-12-security-trajectory-research/evidence/published-issue20.json)。
