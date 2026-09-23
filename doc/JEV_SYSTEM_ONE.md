# Jev System-One 记忆面顾问（Memory-plane advisor）

> 状态：已实现，**默认关闭**。设 `METACODES_JEV_URL` 后默认 `shadow`（只记录不改行为），
> `METACODES_JEV_MODE=advisory` 才让判断影响注入。实现：`src/jev/`；消费方：
> `src/kg/scoped_recall.zig`、`src/tools/kg_tools.zig`、`src/core/agent_loop.zig`。
> 评估复现：`zig build eval:jev-recall-driver`（零 provider 驱动）+ 本文 §6。

## 1. 它是什么，不是什么

Jev（`metask-jev-4b`，自建服务 `POST /v1/systemone`）是一个 **typed decision engine**：
给一段 `state` 和一组封闭问题（boolean / choice），返回每个答案的校准概率。它不生成
文本、不产出命令，也不是 coding agent 的 LLM。

Jev-Mem（arXiv 2609.23986）把这种 System-One 判断放进记忆控制：写路径做类型与关系判定
（`θ_rel = 0.60`），读路径做路由、候选打分与充分性停止（`θ_suff = 0.95`）。metacodes 采用的
是它的**读路径候选打分**与**写路径关系判定**，而且只作为证据，不作为权威。

实测服务特性（2026-09-23，自建端点）：

- 判断是确定性的：同一请求字节得到同一概率，所以请求 SHA-256 就是完整审计键。
- `criteria` 必须写：同一批 18 题，不带 `when_true/when_false` 准确 6/18，带上 17/18。
- 单次大请求（8 候选）约 0.9 s（单客户端 p99 1.06 s）；多客户端共享时线性变慢；提示上限 4096 token。
- `usage.tariff` 为 `"none"`（不计费）。

## 2. 设计原则（融合 Codex 方案后的最终取舍）

| 原则 | 落点 |
|---|---|
| 默认关闭，显式开启 | 未设 `METACODES_JEV_URL` 时 `App.jev == null`，所有消费方走原路径 |
| shadow → advisory 渐进 | `shadow`：照常请求并写 `system_one_decision` 事件，注入/工具结果字节与无顾问时**逐字节相同**；`advisory`：判断才生效 |
| 证据，永不是权威 | 判断只能改变“注入哪几条记忆”、“是否附上相关度注释”、“是否给软提醒”；从不拒绝工具、不改权限/沙箱/预算、不写 TinyKG、不参与 formal verdict |
| 宿主枚举候选 | 候选全部来自 TinyKG BM25（宿主确定性枚举），Jev 只回答关于它们的封闭问题；问题目录是 comptime 校验的常量 |
| 失败语义二分 | 服务故障（超时/5xx/畸形/模型不符/计费）→ 退回基线；**用户中断**→ `error.Aborted` 原样上抛，不被“降级”吞掉 |
| 最小脱敏状态 | 请求 ≤ 400 B，候选窗口 480 B；`$HOME` → `~`，`sk-`/`ghp_`/`AKIA` 等密钥前缀 → `[redacted]`；不发送 transcript、时间戳、路径、插件代次 |
| 零重试 + 熔断 | 不重试（2.5 s 截止内没有退避空间）；故障后熔断 30 s，指数加倍到 5 min |
| 模型钉死 | `METACODES_JEV_MODEL` 钉住模型名，响应模型不符即拒收（`ModelMismatch`） |
| 计费服务拒收 | 响应 `tariff != "none"` 即拒收（`PricedService`），直到内核有独立的花费记账 |
| 缓存契约不破 | 判断只影响已有的追加面（scoped recall 的 `<system-reminder>`、工具结果）；不进 system prompt、不引入时间/代次字节 |

## 3. 架构

```
src/jev/question.zig   封闭问题类型、comptime 校验、请求序列化、严格响应解析
src/jev/client.zig     HTTP 客户端：Io.Select 竞速(响应/截止/中断)、熔断、模型钉、计费拒收
src/jev/advisor.zig    问题目录(版本化) + 判断入口 + Audit(→ system_one_decision 事件)
src/jev/excerpt.zig    判断窗口：候选全文中与请求词最密的 480 B
src/jev/runtime.zig    METACODES_JEV_* 解析、堆上固定的 Runtime(App 持有生命周期)
```

