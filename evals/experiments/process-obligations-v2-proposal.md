# PO-V2:过程义务机制包提案(账本并 DAG / 测试弱化信号 / typed 决策漂移核对 / freshness 升级)

状态:提案(用户 2026-08-17 批准机制包方向)。排队:当前 fstack 复制链(r3/r4 + sealed48)收官之后的下一个 dev16 迭代周期。
证据基础:fstack-pair-20260817-r2 的 11 个低分 treatment trial 逐断言归因(KG evidence 见提案节点出边;原始工件 `~/prj/workbuddy-eval-archive/fstack-pair-20260817/`)。

## 红线(逐字沿用 KG 12205)

所有机制为**任务无关的过程义务**,不得包含任何数据集/任务特定内容;dev16 是唯一迭代面;sealed48 一次性、任务正文禁读、不许重跑;误杀=0 是 enforce 的前置红线;每个新义务 **observe 模式先行**测底率,再谈 enforce(需求账本 items_total=0 的教训:未测采用率就上的义务面=死义务面)。

## 证据摘要(为什么是这四个)

r2 treatment 11 个 <1.0 任务的横切事实:

- 模型在 **16/16 trial 重度使用任务 DAG**(37–97 次调用/trial)做需求分解,而独立需求账本通道 **0 条写入**;end-gate nudge 在模型已建 4–6 个 DAG 需求项时仍宣称"从未记录需求账本"——**假 nudge 在训练模型无视 nudge**。
- 两起**测试弱化**事件,方向一致:security_hardening 把自己失败的断言改弱迁就 bug 代码(并亲口声明"这超出范围"后在 nudge 时重申全部完成);bug_fix 把失败断言改成匹配自己的输出。
- 两起**计划→代码漂移**:dotenv 在计划里两次决定 `logger.debug`,下一个 Edit 写成 `logger.info`,自测将漂移钉死;label_conflicts 逐字引用 README 规则后下一轮实现成反面。
- **现行 gate 义务零判别力**:verification_obligation_met 在全部失败 trial(0.25/0.27/0.42)均为已达成;freshness nudge 三次触发,全部只产生已绿检查的重跑。
- 不可治项(诚实登记):etag/bug_fix/refactor 三面墙的 verifier 要求指令与工作区之外的实现细节(模块路径/哈希算法/逐字文案/与"输出别变"矛盾的隐藏行为),任何 harness 机制不可达,**封死 dev16 均值约 0.10–0.12 的天花板**;refactor 中 governance nudge 将模型推向字面遵守指令、离隐藏测试更远——义务与暗规格反向的警示样本。此三项转入评估程序效度台账,不做任务修改(sealed48 红线)。

## 机制 M1:需求账本并入 DAG 面(TinyKG,wiring 级)

- 需求义务的计数源从独立账本通道改读 **DAG 需求项**(TaskCreate/TaskUpdate 已有真实采用);`requirement_ledger_items_total` 语义变更为 DAG 需求项计数(trace 侧同步,闭合 roster 顺延)。
- end-gate nudge 文本修正:承认已有分解,**只追差集**("你已登记 N 项;以下陈述的义务尚无对应项:…"→ 无差集则不 nudge)。
- 观察指标:nudge 触发率、nudge 后新增项率、假 nudge 率(应归零)。
- 直接猎物:消除全部 trial 中的假 nudge;security_hardening 的"已识别缺陷未入账"进入差集追问射程。

## 机制 M2:测试弱化反模式信号(Lean/发射侧,observe 先行)

- 封闭可观察信号:**"上一次验证事件为失败之后,对测试分类文件的、仅触断言的编辑"**。构件全部已在 journal:文件分类(read_state/effect)、gate v2 验证事件(tier1/tier2/churn)、Edit diff。
- 阶段 1(observe):新 observation 事件 `test_weakening_candidate`(schema 钉版本,进 lockstep 表测试),trace/audit 加计数列。跑 dev16 测底率与误报率(正当的断言修正会命中——两轮 r2 数据里 bug_fix 有 2 起*合法*断言迭代([79][87]是修自己测试的真 bug),**必须先测得出可接受阈值**)。
- 阶段 2(nudge+decision):信号触发 → 要求落 decision 节点说明"为何改断言而非代码"。**不 block**(fail-closed 拦截会误杀合法测试修正,违反误杀红线)。
- 直接猎物:security_hardening 型死法(0.42,其中 6/7 失败检查即模型主动放弃的修复)。

## 机制 M3:typed 决策 + 漂移核对(TinyKG→gate)

- 计划期关键选择落 **typed decision 节点**(现有 KgRemember/decision kind,已有非零采用:label_conflicts trial 自发写过 decision);记录形态:一句话选择 + 关键 token(如"日志级别=debug")。
- end-gate 新增**决策核对段**:枚举本 trial 的 decision 节点,要求模型逐条对照最终 diff 确认"已兑现/已显式修订"。诚实登记:核对是**提示协议**(模型自查+计数器观察),不是机械 diff 语义比对——机械化需要语义理解,超出可判定射程;观察指标为核对段触发后的修正率。
- 直接猎物:dotenv 型漂移(计划 debug→实现 info)、label_conflicts 型引用-实现背离。

## 机制 M4:freshness 义务升级(gate v2 传感器,机械可判)

- 现行义务"存在任意验证事件"升级为:**最后一次变更事件之后存在覆盖变更面的验证事件**(mutation-after-last-verification ⇒ 义务未达成,直至重验)。churn/reopen 传感器已有,此为其义务化。
- 机械可判(journal 内 mutation/verification 事件序即可),两侧(Zig 义务判定+Python audit 重算)lockstep。
- 阶段 1 observe(新计数列:stale-verification-at-close 率),阶段 2 enforce(gate 不放行→nudge 重验)。
- 直接猎物:全部"绿灯橡皮图章"型达成;install_and_run 型"最后一次 mypy/ruff 重跑但未重验行为面"。

## 测量计划

1. **Observe 波**(dev16,1 对 ≈ $22):四机制全 observe,采底率(M2 误报率、M1 假 nudge 归零验证、M3 决策节点采用率、M4 stale 率)。判据:M2 误报可界定阈值、M3 采用率 >0、M1 假 nudge =0。
2. **Enforce 波**(dev16,配对,~$22/对 ×2):主指标沿用 fstack 口径(误杀=0 红线、剂量计数器为主、reward delta 带内解读);机制特异指标 = 各"直接猎物"型失败的翻转计数(security 型/dotenv 型逐 trial 裁定)。
3. **泛化确认(开放问题,需用户决策)**:sealed48 已承诺给当前 fstack 链且一次性不可重用。PO-V2 的泛化仪器选项:(a) 追加密封集 v2(需新任务来源);(b) 接受 dev16 多轮 + 逐案裁定证据,泛化主张显式降级。提案不预设,留待 sealed48 收官后定。

## 与既有路线图的关系

- 排在:fstack r3/r4 复制 → sealed48 → 合并部署下一向量 之后。
- 与资金州机 Rev1/Rev2(F6/F4/台账/journal 三事件)正交,可并行开发、同 rev 或分 rev 落地(每 rev 都动 host control plane,只能落在 wave 之间)。
- M2/M4 的 schema 新增走 wire 契约 lockstep 纪律(常量+roster+表测试;若单一真理源 codegen 先落地则走 codegen)。
- 溯源:本提案是"typed plan/patch/invariant + 验证器判定合法性"通用思路的第一落地增量,选点原则 = **落在采用率已存在的面上**(DAG 有、账本无),invariant 生命周期与 patch 生命周期分离(RRP 管道先例)。
