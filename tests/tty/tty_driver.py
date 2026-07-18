"""PTY 驱动器 —— 起二进制(isatty=true)、设窗口大小、按高层键序列喂键、抓字节。

复用 tests/e2e/pty_probe.py 的 fork/drain 心法,参数化成可复用 run()。

双后端:
  - POSIX:pty.fork + TIOCSWINSZ(原实现,零变化)。
  - Windows:ConPTY(pywinpty)。子进程拿到真 pseudo console(isatty=true),键序列
    以 VT 字节写入、由 ConPTY 翻译成 console input;输出是 ConPTY **重合成**的标准 VT
    序列(CUP/EL/SGR…),screen.py 按 VT 语义回放,断言语义等价。依赖:pip install pywinpty。

等待语义(事件 + sleep 上限结合,2026-07-18):
  - `sleep:N` = **settle 睡眠**:至多 N 秒,连续 QUIET_SLEEP 秒无新输出字节即提前返回。
    可靠性依据:生成/工具执行期 watcher 以 100ms poll 超时驱动 spinner 重画
    (tui_backend.zig watcherMain),TUI 忙时流不会静默 >0.1s;静默 0.8s ⇔ turn 结束或
    等待输入。N 仍是最坏情况兜底(行为等价旧全睡语义的上界)。
  - `strictsleep:N` = 旧语义,睡满 N 秒。**时序断言**(逐帧快照/否定断言"N 秒内不出现
    X")必须用它——settle 提前退出会把这类窗口静默削短。
  - `wait:PATTERN:N` = 等渲染后的屏幕任一行含 PATTERN(至多 N 秒),命中后短 settle
    防抓半帧。超时不抛错(交给用例自身断言给出屏幕 diff)。
  两后端共享同一份实现(_Capture),只有"读一片字节"原语按平台实现——语义永不分叉。
"""
import os
import subprocess
import sys
import time

IS_WINDOWS = sys.platform == "win32"
if not IS_WINDOWS:
    import pty
    import select
    import struct
    import fcntl
    import termios

# settle 静默阈值:必须显著大于 TUI 忙时最大重画间隔(spinner poll 100ms)与
# slow_mock_server 的 __DELAY__ 分片(≤0.5s;注意 delay 期间 spinner 仍在重画,
# 真正的静默只出现在 turn 结束/等输入时)。
QUIET_SLEEP = 0.8
# 键间 drain 的静默阈值:回显重画在写键后 ~毫秒级到达,0.2s 足够;打字落在生成期时
# 流本就不静默,退化为睡满 per_key_drain(与旧行为一致)。
QUIET_KEY = 0.2
# wait: 命中后的短 settle,防止断言抓到重画中途的半帧。
SETTLE_AFTER_HIT = 0.3

# 高层键名 → 字节
SPECIAL = {
    "enter": b"\r",
    "shift_enter": b"\x1b[13;2u",  # CSI u
    "ctrl_enter": b"\x1b[13;5u",
    "backspace": b"\x7f",
    "ctrl_h": b"\x08",
    "left": b"\x1b[D",
    "right": b"\x1b[C",
    "up": b"\x1b[A",
    "down": b"\x1b[B",
    "home": b"\x1b[H",
    "end": b"\x1b[F",
    "shift_tab": b"\x1b[Z",
    "tab": b"\t",
    "ctrl_u": b"\x15",
    "ctrl_y": b"\x19",
    "ctrl_w": b"\x17",
    "ctrl_k": b"\x0b",
    "ctrl_c": b"\x03",
    "ctrl_d": b"\x04",
    "ctrl_o": b"\x0f",
    "ctrl_t": b"\x14",
    "ctrl_l": b"\x0c",
    "ctrl_r": b"\x12",
    "esc": b"\x1b",
}

KEEPALIVE = b"0011Ignore"


