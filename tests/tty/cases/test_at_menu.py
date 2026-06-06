"""DIFF#5:`@` 引用菜单(对齐 cc 2.1.167)。

`@` → 输入框上方列匹配文件(`+ name`);`@R` 过滤;↑↓ 移高亮;Tab/Enter 插入路径。
全离线(纯 UI + 本地文件枚举,不打模型)。每 test 自建隔离 cwd 放固定文件。
"""
import os
import sys
import tempfile
import shutil
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tty_driver import run
from screen import Screen


def _mkdir_with_files():
    wd = tempfile.mkdtemp(prefix="cc-atmenu-")
    open(os.path.join(wd, "README.md"), "w").write("x")
    open(os.path.join(wd, "main.py"), "w").write("x")
    os.makedirs(os.path.join(wd, "src"), exist_ok=True)
    return wd


def _cap(bin_path, wd, events, rows=24, cols=80):
    raw = run(bin_path, ["sleep:0.8"] + events, per_key_drain=0.07, cwd=wd)
    sc = Screen(rows, cols)
    sc.feed(raw)
    return sc, raw


def _menu_files(sc):
    out = []
    for r in range(sc.rows):
        t = sc.line_text(r).strip()
        if t.startswith("+ "):
            out.append(t[2:].strip())
    return out


def test_at_menu_lists_files(bin_path):
    wd = _mkdir_with_files()
    try:
        sc, _ = _cap(bin_path, wd, ["type:@", "sleep:0.4"])
        files = _menu_files(sc)
        for need in ("README.md", "main.py", "src/"):
            assert need in files, f"@ 菜单缺 {need}:{files}"
    finally:
        shutil.rmtree(wd, ignore_errors=True)


def test_at_menu_filters(bin_path):
    wd = _mkdir_with_files()
    try:
        sc, _ = _cap(bin_path, wd, ["type:@R", "sleep:0.4"])
        files = _menu_files(sc)
        assert "README.md" in files, f"@R 应含 README.md:{files}"
        assert "main.py" not in files, f"@R 不应含 main.py:{files}"
    finally:
        shutil.rmtree(wd, ignore_errors=True)


def test_at_menu_tab_inserts(bin_path):
    wd = _mkdir_with_files()
    try:
        sc, _ = _cap(bin_path, wd, ["type:@R", "sleep:0.3", "key:tab", "sleep:0.3"])
        box = ""
        for r in range(sc.rows):
            t = sc.line_text(r).strip()
            if t.startswith("❯"):
                box = t
        assert "@README.md" in box, f"Tab 应插入 @README.md,实得 {box!r}"
    finally:
        shutil.rmtree(wd, ignore_errors=True)


def test_at_menu_down_moves_highlight(bin_path):
    import re
    wd = _mkdir_with_files()
    try:
        _, raw = _cap(bin_path, wd, ["type:@", "sleep:0.2", "key:down", "sleep:0.3"])
        s = raw[-6000:].decode("latin-1")
        # 收集每个候选项的颜色 class:accent=\x1b[36m,dim=\x1b[2m
        accent = []
        for m in re.finditer(r"(\x1b\[[0-9;]*m)\s*\+ ([A-Za-z./]+)", s):
            if m.group(1) == "\x1b[36m":
                accent.append(m.group(2))
        # Down 后高亮应落在第 2 项(main.py),不是第 1 项
        assert accent and accent[-1] == "main.py", f"Down 后应高亮 main.py,实得 accent={accent}"
    finally:
        shutil.rmtree(wd, ignore_errors=True)
