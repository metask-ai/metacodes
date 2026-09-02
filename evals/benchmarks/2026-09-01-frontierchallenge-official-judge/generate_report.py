#!/usr/bin/env python3
"""Generate report.md from data/ (shard summaries + meta). Do not hand-edit report."""
import json, glob, statistics
from pathlib import Path
HERE = Path(__file__).resolve().parent
meta = json.loads((HERE/"data/meta.json").read_text())
rows = []
for f in sorted(glob.glob(str(HERE/"data/run-metacodes-oj/*.json"))):
    rows += json.load(open(f))["rows"]
seen = {}
for r in rows: seen[r["task_id"]] = r
rows = list(seen.values())
graded = [r for r in rows if r.get("task_score") is not None and r.get("evaluation_complete") == 1]
passed = sum(1 for r in graded if r.get("passed") == 1)
tot = sum(r["task_score"] for r in graded)
sc = sorted(r["task_score"] for r in graded)
dist = [0]*5
for x in sc: dist[min(4, int(x*5))] += 1
res = [(r["task_id"], str(r.get("error") or "")) for r in rows if r.get("evaluation_complete") == 0 or r.get("error")]
L = []
L.append(f"# 评测报告:{meta['round']}\n")
L.append("> 本文件由 generate_report.py 从 data/ 生成,请勿手改。\n")
s = meta["system_under_test"]; j = meta["judge"]
L.append(f"- 被测系统:**{s['scaffold']}** @ `{s['commit'][:12]}` × {s['model']}")
L.append(f"- Judge:**{j['model']}** ×{j['repeats']}(定义内配置,可对标官方)")
L.append(f"- 拓扑:patron {meta['topology']['patron']};kunshan {meta['topology']['kunshan']}\n")
L.append("## 结果\n")
L.append("| 指标 | 值 |\n|---|---|")
L.append(f"| 判分题数 | {len(graded)}(present {len(rows)}/80) |")
L.append(f"| Pass Rate(判分) | **{passed}/{len(graded)} = {passed/len(graded):.1%}** |")
L.append(f"| Mean Score(判分) | **{100*tot/len(graded):.1f} / 100** |")
L.append(f"| 中位分 | {statistics.median(sc):.3f} |")
L.append(f"| Pass Rate(官方 97 分母) | {passed/97:.1%} |")
L.append(f"| Score(官方 97 分母) | {100*tot/97:.1f} |")
L.append(f"| Pass Rate(开放 81) | {passed/81:.1%} |\n")
L.append("分布(0.2 分档):" + " / ".join(str(x) for x in dist) + "\n")
L.append("## 残差\n")
for t, e in sorted(res):
    tag = "genuine-0" if "genuine" in e else "judge-flake/infra(计零)"
    L.append(f"- `{t}` — {tag}")
L.append("\n## 披露\n")
for d in meta["disclosures"]:
    L.append(f"- {d}")
L.append("\n## 参照轮\n")
for k, v in meta["reference_rounds"].items():
    L.append(f"- {k}:{v}")
L.append("")
(HERE/"report.md").write_text("\n".join(L), encoding="utf-8")
print("report.md:", len(L), "lines")