四个消费点（全部是记忆面上已经存在的决策）：

| 决策 | 问题目录 | 基线（无顾问） | advisory 下的变化 |
|---|---|---|---|
| 自动召回注入（scoped recall） | `metacodes.jev.recall-relevance.v2` | BM25 top-3，绝对地板 3.0 + 相对衰减 0.5 | 见 §4：地板通过后，在 BM25 带内按“判断概率 + BM25”重排 8 个候选 |
| `KgRecall` 结果 | `metacodes.jev.recall-evidence.v2` | 原结果 | 追加 `system_one` 块：每条相关度 + 证据充分性 + 使用说明 |
| `KgRemember` 写入 | `metacodes.jev.memory-relation.v1` | 前缀近重复检测 | 追加 `relations` 块：同义/矛盾的已有记忆（写入照常发生） |
| 枚举意图 | `metacodes.jev.enumeration-intent.v1` | 确定性关键词提示 | 只武装**软提醒**；拒绝型修复仍只绑定确定性提示 |

每次咨询都写一条 `system_one_decision` 事件（schema `metacodes-system-one-decision-v1`）：
decision、question_set、mode、outcome、actuated、request_sha256、model、elapsed_ms、
question_count、state_bytes、judged、positive、changed。召回门的决定进评估事件流
（native events，评估适配器 `scripts/eval/e2e_adapter.py` 对它做因果不变量校验：未应答的咨询
不能带判断计数，`actuated` 只能出现在 advisory 且 `changed > 0` 时）；工具面（KgRecall、
KgRemember、枚举）的决定进会话的 tool-observation journal（`tool-observations.jsonl`，
rollout 产物摘要同样覆盖它）。

配置（环境变量）：

| 变量 | 含义 |
|---|---|
| `METACODES_JEV_URL` | 服务 origin（如 `http://host:10420`）；未设即关闭 |
| `METACODES_JEV_MODE` | `shadow`（默认）或 `advisory` |
| `METACODES_JEV_TIMEOUT_MS` | 单次截止，默认 2500（8 候选判断单客户端 p50 0.91 s / p99 1.06 s，三个客户端共享服务时 p50 2.4 s；超时会退回基线并开熔断，所以给共享服务留余量） |
| `METACODES_JEV_MODEL` | 期望的模型名（钉死）；不设则接受服务报告的任何模型 |
| `METACODES_JEV_DECISIONS` | 逗号分隔的决策面子集：`scoped_recall`、`recall_evidence`、`memory_relation`、`enumeration_intent`（默认全部）；没列出的面行为与没有顾问完全相同；未知名或空列表会让顾问整体关闭并告警 |

## 4. 召回门：最终方案

```
BM25 取 8 个候选 → 地板：top 分 < 3.0 ⇒ 判定答案缺席，不注入，也不咨询 Jev
地板通过 ⇒ Jev 对 8 个候选各答一个 boolean（v2 措辞，读每条的 480 B 聚焦窗口）
        ⇒ 只在 BM25 带内挑：分数 ≥ top × 0.5（与基线同一个相对带，但覆盖整个 8 候选池）
        ⇒ 融合分 = P(相关) + 0.5 × BM25 / BM25_top，降序（BM25 名次破平）
        ⇒ 依次取 P ≥ 40% 的，最多 3 条；一条都没有 ⇒ 只注入带内融合分最高的 1 条
```

实现：`scoped_recall.judgedSelection`（`RELEVANCE_THRESHOLD_PERCENT = 40`，
`BM25_FUSION_WEIGHT = 0.5`，带宽复用基线的 `REL_RATIO = 0.5`）。每一条设计都来自一次失败：

- **BM25 管“有没有”，Jev 与 BM25 一起管“是哪条”**。v1 让 Jev 独自决定注入（θ = 60，
  全不相关就不注入），在 dev 上命中从 0.620 掉到 0.495：Jev 的“全部不相关”会把措辞迂回但
  真正相关的记忆整批丢掉。答案缺席的信号于是还给 BM25 地板。
