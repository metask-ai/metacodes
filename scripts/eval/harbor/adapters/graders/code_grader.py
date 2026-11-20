"""Deterministic unit-test grader for HumanEval and MBPP tasks.

Runs inside the separate verifier container (tests/Dockerfile), which holds
only this file, the task's spec.json and the agent's submitted
/app/solution.py (a declared Harbor artifact). Python 3.9+, stdlib only.

Threat model
------------
The submission is arbitrary Python written to be graded. Whatever runs in
its interpreter it can read and rewrite: globals of any module, builtins,
sys.modules, frames (sys._getframe, gc), stdin, the environment, files it can
open, /proc/self, signal handlers, atexit, threads, os._exit. So no pass
signal may come from the submission's process, and no test may run there,
because an object such as `class E: __eq__ = lambda *a: True` turns
`assert candidate(x) == y` into a pass in a shared interpreter (the reference
HumanEval/MBPP harnesses share one, and accept it).

Design: two processes that share no memory.

* The *submission* process (`--role submission`) runs the HumanEval prompt
  (or, for MBPP, nothing) then solution.py, then the MBPP setup code, all in
  one namespace as the reference harness does, and serves calls into that
  namespace over a pipe. Results go back as pickles in which every object
  that is not plain data (numbers, strings, bytes, lists, tuples, dicts,
  sets, a few stdlib containers) is replaced by an opaque handle.
* The *driver* process (`--role driver`) runs only dataset code: the
  HumanEval prompt and `check(candidate)`, or the MBPP imports and asserts.
  Names that the submission defines become proxies whose calls go over the
  pipe. Replies are unpickled with a whitelist of plain-data classes (no
  other class or callable can be named), handles compare by identity, and
  a reply the driver cannot decode marks the run broken. The driver reads
  the spec on stdin and reports by exit status 0 plus a final
  `METACODES-PASS` line on its own stdout, both written only after every
  test returned.

The grader (run as root by test.sh) runs the submission as uid/gid 65534 and
the driver as uid/gid 65533 with no supplementary groups, so the submission
can neither signal, trace nor read the driver (/proc/<pid>/fd, /proc/<pid>/mem)
nor read the spec, the driver's output or the grader's scratch directory
(0700, root). Both run with a memory limit, a file size limit, an empty
environment, `python -I`, a wall-clock limit and their own session; the cwd
is an empty read-only directory. After the driver exits or the time runs
out, the grader SIGKILLs both process groups and then every process left
under either uid (kill(-1) from a child switched to that uid, which also
reaches processes that left the group), and only then writes reward.txt.
Run as non-root (the local tests), both children keep the grader's uid and
the separation is by process only.

Out of scope: kernel or container escapes, and resource exhaustion beyond the
limits (which only fails the submission). A remote object returned as a
handle supports calls, attribute reads, iteration, len, indexing, `in`,
bool, str and repr; it equals only itself, so a test that compares a
submission-defined object (not plain data) to a value fails.

Usage:
  code_grader.py --spec spec.json --solution solution.py \
                 --reward reward.txt [--details grade.json]

spec.json: {"kind": "humaneval", "prompt": str, "entry_point": str, "test": str}
        or {"kind": "mbpp", "setup": str, "imports": [str], "tests": [str]}
        plus optional "timeout_sec" (default 60).
"""

from __future__ import annotations

import argparse
import builtins
import collections
import decimal
import fractions
import io
import json
import os
import pickle
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import time
import traceback
import types
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

SANDBOX_UID = 65534  # submission
DRIVER_UID = 65533  # dataset tests
MEMORY_LIMIT_BYTES = 2 << 30
FILE_SIZE_LIMIT_BYTES = 16 << 20
DEFAULT_TIMEOUT_SEC = 60.0
MAX_FRAME_BYTES = 64 << 20
MAX_NAMES = 10000
PASS_MARKER = "METACODES-PASS"
TAIL = 2000

