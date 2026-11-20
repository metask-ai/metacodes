"""Remote side of an SSH Bench executor. Runs on the Linux execution host,
inside that host's own `metacodes` (node.py):

    metacodes bench node run <spec.json>
    metacodes bench node manifest <job-dir>
    metacodes bench node pack <job-dir>   # JSON items on stdin

`run` reads one JSON line from stdin first,
`{"env": {NAME: value}, "credential": "<real token>"}`, carried by the SSH
channel instead of argv or a file. `env` goes to Harbor's environment: the
run's key variable there holds only the run-scoped placeholder the task
containers present. `credential` stays in this process: the credential relay
it starts beside this host's Docker daemon accepts the placeholder and
forwards with this real token. It runs Harbor in its own process group and
prints JSON events on stdout (`started`, `heartbeat` every 2 s, `exit`).
Later stdin lines are control messages:

- `{"credential": "<new token>"}`: a refreshed access token from the
  workbench (which alone holds the refresh token); the relay swaps it in
  atomically, and keeps the previous one if none arrives;
- `cancel`, or the channel closing: interrupt Harbor (SIGINT, then SIGKILL
  after 20 s).

With `"egress"` in the spec, the driver starts the run's egress
(viewer/egress.py) before Harbor and removes it after: in workbench mode a
forwarder on the Docker bridge's gateway to the session's `ssh -R` port, and
in both modes a run-scoped DOCKER_CONFIG directory holding only the proxy
settings (`egress` event). With `"ghcr_mirror"`, ghcr.io images the selected
tasks name and that are missing locally are pulled through the mirror and
tagged back first (`ghcr` event; heartbeats continue meanwhile).

`egress-probe <json>` is setup's end-to-end check of that path from a
container on a user-defined network.

`pack` streams a PAX tar of the requested files. An item is a name, or
`[name, offset, sha256]`: when the DELTA_CHECK_BYTES before `offset` still
hash to `sha256`, only the bytes from `offset` on are sent and the member
carries `metacodes.offset`; otherwise the whole file. Every member carries
`metacodes.stamp` ("size mtime_ns" of what was read). Python 3.9, stdlib only.
"""
from __future__ import annotations

import hashlib
import json
import os
import signal
import subprocess
import sys
import tarfile
import threading
import time
from pathlib import Path, PurePosixPath
from urllib.parse import urlsplit

DELTA_CHECK_BYTES = 64 * 1024  # executors.DELTA_CHECK_BYTES


EMIT_LOCK = threading.Lock()


def emit(event, **fields):
    with EMIT_LOCK:
        sys.stdout.write(json.dumps({"event": event, **fields}) + "\n")
        sys.stdout.flush()


def absolute(value):
    return str(Path(value).expanduser().resolve()) if value else value


