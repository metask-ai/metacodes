"""strict-autowrap 虚拟终端自检 + cc-zig 输出在严格 autowrap 下是否错位。

阶段0 地基:screen.py 的 autowrap=True 模式实现 DEC Last-Column Flag(pending-wrap)。
本用例先证明该模式真的能复现 autowrap 差异(基元级),再验 cc-zig 实际输出是否触发。

结论(2026-06-11 实测):cc-zig 每行以 \r\n 结尾,\r 清 pending-wrap → 不触发 autowrap 差异。
故"Apple Terminal 线条不对"**不是** autowrap 根因(虚拟终端复现不出)——真因需真机原始字节定位。
本用例锁住"strict 终端工作正常 + cc-zig 不触发 autowrap"两个事实,防回归。
"""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from screen import Screen  # noqa: E402
from tty_driver import run  # noqa: E402
import tempfile  # noqa: E402


def test_strict_autowrap_primitive_diverges(_bin_path=None):
    # 基元级:写满整行(80×A)再写 B。理想终端截断 B;strict 终端 pending-wrap 后换行放 B。
    ideal = Screen(24, 80, autowrap=False)
    ideal.feed(b"A" * 80 + b"B")
    strict = Screen(24, 80, autowrap=True)
    strict.feed(b"A" * 80 + b"B")
    assert ideal.line_text(1) == "", "理想终端应截断 B(不换行,第 2 行空)"
    assert strict.line_text(1)[:1] == "B", "strict 终端应 autowrap 把 B 放到第 2 行"


def test_crlf_after_full_line_no_divergence(_bin_path=None):
    # 关键:写满整行后立即 \r\n,两终端一致(\r 清 pending-wrap)。
    # 这正是 cc-zig 的行式重绘模式 → 解释了为何 autowrap 不致 cc-zig 错位。
    for aw in (False, True):
        sc = Screen(24, 80, autowrap=aw)
        sc.feed(b"A" * 80 + b"\r\n" + b"C")
        assert sc.line_text(1)[:1] == "C", f"autowrap={aw}: \\r\\n 后 C 应在第 2 行"


def test_sync_output_pairing_counted(_bin_path=None):
    # ?2026h/l 配对计数(供阶段1 同步输出断言)。
    sc = Screen(24, 80, autowrap=True)
    sc.feed(b"\x1b[?2026h" + b"hello" + b"\x1b[?2026l")
    assert sc.max_sync_depth == 1, "应记录一次 BSU/ESU 配对"
    assert sc.sync_depth == 0, "结束应配平"


def test_cczig_output_no_autowrap_divergence(bin_path):
    # cc-zig 真实输出喂入两种终端,帧应一致(证明 autowrap 非 cc-zig 错位根因)。
    raw = run(
        bin_path,
        ["sleep:0.7", "type:hello world", "sleep:0.25"],
        env={"TERM_PROGRAM": "Apple_Terminal", "TERM": "xterm-256color", "HOME": tempfile.mkdtemp()},
        term_size=(24, 80),
    )
    ideal = Screen(24, 80, autowrap=False)
    ideal.feed(raw)
    strict = Screen(24, 80, autowrap=True)
    strict.feed(raw)
    a = [ideal.line_text(r).rstrip() for r in range(24)]
    b = [strict.line_text(r).rstrip() for r in range(24)]
    diff = [r for r in range(24) if a[r] != b[r]]
    assert not diff, f"cc-zig 输出在 strict autowrap 下不应错位(差异行 {diff});若此断言失败说明发现了 autowrap 真因"
    # cc-zig 当前无同步输出 → strict 终端不应记到 2026 配对。
    assert strict.max_sync_depth == 0, "阶段1 前 cc-zig 不应发同步输出序列"
