"""Regenerate the takeover audit from bounded, local snapshots; no network."""
import collections
import csv
import hashlib
import io
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DATA = ROOT / "data"
cohorts = json.loads((DATA / "workbuddy/cohorts.json").read_text())
snapshots = [json.loads((DATA / f"workbuddy/{host}.json").read_text()) for host in ("patron", "kunshan")]
rows, transactions, alternatives = [], [], []
for snapshot in snapshots:
    manifest = snapshot["current_artifact_manifest"]
    assert snapshot["current_binary_sha256"] == manifest["executables"]["metacodes"]["sha256"]
    for slug, group in snapshot["slugs"].items():
        selected = group["selected"]
        assert selected and len(group["launches"]) == len(group["receipts"]) == 1, slug
        launch, receipt = group["launches"][0], group["receipts"][0]
        assert launch["run_id"] == receipt["run_id"]
        assert launch["artifact_manifest_sha256"] == snapshot["current_artifact_manifest_sha256"]
        for key, artifact in launch["artifacts"].items():
            assert artifact["sha256"] == manifest["executables"][key]["sha256"], (slug, key)
        domain = slug.split("-")[2]
        for row in selected["rows"]:
            assert row["launch_run_id"] == launch["run_id"], row["task"]
            score = (row["verifier_result"] or {}).get("rewards", {}).get("reward")
            assert isinstance(score, (int, float)) and not isinstance(score, bool)
            assert math.isfinite(score) and 0 <= score <= 1
            rows.append({**row, "domain": domain, "host": snapshot["host"], "slug": slug,
                         "run": selected["run"], "reward": score, "receipt_state": receipt["state"]})
        transactions.append({"host": snapshot["host"], "slug": slug, "run": selected["run"],
                             "trials": len(selected["rows"]), "launch": launch, "receipt": receipt})
        alternatives.extend({"host": snapshot["host"], "slug": slug, **old} for old in group["other_runs"])

def metrics(items):
    scores = [r["reward"] for r in items]
    return {"n": len(items), "sum": math.fsum(scores), "mean": math.fsum(scores) / len(items),
            "full_pass": sum(v == 1 for v in scores), "exceptions": sum(bool(r["exception_type"]) for r in items)}

domains = {}
for domain, spec in cohorts["subsets"].items():
    expected = {name for cohort, value in spec["cohorts"].items() if cohort != "dev_etag"
                for name in value["task_selection"]["names"]}
    subset = [r for r in rows if r["domain"] == domain]
    found = [r["task"] for r in subset]
    assert len(found) == len(set(found)) == spec["task_count"], domain
    assert set(found) == expected, (domain, set(found) ^ expected)
    domains[domain] = metrics(subset)
assert len(rows) == 260 and len(transactions) == 17
total = metrics(rows)
states = collections.Counter(t["receipt"]["state"] for t in transactions)
assert set(states) <= {"committed", "authorized_failure"}
committed = [t for t in transactions if t["receipt"]["state"] == "committed"]
failed = [t for t in transactions if t["receipt"]["state"] == "authorized_failure"]
assert all(t["receipt"]["runner"]["returncode"] == 0 for t in failed)
assert all(t["launch"]["evaluation_treatment"]["project_control"] == "absent" for t in transactions)
for transaction in transactions:
    treatment = transaction["launch"]["evaluation_treatment"]
    for key in ("verification_checkpoint", "verification_final_gate", "verification_final_observe",
                "requirement_ledger", "requirement_ledger_observe", "memory_accumulation",
                "self_evolution", "outcome_feedback"):
        assert treatment[key] is False, (transaction["slug"], key)
    assert treatment["continuity_seed_sha256"] is None
committed_cost = sum(t["receipt"]["budget_transaction"]["actual_cost_microusd"] for t in committed) / 1e6
exposed_cap = sum(t["receipt"]["budget_transaction"]["max_cost_microusd"] for t in failed) / 1e6
reported_cost = math.fsum(r["agent_result"]["cost_usd"] or 0 for r in rows)
missing_cost = sum(r["agent_result"]["cost_usd"] is None for r in rows)
sec15 = [r for r in rows if r["slug"].endswith("-sec15")]
prior245 = [r for r in rows if not r["slug"].endswith("-sec15")]

fc = {}
for shard in ("long", "mainA", "mainB"):
    for row in json.loads((DATA / f"frontierchallenge/{shard}.json").read_text())["rows"]:
        assert row["task_id"] not in fc, row["task_id"]
        fc[row["task_id"]] = row
fc_graded = [r for r in fc.values() if r.get("evaluation_complete") == 1 and r.get("task_score") is not None]
fc_sum = math.fsum(r["task_score"] for r in fc_graded)
fc_pass = sum(r.get("passed") == 1 for r in fc_graded)
fc_provenance = json.loads((DATA / "frontierchallenge/provenance.json").read_text())
fc_meta = fc_provenance["frontierchallenge"]

