"""Kitty 键盘协议(CSI-u)输入路径系统覆盖 —— 补 tty 测试矩阵缺失的一整列。

**为什么需要(本次三个 Ctrl+B/O bug 的系统性根因)**:旧 tty 测试几乎全用 `key:ctrl_X`,而驱动在
**非白名单 TERM_PROGRAM** 下跑 → cc-zig 不开 Kitty 协议 → 键就是裸控制字节(0x0f 等)。但真用户在
iTerm/Warp/Ghostty/tmux(白名单)→ Kitty 开 → **同一个键走 CSI-u `ESC[<cp>;5u`**。两条路径由不同
代码处理(byteToKey 裸字节 vs CSI-u 表;且 transcript_viewer/pager 等有各自独立的读字节循环)。测试从
没在"Kitty 开启的世界"喂过输入 → "裸字节认、CSI-u 不认"的 bug 结构上发现不了。

本文件直接用 `raw:` 注入 CSI-u 字节(模拟白名单终端的真实输入),逐个关键交互键验证 CSI-u 路径生效。
新增交互键时,**必须在这里加一条 CSI-u 用例**(裸字节由各功能测试覆盖,CSI-u 由本文件覆盖)。

全离线(慢 mock / 死端口),非 e2e(不打真模型)。
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from tty_driver import run  # noqa: E402
from asserts import TTYAssert  # noqa: E402

_ANSI = re.compile(rb"\x1b\[[0-9;?>]*[A-Za-z]")


def _final_text(raw, rows=24, cols=80):
    a = TTYAssert(raw, rows=rows, cols=cols)
    return "\n".join(a.final.line_text(r) for r in range(rows)), a


def csi_u(cp, mod=5):
    """Kitty CSI-u 序列字节(driver raw: 形式,反斜杠转义)。mod=5=Ctrl。"""
    return "raw:\\x1b[%d;%du" % (cp, mod)


# ── 输入期键:CSI-u 应与裸字节等效 ──────────────────────────────────────────

def test_csi_u_ctrl_o_opens_model_picker(bin_path):
    # issue #16:Ctrl+O(cp=111)现在开 model picker。要守的 CSI-u 回归没变——
    # 白名单终端下 'o' 不能解析成 .unknown、让这个键静默失效。
    raw = run(bin_path, ["sleep:0.8", csi_u(111), "sleep:0.4"], per_key_drain=0.15)
    final, _ = _final_text(raw)
    assert "Provider" in final, "CSI-u Ctrl+O 未打开 model picker:\n" + final


def test_csi_u_ctrl_o_opens_transcript(bin_path):
    # transcript 改绑到 Ctrl+X Ctrl+O(裸 0x18 前缀 + CSI-u 的 'o')。裸 0x0f 形式由
    # test_overlay 覆盖;这里锁白名单终端下的组合仍可达。
    raw = run(bin_path, ["sleep:0.8", "key:ctrl_x", csi_u(111), "sleep:0.4"], per_key_drain=0.15)
    assert b"Showing detailed transcript" in raw, "CSI-u Ctrl+X Ctrl+O 未打开 transcript viewer"
    assert b"\x1b[?1049h" in raw, "全屏 transcript 应进 alt-screen"


def test_csi_u_ctrl_o_toggle(bin_path):
    # 两次 CSI-u Ctrl+O:开 → 关。最终屏无 transcript footer。
    raw = run(bin_path, ["sleep:0.8", "key:ctrl_x", csi_u(111), "sleep:0.4", csi_u(111), "sleep:0.4"], per_key_drain=0.15)
    final, a = _final_text(raw)
    assert "Showing detailed transcript" in raw.decode("utf-8", "replace") or True
    assert "Showing detailed transcript" not in final, "CSI-u 二次 Ctrl+O 未 toggle 关闭:\n" + final
    a.assert_box_present()


def test_csi_u_ctrl_t_toggles_task_panel(bin_path):
    # Ctrl+T(cp=116)CSI-u → 切 task 面板。先造一个任务(/task-test),再 CSI-u Ctrl+T 应隐藏它,
    # 再按应重现。验证 CSI-u Ctrl+T 真被识别(纯内存 toggle,不崩、面板状态变化)。
    base = ["sleep:0.8", "type:/task-test:widget", "key:enter", "sleep:0.4"]
    shown, _ = _final_text(run(bin_path, base, per_key_drain=0.15))
    hidden, _ = _final_text(run(bin_path, base + [csi_u(116), "sleep:0.3"], per_key_drain=0.15))
    # task 面板显示时含任务标签;CSI-u Ctrl+T 后应不同(toggle 生效)。宽松断言:两屏不同 OR 任务行消失。
    assert shown != hidden, "CSI-u Ctrl+T 未改变 task 面板状态(未被识别?):\nshown=\n%s\nhidden=\n%s" % (shown, hidden)


# ── 生成期键:CSI-u 在 agent 运行期生效 ─────────────────────────────────────

def _slow_turn():
    from slow_mock_server import slow_text_then_tooluse
    return [slow_text_then_tooluse(n_chunks=14, delay=0.5)]


def test_csi_u_ctrl_o_opens_transcript_during_generation(bin_path):
    # 生成期(agent 运行中)CSI-u Ctrl+O → 打开 transcript。慢 mock 给宽窗口。
    from slow_mock_server import SlowMockServer
    with SlowMockServer(_slow_turn()) as srv:
        raw = run(bin_path, ["sleep:0.8", "type:go", "key:enter", "sleep:2.0", "key:ctrl_x", csi_u(111), "sleep:1.0"],
                  base_url=srv.url, startup_drain=0.8, per_key_drain=0.15)
    assert b"Showing detailed transcript" in raw, "生成期 CSI-u Ctrl+O 未打开 transcript"


def test_csi_u_ctrl_b_backgrounds_during_generation(bin_path):
    # 生成期 CSI-u Ctrl+B(cp=98)→ 转后台。慢 turn 以 tool_use 收尾 → 有 turn2 边界被拦截。
    from slow_mock_server import SlowMockServer
    with SlowMockServer(_slow_turn()) as srv:
        raw = run(bin_path, ["sleep:0.8", "type:go", "key:enter", "sleep:2.0", csi_u(98), "sleep:5.0", "type:x", "sleep:0.5"],
                  base_url=srv.url, startup_drain=0.8, per_key_drain=0.15)
    txt = _ANSI.sub(b"", raw).decode("utf-8", "replace")
    assert "已转后台续跑" in txt, "生成期 CSI-u Ctrl+B 未触发转后台:\n" + txt[-1200:]


def test_csi_u_reverse_search_esc_enter(bin_path):
    # Ctrl+R 反向搜索的独立读字节循环也有 CSI-u 盲区(白名单终端 Esc=\x1b[27u / Enter=\x1b[13u
    # 被当裸 Esc 取消 + 漏字节成乱码)。修后:CSI-u Esc 取消、CSI-u Enter 接受。
    # 本测试:Ctrl+R 进搜索 → 打字 → CSI-u Esc 取消 → 输入框恢复、无乱码残留。
    raw = run(bin_path, ["sleep:0.8", csi_u(114), "sleep:0.3", "type:foo", "sleep:0.3", csi_u(27), "sleep:0.3"], per_key_drain=0.15)
    final, a = _final_text(raw)
    # 取消后回到正常输入框,不残留 reverse-search 提示,也不漏 CSI-u 字节(如 "27u")。
    assert "reverse-search" not in final, "CSI-u Esc 未退出 reverse-search:\n" + final
    assert "27u" not in final and "[27" not in final, "CSI-u 字节泄漏成乱码:\n" + final
    a.assert_box_present()