class _KeepaliveFilter:
    """流式滤除 pywinpty agent 的 keepalive 标记(可能跨 recv 块被切开)。

    旧实现按整包比对(data == KEEPALIVE),流合并场景漏滤(review-2 P2 记档):
    标记混进输出既污染断言,也会打破 settle 静默检测(早退永不触发)。本类跨块匹配:
    尾部凡是标记真前缀的字节先扣住(carry ≤ len-1 字节),拼上下一块再判;
    run 结束 flush() 把扣住的合法尾字节还回输出。
    """

    def __init__(self):
        self._carry = b""

    def feed(self, data):
        buf = self._carry + data
        self._carry = b""
        buf = buf.replace(KEEPALIVE, b"")
        for k in range(min(len(KEEPALIVE) - 1, len(buf)), 0, -1):
            if buf.endswith(KEEPALIVE[:k]):
                self._carry = buf[-k:]
                buf = buf[:-k]
                break
        return buf

    def flush(self):
        c, self._carry = self._carry, b""
        return c


class _Capture:
    """输出捕获 + 全部等待原语(两后端共享同一份实现)。

    read_once(slice_s) 由后端注入:阻塞至多 slice_s 秒;返回本次新字节
    (b"" = 本片无输出;None = EOF/不可恢复错误)。平台差异(select 对象、
    keepalive 过滤、宽字符)全部在 read_once 内消化,等待语义这里只有一份。
    """

    def __init__(self, read_once, rows, cols):
        self._read_once = read_once
        self.out = bytearray()
        self.rows = rows
        self.cols = cols
        self.eof = False
        self._screen = None
        self._fed = 0

    def _pump(self, slice_s):
        """读一片。返回 True 当且仅当收到了新字节。"""
        if self.eof:
            return False
        data = self._read_once(slice_s)
        if data is None:
            self.eof = True
            return False
        if data:
            self.out.extend(data)
            return True
        return False

    def drain(self, timeout):
        """严格 drain:持续收字节直到窗口睡满(strictsleep/resize/settle-after-hit)。"""
        end = time.time() + timeout
        while time.time() < end and not self.eof:
            self._pump(0.05)

    def drain_settle(self, timeout, quiet):
        """settle drain:至多 timeout 秒;连续 quiet 秒无新字节即提前返回。"""
        start = time.time()
        end = start + timeout
        last = start
        while True:
            now = time.time()
            if now >= end or self.eof or (now - last) >= quiet:
                return
            if self._pump(0.05):
                last = time.time()

    def screen_has(self, pattern):
        """渲染后的屏幕任一行含 pattern(增量喂持久 Screen;feed 自带跨块残留缓冲)。"""
        if self._screen is None:
            from screen import Screen
            self._screen = Screen(self.rows, self.cols)
        if self._fed < len(self.out):
            self._screen.feed(bytes(self.out[self._fed:]))
            self._fed = len(self.out)
        sc = self._screen
        return any(pattern in sc.line_text(r) for r in range(sc.rows))

    def wait_pattern(self, pattern, timeout):
        """等屏幕出现 pattern,至多 timeout 秒;命中后短 settle。超时静默返回 False。"""
        end = time.time() + timeout
        while True:
            if self.screen_has(pattern):
                self.drain(SETTLE_AFTER_HIT)
                return True
            if time.time() >= end or self.eof:
                return False
            self._pump(0.1)


def _set_winsize(fd, rows, cols):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


def _build_env(base_url, env):
    """两后端共用的隔离 env。"""
    full_env = dict(os.environ)
    full_env["METACODES_LOG"] = "*:warn"
    full_env["FORCE_COLOR"] = "1"  # 锁 basic_16,让 accent/warn 是固定标准色 SGR
    # 离线:跳过启动期 probeModels 网络调用——它在无网/沙箱里会 hang,导致 REPL 永不渲染
    # (实测根因:pty 下 0 字节 = 卡在 probeModels,非 drain 时序)。
    full_env["METACODES_NO_PROBE"] = "1"
    # Offline UI tests use a dead base_url and never send a real model request.
    # OAuth removed the old built-in token fallback, so provide a dummy bearer
    # only for that offline path. Live model tests pass base_url=None and must
    # keep the user's real env/OAuth credential resolution intact.
    if base_url:
        full_env.setdefault("METASK_API_KEY", "tty-dummy-key")
    # HOME 隔离:不读用户真实 ~/.claude / ~/.metacodes(settings/agents/skills),保证可重复。
    full_env.setdefault("HOME", "/tmp/cc-tty-home")
    os.makedirs(full_env["HOME"], exist_ok=True)
    if IS_WINDOWS:
        # Windows 侧 homeDir 走 USERPROFILE;与 HOME 指向同一隔离目录。
        full_env["USERPROFILE"] = os.path.abspath(full_env["HOME"])
    if env:
        for k, v in env.items():
            if v is None:
                full_env.pop(k, None)
            else:
                full_env[k] = v
    return full_env


