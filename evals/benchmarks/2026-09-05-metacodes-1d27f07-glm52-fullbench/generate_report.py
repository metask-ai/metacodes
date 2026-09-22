#!/usr/bin/env python3
"""Generate report.md for this round from the files under data/ (never hand-edit report.md).

data/meta.json                         environment, versions, configuration, disclosures
data/frontierchallenge/<shard>.json    harbor summarize output per shard (rows[])
data/workbuddy/trials.json             collect_results.py output ({slug: {runs, trials}})
data/workbuddy/receipts.json           gate receipt/journal summary per slug (optional)
data/workbuddy/plan.json               cohort plan (slug -> subset/cohort/names)

    python3 generate_report.py
"""
from __future__ import annotations

import json
import re
import statistics
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
DATA = HERE / "data"
meta = json.loads((DATA / "meta.json").read_text())


def pct(x: float) -> str:
    return f"{100 * x:.1f}%"


# ---------------------------------------------------------------- FrontierChallenge
def fc_metrics():
    rows = {}
    shards = {}
    for f in sorted((DATA / "frontierchallenge").glob("*.json")):  # shard files only; reference-* lives in a subdir
        s = json.loads(f.read_text())
        shards[f.stem] = len(s["rows"])
        for r in s["rows"]:
            rows[r["task_id"]] = r  # later shard wins on duplicate task ids
    rows = list(rows.values())
    den97 = meta["frontierchallenge"]["official_denominator"]
    den81 = meta["frontierchallenge"]["open_track_tasks"]
    graded = [r for r in rows if r.get("task_score") is not None and r.get("evaluation_complete") == 1]
    scores = sorted(r["task_score"] for r in graded)
    passed = sum(1 for r in graded if r.get("passed") == 1)
    tot = sum(scores)
    dist = [0] * 5
    for x in scores:
        dist[min(4, int(x * 5))] += 1
    attempted_path = DATA / "frontierchallenge" / "tasks_attempted.txt"
    attempted = [l.strip() for l in attempted_path.read_text().splitlines() if l.strip()] if attempted_path.is_file() else []
    present = {r["task_id"] for r in rows}
    absent = [t for t in attempted if not any(i == t or i.startswith(t) or t.startswith(i) for i in present)]
    zeros = sorted({r["task_id"] for r in rows if r.get("scored_zero_missing_artifact")})
    unres = sorted({r["task_id"] for r in rows if (r.get("evaluation_complete") == 0 and not r.get("scored_zero_missing_artifact")) or (r.get("error") and "no reward" in str(r["error"]))})
    return {
        "shards": shards, "tasks": len(rows), "graded": len(graded), "passed": passed,
        "pass_graded": passed / len(graded) if graded else 0.0,
        "mean_graded": 100 * tot / len(graded) if graded else 0.0,
        "median": statistics.median(scores) if scores else 0.0,
        "pass_97": passed / den97, "score_97": 100 * tot / den97,
        "pass_81": passed / den81, "score_81": 100 * tot / den81,
        "dist": dist, "zeros": zeros, "unresolved": unres, "attempted": len(attempted), "absent": absent,
        "rows": sorted(rows, key=lambda r: r["task_id"]),
    }


