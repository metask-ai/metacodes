"""screen.py 的 ANSI SGR 颜色解析单测(纯解析,不起二进制)。

回归 basic_16 + 验证扩展色 38;5;N(256)/ 38;2;R;G;B(RGB)正确映射 border_class,
且 48;...(背景色)不误吞后续前景色 class。run_tty_tests 会把本文件当普通 case 收集
(函数名 test_*,签名 (bin_path) 但这里用不到 bin)。
"""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from screen import Screen
from asserts import AssertError


def _cls(seq: str) -> str:
    s = Screen(2, 20)
    s.feed(seq.encode() + b"X")
    return s.grid[0][0].border_class


def _expect(seq, want):
    got = _cls(seq)
    if got != want:
        raise AssertError(f"SGR {seq!r}: 期望 border_class={want},实得 {got}")


def test_T28_sgr_basic16(bin_path):
    _expect("\x1b[36m", "accent")   # cyan
    _expect("\x1b[34m", "accent")   # blue
    _expect("\x1b[33m", "warn")     # yellow
    _expect("\x1b[31m", "danger")   # red
    _expect("\x1b[2m", "dim")
    _expect("\x1b[0m", "plain")


def test_T29_sgr_256(bin_path):
    _expect("\x1b[38;5;14m", "accent")   # bright cyan
    _expect("\x1b[38;5;196m", "danger")  # bright red
    _expect("\x1b[38;5;226m", "warn")    # bright yellow
    _expect("\x1b[38;5;240m", "plain")   # gray


def test_T30_sgr_rgb(bin_path):
    _expect("\x1b[38;2;0;200;255m", "accent")
    _expect("\x1b[38;2;255;0;0m", "danger")
    _expect("\x1b[38;2;255;220;0m", "warn")
    _expect("\x1b[38;2;128;128;128m", "plain")


def test_T31_sgr_bg_not_swallowed(bin_path):
    # 48;5;N(背景)不应吞掉紧随的 36m(前景青)。
    s = Screen(2, 20)
    s.feed(b"\x1b[48;5;200m\x1b[36mX")
    if s.grid[0][0].border_class != "accent":
        raise AssertError(f"48;5;N 误吞后续前景色,got {s.grid[0][0].border_class}")