- **融合 BM25**。Jev 只读 480 B 窗口，BM25 读全文。在整段会话这种长记忆上，只用 Jev 重排
  反而低于基线（0.700 vs 0.725）；加回 0.5 倍归一 BM25 后到 0.790。短记忆上融合的代价是
  0.730 → 0.685，两者都显著优于基线；在两种粒度上都显著优于基线的只有融合。
- **地板以下不咨询 Jev**：此时两种策略都不注入，咨询只会给每个无关轮次加约 1 s 延迟。
- **v2 措辞**（“是否关于请求所问的那个具体的人/事/物”）替换 v1（“是否回答请求所必需”）：
  v1 过严，漏掉只提供线索的记忆（同一批 123 个 dev 案例 0.748 vs 0.724）。
- **BM25 带**（付费程序性迁移试点暴露，§6.3）：判断器会把“另一个同族任务的具体 diff”评得
  比“这一族的协议说明”更相关（66–85% 对 27–71%），而那条 diff 的 BM25 只有协议的 1/9；不设带时
  它被注入，模型照抄了兄弟任务的改动。带把 Jev 的选择限制在 BM25 认为可信的候选里：程序性池
  （分数陡）上退化为基线，LongMemEval 池（分数平）上一条命中都没少。
- **聚焦窗口**：取候选全文中与请求词最密的 480 B；停用词只含通用英文虚词。曾试过把评测提示
  模板词也列为停用词（dev +0.03），那是在拟合评测集，已弃用；按池内 IDF 加权也试过，无增益。
  窗口在长记忆上把命中从 0.750（头部）提到 0.790，在短记忆上持平（0.685 vs 0.700）。

## 5. 与 Codex 方案的融合

Codex 的《Jev × metacodes Harness 接入方案》目标是用 Jev（+ JevTree 图搜索）改进长任务的
**下一步动作选择**。逐条取舍如下：

| Codex 主张 | 处理 | 理由 |
|---|---|---|
| 内核独占 AgentLoop/权限/沙箱/预算/formal/TinyKG admission/CAS | **采纳** | 与 AGENTS.md 内核边界一致；Jev 不拿任何可变句柄 |
| 默认 disabled；服务故障退回基线；取消/预算/journal 错误照旧 fail-closed | **采纳** | 实现为 `Outcome` 与 `error.Aborted` 的二分 |
| DecisionAdvisor typed seam，由 Host 安装 | **采纳并收窄** | `Advisor` 由 App 持有、经 `AgentLoop.Options.jev` 与 `ToolContext.jev` 传入；但只接在记忆面四个已有决策点，不做通用 turn-boundary observation |
| 候选只来自宿主确定性枚举，Jev 不生成命令/路径 | **采纳** | 候选 = BM25 命中；问题目录 comptime 校验 |
| 最小脱敏 state；不发 transcript/秘密/路径/时间戳 | **采纳** | `appendRedacted` + 字节预算 |
| 算术/计数/日期/权限由内核定，不交给 Jev | **采纳** | 计数、阈值、选择都在 Zig 里 |
| 钉死具体模型，避免别名漂移 | **采纳** | `METACODES_JEV_MODEL` + `ModelMismatch` |
| shadow / advisory / enforced-safe 三档 | **采纳前两档，拒绝 enforced-safe** | 记忆面没有需要“强制路由”的动作；而且判断是传感器，按 sensor/policy 分离原则“错判只能静音一个门，不能触发一个门” |
| 重试须为零或逐次入预算 journal | **采纳零重试**；拒绝“截止内有限退避” | 2.5 s 截止里没有退避空间；用熔断代替 |
| 内核 BudgetAccount/ProviderCharge，Jev 与主 provider 共享总上限 | **推迟，改为拒收计费服务** | 自建服务 `tariff: none`；在没有花费记账前，任何计费响应直接拒收，比“先建一个空转的账户”更诚实。延迟成本（elapsed_ms）逐次入事件：shadow 不是零成本 |
| JevTree：状态合并、路径概率、unresolved mass、Pareto 选择、receding horizon | **推迟** | Codex 自己承认编码任务 `max_depth=1`、未执行分支全是 unresolved——图搜索退化为局部偏好，而且没有可测的地面真值。记忆面有 BM25 这个现成传感器和 LongMemEval 金标，先在这里证明价值 |
| 动作族评分（Read/Grep/RunTests/Write…）与 bounded nudge | **推迟** | nudge 每轮进入 provider 可见字节，与缓存契约冲突，需先设计追加面；也缺少把“更好的下一步”变成分数的评估 |
| Stage 0 离线回放 | **采纳为零 provider 驱动** | `scripts/jev_recall_eval_driver.zig` 直接调用生产策略函数回放候选池，见 §6 |
| “JevTree README 的数字不是 metacodes 的 SLA，以本项目冻结配对评估为准” | **采纳** | §6 全部是本项目评估 |