summary = {"workbuddy": {"domains": domains, "total": total, "equal_domain_mean": math.fsum(v["mean"] for v in domains.values()) / 4,
           "receipt_states": dict(states), "committed_cost_usd": committed_cost, "failed_authorized_cap_usd": exposed_cap,
           "partial_reported_actor_cost_usd": reported_cost, "actor_cost_missing_trials": missing_cost},
           "frontierchallenge": {"graded": len(fc_graded), "passed": fc_pass, "mean": fc_sum / len(fc_graded),
           "official_97_mean": fc_sum / 97, "official_97_pass_rate": fc_pass / 97},
           "checks": {"full_task_identity_coverage": True, "unique_task_rows": True, "score_range": True,
           "launch_receipt_identity": True, "all_launch_artifacts_match_manifest": True, "provider_requests_by_collector": 0}}
(ROOT / "summary.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n")
csv_buffer = io.StringIO(newline="")
writer = csv.DictWriter(csv_buffer, fieldnames=["domain", "task", "reward", "exception_type", "host", "slug", "run", "receipt_state", "result_sha256", "result_path"])
writer.writeheader()
for row in sorted(rows, key=lambda r: (r["domain"], r["task"])):
    writer.writerow({k: row[k] for k in writer.fieldnames})
(ROOT / "trials.csv").write_text(csv_buffer.getvalue())

L = ["# Metacodes 基准测试接手核验报告", "", "> 由 `generate_report.py` 根据本目录 `data/` 生成。核验日期：2026-09-12。", "",
     f"WorkBuddy 已收齐 **260/260 题**，任务加权均分 **{total['mean'] * 100:.2f}/100**，满分 **{total['full_pass']}/260**。实际被测二进制为 **Metacodes 0.1.0，提交 `1d27f07`**。17 笔选定运行中，7 笔审计提交成功、10 笔为 `authorized_failure`；这些分数是评测器观察值，不能标为 0.2.0 正式验收成绩。", "",
     "## WorkBuddy 结果", "", "| 域 | 判分覆盖 | 平均分 / 100 | 满分题数 |", "|---|---:|---:|---:|"]
for domain, value in domains.items():
    L.append(f"| {domain} | {value['n']}/{value['n']} | {value['mean'] * 100:.2f} | {value['full_pass']} |")
