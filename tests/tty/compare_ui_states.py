#!/usr/bin/env python3
"""真 cc(napicc) vs cc-zig(metacodes-debug)UI 状态机逐帧对照录制。

不打真实模型(纯 UI 交互层):启动屏 / 打字回显 / ? 帮助 / shift+tab 模式循环 /
斜杠菜单 / 多行(\\ 续行) / esc 语义 / Ctrl+O。每步切帧,左右并排 dump 供肉眼对差。

cc-zig 用死端口(NO_PROBE)离线;napicc 真端点但这些步骤都不提交,不烧 token
(只 ? / shift+tab / 打字这类纯本地 UI 操作;斜杠菜单不回车)。

用法:
    python3 compare_ui_states.py            # 同时录两边并排
    python3 compare_ui_states.py --only zig # 只录 cc-zig
    python3 compare_ui_states.py --only cc  # 只录真 cc
"""
import os
import sys
import argparse

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
ROOT = os.path.dirname(os.path.dirname(HERE))  # metacodes 仓库根
sys.path.insert(0, ROOT)

from cc_compare_recorder import record_steps  # noqa: E402

NAPICC = os.environ.get("NAPICC", "napicc")
ZIG = os.path.join(os.path.dirname(os.path.dirname(HERE)), "zig-out", "bin", "metacodes-debug")

# 真 cc 首次进新目录有 "trust this folder?" 门,先 enter 信任再进主 REPL。
# cc-zig 无此门,enter 在空框上是无害的(空输入不提交)。
TRUST = [("step", "00-信任目录", [("sleep", 2.5), ("key", "enter"), ("sleep", 1.5)])]

# 纯 UI 状态机步骤(不提交真实 prompt,零 token)。
UI_STEPS = [
    ("step", "01-启动屏", [("sleep", 2.5)]),
    ("step", "02-打字 hello", [("type", "hello")]),
    ("step", "03-按 ? 帮助态", [("key", "?"), ("sleep", 0.5)]),
    ("step", "04-退格清 ?", [("key", "backspace"), ("sleep", 0.3)]),
    ("step", "05-清空(ctrl_u)", [("key", b"\x15"), ("sleep", 0.3)]),
    ("step", "06-shift_tab×1", [("key", "shift_tab"), ("sleep", 0.4)]),
    ("step", "07-shift_tab×2", [("key", "shift_tab"), ("sleep", 0.4)]),
    ("step", "08-shift_tab×3", [("key", "shift_tab"), ("sleep", 0.4)]),
    ("step", "09-shift_tab×4(回环)", [("key", "shift_tab"), ("sleep", 0.4)]),
    ("step", "10-斜杠菜单", [("type", "/"), ("sleep", 0.5)]),
    ("step", "11-斜杠+he", [("type", "he"), ("sleep", 0.4)]),
    ("step", "12-清斜杠", [("key", b"\x15"), ("sleep", 0.3)]),
    ("step", "13-多行(esc 退出菜单先)", [("key", "esc"), ("sleep", 0.3)]),
]


def dump(title, frames):
    print(f"\n{'#'*70}\n# {title}\n{'#'*70}")
    for label, text in frames:
        print(f"\n========== {label} ==========")
        print(text)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", choices=["zig", "cc"], default=None)
    ap.add_argument("--rows", type=int, default=30)
    ap.add_argument("--cols", type=int, default=90)
    args = ap.parse_args()

    if args.only != "cc":
        zig_env = {
            "METACODES_NO_PROBE": "1",
            "METACODES_LOG": "*:warn",
            "FORCE_COLOR": "1",
        }
        zframes, zraw = record_steps(
            ZIG, UI_STEPS, rows=args.rows, cols=args.cols, env=zig_env,
            args=["--permission", "default", "--base-url", "http://127.0.0.1:1/v1/messages"],
        )
        dump("cc-zig (metacodes-debug)", zframes)
        print(f"\n[cc-zig raw={len(zraw)} bytes]")

    if args.only != "zig":
        cframes, craw = record_steps(NAPICC, TRUST + UI_STEPS, rows=args.rows, cols=args.cols)
        dump("真 cc (napicc 2.1.165)", cframes)
        print(f"\n[napicc raw={len(craw)} bytes]")


if __name__ == "__main__":
    main()