## 6. 评估

### 6.1 方法（零 provider，召回门本身）

- 数据：LongMemEval-S cleaned（sha256 `d6f21ea9…c442`），`adapt-longmem-memory --limit 500
  --split-seed 20260806` 的案例顺序；金标 = 官方 `answer_session_ids`。
- 记忆库：每个案例一个隔离 TinyKG 库，用固定 TinyKG 二进制建库。两种库：
  **mixed** = 付费 runner 实际建的库（整段会话节点 + 每轮节点，候选中位 13.7 KB）；
  **turn** = 只有每轮节点（原子记忆，中位 2.2 KB）。候选池 = `search --profile agent-memory`
  的 BM25 前 8。
- 指标：命中 = 注入集合里至少一条属于金标会话；另报每例注入条数、精度（注入中属于金标的比例）、
  每例噪声条数。配对 exact McNemar。
- 切分：案例 0–199 为 dev（所有设计选择都只看 dev），200–499 为 holdout（最终策略定稿前没有
  跑过）。
- 生产驱动：`zig build eval:jev-recall-driver` 构建 `metacodes-jev-recall-eval`，它直接调用
  `scoped_recall.baselineSelection/judgedSelection` 与 `Advisor.judgeRecallRelevance`，
  判断窗口与 `KgClient` 同一个函数——评估的就是生产代码，不是 Python 复刻。

### 6.2 结果

| 库 | 切分 | 基线命中 | Jev 命中 | McNemar p | 注入条数/例 | 精度 | 噪声条数/例 |
|---|---|---|---|---|---|---|---|
| turn | dev 200 | 0.620 | **0.685** | 0.029 | 2.98 → 1.77 | 0.404 → 0.710 | 1.77 → 0.51 |
| turn | **holdout 300** | 0.633 | **0.703** | **0.0019** | 2.98 → 1.68 | 0.387 → 0.685 | 1.83 → 0.53 |
| mixed | dev 200 | 0.725 | 0.780 | 0.09 | 2.96 → 1.45 | 0.337 → 0.655 | 1.97 → 0.50 |
| mixed | **holdout 300** | 0.717 | 0.740 | 0.39 | 2.96 → 1.40 | 0.349 → 0.667 | 1.93 → 0.47 |

表中是最终策略（含 §4 的 BM25 带）。带只改变选择、不改变发给判断器的字节，所以这些数字由
生产驱动记录的同一批（确定性）判断直接算出；与不设带时相比，四个集合的命中一条都没变，注入与
精度差在 ±0.02 以内。

- 原子记忆上命中显著提高（holdout +7.0 个百分点），同时注入少 43%、噪声少 71%。
- 整段会话记忆上命中持平略升（不显著），注入减半、噪声少 76%：主要收益是**不再往上下文里
  塞无关记忆**。
- holdout 分类别（turn 库）：6 类里 5 类提高、multi-session 持平；mixed 库上
  temporal-reasoning（0.786 → 0.750）与 single-session-preference（0.389 → 0.333）略降，
  其余提高。
- 1000 次生产驱动咨询全部应答（驱动截止 8 s）。单客户端延迟（100 次顺序请求）p50 0.91 s、
  p99 1.06 s、最大 1.20 s；三个评测客户端共享服务时 p50 约 2.4 s。

设计迭代（按时间顺序）：

