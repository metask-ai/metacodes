"""Remote side of an SSH Bench executor. Runs on the Linux execution host.

    python3 -m scripts.eval.harbor.viewer.remote run <spec.json>
    python3 -m scripts.eval.harbor.viewer.remote manifest <job-dir>
    python3 -m scripts.eval.harbor.viewer.remote pack <job-dir>   # JSON names on stdin

`run` reads exactly one JSON line from stdin, `{"env": {NAME: value}}`: the
run's credential, carried by the SSH channel instead of argv or a file. It
starts the timing relay beside this host's Docker daemon (when the spec asks
for one), runs Harbor in its own process group and prints JSON events on
stdout (`started`, `heartbeat` every 2 s, `exit`). A later stdin line
`cancel`, or the channel closing, interrupts Harbor (SIGINT, then SIGKILL
after 20 s). Python 3.9, stdlib only.
"""
from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import tarfile
import threading
import time
from pathlib import Path, PurePosixPath


def emit(event, **fields):
    sys.stdout.write(json.dumps({"event": event, **fields}) + "\n")
    sys.stdout.flush()


def absolute(value):
    return str(Path(value).expanduser().resolve()) if value else value


def run(spec_path):
    os.chdir(os.path.expanduser("~"))
    first = sys.stdin.buffer.readline()
    try:
        secret_env = json.loads(first)["env"]
        if not isinstance(secret_env, dict) or not all(isinstance(k, str) and isinstance(v, str)
                                                       for k, v in secret_env.items()):
            raise ValueError
    except (ValueError, KeyError, TypeError):
        emit("error", message="missing credential line")
        return 2
    spec = json.loads(Path(spec_path).read_text(encoding="utf-8"))
    argv = list(spec["argv"])
    # Paths in the spec are relative to the executor's home directory.
    if "/" in argv[0]:
        argv[0] = absolute(argv[0])
    for index, value in enumerate(argv):
        if index and argv[index - 1] == "--ak" and value.split("=", 1)[0] in ("bundle", "config"):
            key, path = value.split("=", 1)
            argv[index] = key + "=" + absolute(path)
        elif index and argv[index - 1] == "-o":
            argv[index] = absolute(value)
    env = dict(os.environ)
    env.update(secret_env)
    runtime = absolute(spec.get("runtime") or ".")
    env["PYTHONPATH"] = runtime
    env["PYTHONUNBUFFERED"] = "1"
    relay = None
    if spec.get("relay"):
        sys.path.insert(0, runtime)
        from scripts.eval.harbor.profiling import TimingRelay
        options = spec["relay"]
        relay = TimingRelay(options["upstream"], secret_env[spec["key_env"]], absolute(options["metrics_dir"]),
                            bind=options.get("bind") or "172.17.0.1", auth_header=options["auth_header"],
                            auth_prefix=options["auth_prefix"], tls=True).__enter__()
        argv += ["--ak", "metrics_proxy=" + relay.url, "--ak", "metrics_ca=" + str(relay.ca_path)]
    stop = threading.Event()
    hung_up = threading.Event()

    def control():
        for line in sys.stdin.buffer:
            if line.strip() == b"cancel":
                stop.set()
        hung_up.set()
        stop.set()

    try:
        # Harbor's own output goes to stderr, which SSH carries to the local
        # worker's log; stdout carries only events.
        process = subprocess.Popen(argv, env=env, stdin=subprocess.DEVNULL, stdout=sys.stderr.fileno(),
                                   start_new_session=True)
        emit("started", pid=process.pid)
        threading.Thread(target=control, daemon=True).start()
        interrupted_at = None
        last = 0.0
        while process.poll() is None:
            if stop.is_set() and interrupted_at is None:
                interrupted_at = time.monotonic()
                emit("cancelling", hung_up=hung_up.is_set())
                os.killpg(process.pid, signal.SIGINT)
            if interrupted_at and time.monotonic() - interrupted_at > 20:
                os.killpg(process.pid, signal.SIGKILL)
            if time.monotonic() - last > 2:
                try:
                    emit("heartbeat")
                except (BrokenPipeError, OSError):
                    stop.set()
                last = time.monotonic()
            time.sleep(0.25)
        try:
            emit("exit", code=process.returncode, cancelled=interrupted_at is not None)
        except (BrokenPipeError, OSError):
            pass
        return process.returncode
    finally:
        if relay:
            relay.__exit__(None, None, None)


def files(root):
    root = Path(root)
    result = {}
    if not root.is_dir():
        return result
    for path in root.rglob("*"):
        if path.is_file() and not path.is_symlink():
            stat = path.stat()
            result[path.relative_to(root).as_posix()] = [stat.st_size, stat.st_mtime_ns]
    return result


def pack(root):
    root = Path(root).resolve()
    names = json.loads(sys.stdin.read() or "[]")
    with tarfile.open(fileobj=sys.stdout.buffer, mode="w|") as archive:
        for name in names:
            parts = PurePosixPath(name).parts
            if not isinstance(name, str) or PurePosixPath(name).is_absolute() or ".." in parts:
                continue
            path = root / name
            if path.is_symlink() or not path.is_file() or root not in path.resolve().parents:
                continue
            archive.add(str(path), arcname=name, recursive=False)
    sys.stdout.flush()
    return 0


def main(argv=None):
    args = list(sys.argv[1:] if argv is None else argv)
    if len(args) != 2 or args[0] not in ("run", "manifest", "pack"):
        print("usage: remote.py run <spec> | manifest <dir> | pack <dir>", file=sys.stderr)
        return 2
    action, target = args
    if action == "run":
        return run(target)
    if action == "manifest":
        print(json.dumps(files(target)))
        return 0
    return pack(target)


if __name__ == "__main__":
    sys.exit(main())