def run(spec_path):
    os.chdir(os.path.expanduser("~"))
    first = sys.stdin.buffer.readline()
    try:
        message = json.loads(first)
        secret_env = message["env"]
        if not isinstance(secret_env, dict) or not all(isinstance(k, str) and isinstance(v, str)
                                                       for k, v in secret_env.items()):
            raise ValueError
        real = message.get("credential")
        if real is not None and not (isinstance(real, str) and real):
            raise ValueError
        judge_real = message.get("judge_credential")
        if judge_real is not None and not (isinstance(judge_real, str) and judge_real):
            raise ValueError
    except (ValueError, KeyError, TypeError, AttributeError):
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
        elif index and argv[index - 1] in ("-o", "-p"):
            argv[index] = absolute(value)
    env = dict(os.environ)
    env.update(secret_env)
    # Harbor imports the agent from this node's own runtime.
    env["PYTHONPATH"] = str(Path(__file__).resolve().parents[4])
    env["PYTHONUNBUFFERED"] = "1"
    relay = None
    credential = None
    session = None
    stop = threading.Event()
    hung_up = threading.Event()
    try:
        if spec.get("relay"):
            from scripts.eval.harbor.profiling import JUDGE_TOKEN_ENV, PushedCredential, TimingRelay, judge_argv
            options = spec["relay"]
            connect = None
            if options.get("refuse_local_upstream"):
                from scripts.eval.harbor.bench.egress import connect_not_local, names_this_machine
                connect = connect_not_local
                if names_this_machine(urlsplit(options["upstream"]).hostname or ""):
                    # This machine resolves the imported address to itself:
                    # never send the key to whatever listens here.
                    emit("error", message="导入的 Provider 地址在执行机器上解析为本机（回环地址），已拒绝连接；"
                                          "请改用两台机器都能访问到同一网关的地址")
                    return 2
            token = secret_env[spec["key_env"]]
            credential = PushedCredential(real or token)
            judge = options.get("judge")
            # The verifier's judge: its own placeholder (in Harbor's env from
            # the stdin line), the run's pushed token unless a fixed key came.
            judge_token = secret_env.get(JUDGE_TOKEN_ENV) if judge else None
            if judge and not judge_token:
                emit("error", message="missing judge placeholder")
                return 2
            relay = TimingRelay(options["upstream"], credential, absolute(options["metrics_dir"]),
                                bind=options.get("bind") or "172.17.0.1", auth_header=options["auth_header"],
                                auth_prefix=options["auth_prefix"], tls=True, token=token,
                                record=options.get("record", True), judge_token=judge_token,
                                judge_credential=judge_real, connect=connect).__enter__()
            argv += ["--ak", "metrics_proxy=" + relay.url, "--ak", "metrics_ca=" + str(relay.ca_path)]
            if judge:
                argv += judge_argv(judge, relay.url)
                for role in ("api_key", "base_url", "model"):
                    env.pop(judge["env"][role], None)  # the executor's own judge settings
        if spec.get("egress") or spec.get("ghcr_mirror"):
            from scripts.eval.harbor.bench import egress
        if spec.get("egress"):
            # For this run only: the forwarder on the Docker bridge and a
            # DOCKER_CONFIG that tells the docker CLI to give every container
            # the proxy. Removed in `finally`, whatever happens.
            relay_host = urlsplit(relay.url).hostname if relay else None
            # Sidecars are addressed by compose service name: direct, never proxied.
            dataset, patterns = dataset_selection(argv)
            services = egress.task_services(Path(dataset), patterns) if dataset else list(egress.HARBOR_SERVICES)
            session = egress.Session(spec["egress"], Path(spec_path).resolve().parent, [relay_host] + services,
                                     env=env)
            env["DOCKER_CONFIG"] = str(session.directory)
            emit("egress", mode=spec["egress"]["mode"], proxy=session.proxy_url, no_proxy=session.no_proxy)
        return supervise(spec, argv, env, credential, stop, hung_up,
                         egress if spec.get("ghcr_mirror") else None)
    finally:
        if session is not None:
            session.close()
        if relay:
            relay.__exit__(None, None, None)


def dataset_selection(argv):
    """(the `-p` dataset directory, the `-i` patterns) of a Harbor argv."""
    dataset = next((argv[i + 1] for i, a in enumerate(argv[:-1]) if a == "-p"), None)
    return dataset, [argv[i + 1] for i, a in enumerate(argv[:-1]) if a == "-i"]