| 设计 | turn dev 命中 | mixed 命中 | 淘汰原因 |
|---|---|---|---|
| 基线（BM25 地板） | 0.620 | 0.720（全 500） | — |
| v1：严格措辞 + Jev 独自选择 θ = 60 + 头部摘录 | 0.495（p = 0.001，更差） | 0.450（全 500，p ≈ 1e-22，更差） | 丢掉措辞迂回的相关记忆 |
| v2 措辞 + Jev 独自重排 θ = 40 + 聚焦窗口 | 0.730 | 0.700（dev） | 长记忆上低于基线 |
| v2 + 判断与 BM25 融合 | 0.685 | 0.780（dev，生产驱动） | 付费程序性试点注入兄弟任务的 diff（§6.3） |
| **v2 + 融合 + BM25 带（定稿）** | 0.685 | 0.780（dev） | — |

### 6.3 付费配对试点（本项目自己的 production runner）

所有付费试点都走 `scripts/eval/memory_agent_runtime_pilot.py`：GLM-5.2、receipt v9、Seatbelt 沙箱、
持久预算 journal、无静默重试；Jev 臂的子进程只连 runner 自己的回环代理（`external_network_calls`
保持 0），每次判断交换以请求/响应 SHA-256 记入 rollout 产物树。`tinykg_jev` = `tinykg_lexical`
+ advisory 模式的 Jev（判断截止 10 s，排除超时这一混杂）。第一轮（v22、LongMemEval 30 例）用
二进制 `4480d64`（sha256 `fae24ca4…`，无 BM25 带）；第二轮（v23、归因 60 例）用 `810591a`
（sha256 `49f4b23e…`，含 BM25 带与 `METACODES_JEV_DECISIONS`）。第一轮的两份计划：

- **程序性迁移** `evals/memory/pilots/procedural-glm52-v22`：v20 同一批 4 个家族、12 个案例、
  验证器逐字节相同，× 4 trials = 144 行，臂位置完全平衡。预注册主估计量：离线确定性成功率配对
  差 `tinykg_jev − tinykg_lexical`（exact McNemar）。上限 $118。
- **LongMemEval-S**：从未碰过的 holdout（位置 200–499）按固定规则选 30 例：去掉
  single-session-preference（评分表式答案无法精确匹配），去掉所有金标都超过 4 个词的案例
  （拒答句、自由回答），其余 5 类各取 holdout 顺序中的前 6 个。过滤后的上游文件 sha256
  `15e93f32…`，经官方 `adapt-longmem-memory` 生成（源 sha256 `7e21db44…`）。90 行，
  上限 $75。数据集不入库，这里只记哈希与规则。

试点先暴露了两个与 Jev 无关、但让本项目付费记忆评测自 TinyKG storage v3 起就跑不动的 runner
缺陷，已修复（`42d16b2`）并写入 CHANGELOG：在线（可写）库的 TinyKG daemon 锁是库的兄弟文件，
不在沙箱放行范围内，TinyKG 臂全部降级；JSONL 用 `str.splitlines()` 切分，遇到 LongMemEval
文本里的 U+2028 就把记录切断。两次中止的尝试（v21 与 LongMemEval 第一次）共提交 $0.104、
保守敞口 $0.904，已记为 v22 的前序尝试；加上两份上限仍在 $200 授权内。

**LongMemEval-S 30 例（付费，holdout）**，`scripts.eval.cli replay-memory` 打分：

| 臂 | 有效行 | EM | F1 | 证据 R@K | 已核实证据 R@K | 暴露记忆 token/例 | 成本/例 |
|---|---|---|---|---|---|---|---|
| `no_memory` | 30 | 0.000 | 0.000 | 0.000 | 0.000 | 0 | $0.005 |
| `tinykg_lexical` | 29 | 0.552 | 0.642 | 0.962 | 0.494 | 7854 | $0.052 |
| `tinykg_jev` | 27 | 0.481 | 0.599 | 0.985 | **0.637** | **6930** | $0.050 |

- 两臂都有效的 26 对里，只有 lexical 答对的 6 对、只有 Jev 答对的 4 对，exact McNemar p = 0.75：
  30 例看不出端到端准确率差异。分歧对大多是精确匹配的格式噪声（“Target (via the Cartwheel
  app).” 对金标 “Target”），两臂都有；答案长度中位数都是 2.5 个词。
