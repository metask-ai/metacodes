# Trial-Resume:付费臂的 per-trial 断点续传(资金州机 Rev2 首增量)

动机:pov2-r1(1630z)baseline 第 15 任务尾部连续 502(断流→连错→超时)→ api_error → 整臂烧毁 $8。
今日粒度 = 臂原子;本设计把基础设施瞬态的恢复粒度降到单 trial,同时不打开任何择优面。

## 三道墙与解法

**墙 1:全臂连续请求序列**(`sorted(seqs)==1..N` 防隐藏流量)。
解:序列完整性改为 **per-proxy-session 连续 + 全归属**。收据记录 session 清单(初始 1 个 + 每次 resume 1 个);
每个 session 内 seq 必须连续且每条请求归属唯一 trial(计分 trial 或 tainted trial);tainted trial 的流量
**披露不丢弃**。"所有流量有账,无一隐藏"性质保持,只是账本从单段变多段。

**墙 2:配对缓存对称**。逐任务 `cacheable_first_request_sha256` 是确定性前缀,resume 的重试 attempt
产生相同首请求 sha → 检查原样通过。缓存温度本就逐 trial 不同(顺序执行),无新增不对称。

**墙 3:反择优**。resume 资格是**机械谓词,fail-closed**,不是操作者口味:
- 资格 = result.json.exception_info 非空(agent 进程失败)**且** 异常类型在允许列表
  (`RESUMABLE_EXCEPTION_TYPES`,现仅 NonZeroAgentExitCodeError;harness 缺陷类 RuntimeError
  即使与 5xx 尾部同现也拒绝,扩类=代码变更+review)**且** 该 trial requests.jsonl 尾部 M=6 条内
  存在 ≥1 网络类失败(status≥500 或 error 含 Connect/Timeout/RemoteProtocol/断流)。
- 干净跑完但分数难看的 trial:exception_info==null → **拒绝**,无例外通道。
- 归属:trial 必须经 staged 路径(内嵌 instance id)+ trial_uri 归属到本 run
  (2026-08-18 审查 F7:同 slug 多 run 共享 result root,mtime 窗口会误伤别的 run)。
- 上界:每 trial 最多 2 次 attempt;每臂最多 resume 3 个 trial(超过 = 系统性故障,整臂烧毁照旧);
  **每事务恰 1 个 resume 授权事件**(2026-08-18 审查定案:崩溃恢复走 continuation 复用事件,
  attempt≥3 设计禁止,>1 的预算只会被禁止路径消费)。
- 留痕:attempt-1 的 result.json **与 requests.jsonl** 哈希入 journal 证据与收据 `resumes` 块;
  resume 决定在花费**之前**作为 journal 事件落账(可审计的事前授权)。

## 州机与账本

新 journal 事件 `trial_resume_authorized`(schema 演进,roster 扩展,旧账本重放不受影响):
`{trials:[task], attempt:2, evidence_sha256(行集哈希), receipt_sha256(失败收据)}`。
资金语义:**不新增授权**——原 max_cost 上界继续约束跨 attempt 总花费(提交额 = 计分 trial 之和 +
attempt-1 真实花费,attempt-1 轨迹缺失时显式披露不可得,2026-08-18 审查 F4);事件只记录恢复决定与证据绑定。
状态流:request_authorized --(runner exit / audit fail, 失败收据)--> [resume-trials 资格验证]
--(trial_resume_authorized 落账)--> 染污改名 --> 重跑指定 trial(独立 instance `<run_id>-a2`)
--(全量审计,taint-aware)--> committed。

**崩溃恢复(2026-08-18 审查 F3 定案)**:落账之后任一窗口(改名/凭证/runner/审计)崩溃,
重新调用 resume-trials 进入 **continuation**——从磁盘(原名或已染污名皆可)重建行集,
逐字节对上事件的 evidence_sha256,复用同一授权继续,绝不追加第二个事件。改名逐 trial 幂等。

**失败收据 ↔ 活账本(2026-08-18 审查 J1)**:resume 落账后活账本必然长过收据 pin 的 checkpoint。
账本是原子重写的单 JSON 文档,"前缀"按结构重建:截断事件链到 pin 的 revision、用账本自己的
确定性序列化重建当时文档,字节必须复现 pin 的长度+哈希;截断点之后只允许同事务的 resume 事件。
仅 resume 流开启此接受法,其余漂移照旧 fail-closed。