# ---------------------------------------------------------------- WorkBuddy
def wb_metrics():
    trials = json.loads((DATA / "workbuddy" / "trials.json").read_text())
    plan_rows = json.loads((DATA / "workbuddy" / "plan.json").read_text())
    receipts = {}
    rp = DATA / "workbuddy" / "receipts.json"
    if rp.is_file():
        receipts = json.loads(rp.read_text())
    # One frozen cohort = one (subset, cohort). A `*-diag1` job is the gate's
    # diagnostic-subset replay of the same cohort minus tasks that could not be
    # built here; its trials fill the same cohort, the dropped tasks stay
    # unscored and are listed as not attempted. Planned = full cohort size.
    cohorts = {}
    for p_ in plan_rows:
        key = (p_["subset"], p_["cohort"])
        c = cohorts.setdefault(key, {"subset": p_["subset"], "cohort": p_["cohort"], "planned": None,
                                     "names": None, "excluded": [], "slugs": []})
        if p_.get("diagnostic"):
            c["excluded"] = list(p_.get("excluded") or [])
        else:
            c["planned"] = p_["n"]; c["names"] = list(p_["names"])
        c["slugs"].append(p_["slug"])
    per_slug = {}
    for p_ in plan_rows:
        slug = p_["slug"]
        rows = trials.get(slug, {}).get("trials", [])
        if not rows and slug not in receipts:
            continue
        by_task = {}
        for r in rows:
            by_task[r["task"]] = r
        rows = list(by_task.values())
        graded = [r for r in rows if r.get("reward") is not None]
        per_slug[slug] = {
            "subset": p_["subset"], "cohort": p_["cohort"], "planned": p_["n"], "diagnostic": bool(p_.get("diagnostic")),
            "attempted": len(rows), "graded": len(graded),
            "mean_reward": sum(r["reward"] for r in graded) / len(graded) if graded else None,
            "full_pass": sum(1 for r in graded if r["reward"] >= 1.0),
            "cost_usd": sum(r.get("cost_usd") or 0 for r in rows),
            "output_tokens": sum(r.get("output_tokens") or 0 for r in rows),
            "input_tokens": sum(r.get("input_tokens") or 0 for r in rows),
            "cache_tokens": sum(r.get("cache_tokens") or 0 for r in rows),
            "agent_s": [r["agent_s"] for r in rows if r.get("agent_s")],
            "exceptions": sum(1 for r in rows if r.get("exception") and r.get("exception") != "no result.json"),
            "receipt": receipts.get(slug),
            "rows": sorted(rows, key=lambda r: r["task"]),
        }
    # cohort-level rows: union of the cohort's transactions, last trial per task wins
    for c in cohorts.values():
        merged = {}
        for slug in c["slugs"]:
            for r in per_slug.get(slug, {}).get("rows", []):
                merged[r["task"]] = r
        c["rows"] = list(merged.values())
        if c.get("names"):  # true not-run (infra) = full cohort names with NO trial at all; an attempted-but-errored trial is NOT "not run"
            attempted_names = {r["task"].split("/")[-1] for r in c["rows"]}
            c["excluded"] = [n for n in c["names"] if n.split("/")[-1] not in attempted_names]
        c["graded"] = sum(1 for r in c["rows"] if r.get("reward") is not None)
        c["reward_sum"] = sum(r["reward"] for r in c["rows"] if r.get("reward") is not None)
        c["full_pass"] = sum(1 for r in c["rows"] if r.get("reward") is not None and r["reward"] >= 1.0)
        c["cost"] = sum(r.get("cost_usd") or 0 for r in c["rows"])
        c["out_tok"] = sum(r.get("output_tokens") or 0 for r in c["rows"])
    by_subset = defaultdict(lambda: {"planned": 0, "graded": 0, "reward_sum": 0.0, "full_pass": 0, "cost": 0.0, "out_tok": 0, "excluded": 0})
    by_cohort = defaultdict(lambda: {"planned": 0, "graded": 0, "reward_sum": 0.0, "full_pass": 0})
    for c in cohorts.values():
        for agg in (by_subset[c["subset"]], by_cohort[c["cohort"]]):
            agg["planned"] += c["planned"] or 0; agg["graded"] += c["graded"]
            agg["reward_sum"] += c["reward_sum"]; agg["full_pass"] += c["full_pass"]
        by_subset[c["subset"]]["cost"] += c["cost"]; by_subset[c["subset"]]["out_tok"] += c["out_tok"]
        by_subset[c["subset"]]["excluded"] += len(c["excluded"])
    return {"per_slug": per_slug, "cohorts": cohorts, "by_subset": dict(by_subset), "by_cohort": dict(by_cohort)}


fc = fc_metrics()
wb = wb_metrics()


def fc_reference_rows() -> dict:
    """Per-task rows of the previous official-judge round (copied into data/ for comparison)."""
    ref = {}
    for f in sorted((DATA / "frontierchallenge" / "reference-2026-09-01").glob("*.json")):
        for r in json.loads(f.read_text())["rows"]:
            ref[r["task_id"]] = r
    return ref


ref_rows = fc_reference_rows()
cur_rows = {r["task_id"]: r for r in fc["rows"]}
common = [t for t in cur_rows if t in ref_rows
          and cur_rows[t].get("evaluation_complete") == 1 and ref_rows[t].get("evaluation_complete") == 1
          and cur_rows[t].get("task_score") is not None and ref_rows[t].get("task_score") is not None]
deltas = sorted(common, key=lambda t: cur_rows[t]["task_score"] - ref_rows[t]["task_score"])
agree = sum(1 for t in common if (cur_rows[t].get("passed") == 1) == (ref_rows[t].get("passed") == 1))
L: list[str] = []
add = L.append
mc = meta["system_under_test"]
add(f"# 评测报告:{meta['round']}")
add("")
add("> 本文件由 `generate_report.py` 从 `data/` 自动生成,请勿手改。")
add("")
add("## 概要")
add("")
add(f"- **被测系统**:metacodes `main@{mc['commit'][:7]}`({mc['commit_title']}),Linux x86_64 ReleaseSafe 交叉编译于 Mac(zig {mc['zig']}),"
    f"无头模式(`-p`)+ {mc['model']} @ {mc['gateway']}")