def supervise(spec, argv, env, credential, stop, hung_up, egress=None, cwd=None):
    """Run Harbor: control channel, heartbeats, cancel; the exit code."""

    def control():
        for line in sys.stdin.buffer:
            line = line.strip()
            if line == b"cancel":
                stop.set()
            elif line.startswith(b"{"):
                try:
                    update = json.loads(line).get("credential")
                except (ValueError, AttributeError):
                    continue
                if credential is not None:
                    credential.set(update)
                    try:
                        emit("credential", pushes=credential.pushes)  # a count, never the token
                    except (BrokenPipeError, OSError):
                        pass
        hung_up.set()
        stop.set()

    threading.Thread(target=control, daemon=True).start()
    dataset, patterns = dataset_selection(argv)
    if egress is not None and dataset:
        images = egress.ghcr_images(Path(dataset), patterns)
        if images:
            # Pulls can outlast the worker's 90 s heartbeat window.
            pulling = threading.Event()

            def beat():
                while not pulling.wait(2):
                    try:
                        emit("heartbeat", phase="ghcr")
                    except (BrokenPipeError, OSError):
                        stop.set()
                        return
            threading.Thread(target=beat, daemon=True).start()
            try:
                tagged = egress.ensure_ghcr(images, spec["ghcr_mirror"], env=env, stop=stop,
                                            log=lambda text: print(text, file=sys.stderr, flush=True))
            finally:
                pulling.set()
            try:
                emit("ghcr", images=len(images), tagged=len(tagged))
            except (BrokenPipeError, OSError):
                stop.set()
            if stop.is_set():  # cancelled (or the channel closed) while pulling
                try:
                    emit("exit", code=130, cancelled=True)
                except (BrokenPipeError, OSError):
                    pass
                return 130
    # Harbor's own output goes to stderr, which SSH carries to the local
    # worker's log; stdout carries only events.
    process = subprocess.Popen(argv, env=env, cwd=cwd, stdin=subprocess.DEVNULL, stdout=sys.stderr.fileno(),
                               start_new_session=True)
    emit("started", pid=process.pid)
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


def files(root):
    root = Path(root)
    result = {}
    if not root.is_dir():
        return result
    for path in root.rglob("*"):
        try:
            if path.is_file() and not path.is_symlink():
                stat = path.stat()
                result[path.relative_to(root).as_posix()] = [stat.st_size, stat.st_mtime_ns]
        except OSError:
            continue  # removed while listing
    return result


class Exactly:
    """`size` bytes of a file that may shrink while it is read (zero padded;
    the next manifest shows the change and the file is sent again)."""

    def __init__(self, handle, size):
        self.handle, self.left = handle, size

    def read(self, size=-1):
        size = self.left if size is None or size < 0 else min(size, self.left)
        chunk = self.handle.read(size)
        chunk += b"\0" * (size - len(chunk))
        self.left -= len(chunk)
        return chunk


def pack_item(archive, root, item):
    if isinstance(item, str):
        name, offset, base = item, 0, None
    elif (isinstance(item, list) and len(item) == 3 and isinstance(item[0], str) and type(item[1]) is int
          and isinstance(item[2], str)):
        name, offset, base = item
    else:
        return
    if not name or PurePosixPath(name).is_absolute() or ".." in PurePosixPath(name).parts:
        return
    path = root / name
    if path.is_symlink() or not path.is_file() or root not in path.resolve().parents:
        return
    try:
        handle = open(path, "rb")
    except OSError:
        return
    with handle:
        info = os.fstat(handle.fileno())
        start = 0
        if base is not None and DELTA_CHECK_BYTES <= offset <= info.st_size:
            handle.seek(offset - DELTA_CHECK_BYTES)
            if hashlib.sha256(handle.read(DELTA_CHECK_BYTES)).hexdigest() == base:
                start = offset
        member = tarfile.TarInfo(name)
        member.size = info.st_size - start
        member.mtime = int(info.st_mtime)
        member.mode = 0o644
        member.pax_headers = {"metacodes.stamp": f"{info.st_size} {info.st_mtime_ns}"}
        if start:
            member.pax_headers["metacodes.offset"] = str(start)
        handle.seek(start)
        archive.addfile(member, Exactly(handle, member.size))


