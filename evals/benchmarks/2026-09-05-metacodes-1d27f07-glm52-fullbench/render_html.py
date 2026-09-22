#!/usr/bin/env python3
"""Render the round's data/ into a self-contained HTML page (companion to report.md)."""
import json, statistics, html
from pathlib import Path

R = Path(__file__).resolve().parent
D = R / "data"
meta = json.loads((D / "meta.json").read_text())
rows = {}
for f in sorted((D / "frontierchallenge").glob("*.json")):
    for r in json.loads(f.read_text())["rows"]:
        rows[r["task_id"]] = r
ref = {}
for f in sorted((D / "frontierchallenge" / "reference-2026-09-01").glob("*.json")):
    for r in json.loads(f.read_text())["rows"]:
        ref[r["task_id"]] = r
attempted = [l.strip() for l in (D / "frontierchallenge" / "tasks_attempted.txt").read_text().splitlines() if l.strip()]
graded = [r for r in rows.values() if r.get("evaluation_complete") == 1 and r.get("task_score") is not None]
scores = sorted(r["task_score"] for r in graded)
passed = sum(1 for r in graded if r.get("passed") == 1)
tot = sum(scores)
den97, den81 = 97, 81
dist = [0] * 5
for x in scores:
    dist[min(4, int(x * 5))] += 1
zeros = sorted(r["task_id"] for r in rows.values() if r.get("scored_zero_missing_artifact"))
absent = [t for t in attempted if not any(i == t or i.startswith(t) or t.startswith(i) for i in rows)]
common = [t for t in rows if t in ref and rows[t].get("evaluation_complete") == 1 and ref[t].get("evaluation_complete") == 1]
deltas = sorted(common, key=lambda t: rows[t]["task_score"] - ref[t]["task_score"])
agree = sum(1 for t in common if (rows[t].get("passed") == 1) == (ref[t].get("passed") == 1))
refm = meta["frontierchallenge"]["reference_previous_round"]
wb_receipts = json.loads((D / "workbuddy" / "receipts.json").read_text())
plan = json.loads((D / "workbuddy" / "plan.json").read_text())
wb_trials = json.loads((D / "workbuddy" / "trials.json").read_text())

def wb_metrics():
    cohorts = {}
    for p_ in plan:
        key = (p_["subset"], p_["cohort"])
        c = cohorts.setdefault(key, {"subset": p_["subset"], "cohort": p_["cohort"], "planned": None, "excluded": [], "slugs": []})
        if p_.get("diagnostic"):
            c["excluded"] = list(p_.get("excluded") or [])
        else:
            c["planned"] = p_["n"]
        c["slugs"].append(p_["slug"])
    per = {}
    for p_ in plan:
        slug = p_["slug"]; rws = wb_trials.get(slug, {}).get("trials", [])
        if not rws and slug not in wb_receipts: continue
        bt = {}
        for r in rws: bt[r["task"]] = r
        rws = list(bt.values())
        g = [r for r in rws if r.get("reward") is not None]
        per[slug] = {"subset": p_["subset"], "cohort": p_["cohort"], "planned": p_["n"], "diag": bool(p_.get("diagnostic")),
                     "graded": len(g), "mean": (sum(r["reward"] for r in g)/len(g)) if g else None,
                     "pass": sum(1 for r in g if r["reward"] >= 1.0),
                     "exc": sum(1 for r in rws if r.get("exception") and r.get("exception") != "no result.json"),
                     "cost": sum(r.get("cost_usd") or 0 for r in rws), "out_tok": sum(r.get("output_tokens") or 0 for r in rws),
                     "receipt": wb_receipts.get(slug)}
    for c in cohorts.values():
        merged = {}
        for slug in c["slugs"]:
            for r in wb_trials.get(slug, {}).get("trials", []): merged[r["task"]] = r
        rws = list(merged.values()); g = [r for r in rws if r.get("reward") is not None]
        c["graded"] = len(g); c["reward_sum"] = sum(r["reward"] for r in g); c["full_pass"] = sum(1 for r in g if r["reward"]>=1.0)
        c["cost"] = sum(r.get("cost_usd") or 0 for r in rws); c["out_tok"] = sum(r.get("output_tokens") or 0 for r in rws)
    from collections import defaultdict as _dd
    bs = _dd(lambda: {"planned":0,"graded":0,"reward_sum":0.0,"full_pass":0,"cost":0.0,"out_tok":0,"excluded":0})
    bc = _dd(lambda: {"planned":0,"graded":0,"reward_sum":0.0,"full_pass":0})
    for c in cohorts.values():
        for agg in (bs[c["subset"]], bc[c["cohort"]]):
            agg["planned"] += c["planned"] or 0; agg["graded"] += c["graded"]; agg["reward_sum"] += c["reward_sum"]; agg["full_pass"] += c["full_pass"]
        bs[c["subset"]]["cost"] += c["cost"]; bs[c["subset"]]["out_tok"] += c["out_tok"]; bs[c["subset"]]["excluded"] += len(c["excluded"])
    return {"per": per, "cohorts": cohorts, "by_subset": dict(bs), "by_cohort": dict(bc)}