add(f"- **基准 1 — FrontierChallenge**(open 赛道,官方分母 {meta['frontierchallenge']['official_denominator']},开放 {meta['frontierchallenge']['open_track_tasks']} 题,启动 {fc['attempted'] or fc['tasks']} 题、产出结果 {fc['tasks']} 题;"
    f"judge = {meta['frontierchallenge']['judge']['model']} ×{meta['frontierchallenge']['judge']['repeats']} 官方 pin);拓扑:{meta['frontierchallenge']['topology']}")
add(f"- **基准 2 — WorkBuddy-Bench**(pin `{meta['workbuddy']['workbuddy_commit'][:7]}`,四域 260 题,按冻结 cohort 分 16 笔预算交易,每笔 1 attempt/串行 1 并发;"
    f"配置 = {meta['workbuddy']['arm']});主机:{meta['workbuddy']['hosts']}")
add(f"- **时间线**:{meta['timeline']}")
add("")
add("## 第一部分:FrontierChallenge(metacodes + glm-5.2,官方 judge)")
add("")
add("| 指标 | 本轮 metacodes@" + mc["commit"][:7] + " | 上轮 2026-09-01 metacodes@59dd28c(同 judge) |")
add("|---|---|---|")
ref = meta["frontierchallenge"]["reference_previous_round"]
add(f"| 有效判分题数 | {fc['graded']} / {fc['tasks']} | {ref['graded']} / {ref['tasks_present']} |")
add(f"| 通过数 | {fc['passed']} | {ref['passed']} |")
add(f"| Pass Rate(判分口径) | **{pct(fc['pass_graded'])}** | {pct(ref['pass_graded'])} |")
add(f"| Mean Score(判分口径) | **{fc['mean_graded']:.1f}** | {ref['mean_graded_100']:.1f} |")
add(f"| 中位分 | {fc['median']:.3f} | {ref['median']:.3f} |")
add(f"| Pass Rate(官方 97 分母) | {pct(fc['pass_97'])} | {pct(ref['pass_97'])} |")
add(f"| Score(官方 97 分母) | {fc['score_97']:.1f} | {ref['score_97_100']:.1f} |")
add(f"| Pass Rate(开放 81) | {pct(fc['pass_81'])} | {pct(ref['pass_81'])} |")
add("")
add("分数分布(判分题,按 0.2 分档):")
add("")
add("| 区间 | 0–0.2 | 0.2–0.4 | 0.4–0.6 | 0.6–0.8 | 0.8–1.0 |")
add("|---|---|---|---|---|---|")
add("| 本轮 | " + " | ".join(str(x) for x in fc["dist"]) + " |")
add("")
add(f"分片:{', '.join(f'{k}={v}' for k, v in fc['shards'].items())}。")
add("")
add(f"**缺交付零分(genuine 0)** {len(fc['zeros'])} 题:" + (", ".join(f"`{t}`" for t in fc["zeros"]) or "无"))
add("")
add(f"**不可判残差(harness/verifier,按官方口径计零)** {len(fc['unresolved'])} 题:" + (", ".join(f"`{t}`" for t in fc["unresolved"]) or "无"))
add("")
add(f"**未产出结果的任务(按官方口径计零)** {len(fc['absent'])} 题:" + (", ".join(f"`{t}`" for t in fc["absent"]) or "无")
    + (";原因:" + "; ".join(f"{a['task']} — {a['reason']}" for a in meta["frontierchallenge"].get("absent_tasks", [])) if fc["absent"] else ""))
add("")
add(f"补跑轮次:{meta['frontierchallenge'].get('rerun_rounds')}。judge 形状事故:{meta['frontierchallenge'].get('judge_shape_incident')}")
add("")
if common:
    add("### 与上轮(2026-09-01,同 judge、同题、同补丁体系)逐题对照")
    add("")
    add(f"两轮共同判分 {len(common)} 题,通过判定一致 {agree} 题({pct(agree / len(common))});"
        f"共同题上本轮均分 {100 * sum(cur_rows[t]['task_score'] for t in common) / len(common):.1f} vs 上轮 {100 * sum(ref_rows[t]['task_score'] for t in common) / len(common):.1f}。"
        "单题分差主要来自 agent 采样与 judge 抽样噪声,只作方向性证据。")
    add("")
    add("**本轮明显落后**:")
    add("")
    add("| 任务 | 上轮 59dd28c | 本轮 1d27f07 | Δ |")
    add("|---|---|---|---|")
    for t_ in deltas[:6]:
        add(f"| `{t_}` | {ref_rows[t_]['task_score']:.2f} | {cur_rows[t_]['task_score']:.2f} | {cur_rows[t_]['task_score'] - ref_rows[t_]['task_score']:+.2f} |")
    add("")
    add("**本轮明显领先**:")
    add("")
    add("| 任务 | 上轮 59dd28c | 本轮 1d27f07 | Δ |")
    add("|---|---|---|---|")
    for t_ in deltas[-6:]:
        add(f"| `{t_}` | {ref_rows[t_]['task_score']:.2f} | {cur_rows[t_]['task_score']:.2f} | {cur_rows[t_]['task_score'] - ref_rows[t_]['task_score']:+.2f} |")
    add("")
    only_now = sorted(t for t in cur_rows if t not in ref_rows or ref_rows[t].get("evaluation_complete") != 1)
    add(f"上轮不可判/缺失而本轮有效判分的题 {len(only_now)} 题:" + (", ".join(f"`{t_}`({cur_rows[t_]['task_score']:.2f})" for t_ in only_now if cur_rows[t_].get('evaluation_complete') == 1) or "无"))
    add("")