def pack(root):
    root = Path(root).resolve()
    items = json.loads(sys.stdin.read() or "[]")
    with tarfile.open(fileobj=sys.stdout.buffer, mode="w|", format=tarfile.PAX_FORMAT) as archive:
        for item in items if isinstance(items, list) else []:
            pack_item(archive, root, item)
    sys.stdout.flush()
    return 0


PROBE_IMAGE = "alpine:3.20"


def egress_probe(options):
    """Setup's check of the container egress path: a container on a fresh
    user-defined network (as Harbor's compose projects use) fetches the
    workbench proxy's probe page through the forwarder (workbench mode) or
    reaches the site proxy (proxy mode). Prints one JSON line."""
    from scripts.eval.harbor.bench import egress
    import uuid
    network = "metacodes-bench-egress-" + uuid.uuid4().hex[:8]
    result = {"ok": False}
    forwarder = None
    try:
        if options["mode"] == "workbench":
            gateway = egress.docker_gateway() or options.get("bind") or "172.17.0.1"
            forwarder = egress.Forwarder(gateway, ("127.0.0.1", int(options["tunnel_port"]))).start()
            url = "http://%s:%d%s" % (forwarder.address[0], forwarder.address[1], egress.PROBE_PATH)
            result["gateway"] = gateway
        else:
            url = options["url"]
        result["url"] = url
        created = subprocess.run(["docker", "network", "create", network], stdin=subprocess.DEVNULL,
                                 capture_output=True, text=True, timeout=60)
        if created.returncode != 0:
            result["error"] = "network: " + (created.stderr or created.stdout or "").strip()[-300:]
            return result
        if options["mode"] == "workbench":
            command = ["wget", "-q", "-T", "10", "-O", "-", url]
        else:  # a site proxy: its port must accept connections from containers
            parts = urlsplit(url)
            command = ["nc", "-z", "-w", "5", parts.hostname, str(parts.port or 80)]
        done = subprocess.run(["docker", "run", "--rm", "--network", network, PROBE_IMAGE] + command,
                              stdin=subprocess.DEVNULL, capture_output=True, timeout=300)
        body = done.stdout.decode(errors="replace").strip()
        result["ok"] = done.returncode == 0 and (options["mode"] != "workbench"
                                                 or body == egress.PROBE_BODY.decode())
        if not result["ok"]:
            result["error"] = (done.stderr.decode(errors="replace") or body).strip()[-300:]
            return result
        external = options.get("external")
        if options["mode"] == "workbench" and external:
            # The probe page proves the tunnel; a real outside fetch proves
            # the proxy's own network and policy (e.g. a fake-IP resolver).
            proxy = "http://%s:%d" % forwarder.address
            fetched = subprocess.run(["docker", "run", "--rm", "--network", network, "-e", "http_proxy=" + proxy,
                                      PROBE_IMAGE, "wget", "-q", "-T", "20", "-O", "/dev/null", external],
                                     stdin=subprocess.DEVNULL, capture_output=True, timeout=300)
            result["external"] = external
            if fetched.returncode != 0:
                result["ok"] = False
                result["error"] = "外网访问失败（" + external + "）：" + \
                    (fetched.stderr.decode(errors="replace") or fetched.stdout.decode(errors="replace")).strip()[-300:]
        return result
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        result["error"] = f"{type(exc).__name__}: {exc}"
        return result
    finally:
        if forwarder is not None:
            forwarder.close()
        subprocess.run(["docker", "network", "rm", network], stdin=subprocess.DEVNULL, capture_output=True,
                       timeout=60)


def main(argv=None):
    args = list(sys.argv[1:] if argv is None else argv)
    if len(args) == 2 and args[0] == "egress-probe":
        result = egress_probe(json.loads(args[1]))
        print(json.dumps(result))
        return 0 if result["ok"] else 1
    if len(args) != 2 or args[0] not in ("run", "manifest", "pack"):
        print("usage: remote.py run <spec> | manifest <dir> | pack <dir> | egress-probe <json>", file=sys.stderr)
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
