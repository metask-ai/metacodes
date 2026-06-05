"""断言库 —— 切帧 + 基于 screen model 的 TUI 布局断言。

切帧:RenderRegion 每次重画都包在 ESC[?25l ... ESC[?25h 之间(hide/show 光标对),
这是最可靠的 flush 边界。一帧 = 一对 hide/show 之间的字节(含)。
"""
from screen import Screen, str_width

HIDE = b"\x1b[?25l"
SHOW = b"\x1b[?25h"


def split_frames(raw: bytes):
    """切成 [(kind, bytes)]:kind='frame'(hide..show 重画)或 'prose'(帧间散文本)。"""
    out = []
    i = 0
    n = len(raw)
    while i < n:
        h = raw.find(HIDE, i)
        if h == -1:
            if i < n:
                out.append(("prose", raw[i:]))
            break
        if h > i:
            out.append(("prose", raw[i:h]))
        s = raw.find(SHOW, h)
        if s == -1:
            out.append(("frame", raw[h:]))
            break
        end = s + len(SHOW)
        out.append(("frame", raw[h:end]))
        i = end
    return out


class AssertError(Exception):
    pass


class TTYAssert:
    def __init__(self, raw: bytes, rows=24, cols=80):
        self.raw = raw
        self.rows = rows
        self.cols = cols
        # 最终屏幕 = 整条流喂一个 Screen
        self.final = Screen(rows, cols)
        self.final.feed(raw)
        # 逐帧快照(每帧累积喂,得到该帧后的屏幕)
        self.frame_screens = []
        sc = Screen(rows, cols)
        for kind, chunk in split_frames(raw):
            sc.feed(chunk)
            if kind == "frame":
                snap = Screen(rows, cols)
                # 复制当前 grid 状态
                self._copy_into(sc, snap)
                self.frame_screens.append(snap)

    @staticmethod
    def _copy_into(src: Screen, dst: Screen):
        for r in range(src.rows):
            for c in range(src.cols):
                s = src.grid[r][c]
                d = dst.grid[r][c]
                d.ch, d.width, d.cont, d.border_class = s.ch, s.width, s.cont, s.border_class
        dst.row, dst.col, dst.cursor_visible, dst.scrolled = src.row, src.col, src.cursor_visible, src.scrolled

    def _fail(self, msg):
        raise AssertError(msg + "\n\n--- 最终屏幕 ---\n" + self.final.render_ascii())

    # ---------- 断言 ----------

    def assert_stable(self, last_n=2):
        """屏幕已settled:最后 last_n 个重画帧的渲染内容完全一致(无 mid-redraw 撕裂)。

        post-hoc 检查(TTYAssert 处理的是已捕获字节,非活进程):若捕获在重画过程
        中结束,最后两帧会不同 → 提示该用例 drain/sleep 不足、需加时间。帧数 < last_n
        时跳过(不够样本不强断,避免对单帧场景误报)。
        """
        frames = self.frame_screens
        if len(frames) < last_n:
            return
        texts = [
            "\n".join(f.line_text(r) for r in range(f.rows))
            for f in frames[-last_n:]
        ]
        if any(t != texts[0] for t in texts):
            self._fail(
                f"屏幕未 settled(最后 {last_n} 帧不一致,可能 drain/sleep 不足):\n"
                + "--- 倒数第2帧 ---\n" + frames[-2].render_ascii()
                + "\n--- 最后帧 ---\n" + frames[-1].render_ascii()
            )

    def box_top_row(self, screen=None):
        sc = screen or self.final
        return sc.find_last_row("╭")

    def box_bottom_row(self, screen=None):
        sc = screen or self.final
        return sc.find_last_row("╰")

    def footer_row(self, screen=None):
        sc = screen or self.final
        # footer 标志:default 态含 "? for shortcuts";非 default 态含 "shift+tab to cycle"
        # (2026-06-05 对齐 cc:非 default footer 不再含 "? for shortcuts")。
        r = sc.find_last_row("? for shortcuts")
        if r is None:
            r = sc.find_last_row("shift+tab to cycle")
        return r

    def content_row(self, screen=None):
        sc = screen or self.final
        return sc.find_last_row("❯")

    def assert_box_present(self):
        if self.box_top_row() is None or self.content_row() is None or self.footer_row() is None:
            self._fail("输入框未完整渲染(缺 ╭ / ❯ / footer)")

    def assert_box_at_bottom(self):
        """框钉"内容底部":下边框紧邻 footer 上方,且 footer 之下无任何非空内容行。
        (注意不是物理屏幕最底行——内容不足时框在屏幕中部,这是底部锚定区的正常形态;
        只有内容填满屏幕时框才到 rows-1。关键不变式:框下方没有杂散内容。)"""
        self.assert_box_present()
        foot = self.footer_row()
        bot = self.box_bottom_row()
        if bot is None or foot is None or bot != foot - 1:
            self._fail(f"下边框未紧邻 footer 上方(bottom={bot}, footer={foot})")
        # footer 之下不应有非空行(否则框没钉在内容底)
        for r in range(foot + 1, self.rows):
            if self.final.line_text(r).strip():
                self._fail(f"footer({foot}) 之下第 {r} 行有残留内容 '{self.final.line_text(r)}'")

    def assert_line_contains(self, row, substr):
        txt = self.final.line_text(row)
        if substr not in txt:
            self._fail(f"第 {row} 行应含 '{substr}',实际 '{txt}'")

    def assert_footer_mode(self, mode_str):
        fr = self.footer_row()
        if fr is None:
            self._fail("无 footer 行")
        txt = self.final.line_text(fr)
        if f"{mode_str} on" not in txt:
            self._fail(f"footer 模式应为 '{mode_str} on',实际 '{txt}'")

    def assert_input_echo(self, text):
        """❯ 行(+续行)拼出的文本 == text;光标列 == 2 + 文本显示宽。"""
        cr = self.content_row()
        if cr is None:
            self._fail("无 ❯ 内容行")
        line = self.final.line_text(cr)
        # 去掉 "❯ " 前缀
        after = line
        idx = line.find("❯")
        if idx >= 0:
            after = line[idx + 1 :].lstrip(" ")
        if after != text:
            self._fail(f"输入回显应为 '{text}',实际 '{after}'(整行 '{line}')")

    def assert_cursor_col(self, expected_col):
        r, c = self.final.cursor()
        if c != expected_col:
            self._fail(f"光标列应为 {expected_col},实际 {c}(行 {r})")

    def assert_cursor_on_content(self, text_before_cursor):
        """光标应在 ❯ 内容行,列 = 2(prefix) + 光标前文本显示宽。"""
        cr = self.content_row()
        r, c = self.final.cursor()
        expected = 2 + str_width(text_before_cursor)
        if c != expected:
            self._fail(f"光标列应为 2+宽({text_before_cursor!r})={expected},实际 {c}")

    def assert_no_jitter(self):
        """所有输入态帧的框顶行号必须恒定(不漂移),每帧框元素各 1。"""
        tops = []
        for sc in self.frame_screens:
            t = sc.find_last_row("╭")
            if t is not None:
                tops.append(t)
        if not tops:
            self._fail("无任何输入框帧")
        if len(set(tops)) != 1:
            raise AssertError(
                f"输入框跳动!框顶行号逐帧={tops}(应恒定)\n\n--- 最后一帧 ---\n"
                + self.frame_screens[-1].render_ascii()
            )

    def assert_box_height(self, n_content_rows):
        top = self.box_top_row()
        bot = self.box_bottom_row()
        if top is None or bot is None:
            self._fail("无完整边框")
        actual = bot - top - 1
        if actual != n_content_rows:
            self._fail(f"框内容应 {n_content_rows} 行,实际 {actual}(top={top},bottom={bot})")

    def assert_border_class(self, expected):
        top = self.box_top_row()
        if top is None:
            self._fail("无上边框")
        cls = self.final.line_attr_class(top)
        if cls != expected:
            self._fail(f"边框色应为 {expected},实际 {cls}")

    def assert_no_full_clear(self):
        if b"\x1b[2J" in self.raw:
            self._fail("打字阶段不应出现 ESC[2J(全屏清,会清 scrollback)")

    def assert_clean_exit(self):
        if not self.raw.rstrip().endswith(b"\x1b[?25h") and b"\x1b[?25h" not in self.raw[-40:]:
            # 宽松:尾部附近有 show cursor
            if b"\x1b[?25h" not in self.raw[-200:]:
                self._fail("退出未 show cursor")
        # 最终屏不应有残留输入框(查边框 ╭/╰;不能查 ❯——提交回显的用户消息合法含 ❯)
        if self.final.find_row("╭") is not None or self.final.find_row("╰") is not None:
            self._fail("退出后仍残留输入框边框 ╭/╰")

    def assert_prose_contains(self, substr):
        """帧间散文本(banner/本地命令输出)含 substr。"""
        prose = b"".join(c for k, c in split_frames(self.raw) if k == "prose")
        # 简单去 ANSI
        import re
        txt = re.sub(rb"\x1b\[[0-9;?>]*[A-Za-z]", b"", prose).decode("utf-8", "replace")
        if substr not in txt:
            self._fail(f"散文本应含 '{substr}'(实际片段:{txt[:200]!r})")