add("<details><summary>逐题明细(task_id / score / passed / 状态)</summary>")
add("")
add("| 任务 | score | passed | 状态 |")
add("|---|---|---|---|")
for r in fc["rows"]:
    st = "graded" if r.get("evaluation_complete") == 1 else ("genuine-0" if r.get("scored_zero_missing_artifact") else "unresolved")
    sc = r.get("task_score")
    add(f"| `{r['task_id']}` | {sc if sc is None else f'{sc:.2f}'} | {int(r.get('passed') or 0)} | {st} |")
add("")
add("</details>")
add("")
add("## 第二部分:WorkBuddy-Bench(metacodes + glm-5.2,基线配置)")
add("")
if meta["workbuddy"].get("status") == "BLOCKED":
    add(f"> **状态:BLOCKED — 本轮无有效判分。** {meta['workbuddy']['blocker']}")
    add("")
    add(f"> 已就绪:{meta['workbuddy']['prepared']}")
    add("")
tot_planned = sum(v["planned"] for v in wb["by_subset"].values())
tot_graded = sum(v["graded"] for v in wb["by_subset"].values())
tot_pass = sum(v["full_pass"] for v in wb["by_subset"].values())
tot_reward = sum(v["reward_sum"] for v in wb["by_subset"].values())
tot_excluded = sum(v["excluded"] for v in wb["by_subset"].values())
add(f"总计:计划 {tot_planned} 题,已判分 {tot_graded} 题(未跑 {tot_excluded} 题为基建原因,按未尝试列出),mean reward(判分题)**{(tot_reward / tot_graded if tot_graded else 0):.3f}**,"
    f"full pass(reward=1)**{tot_pass}**({pct(tot_pass / tot_graded) if tot_graded else '—'} of graded;{pct(tot_pass / tot_planned) if tot_planned else '—'} of planned),"
    f"provider 计费 ${sum(v['cost'] for v in wb['by_subset'].values()):.2f}(actor 侧;Office/Web 的 judge 调用另计)。")
add("")
add("| 子集 | 计划 | 已判分 | 未跑(基建) | mean reward(判分题) | full pass | 花费 USD | output tokens |")
add("|---|---|---|---|---|---|---|---|")
for sub in ("code", "office", "security", "web"):
    v = wb["by_subset"].get(sub)
    if not v:
        continue
    mr = v["reward_sum"] / v["graded"] if v["graded"] else None
    add(f"| {sub} | {v['planned']} | {v['graded']} | {v['excluded']} | {'—' if mr is None else f'{mr:.3f}'} | {v['full_pass']} | {v['cost']:.2f} | {v['out_tok']:,} |")
add("")
add("| cohort | 计划 | 已判分 | mean reward | full pass |")
add("|---|---|---|---|---|")
for co in ("dev", "promotion_a", "promotion_b", "sealed"):
    v = wb["by_cohort"].get(co)
    if not v:
        continue
    mr = v["reward_sum"] / v["graded"] if v["graded"] else None
    add(f"| {co} | {v['planned']} | {v['graded']} | {'—' if mr is None else f'{mr:.3f}'} | {v['full_pass']} |")
add("")
add("逐 cohort(每行一笔预算交易;`authorized_failure(post_run_evidence_audit)` = 全部 trial 已跑完判分、仅门禁收据未 commit,原因见披露):")
add("")
add("| job | 子集/cohort | 计划 | 已判分 | mean | pass | 异常 | agent 用时 p50 | 收据状态 |")
add("|---|---|---|---|---|---|---|---|---|")
for slug, s in wb["per_slug"].items():
    p50 = f"{statistics.median(s['agent_s']):.0f}s" if s["agent_s"] else "—"
    rcp = s["receipt"] or {}
    rc = rcp.get("state", "—") if rcp else "—"
    if rc == "authorized_failure":
        rc = f"authorized_failure({rcp.get('failure_stage') or '?'})"
    elif rc == "committed" and rcp.get("actual_cost_usd") is not None:
        rc = f"committed ${rcp['actual_cost_usd']:.2f}"
    mr = "—" if s["mean_reward"] is None else f"{s['mean_reward']:.3f}"
    add(f"| `{slug}` | {s['subset']}/{s['cohort']}{' (diag)' if s['diagnostic'] else ''} | {s['planned']} | {s['graded']} | {mr} | {s['full_pass']} | {s['exceptions']} | {p50} | {rc} |")