L.extend([f"| 合计 | 260/260 | **{total['mean'] * 100:.2f}** | **{total['full_pass']}** |", "",
          f"四域等权平均为 {summary['workbuddy']['equal_domain_mean'] * 100:.2f}。原会话的 74.4 分来自前 245 题（精确值 {metrics(prior245)['mean'] * 100:.2f}）；遗漏的 15 道 security 题在 2026-09-12 00:49 UTC 跑完，均分 {metrics(sec15)['mean'] * 100:.2f}。补入后 security 为 {domains['security']['mean'] * 100:.2f}，总分为 {total['mean'] * 100:.2f}。不能继续沿用“15 题无法构建”的描述。", "",
          "结果按冻结 cohort manifest 的完整 task_name 精确对应，260 个任务均唯一。每个 job 选取 9 月 10 日起的最后一次完整运行，sec15 仅补充此前遗漏的任务；没有按 reward 高低选成绩，也没有用旧轮次补分。下方保留被排除的早期运行清单。历史上已分析过 sealed 任务并据此修复，这轮属于诊断性复测，不能视作首次盲测或直接对标官方排行榜。", "",
          f"{total['exceptions']} 题在 result.json 中同时保留异常类型和 reward，评分照原样计入；没有因异常剔除分母。逐题来源与 SHA-256 见 [trials.csv](trials.csv)。", "",
          "## 版本与特性", "",
          "两台主机当前源码 checkout 都是 `d99997c`，但 WorkBuddy split mount 中的运行产物仍是旧版。17 份 launch manifest 的二进制、TinyKG、ripgrep 和 formal kernel 哈希全部与当前 artifact manifest 一致；当前 `metacodes --version` 输出均为 `metacodes 0.1.0`。", "",
          "| 项目 | 核验证据 |", "|---|---|",
          "| Metacodes | manifest 源提交 `1d27f074f7ae90a428d805b8b387b20d574ca9df`；所有 launch 二进制 SHA-256 为 `e2552aad56c3c11139d2a8f042599adab49382e90d84bda399e76ac6d2e81cd6` |",
          "| 模型 | launch 记录 `glm-5.2`；该字段说明请求配置，不能证明网关内部实际路由 |",
          "| WorkBuddy | 上游 pin `b516950be5b56eb3be406c2f76ee1c5111dcb57f`，每笔 1 attempt、串行 1 并发 |",
          "| TinyKG | 二进制已部署且哈希绑定；launch 声明 `fresh-home-per-trial`、清除远端 TinyKG 环境变量。这不能单独证明每题实际调用过 TinyKG |",
          "| ripgrep | 已部署且哈希绑定；这里只确认产物配置，未逐条审阅工具轨迹 |",
          "| formal kernel | 核心 formal kernel 已部署；不能据此推出 project harness kernel 已开启 |",
          "| project harness | `evaluation_treatment.project_control=absent`，artifact manifest 为 `project_control=not-staged` |",
          "| 实验处理 | verification checkpoint/final gate、requirement ledger、memory accumulation、self evolution、outcome feedback 均为 false，continuity seed 为 null |", "",
          "因此，原会话“合并后新版已重跑”和“这些特性全部正常开启”的说法不受实际 launch 证据支持。源码更新、overlay 更新和运行产物更新是三个独立步骤；本轮记录显示运行产物没有随源码更新。", "",
          "## 审计和费用", "",
          "| 选定交易范围 | 交易数 | 覆盖题数 | receipt 状态 |", "|---|---:|---:|---|",
          f"| code 全域；security dev / promotion_a / promotion_b | {len(committed)} | {sum(t['trials'] for t in committed)} | committed |",
          f"| office、web 全域；security sealed 与 sec15 | {len(failed)} | {sum(t['trials'] for t in failed)} | authorized_failure，post_run_evidence_audit |", "",
          "10 笔失败交易的 receipt 均记录 runner returncode=0，说明评测 runner 已结束；这不等于 paid gate 审计通过。另外 7 笔有 committed receipt。失败日志包括 provider wave sequence 缺失/重复，以及 security trial identity incomplete/drifted。现有 compact receipt 只能确认失败阶段，不能据此断言 killed-trial 是全部失败的根因。", "",
          f"7 笔成功交易的审计实际成本合计 **${committed_cost:.2f}**。10 笔失败交易实际费用未确认，授权上限仍暴露 **${exposed_cap:.0f}**；这是上限，不是实际消费。选定 trial 的 actor cost 已知项合计 ${reported_cost:.2f}，另有 {missing_cost} 题该字段为空，且不包含完整 judge 费用，不能当总账。这些金额只涵盖选定交易，未汇总早期中止或被替代轮次。", "",
          "接手过程中只读取已完成结果、manifest、receipt 和版本信息，没有启动新的 provider 请求，也没有重试失败的付费交易。", "",
          "## FrontierChallenge 历史结果", "",
          f"沿用 2026-09-05 归档数据：启动 80 题、有效判分 {len(fc_graded)} 题、通过 {fc_pass} 题；判分口径均分 **{fc_sum / len(fc_graded) * 100:.2f}/100**、通过率 **{fc_pass / len(fc_graded) * 100:.2f}%**。官方 97 题分母下均分 **{fc_sum / 97 * 100:.2f}**、通过率 **{fc_pass / 97 * 100:.2f}%**。", "",
          "该结果是旧版历史记录，本次没有重跑 FrontierChallenge。原归档披露了缺失任务按零计入、judge 输出形状归一化及重试补丁；使用官方 judge 模型名也不使本地 patched run 自动成为官方榜单成绩。复制的数据及原始文件 SHA-256 见 [provenance.json](data/frontierchallenge/provenance.json)。", "",
          "## 接手后的待办", "",
          "1. 现有 0.1.0 观察结果已收齐。README 可使用下面的短文案，但版本必须如实标明。",
          "2. 若继续 0.2.0 目标，先用本轮失败证据修复并测试审计问题，确认源码、overlay、split-mount 产物都绑定同一发布提交。另行核定 project harness 和其他 treatment 的目标配置。",
          "3. 在实际启动新付费测试前完成零费用 preflight/dry-run，明确本轮总预算和 durable journal。旧失败 receipt 禁止直接重试；新版实验需要独立、可审计的计划。",
          "4. 新版结果、版本和特性证据齐备后，再提交 README、版本变更及 PR，待 CI 通过后完成发布流程。", "",
          "README 短文案：", "",
          f"> Metacodes 0.1.0（1d27f07）+ GLM-5.2：WorkBuddy-Bench 260/260 题平均 {total['mean'] * 100:.2f}/100，满分 {total['full_pass']} 题；code 72.66、office 78.81、security 58.97、web 81.14。本地诊断性复测，含未通过运行后审计的交易。", "",
          "## 选定运行", "", "| 主机 | job | run | 题数 | receipt |", "|---|---|---|---:|---|"])
for t in transactions:
    L.append(f"| {t['host']} | `{t['slug']}` | `{t['run']}` | {t['trials']} | {t['receipt']['state']} |")
L.extend(["", "早期运行被整体替代，不参与本报告均分：", "", "| 主机 | job | 早期 run | 已产生结果数 |", "|---|---|---|---:|"])
for old in alternatives:
    L.append(f"| {old['host']} | `{old['slug']}` | `{old['run']}` | {old['trials']} |")
L.extend(["", "## 本地复算", "", "```sh", "python3 generate_report.py", "```", "",
          "脚本检查完整任务集合、重复任务、评分范围、launch/receipt 的 run_id 和运行产物哈希，输出本报告、summary.json 与 trials.csv。主机原始轨迹和请求正文未复制；本目录只保存有界评分、来源哈希和必要运行元数据。"])
(ROOT / "report.md").write_text("\n".join(L) + "\n")
checksums = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
             for p in sorted(DATA.rglob("*")) if p.is_file()}
(ROOT / "data-sha256.json").write_text(json.dumps(checksums, indent=2) + "\n")
print(json.dumps(summary, ensure_ascii=False, indent=2))
