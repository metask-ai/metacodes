# Metacodes 基准测试接手核验报告

> 由 `generate_report.py` 根据本目录 `data/` 生成。核验日期：2026-09-12。

WorkBuddy 已收齐 **260/260 题**，任务加权均分 **72.97/100**，满分 **80/260**。实际被测二进制为 **Metacodes 0.1.0，提交 `1d27f07`**。17 笔选定运行中，7 笔审计提交成功、10 笔为 `authorized_failure`；这些分数是评测器观察值，不能标为 0.2.0 正式验收成绩。

## WorkBuddy 结果

| 域 | 判分覆盖 | 平均分 / 100 | 满分题数 |
|---|---:|---:|---:|
| code | 80/80 | 72.66 | 33 |
| office | 50/50 | 78.81 | 0 |
| security | 60/60 | 58.97 | 11 |
| web | 70/70 | 81.14 | 36 |
| 合计 | 260/260 | **72.97** | **80** |

四域等权平均为 72.89。原会话的 74.4 分来自前 245 题（精确值 74.41）；遗漏的 15 道 security 题在 2026-09-12 00:49 UTC 跑完，均分 49.44。补入后 security 为 58.97，总分为 72.97。不能继续沿用“15 题无法构建”的描述。

结果按冻结 cohort manifest 的完整 task_name 精确对应，260 个任务均唯一。每个 job 选取 9 月 10 日起的最后一次完整运行，sec15 仅补充此前遗漏的任务；没有按 reward 高低选成绩，也没有用旧轮次补分。下方保留被排除的早期运行清单。历史上已分析过 sealed 任务并据此修复，这轮属于诊断性复测，不能视作首次盲测或直接对标官方排行榜。

4 题在 result.json 中同时保留异常类型和 reward，评分照原样计入；没有因异常剔除分母。逐题来源与 SHA-256 见 [trials.csv](trials.csv)。

## 版本与特性

两台主机当前源码 checkout 都是 `d99997c`，但 WorkBuddy split mount 中的运行产物仍是旧版。17 份 launch manifest 的二进制、TinyKG、ripgrep 和 formal kernel 哈希全部与当前 artifact manifest 一致；当前 `metacodes --version` 输出均为 `metacodes 0.1.0`。

| 项目 | 核验证据 |
|---|---|
| Metacodes | manifest 源提交 `1d27f074f7ae90a428d805b8b387b20d574ca9df`；所有 launch 二进制 SHA-256 为 `e2552aad56c3c11139d2a8f042599adab49382e90d84bda399e76ac6d2e81cd6` |
| 模型 | launch 记录 `glm-5.2`；该字段说明请求配置，不能证明网关内部实际路由 |
| WorkBuddy | 上游 pin `b516950be5b56eb3be406c2f76ee1c5111dcb57f`，每笔 1 attempt、串行 1 并发 |
| TinyKG | 二进制已部署且哈希绑定；launch 声明 `fresh-home-per-trial`、清除远端 TinyKG 环境变量。这不能单独证明每题实际调用过 TinyKG |
| ripgrep | 已部署且哈希绑定；这里只确认产物配置，未逐条审阅工具轨迹 |
| formal kernel | 核心 formal kernel 已部署；不能据此推出 project harness kernel 已开启 |
| project harness | `evaluation_treatment.project_control=absent`，artifact manifest 为 `project_control=not-staged` |
| 实验处理 | verification checkpoint/final gate、requirement ledger、memory accumulation、self evolution、outcome feedback 均为 false，continuity seed 为 null |

因此，原会话“合并后新版已重跑”和“这些特性全部正常开启”的说法不受实际 launch 证据支持。源码更新、overlay 更新和运行产物更新是三个独立步骤；本轮记录显示运行产物没有随源码更新。

## 审计和费用

| 选定交易范围 | 交易数 | 覆盖题数 | receipt 状态 |
|---|---:|---:|---|
| code 全域；security dev / promotion_a / promotion_b | 7 | 101 | committed |
| office、web 全域；security sealed 与 sec15 | 10 | 159 | authorized_failure，post_run_evidence_audit |

10 笔失败交易的 receipt 均记录 runner returncode=0，说明评测 runner 已结束；这不等于 paid gate 审计通过。另外 7 笔有 committed receipt。失败日志包括 provider wave sequence 缺失/重复，以及 security trial identity incomplete/drifted。现有 compact receipt 只能确认失败阶段，不能据此断言 killed-trial 是全部失败的根因。

7 笔成功交易的审计实际成本合计 **$82.78**。10 笔失败交易实际费用未确认，授权上限仍暴露 **$714**；这是上限，不是实际消费。选定 trial 的 actor cost 已知项合计 $293.15，另有 9 题该字段为空，且不包含完整 judge 费用，不能当总账。这些金额只涵盖选定交易，未汇总早期中止或被替代轮次。

接手过程中只读取已完成结果、manifest、receipt 和版本信息，没有启动新的 provider 请求，也没有重试失败的付费交易。

## FrontierChallenge 历史结果