- 过程指标朝 Jev 一侧移动：模型真正打开核实的金标证据从 0.494 升到 0.637，暴露给模型的记忆
  token 少 12%。
- 无效行 3 对 1，原因都是 “一次运行里出现多个不同的 seed 检索计划”（治理协议判无效）。
  样本太小，不能归因于 Jev；在 Jev 行里看到的一例，第一次检索的 `sufficient` 已是 88，模型仍
  换了措辞重新 seed。
- 这一臂每例多约 3 s 墙钟（判断延迟），token 与成本基本持平。

**程序性迁移 v22（付费，预注册）**：第 82 行遇到网关 122 s 卡顿、客户端按流存活规则重发了一次
请求，runner 按“单次 provider 尝试”不变量 fail-closed 中止（设计如此，非 Jev 问题）。已核实的
前 81 行覆盖 4 个家族中的 3 个：

| 臂 | 在线（写入）成功 | 离线（迁移）成功 | 每行成本 |
|---|---|---|---|
| `no_memory` | 9/9 | 0/18 | $0.133 |
| `tinykg_lexical` | 9/9 | **18/18** | $0.083 |
| `tinykg_jev`（无 BM25 带） | 9/9 | **15/18** | $0.092 |

`tinykg_jev − tinykg_lexical` 离线配对：lexical 独胜 3、Jev 独胜 0（p = 0.25，不显著但方向一致）。
逐行复盘（`native-events.jsonl` + cassette 首个请求）：三行里唯一触发的 Jev 决策都是召回门
（`changed = 2`），KgRecall 注释与枚举判断都没有参与。基线注入的是本族协议说明（“Register …
Establish this family's protocol …”）；Jev 门在 2 行里注入了兄弟任务的具体 diff，模型把兄弟的
`schema_upgrade` 条目也写进了当前工作区；第 3 行内容正确但用 `ITEMS.append(...)` 而非改字面量，
被只做静态 AST 比较的验证器判错。

用这 36 个离线行各自的 TinyKG 库重建召回池、经生产驱动重问判断器（判断是确定性的）：旧策略在
18/18 个 Jev 池里都注入了 diff、5/18 丢了协议说明；加上 BM25 带后 36/36 与基线选择完全相同。
同一个带在 LongMemEval 四个集合（dev/holdout × turn/mixed）上命中一条都没变（§6.2 的数字即
带宽策略下的结果）。

**LongMemEval-S 归因试点（付费，二进制 `810591a`，含 BM25 带）**：同一规则从 holdout 再取 60 个
新案例（两份各 30 例并行跑），四臂，`tinykg_jev_recall` = 只开召回门（`METACODES_JEV_DECISIONS=
scoped_recall`）。合计 $9.44。

| 臂 | 有效行 | EM | 已核实金标证据（全部行） | 暴露记忆 token/例 |
|---|---|---|---|---|
| `tinykg_lexical` | 52/60 | 25/52 = 0.481 | 33/60 | 7505 |
| `tinykg_jev`（四个面全开） | 54/60 | 27/54 = 0.500 | 34/60 | 6579 |
| `tinykg_jev_recall`（只开召回门） | 55/60 | 27/55 = 0.491 | **42/60** | 6937 |

- 端到端准确率三臂没有差别（配对分歧 4:4、3:4、6:5）。
- 过程指标：只开召回门的臂让模型**打开核实到金标证据**的比例明显更高——对 lexical 的配对分歧
  13:4（exact p = 0.049）；四面全开的臂对 lexical 是 13:12，被抵消了；两个 Jev 臂之间 15:7
  （p = 0.13）。三臂**检索到**金标证据的比例相同（分歧 ≤ 1），差别只在模型是否去读它。这是
  次要、探索性指标，但方向清楚：召回门注入了更对的记忆；KgRecall 上的相关度/充分性注释没有
  增益，反而抵消了这份好处。
- 与第一次 30 例合并后（90 例），“多个不同 seed 计划”导致的无效行 lexical 与四面全开各 9 行：
  第一次试点里 3:1 的差异是噪声，不是注释诱发的。

