"""run_tty_tests 的 --jobs 单测(离线,不起二进制;bin_path 只交给 runner 过它的可执行检查)。

--jobs 把用例分给多个 worker 子进程(#588)。这里钉死:结果与逐个跑一致;失败、超时、worker
崩掉都让退出码非 0 并点名是哪个用例;独占用例(固定登录回调端口)彼此不并行。
"""
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from run_tty_tests import is_exclusive, next_case  # noqa: E402
from tty_driver import case_tmpdir  # noqa: E402

RUNNER = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "run_tty_tests.py")
# CI 用 TTY_SHARD 给本套件分片;被测的 runner 会继承它,只跑假用例表里的一片。
_ENV = {k: v for k, v in os.environ.items() if k != "TTY_SHARD"}

_HEADER = """\
import os
import time
from asserts import AssertError
from e2e_helpers import SkipTest
"""


def _cases_dir(body):
    d = case_tmpdir("cc-tty-runner-jobs-")
    with open(os.path.join(d, "test_fake.py"), "w") as f:
        f.write(_HEADER + body)
    return d


def _run(bin_path, cases_dir, *extra):
    p = subprocess.run([sys.executable, RUNNER, "--bin", bin_path, "--cases-dir", cases_dir, *extra],
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, encoding="utf-8",
                       errors="replace", timeout=120, env=_ENV)
    summary = re.search(r"=== 结果:(\d+) passed / (\d+) failed(?: / (\d+) skipped)?", p.stdout)
    assert summary, p.stdout
    counts = tuple(int(g or 0) for g in summary.groups())
    failed = re.search(r"^失败:(.*)$", p.stdout, re.M)
    return p.returncode, counts, sorted(failed.group(1).split(", ")) if failed else [], p.stdout


def test_jobs_report_the_same_results_as_a_serial_run(bin_path):
    body = "".join(
        f"def test_pass_{i}(bin_path):\n    time.sleep(0.05)\n\n"
        f"def test_fail_{i}(bin_path):\n    raise AssertError('screen differs {i}')\n\n"
        f"def test_skip_{i}(bin_path):\n    raise SkipTest('no model')\n\n"
        f"def test_error_{i}(bin_path):\n    raise RuntimeError('boom {i}')\n\n"
        for i in range(3))
    d = _cases_dir(body)
    serial = _run(bin_path, d)
    for jobs in ("1", "3", "20"):
        parallel = _run(bin_path, d, "--jobs", jobs)
        assert parallel[:3] == serial[:3], (jobs, serial[:3], parallel[:3], parallel[3])
    assert serial[:2] == (1, (3, 6, 3)), serial
    assert "screen differs 2" in parallel[3] and "boom 1" in parallel[3], parallel[3]


def test_a_hang_or_a_dead_worker_fails_its_case_and_the_run_goes_on(bin_path):
    d = _cases_dir(
        "def test_a_hangs(bin_path):\n    time.sleep(60)\n\n"
        "def test_b_kills_its_worker(bin_path):\n    os._exit(3)\n\n"
        + "".join(f"def test_c_passes_{i}(bin_path):\n    pass\n\n" for i in range(4)))
    code, counts, failed, out = _run(bin_path, d, "--jobs", "2", "--case-timeout", "3")
    assert code == 1, out
    assert counts == (4, 2, 0), out
    assert failed == ["test_fake.test_a_hangs", "test_fake.test_b_kills_its_worker"], out
    assert re.search(r"test_fake\.test_a_hangs … ✗ FAIL \(\d+\.\d+s\) \(超时\)", out), out
    assert "worker 进程意外退出(退出码 3)" in out, out


def test_all_passing_jobs_exit_zero(bin_path):
    d = _cases_dir("".join(f"def test_ok_{i}(bin_path):\n    pass\n\n" for i in range(5)))
    code, counts, failed, out = _run(bin_path, d, "--jobs", "3")
    assert (code, counts, failed) == (0, (5, 0, 0), []), out


def test_bad_jobs_values_are_environment_errors(bin_path):
    d = _cases_dir("def test_ok(bin_path):\n    pass\n")
    for extra in (["--jobs", "0"], ["--jobs", "x"], ["--jobs", "2", "--case-timeout", "0"]):
        p = subprocess.run([sys.executable, RUNNER, "--bin", bin_path, "--cases-dir", d, *extra],
                           capture_output=True, encoding="utf-8", errors="replace", timeout=60, env=_ENV)
        assert p.returncode == 2, (extra, p.stdout, p.stderr)


def test_exclusive_cases_never_run_side_by_side(bin_path):
    assert is_exclusive("test_login.test_x") and is_exclusive("test_login_logout.test_y")
    assert not is_exclusive("test_layout.test_z")
    pending = ["test_layout.a", "test_login.b", "test_login_logout.c", "test_overlay.d"]
    # 没有独占用例在跑:先取独占的,让那条串行链早点开始。
    assert next_case(pending, exclusive_running=False) == 1
    # 有独占用例在跑:只取非独占的。
    assert next_case(pending, exclusive_running=True) == 0
    assert next_case(["test_login.b", "test_openrouter_login.c"], exclusive_running=True) is None
    assert next_case([], exclusive_running=False) is None