add("")
na = meta["workbuddy"].get("not_attempted") or {}
for sub, info in na.items():
    items = info.get("tasks") or info.get("cohorts") or []
    tail = ("；probe " + " ".join(f"{k}={v}" for k, v in info["probe"].items())) if info.get("probe") else ""
    add(f"未跑({sub},基建原因:{info['reason']}):" + ", ".join(f"`{x}`" for x in items) + tail)
    add("")
refwb = meta["workbuddy"].get("reference_previous")
if refwb:
    add(f"参考:{refwb}")
    add("")
add("<details><summary>WorkBuddy 逐题明细</summary>")
add("")
add("| job | 任务 | reward | tests | output tok | agent s | 异常 |")
add("|---|---|---|---|---|---|---|")
for slug, s in wb["per_slug"].items():
    for r in s["rows"]:
        if r.get("exception") == "no result.json":
            continue
        tests = f"{r.get('tests_passed')}/{r.get('tests_total')}" if r.get("tests_total") else "—"
        rw = "—" if r.get("reward") is None else f"{r['reward']:.2f}"
        add(f"| `{slug.replace('metacodes-glm52-', '')}` | `{r['task']}` | {rw} | {tests} | {r.get('output_tokens') or 0:,} | {int(r['agent_s']) if r.get('agent_s') else '—'} | {r.get('exception') or ''} |")
add("")
add("</details>")
add("")
# ---------------- 第三部分:失败分析 ----------------
from collections import Counter as _Counter
add("## 第三部分:失败分析(为什么失败)")
add("")
add("本节区分三类失败:**能力性**(agent 跑完但判分低/零)、**基建性**(题目在本环境跑不起来)、**判分口径**(trial 判了分但门禁/judge 收尾另计)。前者反映 metacodes+glm-5.2 的真实短板,后两者是环境与流程约束。")
add("")
_sub_rows = defaultdict(list)   # cohorts are disjoint task sets; collect their merged rows (matches by_subset)
for _c in wb["cohorts"].values():
    _sub_rows[_c["subset"]].extend(_c["rows"])
def _bkt(x):
    if x is None: return "err"
    if x == 0: return "zero"
    if x >= 1.0: return "full"
    return "partial"

add("### 3.1 能力性失败:奖励分布")
add("")
add("| 子集 | 判分 | 0 分 | 部分(0<r<1) | 满分 | 执行异常 | mean |")
add("|---|---|---|---|---|---|---|")
for sub in ("code", "web", "office", "security"):
    rr = _sub_rows[sub]
    b = _Counter(_bkt(r.get("reward")) for r in rr)
    g = [r for r in rr if r.get("reward") is not None]
    add(f"| {sub} | {len(g)} | {b['zero']} | {b['partial']} | {b['full']} | {b['err']} | {(sum(r['reward'] for r in g)/len(g)) if g else 0:.3f} |")
add("")
def _sm(sub):
    g = [r["reward"] for r in _sub_rows[sub] if r.get("reward") is not None]
    return (sum(g)/len(g)) if g else 0.0
def _fz(sub):
    g = [r["reward"] for r in _sub_rows[sub] if r.get("reward") is not None]
    return sum(1 for x in g if x >= 1.0), sum(1 for x in g if x == 0)
_wf, _wz = _fz("web")
add(f"- **code({_sm('code'):.3f})与 web({_sm('web'):.3f}) 最强**:多数题拿部分或满分,0 分很少。code 稳在“读仓库→改结构化代码→过测试”;web 是前端/UI 生成,规则可测,**满分很多**(web 判分题里 {_wf} 题满分)。")
add(f"- **office({_sm('office'):.3f},满分极少)**:分数几乎全落在部分分区间——模型能产出“大体正确”的文档/表格,但极少拿满分,是**漏评分点**而非**做不出来**(见 3.3)。")
add(f"- **security({_sm('security'):.3f})**:此前被一个 `/workdir` 权限 bug 严重低估——修复并重跑 26 道受影响题后,均分由 0.285 抬到 {_sm('security'):.3f}、满分由 4 升到 {_fz('security')[0]}(见 3.2/3.6)。剩余短板集中在**内存破坏利用**一类。")
add("")

