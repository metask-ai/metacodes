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
- 资格 = result.json.exception_info 非空(agent 进程失败)**且** 该 trial requests.jsonl 尾部 M=6 条内
  存在 ≥1 网络类失败(status≥500 或 error 含 Connect/Timeout/RemoteProtocol/断流)。
- 干净跑完但分数难看的 trial:exception_info==null → **拒绝**,无例外通道。
- 上界:每 trial 最多 2 次 attempt;每臂最多 resume 3 个 trial(超过 = 系统性故障,整臂烧毁照旧)。
- 留痕:attempt-1 工件全量哈希入收据 `resumes` 块(tainted_reason=异常类+provider 尾部状态);
  resume 决定在花费**之前**作为 journal 事件落账(可审计的事前授权)。

## 州机与账本

新 journal 事件 `trial_resume_authorized`(schema 演进,roster 扩展,旧账本重放不受影响):
`{trials:[task], attempt:2, evidence_sha256(每 trial 的 attempt-1 result.json 哈希), receipt_sha256(失败收据)}`。
资金语义:**不新增授权**——原 max_cost 上界继续约束跨 attempt 总花费;事件只记录恢复决定与证据绑定。
状态流:request_authorized --(runner exit / audit fail, 失败收据)--> [resume-trials 资格验证]
--(trial_resume_authorized 落账)--> 重跑指定 trial --(全量审计,taint-aware)--> committed。

## 审计改造(taint-aware _collect_usage)

- 轨迹绑定:tainted trial 目录(按 resumes 块的 result.json 哈希识别)从计分绑定排除;
  同任务的 attempt-2 目录成为唯一计分绑定(仍要求唯一性,双清洁目录照旧报错)。
- 三向请求账本照旧,但按 session 分段校验;tainted 流量计入披露列
  (`resumed_trial_requests`),不入 turn 恒等式。
- 收据新增 `resumes` 披露块;`exception_info` 检查对 attempt-2 照常执行(必须干净)。

## paired_analysis

校验 resumes 块(上界/证据形/attempt-2 清洁),报告披露 resumed 任务清单与 taint 原因;
H5 reward 绑定用 attempt-2 的 result.json。跨臂:resume 与否不要求对称(它是基础设施
事件,不是 treatment;但报告必须并排披露两臂 resume 计数,供解读者判断)。

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