**程序性迁移 v23（付费，预注册，含 BM25 带，二进制 `810591a`）**：第 136 行（`no_memory` 臂）又遇到
一次网关卡顿重发，同样按不变量中止；已核实的前 135 行覆盖全部 4 个家族：

| 家族 | `no_memory` 离线 | `tinykg_lexical` 离线 | `tinykg_jev` 离线 |
|---|---|---|---|
| evidence-route | 0/8 | 7/8 | 7/8 |
| rollback-ticket | 0/8 | 7/8 | 7/8 |
| lease-release | 0/8 | 7/8 | 7/8 |
| checkpoint-capsule | 0/6 | 6/6 | 6/6 |
| 合计 | 0/30 | **27/30** | **27/30** |

主估计量 `tinykg_jev − tinykg_lexical`：配对分歧 3:3，p = 1.0——v22 的迁移退化（15/18 对 18/18）
消失。召回门在这 135 行里被咨询 16 次、一次都没有改变选择（与基线相同，正是带的设计）。在线行
三臂 14–15/15；每行离线成本两臂都约 $0.10（`no_memory` $0.21，它没有记忆只能反复摸索）。

**付费花费合计**（全部经持久预算 journal，无静默重试）：

| 运行 | 结果 | 已提交 | 另计未结算敞口 |
|---|---|---|---|
| v21 | runner 缺陷中止（在线库 daemon 锁） | $0.046 | $0.80 |
| LongMemEval 第一次 | runner 缺陷中止（JSONL U+2028） | $0.058 | — |
| LongMemEval 30 例 | 完成 | $3.255 | — |
| v22 | 网关卡顿中止，81 行已核实 | $8.315 | $0.80 |
| 归因 60 例（两份） | 完成 | $9.443 | — |
| v23 | 网关卡顿中止，135 行已核实 | $14.922 | $0.60 |
| **合计** | | **$36.04** | 保守 **$38.24**（授权 $200） |

## 7. 结论与推荐配置

按决策面汇总证据（全部是本项目评估）：

| 决策面 | 证据 | 推荐 |
|---|---|---|
| `scoped_recall` 召回门 | 离线：原子记忆 holdout 命中 0.633 → 0.703（p = 0.0019），注入少 43%、噪声少 71%；整段会话记忆命中持平、噪声少 76%；程序性池与基线逐一相同（BM25 带）。付费：程序性迁移离线 27/30 对 lexical 27/30（未设带的 v22 是 15/18 对 18/18）；LongMemEval 准确率不变，已核实金标证据 33/60 → 42/60（p = 0.049） | **advisory** |
| `recall_evidence` KgRecall 注释 | 付费归因：没有增益，且抵消了召回门带来的核实提升（34/60 对 42/60） | 关闭（待重新设计） |
| `memory_relation` 写路径关系 | 所有付费试点里一次都没被咨询（没有写入与已有记忆冲突） | 暂不启用；需要有冲突写入的评测 |
| `enumeration_intent` 枚举意图 | 付费试点里咨询 55 次，一次都没越过 80% 阈值、从未武装软提醒 | 暂不启用 |

对应的配置：

```sh
export METACODES_JEV_URL=http://<host>:10420
export METACODES_JEV_MODE=advisory
export METACODES_JEV_DECISIONS=scoped_recall
export METACODES_JEV_MODEL=metask-jev-4b
```

默认值保持保守：不设 URL 即关闭；设了 URL 默认 `shadow`、四个面全开（只记账不改行为，
用来积累后续评估数据）。

后续：

1. **KgRecall 注释重做**：去掉数字与指导语，只按“判断 + BM25 带”重排命中顺序，再用同一个归因臂
   验证；不能再抵消召回门。
2. **写路径与枚举**：先造有冲突写入、需要枚举多项的评测，再决定 `memory_relation` /
   `enumeration_intent` 是否启用。
3. **缓存**：判断是确定性的，可按请求 SHA-256 在会话内缓存，重复查询零延迟。
4. **动作面（Codex Stage 2/3）**：先建设“下一步动作”的离线金标（DecisionFixture），再做
   只读动作族的 shadow 评分；在拿到配对证据之前不进入 provider 可见字节。
