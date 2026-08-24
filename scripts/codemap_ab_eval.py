#!/usr/bin/env python3
"""CodeMap 引导提示词 A/B 验证。

问题:这套 # Using your tools 引导行 + describeCodeMap,是否真的提高了模型在
**自然编程问题**(不点名工具)下选择 CodeMap 的比率?

方法:同一批问题 × 同一份代码 cwd,分别在
  - baseline(无引导,/tmp/cc-baseline-debug)
  - treated (有引导,/tmp/cc-treated-debug)
上各跑 N 次,扫 transcript 看模型首选了哪个工具(CodeMap / Read / Grep / Glob / 其它)。
统计 CodeMap 命中率。引导有效 ⟺ treated 命中率显著 > baseline。

真模型走 client.zig 硬编码端点(同既有 tty e2e)。漂移靠"每题多 trial 取比率"吸收。
"""
import os
import sys
import time
import glob
import json
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TTY_DIR = os.path.join(os.path.dirname(HERE), "tests", "tty")
sys.path.insert(0, TTY_DIR)
from tty_driver import run  # noqa: E402

BASELINE = "/tmp/cc-baseline-debug"
TREATED = "/tmp/cc-treated-debug"
TRIALS = int(os.environ.get("AB_TRIALS", "4"))  # 每题每 build 跑几次
WAIT_S = 22

# 一个有清晰结构的多文件 Zig 项目,给 CodeMap/Grep/Read 都有真东西可做。
FILES = {
    "shapes.zig": """\
const std = @import("std");

pub const Color = enum { red, green, blue };

pub const Rect = struct {
    w: i32,
    h: i32,
    pub fn area(self: Rect) i32 { return self.w * self.h; }
    pub fn perimeter(self: Rect) i32 { return 2 * (self.w + self.h); }
};

pub const Circle = struct {
    r: i32,
    pub fn area(self: Circle) i32 { return 3 * self.r * self.r; }
};

pub fn maxArea(a: i32, b: i32) i32 { return if (a > b) a else b; }
""",
    "util.zig": """\
const std = @import("std");

pub fn clamp(v: i32, lo: i32, hi: i32) i32 {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

pub fn sum(items: []const i32) i32 {
    var t: i32 = 0;
    for (items) |x| t += x;
    return t;
}

pub const VERSION = "1.2.3";
""",
}

# 自然编程问题:都该让"看结构/找定义"成为最优解,但**不点名 CodeMap**。
# 每题标注"理想工具"——CodeMap 是引导想推动的选择。
QUESTIONS = [
    "I just opened this project. Without dumping whole files, show me what types and "
    "functions are defined in shapes.zig and where each one is.",

    "Give me a high-level structural overview of util.zig — just the function and "
    "constant definitions with their line numbers, not the full bodies.",

    "Where is the area method defined in this codebase, and on which types? "
    "I only want the definitions, not every place it's mentioned.",

    "I'm unfamiliar with shapes.zig and util.zig. Map out their structure for me so "
    "I know what's defined where, without reading the entire files.",

    "List every public function and type across these two files with signatures, "
    "as compactly as possible.",
]


def fresh_home():
    return tempfile.mkdtemp(prefix="cc-ab-home-")


def make_cwd():
    d = tempfile.mkdtemp(prefix="cc-ab-cwd-")
    for name, body in FILES.items():
        with open(os.path.join(d, name), "w", encoding="utf-8") as f:
            f.write(body)
    return d


def first_tool(home):
    """返回该 session 里**第一个被调用**的工具名(模型的首选),没有则 None。
    transcript.jsonl: 每行 message JSON,blocks 里有 tool_use。按文件+行顺序取最早。"""
    pat = os.path.join(home, ".metacodes", "projects", "*", "*", "transcript.jsonl")
    seq = []
    for path in glob.glob(pat):
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                for ln, line in enumerate(f):
                    line = line.strip()
                    if not line or '"tool_use"' not in line:
                        continue
                    try:
                        msg = json.loads(line)
                    except Exception:
                        continue
                    for b in msg.get("blocks", []) or []:
                        if isinstance(b, dict) and b.get("type") == "tool_use":
                            seq.append((ln, b.get("name", "?")))
        except FileNotFoundError:
            pass
    if not seq:
        return None
    seq.sort(key=lambda t: t[0])
    return seq[0][1]


def run_one(binp, prompt, cwd):
    home = fresh_home()
    keys = ["sleep:0.8", "type:" + prompt, "key:enter", "sleep:%g" % WAIT_S]
    try:
        run(binp, keys, base_url=None, env={"HOME": home}, cwd=cwd,
            per_key_drain=0.04, startup_drain=1.0)
        return first_tool(home)
    finally:
        import shutil
        shutil.rmtree(home, ignore_errors=True)


def eval_build(label, binp, cwd):
    print(f"\n===== {label}  ({binp}) =====")
    tally = {}          # tool -> count
    codemap_hits = 0
    total = 0
    per_q = []
    for qi, q in enumerate(QUESTIONS):
        picks = []
        for _ in range(TRIALS):
            t = run_one(binp, q, cwd)
            picks.append(t)
            tally[t] = tally.get(t, 0) + 1
            total += 1
            if t == "CodeMap":
                codemap_hits += 1
            time.sleep(0.3)
        cm = sum(1 for p in picks if p == "CodeMap")
        per_q.append(cm)
        print(f"  Q{qi+1}: CodeMap {cm}/{TRIALS}   picks={picks}")
    rate = codemap_hits / total if total else 0.0
    print(f"  -- {label}: CodeMap {codemap_hits}/{total} = {rate:.0%}   tool tally={tally}")
    return codemap_hits, total, tally, per_q


def main():
    for b in (BASELINE, TREATED):
        if not os.access(b, os.X_OK):
            print(f"[ERROR] 缺二进制: {b}", file=sys.stderr)
            return 2
    cwd = make_cwd()
    print(f"题库 {len(QUESTIONS)} 题 × {TRIALS} trial × 2 build = "
          f"{len(QUESTIONS)*TRIALS*2} 次真模型调用")
    bh, bt, btally, bpq = eval_build("BASELINE(无引导)", BASELINE, cwd)
    th, tt, ttally, tpq = eval_build("TREATED (有引导)", TREATED, cwd)

    print("\n================ 对照结果 ================")
    print(f"  baseline CodeMap 命中率: {bh}/{bt} = {bh/bt:.0%}")
    print(f"  treated  CodeMap 命中率: {th}/{tt} = {th/tt:.0%}")
    delta = (th/tt) - (bh/bt) if bt and tt else 0
    print(f"  Δ(treated - baseline) = {delta:+.0%}")
    print(f"  baseline 工具分布: {btally}")
    print(f"  treated  工具分布: {ttally}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
