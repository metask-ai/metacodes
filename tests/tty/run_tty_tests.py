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

**并行**:`--jobs N` 在本机同时跑 N 个分片(N 个子进程,各跑 `select_shard` 的一片,输出各写
一个日志),父进程按完成顺序打印每条结果、合并成一份汇总(`merge_results`)。套件绝大部分时间在
等屏幕静默,不是在算,所以墙钟时间随片数下降(#588)。`--shard` 只给 CI 的多台 runner 用,两者不能同时给。
- 占用本机固定资源(固定端口等)的用例用 `tty_driver.runs_alone(原因)` 标记:`--jobs` 把它们
  从分片里拿出来,并行阶段结束后单独逐个跑。串行和 `--shard` 照旧按顺序跑,标记不起作用。
- 每条用例有时限(`--case-timeout S`,`--jobs` 下默认 CASE_TIMEOUT_JOBS 秒;串行默认不限,与
  以前一样):POSIX 上到点 SIGALRM 打断用例、判失败、接着跑下一条。父进程另有看门狗:某片一条
  用例超过时限 + WATCHDOG_GRACE 仍无结果(SIGALRM 也没能打断),杀掉该片,它跑着的和没跑的
  用例都判失败。一个挂死的用例(#569)因此拖不住整个套件。

用法:
  python3 tests/tty/run_tty_tests.py --bin zig-out/bin/metacodes-debug [-k 过滤] [--shard K/N | --jobs N]
      [--case-timeout S] [-v]
"""
import os
import sys
import json
import time
import shutil
import signal
import tempfile
import subprocess
import importlib.util
import traceback

# Windows 控制台默认代码页(GBK 等)编不了 ▶/✓/⊘ → UnicodeEncodeError 直接带崩 runner。
# 统一强制 UTF-8(POSIX 上本来就是,无变化);errors=replace 兜底任何环境。
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

HERE = os.path.dirname(os.path.abspath(__file__))
DOMAINS_PATH = os.path.join(HERE, "domains.json")
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


def load_domains(path=DOMAINS_PATH):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, dict) or data.get("schema") != "metacodes.tty-domains/v1":
        raise ValueError(f"invalid tty domains schema in {path}")
    raw = data.get("domains")
    if not isinstance(raw, dict) or not raw:
        raise ValueError(f"invalid tty domains mapping in {path}")
    domains = {}
    for name, modules in raw.items():
        if not isinstance(name, str) or not name or not isinstance(modules, list) or not modules:
            raise ValueError(f"invalid tty domain entry: {name!r}")
        if not all(isinstance(mod, str) and mod.startswith("test_") for mod in modules):
            raise ValueError(f"invalid module name in tty domain {name!r}")
        if len(modules) != len(set(modules)):
            raise ValueError(f"duplicate module in tty domain {name!r}")
        domains[name] = tuple(modules)
    return domains


def parse_domains(text, domains):
    wanted = []
    seen = set()
    unknown = []
    for part in text.split(","):
        name = part.strip()
        if not name:
            continue
        if name not in domains:
            if name not in unknown:
                unknown.append(name)
        elif name not in seen:
            seen.add(name)
            wanted.append(name)
    return tuple(wanted), unknown


def filter_domains(cases, selected, domains):
    if not selected:
        return cases
    allowed = {mod for name in selected for mod in domains[name]}
    return [case for case in cases if case[0].split(".", 1)[0] in allowed]


# `--jobs` 下每条用例的默认时限(秒)。本机全量最慢的用例约 31s(#588),留足余量。
CASE_TIMEOUT_JOBS = 300.0
# 看门狗在用例时限之外再等多久才杀掉整片(SIGALRM 应先到;到不了才轮到它)。
WATCHDOG_GRACE = 60.0


class CaseTimeout(BaseException):
    """用例超时。继承 BaseException:用例里的 `except Exception` 吞不掉它。"""


def runs_alone(fn):
    """用例是否标了 `tty_driver.runs_alone`(占本机固定资源,不能与别的用例同时跑)。"""
    return bool(getattr(fn, "tty_runs_alone", None))


def _arm_timeout(seconds):
    """POSIX:seconds 秒后在主线程抛 CaseTimeout。返回撤销函数;无时限或无 SIGALRM 时什么都不做。"""
    if not seconds or not hasattr(signal, "setitimer"):
        return lambda: None

    def on_alarm(signum, frame):  # noqa: ARG001
        raise CaseTimeout(f"超过用例时限 {seconds:.0f}s")

    previous = signal.signal(signal.SIGALRM, on_alarm)
    signal.setitimer(signal.ITIMER_REAL, seconds)

    def disarm():
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)
    return disarm


def run_cases(cases, bin_path, *, header, case_timeout=None, record=None):
    """逐条跑 cases,打印进度和汇总;返回退出码(0 全过 / 1 有失败)。

    record(event):每条用例开始、结束各调一次(`--jobs` 的子进程用它把结果写给父进程)。"""
    record = record or (lambda event: None)
    passed = 0
    failed = []
    skipped = []
    total = len(cases)
    _emit(header)
    suite_t0 = time.monotonic()
    for idx, (name, fn) in enumerate(cases, 1):
        # 先打"开始"行(无换行,带 carriage-return 风格的进度前缀),立即 flush
        # → 即使该测试要跑 40s,日志也立刻显示"正在跑哪条",不会黑屏到结束。
        _emit(f"[{idx}/{total}] ▶ {name} … ", newline=False)
        record({"event": "start", "name": name})
        t0 = time.monotonic()
        status, detail = "pass", ""
        disarm = _arm_timeout(case_timeout)
        try:
            try:
                fn(bin_path)
            finally:
                disarm()
            dt = time.monotonic() - t0
            _emit(f"✓ ({dt:.1f}s)")
            passed += 1
        except SkipTest as e:
            dt = time.monotonic() - t0
            # 真模型漂移:被测路径未触发(模型没调目标工具)→ 跳过,非失败。
            _emit(f"⊘ skip ({dt:.1f}s): {e}")
            skipped.append(name)
            status, detail = "skip", str(e)
        except AssertError as e:
            dt = time.monotonic() - t0
            _emit(f"✗ FAIL ({dt:.1f}s)")
            detail = str(e)
            _emit("    " + detail.replace("\n", "\n    "))
            failed.append(name)
            status = "fail"
        except CaseTimeout as e:
            dt = time.monotonic() - t0
            _emit(f"✗ FAIL ({dt:.1f}s) ({e})")
            detail = f"{e}\n{traceback.format_exc()}"
            _emit("    " + detail.replace("\n", "\n    "))
            failed.append(name)
            status = "fail"
        except Exception:  # noqa: BLE001
            dt = time.monotonic() - t0
            _emit(f"✗ FAIL ({dt:.1f}s) (运行异常)")
            # 用 format_exc()(无参,全版本兼容);format_exception(e) 单参形态仅 3.10+,
            # 在 3.9 会自身抛 TypeError 把整个 runner 带崩。
            detail = traceback.format_exc()
            _emit("    " + detail.replace("\n", "\n    "))
            failed.append(name)
            status = "fail"
        finally:
            release_case_dirs()  # 用例自建的临时目录(tty_driver.case_tmpdir),失败也删
        record({"event": "end", "name": name, "status": status, "dt": round(dt, 3), "detail": detail})

    suite_dt = time.monotonic() - suite_t0
    skip_note = f" / {len(skipped)} skipped" if skipped else ""
    _emit(f"\n=== 结果:{passed} passed / {len(failed)} failed{skip_note}  ({suite_dt:.0f}s) ===")
    if skipped:
        _emit("跳过(漂移/环境):" + ", ".join(skipped))  # 漂移=模型未触发被测路径;环境=凭证失效/依赖缺失
    if failed:
        _emit("失败:" + ", ".join(failed))
        return 1
    return 0


# ---------------------------------------------------------------- --jobs N


def plan_jobs(cases, jobs):
    """(并行分片列表, 单独跑的用例):不带 runs_alone 的用例按 select_shard 分成至多 jobs 片
    (不要空片),带标记的留到并行阶段之后逐个单独跑。"""
    shared = [case for case in cases if not runs_alone(case[1])]
    alone = [case for case in cases if runs_alone(case[1])]
    count = min(jobs, len(shared))
    shards = [select_shard(shared, k, count) for k in range(1, count + 1)]
    return shards, alone


class Summary:
    """合并后的结果。failed 是 [(name, 原因)],按计划顺序。"""

    def __init__(self):
        self.passed = []
        self.skipped = []
        self.failed = []
        self.env_error = False

    def exit_code(self):
        if self.env_error:
            return 2
        return 1 if self.failed else 0


def merge_results(planned, events, exits):
    """合并各片结果。planned[i] 是第 i 片计划跑的用例名(按顺序),events[i] 是它写回的事件,
    exits[i] 是它的退出码(被看门狗杀掉为 None)。

    每条计划内的用例恰好落进 passed / skipped / failed 之一:有 end 事件的按事件;开始了没结束的
    (片被杀或崩了)和没开始的都判失败并写明原因——片提前退出,漏跑的用例不能悄悄不算。
    退出码 2(环境错误)且一条都没开始的片记为 env_error。"""
    summary = Summary()
    for names, evs, code in zip(planned, events, exits):
        ended = {}
        started = set()
        for ev in evs:
            if ev.get("event") == "start":
                started.add(ev.get("name"))
            elif ev.get("event") == "end":
                ended[ev.get("name")] = ev
        if code == 2 and not started:
            summary.env_error = True
        how = "被看门狗杀掉" if code is None else f"退出码 {code}"
        for name in names:
            ev = ended.get(name)
            if ev is None:
                verb = "跑到一半" if name in started else "没有跑"
                summary.failed.append((name, f"{verb}:所在分片{how}"))
            elif ev.get("status") == "pass":
                summary.passed.append(name)
            elif ev.get("status") == "skip":
                summary.skipped.append(name)
            else:
                summary.failed.append((name, "失败"))
    return summary


def read_events(path, offset):
    """读 path 从 offset 起的完整行,返回 (事件列表, 新 offset)。还没写完的半行留到下次。"""
    try:
        with open(path, "rb") as f:
            f.seek(offset)
            data = f.read()
    except FileNotFoundError:
        return [], offset
    end = data.rfind(b"\n") + 1
    events = [json.loads(line) for line in data[:end].splitlines() if line.strip()]
    return events, offset + end


class _Job:
    """一个子进程:按给定顺序跑 names,事件写进 results,完整输出写进 log。"""

    def __init__(self, label, names, workdir, argv_base):
        self.label = label
        self.names = names
        self.results = os.path.join(workdir, f"{label}.jsonl")
        self.log = os.path.join(workdir, f"{label}.log")
        list_path = os.path.join(workdir, f"{label}.cases")
        with open(list_path, "w", encoding="utf-8") as f:
            f.write("\n".join(names) + "\n")
        argv = argv_base + ["--case-list", list_path, "--results", self.results]
        env = dict(os.environ)
        env.pop("TTY_SHARD", None)
        env.pop("TTY_DOMAINS", None)
        self._log_file = open(self.log, "wb")
        # 自成进程组:看门狗杀片时连同它起的 pty 子进程一起杀
        kwargs = {"start_new_session": True} if os.name == "posix" else {}
        self.proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=self._log_file,
                                     stderr=subprocess.STDOUT, env=env, **kwargs)
        self.offset = 0
        self.events = []
        self.current = None  # (正在跑的用例, 开始时刻)
        self.running = True
        self.code = None  # 退出码;被杀为 None

    def kill(self):
        try:
            if os.name == "posix":
                os.killpg(self.proc.pid, signal.SIGKILL)
            else:
                self.proc.kill()
        except OSError:
            pass
        self.proc.wait()
        self.running = False
        self.code = None

    def close(self):
        self._log_file.close()


def _run_phase(jobs, total, done, case_timeout):
    """跑一组并发的子进程直到全部结束,边跑边打印每条结果。返回更新后的完成数。"""
    running = list(jobs)
    while running:
        for job in list(running):
            exited = job.proc.poll() is not None  # 先看退出、再读事件:退出前写的事件不会漏读
            new, job.offset = read_events(job.results, job.offset)
            for ev in new:
                job.events.append(ev)
                if ev.get("event") == "start":
                    job.current = (ev.get("name"), time.monotonic())
                    continue
                job.current = None
                done += 1
                status = ev.get("status")
                mark = {"pass": "✓", "skip": "⊘ skip"}.get(status, "✗ FAIL")
                line = f"[{done}/{total}] {mark} {ev.get('name')} ({ev.get('dt', 0):.1f}s, {job.label})"
                if status == "skip":
                    line += f": {ev.get('detail', '')}"
                _emit(line)
                if status == "fail" and ev.get("detail"):
                    _emit("    " + ev["detail"].rstrip("\n").replace("\n", "\n    "))
            if exited:
                job.running = False
                job.code = job.proc.returncode
                running.remove(job)
            elif job.current and time.monotonic() - job.current[1] > case_timeout + WATCHDOG_GRACE:
                _emit(f"[看门狗] {job.label} 的 {job.current[0]} 超过 {case_timeout + WATCHDOG_GRACE:.0f}s "
                      "仍无结果,杀掉这一片")
                job.kill()
                running.remove(job)
        if running:
            time.sleep(0.2)
    return done


def run_jobs(cases, bin_path, jobs, *, case_timeout, verbose=False):
    """--jobs N:并行跑各片,再逐个单独跑 runs_alone 用例,合并汇总。返回退出码。"""
    shards, alone = plan_jobs(cases, jobs)
    total = len(cases)
    workdir = tempfile.mkdtemp(prefix="tty-jobs-")
    argv_base = [sys.executable, os.path.abspath(__file__), "--bin", bin_path,
                 "--case-timeout", str(case_timeout)]
    if verbose:
        argv_base.append("-v")
    alone_note = f",另有 {len(alone)} 个单独跑" if alone else ""
    _emit(f"=== TTY 测试:{total} 个用例,{len(shards)} 个分片并行{alone_note},bin={bin_path} ===")
    _emit(f"(各片完整输出:{workdir})\n")
    t0 = time.monotonic()
    done = 0
    all_jobs = []
    try:
        phase = [_Job(f"shard-{k}-of-{len(shards)}", [name for name, _ in shard], workdir, argv_base)
                 for k, shard in enumerate(shards, 1)]
        all_jobs += phase
        done = _run_phase(phase, total, done, case_timeout)
        for k, (name, _) in enumerate(alone, 1):  # 并行阶段已结束:此刻只有这一条用例在跑
            job = _Job(f"alone-{k}", [name], workdir, argv_base)
            all_jobs.append(job)
            done = _run_phase([job], total, done, case_timeout)
    finally:
        for job in all_jobs:
            if job.running:
                job.kill()
            job.close()

    summary = merge_results([j.names for j in all_jobs], [j.events for j in all_jobs],
                            [j.code for j in all_jobs])
    wall = time.monotonic() - t0
    case_sum = sum(ev.get("dt", 0) for j in all_jobs for ev in j.events if ev.get("event") == "end")
    skip_note = f" / {len(summary.skipped)} skipped" if summary.skipped else ""
    _emit(f"\n=== 结果:{len(summary.passed)} passed / {len(summary.failed)} failed{skip_note}  "
          f"({wall:.0f}s;各用例耗时合计 {case_sum:.0f}s) ===")
    if summary.skipped:
        _emit("跳过(漂移/环境):" + ", ".join(summary.skipped))
    if summary.failed:
        _emit("失败:" + ", ".join(f"{name}({why})" for name, why in summary.failed))
    if summary.env_error:
        _emit("[ERROR] 有分片报环境错误,见它的日志")
    if summary.failed or summary.env_error:
        _emit(f"各片日志保留在 {workdir}")
    else:
        shutil.rmtree(workdir, ignore_errors=True)
    return summary.exit_code()


def _positive(text, kind):
    try:
        value = kind(text)
    except ValueError:
        return None
    return value if value > 0 else None


def main():
    args = sys.argv[1:]
    bin_path = "zig-out/bin/metacodes-debug"
    kfilter = None
    domains_text = os.environ.get("TTY_DOMAINS") or None
    domains_arg = None
    shard_text = os.environ.get("TTY_SHARD") or None
    shard_arg = None
    jobs_text = None
    timeout_text = None
    case_list = None  # --jobs 的子进程:只跑这些用例,按给出的顺序
    results_path = None  # --jobs 的子进程:每条用例的开始/结束写成一行 JSON
    verbose = False
    i = 0
    while i < len(args):
        if args[i] == "--bin":
            bin_path = args[i + 1]
            i += 2
        elif args[i] == "-k":
            kfilter = args[i + 1]
            i += 2
        elif args[i] == "--domains":
            domains_arg = args[i + 1]
            i += 2
        elif args[i] == "--shard":
            shard_arg = args[i + 1]
            i += 2
        elif args[i] == "--jobs":
            jobs_text = args[i + 1]
            i += 2
        elif args[i] == "--case-timeout":
            timeout_text = args[i + 1]
            i += 2
        elif args[i] == "--case-list":
            case_list = args[i + 1]
            i += 2
        elif args[i] == "--results":
            results_path = args[i + 1]
            i += 2
        elif args[i] == "-v":
            verbose = True
            i += 1
        else:
            i += 1
    if shard_arg is not None:
        shard_text = shard_arg
    if domains_arg is not None:
        domains_text = domains_arg

    jobs = None
    if jobs_text is not None:
        jobs = _positive(jobs_text, int)
        if jobs is None:
            print(f"[ERROR] --jobs 须为正整数: {jobs_text}", file=sys.stderr)
            return 2
        if shard_arg is not None:
            print("[ERROR] --jobs 与 --shard 不能同时给", file=sys.stderr)
            return 2
        shard_text = None  # 环境里的 TTY_SHARD 让给 --jobs,子进程也不继承它

    case_timeout = None
    if timeout_text is not None:
        case_timeout = _positive(timeout_text, float)
        if case_timeout is None:
            print(f"[ERROR] --case-timeout 须为正数(秒): {timeout_text}", file=sys.stderr)
            return 2
    elif jobs is not None:
        case_timeout = CASE_TIMEOUT_JOBS

    shard = None
    if shard_text is not None:
        shard = parse_shard(shard_text)
        if shard is None:
            print(f"[ERROR] 分片须为 K/N(1 ≤ K ≤ N): {shard_text}", file=sys.stderr)
            return 2

    selected_domains = ()
    domains_map = None
    if domains_text and case_list is None:
        try:
            domains_map = load_domains()
        except Exception as exc:
            print(f"[ERROR] 读取域清单失败: {exc}", file=sys.stderr)
            return 2
        selected_domains, unknown = parse_domains(domains_text, domains_map)
        if unknown:
            known = ", ".join(sorted(domains_map))
            print(f"[ERROR] 未知的 TTY 域: {', '.join(unknown)} (可选: {known})", file=sys.stderr)
            return 2

    if not os.access(bin_path, os.X_OK):
        print(f"[ERROR] 二进制不存在/不可执行: {bin_path}", file=sys.stderr)
        return 2

    cases = load_cases()
    if case_list is not None:
        with open(case_list, encoding="utf-8") as f:
            wanted = [line.strip() for line in f if line.strip()]
        by_name = dict(cases)
        unknown = [name for name in wanted if name not in by_name]
        if unknown:
            print(f"[ERROR] 用例表里没有: {', '.join(unknown)}", file=sys.stderr)
            return 2
        cases = [(name, by_name[name]) for name in wanted]
    if selected_domains:
        cases = filter_domains(cases, selected_domains, domains_map)
    if kfilter:
        cases = [(n, f) for n, f in cases if kfilter in n]
    if not cases:
        print("[ERROR] 没有匹配的用例", file=sys.stderr)
        return 2
    pre_shard_count = len(cases)
    if shard is not None:
        cases = select_shard(cases, *shard)
    if not cases:
        domain_note = f",域 {','.join(selected_domains)}" if selected_domains else ""
        _emit(f"=== TTY 测试:0 个用例,分片 {shard[0]}/{shard[1]}{domain_note} (共 {pre_shard_count} 条已由其余分片覆盖) ===")
        return 0

    if jobs is not None:
        return run_jobs(cases, bin_path, jobs, case_timeout=case_timeout, verbose=verbose)

    record = None
    results_file = None
    if results_path is not None:
        results_file = open(results_path, "a", encoding="utf-8")

        def record(event):
            results_file.write(json.dumps(event, ensure_ascii=False) + "\n")
            results_file.flush()

    shard_note = f",分片 {shard[0]}/{shard[1]}" if shard is not None else ""
    domain_note = f",域 {','.join(selected_domains)}" if selected_domains else ""
    header = f"=== TTY 测试:{len(cases)} 个用例{shard_note}{domain_note},bin={bin_path} ===\n"
    try:
        return run_cases(cases, bin_path, header=header, case_timeout=case_timeout, record=record)
    finally:
        if results_file is not None:
            results_file.close()


if __name__ == "__main__":
    sys.exit(main())
