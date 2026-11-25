"""TinyKG services (`metacodes --state-dir <root> kgd`) a test left running.

A CLI session that needs TinyKG starts its install's service in its own state
root, and the service outlives the session on purpose: it does not exit when
idle (apps/cli/src/app/kg_autostart.zig). A test that runs the real binary in a
throwaway HOME therefore leaves one service behind per run, unless it sets
`METACODES_KG_AUTOSTART=0` or stops what it started. Once the temporary
directory is gone, nobody can reach that service again.

These helpers find and stop the services whose state root lies under a given
directory, so a test can assert that it leaves none. They read the process
table with `ps` and match the command line, so they work on POSIX only; on
other platforms they report nothing.
"""

from __future__ import annotations

import contextlib
import os
import signal
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Iterator, List, Union

PathLike = Union[str, Path]


def _needles(root: PathLike) -> List[str]:
    """`--state-dir <root>/` as the child saw it, and with symlinks resolved
    (macOS /var is /private/var; the child keeps whichever spelling it got)."""
    spellings = {os.path.abspath(str(root))}
    try:
        spellings.add(str(Path(root).resolve()))
    except OSError:
        pass
    return [" --state-dir " + spelling.rstrip("/") + "/" for spelling in spellings] + [
        " --state-dir " + spelling.rstrip("/") + " " for spelling in spellings
    ]


def live_kgd_under(root: PathLike) -> List[int]:
    """Pids of live `... --state-dir <dir> kgd [--config <path>]` processes
    whose <dir> is `root` or lies below it. Autostart adds `--config` when
    METACODES_KG_CONFIG names the configuration, so `kgd` need not be the
    last word."""
    if os.name != "posix":
        return []
    try:
        # `-ww`: unlimited width on both procps and BSD ps, whatever the
        # caller's terminal or COLUMNS; a cut line would hide the service.
        listing = subprocess.run(
            ["ps", "-A", "-ww", "-o", "pid=", "-o", "command="],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            errors="replace",
            timeout=10,
            check=False,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    needles = _needles(root)
    pids = []
    for line in listing.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) != 2 or not fields[0].isdigit():
            continue
        command = fields[1].rstrip() + " "
        for needle in needles:
            at = command.find(needle)
            # The subcommand follows the state root; keep the needle's last
            # character so a root named exactly still has its separator.
            if at >= 0 and " kgd " in command[at + len(needle) - 1 :]:
                pids.append(int(fields[0]))
                break
    return pids


def stop_kgd_under(root: PathLike, timeout: float = 5.0) -> List[int]:
    """Stop the services `live_kgd_under(root)` names: SIGTERM, then SIGKILL
    after `timeout` seconds. Returns the pids it signalled."""
    pids = live_kgd_under(root)
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
    deadline = time.monotonic() + timeout
    remaining = list(pids)
    while remaining and time.monotonic() < deadline:
        remaining = [pid for pid in remaining if _alive(pid)]
        if remaining:
            time.sleep(0.05)
    for pid in remaining:
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
    return pids


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    # A child of this process that exited stays a zombie until reaped.
    try:
        reaped, _ = os.waitpid(pid, os.WNOHANG)
        return reaped == 0
    except ChildProcessError:
        return True


@contextlib.contextmanager
def temporary_directory_without_kgd(**kwargs) -> Iterator[str]:
    """`tempfile.TemporaryDirectory` for a test that runs the real binary:
    any TinyKG service still running under it at exit is stopped, and when
    the body succeeded, its presence fails the test (the run leaked it)."""
    with tempfile.TemporaryDirectory(**kwargs) as directory:
        succeeded = False
        try:
            yield directory
            succeeded = True
        finally:
            leaked = stop_kgd_under(directory)
        if succeeded and leaked:
            raise AssertionError(
                f"the run left TinyKG services running under {directory}: pids {leaked}; "
                "set METACODES_KG_AUTOSTART=0 or stop what it started"
            )
