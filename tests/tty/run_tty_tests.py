#!/usr/bin/env python3
"""TTY 测试 runner —— 收集 cases/*.py 的 test_* 函数,逐个跑,汇总 pass/fail。

每个 case 函数签名:def test_xxx(bin_path) -> None,失败 raise AssertError(含屏幕 diff)。
退出码:0 全过;1 有失败;2 环境错误(无二进制 / 非 macOS-Linux)。

**实时输出**:每条测试开始前先打 `▶ <name> …`、结束后打结果 + 耗时,每行都 flush。
被管道/重定向到文件时(非 tty)Python 默认块缓冲会把输出攒到进程退出——本 runner 强制
每条 flush(见 _emit),故 `tail -f` 日志能逐条看到进度,不会"卡到最后才出全部结果"。

**分片**:`--shard K/N`(或环境变量 `TTY_SHARD=K/N`,`zig build windows:tty` 经它透传)只跑
排序后用例表里下标 `i % N == K-1` 的那些:N 个分片恰好覆盖全表、互不重叠,且慢用例按模块聚集,
轮转能把它们摊到各片。CI 的 TTY job 按分片在多台 runner 上并行(doc/CI_DESIGN.md §4)。

用法:
  python3 tests/tty/run_tty_tests.py --bin zig-out/bin/metacodes-debug [-k 过滤] [--shard K/N] [-v]
"""
import os
import sys
import time
import importlib.util
import traceback

# Windows 控制台默认代码页(GBK 等)编不了 ▶/✓/⊘ → UnicodeEncodeError 直接带崩 runner。
# 统一强制 UTF-8(POSIX 上本来就是,无变化);errors=replace 兜底任何环境。
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)  # 让 cases 能 import screen/asserts/tty_driver

from asserts import AssertError  # noqa: E402
from tty_driver import release_case_dirs  # noqa: E402
try:
    from e2e_helpers import SkipTest  # noqa: E402
except Exception:  # noqa: BLE001
    class SkipTest(Exception):  # fallback:e2e_helpers 不可用时仍可跑非 e2e 用例
        pass


def _emit(line, *, newline=True):
    """打印一行并**立即 flush**(被重定向到文件时也实时可见,不被块缓冲攒住)。"""
    sys.stdout.write(line + ("\n" if newline else ""))
    sys.stdout.flush()


def load_cases():
    cases = []
    cases_dir = os.path.join(HERE, "cases")
    for fn in sorted(os.listdir(cases_dir)):
        if not fn.startswith("test_") or not fn.endswith(".py"):
            continue
        path = os.path.join(cases_dir, fn)
        spec = importlib.util.spec_from_file_location(fn[:-3], path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        for name in sorted(dir(mod)):
            if name.startswith("test_"):
                cases.append((f"{fn[:-3]}.{name}", getattr(mod, name)))
    return cases


def parse_shard(text):
    """`K/N`(1 ≤ K ≤ N)→ (K, N);格式不对返回 None。"""
    parts = text.split("/")
    if len(parts) != 2 or not all(p.isdigit() for p in parts):
        return None
    index, count = int(parts[0]), int(parts[1])
    if count < 1 or not 1 <= index <= count:
        return None
    return index, count


def select_shard(cases, index, count):
    """第 index 片(1 起):下标 i % count == index-1 的用例。count 片恰好划分全表。"""
    return [case for i, case in enumerate(cases) if i % count == index - 1]


def main():
    args = sys.argv[1:]
    bin_path = "zig-out/bin/metacodes-debug"
    kfilter = None
    shard_text = os.environ.get("TTY_SHARD") or None
    i = 0
    while i < len(args):
        if args[i] == "--bin":
            bin_path = args[i + 1]
            i += 2
        elif args[i] == "-k":
            kfilter = args[i + 1]
            i += 2
        elif args[i] == "--shard":
            shard_text = args[i + 1]
            i += 2
        elif args[i] == "-v":
            i += 1
        else:
            i += 1

    shard = None
    if shard_text is not None:
        shard = parse_shard(shard_text)
        if shard is None:
            print(f"[ERROR] 分片须为 K/N(1 ≤ K ≤ N): {shard_text}", file=sys.stderr)
            return 2

    if not os.access(bin_path, os.X_OK):
        print(f"[ERROR] 二进制不存在/不可执行: {bin_path}", file=sys.stderr)
        return 2

    cases = load_cases()
    if kfilter:
        cases = [(n, f) for n, f in cases if kfilter in n]
    if shard is not None:
        cases = select_shard(cases, *shard)
    if not cases:
        print("[ERROR] 没有匹配的用例", file=sys.stderr)
        return 2

    passed = 0
    failed = []
    skipped = []
    total = len(cases)
    shard_note = f",分片 {shard[0]}/{shard[1]}" if shard is not None else ""
    _emit(f"=== TTY 测试:{total} 个用例{shard_note},bin={bin_path} ===\n")
    suite_t0 = time.monotonic()
    for idx, (name, fn) in enumerate(cases, 1):
        # 先打"开始"行(无换行,带 carriage-return 风格的进度前缀),立即 flush
        # → 即使该测试要跑 40s,日志也立刻显示"正在跑哪条",不会黑屏到结束。
        _emit(f"[{idx}/{total}] ▶ {name} … ", newline=False)
        t0 = time.monotonic()
        try:
            fn(bin_path)
            dt = time.monotonic() - t0
            _emit(f"✓ ({dt:.1f}s)")
            passed += 1
        except SkipTest as e:
            dt = time.monotonic() - t0
            # 真模型漂移:被测路径未触发(模型没调目标工具)→ 跳过,非失败。
            _emit(f"⊘ skip ({dt:.1f}s): {e}")
            skipped.append(name)
        except AssertError as e:
            dt = time.monotonic() - t0
            _emit(f"✗ FAIL ({dt:.1f}s)")
            _emit("    " + str(e).replace("\n", "\n    "))
            failed.append(name)
        except Exception:  # noqa: BLE001
            dt = time.monotonic() - t0
            _emit(f"✗ FAIL ({dt:.1f}s) (运行异常)")
            # 用 format_exc()(无参,全版本兼容);format_exception(e) 单参形态仅 3.10+,
            # 在 3.9 会自身抛 TypeError 把整个 runner 带崩。
            _emit("    " + traceback.format_exc().replace("\n", "\n    "))
            failed.append(name)
        finally:
            release_case_dirs()  # 用例自建的临时目录(tty_driver.case_tmpdir),失败也删

    suite_dt = time.monotonic() - suite_t0
    skip_note = f" / {len(skipped)} skipped" if skipped else ""
    _emit(f"\n=== 结果:{passed} passed / {len(failed)} failed{skip_note}  ({suite_dt:.0f}s) ===")
    if skipped:
        _emit("跳过(漂移/环境):" + ", ".join(skipped))  # 漂移=模型未触发被测路径;环境=凭证失效/依赖缺失
    if failed:
        _emit("失败:" + ", ".join(failed))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
