#!/usr/bin/env python3
"""TTY 测试 runner —— 收集 cases/*.py 的 test_* 函数,逐个跑,汇总 pass/fail。

每个 case 函数签名:def test_xxx(bin_path) -> None,失败 raise AssertError(含屏幕 diff)。
退出码:0 全过;1 有失败;2 环境错误(无二进制 / 非 macOS-Linux)。

用法:
  python3 tests/tty/run_tty_tests.py --bin zig-out/bin/metacodes-debug [-k 过滤] [-v]
"""
import os
import sys
import importlib.util
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)  # 让 cases 能 import screen/asserts/tty_driver

from asserts import AssertError  # noqa: E402


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


def main():
    args = sys.argv[1:]
    bin_path = "zig-out/bin/metacodes-debug"
    kfilter = None
    verbose = False
    i = 0
    while i < len(args):
        if args[i] == "--bin":
            bin_path = args[i + 1]
            i += 2
        elif args[i] == "-k":
            kfilter = args[i + 1]
            i += 2
        elif args[i] == "-v":
            verbose = True
            i += 1
        else:
            i += 1

    if not os.access(bin_path, os.X_OK):
        print(f"[ERROR] 二进制不存在/不可执行: {bin_path}", file=sys.stderr)
        return 2

    cases = load_cases()
    if kfilter:
        cases = [(n, f) for n, f in cases if kfilter in n]
    if not cases:
        print("[ERROR] 没有匹配的用例", file=sys.stderr)
        return 2

    passed = 0
    failed = []
    print(f"=== TTY 测试:{len(cases)} 个用例,bin={bin_path} ===\n")
    for name, fn in cases:
        try:
            fn(bin_path)
            print(f"  ✓ {name}")
            passed += 1
        except AssertError as e:
            print(f"  ✗ {name}")
            print("    " + str(e).replace("\n", "\n    "))
            failed.append(name)
        except Exception as e:  # noqa: BLE001
            print(f"  ✗ {name}  (运行异常)")
            # 用 format_exc()(无参,全版本兼容);format_exception(e) 单参形态仅 3.10+,
            # 在 3.9 会自身抛 TypeError 把整个 runner 带崩。
            print("    " + traceback.format_exc().replace("\n", "\n    "))
            failed.append(name)

    print(f"\n=== 结果:{passed} passed / {len(failed)} failed ===")
    if failed:
        print("失败:", ", ".join(failed))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
