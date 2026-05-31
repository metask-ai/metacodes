"""PTY 驱动器 —— fork 起二进制(isatty=true)、设窗口大小、按高层键序列喂键、抓字节。

复用 tests/e2e/pty_probe.py 的 fork/drain 心法,参数化成可复用 run()。
"""
import os
import pty
import sys
import time
import select
import struct
import fcntl
import termios

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
    "ctrl_c": b"\x03",
    "ctrl_d": b"\x04",
    "esc": b"\x1b",
}


def _set_winsize(fd, rows, cols):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


def run(bin_path, key_events, term_size=(24, 80), env=None,
        startup_drain=0.8, per_key_drain=0.25):
    """fork pty,设窗口,exec bin,按 key_events 喂键,返回合并原始字节流。

    key_events 元素(字符串):
      "type:文本"      逐 codepoint 写(模拟打字,每字单独 drain → 暴露逐帧 bug)
      "key:NAME"       SPECIAL[NAME]
      "sleep:N"        父进程等待 N 秒 + drain
      "resize:RxC"     运行中改窗口(触 SIGWINCH)
      "raw:..."        原样字节(用 \\xNN 转义)
    """
    rows, cols = term_size
    full_env = dict(os.environ)
    full_env["METACODES_LOG"] = "*:warn"
    full_env["FORCE_COLOR"] = "1"  # 锁 basic_16,让 accent/warn 是固定标准色 SGR
    if env:
        full_env.update(env)

    pid, fd = pty.fork()
    if pid == 0:
        # 子进程
        try:
            os.environ.clear()
            os.environ.update(full_env)
            os.execv(bin_path, [bin_path, "--permission", "bypassPermissions"])
        except OSError:
            os._exit(127)
        os._exit(127)

    # 父进程
    try:
        _set_winsize(fd, rows, cols)
    except OSError:
        pass

    out = bytearray()

    def drain(timeout):
        end = time.time() + timeout
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.05)
            if r:
                try:
                    data = os.read(fd, 8192)
                except OSError:
                    return
                if not data:
                    return
                out.extend(data)

    def write(b):
        try:
            os.write(fd, b)
        except OSError:
            pass

    drain(startup_drain)

    for ev in key_events:
        if ev.startswith("type:"):
            text = ev[5:]
            for ch in text:
                write(ch.encode("utf-8"))
                drain(per_key_drain)
        elif ev.startswith("key:"):
            name = ev[4:]
            write(SPECIAL.get(name, b""))
            drain(per_key_drain)
        elif ev.startswith("sleep:"):
            drain(float(ev[6:]))
        elif ev.startswith("resize:"):
            spec = ev[7:]
            r2, c2 = spec.split("x")
            try:
                _set_winsize(fd, int(r2), int(c2))
            except OSError:
                pass
            drain(0.2)
        elif ev.startswith("raw:"):
            write(ev[4:].encode("latin-1", "ignore").decode("unicode_escape").encode("latin-1"))
            drain(per_key_drain)

    drain(0.5)
    try:
        os.close(fd)
    except OSError:
        pass
    try:
        os.waitpid(pid, 0)
    except OSError:
        pass
    return bytes(out)
