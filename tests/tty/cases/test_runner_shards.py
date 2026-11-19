"""run_tty_tests 的分片逻辑单测(离线,不起二进制,bin_path 未用)。

CI 把 TTY 套件按 `--shard K/N` 拆到多台 runner(doc/CI_DESIGN.md §4)。分片漏一个用例
就是一个永远不跑却也不报错的用例,所以这里钉死:N 片恰好划分全表、互不重叠。
`--jobs N` 在本机并行跑各片再合并结果(#588):同样钉死每条用例恰好跑一次、恰好计一次。
"""
import json
import os
import signal
import subprocess
import sys
import tempfile

TTY_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, TTY_DIR)
from run_tty_tests import (  # noqa: E402
    load_cases, merge_results, parse_shard, plan_jobs, read_events, runs_alone, select_shard)
from tty_driver import runs_alone as mark_runs_alone  # noqa: E402
from e2e_helpers import SkipTest  # noqa: E402


def test_shards_partition_the_real_case_list(bin_path):
    names = [name for name, _ in load_cases()]
    for count in (1, 2, 3, 4, 6, 7, 8):
        seen = []
        for index in range(1, count + 1):
            seen.extend(name for name, _ in select_shard([(n, None) for n in names], index, count))
        assert sorted(seen) == sorted(names), f"{count} 片没有恰好划分用例表"
        assert len(seen) == len(set(seen)), f"{count} 片有重叠"


def test_shard_spec_is_validated(bin_path):
    assert parse_shard("1/1") == (1, 1)
    assert parse_shard("3/4") == (3, 4)
    for bad in ("0/3", "4/3", "1/0", "1", "a/b", "1/2/3", "", "-1/2"):
        assert parse_shard(bad) is None, bad


# ---- --jobs N:本机并行跑各片(#588)。分配或合并漏一条,就是一个没跑却不报错的用例。


def _plain(bin_path):
    pass


@mark_runs_alone("a fixed port")
def _alone(bin_path):
    pass


def test_jobs_plan_runs_every_case_once_and_holds_back_the_ones_that_run_alone(bin_path):
    cases = load_cases()
    alone_names = sorted(name for name, fn in cases if runs_alone(fn))
    # 断言固定 OAuth 回调端口的两条 /login 用例不能与别的登录用例同时跑
    assert "test_login.test_login_chatgpt_codex_waits_on_its_registered_port_with_the_codex_parameters" in alone_names
    assert "test_login.test_login_chatgpt_codex_takes_1457_when_1455_is_held_and_sends_it_nothing" in alone_names
    names = [name for name, _ in cases]
    for jobs in (1, 2, 3, 4, 8):
        shards, alone = plan_jobs(cases, jobs)
        assert len(shards) == jobs, jobs
        seen = [name for shard in shards for name, _ in shard]
        assert len(seen) == len(set(seen)), f"--jobs {jobs} 有重叠"
        assert not set(seen) & set(alone_names), f"--jobs {jobs} 把单独跑的用例放进了分片"
        assert sorted(seen + [name for name, _ in alone]) == sorted(names), f"--jobs {jobs} 漏了用例"
    # 片数不超过可分的用例数,不起空片
    shards, alone = plan_jobs([("a", _plain), ("b", _alone), ("c", _plain)], 5)
    assert [[n for n, _ in s] for s in shards] == [["a"], ["c"]]
    assert [n for n, _ in alone] == ["b"]
    shards, alone = plan_jobs([("b", _alone)], 3)
    assert shards == [] and [n for n, _ in alone] == ["b"]


def _ev(kind, name, status=None):
    ev = {"event": kind, "name": name}
    if status:
        ev.update(status=status, dt=1.0, detail="")
    return ev


def test_jobs_merge_counts_every_planned_case_exactly_once(bin_path):
    planned = [["a", "b", "c"], ["d", "e"], ["f"], ["g"]]
    events = [
        [_ev("start", "a"), _ev("end", "a", "pass"), _ev("start", "b"), _ev("end", "b", "skip"),
         _ev("start", "c"), _ev("end", "c", "fail")],
        # 第二片跑到 e 时被看门狗杀掉
        [_ev("start", "d"), _ev("end", "d", "pass"), _ev("start", "e")],
        # 第三片崩了,一条都没开始
        [],
        [_ev("start", "g"), _ev("end", "g", "pass")],
    ]
    summary = merge_results(planned, events, [1, None, 1, 0])
    assert summary.passed == ["a", "d", "g"]
    assert summary.skipped == ["b"]
    assert [name for name, _ in summary.failed] == ["c", "e", "f"]
    reasons = dict(summary.failed)
    assert "看门狗" in reasons["e"] and "跑到一半" in reasons["e"]
    assert "没有跑" in reasons["f"] and "退出码 1" in reasons["f"]
    assert not summary.env_error and summary.exit_code() == 1

    ok = merge_results([["a"], ["b"]], [[_ev("start", "a"), _ev("end", "a", "pass")],
                                       [_ev("start", "b"), _ev("end", "b", "skip")]], [0, 0])
    assert ok.exit_code() == 0 and ok.failed == []

    # 退出码 2 且什么都没跑:环境错误(没有二进制等),整体退出码也是 2
    env = merge_results([["a"], ["b"]], [[_ev("start", "a"), _ev("end", "a", "pass")], []], [0, 2])
    assert env.env_error and env.exit_code() == 2 and [n for n, _ in env.failed] == ["b"]


def test_jobs_results_file_is_read_in_whole_lines(bin_path):
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "r.jsonl")
        assert read_events(path, 0) == ([], 0)  # 子进程还没写
        with open(path, "w", encoding="utf-8") as f:
            f.write(json.dumps(_ev("start", "a")) + "\n" + '{"event": "end", "na')
        events, offset = read_events(path, 0)
        assert events == [_ev("start", "a")]
        with open(path, "a", encoding="utf-8") as f:
            f.write('me": "a", "status": "pass"}\n')
        events, offset = read_events(path, offset)
        assert events == [{"event": "end", "name": "a", "status": "pass"}]
        assert read_events(path, offset) == ([], offset)


def test_case_timeout_interrupts_a_hung_case(bin_path):
    if not hasattr(signal, "setitimer"):
        raise SkipTest("no SIGALRM on this platform; the --jobs watchdog covers a hang there")
    # 在子进程里试:runner 自己的用例时限也用 SIGALRM,在这里嵌套会把它关掉。
    # 用例里的 `except Exception` 吞不掉超时。
    code = (
        "import sys, time; sys.path.insert(0, %r)\n"
        "import run_tty_tests as r\n"
        "disarm = r._arm_timeout(0.2)\n"
        "try:\n"
        "    try:\n"
        "        time.sleep(5)\n"
        "    except Exception:\n"
        "        print('swallowed')\n"
        "except r.CaseTimeout:\n"
        "    print('timed out')\n"
        "finally:\n"
        "    disarm()\n" % TTY_DIR)
    out = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, timeout=30)
    assert out.stdout.strip() == "timed out", (out.stdout, out.stderr)