# Exact types a reply may contain as values; everything else is a handle.
_PLAIN_TYPES = (
    type(None), bool, int, float, complex, str, bytes, bytearray, list, tuple, dict, set, frozenset,
    range, slice, collections.OrderedDict, collections.Counter, collections.defaultdict, collections.deque,
    decimal.Decimal, fractions.Fraction,
)
# The classes a reply pickle may name (the driver's whitelist).
_ALLOWED_GLOBALS = {
    ("builtins", name)
    for name in ("int", "float", "complex", "str", "bytes", "bytearray", "list", "tuple", "dict", "set",
                 "frozenset", "bool", "range", "slice")
} | {
    ("collections", name) for name in ("OrderedDict", "Counter", "defaultdict", "deque")
} | {("decimal", "Decimal"), ("fractions", "Fraction")}


# --- framing (both children) -------------------------------------------------


def _write_frame(fd: int, payload: bytes) -> None:
    data = struct.pack(">I", len(payload)) + payload
    view = memoryview(data)
    while view:
        written = os.write(fd, view)
        view = view[written:]


def _read_exact(fd: int, size: int) -> bytes:
    chunks: List[bytes] = []
    while size:
        chunk = os.read(fd, min(size, 1 << 20))
        if not chunk:
            raise EOFError("pipe closed")
        chunks.append(chunk)
        size -= len(chunk)
    return b"".join(chunks)


def _read_frame(fd: int) -> bytes:
    (size,) = struct.unpack(">I", _read_exact(fd, 4))
    if size > MAX_FRAME_BYTES:
        raise ValueError("frame too large")
    return _read_exact(fd, size)


# --- submission process (untrusted: everything here can be subverted) --------


def _submission_main(rfd: int, wfd: int) -> int:  # pragma: no cover - runs in the child
    payload = json.loads(sys.stdin.read())
    sys.stdin.close()
    module = types.ModuleType("__solution__")
    sys.modules["__solution__"] = module
    namespace = module.__dict__
    table: Dict[int, Any] = {}
    memo: Dict[int, int] = {}

    class ReplyPickler(pickle.Pickler):
        def persistent_id(self, obj: Any) -> Any:
            if type(obj) in _PLAIN_TYPES or (type(obj) is type and obj in _PLAIN_TYPES):
                return None  # data, or a plain class a reduce names (Counter, ...)
            key = id(obj)
            if key not in memo:
                memo[key] = len(table)
                table[memo[key]] = obj
            return ("ref", memo[key])

    class RequestUnpickler(pickle.Unpickler):
        def persistent_load(self, pid: Any) -> Any:
            if pid[0] == "name":
                return namespace[pid[1]]
            return table[pid[1]]

    def send(message: Any) -> None:
        buffer = io.BytesIO()
        try:
            ReplyPickler(buffer, protocol=4).dump(message)
        except Exception as exc:  # unpicklable reply (recursion, ...)
            buffer = io.BytesIO()
            ReplyPickler(buffer, protocol=4).dump(("raise", "RuntimeError", "unencodable reply: %r" % exc))
        _write_frame(wfd, buffer.getvalue())

    try:
        if payload.get("prompt"):
            exec(compile(payload["prompt"], "prompt.py", "exec"), namespace)
        exec(compile(payload["source"], "solution.py", "exec"), namespace)
        for line in payload.get("imports", []):
            exec(compile(line, "imports.py", "exec"), namespace)
        if payload.get("setup"):
            exec(compile(payload["setup"], "setup.py", "exec"), namespace)
    except BaseException:  # noqa: B902 - reported to the driver as a failure
        send(("error", traceback.format_exc()[-TAIL:]))
        return 1
    send(("hello", [name for name in namespace if isinstance(name, str) and not name.startswith("__")]))

    def resolve(target: Tuple[str, Any]) -> Any:
        if target[0] == "name":
            if target[1] not in namespace:
                raise NameError("name %r is not defined" % target[1])
            return namespace[target[1]]
        return table[target[1]]

    while True:
        try:
            request = RequestUnpickler(io.BytesIO(_read_frame(rfd))).load()
        except EOFError:
            return 0
        op, args = request[0], request[2:]
        try:
            target = resolve(request[1])
            if op == "call":
                value = target(*args[0], **args[1])
            elif op == "getattr":
                value = getattr(target, args[0])
            elif op == "len":
                value = len(target)
            elif op == "iter":
                value = iter(target)
            elif op == "next":
                value = next(target)
            elif op == "bool":
                value = bool(target)
            elif op == "repr":
                value = repr(target)
            elif op == "str":
                value = str(target)
            elif op == "getitem":
                value = target[args[0]]
            elif op == "contains":
                value = args[0] in target
            else:
                raise ValueError("unknown op")
        except BaseException as exc:  # noqa: B902 - mapped to a driver-side exception
            send(("raise", type(exc).__name__, str(exc)[:TAIL]))
            continue
        send(("ok", value))