def _seccat(t):
    t = t.split("/")[-1]
    if t.startswith("bb-bin"): return "二进制 pwn(bb-bin)"
    if any(k in t for k in ["overflow","uaf","oob","safe-linking","parse-crash"]): return "内存破坏利用"
    if any(k in t for k in ["ssrf","cache-","ssti","cms","host-header","deception","poisoning","2fa","-import"]): return "Web/应用漏洞利用"
    if any(k in t for k in ["dll","loader","stealer","dropper","rat","sideload","rootkit","cryptominer","anti-analysis","rule-gen","yara","detect"]): return "恶意样本分析/检测规则"
    return "其他"
add("### 3.2 security:能力被三层管道缺陷压成假 0,真实短板仅剩 3 道题")
add("")
add("| 类别 | 判分 | mean | 0 分 | 满分 |")
add("|---|---|---|---|---|")
_cat = defaultdict(list)
for r in _sub_rows["security"]:
    if r.get("reward") is not None: _cat[_seccat(r["task"])].append(r["reward"])
for k in ("内存破坏利用","Web/应用漏洞利用","二进制 pwn(bb-bin)","恶意样本分析/检测规则","其他"):
    vs = _cat.get(k) or []
    if not vs: continue
    add(f"| {k} | {len(vs)} | {sum(vs)/len(vs):.3f} | {sum(1 for x in vs if x==0)} | {sum(1 for x in vs if x>=1)} |")
add("")
add("**结论(经三轮缺陷修复后的定论)**:security 子集经历了本次评测最曲折的更正。初版 0.285、称模型“会分析不会打、内存破坏利用全 0”——**完全错误**,是三层叠加的管道缺陷把能力压成 0/exception,与模型无关:")
add("")
add("1. **`/workdir` 权限**:agent 以非 root `dev` 运行,判分交付物 `/workdir/findings.json` 写不进去(约 20 题假 0);")
add("2. **`max_output_tokens=16384` 太小**:多步题第一步 `find-vuln` 的漏洞报告被截断,第一步不过线→整题被砍;")
add("3. **fresh-HOME 多步冲突**:第一步过线后,第二步 `poc-verify` 因复用同一 HOME 触发 `exit 70`,agent 秒退无输出→整题记为 exception 被剔除。")
add("")
add("逐层修复(agent 以 root 写 workdir / 上限提到 32768 / HOME 按步唯一 + trace 容错)后,security 由 **0.285 → 0.598**,能力一分未动。类别分布拉平:内存破坏利用 0.181→**0.534**、Web/应用漏洞利用 0→**0.507**、bb-bin 0.571、恶意样本分析/检测 0.626。多步内存破坏利用题拿到 0.41–0.86 的实分(nginx/fluentbit 的 PoC 步满分 1.0)。")
add("")
add("**真正的能力墙收窄到 3 道具体题**:`binutils-oob-write`(0.0)、`php-unserialize-uaf`(0.0)、`vim-tabpanel-escape`(0.048)——它们第一步在 32768 下也不过线、无截断,是 glm-5.2 确实做不出的漏洞识别。这是去除全部已知管道污染后,security 唯一稳固的能力短板。")
add("")
add("")
add("")

add("### 3.3 office:难度梯度明显,失分在“漏评分点”")
add("")
add("| 难度 | 判分 | mean | 满分 |")
add("|---|---|---|---|")
_lvl = defaultdict(list)
for r in _sub_rows["office"]:
    if r.get("reward") is None: continue
    m = re.search(r"(L[234])", r["task"]); _lvl[m.group(1) if m else "未标注"].append(r["reward"])
for k in ("L2","L3","L4","未标注"):
    vs = _lvl.get(k) or []
    if vs: add(f"| {k} | {len(vs)} | {sum(vs)/len(vs):.3f} | {sum(1 for x in vs if x>=1)} |")
add("")
add("**结论(已更正)**:L2→L3→L4 均分 0.930→0.790→0.714,仍单调下降但**梯度远比初版平缓**。初版报的是 0.93→0.70→0.49——那个陡峭断崖有相当一部分不是难度,而是 `max_tokens` 缺陷:L4 推理链更长,更容易吃满续写预算后交空答案(见 3.6)。修复后 L4 由 0.49 抬到 0.714。剩下的梯度才是真实难度效应:office 按 rubric 分项判分,模型能完成主体但常漏细项(格式、口径、边界条件),越复杂漏得越多——是**精度**问题而非做不出来。满分仍然极少(50 题仅 1 题),这一点未被修复改变。")
add("")

add("### 3.4 code:强于数据/结构化改造,弱于 bug 修复与严格契约")
add("")
_cc = defaultdict(list)
for r in _sub_rows["code"]:
    if r.get("reward") is None: continue
    _cc[r["task"].split("/")[-1].split("-")[0]].append(r["reward"])