WB = wb_metrics()
SUBORDER = ["code","office","security","web"]
wb_graded_total = sum(v["graded"] for v in WB["by_subset"].values())
wb_planned_total = sum(v["planned"] for v in WB["by_subset"].values())
wb_reward_sum = sum(v["reward_sum"] for v in WB["by_subset"].values())
wb_pass_total = sum(v["full_pass"] for v in WB["by_subset"].values())
wb_cost_total = sum(v["cost"] for v in WB["by_subset"].values())

# ---- failure-analysis data (cohort-merged rows per subset; matches report.md) ----
from collections import defaultdict as _dd2
_subco = {pp["slug"]: (pp["subset"], pp["cohort"]) for pp in plan}
_cohort_rows = _dd2(dict)
for _slug, _v in wb_trials.items():
    _k = _subco.get(_slug)
    if not _k: continue
    for _r in _v.get("trials", []):
        _cohort_rows[_k][_r["task"]] = _r
_SR = _dd2(list)
for _k, _d in _cohort_rows.items():
    _SR[_k[0]].extend(_d.values())

def _bkt(x):
    if x is None: return "err"
    if x == 0: return "zero"
    if x >= 1.0: return "full"
    return "partial"

def fa_dist_rows():
    tr = []
    for sub in ("code", "web", "office", "security"):
        rr = _SR[sub]; b = {"zero":0,"partial":0,"full":0,"err":0}
        for r in rr: b[_bkt(r.get("reward"))] += 1
        g = [r for r in rr if r.get("reward") is not None]
        m = sum(r["reward"] for r in g)/len(g) if g else 0
        tr.append(f'<tr><td><b>{sub}</b></td><td class="num">{len(g)}</td><td class="num">{b["zero"]}</td><td class="num">{b["partial"]}</td><td class="num">{b["full"]}</td><td class="num">{b["err"]}</td><td class="num">{m:.3f}</td></tr>')
    return "".join(tr)

def _seccat(t):
    t=t.split("/")[-1]
    if t.startswith("bb-bin"): return "二进制 pwn"
    if any(k in t for k in ["overflow","uaf","oob","safe-linking","parse-crash"]): return "内存破坏利用"
    if any(k in t for k in ["ssrf","cache-","ssti","cms","host-header","deception","poisoning","2fa","-import"]): return "Web/应用漏洞利用"
    if any(k in t for k in ["dll","loader","stealer","dropper","rat","sideload","rootkit","cryptominer","anti-analysis","rule-gen","yara","detect"]): return "恶意样本分析/检测"
    return "其他"

def fa_sec_rows():
    cat=_dd2(list)
    for r in _SR["security"]:
        if r.get("reward") is not None: cat[_seccat(r["task"])].append(r["reward"])
    tr=[]
    for k in ("内存破坏利用","Web/应用漏洞利用","二进制 pwn","恶意样本分析/检测","其他"):
        vs=cat.get(k) or []
        if not vs: continue
        cls=' class="zero"' if sum(vs)/len(vs)==0 else ""
        tr.append(f'<tr{cls}><td>{k}</td><td class="num">{len(vs)}</td><td class="num">{sum(vs)/len(vs):.3f}</td><td class="num">{sum(1 for x in vs if x==0)}</td><td class="num">{sum(1 for x in vs if x>=1)}</td></tr>')
    return "".join(tr)

def fa_office_rows():
    import re as _re2
    lvl=_dd2(list)
    for r in _SR["office"]:
        if r.get("reward") is None: continue
        m=_re2.search(r"(L[234])", r["task"]); lvl[m.group(1) if m else "未标注"].append(r["reward"])
    tr=[]
    for k in ("L2","L3","L4","未标注"):
        vs=lvl.get(k) or []
        if vs: tr.append(f'<tr><td>{k}</td><td class="num">{len(vs)}</td><td class="num">{sum(vs)/len(vs):.3f}</td><td class="num">{sum(1 for x in vs if x>=1)}</td></tr>')
    return "".join(tr)

def fa_code_rows():
    cc=_dd2(list)
    for r in _SR["code"]:
        if r.get("reward") is None: continue
        cc[r["task"].split("/")[-1].split("-")[0]].append(r["reward"])
    ccs=sorted(((k,sum(v)/len(v),len(v),sum(1 for x in v if x>=1)) for k,v in cc.items() if len(v)>=3), key=lambda x:x[1])
    weak=ccs[:5]; strong=ccs[::-1][:5]; tr=[]
    for i in range(min(5,len(weak))):
        w=weak[i]; st=strong[i]
        tr.append(f'<tr><td class="mono">{w[0]}</td><td class="num">{w[2]}</td><td class="num">{w[1]:.3f}</td><td></td><td class="mono">{st[0]}</td><td class="num">{st[2]}</td><td class="num">{st[1]:.3f}</td></tr>')
    return "".join(tr)

def fa_fc():
    g=[r for r in graded]; b={"full":0,"mid":0,"low":0,"zero":0}
    for r in g:
        sc=r["task_score"]; b["full" if sc>=1 else ("zero" if sc==0 else ("low" if sc<0.5 else "mid"))]+=1
    return b


