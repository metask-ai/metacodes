#!/usr/bin/env python3
"""真 cc vs cc-zig 工具调用交互逐帧录制(打真模型,低复杂度任务)。

任务:让模型读一个预置文件 / 跑一条 echo / 写一个文件 / grep。
观察工具卡片格式:图标、工具名、参数摘要、结果行、缩进、颜色、状态转移
(pending spinner → running → done 折叠)。

用法:
    python3 compare_tool_cards.py cc   <task>   # 真 cc
    python3 compare_tool_cards.py zig  <task>   # cc-zig
tasks: read | bash | write | grep | edit | ls
"""
import os, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
sys.path.insert(0, ROOT)
from cc_compare_recorder import record_steps  # noqa: E402

NAPICC = "/Users/david/bin/napicc"
ZIG = os.path.join(os.path.dirname(os.path.dirname(HERE)), "zig-out", "bin", "metacodes-debug")

PROMPTS = {
    "read":  'Read the file ./hello.txt and show me its contents',
    "bash":  'Run the shell command: echo cc_tool_marker',
    "write": 'Create a file ./out.txt containing the text DONE',
    "grep":  'Search for the word NEEDLE in the file ./hello.txt',
    "ls":    'List the files in the current directory',
    "edit":  "In ./hello.txt change the word alpha to beta",
}


def seed(workdir):
    with open(os.path.join(workdir, "hello.txt"), "w") as f:
        f.write("alpha NEEDLE line1\nline2 content\n")


def build_steps(prompt, is_cc):
    pre = []
    if is_cc:
        pre = [("step", "00-trust", [("sleep", 2.5), ("key", "enter"), ("sleep", 1.5)])]
    return pre + [
        ("step", "01-就绪", [("sleep", 1.0)]),
        ("step", "02-输入任务", [("paste", prompt)]),
        ("step", "03-提交后0.8s", [("key", "enter"), ("sleep", 0.8)]),
        ("step", "04-+1.5s", [("sleep", 1.5)]),
        ("step", "05-+2.5s", [("sleep", 2.5)]),
        ("step", "06-+3.5s", [("sleep", 3.5)]),
        ("step", "07-+5s", [("sleep", 5.0)]),
        ("step", "08-终态", [("sleep", 4.0)]),
    ]


def main():
    which = sys.argv[1] if len(sys.argv) > 1 else "zig"
    task = sys.argv[2] if len(sys.argv) > 2 else "read"
    prompt = PROMPTS[task]
    workdir = tempfile.mkdtemp(prefix="cc-toolcard-")
    seed(workdir)

    if which == "cc":
        frames, raw = record_steps(NAPICC, build_steps(prompt, True),
                                   rows=30, cols=90, workdir=workdir)
        tag = "真 cc"
    else:
        env = {"METACODES_NO_PROBE": "0", "METACODES_LOG": "*:warn", "FORCE_COLOR": "1"}
        frames, raw = record_steps(ZIG, build_steps(prompt, False), rows=30, cols=90,
                                   env=env, args=["--permission", "bypassPermissions"],
                                   workdir=workdir)
        tag = "cc-zig"
    print(f"###### {tag} / task={task} ######")
    for label, text in frames:
        print(f"\n========== {label} ==========\n{text}")
    print(f"\n[raw={len(raw)} bytes]")


if __name__ == "__main__":
    main()