# --- driver process (trusted: runs dataset code only) -----------------------


class ProtocolError(BaseException):
    """The submission broke the call protocol; not catchable as Exception."""


class _Channel:
    broken = False
    decoding = False
    rfd = -1
    wfd = -1
    refs: Dict[int, "RemoteRef"] = {}


class _ReplyUnpickler(pickle.Unpickler):
    def find_class(self, module: str, name: str) -> Any:
        if (module, name) not in _ALLOWED_GLOBALS:
            raise pickle.UnpicklingError("class %s.%s is not allowed" % (module, name))
        return super().find_class(module, name)

    def persistent_load(self, pid: Any) -> Any:
        if not (isinstance(pid, tuple) and len(pid) == 2 and pid[0] == "ref" and type(pid[1]) is int):
            raise pickle.UnpicklingError("bad handle")
        ref = _Channel.refs.get(pid[1])
        if ref is None:
            ref = _Channel.refs[pid[1]] = RemoteRef(("ref", pid[1]))
        return ref


class _RequestPickler(pickle.Pickler):
    def persistent_id(self, obj: Any) -> Any:
        if type(obj) is RemoteRef:
            return object.__getattribute__(obj, "_target")
        return None


def _rpc(op: str, target: Tuple[str, Any], *args: Any) -> Any:
    if _Channel.broken:
        raise ProtocolError("the submission process is gone")
    buffer = io.BytesIO()
    if _Channel.decoding:  # a reply's reduce may not call back into the submission
        _Channel.broken = True
        raise ProtocolError("a reply tried to call the submission while it was decoded")
    _RequestPickler(buffer, protocol=4).dump((op, target) + args)
    try:
        _write_frame(_Channel.wfd, buffer.getvalue())
        frame = _read_frame(_Channel.rfd)
        _Channel.decoding = True
        try:
            reply = _ReplyUnpickler(io.BytesIO(frame)).load()
        finally:
            _Channel.decoding = False
    except BaseException as exc:
        _Channel.broken = True
        raise ProtocolError("bad reply from the submission: %r" % exc) from None
    if isinstance(reply, tuple) and len(reply) == 2 and reply[0] == "ok":
        return reply[1]
    if isinstance(reply, tuple) and len(reply) == 3 and reply[0] == "raise" \
            and type(reply[1]) is str and type(reply[2]) is str:
        if op == "next" and reply[1] == "StopIteration":
            raise StopIteration
        exc_type = getattr(builtins, reply[1], None)
        if not (isinstance(exc_type, type) and issubclass(exc_type, Exception)) \
                or issubclass(exc_type, (StopIteration, StopAsyncIteration)):
            exc_type = RuntimeError
        raise exc_type("%s (raised by the submission: %s)" % (reply[2], reply[1]))
    _Channel.broken = True
    raise ProtocolError("malformed reply from the submission")


def _typed(value: Any, expected: type) -> Any:
    if type(value) is not expected:
        _Channel.broken = True
        raise ProtocolError("the submission returned %s where %s is required" % (type(value).__name__, expected.__name__))
    return value


