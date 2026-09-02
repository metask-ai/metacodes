#!/usr/bin/env python3
"""Generate report.md for this benchmark round from the files under data/.

Everything in the report is computed from data/ (summary.json of both harbor
jobs, olympiad results.json, meta.json). Re-run after changing data:

    python3 generate_report.py
"""
from __future__ import annotations

import json
import statistics
from pathlib import Path

HERE = Path(__file__).resolve().parent
DATA = HERE / "data"

meta = json.loads((DATA / "meta.json").read_text())
cc = json.loads((DATA / "run-claude-code" / "summary.json").read_text())
mc = json.loads((DATA / "run-metacodes" / "summary.json").read_text())
oly = json.loads((DATA / "olympiad-glm52" / "results.json").read_text())

DEN_OFFICIAL = meta["benchmark"]["official_denominator"]
DEN_OPEN = meta["benchmark"]["open_track_tasks"]


def graded_rows(s: dict) -> list[dict]:
    return [r for r in s["rows"] if r.get("task_score") is not None
            and r.get("evaluation_complete") == 1]


def metrics(s: dict) -> dict:
    rows = graded_rows(s)
    scores = sorted(r["task_score"] for r in rows)
    passed = sum(1 for r in rows if r.get("passed") == 1)
    total_score = sum(scores)
    dist = [0] * 5
    for x in scores:
        dist[min(4, int(x * 5))] += 1
    zeros_artifact = [r["task_id"] for r in s["rows"]
                      if r.get("scored_zero_missing_artifact")]
    unresolved = [r["task_id"] for r in s["rows"]
                  if r.get("evaluation_complete") == 0
                  and not r.get("scored_zero_missing_artifact")
                  or (r.get("error") and "no reward" in str(r["error"]))]
    return {
        "graded": len(rows), "passed": passed,
        "pass_graded": passed / len(rows),
        "mean_graded": 100 * total_score / len(rows),
        "median": statistics.median(scores),
        "pass_97": passed / DEN_OFFICIAL,
        "score_97": 100 * total_score / DEN_OFFICIAL,
        "pass_open": passed / DEN_OPEN,
        "score_open": 100 * total_score / DEN_OPEN,
        "dist": dist,
        "zeros_artifact": sorted(set(zeros_artifact)),
        "unresolved": sorted(set(unresolved)),
    }


m_cc, m_mc = metrics(cc), metrics(mc)

cc_by = {r["task_id"]: r for r in cc["rows"]}
mc_by = {r["task_id"]: r for r in mc["rows"]}
common = [t for t in cc_by
          if t in mc_by
          and cc_by[t].get("task_score") is not None
          and mc_by[t].get("task_score") is not None
          and cc_by[t].get("evaluation_complete") == 1
          and mc_by[t].get("evaluation_complete") == 1]
agree = sum(1 for t in common
            if (cc_by[t]["passed"] == 1) == (mc_by[t]["passed"] == 1))
diffs = sorted(common,
               key=lambda t: mc_by[t]["task_score"] - cc_by[t]["task_score"])

oly_rows = oly["rows"]
oly_correct = sum(1 for r in oly_rows if r["is_correct"])
oly_durs = sorted(r["duration_seconds"] for r in oly_rows)


def pct(x: float) -> str:
    return f"{100 * x:.1f}%"


def task_row(t: str) -> str:
    return (f"| `{t}` | {cc_by[t]['task_score']:.2f} | "
            f"{mc_by[t]['task_score']:.2f} | "
            f"{mc_by[t]['task_score'] - cc_by[t]['task_score']:+.2f} |")


L: list[str] = []
add = L.append
add(f"# 评测报告:{meta['round']}")
add("")
add(f"> 本文件由 `generate_report.py` 从 `data/` 自动生成,请勿手改。")
add("")
add("## 概要")
add("")
add(f"- **基准**: {meta['benchmark']['name']}(open 赛道,官方分母 {DEN_OFFICIAL},"
    f"开放赛道 {DEN_OPEN} 题,实跑 {meta['benchmark']['tasks_attempted']} 题)")
add(f"- **模型**: {meta['model']['id']} @ {meta['model']['gateway']}"
    f"({meta['model']['protocol']})")
add(f"- **Judge**: {meta['judge']['model']} ×{meta['judge']['repeats']}"
    f"(官方 pin:{meta['judge']['official_pinned']};{meta['judge']['comparability']})")
add(f"- **对照设计**: 同机({meta['host']['name']})、同题、同模型、同 judge、"
    f"同补丁与限时,仅 scaffold 不同")
