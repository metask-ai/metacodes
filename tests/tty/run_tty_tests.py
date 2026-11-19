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

**本机并行**:`--jobs N` 起 N 个 worker 子进程(本脚本 `--worker` 模式),从同一个待跑队列里
取用例,结果按用例汇总成一份,退出码同上。套件的耗时几乎都在等屏幕安静(#588),所以 N 个
job 大致把耗时除以 N。并行时每个用例有时限(`--case-timeout`,默认 120s,最慢的用例约 30s):
超时就杀掉它所在的 worker、判该用例失败、换一个新 worker 接着跑,一个卡死的用例(#569)拖不住
整轮。会让 metacodes 在固定端口等登录回调的用例(EXCLUSIVE_MODULES)同一时刻只跑一个。
`--shard` 先选出本片,`--jobs` 再并行跑这一片。不加 `--jobs` 时仍在本进程里逐个跑,没有时限。

用法:
  python3 tests/tty/run_tty_tests.py --bin zig-out/bin/metacodes-debug [-k 过滤] [--shard K/N]
      [--jobs N [--case-timeout 秒]] [-v]
"""
import os
import sys
import time
import json
import queue
import subprocess
import threading
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


# 让 metacodes 在固定端口(1455,占用时 1457,src/core/auth.zig)等登录回调的用例模块。两个这样的
# 用例同时跑会抢端口:后起的落到别的端口,断言端口的用例失败或跳过。--jobs 下同一时刻只跑一个。
EXCLUSIVE_MODULES = frozenset({"test_login", "test_login_logout", "test_openrouter_login"})
DEFAULT_CASE_TIMEOUT = 120.0


def load_cases(cases_dir=None):
    cases = []
    cases_dir = cases_dir or os.path.join(HERE, "cases")
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


def is_exclusive(name):
    return name.split(".", 1)[0] in EXCLUSIVE_MODULES


def next_case(pending, exclusive_running):
    """--jobs 下空闲 worker 该取的用例在 pending 里的下标,没有可取的返回 None。

    独占用例彼此串行;没有独占用例在跑时先取独占的,让这条串行链和其余用例并行推进,
    而不是攒到最后单独跑。其余按原顺序。
    """
    first_shared = None
    for i, name in enumerate(pending):
        if is_exclusive(name):
            if not exclusive_running:
                return i
        elif first_shared is None:
            first_shared = i
            if exclusive_running:
                return i
    return first_shared


def run_case(fn, bin_path):
    """跑一个用例 → (status, 耗时, detail)。status:pass / skip / fail / error。"""
    t0 = time.monotonic()
    try:
        fn(bin_path)
        return "pass", time.monotonic() - t0, ""
    except SkipTest as e:
        # 真模型漂移:被测路径未触发(模型没调目标工具)→ 跳过,非失败。
        return "skip", time.monotonic() - t0, str(e)
    except AssertError as e:
        return "fail", time.monotonic() - t0, str(e)
    except Exception:  # noqa: BLE001
        # 用 format_exc()(无参,全版本兼容);format_exception(e) 单参形态仅 3.10+,
        # 在 3.9 会自身抛 TypeError 把整个 runner 带崩。
        return "error", time.monotonic() - t0, traceback.format_exc()
    finally:
        release_case_dirs()  # 用例自建的临时目录(tty_driver.case_tmpdir),失败也删


def result_lines(status, dt, detail):
    """结果行(接在 `▶ name … ` 之后)及其后的缩进详情。"""
    if status == "pass":
        return [f"✓ ({dt:.1f}s)"]
    if status == "skip":
        return [f"⊘ skip ({dt:.1f}s): {detail}"]
    note = {"fail": "", "error": " (运行异常)", "timeout": " (超时)"}[status]
    return [f"✗ FAIL ({dt:.1f}s){note}", "    " + detail.replace("\n", "\n    ")]


def run_serial(bin_path, cases):
    passed, failed, skipped = 0, [], []
    total = len(cases)
    for idx, (name, fn) in enumerate(cases, 1):
        # 先打"开始"行(无换行,带 carriage-return 风格的进度前缀),立即 flush
        # → 即使该测试要跑 40s,日志也立刻显示"正在跑哪条",不会黑屏到结束。
        _emit(f"[{idx}/{total}] ▶ {name} … ", newline=False)
        status, dt, detail = run_case(fn, bin_path)
        for line in result_lines(status, dt, detail):
            _emit(line)
        if status == "pass":
            passed += 1
        elif status == "skip":
            skipped.append(name)
        else:
            failed.append(name)
    return passed, failed, skipped


def worker_main(bin_path, cases_dir):
    """--jobs 的 worker:从 stdin 逐行读用例名,跑完往 stdout 写一行 JSON 结果。"""
    # stdout 只留给结果协议:用例自己(及其子进程)往 fd 1 写的东西改走 stderr。
    proto = os.fdopen(os.dup(1), "w", encoding="utf-8")
    os.dup2(2, 1)
    by_name = dict(load_cases(cases_dir))
    for line in sys.stdin:
        name = line.strip()
        if not name:
            continue
        status, dt, detail = run_case(by_name[name], bin_path)
        proto.write(json.dumps({"name": name, "status": status, "dt": dt, "detail": detail}) + "\n")
        proto.flush()
    return 0


class _Worker:
    def __init__(self, slot, bin_path, cases_dir, events):
        argv = [sys.executable, os.path.abspath(__file__), "--worker", "--bin", bin_path]
        if cases_dir:
            argv += ["--cases-dir", cases_dir]
        self.proc = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     encoding="utf-8", errors="replace")
        self.case = None
        self.started = 0.0
        threading.Thread(target=self._read, args=(slot, events), daemon=True).start()

    def _read(self, slot, events):
        for line in self.proc.stdout:
            events.put((slot, self, line))
        events.put((slot, self, None))

    def start(self, name):
        self.case = name
        self.started = time.monotonic()
        self.proc.stdin.write(name + "\n")
        self.proc.stdin.flush()

    def close(self):
        try:
            self.proc.stdin.close()
        except OSError:
            pass

    def kill(self):
        # 子进程 metacodes 在自己的会话里(pty.fork 会 setsid);worker 一死 pty 主端关闭,
        # 它收到 SIGHUP 退出。
        self.proc.kill()
        self.proc.wait()


def run_parallel(bin_path, cases, jobs, case_timeout, cases_dir):
    pending = [name for name, _ in cases]
    total = len(pending)
    results = {}
    events = queue.Queue()
    workers = [None] * min(jobs, total)
    done = 0

    def record(name, status, dt, detail, slot):
        nonlocal done
        done += 1
        results[name] = status
        lines = result_lines(status, dt, detail)
        _emit(f"[{done}/{total}] [job {slot + 1}] {name} … {lines[0]}")
        for line in lines[1:]:
            _emit(line)

    try:
        while pending or any(w and w.case for w in workers):
            exclusive_running = any(w and w.case and is_exclusive(w.case) for w in workers)
            for slot, w in enumerate(workers):
                if w and w.case:
                    continue
                i = next_case(pending, exclusive_running)
                if i is None:
                    break
                if w is None:
                    w = workers[slot] = _Worker(slot, bin_path, cases_dir, events)
                w.start(pending.pop(i))
                exclusive_running = exclusive_running or is_exclusive(w.case)
            busy = [w for w in workers if w and w.case]
            if not busy:
                break
            wait = min(w.started + case_timeout for w in busy) - time.monotonic()
            try:
                slot, w, line = events.get(timeout=max(wait, 0))
            except queue.Empty:
                now = time.monotonic()
                for slot, w in enumerate(workers):
                    if w and w.case and now - w.started >= case_timeout:
                        w.kill()
                        workers[slot] = None
                        record(w.case, "timeout", now - w.started,
                               f"超过 --case-timeout {case_timeout:g}s,已结束它所在的 worker", slot)
                continue
            if workers[slot] is not w:
                continue  # 已被超时换掉的 worker 的残余输出
            if line is None:
                code = w.proc.wait()
                workers[slot] = None
                if w.case:
                    record(w.case, "error", time.monotonic() - w.started,
                           f"worker 进程意外退出(退出码 {code})", slot)
                continue
            r = json.loads(line)
            w.case = None
            record(r["name"], r["status"], r["dt"], r["detail"], slot)
    finally:
        for w in workers:
            if w:
                w.close()
        for w in workers:
            if w:
                try:
                    w.proc.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    w.kill()

    names = [name for name, _ in cases]
    passed = sum(1 for n in names if results.get(n) == "pass")
    failed = [n for n in names if results.get(n) not in ("pass", "skip")]
    skipped = [n for n in names if results.get(n) == "skip"]
    return passed, failed, skipped


def main():
    args = sys.argv[1:]
    bin_path = "zig-out/bin/metacodes-debug"
    kfilter = None
    shard_text = os.environ.get("TTY_SHARD") or None
    verbose = False
    jobs_text = None
    timeout_text = None
    cases_dir = None
    worker = False
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
        elif args[i] == "--jobs":
            jobs_text = args[i + 1]
            i += 2
        elif args[i] == "--case-timeout":
            timeout_text = args[i + 1]
            i += 2
        elif args[i] == "--cases-dir":  # runner 自测用:换一个用例目录
            cases_dir = args[i + 1]
            i += 2
        elif args[i] == "--worker":  # --jobs 内部用
            worker = True
            i += 1
        elif args[i] == "-v":
            verbose = True
            i += 1
        else:
            i += 1

    if worker:
        return worker_main(bin_path, cases_dir)

    shard = None
    if shard_text is not None:
        shard = parse_shard(shard_text)
        if shard is None:
            print(f"[ERROR] 分片须为 K/N(1 ≤ K ≤ N): {shard_text}", file=sys.stderr)
            return 2

    jobs = None
    if jobs_text is not None:
        jobs = int(jobs_text) if jobs_text.isdigit() else 0
        if jobs < 1:
            print(f"[ERROR] --jobs 须为正整数: {jobs_text}", file=sys.stderr)
            return 2
    case_timeout = DEFAULT_CASE_TIMEOUT
    if timeout_text is not None:
        try:
            case_timeout = float(timeout_text)
        except ValueError:
            case_timeout = 0
        if not case_timeout > 0:
            print(f"[ERROR] --case-timeout 须为正数(秒): {timeout_text}", file=sys.stderr)
            return 2

    if not os.access(bin_path, os.X_OK):
        print(f"[ERROR] 二进制不存在/不可执行: {bin_path}", file=sys.stderr)
        return 2

    cases = load_cases(cases_dir)
    if kfilter:
        cases = [(n, f) for n, f in cases if kfilter in n]
    if shard is not None:
        cases = select_shard(cases, *shard)
    if not cases:
        print("[ERROR] 没有匹配的用例", file=sys.stderr)
        return 2

    total = len(cases)
    shard_note = f",分片 {shard[0]}/{shard[1]}" if shard is not None else ""
    jobs_note = f",{jobs} 个 job 并行,单个用例时限 {case_timeout:g}s" if jobs is not None else ""
    _emit(f"=== TTY 测试:{total} 个用例{shard_note}{jobs_note},bin={bin_path} ===\n")
    suite_t0 = time.monotonic()
    if jobs is None:
        passed, failed, skipped = run_serial(bin_path, cases)
    else:
        passed, failed, skipped = run_parallel(bin_path, cases, jobs, case_timeout, cases_dir)

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