class RemoteRef:
    """A name or object in the submission process; equal only to itself."""

    __slots__ = ("_target",)

    def __init__(self, target: Tuple[str, Any]) -> None:
        object.__setattr__(self, "_target", target)

    def _t(self) -> Tuple[str, Any]:
        return object.__getattribute__(self, "_target")

    def __call__(self, *args: Any, **kwargs: Any) -> Any:
        return _rpc("call", self._t(), args, kwargs)

    def __getattr__(self, name: str) -> Any:
        if name.startswith("__"):
            raise AttributeError(name)
        return _rpc("getattr", self._t(), name)

    def __setattr__(self, name: str, value: Any) -> None:
        raise TypeError("remote objects are read-only")

    def __len__(self) -> int:
        return _typed(_rpc("len", self._t()), int)

    def __iter__(self) -> "RemoteRef":
        value = _rpc("iter", self._t())
        if type(value) is not RemoteRef:
            return iter(value)  # type: ignore[return-value]
        return value

    def __next__(self) -> Any:
        return _rpc("next", self._t())

    def __bool__(self) -> bool:
        return _typed(_rpc("bool", self._t()), bool)

    def __repr__(self) -> str:
        return _typed(_rpc("repr", self._t()), str)

    def __str__(self) -> str:
        return _typed(_rpc("str", self._t()), str)

    def __getitem__(self, key: Any) -> Any:
        return _rpc("getitem", self._t(), key)

    def __contains__(self, item: Any) -> bool:
        return _typed(_rpc("contains", self._t(), item), bool)


def _driver_main(rfd: int, wfd: int) -> int:  # pragma: no cover - runs in the child
    spec = json.loads(sys.stdin.read())
    sys.stdin.close()
    _Channel.rfd, _Channel.wfd = rfd, wfd
    try:
        frame = _read_frame(rfd)
        _Channel.decoding = True
        hello = _ReplyUnpickler(io.BytesIO(frame)).load()
        _Channel.decoding = False
    except BaseException as exc:  # noqa: B902 - includes ProtocolError
        _Channel.broken = True
        print("the submission did not start: %r" % exc, file=sys.stderr)
        return 1
    if isinstance(hello, tuple) and len(hello) == 2 and hello[0] == "error" and type(hello[1]) is str:
        print("solution.py failed to load:\n" + hello[1], file=sys.stderr)
        return 1
    if not (isinstance(hello, tuple) and len(hello) == 2 and hello[0] == "hello" and type(hello[1]) is list
            and len(hello[1]) <= MAX_NAMES and all(type(n) is str and n.isidentifier() for n in hello[1])):
        print("malformed hello from the submission", file=sys.stderr)
        return 1
    defined = set(hello[1])
    try:
        if spec["kind"] == "humaneval":
            entry = spec["entry_point"]
            if entry not in defined:
                print("entry point %r is not defined" % entry, file=sys.stderr)
                return 1
            namespace: Dict[str, Any] = {"__name__": "__humaneval__"}
            exec(compile(spec.get("prompt", ""), "prompt.py", "exec"), namespace)
            # The prompt's own helpers (poly, encode_cyclic, ...) stay the
            # dataset's; its stub of the entry point is the submission's, as
            # some tests call it by name (HumanEval/33).
            candidate = namespace[entry] = RemoteRef(("name", entry))
            exec(compile(spec["test"], "test.py", "exec"), namespace)
            namespace["check"](candidate)
        elif spec["kind"] == "mbpp":
            namespace = {"__name__": "__mbpp__"}
            for line in spec.get("imports", []):
                exec(compile(line, "imports.py", "exec"), namespace)
            # The tests reach the submission's names (functions, classes and
            # the objects the setup code built): those the reference solution
            # binds (spec "names"), else every non-builtin it defines.
            names = spec.get("names")
            if names is None:
                names = [name for name in defined if not hasattr(builtins, name)]
            for name in names:
                if name not in namespace:
                    namespace[name] = RemoteRef(("name", name))
            for index, test in enumerate(spec["tests"]):
                exec(compile(test, "test_%d.py" % index, "exec"), namespace)
        else:
            print("unknown spec kind", file=sys.stderr)
            return 1
    except BaseException:  # noqa: B902 - any escape fails the run
        traceback.print_exc()
        return 1
    if _Channel.broken:
        print("the submission broke the protocol", file=sys.stderr)
        return 1
    sys.stdout.flush()
    sys.stdout.write("\n" + PASS_MARKER + "\n")
    sys.stdout.flush()
    return 0