def _drive(key_events, write, cap, set_size, per_key_drain):
    """按 key_events 驱动(两后端共用)。write 收 bytes;set_size 收 (rows, cols)。"""
    for ev in key_events:
        if ev.startswith("type:"):
            text = ev[5:]
            for ch in text:
                write(ch.encode("utf-8"))
                cap.drain_settle(per_key_drain, QUIET_KEY)
        elif ev.startswith("key:"):
            name = ev[4:]
            write(SPECIAL.get(name, b""))
            cap.drain_settle(per_key_drain, QUIET_KEY)
        elif ev.startswith("strictsleep:"):
            cap.drain(float(ev[12:]))
        elif ev.startswith("sleep:"):
            cap.drain_settle(float(ev[6:]), QUIET_SLEEP)
        elif ev.startswith("wait:"):
            pattern, _, t = ev[5:].rpartition(":")
            cap.wait_pattern(pattern, float(t))
        elif ev.startswith("resize:"):
            spec = ev[7:]
            r2, c2 = spec.split("x")
            set_size(int(r2), int(c2))
            cap.drain(0.2)
        elif ev.startswith("raw:"):
            write(ev[4:].encode("latin-1", "ignore").decode("unicode_escape").encode("latin-1"))
            cap.drain_settle(per_key_drain, QUIET_KEY)


def run(bin_path, key_events, term_size=(24, 80), env=None,
        startup_drain=0.8, per_key_drain=0.25, base_url="http://127.0.0.1:1/v1/messages",
        permission="bypassPermissions", cwd=None):
    """fork pty,设窗口,exec bin,按 key_events 喂键,返回合并原始字节流。

    base_url: 默认指死端口(连接立即 refused,probeModels/请求不 hang)——离线渲染测试用。
              打真实模型的 case(test_generating 等)传 base_url=None 用硬编码真端点。
    permission: --permission 模式(默认 bypassPermissions 免弹窗;测权限弹窗传 "default")。
    cwd: 子进程工作目录(默认继承)。测权限弹窗时传隔离临时目录,避免项目 .claude/settings 污染。

    key_events 元素(字符串):
      "type:文本"        逐 codepoint 写(模拟打字,每字单独 drain → 暴露逐帧 bug)
      "key:NAME"         SPECIAL[NAME]
      "sleep:N"          settle 睡眠:至多 N 秒,输出静默 QUIET_SLEEP 秒即提前返回
      "strictsleep:N"    睡满 N 秒(时序断言/否定断言窗口专用)
      "wait:PATTERN:N"   等屏幕出现 PATTERN,至多 N 秒(命中后短 settle)
      "resize:RxC"       运行中改窗口(触 SIGWINCH / ConPTY resize)
      "raw:..."          原样字节(用 \\xNN 转义)
    """
    rows, cols = term_size
    # bin_path 转绝对路径:cwd 非 None 时子进程会 chdir,相对 bin_path 会失效。
    bin_path = os.path.abspath(bin_path)
    full_env = _build_env(base_url, env)

    if IS_WINDOWS:
        return _run_windows(bin_path, key_events, (rows, cols), full_env,
                            permission, base_url, cwd, startup_drain, per_key_drain)

    pid, fd = pty.fork()
    if pid == 0:
        # 子进程
        try:
            os.environ.clear()
            os.environ.update(full_env)
            if cwd:
                os.chdir(cwd)
            argv = [bin_path, "--permission", permission]
            if base_url:
                # 死端口兜底:即便 NO_PROBE 失效,网络调用也立即 refused 不 hang。
                argv += ["--base-url", base_url]
            os.execv(bin_path, argv)
        except OSError:
            os._exit(127)
        os._exit(127)

    # 父进程
    try:
        _set_winsize(fd, rows, cols)
    except OSError:
        pass

    def read_once(slice_s):
        r, _, _ = select.select([fd], [], [], slice_s)
        if not r:
            return b""
        try:
            data = os.read(fd, 8192)
        except OSError:
            return None
        if not data:
            return None
        return data

    cap = _Capture(read_once, rows, cols)

    def write(b):
        try:
            os.write(fd, b)
        except OSError:
            pass

    def set_size(r2, c2):
        try:
            _set_winsize(fd, r2, c2)
        except OSError:
            pass

    cap.drain(startup_drain)
    _drive(key_events, write, cap, set_size, per_key_drain)

    cap.drain(0.5)
    try:
        os.close(fd)
    except OSError:
        pass
    try:
        os.waitpid(pid, 0)
    except OSError:
        pass
    return bytes(cap.out)


