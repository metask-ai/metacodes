"""Deterministic unit-test grader for HumanEval and MBPP tasks.

Runs inside the separate verifier container (tests/Dockerfile), which holds
only this file, the task's spec.json and the agent's submitted
/app/solution.py (a declared Harbor artifact). Python 3.9+, stdlib only.

The submission and the dataset's tests run in a child interpreter as an
unprivileged user (uid/gid 65534 when the grader runs as root), with a wall
clock limit, a memory limit and an empty environment, in a scratch directory
it cannot write. The child prints a per-run nonce, which it reads from stdin
before importing the submission, only after every test passed; the grader
awards 1 only for exit status 0 *and* that exact final line. A submission
that exits early, prints a pass line of its own, or crashes gets 0.

Like the reference HumanEval/MBPP harnesses, the tests share an interpreter
with the submission: a submission written to subvert the interpreter itself
(frame introspection to steal the nonce) is outside what this grader proves.

Usage:
  code_grader.py --spec spec.json --solution solution.py \
                 --reward reward.txt [--details grade.json]

spec.json: {"kind": "humaneval", "entry_point": str, "test": str}
        or {"kind": "mbpp", "setup": str, "imports": [str], "tests": [str]}
        plus optional "timeout_sec" (default 60).
"""

from __future__ import annotations

import argparse
import json
import os
import secrets
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Dict, List, Optional, Tuple

UNPRIVILEGED = 65534
MEMORY_LIMIT_BYTES = 2 << 30
DEFAULT_TIMEOUT_SEC = 60.0

HARNESS = r'''
import json, sys
nonce = sys.stdin.readline().strip()
spec = json.loads(open("spec.json", encoding="utf-8").read())
source = open("solution.py", encoding="utf-8").read()
namespace = {"__name__": "__solution__", "__builtins__": __builtins__}
exec(compile(source, "solution.py", "exec"), namespace)
if spec["kind"] == "humaneval":
    exec(compile(spec["test"], "test.py", "exec"), namespace)
    candidate = namespace.get(spec["entry_point"])
    if not callable(candidate):
        raise SystemExit("entry point %r is not defined" % spec["entry_point"])
    namespace["check"](candidate)
elif spec["kind"] == "mbpp":
    for line in spec.get("imports", []):
        exec(compile(line, "imports.py", "exec"), namespace)
    if spec.get("setup"):
        exec(compile(spec["setup"], "setup.py", "exec"), namespace)
    for index, test in enumerate(spec["tests"]):
        exec(compile(test, "test_%d.py" % index, "exec"), namespace)
else:
    raise SystemExit("unknown spec kind")
sys.stdout.flush()
sys.stdout.write("\nMETACODES-PASS " + nonce + "\n")
sys.stdout.flush()
'''


def _limits() -> None:  # pragma: no cover - runs in the child
    import resource

    for limit, value in ((resource.RLIMIT_AS, MEMORY_LIMIT_BYTES), (resource.RLIMIT_CORE, 0)):
        try:
            resource.setrlimit(limit, (value, value))
        except (ValueError, OSError):  # macOS rejects RLIMIT_AS; Linux enforces it
            pass
    os.setsid()


def run_submission(spec: Dict[str, object], solution: Optional[Path]) -> Tuple[bool, Dict[str, object]]:
    """(passed, details) for one submission against one spec."""
    if solution is None or not solution.is_file():
        return False, {"error": "no /app/solution.py was submitted"}
    timeout = float(spec.get("timeout_sec", DEFAULT_TIMEOUT_SEC))  # type: ignore[arg-type]
    nonce = secrets.token_hex(16)
    work = Path(tempfile.mkdtemp(prefix="grade-"))
    try:
        (work / "harness.py").write_text(HARNESS, encoding="utf-8")
        (work / "spec.json").write_text(json.dumps(spec), encoding="utf-8")
        shutil.copyfile(solution, work / "solution.py")
        for path in work.iterdir():
            path.chmod(0o444)
        work.chmod(0o555)
        kwargs: Dict[str, object] = {}
        if os.name == "posix":
            kwargs["preexec_fn"] = _limits
            if os.geteuid() == 0:
                kwargs.update(user=UNPRIVILEGED, group=UNPRIVILEGED, extra_groups=[])
        try:
            proc = subprocess.run(  # type: ignore[call-overload]
                [sys.executable, "-I", "harness.py"],
                cwd=str(work),
                input=nonce + "\n",
                capture_output=True,
                text=True,
                timeout=timeout,
                env={"PATH": "/usr/local/bin:/usr/bin:/bin", "HOME": str(work), "PYTHONHASHSEED": "0"},
                **kwargs,
            )
        except subprocess.TimeoutExpired:
            return False, {"error": "timed out after %.0fs" % timeout}
    finally:
        work.chmod(0o755)
        shutil.rmtree(work, ignore_errors=True)
    lines = [line for line in proc.stdout.splitlines() if line.strip()]
    passed = proc.returncode == 0 and bool(lines) and lines[-1] == "METACODES-PASS " + nonce
    details: Dict[str, object] = {"returncode": proc.returncode, "stderr_tail": proc.stderr[-2000:]}
    if proc.returncode == 0 and not passed:
        details["error"] = "the child exited 0 without completing the tests"
    return passed, details


def grade(spec_path: Path, solution: Path) -> Tuple[int, Dict[str, object]]:
    spec = json.loads(spec_path.read_text(encoding="utf-8"))
    passed, details = run_submission(spec, solution)
    details["passed"] = passed
    return (1 if passed else 0), details


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--spec", type=Path, required=True)
    parser.add_argument("--solution", type=Path, required=True)
    parser.add_argument("--reward", type=Path, required=True)
    parser.add_argument("--details", type=Path)
    args = parser.parse_args(argv)
    reward, details = grade(args.spec, args.solution)
    args.reward.parent.mkdir(parents=True, exist_ok=True)
    args.reward.write_text("%d\n" % reward, encoding="utf-8")
    if args.details:
        args.details.write_text(json.dumps(details, indent=1, sort_keys=True) + "\n", encoding="utf-8")
    print("reward=%d" % reward)
    return 0


if __name__ == "__main__":
    sys.exit(main())
