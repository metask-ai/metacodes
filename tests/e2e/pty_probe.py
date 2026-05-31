#!/usr/bin/env python3
# PTY 驱动 cc-zig 验证 TUI 输入框渲染(headless 真 tty)。
# 起一个 pty,让 metacodes 以为连了真终端(isatty=true)→ 触发 RenderRegion 输入框。
# 喂几个字符 + /exit,捕获原始 ANSI 输出,打印可读化(转义可见)供核查跳动。
import os, pty, sys, time, select, re

BIN = sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/metacodes-debug"
keys = sys.argv[2] if len(sys.argv) > 2 else "hi"

def main():
    pid, fd = pty.fork()
    if pid == 0:
        # 子进程:exec 二进制(继承 pty 作为 stdin/stdout/stderr → isatty 真)
        os.environ["METACODES_LOG"] = "*:warn"
        os.execv(BIN, [BIN, "--permission", "bypassPermissions"])
        os._exit(127)

    # 父进程:喂输入 + 收输出
    out = bytearray()
    def drain(timeout=0.4):
        end = time.time() + timeout
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.1)
            if r:
                try:
                    data = os.read(fd, 4096)
                except OSError:
                    return
                if not data:
                    return
                out.extend(data)
    drain(0.8)                      # 启动 banner + 初始输入框
    for ch in keys:                 # 逐字符喂(模拟打字)——跳动 bug 发生在打字阶段
        os.write(fd, ch.encode())
        drain(0.25)
    # 不提交真实查询(省 model 调用);清空当前行 + /exit 退出
    os.write(fd, b"\x15")           # Ctrl+U 清行
    drain(0.3)
    os.write(fd, b"/exit\r")        # 退出
    drain(0.8)
    try:
        os.close(fd)
    except OSError:
        pass
    try:
        os.waitpid(pid, 0)
    except OSError:
        pass

    raw = bytes(out)
    # 可读化:把 ESC 转成 <ESC>,统计关键 ANSI
    vis = raw.replace(b"\x1b", b"<ESC>")
    sys.stdout.write("=== 可读化输出(<ESC> = 0x1b)===\n")
    sys.stdout.write(vis.decode("utf-8", "replace"))
    sys.stdout.write("\n=== 统计 ===\n")
    ups = re.findall(rb"\x1b\[(\d*)A", raw)              # cursor up N
    print("cursor-up 序列(每次按键回顶应是小数字,如 1/2,不应递增):", [u.decode() or "1" for u in ups])
    print("box 上边框 ╭ 次数:", raw.count("╭".encode()))
    print("box 下边框 ╰ 次数:", raw.count("╰".encode()))
    print("❯ pointer 次数:", raw.count("❯".encode()))
    print("footer '? for shortcuts' 次数:", raw.count(b"? for shortcuts"))
    print("含 \\x1b[2J(全屏清,应为 0):", raw.count(b"\x1b[2J"))

main()