def pct(x): return f"{100*x:.1f}%"
def esc(s): return html.escape(str(s))

# ---- charts (inline SVG) ----
def dist_chart():
    labels = ["0–0.2", "0.2–0.4", "0.4–0.6", "0.6–0.8", "0.8–1.0"]
    W, H, pad_l, pad_b, pad_t = 520, 200, 36, 30, 14
    m = max(dist) or 1
    bw = (W - pad_l - 10) / 5
    out = [f'<svg viewBox="0 0 {W} {H}" role="img" aria-label="分数分布" class="chart">']
    for i in range(0, 5):
        y = pad_t + (H - pad_t - pad_b) * (1 - i / 4)
        v = round(m * i / 4)
        out.append(f'<line x1="{pad_l}" y1="{y:.1f}" x2="{W-10}" y2="{y:.1f}" class="grid"/><text x="{pad_l-6}" y="{y+4:.1f}" class="tick" text-anchor="end">{v}</text>')
    for i, (lab, v) in enumerate(zip(labels, dist)):
        h = (H - pad_t - pad_b) * v / m
        x = pad_l + i * bw + bw * 0.18
        y = H - pad_b - h
        cls = "bar hi" if i == 4 else "bar"
        out.append(f'<rect x="{x:.1f}" y="{y:.1f}" width="{bw*0.64:.1f}" height="{h:.1f}" class="{cls}" rx="2"/>')
        out.append(f'<text x="{x + bw*0.32:.1f}" y="{y-5:.1f}" class="val" text-anchor="middle">{v}</text>')
        out.append(f'<text x="{x + bw*0.32:.1f}" y="{H-10}" class="tick" text-anchor="middle">{lab}</text>')
    out.append("</svg>")
    return "".join(out)

def delta_chart():
    items = deltas[:6] + deltas[-6:]
    W, rowh, pad_l, pad_t = 560, 22, 250, 10
    H = pad_t + rowh * len(items) + 24
    cx = pad_l + (W - pad_l - 20) / 2
    scale = (W - pad_l - 20) / 2
    out = [f'<svg viewBox="0 0 {W} {H}" role="img" aria-label="与上轮逐题分差" class="chart">']
    for k, t in enumerate(("-1.0", "-0.5", "0", "+0.5", "+1.0")):
        x = cx + (k - 2) * scale / 2
        out.append(f'<line x1="{x:.1f}" y1="{pad_t}" x2="{x:.1f}" y2="{H-22}" class="grid"/><text x="{x:.1f}" y="{H-6}" class="tick" text-anchor="middle">{t}</text>')
    for i, t in enumerate(items):
        d = rows[t]["task_score"] - ref[t]["task_score"]
        y = pad_t + i * rowh
        x0, x1 = (cx + d * scale, cx) if d < 0 else (cx, cx + d * scale)
        out.append(f'<text x="{pad_l-8}" y="{y+15}" class="lab" text-anchor="end">{esc(t.replace("task_", "", 1)[:34])}</text>')
        out.append(f'<rect x="{x0:.1f}" y="{y+4}" width="{max(1.0, x1-x0):.1f}" height="{rowh-8}" class="{"bar neg" if d < 0 else "bar pos"}" rx="2"/>')
        out.append(f'<text x="{(x1+6) if d>=0 else (x0-6):.1f}" y="{y+15}" class="val" text-anchor="{"start" if d>=0 else "end"}">{d:+.2f}</text>')
    out.append("</svg>")
    return "".join(out)

# ---- tables ----
def task_table():
    trs = []
    for t, r in sorted(rows.items()):
        st = "graded" if r.get("evaluation_complete") == 1 else ("genuine-0" if r.get("scored_zero_missing_artifact") else "unresolved")
        sc = r.get("task_score")
        prev = ref.get(t, {}).get("task_score") if ref.get(t, {}).get("evaluation_complete") == 1 else None
        cls = "pass" if r.get("passed") == 1 else ("zero" if r.get("scored_zero_missing_artifact") else "")
        trs.append(f'<tr class="{cls}"><td class="mono">{esc(t)}</td><td class="num">{"" if sc is None else f"{sc:.2f}"}</td><td class="num">{"—" if prev is None else f"{prev:.2f}"}</td><td>{"✓" if r.get("passed")==1 else ""}</td><td class="muted">{"缺交付" if r.get("scored_zero_missing_artifact") else st}</td></tr>')
    for t in absent:
        trs.append(f'<tr class="absent"><td class="mono">{esc(t)}</td><td class="num">—</td><td class="num">—</td><td></td><td class="muted">未产出结果(计零)</td></tr>')
    return "".join(trs)

