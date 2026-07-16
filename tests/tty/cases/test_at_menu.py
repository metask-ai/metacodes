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
    wd = _mkdir_with_files()
    try:
        _, raw = _cap(bin_path, wd, ["type:@", "sleep:0.2", "key:down", "sleep:0.3"])
        # 终态判定(而非 raw 字节顺序推断):ConPTY 会整屏重合成,"最后出现的 accent 序列"
        # 与"当前高亮"不再一一对应(尾窗可横跨两帧);POSIX 增量渲染下终态判定同样成立。
        from screen import Screen
        sc = Screen(24, 80)
        sc.feed(raw)

        # 目录枚举顺序平台相关(POSIX=创建序 README 在前;Windows FindFirstFile=字母序
        # main.py 在前)——不硬编码文件名,按**屏幕行序**断言:Down 后高亮在第 2 项,非第 1 项。
        items = []  # (row, name, class) 按行序
        for r in range(sc.rows):
            t = sc.line_text(r)
            for name in ("main.py", "README.md"):
                if "+ " + name in t:
                    cls = None
                    for cell in sc.grid[r]:
                        if cell.ch and not cell.ch.isspace():
                            cls = cell.border_class
                            break
                    items.append((r, name, cls))
        assert len(items) == 2, f"应列出两个候选,实得 {items}"
        assert items[1][2] == "accent", f"Down 后第 2 项应高亮(accent),实得 {items}"
        assert items[0][2] != "accent", f"第 1 项不应仍是 accent,实得 {items}"
    finally:
        shutil.rmtree(wd, ignore_errors=True)