add("")
add("## 主结果")
add("")
add("| 指标 | claude-code + glm-5.2 | metacodes + glm-5.2 |")
add("|---|---|---|")
sc_cc = meta["scaffolds"]["claude-code"]
sc_mc = meta["scaffolds"]["metacodes"]
add(f"| scaffold 版本 | {sc_cc['version']} | main@{sc_mc['commit']} |")
add(f"| 有效判分题数 | {m_cc['graded']} | {m_mc['graded']} |")
add(f"| 通过数 | {m_cc['passed']} | {m_mc['passed']} |")
add(f"| Pass Rate(判分口径) | **{pct(m_cc['pass_graded'])}** | **{pct(m_mc['pass_graded'])}** |")
add(f"| Mean Score(判分口径) | **{m_cc['mean_graded']:.1f}** | **{m_mc['mean_graded']:.1f}** |")
add(f"| 中位分 | {m_cc['median']:.3f} | {m_mc['median']:.3f} |")
add(f"| Pass Rate(官方 {DEN_OFFICIAL} 分母) | {pct(m_cc['pass_97'])} | {pct(m_mc['pass_97'])} |")
add(f"| Score(官方 {DEN_OFFICIAL} 分母) | {m_cc['score_97']:.1f} | {m_mc['score_97']:.1f} |")
add(f"| Pass Rate(开放赛道 {DEN_OPEN}) | {pct(m_cc['pass_open'])} | {pct(m_mc['pass_open'])} |")
add("")
add("分数分布(判分题,按 0.2 分档):")
add("")
add("| 区间 | 0–0.2 | 0.2–0.4 | 0.4–0.6 | 0.6–0.8 | 0.8–1.0 |")
add("|---|---|---|---|---|---|")
add("| claude-code | " + " | ".join(str(x) for x in m_cc["dist"]) + " |")
add("| metacodes | " + " | ".join(str(x) for x in m_mc["dist"]) + " |")
add("")
add("## 逐题对照")
add("")
add(f"共同判分 {len(common)} 题,通过判定一致 {agree} 题"
    f"({pct(agree / len(common))})。分歧最大者:")
add("")
add("**metacodes 明显落后**(多为缺交付归零):")
add("")
add("| 任务 | claude-code | metacodes | Δ |")
add("|---|---|---|---|")
for t in diffs[:6]:
    add(task_row(t))
add("")
add("**metacodes 明显领先**(MD/计算化学簇):")
add("")
add("| 任务 | claude-code | metacodes | Δ |")
add("|---|---|---|---|")
for t in diffs[-6:]:
    add(task_row(t))
add("")
add("## 零分与残差明细")
add("")
for label, m, s in (("claude-code", m_cc, cc), ("metacodes", m_mc, mc)):
    add(f"**{label}** — 缺交付零分 {len(m['zeros_artifact'])} 题"
        f",不可判残差 {len(m['unresolved'])} 题:")
    add("")
    for t in m["zeros_artifact"]:
        add(f"- 缺交付(genuine 0):`{t}`")
    for t in m["unresolved"]:
        add(f"- 不可判(harness/verifier,按官方口径计零):`{t}`")
    add("")
add("## 结构性结论")
add("")
mc_only_zero = set(m_mc["zeros_artifact"]) - set(m_cc["zeros_artifact"])
cc_only_zero = set(m_cc["zeros_artifact"]) - set(m_mc["zeros_artifact"])
add(f"- 两 scaffold 交付纪律互补:claude-code 独有缺交付 {len(cc_only_zero)} 题,"
    f"metacodes 独有 {len(mc_only_zero)} 题——差距主要不在解题力,"
    "而在是否把任务规定的 deliverables 完整写入 `/app/output`。")
add("- metacodes 在分子动力学/计算化学工作流上系统性占优;"
    "在部分分析化学/晶体学任务上因漏交文件归零。")
add("")
add("## 附:FrontierScience-Olympiad(同模型,public harness)")
add("")
add(f"- 题数 {oly['n']},判对 {oly_correct}"
    f"(当前数据为重试后状态 {pct(oly_correct / oly['n'])};"
    f"首跑口径 {pct(meta['olympiad_context']['first_run_accuracy'])},"
    f"重试策略见 meta.json)")
add(f"- 单题时长 p50 = {oly_durs[len(oly_durs) // 2]:.0f}s,"
    f"最长 {oly_durs[-1]:.0f}s;无答案题 "
    f"{sum(1 for r in oly_rows if r['predicted_empty'])} 题")
add("")
add("## 披露清单(结果解读必读)")
add("")
add(f"- 任务镜像:{meta['benchmark']['image']['modification']}")
for p in meta["grader_wrapper_patches"]:
    add(f"- grader 包装补丁:{p}")
add(f"- 重跑纪律:{meta['rerun_policy']}")
for e in meta["benchmark"]["excluded"]:
    add(f"- 剔除:`{e['task']}` — {e['reason']}")
add(f"- Judge 传输层:{meta['judge']['transport']}")
add(f"- 网络:{meta['network_notes']}")
add("")
add("## 数据文件")
add("")
add("- `data/run-claude-code/summary.{json,csv}` — claude-code 全量逐题明细")
add("- `data/run-metacodes/summary.{json,csv}` — metacodes 全量逐题明细")
add("- `data/olympiad-glm52/results.json` — olympiad 逐题明细")
add("- `data/meta.json` — 环境、版本、判分配置、披露与时间线")
add(f"- 原始 trial 产物(transcript/verifier 日志)在 {meta['host']['name']}:"
    "`~/frontier-bench/FrontierAgent/benchmarks/frontierchallenge/results/harbor/`")
add("")

(HERE / "report.md").write_text("\n".join(L), encoding="utf-8")
print(f"report.md written: {len(L)} lines")