def wb_subset_chart():
    items = [(sub, WB["by_subset"][sub]) for sub in SUBORDER if sub in WB["by_subset"]]
    W, rowh, pad_l, pad_t, pad_r = 560, 34, 74, 12, 54
    H = pad_t + rowh * len(items) + 26
    x0 = pad_l; span = W - pad_l - pad_r
    out = [f'<svg viewBox="0 0 {W} {H}" role="img" aria-label="各子集 mean reward" class="chart">']
    for k in range(0, 6):
        x = x0 + span * k / 5
        out.append(f'<line x1="{x:.1f}" y1="{pad_t}" x2="{x:.1f}" y2="{H-24:.1f}" class="grid"/><text x="{x:.1f}" y="{H-8}" class="tick" text-anchor="middle">{k/5:.1f}</text>')
    for i, (sub, v) in enumerate(items):
        y = pad_t + i * rowh
        m = v["reward_sum"] / v["graded"] if v["graded"] else None
        out.append(f'<text x="{pad_l-8}" y="{y+rowh/2+4:.1f}" class="lab" text-anchor="end">{esc(sub)}</text>')
        if m is None:
            out.append(f'<text x="{x0+6}" y="{y+rowh/2+4:.1f}" class="tick">未跑(基建)</text>')
        else:
            w = span * m
            out.append(f'<rect x="{x0:.1f}" y="{y+5:.1f}" width="{max(1.0,w):.1f}" height="{rowh-12}" class="bar hi" rx="2"/>')
            out.append(f'<text x="{x0+w+6:.1f}" y="{y+rowh/2+4:.1f}" class="val" text-anchor="start">{m:.3f} · {v["graded"]}/{v["planned"]}题</text>')
    out.append("</svg>")
    return "".join(out)

def wb_subset_rows():
    trs = []
    for sub in SUBORDER:
        v = WB["by_subset"].get(sub)
        if not v: continue
        m = "—" if not v["graded"] else f'{v["reward_sum"]/v["graded"]:.3f}'
        na = v["excluded"] + (70 - 0 if sub == "web" else 0)
        naw = "70(全域)" if sub == "web" else (str(v["excluded"]) if v["excluded"] else "0")
        trs.append(f'<tr><td><b>{esc(sub)}</b></td><td class="num">{v["planned"]}</td><td class="num">{v["graded"]}</td><td class="num">{naw}</td><td class="num">{m}</td><td class="num">{v["full_pass"]}</td><td class="num">{v["cost"]:.2f}</td></tr>')
    return "".join(trs)

def wb_cohort_rows():
    order = {s["slug"]: i for i, s in enumerate(plan)}
    trs = []
    for slug in sorted(WB["per"], key=lambda k: order.get(k, 99)):
        v = WB["per"][slug]
        rc = v.get("receipt") or {}
        st = rc.get("state") or "no receipt"
        if st == "authorized_failure":
            st = f'authorized_failure({rc.get("failure_stage") or "?"})'; badge = "fail"
        elif st == "committed":
            st = f'committed ${rc.get("actual_cost_usd"):.2f}' if rc.get("actual_cost_usd") is not None else "committed"; badge = "ok"
        else:
            badge = "idle"
        m = "—" if v["mean"] is None else f'{v["mean"]:.3f}'
        name = slug.replace("metacodes-glm52-", "") + (" (diag)" if v["diag"] else "")
        trs.append(f'<tr><td class="mono">{esc(name)}</td><td>{v["subset"]}/{v["cohort"]}</td><td class="num">{v["planned"]}</td><td class="num">{v["graded"]}</td><td class="num">{m}</td><td class="num">{v["pass"]}</td><td class="num">{v["exc"] or ""}</td><td><span class="chip {badge}">{esc(st)}</span></td></tr>')
    return "".join(trs)

def wb_na_items():
    na = wb.get("not_attempted") or {}
    out = []
    for subk, info in na.items():
        items = info.get("tasks") or info.get("cohorts") or []
        pr = info.get("probe")
        tail = ("(probe " + " ".join(f"{k}={v}" for k,v in pr.items()) + ")") if pr else ""
        out.append(f'<li><b>{esc(subk)}</b> {tail}:<span class="muted"> {esc(info["reason"])}</span><br>' + ", ".join(f"<code>{esc(x)}</code>" for x in items) + "</li>")
    return "".join(out)

sut = meta["system_under_test"]
fc = meta["frontierchallenge"]
wb = meta["workbuddy"]
disc = "".join(f"<li>{esc(d)}</li>" for d in meta["disclosures"])
mean_graded = 100 * tot / len(graded)
median = statistics.median(scores)
common_now = 100 * sum(rows[t]["task_score"] for t in common) / len(common)
common_ref = 100 * sum(ref[t]["task_score"] for t in common) / len(common)

