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


def _set_winsize(fd, rows, cols):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


def run(bin_path, key_events, term_size=(24, 80), env=None,
        startup_drain=0.8, per_key_drain=0.25, base_url="http://127.0.0.1:1/v1/messages",
        permission="bypassPermissions", cwd=None):
    """fork pty,设窗口,exec bin,按 key_events 喂键,返回合并原始字节流。

    base_url: 默认指死端口(连接立即 refused,probeModels/请求不 hang)——离线渲染测试用。
              打真实模型的 case(test_generating 等)传 base_url=None 用硬编码真端点。
    permission: --permission 模式(默认 bypassPermissions 免弹窗;测权限弹窗传 "default")。
    cwd: 子进程工作目录(默认继承)。测权限弹窗时传隔离临时目录,避免项目 .claude/settings 污染。

    key_events 元素(字符串):
      "type:文本"      逐 codepoint 写(模拟打字,每字单独 drain → 暴露逐帧 bug)
      "key:NAME"       SPECIAL[NAME]
      "sleep:N"        父进程等待 N 秒 + drain
      "resize:RxC"     运行中改窗口(触 SIGWINCH)
      "raw:..."        原样字节(用 \\xNN 转义)
    """
    rows, cols = term_size
    # bin_path 转绝对路径:cwd 非 None 时子进程会 chdir,相对 bin_path 会失效。
    bin_path = os.path.abspath(bin_path)
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
    if env:
        for k, v in env.items():
            if v is None:
                full_env.pop(k, None)
            else:
                full_env[k] = v

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
