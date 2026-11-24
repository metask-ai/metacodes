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
- `{"concurrency": N}`: the most trials Harbor runs at once from now on,
  written to the file its trial queue reads (live_concurrency.py);
- `{"tunnel_port": N}`: the executor loopback port of the `ssh -R` forward
  the session that attached carries; the egress forwarder relays there;
- `cancel`: interrupt Harbor (SIGINT, then SIGKILL after 20 s).

The channel closing does not stop the run: Harbor and the relay keep going
and `attach <spec.json>` connects a new session to the driver (on the
socket attach_socket() names for the run directory), whose stdin/stdout
then carry the same control lines and events. Until that socket listens,
the run directory's DRIVER_PID tells `attach` the driver is still starting. Only when no session is back within the spec's
`detach_grace` seconds is Harbor interrupted. The run's terminal event is
also kept in the run directory, so a session attaching after the end still
receives it; with the original session gone, the driver's and Harbor's
output goes to DRIVER_LOG there.

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
import socket
import subprocess
import sys
import tarfile
import threading
import time
from pathlib import Path, PurePosixPath
from urllib.parse import urlsplit

from scripts.eval.harbor import live_concurrency

DELTA_CHECK_BYTES = 64 * 1024  # executors.DELTA_CHECK_BYTES
DETACH_GRACE = 1800
SOCKET_ROOT = "/tmp"  # short: AF_UNIX paths are limited to about 100 bytes
DRIVER_PID = "driver.pid"
END_EVENT = "end.json"
DRIVER_LOG = "driver.log"


EMIT_LOCK = threading.Lock()
OUT = None  # the attached session's writer; None while the first one lasts


def attach_socket(run_dir):
    """The attach socket of the driver of `run_dir`: a bounded name in a
    directory only this user can enter."""
    root = Path(SOCKET_ROOT) / f"metacodes-bench-{os.getuid()}"
    try:
        root.mkdir(mode=0o700)
    except FileExistsError:
        pass
    info = os.lstat(root)
    if not os.path.isdir(root) or os.path.islink(root) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise OSError(f"{root} 不是当前用户私有的目录")
    digest = hashlib.sha256(str(Path(run_dir).resolve()).encode()).hexdigest()[:24]
    return str(root / (digest + ".sock"))


def claim(run_dir):
    """Mark `run_dir` as having a live driver, for `attach` to wait on."""
    try:
        (Path(run_dir) / DRIVER_PID).write_text(str(os.getpid()), encoding="ascii")
    except OSError:
        pass


def driver_alive(run_dir):
    try:
        os.kill(int((Path(run_dir) / DRIVER_PID).read_text(encoding="ascii")), 0)
        return True
    except (OSError, ValueError):
        return False


def emit(event, **fields):
    """Send one event to the current session. A lost session is not an
    error here: the run goes on and the next session gets later events."""
    line = json.dumps({"event": event, **fields}) + "\n"
    with EMIT_LOCK:
        try:
            out = OUT or sys.stdout
            out.write(line)
            out.flush()
        except (OSError, ValueError):
            pass


