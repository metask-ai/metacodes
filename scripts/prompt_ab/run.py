#!/usr/bin/env python3
"""提示词 A/B 框架 CLI:跑实验 → 按题类别统计 → 双比例 z 检验 → 报告 + 推荐最优。

用法:
  python3 scripts/prompt_ab/run.py --experiment codemap --trials 8
  python3 scripts/prompt_ab/run.py --experiment codemap --variants baseline,current
  python3 scripts/prompt_ab/run.py --experiment codemap --trials 1   # 冒烟

提示词 variant 经 base64 env 注入同一个二进制(src/core/prompt_override.zig),无需重编译。
"""
import os
import sys
import time
import argparse
import importlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import harness  # noqa: E402
import stats  # noqa: E402

CATEGORIES = ["structure", "locate_symbol"]
PRIMARY_TOOL = {"structure": "CodeMap", "locate_symbol": "FindSymbol"}


def load_experiment(name):
    return importlib.import_module(f"experiments.{name}")


def run_variant(binp, exp, variant_name, questions, trials, cwd):
    """跑一个 variant 的全部题 × trials。返回逐 attempt 记录列表。
    record = {q, split, category, first_tool, score, primary_hit}"""
    slots = exp.VARIANTS[variant_name]
    records = []
    for q in questions:
        for t in range(trials):
            ft = harness.run_attempt(binp, q["prompt"], slots, cwd)
            records.append({
                "split": q["split"],
                "category": q["category"],
                "first_tool": ft,
                "score": exp.score(ft, q),
                "primary_hit": exp.primary_hit(ft, q),
            })
            time.sleep(0.3)
    return records


def agg(records, split, category):
    """筛 split+category 的 (primary_hits, n, half_credit次优数, tool分布)。"""
    sub = [r for r in records if r["split"] == split and r["category"] == category]
    n = len(sub)
    hits = sum(1 for r in sub if r["primary_hit"])
    # 次优:locate_symbol 里选了 CodeMap(score==0.5)
    suboptimal = sum(1 for r in sub if (not r["primary_hit"]) and r["score"] == 0.5)
    tally = {}
    for r in sub:
        tally[r["first_tool"]] = tally.get(r["first_tool"], 0) + 1
    return hits, n, suboptimal, tally


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--experiment", required=True)
    ap.add_argument("--bin", default="zig-out/bin/metacodes-debug")
    ap.add_argument("--trials", type=int, default=8)
    ap.add_argument("--variants", default=None, help="逗号分隔;默认全部")
    args = ap.parse_args()

    if not os.access(args.bin, os.X_OK):
        print(f"[ERROR] 二进制不存在/不可执行: {args.bin}", file=sys.stderr)
        return 2

    exp = load_experiment(args.experiment)
    variants = args.variants.split(",") if args.variants else list(exp.VARIANTS.keys())
    for v in variants:
        if v not in exp.VARIANTS:
            print(f"[ERROR] 未知 variant: {v} (有: {list(exp.VARIANTS)})", file=sys.stderr)
            return 2

    questions = exp.QUESTIONS
    cwd = harness.make_cwd(exp.FIXTURE_FILES)
    total_calls = len(variants) * len(questions) * args.trials
    print(f"实验 {args.experiment}: {len(variants)} variant × {len(questions)} 题 × "
          f"{args.trials} trial = {total_calls} 次真模型调用", flush=True)

    results = {}  # variant -> records
    for v in variants:
        print(f"\n>>> 跑 variant: {v} ...", flush=True)
        results[v] = run_variant(args.bin, exp, v, questions, args.trials, cwd)

    # ── 报告 ──
    print("\n" + "=" * 70)
    print("按题类别 × split 命中率(primary_hit:结构题=CodeMap,找定义题=FindSymbol)")
    print("=" * 70)
    for split in ("train", "holdout"):
        print(f"\n[{split}]")
        for cat in CATEGORIES:
            print(f"  类别 {cat} (理想工具={PRIMARY_TOOL[cat]}):")
            for v in variants:
                h, n, sub, tally = agg(results[v], split, cat)
                sub_note = f"  次优(CodeMap){sub}/{n}" if cat == "locate_symbol" else ""
                print(f"    {v:14s} {stats.fmt_rate(h, n)}{sub_note}   tools={tally}", flush=True)

    # ── 两两 z 检验(只在 train+全 split 合并上做主指标对比,聚焦 baseline vs others)──
    print("\n" + "=" * 70)
    print("双比例 z 检验(全 split 合并,主指标命中率;α=0.05)")
    print("=" * 70)
    for cat in CATEGORIES:
        print(f"\n  类别 {cat}:")

        def cat_hits(v):
            sub = [r for r in results[v] if r["category"] == cat]
            return sum(1 for r in sub if r["primary_hit"]), len(sub)
        base = "baseline" if "baseline" in variants else variants[0]
        bh, bn = cat_hits(base)
        for v in variants:
            if v == base:
                continue
            vh, vn = cat_hits(v)
            z, p = stats.two_proportion_z(vh, vn, bh, bn)
            sig = "显著✓" if p < 0.05 else "不显著"
            print(f"    {v} vs {base}: {vh}/{vn} vs {bh}/{bn}  z={z:+.2f} p={p:.3f} [{sig}]",
                  flush=True)

    # ── 推荐 ──
    print("\n" + "=" * 70)
    print("综合得分(全题 score 均值,含次优半分):")
    best, best_score = None, -1.0
    for v in variants:
        recs = results[v]
        s = sum(r["score"] for r in recs) / len(recs) if recs else 0.0
        print(f"  {v:14s} {s:.3f}", flush=True)
        if s > best_score:
            best, best_score = v, s
    print(f"\n推荐最优 variant: {best}  (综合得分 {best_score:.3f})")
    print("注:小样本下'显著'才是可信结论;综合得分仅供排序参考。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