# --- grader ------------------------------------------------------------------


def _limits() -> None:  # pragma: no cover - runs in the child
    import resource

    for limit, value in ((resource.RLIMIT_AS, MEMORY_LIMIT_BYTES), (resource.RLIMIT_CORE, 0),
                         (resource.RLIMIT_FSIZE, FILE_SIZE_LIMIT_BYTES)):
        try:
            resource.setrlimit(limit, (value, value))
        except (ValueError, OSError):  # macOS rejects RLIMIT_AS; Linux enforces it
            pass


def _is_root() -> bool:
    return os.name == "posix" and os.geteuid() == 0


def _kill_uid(uid: int) -> None:
    """SIGKILL every process running as `uid` (not the caller): kill(-1) as that uid."""
    pid = os.fork()
    if pid == 0:  # pragma: no cover - runs in the child
        try:
            os.setgroups([])
            os.setgid(uid)
            os.setuid(uid)
            for _ in range(1000):  # a forking process can add members between sweeps
                try:
                    os.kill(-1, signal.SIGKILL)
                except ProcessLookupError:
                    break
                time.sleep(0.001)
        finally:
            os._exit(0)
    os.waitpid(pid, 0)


def _kill_group(proc: "subprocess.Popen[bytes]") -> None:
    try:
        os.killpg(proc.pid, signal.SIGKILL)  # start_new_session: pgid == pid
    except (ProcessLookupError, PermissionError):
        pass


def _spawn(role: str, fds: Tuple[int, int], stdin: int, stdout: int, stderr: int, cwd: str,
           uid: Optional[int]) -> "subprocess.Popen[bytes]":
    kwargs: Dict[str, Any] = {}
    if os.name == "posix":
        kwargs["preexec_fn"] = _limits
        kwargs["start_new_session"] = True
        if uid is not None:
            kwargs.update(user=uid, group=uid, extra_groups=[])
    return subprocess.Popen(
        [sys.executable, "-I", str(Path(__file__).resolve()), "--role", role,
         "--rfd", str(fds[0]), "--wfd", str(fds[1])],
        cwd=cwd,
        stdin=stdin,
        stdout=stdout,
        stderr=stderr,
        pass_fds=fds,
        env={"PATH": "/usr/local/bin:/usr/bin:/bin", "HOME": cwd, "PYTHONHASHSEED": "0"},
        **kwargs,
    )


def _tail(path: Path) -> str:
    try:
        with path.open("rb") as handle:
            handle.seek(0, os.SEEK_END)
            handle.seek(max(0, handle.tell() - TAIL))
            return handle.read().decode("utf-8", "replace")
    except OSError:
        return ""