class Control:
    """The run's control channel: the session that started it, then each
    session that attaches. `lost_at` is when the current one closed."""

    def __init__(self, run_dir, on_line, grace):
        self.run_dir, self.on_line, self.grace = run_dir, on_line, grace
        self.lock = threading.Lock()
        self.current = 0
        self.lost_at = None
        self.quiet = False
        self.listener = None
        self.path = None

    def follow(self, reader, generation):
        try:
            for line in reader:
                self.on_line(line.strip())
        except (OSError, ValueError):
            pass
        with self.lock:
            if generation == self.current:
                self.lost_at = time.monotonic()
                self.silence()

    def silence(self):
        """Point stdout and stderr at DRIVER_LOG once the first session is
        gone, so neither the driver nor Harbor writes into a dead channel."""
        if self.quiet or self.run_dir is None:
            return
        self.quiet = True
        fd = os.open(str(self.run_dir / DRIVER_LOG), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        os.dup2(fd, 1)
        os.dup2(fd, 2)
        os.close(fd)

    def listen(self):
        """Accept attaching sessions; False when the socket cannot be bound."""
        previous = os.umask(0o077)
        try:
            path = self.path = attach_socket(self.run_dir)
            if os.path.lexists(path):
                os.unlink(path)
            self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.listener.bind(path)
            self.listener.listen(4)
        except OSError:
            self.listener = None
            return False
        finally:
            os.umask(previous)

        def accept():
            global OUT
            while True:
                try:
                    conn, _ = self.listener.accept()
                except OSError:
                    return
                with self.lock:
                    self.current += 1
                    generation = self.current
                    self.lost_at = None
                    self.silence()
                    with EMIT_LOCK:
                        OUT = conn.makefile("w", encoding="utf-8")
                threading.Thread(target=self.follow, args=(conn.makefile("rb"), generation), daemon=True).start()

        threading.Thread(target=accept, daemon=True).start()
        return True

    def expired(self):
        with self.lock:
            return self.lost_at is not None and time.monotonic() - self.lost_at > self.grace

    def close(self):
        if self.listener is not None:
            self.listener.close()
            try:
                os.unlink(self.path)
            except OSError:
                pass


def terminal(run_dir, event, **fields):
    """The run's one terminal event, kept for a session attaching later."""
    if run_dir is not None:
        try:
            (run_dir / END_EVENT).write_text(json.dumps({"event": event, **fields}) + "\n", encoding="utf-8")
        except OSError:
            pass
    emit(event, **fields)


def absolute(value):
    return str(Path(value).expanduser().resolve()) if value else value


def run(spec_path):
    os.chdir(os.path.expanduser("~"))
    claim(Path(spec_path).resolve().parent)
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
        elif index and argv[index - 1] in ("-o", "-p", "--extra-docker-compose"):
            argv[index] = absolute(value)
    env = dict(os.environ)
    env.update(secret_env)
    # Harbor imports the agent from this node's own runtime.
    env["PYTHONPATH"] = str(Path(__file__).resolve().parents[4])
    env["PYTHONUNBUFFERED"] = "1"
    limit_path = Path(spec_path).resolve().parent / "concurrency"
    env[live_concurrency.FILE_ENV] = str(limit_path)
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
        forwarder = session.forwarder if session is not None else None
        return supervise(spec, argv, env, credential, stop, hung_up,
                         egress if spec.get("ghcr_mirror") else None, limit_path=limit_path,
                         run_dir=Path(spec_path).resolve().parent,
                         retarget=(lambda port: setattr(forwarder, "target", ("127.0.0.1", port)))
                         if forwarder is not None else None)
    finally:
        if session is not None:
            session.close()
        if relay:
            relay.__exit__(None, None, None)


def dataset_selection(argv):
    """(the `-p` dataset directory, the `-i` patterns) of a Harbor argv."""
    dataset = next((argv[i + 1] for i, a in enumerate(argv[:-1]) if a == "-p"), None)
    return dataset, [argv[i + 1] for i, a in enumerate(argv[:-1]) if a == "-i"]


def beating(phase, stop, work):
    """work() with a heartbeat every 2 s: preparation can outlast the
    worker's 90 s heartbeat window."""
    done = threading.Event()

    def beat():
        while not done.wait(2):
            emit("heartbeat", phase=phase)
    threading.Thread(target=beat, daemon=True).start()
    try:
        return work()
    finally:
        done.set()


def cancelled_exit(run_dir):
    terminal(run_dir, "exit", code=130, cancelled=True)
    return 130


def pump(source):
    """Copy Harbor's output to stderr, wherever that points now."""
    for chunk in iter(lambda: source.read1(65536), b""):
        try:
            os.write(2, chunk)
        except OSError:
            pass


def supervise(spec, argv, env, credential, stop, hung_up, egress=None, cwd=None, prepare=None, finish=None,
              limit_path=None, run_dir=None, retarget=None):
    """Run Harbor: control channel, heartbeats, cancel; the exit code.

    `prepare(stop)`, when given, runs first under heartbeats and with cancel
    already handled; it returns (argv, env, cwd), or None once `stop` is set,
    and raises ValueError with a user-facing reason. `finish()`, when given,
    runs under heartbeats before the run's one terminal event, however the
    run ends. With `run_dir`, sessions can attach (Control) and the run
    stops only when none is back within the spec's `detach_grace`;
    `retarget(port)` points the egress forwarder at a new session's tunnel."""

    def on_line(line):
        if line == b"cancel":
            stop.set()
            return
        if not line.startswith(b"{"):
            return
        try:
            message = json.loads(line)
            update = message.get("credential")
            concurrency = message.get("concurrency")
            port = message.get("tunnel_port")
        except (ValueError, AttributeError):
            return
        if type(port) is int and retarget is not None:
            retarget(port)
        if concurrency is not None:
            if type(concurrency) is int and limit_path is not None:
                try:
                    live_concurrency.write(limit_path, concurrency)
                except OSError:
                    pass
            return
        if update is not None and credential is not None:
            credential.set(update)
            emit("credential", pushes=credential.pushes)  # a count, never the token

    control = Control(run_dir, on_line, float(spec.get("detach_grace") or DETACH_GRACE))
    if run_dir is None:
        control.grace = 0  # nothing can attach: a closed channel stops the run
    elif not control.listen():
        terminal(run_dir, "error", message="执行机器上建不了重连用的 Unix socket（/tmp/metacodes-bench-<uid>/），"
                                           "评测没有启动；请检查 /tmp 是否可写、该目录是否属于当前用户且权限为 700")
        return 2

    def watch():
        while not control.expired():
            time.sleep(0.5)
        hung_up.set()
        stop.set()

    threading.Thread(target=control.follow, args=(sys.stdin.buffer, 0), daemon=True).start()
    threading.Thread(target=watch, daemon=True).start()
    try:
        return run_harbor(spec, argv, env, stop, hung_up, egress, cwd, prepare, finish, run_dir)
    finally:
        control.close()


def run_harbor(spec, argv, env, stop, hung_up, egress, cwd, prepare, finish, run_dir):

    def finishing():
        if finish is not None:
            try:
                beating("finish", stop, finish)
            except Exception as exc:  # the run's outcome is reported regardless
                print(f"清理失败：{type(exc).__name__}: {exc}", file=sys.stderr, flush=True)

    if prepare is not None:
        try:
            prepared = beating("prepare", stop, lambda: prepare(stop))
        except ValueError as exc:
            finishing()
            terminal(run_dir, "error", message=str(exc))
            return 2
        if prepared is None or stop.is_set():
            finishing()
            return cancelled_exit(run_dir)
        argv, env, cwd = prepared
    dataset, patterns = dataset_selection(argv)
    if egress is not None and dataset:
        images = egress.ghcr_images(Path(dataset), patterns)
        if images:
            tagged = beating("ghcr", stop, lambda: egress.ensure_ghcr(
                images, spec["ghcr_mirror"], env=env, stop=stop,
                log=lambda text: print(text, file=sys.stderr, flush=True)))
            emit("ghcr", images=len(images), tagged=len(tagged))
            if stop.is_set():  # cancelled (or no session came back) while pulling
                finishing()
                return cancelled_exit(run_dir)
    # Harbor's own output goes to stderr, which SSH carries to the local
    # worker's log; stdout carries only events.
    try:
        process = subprocess.Popen(argv, env=env, cwd=cwd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, start_new_session=True)
    except OSError as exc:
        finishing()
        terminal(run_dir, "error", message=f"启动失败：{exc}")
        return 2
    output = threading.Thread(target=pump, args=(process.stdout,), daemon=True)
    output.start()
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
            emit("heartbeat")
            last = time.monotonic()
        time.sleep(0.25)
    output.join(5)
    process.stdout.close()
    finishing()
    terminal(run_dir, "exit", code=process.returncode, cancelled=interrupted_at is not None)
    return process.returncode


def attach(spec_path):
    """Connect this session to the driver of the run `spec_path` names; once
    that run has ended, print its terminal event instead."""
    os.chdir(os.path.expanduser("~"))
    run_dir = Path(spec_path).resolve().parent
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        conn.connect(attach_socket(run_dir))
    except OSError:
        end = run_dir / END_EVENT
        if end.is_file():
            sys.stdout.write(end.read_text(encoding="utf-8"))
            sys.stdout.flush()
            return 0
        if driver_alive(run_dir):
            return 75  # still starting: no event, the workbench tries again
        emit("error", message="执行机器上这次运行的驱动进程已经不在了（机器重启，或进程被结束），结果只有已经写入作业目录的部分")
        return 3

    def forward():
        try:
            for chunk in iter(lambda: sys.stdin.buffer.read1(65536), b""):
                conn.sendall(chunk)
            conn.shutdown(socket.SHUT_WR)
        except OSError:
            pass

    threading.Thread(target=forward, daemon=True).start()
    try:
        for chunk in iter(lambda: conn.recv(65536), b""):
            sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()
    except OSError:
        pass
    return 0


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
    if len(args) != 2 or args[0] not in ("run", "attach", "manifest", "pack"):
        print("usage: remote.py run <spec> | attach <spec> | manifest <dir> | pack <dir> | egress-probe <json>",
              file=sys.stderr)
        return 2
    action, target = args
    if action == "run":
        return run(target)
    if action == "attach":
        return attach(target)
    if action == "manifest":
        print(json.dumps(files(target)))
        return 0
    return pack(target)


if __name__ == "__main__":
    sys.exit(main())
