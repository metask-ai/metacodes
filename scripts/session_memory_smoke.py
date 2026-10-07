#!/usr/bin/env python3
"""Zero-paid regression smoke: a long session must not keep what it frees.

An interactive session once ran on the process arena (`std.process.Init.arena`),
which frees nothing: every request body, streamed response and tool result
stayed committed until exit, and multi-day sessions reached tens of GB. This
drives the real binary with a scripted loopback provider and checks two things:

1. growth: over a headless session of READ_TURNS tool turns whose conversation
   grows by FILE_BYTES per turn, the child's memory grows (after WARMUP_TURNS)
   by less than the total size of the request bodies it sent meanwhile. On the
   arena it grew by about six times that; on the general-purpose allocator by
   about a third.
2. hygiene: a REPL session with tool turns, a forced auto-compaction and slash
   commands exits 0 with no panic and, on a Debug binary, no DebugAllocator
   leak or invalid-free report (the REPL path returns from `main`, so the
   allocator checks run at exit).

usage: session_memory_smoke.py --binary zig-out/bin/metacodes
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from typing import Callable, Dict, List, Optional

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.eval.workbuddy.mock_provider import (  # noqa: E402
    MOCK_CREDENTIAL,
    _final_sse,
    _LoopbackServer,
    _tool_sse,
)

READ_TURNS = 40
WARMUP_TURNS = 10
FILE_BYTES = 6000
CRASH = re.compile(r"panic|Segmentation fault|reached unreachable|error\(DebugAllocator\)|Invalid free|Double free")


def _memory_bytes(pid: int) -> Optional[int]:
    """Committed (Windows) or resident (POSIX) bytes of a live child."""
    if os.name == "nt":
        import ctypes
        import ctypes.wintypes as wt

        class Counters(ctypes.Structure):
            _fields_ = [("cb", wt.DWORD), ("PageFaultCount", wt.DWORD)] + [
                (name, ctypes.c_size_t)
                for name in (
                    "PeakWorkingSetSize", "WorkingSetSize", "QuotaPeakPagedPoolUsage",
                    "QuotaPagedPoolUsage", "QuotaPeakNonPagedPoolUsage", "QuotaNonPagedPoolUsage",
                    "PagefileUsage", "PeakPagefileUsage", "PrivateUsage",
                )
            ]

        handle = ctypes.windll.kernel32.OpenProcess(0x1000, False, pid)
        if not handle:
            return None
        try:
            counters = Counters()
            counters.cb = ctypes.sizeof(Counters)
            if not ctypes.windll.psapi.GetProcessMemoryInfo(handle, ctypes.byref(counters), counters.cb):
                return None
            return int(counters.PrivateUsage)
        finally:
            ctypes.windll.kernel32.CloseHandle(handle)
    status = Path(f"/proc/{pid}/status")
    if status.exists():
        match = re.search(r"^VmRSS:\s+(\d+) kB", status.read_text(errors="replace"), re.M)
        return int(match.group(1)) * 1024 if match else None
    completed = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True, check=False)
    return int(completed.stdout.strip()) * 1024 if completed.stdout.strip().isdigit() else None


class Provider:
    """Loopback Anthropic-SSE provider; `respond(n, request)` builds each answer."""

    def __init__(self, respond: Callable[[int, Dict], bytes]) -> None:
        self.respond = respond
        self.requests = 0
        self.body_bytes: List[int] = []
        self.memory: List[Optional[int]] = []
        self.pid: Optional[int] = None
        self.error = ""
        lock = threading.Lock()
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler contract
                body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                with lock:
                    outer.requests += 1
                    outer.body_bytes.append(len(body))
                    outer.memory.append(_memory_bytes(outer.pid) if outer.pid else None)
                    try:
                        payload = outer.respond(outer.requests, json.loads(body))
                    except Exception as exc:  # surfaced through the result, not a hung client
                        outer.error = f"{type(exc).__name__}: {exc}"
                        self.send_error(409)
                        return
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, *_args: object) -> None:
                return

        self.server = _LoopbackServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True).start()

    def close(self) -> None:
        self.server.shutdown()
        self.server.server_close()


def _run(binary: Path, provider: Provider, work: Path, args: List[str], stdin: Optional[str], extra_env: Dict[str, str]) -> subprocess.CompletedProcess:
    home = work / ".home"
    home.mkdir(parents=True, exist_ok=True)
    env = {key: value for key, value in os.environ.items() if not key.startswith(("METACODES_", "TINYKG_", "CLAUDE_CODE_", "METASK_"))}
    env.update(
        {
            "HOME": str(home),
            "USERPROFILE": str(home),
            "METACODES_NO_PROBE": "1",
            "METACODES_KG_AUTOSTART": "0",
            "METACODES_JEV_URL": "off",
            **extra_env,
        }
    )
    argv = [
        str(binary), "--api-key", MOCK_CREDENTIAL,
        "--base-url", f"http://127.0.0.1:{provider.server.server_port}/v1/messages",
        "--model", "offline", "--permission", "bypassPermissions", "--no-theme", *args,
    ]
    process = subprocess.Popen(
        argv, cwd=work, env=env,
        stdin=subprocess.PIPE if stdin is not None else subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    provider.pid = process.pid
    stdout, stderr = process.communicate(stdin.encode() if stdin is not None else None, timeout=180)
    return subprocess.CompletedProcess(argv, process.returncode, stdout, stderr)


def growth_check(binary: Path) -> List[str]:
    with tempfile.TemporaryDirectory(prefix="metacodes-memory-smoke-") as directory:
        work = Path(directory)
        line = "x" * 63 + "\n"
        for index in range(READ_TURNS):
            (work / f"f{index:03d}.txt").write_text(f"file {index}\n" + line * (FILE_BYTES // 64), encoding="utf-8")

        def respond(n: int, _request: Dict) -> bytes:
            if n <= READ_TURNS:
                return _tool_sse(n, f"read-{n}", "Read", {"file_path": str(work / f"f{n - 1:03d}.txt")})
            return _final_sse(n, "done")

        provider = Provider(respond)
        try:
            completed = _run(binary, provider, work, ["--json", "-p", "read the files"], None, {})
        finally:
            provider.close()
    problems = []
    if completed.returncode != 0 or provider.error or provider.requests != READ_TURNS + 1:
        return [f"growth session did not complete: exit {completed.returncode}, {provider.requests} requests, {provider.error}, stderr {completed.stderr[-400:]!r}"]
    if any(value is None for value in provider.memory):
        return ["growth session: could not sample the child's memory on this platform"]
    # Measure from a warmed-up turn: one-time startup work (background threads,
    # lazily built tables) lands at a variable point in the first requests.
    base = WARMUP_TURNS
    turns = len(provider.memory) - 1 - base
    growth = provider.memory[-1] - provider.memory[base]
    sent = sum(provider.body_bytes[base:])
    print(f"growth: {growth / 2**20:.1f} MiB over {turns} turns; request bodies sent: {sent / 2**20:.1f} MiB")
    if growth > sent:
        problems.append(
            f"memory grew {growth / 2**20:.1f} MiB over {turns} turns, more than the "
            f"{sent / 2**20:.1f} MiB of request bodies sent: the session is keeping freed buffers"
        )
    return problems


def hygiene_check(binary: Path) -> List[str]:
    sequence = [
        ("Write", {"file_path": "smoke/a.txt", "content": "alpha\nbeta\n"}),
        ("Read", {"file_path": "smoke/a.txt"}),
        ("Edit", {"file_path": "smoke/a.txt", "old_string": "beta", "new_string": "gamma"}),
        ("Grep", {"pattern": "gamma", "path": "smoke"}),
        ("TaskCreate", {"subject": "first", "description": "d"}),
        ("TaskList", {}),
    ]

    def respond(n: int, request: Dict) -> bytes:
        if not request.get("tools"):
            return _final_sse(n, "SUMMARY: smoke/a.txt was written, read and edited.")
        messages = request.get("messages", [])
        steps = 0
        for message in reversed(messages):
            content = message.get("content")
            if isinstance(content, str):
                break
            results = sum(1 for block in content or [] if block.get("type") == "tool_result")
            if message.get("role") == "user" and not results:
                break
            steps += results
        if steps < len(sequence):
            name, args = sequence[steps]
            return _tool_sse(n, f"smoke-{n}", name, args)
        return _final_sse(n, "turn finished")

    provider = Provider(respond)
    try:
        with tempfile.TemporaryDirectory(prefix="metacodes-memory-smoke-repl-") as directory:
            completed = _run(
                binary, provider, Path(directory), [],
                "first turn\n/cost\nsecond turn\n/clear\nthird turn\n/exit\n",
                {"METACODES_FORCE_COMPACT_AT": "20000", "METACODES_FORCE_COMPACT_KEEP": "4"},
            )
    finally:
        provider.close()
    stderr = completed.stderr.decode("utf-8", "replace")
    problems = []
    if completed.returncode != 0 or provider.error:
        problems.append(f"REPL session exited {completed.returncode} ({provider.error})")
    crash = CRASH.search(stderr)
    if crash:
        start = max(0, crash.start() - 200)
        problems.append(f"REPL session reported {crash.group(0)!r}: {stderr[start:start + 1200]}")
    print(f"hygiene: REPL exit {completed.returncode}, {provider.requests} requests")
    return problems


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--binary", type=Path, required=True)
    args = parser.parse_args(argv)
    binary = args.binary.resolve()
    started = time.monotonic()
    problems = growth_check(binary) + hygiene_check(binary)
    for problem in problems:
        print(f"FAIL: {problem}", file=sys.stderr)
    print(f"session memory smoke: {'FAIL' if problems else 'ok'} in {time.monotonic() - started:.1f}s")
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