**重跑实例隔离(2026-08-18 审查 F1/F2 根治)**:重跑 INSTANCE_ID=`<run_id>-a2`,原 instance 的
shard 日志/proxy.yaml/instance manifest 保持冻结字节;审计端按 task 精确绑定 -a2 staged 路径与
从原路由确定性派生的 -a2 model_route(不读取、不信任重跑生成的 instance manifest)。

## 审计改造(taint-aware _collect_usage)

- 轨迹绑定:tainted trial 目录(按 resumes 块的 result.json 哈希识别)从计分绑定排除;
  同任务的 attempt-2 目录成为唯一计分绑定(仍要求唯一性,双清洁目录照旧报错)。
- 三向请求账本照旧,但按 session 分段校验;tainted 流量计入披露列
  (`resumed_trial_requests`),不入 turn 恒等式。
- 收据新增 `resumes` 披露块;`exception_info` 检查对 attempt-2 照常执行(必须干净)。

## paired_analysis

校验 resumes 块(上界/证据形/attempt-2 清洁/行 schema 含 requests_sha256+attempt1_usage),
报告披露 resumed 任务清单与 taint 原因;H5 reward 绑定用 attempt-2 的 result.json。
**revision-gap 绑定(2026-08-18 审查 J3)**:commit_revision − authorization_revision − 1 恰等于
resume 事件数(有 resumes 块=1,无=0)——藏匿或伪造披露块都会撞已被字节重放钉死的账本 revision。
审计端另有硬绑定:resume_post_run_audit 只信账本 resume_events,收据行必须逐字节复现
journaled evidence_sha256。跨臂:resume 与否不要求对称(它是基础设施事件,不是 treatment;
但报告必须并排披露两臂 resume 计数,供解读者判断)。

## 第二轮审查落定(2026-08-18)

- **余量预检**:授权前汇总本 run 已观测花费(干净 trial + attempt-1 轨迹,缺失按 0 低估),
  已达事务上限即拒绝——重跑注定无法 commit 的臂现在烧毁,而不是花两次钱后卡死。
- **半成品拒绝**:trajectory 有、result 无的目录(runner 死在 verifier 期,真实窗口 ~13s)
  前置拒绝并报路径;它对 pending 检测不可见、对审计轨迹计数可见。
- **pending 子集**:continuation 只重跑仍缺干净 attempt-2 的任务;全齐则零花费直进审计
  (此路径不要求 provider 凭证,--credential-fd 改为可选)。attempt-2 自身异常 = 烧臂。
- **终端性资格**:账本连续失败尾段才算瞬态;5xx 后有成功记录 = 已恢复,agent 之死另有原因,拒绝。
- **双层披露防御**:paired 的 revision-gap 管存在性(藏匿/伪造),账本 resume_events 内容绑定管
  篡改(换任务名/哈希/理由);变异验证两层各有击杀测试。
- **残余(登记非修)**:资格谓词常量/文案在授权与 continuation 之间变更会令在途 resume
  以"证据不匹配"死亡(罕见,fail-closed);started_ns 由操作者提供,共享 result root 的
  错值两个方向都 fail-closed 但报错不指向根因;>1 resumed trial 的全编排路径待生产首用
  (账本/审计逐行逻辑已各自有测)。

## 部署位置

恢复工具,不改模型面(treatment 语义零变化;launch_gate/journal 属 host control plane)。
默认部署点 = 下一自然边界;**事故即时部署合法**:若链条中途撞瞬态,经既有 succession
机制(auditor 模块 + witness/复现证明)部署后 resume,收据披露 succession——这正是
succession 设计的用途(fstack-r2 baseline 曾以同路径恢复)。

## 增量切分

| 增量 | 内容 | 面 |
|---|---|---|
| A | journal 事件 + 重放兼容 + 测试 | memory_budget_journal |
| B | 资格谓词(纯函数)+ resume-trials 子命令(验证→落账→重跑→审计→commit) | launch_gate |
| C | taint-aware 审计(绑定排除/分段序列/披露块) | launch_gate |
| D | 收据/paired_analysis 校验与披露 | paired_analysis |