def _run_windows(bin_path, key_events, term_size, full_env,
                 permission, base_url, cwd, startup_drain, per_key_drain):
    """ConPTY 后端。与 POSIX run() 相同的键序列/drain 语义,返回原始字节流(UTF-8)。

    走 pywinpty 高层 PtyProcess(argv 列表 + env dict,它负责 which/cmdline/env 块拼装
    ——裸 PTY.spawn 的 cmdline 约定是"前导空格 + 不含 argv0",手拼极易踩坑,实测踩过)。
    其 fileobj 是本机 socket,Windows 上可 select → 非阻塞 drain 收原始 bytes。
    """
    import select as _select
    from winpty.ptyprocess import PtyProcess  # 延迟 import:POSIX 环境无此依赖

    rows, cols = term_size
    argv = [bin_path, "--permission", permission]
    if base_url:
        argv += ["--base-url", base_url]

    proc = PtyProcess.spawn(argv, cwd=(cwd or None), env=full_env, dimensions=(rows, cols))
    sock = proc.fileobj
    kfilter = _KeepaliveFilter()

    def read_once(slice_s):
        r, _, _ = _select.select([sock], [], [], slice_s)
        if not r:
            return b""
        try:
            data = sock.recv(8192)
        except OSError:
            return None
        if not data:
            return None
        return kfilter.feed(data)  # 整片是 keepalive 时返回 b"" → 不算新字节,不打破静默

    cap = _Capture(read_once, rows, cols)

    def write(b):
        # PtyProcess.write 收 str(内部 utf-8 编码)。type: 的 CJK 字节按 utf-8 还原;
        # SPECIAL/raw 是 ASCII/ESC 字节,latin-1 兜底。
        try:
            s = b.decode("utf-8")
        except UnicodeDecodeError:
            s = b.decode("latin-1")
        try:
            proc.write(s)
        except Exception:  # noqa: BLE001
            pass

    def set_size(r2, c2):
        try:
            proc.setwinsize(r2, c2)
        except Exception:  # noqa: BLE001
            pass

    cap.drain(startup_drain)
    # ConPTY + debug 二进制启动明显慢于 POSIX(实测首帧 ~2-3s):固定 startup_drain 会
    # 抓到 0 字节假失败。自适应:未见首个完整帧(show-cursor 标记)就继续等,上限 10s。
    deadline = time.time() + 10.0
    while b"\x1b[?25h" not in cap.out and time.time() < deadline:
        cap.drain(0.3)
    # 键间 drain 同理放宽下限(0.25s 在 ConPTY 下常抓不到该键引发的重画)。
    _drive(key_events, write, cap, set_size, max(per_key_drain, 0.4))

    # 收尾:静默检测——持续有新字节就继续收(如 /help 输出、退出清理帧),0.6s 无新字节才停,上限 6s。
    cap.drain_settle(6.0, 0.6)
    cap.out.extend(kfilter.flush())
    try:
        proc.terminate(force=True)
    except Exception:  # noqa: BLE001
        pass
    return bytes(cap.out)