_ccs = sorted(((k, sum(v)/len(v), len(v), sum(1 for x in v if x>=1)) for k, v in _cc.items() if len(v) >= 3), key=lambda x: x[1])
add("最弱 5 类 / 最强 5 类(n≥3):")
add("")
add("| 类别 | n | mean | 满分 | |  | 类别 | n | mean | 满分 |")
add("|---|---|---|---|---|---|---|---|---|---|")
_weak = _ccs[:5]; _strong = _ccs[::-1][:5]
for i in range(5):
    w = _weak[i]; s2 = _strong[i]
    add(f"| {w[0]} | {w[2]} | {w[1]:.3f} | {w[3]} | | | {s2[0]} | {s2[2]} | {s2[1]:.3f} | {s2[3]} |")
add("")
add("**结论**:最弱是 `bug_fix`(0.45)、`api_contract`(0.45)、`security_hardening`(0.56)——这些题要么要精确定位并**完整**修复缺陷(改一半就过不了测试),要么要求严格符合 API 契约/错误码;模型常改到“部分对”。最强是 `data_reporting`/`feature_pipeline`/`testing`/`data_quality`/`schema_behavior`(0.92–1.00)——数据处理与结构化产出类,规则明确、可测。")
add("")

add("### 3.5 FrontierChallenge:失败集中在计算化学/分子模拟")
add("")
_fcg = [r for r in fc["rows"] if r.get("evaluation_complete") == 1 and r.get("task_score") is not None]
_fb = _Counter()
for r in _fcg:
    s = r["task_score"]; _fb["满分(=1)" if s >= 1 else ("0 分" if s == 0 else ("低分(<0.5)" if s < 0.5 else "中高(0.5–1)"))] += 1
add(f"79 题判分分布:满分 {_fb['满分(=1)']}、中高(0.5–1)**{_fb['中高(0.5–1)']}**、低分(<0.5)**{_fb['低分(<0.5)']}**、0 分 {_fb['0 分']}。")
add("")
_z = sorted(r["task_id"] for r in fc["rows"] if r.get("scored_zero_missing_artifact"))
add(f"**7 题缺交付 0 分全部是计算化学/分子动力学模拟**:{', '.join('`'+z+'`' for z in _z)}。它们需要 LAMMPS / CP2K / GROMACS-MD / QM-MM / umbrella-sampling 等专业模拟工具链跑出结果文件;harness 内要么缺工具、要么模型无法驱动这条长链,最终没产出可判的交付物(计零)。另有 `task_205_umbrella_wham`(0.07)、`task_009_raman_graphene_qc`(0.09)、`task_203_qmmm_trypsin`(0.35)同属此类。**其余 61 题落在 0.5–1.0**,说明 metacodes+glm-5.2 在常规科研编程/数据分析题上是可用的,短板明确是重型数值模拟。")
add("")

