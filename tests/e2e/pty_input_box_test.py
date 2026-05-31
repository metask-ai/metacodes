#!/usr/bin/env python3
"""PTY 输入框渲染回归测试(自断言,无需真实模型 / token)。

用 pty.fork 起 metacodes 让它以为连了真终端(isatty=true)→ 触发 RenderRegion
输入框渲染。逐字符喂键(只在打字阶段验证,**不提交查询**,故不打模型、可进默认 CI),
捕获原始 ANSI 字节,断言:

  1. 每帧回顶的 cursor-up(`ESC[<n>A`)序列稳定(只含小数字、不递增)
     —— 这是"输入框跳动" bug 的精确回归点(修复前会递增/出现大数字)。
  2. 框元素每帧齐全且数量一致(上边框 ╭ / 下边框 ╰ / ❯ / footer)。
  3. 从不出现 `ESC[2J`(全屏清屏)—— 不碰 scrollback 的硬规则。
  4. 退出干净(show cursor `ESC[?25h`)。

退出码:0 = 全部通过;1 = 有断言失败(打印失败详情);2 = 运行/环境错误。

用法:pty_input_box_test.py [BIN]
"""
import os
import pty
import sys
import time
import select
import re

BIN = sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/metacodes-debug"
KEYS = "abc"  # 打字 3 个普通字符触发 3 次重画(跳动会在这阶段暴露)


def run_capture():
    """起 pty 跑二进制,喂键,返回捕获的原始字节。"""
    pid, fd = pty.fork()
    if pid == 0:
        os.environ["METACODES_LOG"] = "*:warn"
        try:
            os.execv(BIN, [BIN, "--permission", "bypassPermissions"])
        except OSError:
            os._exit(127)
        os._exit(127)

    out = bytearray()

    def drain(timeout):
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

    drain(0.8)                 # banner + 初始输入框
    for ch in KEYS:            # 逐字符打字(跳动 bug 在此阶段暴露)
        os.write(fd, ch.encode())
        drain(0.3)
    os.write(fd, b"\x15")      # Ctrl+U 清行(不提交,省 model 调用)
    drain(0.3)
    os.write(fd, b"/exit\r")   # 退出
    drain(0.8)
    try:
        os.close(fd)
    except OSError:
        pass
    try:
        os.waitpid(pid, 0)
    except OSError:
        pass
    return bytes(out)


def main():
    if not os.access(BIN, os.X_OK):
        print(f"[SKIP] 二进制不存在/不可执行: {BIN}", file=sys.stderr)
        return 2
    try:
        raw = run_capture()
    except Exception as e:  # noqa: BLE001
        print(f"[ERROR] PTY 运行失败: {e}", file=sys.stderr)
        return 2

    failures = []

    # 必须真的渲染了输入框(否则可能根本没进 RenderRegion 路径 → 测试无意义)
    n_top = raw.count("╭".encode())
    n_bot = raw.count("╰".encode())
    n_ptr = raw.count("❯".encode())
    n_foot = raw.count(b"? for shortcuts")
    if n_top == 0 or n_ptr == 0:
        print(f"[ERROR] 未检测到输入框渲染(╭={n_top} ❯={n_ptr})——pty 可能没驱动到 tty 路径", file=sys.stderr)
        return 2

    # 断言 1:每帧框元素齐全(上=下边框数,且 ❯/footer 与边框同数)
    if not (n_top == n_bot == n_ptr == n_foot):
        failures.append(f"框元素数量不一致:╭={n_top} ╰={n_bot} ❯={n_ptr} footer={n_foot}(应全相等)")

    # 断言 2(核心:防跳动):cursor-up `ESC[<n>A` 的 n 必须都是小数字(<=区高,这里<=3),
    #   且整段序列不出现"递增漂移"。修复前回顶用总行数(4)或随帧递增。
    ups = [int(m.decode() or "1") for m in re.findall(rb"\x1b\[(\d*)A", raw)]
    big = [n for n in ups if n > 3]
    if big:
        failures.append(f"cursor-up 出现大跨度回退 {big}(应 <=3;说明框在漂移/跳动)")
    # 检测单调递增漂移:连续 3 个严格递增即判失败
    for i in range(len(ups) - 2):
        if ups[i] < ups[i + 1] < ups[i + 2]:
            failures.append(f"cursor-up 连续递增 {ups[i:i+3]}(典型逐帧上漂)")
            break

    # 断言 3:绝不全屏清屏(碰 scrollback)
    n_2j = raw.count(b"\x1b[2J")
    if n_2j != 0:
        failures.append(f"出现 {n_2j} 次 ESC[2J(全屏清屏,会清掉 scrollback;输入框重绘不应用它)")

    # 断言 4:退出 show cursor
    if raw.count(b"\x1b[?25h") == 0:
        failures.append("未检测到 show-cursor(ESC[?25h);退出可能留隐藏光标")

    if failures:
        print("=== PTY 输入框测试 FAIL ===")
        for f in failures:
            print("  ✗ " + f)
        print(f"  (cursor-up 序列={ups})")
        return 1

    print("=== PTY 输入框测试 PASS ===")
    print(f"  框={n_top} 帧,cursor-up 序列={ups}(稳定不漂),ESC[2J=0,show-cursor ✓")
    return 0


if __name__ == "__main__":
    sys.exit(main())