page = f"""<title>metacodes 1d27f07 双基准评测</title>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Archivo:wght@500;600;700&family=IBM+Plex+Mono:wght@400;500&family=Noto+Sans+SC:wght@400;500;700&display=swap">
<style>
:root{{--bg:#f2f4f6;--surface:#ffffff;--ink:#17212a;--ink-2:#4d5b67;--line:#d5dbe0;--accent:#0b6e4f;--accent-ink:#0b6e4f;--warn:#a8681a;--crit:#b23a3a;--chip:#e6ebee;--pass-bg:#e8f3ee;--zero-bg:#f7e9e9;--grid:#dfe4e8}}
@media (prefers-color-scheme: dark){{:root:not([data-theme="light"]){{--bg:#0f151a;--surface:#161e25;--ink:#e6ebef;--ink-2:#9aa8b3;--line:#2a353e;--accent:#4fc39a;--accent-ink:#4fc39a;--warn:#d9a252;--crit:#e07272;--chip:#233039;--pass-bg:#16302a;--zero-bg:#3a2222;--grid:#243039}}}}
:root[data-theme="dark"]{{--bg:#0f151a;--surface:#161e25;--ink:#e6ebef;--ink-2:#9aa8b3;--line:#2a353e;--accent:#4fc39a;--accent-ink:#4fc39a;--warn:#d9a252;--crit:#e07272;--chip:#233039;--pass-bg:#16302a;--zero-bg:#3a2222;--grid:#243039}}
body{{background:var(--bg);color:var(--ink);font-family:"Noto Sans SC","PingFang SC","Hiragino Sans GB","Microsoft YaHei",system-ui,sans-serif;font-size:15px;line-height:1.65;margin:0}}
.wrap{{max-width:1040px;margin:0 auto;padding:40px 28px 80px}}
h1,h2,h3{{font-family:Archivo,"Noto Sans SC",system-ui,sans-serif;text-wrap:balance;letter-spacing:-0.01em;line-height:1.2}}
h1{{font-size:34px;font-weight:700;margin:0 0 6px}}
h2{{font-size:22px;font-weight:600;margin:52px 0 14px;padding-top:18px;border-top:1px solid var(--line)}}
h3{{font-size:17px;font-weight:600;margin:28px 0 10px}}
.eyebrow{{font-family:"IBM Plex Mono",monospace;font-size:12px;letter-spacing:.08em;text-transform:uppercase;color:var(--ink-2)}}
.lede{{color:var(--ink-2);max-width:70ch;margin:8px 0 0}}
.mono{{font-family:"IBM Plex Mono",ui-monospace,monospace;font-size:13px}}
.num{{font-family:"IBM Plex Mono",ui-monospace,monospace;font-variant-numeric:tabular-nums;text-align:right}}
.muted{{color:var(--ink-2)}}
.stats{{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:12px;margin:26px 0 8px}}
.stat{{background:var(--surface);border:1px solid var(--line);padding:14px 16px 12px;border-radius:6px}}
.stat .k{{font-family:"IBM Plex Mono",monospace;font-size:11px;letter-spacing:.06em;text-transform:uppercase;color:var(--ink-2)}}
.stat .v{{font-family:Archivo,system-ui,sans-serif;font-size:30px;font-weight:700;line-height:1.1;margin-top:6px;font-variant-numeric:tabular-nums}}
.stat .s{{font-size:12px;color:var(--ink-2);margin-top:4px}}
.stat.blocked .v{{color:var(--crit);font-size:22px}}
table{{border-collapse:collapse;width:100%;font-size:14px;background:var(--surface);border:1px solid var(--line)}}
th{{text-align:left;font-weight:600;font-size:12px;letter-spacing:.04em;text-transform:uppercase;color:var(--ink-2);padding:9px 12px;border-bottom:1px solid var(--line);background:color-mix(in srgb,var(--surface) 92%,var(--ink))}}
td{{padding:7px 12px;border-bottom:1px solid var(--line);vertical-align:top}}
tr:last-child td{{border-bottom:0}}
th.num{{text-align:right}}
tr.pass td:nth-child(4){{color:var(--accent-ink);font-weight:700}}
tr.zero td{{background:var(--zero-bg)}}
tr.absent td{{background:var(--zero-bg)}}
.tablewrap{{overflow-x:auto;margin:10px 0}}
.two{{display:grid;grid-template-columns:1fr 1fr;gap:20px;align-items:start}}
@media (max-width:760px){{.two{{grid-template-columns:1fr}}}}
.chart{{width:100%;height:auto;display:block}}
.chart .grid{{stroke:var(--grid);stroke-width:1}}
.chart .bar{{fill:color-mix(in srgb,var(--accent) 45%,var(--surface))}}
.chart .bar.hi{{fill:var(--accent)}}
.chart .bar.pos{{fill:var(--accent)}}
.chart .bar.neg{{fill:var(--crit)}}
.chart .tick{{font:11px "IBM Plex Mono",monospace;fill:var(--ink-2)}}
.chart .lab{{font:11px "IBM Plex Mono",monospace;fill:var(--ink)}}
.chart .val{{font:11px "IBM Plex Mono",monospace;fill:var(--ink)}}
.panel{{background:var(--surface);border:1px solid var(--line);border-radius:6px;padding:16px 18px}}
.panel.blocked{{border-left:4px solid var(--crit)}}
.chip{{display:inline-block;font-family:"IBM Plex Mono",monospace;font-size:12px;padding:2px 8px;border-radius:3px;background:var(--chip)}}
.chip.fail{{background:var(--zero-bg);color:var(--crit)}}
.chip.ok{{background:var(--pass-bg);color:var(--accent-ink)}}
.disc li{{margin:6px 0;max-width:90ch}}
details{{margin:12px 0}} summary{{cursor:pointer;color:var(--ink-2);font-size:14px}}
code{{font-family:"IBM Plex Mono",monospace;font-size:13px;background:var(--chip);padding:1px 5px;border-radius:3px}}
a{{color:var(--accent-ink)}}
:focus-visible{{outline:2px solid var(--accent);outline-offset:2px}}
</style>
<div class="wrap">
<div class="eyebrow">metacodes · evals/benchmarks · {esc(meta['round'])}</div>
<h1>metacodes <span class="mono" style="font-size:24px">main@{esc(sut['commit'][:7])}</span> × glm-5.2 双基准评测</h1>
<p class="lede">FrontierChallenge(open 赛道,官方 judge gpt-5.6-sol ×3)双机跑完;WorkBuddy-Bench 四域 260 题全部跑完(Web 与 Security 的 GitHub/Ghidra 任务经 sing-box 解决网络后补齐;security 另修复 <code>/workdir</code> 权限缺陷并重跑 26 题)。单臂基线口径。所有数字由 <code>data/</code> 计算得出;判分口径与披露清单见页尾。</p>

<div class="stats">
  <div class="stat"><div class="k">FC · Pass Rate(判分口径)</div><div class="v">{pct(passed/len(graded))}</div><div class="s">{passed} / {len(graded)} 题通过;上轮 {pct(refm['pass_graded'])}</div></div>
  <div class="stat"><div class="k">FC · Mean Score(判分口径)</div><div class="v">{mean_graded:.1f}</div><div class="s">中位 {median:.3f};上轮 {refm['mean_graded_100']:.1f}</div></div>
  <div class="stat"><div class="k">FC · 官方 97 分母</div><div class="v">{100*tot/den97:.1f}</div><div class="s">Pass {pct(passed/den97)};上轮 {refm['score_97_100']:.1f} / {pct(refm['pass_97'])}</div></div>
  <div class="stat"><div class="k">FC · 判分覆盖</div><div class="v">{len(graded)}/80</div><div class="s">上轮 {refm['graded']}/78;缺交付 {len(zeros)},未产出 {len(absent)}</div></div>
  <div class="stat"><div class="k">WorkBuddy · mean reward(判分)</div><div class="v">{wb_reward_sum/wb_graded_total:.3f}</div><div class="s">{wb_graded_total}/{wb_planned_total} 判分 · full pass {wb_pass_total} · 计费 ${wb_cost_total:.0f}</div></div>
</div>

<h2>一、FrontierChallenge</h2>
<p>被测:metacodes 无头模式(<code>-p</code>,bypassPermissions)+ glm-5.2 @ napi 网关;判分:{esc(fc['judge']['model'])} ×{fc['judge']['repeats']},官方 pin;拓扑:{esc(fc['topology'])}。启动 {len(attempted)} 题(task_098 因 ORCA 许可剔除),产出结果 {len(rows)} 题,全部完成判分。补跑轮:long 1 / mainA 1 / mainB 2,只重跑 verifier/harness 基建失败。</p>
<div class="two">
  <div class="panel"><h3 style="margin-top:0">分数分布(判分题,0.2 分档)</h3>{dist_chart()}</div>
  <div class="panel"><h3 style="margin-top:0">与上轮同 judge 逐题分差(最大 6 降 / 6 升)</h3>{delta_chart()}<p class="muted" style="font-size:13px;margin:8px 0 0">共同判分 {len(common)} 题,通过判定一致 {agree} 题({pct(agree/len(common))});共同题均分 {common_now:.1f} vs {common_ref:.1f}。单题分差含采样噪声,只作方向性证据。</p></div>
</div>

<h3>残差</h3>
<ul>
<li><b>缺交付零分(genuine 0,保留原判)</b> {len(zeros)} 题:{", ".join(f"<code>{esc(z)}</code>" for z in zeros)}</li>
<li><b>未产出结果(计零)</b> {len(absent)} 题:{", ".join(f"<code>{esc(a)}</code>" for a in absent)} — {esc(fc['absent_tasks'][0]['reason'])}</li>
<li><b>judge 形状事故</b>:{esc(fc['judge_shape_incident'])}</li>
</ul>
<details><summary>逐题明细({len(rows)} 题 + 未产出 {len(absent)} 题)</summary><div class="tablewrap"><table><thead><tr><th>任务</th><th class="num">本轮</th><th class="num">上轮 59dd28c</th><th>过</th><th>状态</th></tr></thead><tbody>{task_table()}</tbody></table></div></details>

<h2>二、WorkBuddy-Bench</h2>
<p>协议:pin <code>{esc(wb['workbuddy_commit'][:7])}</code>,四域 260 题按冻结 cohort 分预算交易,{esc(wb['runner'])};配置 = 单臂基线({esc(wb['arm'])});封顶 {esc(wb['caps_per_transaction'])}。总计 <b>{wb_graded_total}/{wb_planned_total}</b> 题判分,mean reward(判分题)<b>{wb_reward_sum/wb_graded_total:.3f}</b>,full pass <b>{wb_pass_total}</b>,actor 侧计费 <b>${wb_cost_total:.2f}</b>(Office/Web 的 judge 调用另计)。</p>
<div class="two">
  <div class="panel"><h3 style="margin-top:0">各子集 mean reward(判分题)</h3>{wb_subset_chart()}<p class="muted" style="font-size:13px;margin:8px 0 0">code / web 最强(web 满分尤其多);security 最低(利用类几乎全 0)。GitHub/Ghidra 与 web 曾卡在构建,已用 sing-box 解决。</p></div>
  <div class="panel"><h3 style="margin-top:0">子集汇总</h3><div class="tablewrap"><table><thead><tr><th>子集</th><th class="num">计划</th><th class="num">判分</th><th class="num">未跑</th><th class="num">mean</th><th class="num">pass</th><th class="num">$</th></tr></thead><tbody>{wb_subset_rows()}</tbody></table></div></div>
</div>
<p class="muted" style="font-size:13px"><code>authorized_failure(post_run_evidence_audit)</code> = 全部 trial 已跑完判分、仅门禁收据未 commit(Office/Web judge 序号缺口、Security 任务名前缀 <code>codebuddy/</code>);分数取自 harbor result.json。运行中修复了两个会烧掉整笔交易的单-trial 异常(被杀 agent 无 result / control-evidence 非 UTF-8),Office-sealed 与 Security-sealed 修复后各重跑一次。</p>
<div class="tablewrap"><table><thead><tr><th>job</th><th>子集/cohort</th><th class="num">计划</th><th class="num">判分</th><th class="num">mean</th><th class="num">pass</th><th class="num">异常</th><th>收据状态</th></tr></thead><tbody>{wb_cohort_rows()}</tbody></table></div>
<h3>未跑(基建原因)</h3>
<ul class="disc">{wb_na_items()}</ul>
<p class="muted">参考:{esc(wb['reference_previous'])}。</p>

<h2>三、失败分析(为什么失败)</h2>
<p class="lede" style="margin-bottom:6px">三类失败:<b>能力性</b>(agent 跑完但判分低/零,反映模型短板)、<b>基建性</b>(题目在本环境跑不起来)、<b>判分口径</b>(trial 判了分但门禁/judge 收尾另计)。</p>
<div class="two">
  <div class="panel"><h3 style="margin-top:0">奖励分布(判分题按档)</h3><div class="tablewrap"><table><thead><tr><th>子集</th><th class="num">判分</th><th class="num">0 分</th><th class="num">部分</th><th class="num">满分</th><th class="num">异常</th><th class="num">mean</th></tr></thead><tbody>{fa_dist_rows()}</tbody></table></div><p class="muted" style="font-size:13px;margin:8px 0 0">code 稳定拿部分/满分;office 几乎只拿部分分(漏评分点);security 半数 0 分。</p></div>
  <div class="panel"><h3 style="margin-top:0">security:短板只在内存破坏利用</h3><div class="tablewrap"><table><thead><tr><th>类别</th><th class="num">判分</th><th class="num">mean</th><th class="num">0 分</th><th class="num">满分</th></tr></thead><tbody>{fa_sec_rows()}</tbody></table></div><p class="muted" style="font-size:13px;margin:8px 0 0"><b>已更正</b>:初版“11 题全 0、模型不会打”系 <code>/workdir</code> 权限 bug 的假象(交付物写不进判分路径)。修复重跑后 Web/应用漏洞利用 0→<b>0.507</b>(2 题满分);真实短板只剩内存破坏利用(0.181)。</p></div>
</div>
<div class="two">
  <div class="panel"><h3 style="margin-top:0">office:难度梯度</h3><div class="tablewrap"><table><thead><tr><th>难度</th><th class="num">判分</th><th class="num">mean</th><th class="num">满分</th></tr></thead><tbody>{fa_office_rows()}</tbody></table></div><p class="muted" style="font-size:13px;margin:8px 0 0"><b>已更正</b>:实际是 0.930→0.790→0.714,梯度比初版平缓得多。初版的 0.93→0.70→0.49 有相当部分不是难度,而是 <code>max_output_tokens</code> 缺陷(L4 推理更长、更易吃满续写预算后交空答案);修复后 L4 由 0.49 抬到 0.714。满分仍极少(50 题仅 1 题)。</p></div>
  <div class="panel"><h3 style="margin-top:0">code:最弱 / 最强(n≥3)</h3><div class="tablewrap"><table><thead><tr><th>弱类</th><th class="num">n</th><th class="num">mean</th><th></th><th>强类</th><th class="num">n</th><th class="num">mean</th></tr></thead><tbody>{fa_code_rows()}</tbody></table></div><p class="muted" style="font-size:13px;margin:8px 0 0">弱:bug 修复、严格 API 契约、安全加固(常“改一半”过不了测试);强:数据处理/模式/测试类(规则明确可测)。</p></div>
</div>
<h3>FrontierChallenge:失败集中在计算化学/分子模拟</h3>
<p>79 题判分:满分 {fa_fc()['full']}、中高(0.5–1)<b>{fa_fc()['mid']}</b>、低分(&lt;0.5)<b>{fa_fc()['low']}</b>、0 分 {fa_fc()['zero']}。<b>7 题缺交付 0 分全部是计算化学/分子动力学模拟</b>(LAMMPS / CP2K / GROMACS-MD / QM-MM / umbrella-sampling):{", ".join(f"<code>{esc(z)}</code>" for z in zeros)} —— 需专业模拟工具链跑出结果文件,harness 内缺工具或模型无法驱动长链,最终无可判交付物。其余 61 题落在 0.5–1.0,短板明确是重型数值模拟。</p>
<h3>基建阻塞与解决(与模型能力无关)</h3>
<p class="muted" style="font-size:13px">260 题最终<b>全部跑完</b>。以下为曾阻塞、后解决的基建问题。</p>
<div class="tablewrap"><table><thead><tr><th>阻塞源</th><th>曾经的影响</th><th>根因</th><th>解决</th></tr></thead><tbody>
<tr><td class="mono">web 70 + security 14(Ghidra/git)</td><td>一度完全跑不起来</td><td>构建容器 pip/git/playwright 连不上 pypi/github(国际线 18–32 KB/s;宿主 TUNA 镜像不进容器;BuildKit 只转发 proxy 变量)</td><td><b>kunshan 已装 sing-box</b>(SOCKS5:10879,实测 2.4–6.4 MB/s);加非特权 HTTP→SOCKS 桥(172.17.0.1:4400),预构建经 <code>--build-arg http_proxy/https_proxy</code> 走该路由。仅构建期、不改 Dockerfile、不碰运行期。web 70/70、security 60/60 补齐</td></tr>
<tr><td class="mono">ld-preload-investigation</td><td>曾误判“漂移”排除</td><td>egress sidecar <code>FROM gogost/gost@sha256:…</code>(Docker Hub nightly),patron 无 registry mirror</td><td>kunshan 镜像源+sing-box 一并跑完</td></tr>
<tr><td class="mono"><b>max_output_tokens 过小</b></td><td><b>12 题误判</b>(office 10 / code 1 / web 1);office 均分压低 0.12,L4 梯度被夸大</td><td>每次回复上限 16384(为 Code 子集标定后跨域继承),glm-5.2 多步任务思考量远超;撞上限后等额续写 3 次仍不够,预算耗尽即<b>把截断轮当作正常完成</b>——无 text 无 tool_use,交付物从未产生。受影响 trial 的 out_tok 精确聚集在 4×16384≈65k</td><td>配置改 32768 后<b>同一二进制</b>重跑 12 题,<b>10 题恢复</b>(0.0→0.70~1.00),overall <b>0.686→0.717</b>;上游修复 <code>7b3ad99</code> 让该情形成为显式终态。<b>2 题仍失败</b>(精确吃满 4×32768≈131k),说明调大上限只是把墙挪远</td></tr>
<tr><td class="mono"><b>security /workdir 权限 bug</b></td><td><b>26 题误判,20 题假 0 分</b>;security 被压到 0.285</td><td>安全题 Dockerfile 以 root 建 <code>WORKDIR /workdir</code> 且不 chown;agent 以非 root <code>dev</code> 运行 → <code>/workdir/findings.json</code> 写不进去。22 个 0 分 trial 全报权限错,21 个改写到 /workspace 或 /tmp</td><td>adapter 加非递归、fail-soft 的 workdir 属主修复(跳过 /tests、/logs/verifier、*/verifier、*/grading、软链)。E2E <code>blind-ssrf</code> <b>0.0 → 1.0</b>;重跑 26 题 security <b>0.285 → 0.543</b></td></tr>
<tr><td class="mono">2× 单-trial 异常烧整笔交易</td><td>office 崩 17/30、security 崩 3/24</td><td>overlay post-run 把 被杀 agent / 非 UTF-8 control evidence 抛异常,穿透 harbor TaskGroup 连坐整批</td><td>bench 侧容错(降级 0 分 trajectory / errors=replace),修复后重跑到完整;已开上游 PR</td></tr>
</tbody></table></div>
<p class="muted" style="font-size:13px"><b>要点</b>:这些是环境/网络约束,非模型能力短板;sing-box 只加速构建期拉取同版本依赖,不改任务内容与运行期隔离。</p>

<h2>披露清单(结果解读必读)</h2>
<ul class="disc">{disc}</ul>

<h2>数据与产物</h2>
<ul>
<li><code>evals/benchmarks/{esc(meta['round'])}/</code>:<code>data/</code>(唯一事实来源)、<code>generate_report.py</code>、<code>report.md</code>;本页由同一份 data/ 渲染。</li>
<li>原始 trial 产物留在各主机:{esc(meta['raw_artifact_locations'])}</li>
<li>时间线:{esc(meta['timeline'])}</li>
</ul>
</div>
"""
out = R / "metacodes-1d27f07-dualbench.html"
out.write_text(page, encoding="utf-8")
print("written", out, len(page), "bytes")