add("### 3.6 基建阻塞与解决(与模型能力无关)")
add("")
add("本轮所有 260 题最终**全部跑完**。下面是曾阻塞、后解决的基建问题:")
add("")
add("| 阻塞源 | 曾经的影响 | 根因 | 解决 |")
add("|---|---|---|---|")
add("| web 全 70 题 + security 14 题(Ghidra/git) | 一度完全跑不起来 | 构建容器内 pip/git/playwright 连不上 pypi/github(国际线 18–32 KB/s;宿主 TUNA 镜像不进容器;BuildKit 只转发 proxy 变量) | **kunshan 已装 sing-box**(SOCKS5:10879,实测 2.4–6.4 MB/s);加非特权 HTTP→SOCKS 桥(172.17.0.1:4400),预构建经 `--build-arg http_proxy/https_proxy` 走该路由。仅构建期、不改 Dockerfile、不碰 agent 运行期。web 70/70、security 60/60 全部补跑完成 |")
add("| security ld-preload-investigation | 曾误判为“containerd 漂移” | 真因:egress sidecar `FROM gogost/gost@sha256:…`(Docker Hub nightly),patron 无 registry mirror | kunshan 镜像源可拉;经 sing-box 路线一并跑完 |")
add("| 两个“单-trial 异常烧整笔交易”缺陷 | office-sealed 崩 17/30、security-sealed 崩 3/24 | overlay post-run 把 被杀 agent(无 result)/ 非 UTF-8 control evidence 抛异常,穿透 harbor TaskGroup 连坐整批 | bench 侧容错(降级 0 分 trajectory / errors=replace),修复后重跑到完整;已开上游 PR |")
add("| **security `/workdir` 权限 bug(最严重)** | **26 题被误判,20 题假 0 分;security 均分被压到 0.285** | 安全题 Dockerfile 以 root 建 `WORKDIR /workdir` 且从不 chown;metacodes 让 agent 以非 root 的 `dev` 运行 → 判分交付物 `/workdir/findings.json` 写不进去。实测 22 个 0 分 trial 全部报权限错、21 个把 findings.json 写到了 `/workspace` 或 `/tmp` | adapter 在 `ensure_agent_user` 后加一次**非递归**、**fail-soft** 的 workdir 属主修复(跳过 `/tests`、`/logs/verifier`、`*/verifier`、`*/grading`、软链与路径穿越)。端到端验证 `blind-ssrf-redis-write` **0.0 → 1.0**;重跑 26 题后 security **0.285 → 0.543**、满分 4 → 12 |")
add("| **`max_output_tokens` 过小 → 静默空交付** | **12 题被误判(office 10、code 1、web 1)**;office 均分被压低 0.12、L4 梯度被夸大 | 模型配置把每次回复上限设为 16384(为 Code 子集标定后跨域继承),而 glm-5.2 在多步任务上思考量远超它;撞上限后 metacodes 等额续写 3 次仍不够,预算耗尽便**把截断轮当作正常完成**——该轮既无 text 也无 tool_use,交付物从未产生。实测受影响 trial 的 out_tok 精确聚集在 4×16384≈65k | 配置改 32768 后重跑 12 题:**10 题恢复**(0.0→0.70~1.00);另加上游修复 `7b3ad99`,让「截断且续写耗尽且无产出」成为显式终态 `max_tokens_exhausted` 而非静默成功。**2 题仍失败**(out_tok 精确吃满 4×32768≈131k),证明调大上限只是把墙挪远,根治要靠行为引导或 thinking 预算分离 |")
add("| **fresh-HOME 多步冲突 → step2 秒退** | 多步 security 题第一步过线后整题记为 exception 被剔除(≥5 题) | HOME 路径写死为 `/tmp/metacodes-workbuddy-home` 常量,一个 trial 的所有 step 共享;step1 建后不清理,step2 撞 `test ! -e $run_home ... exit 70`,agent 未启动→无 output→adapter 抛 trace 异常连坐整题 | adapter 把 HOME 按步唯一化(`sha256(logs_dir+instruction)`,因 harbor 多步复用同一 logs_dir,需折入每步不同的 instruction);trace 缺失并入容错。重跑:nginx/fluentbit exception→**0.864**、curl→0.752、jq→0.707、junrar→0.409;security **0.543→0.598** |")
add("")
add("**要点**:这些是**环境/网络**约束,不是 metacodes+glm-5.2 的能力短板。解决后,能力性结论(3.1–3.5)才是完整口径。sing-box 只加速构建期拉取同版本依赖,不改任务内容与运行期隔离。")
add("")
add("**方法论教训**:`/workdir` 这件事最值得记——它让一整个子域看起来像“能力墙”(某类题齐刷刷 0 分),实际是落盘管道坏了。**在 agent 评测里,某个类别整齐地全 0 是管道信号,不是能力信号**;把结论归给模型之前,先验证交付路径、运行用户、以及判分器实际读的位置。初版报告正是在这里过度自信。")
add("")
add("### 3.7 判分口径(trial 判了分,收尾另计)")
add("")
add("- **WorkBuddy 收据多为 `authorized_failure`**:Office/Web 因 verifier 侧 LLM judge 占用 job 代理全局序号、门禁 post-run 审计“序号连续”检查必失败;Security 因数据集任务名前缀是 `codebuddy/` 而审计写死 `workbuddy/`。两者**全部 trial 已跑完判分**,分数取自 harbor result.json(按方案 B),仅门禁收据未 commit。")
add("- **FrontierChallenge judge 形状事故**:官方 judge gpt-5.6-sol 约四成首轮 trial 把 `criterion_scores` 返回成 `{id:{...}}` 字典形而非数组形,触发“缺 criterion_scores 数组”;补跑轮加 FC_NORM 无损归一化 + 每重复 5 次尝试后全部判出。归一化只改容器形状不改分数/ID。")
add("")

add("## 披露清单(结果解读必读)")
add("")
for d in meta["disclosures"]:
    add(f"- {d}")
add("")
add("## 数据文件")
add("")
add("- `data/frontierchallenge/{long,mainA,mainB}.{json,csv}` — 三分片 harbor summarize 逐题明细(合并时 task_id 去重);`tasks_attempted.txt` 启动的 80 题;`reference-2026-09-01/` 上轮同 judge 的逐题数据副本(仅供对照)")
add("- `data/workbuddy/trials.json` — 各主机 harbor 结果的有界派生行(collect_results.py);`plan.json` 冻结 cohort 计划;`receipts.json` 门禁收据摘要")
add("- `data/meta.json` — 环境、版本、判分配置、披露与时间线")
add(f"- 原始 trial 产物(transcript/verifier 日志/proxy 审计)留在各主机:{meta['raw_artifact_locations']}")
add("")
(HERE / "report.md").write_text("\n".join(L), encoding="utf-8")
print(f"report.md written: {len(L)} lines")