沿用 2026-09-05 归档数据：启动 80 题、有效判分 79 题、通过 45 题；判分口径均分 **69.55/100**、通过率 **56.96%**。官方 97 题分母下均分 **56.64**、通过率 **46.39%**。

该结果是旧版历史记录，本次没有重跑 FrontierChallenge。原归档披露了缺失任务按零计入、judge 输出形状归一化及重试补丁；使用官方 judge 模型名也不使本地 patched run 自动成为官方榜单成绩。复制的数据及原始文件 SHA-256 见 [provenance.json](data/frontierchallenge/provenance.json)。

## 接手后的待办

1. 现有 0.1.0 观察结果已收齐。README 可使用下面的短文案，但版本必须如实标明。
2. 若继续 0.2.0 目标，先用本轮失败证据修复并测试审计问题，确认源码、overlay、split-mount 产物都绑定同一发布提交。另行核定 project harness 和其他 treatment 的目标配置。
3. 在实际启动新付费测试前完成零费用 preflight/dry-run，明确本轮总预算和 durable journal。旧失败 receipt 禁止直接重试；新版实验需要独立、可审计的计划。
4. 新版结果、版本和特性证据齐备后，再提交 README、版本变更及 PR，待 CI 通过后完成发布流程。

README 短文案：

> Metacodes 0.1.0（1d27f07）+ GLM-5.2：WorkBuddy-Bench 260/260 题平均 72.97/100，满分 80 题；code 72.66、office 78.81、security 58.97、web 81.14。本地诊断性复测，含未通过运行后审计的交易。

## 选定运行

| 主机 | job | run | 题数 | receipt |
|---|---|---|---:|---|
| patron | `metacodes-glm52-code-dev-full1` | `2026-09-10__12-07-27` | 16 | committed |
| patron | `metacodes-glm52-code-proma-full1` | `2026-09-10__13-03-49` | 8 | committed |
| patron | `metacodes-glm52-code-promb-full1` | `2026-09-10__14-21-46` | 8 | committed |
| patron | `metacodes-glm52-code-sealed-full1` | `2026-09-10__15-25-42` | 48 | committed |
| patron | `metacodes-glm52-office-dev-full1` | `2026-09-10__20-39-34` | 10 | authorized_failure |
| patron | `metacodes-glm52-office-proma-full1` | `2026-09-10__23-51-11` | 5 | authorized_failure |
| patron | `metacodes-glm52-office-promb-full1` | `2026-09-11__00-19-39` | 5 | authorized_failure |
| patron | `metacodes-glm52-office-sealed-full1` | `2026-09-11__21-26-00` | 30 | authorized_failure |
| kunshan | `metacodes-glm52-security-dev-diag1` | `2026-09-10__12-17-04` | 11 | committed |
| kunshan | `metacodes-glm52-security-proma-full1` | `2026-09-10__11-59-19` | 6 | committed |
| kunshan | `metacodes-glm52-security-promb-diag1` | `2026-09-10__12-50-00` | 4 | committed |
| kunshan | `metacodes-glm52-security-sealed-diag1` | `2026-09-10__13-37-09` | 24 | authorized_failure |
| kunshan | `metacodes-glm52-web-dev-full1` | `2026-09-10__19-19-34` | 14 | authorized_failure |
| kunshan | `metacodes-glm52-web-proma-full1` | `2026-09-10__23-21-26` | 7 | authorized_failure |
| kunshan | `metacodes-glm52-web-promb-full1` | `2026-09-11__21-23-24` | 7 | authorized_failure |
| kunshan | `metacodes-glm52-web-sealed-full1` | `2026-09-12__00-11-19` | 42 | authorized_failure |
| kunshan | `metacodes-glm52-security-sealed-sec15` | `2026-09-12__07-12-17` | 15 | authorized_failure |

早期运行被整体替代，不参与本报告均分：

| 主机 | job | 早期 run | 已产生结果数 |
|---|---|---|---:|
| patron | `metacodes-glm52-code-dev-full1` | `2026-09-10__09-26-17` | 16 |
| patron | `metacodes-glm52-code-dev-full1` | `2026-09-10__10-47-05` | 2 |
| patron | `metacodes-glm52-code-proma-full1` | `2026-09-10__10-17-23` | 7 |
| patron | `metacodes-glm52-office-sealed-full1` | `2026-09-11__00-35-30` | 5 |
| kunshan | `metacodes-glm52-security-dev-diag1` | `2026-09-10__09-46-07` | 11 |
| kunshan | `metacodes-glm52-security-proma-full1` | `2026-09-10__09-23-38` | 6 |
| kunshan | `metacodes-glm52-security-promb-diag1` | `2026-09-10__10-22-25` | 2 |
| kunshan | `metacodes-glm52-web-promb-full1` | `2026-09-11__00-28-13` | 3 |

## 本地复算

```sh
python3 generate_report.py
```

脚本检查完整任务集合、重复任务、评分范围、launch/receipt 的 run_id 和运行产物哈希，输出本报告、summary.json 与 trials.csv。主机原始轨迹和请求正文未复制；本目录只保存有界评分、来源哈希和必要运行元数据。
