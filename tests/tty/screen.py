"""终端模拟器(screen model)—— 把 ANSI 字节流回放成虚拟屏幕网格。

吃 RenderRegion emit 的字节,维护行列网格 + 光标 + 颜色属性,
让测试能像人眼一样断言"屏幕长什么样 / 光标在哪 / 框是否钉底"。

只实现 RenderRegion 实际用到的 ANSI 子集(见 ansi.zig):
  ESC[<n>A 上移、ESC[<n>C 右移、ESC[<n>G 列定位(1-based)、
  ESC[2K 清整行、ESC[0K 清到行尾、\r、\n(底部触发上滚)、
  ESC[?25l/h 光标显隐、SGR(颜色→border_class)。
未知 final byte(?2004h / >4;1m 等)安静吞掉。

char_width 逐行复刻 apps/cli/src/repl/tui/term.zig:codepointDisplayWidth,
否则光标列断言与实现对不齐。
"""


def char_width(cp: int) -> int:
    """复刻 term.zig:codepointDisplayWidth。控制字符=0,CJK/emoji 全角=2,其余=1。"""
    if cp < 0x20 or cp == 0x7F:
        return 0
    if 0x1100 <= cp <= 0x115F:
        return 2
    if 0x2E80 <= cp <= 0x303E:
        return 2
    if 0x3041 <= cp <= 0x33FF:
        return 2
    if 0x3400 <= cp <= 0x4DBF:
        return 2
    if 0x4E00 <= cp <= 0x9FFF:
        return 2
    if 0xA000 <= cp <= 0xA4CF:
        return 2
    if 0xAC00 <= cp <= 0xD7A3:
        return 2
    if 0xF900 <= cp <= 0xFAFF:
        return 2
    if 0xFE30 <= cp <= 0xFE4F:
        return 2
    if 0xFF00 <= cp <= 0xFF60:
        return 2
    if 0xFFE0 <= cp <= 0xFFE6:
        return 2
    if 0x1F300 <= cp <= 0x1FAFF:
        return 2
    if 0x20000 <= cp <= 0x2FFFD:
        return 2
    if 0x30000 <= cp <= 0x3FFFD:
        return 2
    return 1


def str_width(s: str) -> int:
    return sum(char_width(ord(c)) for c in s)


class Cell:
    __slots__ = ("ch", "width", "cont", "border_class", "written")

    def __init__(self):
        self.ch = " "
        self.width = 1
        self.cont = False  # 宽字符的续格(占位,不重复显示)
        self.border_class = "plain"
        # 写过字符(含显式空格)。resize 重排按它算一行的长度:擦掉的格子不算,
        # 写进去的空格算(xterm.js 的 getTrimmedLength 同此)。
        self.written = False

    def clear(self):
        self.ch = " "
        self.width = 1
        self.cont = False
        self.border_class = "plain"
        self.written = False


