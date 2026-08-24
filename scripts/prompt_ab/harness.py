"""跑单次 A/B attempt:把 variant 提示词经 base64 env 注入二进制 → 真模型跑一题 →
扫 transcript 取模型**首选工具**(第一个被调用的工具)。

复用 tests/tty 的 tty_driver.run(已验证可驱动真模型 + PTY)。提示词热插拔靠
src/core/prompt_override.zig 的 env 旁路:env METACODES_PROMPT_OVERRIDE_<SLOT>=<base64>。
"""
import os
import sys
import glob
import json
import base64
import shutil
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TTY_DIR = os.path.join(os.path.dirname(os.path.dirname(HERE)), "tests", "tty")
sys.path.insert(0, TTY_DIR)
from tty_driver import run  # noqa: E402

WAIT_S = int(os.environ.get("AB_WAIT_S", "22"))


def env_for_variant(variant_slots):
    """variant_slots: {SLOT: 文本}。→ {METACODES_PROMPT_OVERRIDE_<SLOT>: base64}。
    空 dict(baseline)→ 不注入任何 override,用编译进二进制的默认提示词。"""
    env = {}
    for slot, text in (variant_slots or {}).items():
        b64 = base64.standard_b64encode(text.encode("utf-8")).decode("ascii")
        env["METACODES_PROMPT_OVERRIDE_" + slot] = b64
    return env


def first_tool(home):
    """该 session 第一个被调用的工具名(模型首选),无则 None。
    transcript.jsonl 每行 message JSON,blocks 里 tool_use,按文件内行序取最早。"""
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


def make_cwd(fixture_files):
    d = tempfile.mkdtemp(prefix="cc-ab-cwd-")
    for name, body in fixture_files.items():
        with open(os.path.join(d, name), "w", encoding="utf-8") as f:
            f.write(body)
    return d


def run_attempt(bin_path, prompt, variant_slots, cwd, wait_s=None):
    """跑一次:注入 variant env → 输入 prompt → 等 → 返回 first_tool。"""
    home = tempfile.mkdtemp(prefix="cc-ab-home-")
    env = {"HOME": home}
    env.update(env_for_variant(variant_slots))
    keys = ["sleep:0.8", "type:" + prompt, "key:enter", "sleep:%g" % (wait_s or WAIT_S)]
    try:
        run(bin_path, keys, base_url=None, env=env, cwd=cwd,
            per_key_drain=0.04, startup_drain=1.0)
        return first_tool(home)
    finally:
        shutil.rmtree(home, ignore_errors=True)