def run_submission(spec: Dict[str, object], solution: Optional[Path]) -> Tuple[bool, Dict[str, object]]:
    """(passed, details) for one submission against one spec."""
    if solution is None or not solution.is_file():
        return False, {"error": "no /app/solution.py was submitted"}
    timeout = float(spec.get("timeout_sec", DEFAULT_TIMEOUT_SEC))  # type: ignore[arg-type]
    root = _is_root()
    private = Path(tempfile.mkdtemp(prefix="grade-"))  # 0700: the grader's only
    cwd = Path(tempfile.mkdtemp(prefix="grade-cwd-"))
    cwd.chmod(0o555)
    procs: List["subprocess.Popen[bytes]"] = []
    pipe_fds: List[int] = []
    try:
        submission_input = {
            "source": solution.read_text(encoding="utf-8", errors="replace"),
            "prompt": spec.get("prompt", "") if spec.get("kind") == "humaneval" else "",
            "imports": spec.get("imports", []) if spec.get("kind") == "mbpp" else [],
            "setup": spec.get("setup", "") if spec.get("kind") == "mbpp" else "",
        }
        (private / "submission.json").write_text(json.dumps(submission_input), encoding="utf-8")
        (private / "spec.json").write_text(json.dumps(spec), encoding="utf-8")
        to_sub_r, to_sub_w = os.pipe()
        to_drv_r, to_drv_w = os.pipe()
        pipe_fds = [to_sub_r, to_sub_w, to_drv_r, to_drv_w]
        with open(private / "submission.json", "rb") as sub_in, open(private / "spec.json", "rb") as drv_in, \
                open(private / "sub.out", "wb") as sub_out, open(private / "sub.err", "wb") as sub_err, \
                open(private / "drv.out", "wb") as drv_out, open(private / "drv.err", "wb") as drv_err:
            submission = _spawn("submission", (to_sub_r, to_drv_w), sub_in.fileno(), sub_out.fileno(),
                                sub_err.fileno(), str(cwd), SANDBOX_UID if root else None)
            procs.append(submission)
            driver = _spawn("driver", (to_drv_r, to_sub_w), drv_in.fileno(), drv_out.fileno(),
                            drv_err.fileno(), str(cwd), DRIVER_UID if root else None)
            procs.append(driver)
        for fd in pipe_fds:
            os.close(fd)
        pipe_fds = []
        timed_out = False
        try:
            driver.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
    finally:
        for fd in pipe_fds:
            os.close(fd)
        # Nothing the submission started may outlive grading: the groups,
        # then every process left under either uid (a grandchild that called
        # setsid), before the caller writes reward.txt.
        for proc in procs:
            _kill_group(proc)
        if root:
            _kill_uid(SANDBOX_UID)
            _kill_uid(DRIVER_UID)
        for proc in procs:
            proc.kill()
            proc.wait()
        cwd.chmod(0o755)
        shutil.rmtree(cwd, ignore_errors=True)
    try:
        if timed_out:
            return False, {"error": "timed out after %.0fs" % timeout,
                           "submission_stderr_tail": _tail(private / "sub.err")}
        out = (private / "drv.out").read_text(encoding="utf-8", errors="replace")
        lines = [line for line in out.splitlines() if line.strip()]
        passed = driver.returncode == 0 and bool(lines) and lines[-1] == PASS_MARKER
        details: Dict[str, object] = {
            "returncode": driver.returncode,
            "stderr_tail": _tail(private / "drv.err"),
            "submission_stderr_tail": _tail(private / "sub.err"),
        }
        if driver.returncode == 0 and not passed:
            details["error"] = "the test driver exited 0 without completing the tests"
        return passed, details
    finally:
        shutil.rmtree(private, ignore_errors=True)


def grade(spec_path: Path, solution: Path) -> Tuple[int, Dict[str, object]]:
    spec = json.loads(spec_path.read_text(encoding="utf-8"))
    passed, details = run_submission(spec, solution)
    details["passed"] = passed
    return (1 if passed else 0), details


def main(argv: Optional[List[str]] = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if argv[:1] == ["--role"]:
        role = argparse.ArgumentParser()
        role.add_argument("--role", choices=("submission", "driver"), required=True)
        role.add_argument("--rfd", type=int, required=True)
        role.add_argument("--wfd", type=int, required=True)
        roles = role.parse_args(argv)
        child = _submission_main if roles.role == "submission" else _driver_main
        return child(roles.rfd, roles.wfd)
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--spec", type=Path, required=True)
    parser.add_argument("--solution", type=Path, required=True)
    parser.add_argument("--reward", type=Path, required=True)
    parser.add_argument("--details", type=Path)
    args = parser.parse_args(argv)
    reward, details = grade(args.spec, args.solution)  # every child is dead here
    args.reward.parent.mkdir(parents=True, exist_ok=True)
    args.reward.write_text("%d\n" % reward, encoding="utf-8")
    if args.details:
        args.details.write_text(json.dumps(details, indent=1, sort_keys=True) + "\n", encoding="utf-8")
    print("reward=%d" % reward)
    return 0


if __name__ == "__main__":
    sys.exit(main())