class Screen:
    def __init__(self, rows: int = 24, cols: int = 80, autowrap: bool = False):
        self.rows = rows
        self.cols = cols
        # autowrap=False(默认):理想终端——col>=cols 直接截断(实现端自己软折,现有用例据此写)。
        # autowrap=True:严格 DEC 终端(如 Apple Terminal)——写满最后一列进入 pending-wrap
        #   (DEC Last-Column Flag),下个可打印字符才真换行。用于复现"终端 autowrap 致框线错位"。
        self.autowrap = autowrap
        self.grid = [[Cell() for _ in range(cols)] for _ in range(rows)]
        # wrapped[r]:第 r 行是上一行的软折续行(xterm.js 的 isWrapped)。resize 重排时
        # 软折的几行合成一条逻辑行;EL 2 / ED 擦过的行重新算独立一行。
        self.wrapped = [False] * rows
        # 滚出屏顶的行 [(cells, wrapped)]。resize 重排要它:变宽时终端把它们拉回屏上。
        self.history = []
        self.row = 0
        self.col = 0
        self.cursor_visible = True
        self.scrolled = 0
        self._pending_wrap = False  # DEC Last-Column Flag(仅 autowrap=True 用)
        self.sync_depth = 0  # ?2026h/l 配对计数(BSU/ESU)
        self.max_sync_depth = 0
        # DECSC/DECRC 存档的光标位置(ESC 7 / ESC 8)。
        self._saved_row = 0
        self._saved_col = 0
        # 当前 SGR 状态 → border_class
        self.cur_class = "plain"
        # ANSI 解析状态
        self._buf = b""

    # ---------------- 写入路径 ----------------

    def feed(self, data: bytes) -> None:
        # 拼接残留(跨 feed 的不完整序列)
        data = self._buf + data
        self._buf = b""
        i = 0
        n = len(data)
        while i < n:
            b = data[i]
            if b == 0x1B:  # ESC
                consumed = self._handle_escape(data, i)
                if consumed is None:
                    # 不完整序列,留到下次 feed
                    self._buf = data[i:]
                    return
                i += consumed
                continue
            if b == 0x0D:  # \r
                self.col = 0
                self._pending_wrap = False
                i += 1
                continue
            if b == 0x0A:  # \n
                # autowrap 下若处 pending-wrap:DEC 语义是 \n 仍只下移一行(延迟换行不叠加)。
                self._pending_wrap = False
                self._newline()
                i += 1
                continue
            if b == 0x09:  # \t → 当 1 空格(简化)
                self._put_char(" ", 1)
                i += 1
                continue
            if b < 0x20:  # 其它控制字符忽略
                i += 1
                continue
            # 可打印:解码一个 UTF-8 codepoint
            cp_len = (
                1 if b < 0x80
                else 2 if (b & 0xE0) == 0xC0
                else 3 if (b & 0xF0) == 0xE0
                else 4 if (b & 0xF8) == 0xF0
                else 1
            )
            if i + cp_len > n:
                self._buf = data[i:]  # 不完整 UTF-8,留到下次
                return
            chunk = data[i : i + cp_len]
            try:
                ch = chunk.decode("utf-8")
            except UnicodeDecodeError:
                ch = "�"  # 破碎 → replacement(测试可据此抓 UTF-8 bug)
                cp_len = 1
            self._put_char(ch, char_width(ord(ch)) if len(ch) == 1 else 1)
            i += cp_len

    def _handle_escape(self, data: bytes, i: int):
        """处理从 data[i]==ESC 开始的转义序列。返回消耗字节数,或 None(不完整)。"""
        n = len(data)
        if i + 1 >= n:
            return None
        c1 = data[i + 1]
        if c1 == ord("["):  # CSI
            return self._handle_csi(data, i)
        if c1 == ord("]"):  # OSC → 跳到 BEL 或 ST
            j = i + 2
            while j < n and data[j] != 0x07:
                if data[j] == 0x1B and j + 1 < n and data[j + 1] == ord("\\"):
                    return j + 2 - i
                j += 1
            if j < n:
                return j + 1 - i
            return None
        # ESC 7 = DECSC 存光标;ESC 8 = DECRC 复光标(transcript viewer inline 锚区顶用)。
        if c1 == ord("7"):
            self._saved_row = self.row
            self._saved_col = self.col
            return 2
        if c1 == ord("8"):
            self.row = self._saved_row
            self.col = self._saved_col
            return 2
        # ESC 后其它单字节 —— 吞 2 字节
        return 2

    def _handle_csi(self, data: bytes, i: int):
        n = len(data)
        j = i + 2
        # private 前缀 ? 或 >
        private = b""
        if j < n and data[j] in (ord("?"), ord(">")):
            private = bytes([data[j]])
            j += 1
        params = b""
        while j < n and (0x30 <= data[j] <= 0x3F):  # 参数字节 0-9 ; : < = > ?
            params += bytes([data[j]])
            j += 1
        # 中间字节(空格等)
        while j < n and (0x20 <= data[j] <= 0x2F):
            j += 1
        if j >= n:
            return None  # 不完整
        final = data[j]
        self._dispatch_csi(private, params, final)
        return j + 1 - i

    def _parse_params(self, params: bytes):
        if not params:
            return []
        out = []
        for p in params.split(b";"):
            try:
                out.append(int(p) if p else 0)
            except ValueError:
                out.append(0)
        return out

    def _dispatch_csi(self, private: bytes, params: bytes, final: int):
        ps = self._parse_params(params)
        f = chr(final)
        n1 = ps[0] if ps else 0
        if private:
            # ?25l/h 光标显隐
            if private == b"?" and ps and ps[0] == 25:
                self.cursor_visible = f == "h"
            # ?2026h/l Synchronized Output(BSU/ESU):记配对深度,供断言"整帧原子包裹"。
            elif private == b"?" and ps and ps[0] == 2026:
                if f == "h":
                    self.sync_depth += 1
                    self.max_sync_depth = max(self.max_sync_depth, self.sync_depth)
                elif f == "l" and self.sync_depth > 0:
                    self.sync_depth -= 1
            # ?1049h/l alt-screen:h=保存主屏(grid+光标)并清屏切到 alt;l=恢复主屏到进入前。
            # 真实终端行为——transcript viewer 靠它保护 scrollback、退出原样恢复输入框。
            elif private == b"?" and ps and ps[0] == 1049:
                if f == "h":
                    self._alt_saved = ([row[:] for row in self.grid], self.wrapped[:], self.row, self.col, self.scrolled)
                    self.grid = [[Cell() for _ in range(self.cols)] for _ in range(self.rows)]
                    self.wrapped = [False] * self.rows
                    self.row = 0
                    self.col = 0
                elif f == "l":
                    saved = getattr(self, "_alt_saved", None)
                    if saved is not None:
                        self.grid, self.wrapped, self.row, self.col, self.scrolled = saved
                        self._alt_saved = None
            return
        if f == "A":  # up
            self._pending_wrap = False
            self.row = max(0, self.row - max(1, n1))
        elif f == "B":  # down
            self._pending_wrap = False
            self.row = min(self.rows - 1, self.row + max(1, n1))
        elif f == "C":  # right
            self._pending_wrap = False
            self.col = min(self.cols - 1, self.col + max(1, n1))
        elif f == "D":  # left
            self._pending_wrap = False
            self.col = max(0, self.col - max(1, n1))
        elif f == "G":  # 绝对列(1-based)
            self._pending_wrap = False
            self.col = max(0, min(self.cols - 1, (n1 if ps else 1) - 1))
        elif f == "H" or f == "f":  # 绝对定位(1-based)
            self._pending_wrap = False
            r = (ps[0] if len(ps) >= 1 and ps[0] else 1) - 1
            c = (ps[1] if len(ps) >= 2 and ps[1] else 1) - 1
            self.row = max(0, min(self.rows - 1, r))
            self.col = max(0, min(self.cols - 1, c))
        elif f == "K":  # 清行
            mode = n1
            if mode == 2:
                for cell in self.grid[self.row]:
                    cell.clear()
                self.wrapped[self.row] = False
            elif mode == 0:
                for c in range(self.col, self.cols):
                    self.grid[self.row][c].clear()
                if self.col == 0:
                    self.wrapped[self.row] = False
            elif mode == 1:
                for c in range(0, self.col + 1):
                    self.grid[self.row][c].clear()
        elif f == "J":  # 清屏:0=光标到屏底,1=屏顶到光标,2=全屏
            if mode_is_full(n1):
                for rowcells in self.grid:
                    for cell in rowcells:
                        cell.clear()
                self.wrapped = [False] * self.rows
            elif n1 == 0:
                # 光标到屏幕末:当前行光标后 + 下方所有行(transcript viewer inline 退出 \x1b[J 用)。
                for c in range(self.col, self.cols):
                    self.grid[self.row][c].clear()
                if self.col == 0:
                    self.wrapped[self.row] = False
                for r in range(self.row + 1, self.rows):
                    for cell in self.grid[r]:
                        cell.clear()
                    self.wrapped[r] = False
            elif n1 == 1:
                # 屏顶到光标。
                for r in range(0, self.row):
                    for cell in self.grid[r]:
                        cell.clear()
                    self.wrapped[r] = False
                for c in range(0, self.col + 1):
                    self.grid[self.row][c].clear()
        elif f == "m":  # SGR → border_class
            self._apply_sgr(ps)

    def _apply_sgr(self, ps):
        if not ps:
            ps = [0]
        i = 0
        n = len(ps)
        while i < n:
            p = ps[i]
            if p == 38 or p == 48:
                # 扩展色:38;5;N(256)或 38;2;R;G;B(RGB)。48 是背景,跳过参数不改 class。
                if i + 1 < n and ps[i + 1] == 5:
                    idx = ps[i + 2] if i + 2 < n else 0
                    if p == 38:
                        self.cur_class = self._class_from_256(idx)
                    i += 3
                    continue
                elif i + 1 < n and ps[i + 1] == 2:
                    r = ps[i + 2] if i + 2 < n else 0
                    g = ps[i + 3] if i + 3 < n else 0
                    b = ps[i + 4] if i + 4 < n else 0
                    if p == 38:
                        self.cur_class = self._class_from_rgb(r, g, b)
                    i += 5
                    continue
                # 格式异常:跳过这个 38/48 不误吞后续
                i += 1
                continue
            if p == 0:
                self.cur_class = "plain"
            elif p == 2:
                self.cur_class = "dim"
            elif p == 36 or p == 96:  # cyan = accent(basic_16)
                self.cur_class = "accent"
            elif p == 34 or p == 94:  # blue = accent(light theme)
                self.cur_class = "accent"
            elif p == 33 or p == 93:  # yellow = warn
                self.cur_class = "warn"
            elif p == 31 or p == 91:  # red = danger
                self.cur_class = "danger"
            elif p == 39:
                self.cur_class = "plain"
            i += 1

    @staticmethod
    def _class_from_256(idx: int) -> str:
        """256 色索引 → border_class。16-231 是 6x6x6 立方,232-255 灰阶。
        映射到 theme 语义色:青/蓝→accent,黄→warn,红→danger,其余→plain。"""
        if 16 <= idx <= 231:
            c = idx - 16
            r = (c // 36) % 6
            g = (c // 6) % 6
            b = c % 6
            return Screen._class_from_rgb(r * 51, g * 51, b * 51)
        # 标准 16 色区:复用基本色判定
        cyan = {6, 14}
        blue = {4, 12}
        yellow = {3, 11}
        red = {1, 9}
        if idx in cyan or idx in blue:
            return "accent"
        if idx in yellow:
            return "warn"
        if idx in red:
            return "danger"
        return "plain"

    @staticmethod
    def _class_from_rgb(r: int, g: int, b: int) -> str:
        """RGB → border_class:按主色相归类(accent=青/蓝,warn=黄,danger=红)。"""
        # 近灰(三通道接近)→ plain
        if max(r, g, b) - min(r, g, b) < 40:
            return "plain"
        if b > r and (b > g or g > r):  # 蓝/青占优
            return "accent"
        if r > 120 and g > 120 and b < 120:  # 红+绿高、蓝低 = 黄
            return "warn"
        if r > g and r > b:  # 红占优
            return "danger"
        return "plain"

    def _put_char(self, ch: str, w: int):
        if self.autowrap:
            # 严格 DEC autowrap:若处 pending-wrap,先延迟换行(下移+回列0)再放字符。
            if self._pending_wrap:
                self._pending_wrap = False
                self.col = 0
                self._newline()
                self.wrapped[self.row] = True
            # 宽字符放不下当前行尾 → 也触发换行(简化:宽字符不跨行折半)。
            if w == 2 and self.col == self.cols - 1:
                self.col = 0
                self._newline()
                self.wrapped[self.row] = True
        else:
            if self.col >= self.cols:
                return  # 理想终端:实现端软折,不写溢出;防御性截断
        if self.col >= self.cols:
            return
        cell = self.grid[self.row][self.col]
        cell.ch = ch
        cell.width = max(1, w)
        cell.cont = False
        cell.border_class = self.cur_class
        cell.written = True
        if w == 2 and self.col + 1 < self.cols:
            cont = self.grid[self.row][self.col + 1]
            cont.clear()
            cont.cont = True
            cont.ch = ""
            cont.border_class = self.cur_class
            cont.written = True
        self.col += max(1, w)
        if self.autowrap:
            # 写到最后一列:进入 pending-wrap(光标停在末列,不立即换行)。
            if self.col >= self.cols:
                self.col = self.cols - 1
                self._pending_wrap = True
        else:
            if self.col > self.cols:
                self.col = self.cols

    def _newline(self):
        if self.row >= self.rows - 1:
            self._scroll_up(1)
        else:
            self.row += 1

    def _scroll_up(self, n: int):
        for _ in range(n):
            top = (self.grid.pop(0), self.wrapped.pop(0))
            if getattr(self, "_alt_saved", None) is None:  # alt-screen 没有 scrollback
                self.history.append(top)
            self.grid.append([Cell() for _ in range(self.cols)])
            self.wrapped.append(False)
            self.scrolled += 1

    # ---------------- 改尺寸 ----------------

    def resize(self, rows: int, cols: int, reflow: bool = True) -> None:
        """终端窗口改尺寸(SIGWINCH 那一刻终端对已显示内容做的事)。

        reflow=True:现代终端(iTerm2、Terminal.app、kitty、Ghostty、WezTerm、Windows
        Terminal、xterm.js、tmux)按逻辑行重排——变窄时长行折成多行,变宽时软折的行
        合回去;内容没满屏时贴屏顶,满屏时贴屏底(多出的行进 scrollback,少了从
        scrollback 拉回)。光标跟着它所在的那一格走。
        reflow=False:xterm / GNU screen 式裁剪——每行截断或补齐,行数不变,光标列夹到行内。
        """
        if getattr(self, "_alt_saved", None) is not None:
            raise NotImplementedError("resize while the alternate screen is active is not modeled")
        self._pending_wrap = False
        if reflow:
            self._reflow(rows, cols)
        else:
            self._clip(rows, cols)
        self.rows = rows
        self.cols = cols

    def _clip(self, rows: int, cols: int) -> None:
        for r, cells in enumerate(self.grid):
            self.grid[r] = (cells + [Cell() for _ in range(cols - len(cells))])[:cols]
            # 截断落在宽字符中间:那半个字符不再显示。
            if cols < len(cells) and cells[cols].cont:
                self.grid[r][cols - 1].clear()
        if rows < self.rows:
            # 屏幕变矮:保住光标所在行,顶上的行滚进 scrollback。
            drop = max(0, self.row - (rows - 1))
            for _ in range(drop):
                self.history.append((self.grid.pop(0), self.wrapped.pop(0)))
            self.row -= drop
            del self.grid[rows:]
            del self.wrapped[rows:]
        else:
            self.grid += [[Cell() for _ in range(cols)] for _ in range(rows - self.rows)]
            self.wrapped += [False] * (rows - self.rows)
        self.col = min(self.col, cols - 1)

    def _reflow(self, rows: int, cols: int) -> None:
        old = self.history + list(zip(self.grid, self.wrapped))
        cursor_at = len(self.history) + self.row
        # 内容到最后一个写过字符的行或光标所在行为止,其下的空行不参与重排。
        last = cursor_at
        for i in range(len(old) - 1, cursor_at, -1):
            if any(cell.written for cell in old[i][0]):
                last = i
                break
        # 软折的行拼成逻辑行,记下光标在逻辑行里的格子偏移。
        lines = []  # [cells, cursor_offset or None]
        for i, (cells, wrapped) in enumerate(old[: last + 1]):
            if not wrapped or not lines:
                lines.append([[], None])
            if i == cursor_at:
                lines[-1][1] = len(lines[-1][0]) + self.col
            lines[-1][0].extend(cells)
        out = []
        new_cursor = (0, 0)
        for cells, cursor in lines:
            end = len(cells)
            while end > 0 and not cells[end - 1].written:
                end -= 1
            chunks = [[]]
            at = []  # 每个格子落在 (第几段, 段内列)
            i = 0
            while i < end:
                width = 2 if i + 1 < end and cells[i + 1].cont else 1
                if len(chunks[-1]) + width > cols:
                    chunks.append([])
                for k in range(width):
                    at.append((len(chunks) - 1, len(chunks[-1])))
                    chunks[-1].append(cells[i + k])
                i += width
            if cursor is not None:
                if cursor < len(at):
                    seg, col = at[cursor]
                elif cursor == end and end > 0 and len(chunks[-1]) == cols:
                    # 刚写满最后一段:停在段尾等折行(DEC pending wrap),不落到下一行。
                    seg, col = len(chunks) - 1, cols - 1
                else:
                    # 光标在内容之后:接着最后一段往后数。
                    past = len(chunks[-1]) + cursor - end
                    seg, col = len(chunks) - 1 + past // cols, past % cols
                while len(chunks) <= seg:
                    chunks.append([])
                new_cursor = (len(out) + seg, col)
            for k, chunk in enumerate(chunks):
                out.append((chunk + [Cell() for _ in range(cols - len(chunk))], k > 0))
        # 满屏时贴底,但光标总在屏上。
        top = min(max(0, len(out) - rows), new_cursor[0])
        self.history = out[:top]
        screen = out[top : top + rows]
        screen += [([Cell() for _ in range(cols)], False) for _ in range(rows - len(screen))]
        self.grid = [cells for cells, _ in screen]
        self.wrapped = [wrapped for _, wrapped in screen]
        self.row = new_cursor[0] - top
        self.col = min(new_cursor[1], cols - 1)

    # ---------------- 读出路径 ----------------

    def line_text(self, row: int) -> str:
        if row < 0 or row >= self.rows:
            return ""
        out = []
        for cell in self.grid[row]:
            if cell.cont:
                continue
            out.append(cell.ch if cell.ch else "")
        return "".join(out).rstrip()

    def lines(self):
        return [self.line_text(r) for r in range(self.rows)]

    def cursor(self):
        return (self.row, self.col)

    def line_attr_class(self, row: int) -> str:
        """该行首个非空、非空格单元格的 border_class。"""
        if row < 0 or row >= self.rows:
            return "plain"
        for cell in self.grid[row]:
            if cell.cont:
                continue
            if cell.ch and cell.ch != " ":
                return cell.border_class
        return "plain"

    def find_row(self, substr: str):
        for r in range(self.rows):
            if substr in self.line_text(r):
                return r
        return None

    def find_last_row(self, substr: str):
        for r in range(self.rows - 1, -1, -1):
            if substr in self.line_text(r):
                return r
        return None

    def render_ascii(self) -> str:
        """人类可读 dump:行号 + 内容 + 光标标记 ▮。"""
        out = []
        for r in range(self.rows):
            txt = self.line_text(r)
            mark = ""
            if r == self.row:
                # 在光标列插入标记(粗略,按显示列)
                mark = f"   <cursor col={self.col}>"
            out.append(f"{r:2d} │{txt}{mark}")
        return "\n".join(out)


def mode_is_full(n: int) -> bool:
    return n == 2 or n == 3
