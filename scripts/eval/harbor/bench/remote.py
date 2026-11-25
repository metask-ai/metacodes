"""Remote side of an SSH Bench executor. Runs on the Linux execution host,
inside that host's own `metacodes` (node.py):

    metacodes bench node run <spec.json>
    metacodes bench node attach <spec.json>
    metacodes bench node upgrade <spec.json | runs-dir>
    metacodes bench node manifest <job-dir>
    metacodes bench node pack <job-dir>   # JSON items on stdin

`run` reads one JSON line from stdin first,
`{"env": {NAME: value}, "credential": "<real token>"}`, carried by the SSH
channel instead of argv or a file. `env` goes to Harbor's environment: the
run's key variable there holds only the run-scoped placeholder the task
containers present. `credential` stays in this process: the credential relay
it starts beside this host's Docker daemon accepts the placeholder and
forwards with this real token. Harbor runs in its own process group under a
keeper process (KEEPER) that only records its exit status and output in the
run directory, and the driver prints JSON events on stdout (`started`,
`heartbeat` every 2 s, `exit`).
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
the run directory's DRIVER_PID tells `attach` the driver is still starting.
Only when no session is back within the spec's `detach_grace` seconds is
Harbor interrupted. The run's terminal event is also kept in the run
directory, so a session attaching after the end still receives it; with the
original session gone, the driver's output goes to DRIVER_LOG there.

`upgrade` (run by a newer node after an update) replaces the driver of a
running Harbor run without stopping it (Handoff): Harbor stays with its
keeper, the new driver serves the listening sockets the old one passes over
(relay, egress forwarder, attach, handoff), with the relay's TLS files from
the run directory, and the old one finishes what it had accepted. Its
session gets a `handoff` event and attaches again, now to the new driver. Runs started by a driver from before this, and WorkBuddy runs, keep
their driver to the end.

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
import shutil
import signal
import socket
import subprocess
import sys
import tarfile
import tempfile
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
HARBOR_PID = "harbor.pid"
HARBOR_EXIT = "harbor.exit"
HARBOR_LOG = "harbor.log"
RELAY_TLS = "relay-tls"
LIMIT_FILE = "concurrency"
# The handoff exchange between two drivers; a driver refuses any other.
HANDOFF = 1
HANDOFF_TIMEOUT = 30


EMIT_LOCK = threading.Lock()
OUT = None  # the attached session's writer; None while the first one lasts


def attach_socket(run_dir, suffix=".sock"):
    """The attach socket of the driver of `run_dir`: a bounded name in a
    directory only this user can enter. `suffix` names its other sockets."""
    root = Path(SOCKET_ROOT) / f"metacodes-bench-{os.getuid()}"
    try:
        root.mkdir(mode=0o700)
    except FileExistsError:
        pass
    info = os.lstat(root)
    if not os.path.isdir(root) or os.path.islink(root) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise OSError(f"{root} 不是当前用户私有的目录")
    digest = hashlib.sha256(str(Path(run_dir).resolve()).encode()).hexdigest()[:24]
    return str(root / (digest + suffix))


def handoff_socket(run_dir):
    return attach_socket(run_dir, ".handoff.sock")


def unix_listener(path):
    """A listening Unix socket at `path` (replacing a stale one), owner only."""
    previous = os.umask(0o077)
    try:
        if os.path.lexists(path):
            os.unlink(path)
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            listener.bind(path)
            listener.listen(4)
        except OSError:
            listener.close()
            raise
        return listener
    finally:
        os.umask(previous)


def close_listener(listener, path):
    listener.close()
    try:
        os.unlink(path)
    except OSError:
        pass


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


class Acceptor:
    """Accepts on a listening socket that another driver may come to serve
    (Handoff): polled, so pause() needs neither close() nor shutdown()."""

    def __init__(self, listener, handle):
        listener.settimeout(0.5)
        self.listener, self.handle = listener, handle
        self.running = threading.Event()
        self.thread = None

    def start(self):
        self.running.set()
        self.thread = threading.Thread(target=self.loop, daemon=True)
        self.thread.start()

    def loop(self):
        while self.running.is_set() and self.thread is threading.current_thread():
            try:
                conn, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            if not self.running.is_set():  # accepted just as the socket was handed over
                conn.close()
                return
            self.handle(conn)

    def pause(self):
        self.running.clear()
        if self.thread is not None and self.thread is not threading.current_thread():
            self.thread.join()


class Control:
    """The run's control channel: the session that started it, then each
    session that attaches. `lost_at` is when the current one closed."""

    def __init__(self, run_dir, on_line, grace):
        self.run_dir, self.on_line, self.grace = run_dir, on_line, grace
        self.lock = threading.Lock()
        self.current = 0
        self.lost_at = None
        self.quiet = False
        self.acceptor = None
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
        gone, so the driver never writes into a dead channel."""
        if self.quiet or self.run_dir is None:
            return
        self.quiet = True
        fd = os.open(str(self.run_dir / DRIVER_LOG), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        os.dup2(fd, 1)
        os.dup2(fd, 2)
        os.close(fd)

    def listen(self):
        """Accept attaching sessions; False when the socket cannot be bound."""
        try:
            listener = unix_listener(attach_socket(self.run_dir))
        except OSError:
            return False
        self.adopt(listener)
        self.resume()
        return True

    def adopt(self, listener):
        """Serve `listener` (the attach socket) from resume() on."""
        self.path = attach_socket(self.run_dir)
        self.acceptor = Acceptor(listener, self.attached)

    def attached(self, conn):
        global OUT
        with self.lock:
            self.current += 1
            generation = self.current
            self.lost_at = None
            self.silence()
            with EMIT_LOCK:
                OUT = conn.makefile("w", encoding="utf-8")
        threading.Thread(target=self.follow, args=(conn.makefile("rb"), generation), daemon=True).start()

    def resume(self):
        self.acceptor.start()

    def pause(self):
        if self.acceptor is not None:
            self.acceptor.pause()

    def expired(self):
        with self.lock:
            return self.lost_at is not None and time.monotonic() - self.lost_at > self.grace

    def release(self):
        """Close this process's copy of the attach socket, which a newer
        driver now serves: its path stays."""
        if self.acceptor is not None:
            self.acceptor.pause()
            self.acceptor.listener.close()
            self.acceptor = None

    def close(self):
        if self.acceptor is not None:
            self.acceptor.pause()
            close_listener(self.acceptor.listener, self.path)
            self.acceptor = None


def terminal(run_dir, event, **fields):
    """The run's one terminal event, kept for a session attaching later."""
    if run_dir is not None:
        try:
            (run_dir / END_EVENT).write_text(json.dumps({"event": event, **fields}) + "\n", encoding="utf-8")
        except OSError:
            pass
    emit(event, **fields)


# Started by the driver, never replaced: starts Harbor in its own process
# group, its output to HARBOR_LOG, and writes HARBOR_PID, then HARBOR_EXIT.
KEEPER = r"""
import json, os, subprocess, sys
directory, argv = sys.argv[1], sys.argv[2:]
def put(name, value):
    path = os.path.join(directory, name)
    with open(path + ".tmp", "w") as out:
        out.write(value)
    os.replace(path + ".tmp", path)
with open(os.path.join(directory, "harbor.log"), "ab") as log:
    try:
        child = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                                 start_new_session=True)
    except OSError as exc:
        put("harbor.exit", json.dumps({"error": str(exc)}))
        sys.exit(1)
    put("harbor.pid", str(child.pid))
    put("harbor.exit", json.dumps({"code": child.wait()}))
"""


class Harbor:
    """Harbor under its keeper (KEEPER), which outlives the driver that
    started it, so a newer driver can take the run over (Handoff) and still
    learn Harbor's exit status from `directory`. `offset` is how much of
    HARBOR_LOG this driver's session has been given."""

    def __init__(self, directory, keeper, pid, offset=0, process=None):
        self.directory, self.keeper, self.pid, self.offset = Path(directory), keeper, pid, offset
        self.process = process  # the keeper, when this driver started it
        self.ended = threading.Event()
        self.detached = False  # handed over: the new driver copies the output

    @classmethod
    def start(cls, argv, env, cwd, directory):
        """Raises ValueError with the reason Harbor did not start."""
        directory = Path(directory)
        for name in (HARBOR_PID, HARBOR_EXIT):
            try:
                (directory / name).unlink()
            except FileNotFoundError:
                pass
        log = directory / HARBOR_LOG
        offset = log.stat().st_size if log.exists() else 0
        try:
            keeper = subprocess.Popen([sys.executable, "-c", KEEPER, str(directory)] + list(argv), env=env, cwd=cwd,
                                      stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                      start_new_session=True)
        except OSError as exc:
            raise ValueError(f"启动失败：{exc}") from None
        harbor = cls(directory, keeper.pid, None, offset, keeper)
        while harbor.pid is None:
            try:
                harbor.pid = int((directory / HARBOR_PID).read_text(encoding="ascii"))
            except (OSError, ValueError):
                ended = harbor.result()
                if ended is not None:
                    raise ValueError("启动失败：" + str(ended.get("error") or f"退出码 {ended.get('code')}")) from None
                time.sleep(0.05)
        return harbor

    def alive(self):
        if self.process is not None:
            return self.process.poll() is None
        try:
            os.kill(self.keeper, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            pass
        return True

    def result(self):
        """None while Harbor runs, then {"code": n} or {"error": reason}."""
        for _ in range(2):  # the keeper writes the file just before it exits
            try:
                return json.loads((self.directory / HARBOR_EXIT).read_text(encoding="utf-8"))
            except (OSError, ValueError):
                if self.alive():
                    return None
        return {"error": "执行机器上 Harbor 的看护进程意外退出，没有留下 Harbor 的退出码"}

    def signal(self, number):
        try:
            os.killpg(self.pid, number)
        except OSError:
            pass

    def pump(self, quiet):
        """Copy Harbor's output to stderr, wherever that points now, unless
        `quiet()` or handed over, until Harbor ended."""
        with open(self.directory / HARBOR_LOG, "rb") as source:
            source.seek(self.offset)
            last = False
            while True:
                chunk = source.read(65536)
                if chunk:
                    self.offset += len(chunk)
                    if not quiet() and not self.detached:
                        try:
                            os.write(2, chunk)
                        except OSError:
                            pass
                    continue
                if last:
                    return
                last = self.ended.is_set()
                if not last:
                    time.sleep(0.2)


class Handoff:
    """Hands a running run to a newer driver (`upgrade`, run by a newer
    node) on the run's handoff socket, without stopping Harbor or a model
    request. The new driver asks with {"handoff": HANDOFF}; this one answers
    with the run's state and passes the listening sockets it serves (relay,
    egress forwarder, attach, handoff; SCM_RIGHTS), so nothing is bound
    again; the new one answers {"ready": true} once it can serve them all;
    this one stops accepting, says {"released": true, "target": <the
    forwarder's target now>} and tells its session
    (`handoff` event) to attach again. Until then any failure leaves this
    driver running the run as before. Afterwards it finishes the requests it
    had accepted, and keeps its session's egress tunnel until the new driver
    reports its own ({"tunnel": true} on the same connection)."""

    def __init__(self, run_dir, relay=None, forwarder=None, docker_config=None, credential=None,
                 judge_credential=None, listener=None):
        self.run_dir = run_dir
        self.relay, self.forwarder, self.docker_config = relay, forwarder, docker_config
        self.credential, self.judge_credential = credential, judge_credential
        self.lock = threading.Lock()
        self.done = threading.Event()
        self.closed = False
        self.acceptor = Acceptor(listener, self.serve) if listener is not None else None
        self.successor = None
        self.harbor = self.control = None

    def offer(self, harbor, control):
        self.harbor, self.control = harbor, control
        if self.acceptor is None:
            try:
                self.acceptor = Acceptor(unix_listener(handoff_socket(self.run_dir)), self.serve)
            except OSError:
                print("执行机器上建不了驱动热更新用的 Unix socket，这次运行不能热更新", file=sys.stderr, flush=True)
                return
        self.acceptor.start()

    def close(self):
        if self.acceptor is not None:
            self.acceptor.pause()
            close_listener(self.acceptor.listener, handoff_socket(self.run_dir))
            self.acceptor = None

    def keep(self, running):
        """The supervising loop's check: False once the run was handed
        over. `running` False (Harbor ended, or the run is being stopped)
        withdraws the offer for good."""
        with self.lock:
            if self.done.is_set():
                return False
            if not running:
                self.closed = True
            return True

    def sockets(self):
        named = [("relay", self.relay and self.relay.server.socket),
                 ("forwarder", self.forwarder and self.forwarder.sock),
                 ("attach", self.control.acceptor and self.control.acceptor.listener),
                 ("handoff", self.acceptor.listener)]
        return [(name, sock) for name, sock in named if sock is not None]

    def state(self, names):
        lost = self.control.lost_at
        return {"handoff": HANDOFF, "sockets": names, "keeper": self.harbor.keeper, "harbor": self.harbor.pid,
                "log_offset": self.harbor.offset, "lost_for": None if lost is None else time.monotonic() - lost,
                "credential": self.credential.current() if self.credential is not None else None,
                "judge_credential": self.judge_credential, "docker_config": self.docker_config,
                "relay": None if self.relay is None else {
                    "token": self.relay.token, "judge_token": self.relay.judge_token,
                    "sequence": self.relay.sequence},
                "forwarder": None if self.forwarder is None else {"target": list(self.forwarder.target)}}

    def serve(self, conn):
        try:
            kept = self.exchange(conn)
        except (OSError, ValueError):
            kept = False
        if not kept:
            conn.close()

    def exchange(self, conn):
        """True once the run is handed over; `conn` then stays open for the
        new driver's tunnel report."""
        conn.settimeout(HANDOFF_TIMEOUT)
        reader = conn.makefile("rb")
        request = json.loads(reader.readline() or b"null")
        with self.lock:
            if not isinstance(request, dict) or request.get("handoff") != HANDOFF:
                refusal = "新旧驱动的热更新协议不同"
            elif self.closed:
                refusal = "这次运行正在结束"
            else:
                refusal = None
        if refusal:
            conn.sendall(json.dumps({"refused": refusal}, ensure_ascii=False).encode() + b"\n")
            return False
        sockets = self.sockets()
        socket.send_fds(conn, [json.dumps(self.state([name for name, _ in sockets])).encode() + b"\n"],
                        [sock.fileno() for _, sock in sockets])
        if json.loads(reader.readline() or b"null") != {"ready": True}:
            return False
        with self.lock:
            if self.closed:
                conn.sendall(json.dumps({"refused": "这次运行正在结束"}, ensure_ascii=False).encode() + b"\n")
                return False
            self.pause()
            try:
                target = list(self.forwarder.target) if self.forwarder is not None else None
                conn.sendall(json.dumps({"released": True, "target": target}).encode() + b"\n")
            except OSError:
                self.restore()
                return False
            # Before `done`: the supervising loop then ends, and must find no
            # socket of its own left to close (and unlink).
            self.successor = conn
            self.control.release()
            self.acceptor.listener.close()
            self.acceptor = None
            self.done.set()
        emit("handoff")
        return True

    def pause(self):
        if self.relay is not None:
            self.relay.pause()
        if self.forwarder is not None:
            self.forwarder.pause()
        self.control.pause()
        self.acceptor.pause()
        self.harbor.detached = True

    def restore(self):
        if self.relay is not None:
            self.relay.resume()
        if self.forwarder is not None:
            self.forwarder.start()
        self.control.resume()
        self.acceptor.start()
        self.harbor.detached = False

    def retarget(self, port, then=None):
        """Point the forwarder at a session's tunnel; then `then()` unless
        the run was handed over. Under the handoff's lock, so `released`
        carries the target that is current when the new driver starts."""
        with self.lock:
            self.forwarder.target = ("127.0.0.1", port)
            if then is not None and not self.done.is_set():
                then()

    def wait_successor(self, timeout):
        """Until the new driver has its own egress tunnel, or `timeout`."""
        if self.successor is None:
            return
        try:
            self.successor.settimeout(timeout)
            self.successor.makefile("rb").readline()
        except OSError:
            pass
        self.successor.close()


class Predecessor:
    """The new driver's side of the connection Handoff keeps open: reports
    its own egress tunnel (the first `tunnel_port` a session brings, unless
    the run went on to a newer driver first; then at this driver's end,
    once that one reported), after which the old driver may end and with it
    the old session's tunnel."""

    def __init__(self):
        self.conn = None
        self.lock = threading.Lock()

    def report(self):
        with self.lock:
            if self.conn is None:
                return
            try:
                self.conn.sendall(b'{"tunnel": true}\n')
            except OSError:
                pass
            self.conn.close()
            self.conn = None


def wind_down(handoff, relay, forwarder, docker_config):
    """The driver's end. Handed over: finish only what this process
    accepted, keeping the egress tunnel until the newer driver has one (its
    report arrives once a session brought one, through every later
    handoff), and leave the run's relay, forwarder and DOCKER_CONFIG to it.
    Otherwise remove them."""
    if handoff is not None and handoff.done.is_set():
        if relay is not None:
            relay.release()
        if forwarder is not None:
            handoff.wait_successor(handoff.control.grace)
            forwarder.release(lambda: (handoff.run_dir / END_EVENT).exists())
        return
    if handoff is not None:
        handoff.close()
    if forwarder is not None:
        forwarder.close()
    if docker_config:
        shutil.rmtree(docker_config, ignore_errors=True)
    if relay is not None:
        relay.__exit__(None, None, None)


def absolute(value):
    return str(Path(value).expanduser().resolve()) if value else value


def run(spec_path):
    os.chdir(os.path.expanduser("~"))
    run_dir = Path(spec_path).resolve().parent
    claim(run_dir)
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
    env["TZ"] = "UTC"
    limit_path = run_dir / LIMIT_FILE
    env[live_concurrency.FILE_ENV] = str(limit_path)
    relay = None
    credential = None
    forwarder = None
    docker_config = None
    handoff = None
    stop = threading.Event()
    hung_up = threading.Event()
    try:
        if spec.get("relay"):
            from scripts.eval.harbor.profiling import JUDGE_TOKEN_ENV, judge_argv
            options = spec["relay"]
            if options.get("refuse_local_upstream"):
                from scripts.eval.harbor.bench.egress import names_this_machine
                if names_this_machine(urlsplit(options["upstream"]).hostname or ""):
                    # This machine resolves the imported address to itself:
                    # never send the key to whatever listens here.
                    emit("error", message="导入的 Provider 地址在执行机器上解析为本机（回环地址），已拒绝连接；"
                                          "请改用两台机器都能访问到同一网关的地址")
                    return 2
            token = secret_env[spec["key_env"]]
            judge = options.get("judge")
            # The verifier's judge: its own placeholder (in Harbor's env from
            # the stdin line), the run's pushed token unless a fixed key came.
            judge_token = secret_env.get(JUDGE_TOKEN_ENV) if judge else None
            if judge and not judge_token:
                emit("error", message="missing judge placeholder")
                return 2
            relay = start_relay(options, run_dir, real or token, token, judge_token, judge_real)
            credential = relay.credential
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
            session = egress.Session(spec["egress"], run_dir, [relay_host] + services, env=env)
            forwarder, docker_config = session.forwarder, str(session.directory)
            env["DOCKER_CONFIG"] = docker_config
            emit("egress", mode=spec["egress"]["mode"], proxy=session.proxy_url, no_proxy=session.no_proxy)
        handoff = Handoff(run_dir, relay, forwarder, docker_config, credential, judge_real)
        code = supervise(spec, argv, env, credential, stop, hung_up,
                         egress if spec.get("ghcr_mirror") else None, limit_path=limit_path,
                         run_dir=run_dir, retarget=handoff.retarget if forwarder is not None else None,
                         handoff=handoff)
        return 0 if code is None else code
    finally:
        wind_down(handoff, relay, forwarder, docker_config)


def start_relay(options, run_dir, credential, token, judge_token, judge_credential, listener=None, sequence=0):
    """The run's credential relay, its TLS files in the run directory so a
    newer driver serves with the same CA (`listener`: the one it took over)."""
    from scripts.eval.harbor.profiling import PushedCredential, TimingRelay
    connect = None
    if options.get("refuse_local_upstream"):
        from scripts.eval.harbor.bench.egress import connect_not_local
        connect = connect_not_local
    relay = TimingRelay(options["upstream"], PushedCredential(credential), absolute(options["metrics_dir"]),
                        bind=options.get("bind") or "172.17.0.1", auth_header=options["auth_header"],
                        auth_prefix=options["auth_prefix"], tls=True, token=token,
                        record=options.get("record", True), judge_token=judge_token,
                        judge_credential=judge_credential, connect=connect, cert_dir=run_dir / RELAY_TLS,
                        listener=listener, sequence=sequence)
    return relay if listener is not None else relay.__enter__()


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


def control_lines(stop, credential, limit_path, retarget):
    """The handler of the control lines a session sends."""

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

    return on_line


def watch_sessions(control, stop, hung_up):
    """Stop the run once no session is back within the grace period."""

    def watch():
        while not control.expired():
            time.sleep(0.5)
        hung_up.set()
        stop.set()

    threading.Thread(target=watch, daemon=True).start()


def supervise(spec, argv, env, credential, stop, hung_up, egress=None, cwd=None, prepare=None, finish=None,
              limit_path=None, run_dir=None, retarget=None, handoff=None):
    """Run Harbor: control channel, heartbeats, cancel; the exit code, or
    None once `handoff` gave the run to a newer driver.

    `prepare(stop)`, when given, runs first under heartbeats and with cancel
    already handled; it returns (argv, env, cwd), or None once `stop` is set,
    and raises ValueError with a user-facing reason. `finish()`, when given,
    runs under heartbeats before the run's one terminal event, however the
    run ends. With `run_dir`, sessions can attach (Control) and the run
    stops only when none is back within the spec's `detach_grace`;
    `retarget(port)` points the egress forwarder at a new session's tunnel."""
    control = Control(run_dir, control_lines(stop, credential, limit_path, retarget),
                      float(spec.get("detach_grace") or DETACH_GRACE))
    if run_dir is None:
        control.grace = 0  # nothing can attach: a closed channel stops the run
    elif not control.listen():
        terminal(run_dir, "error", message="执行机器上建不了重连用的 Unix socket（/tmp/metacodes-bench-<uid>/），"
                                           "评测没有启动；请检查 /tmp 是否可写、该目录是否属于当前用户且权限为 700")
        return 2
    threading.Thread(target=control.follow, args=(sys.stdin.buffer, 0), daemon=True).start()
    watch_sessions(control, stop, hung_up)
    try:
        return run_harbor(spec, argv, env, stop, hung_up, egress, cwd, prepare, finish, run_dir, control, handoff)
    finally:
        control.close()


def run_harbor(spec, argv, env, stop, hung_up, egress, cwd, prepare, finish, run_dir, control, handoff):

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
    directory = run_dir or Path(tempfile.mkdtemp(prefix="metacodes-bench-harbor-"))
    try:
        try:
            harbor = Harbor.start(argv, env, cwd, directory)
        except ValueError as exc:
            finishing()
            terminal(run_dir, "error", message=str(exc))
            return 2
        emit("started", pid=harbor.pid)
        return follow(harbor, stop, hung_up, run_dir, control, handoff, finishing, spec.get("worker_results"))
    finally:
        if run_dir is None:
            shutil.rmtree(directory, ignore_errors=True)


def follow(harbor, stop, hung_up, run_dir, control, handoff, finishing, worker_results=False):
    """Supervise a started Harbor until it ends (the run's terminal event
    and exit code), or until `handoff` gave the run to a newer driver
    (None). Harbor's output reaches the session meanwhile (pump)."""
    output = threading.Thread(target=harbor.pump, args=(lambda: worker_results or control.quiet,), daemon=True)
    output.start()
    if handoff is not None:
        handoff.offer(harbor, control)
    interrupted_at = None
    last = 0.0
    while True:
        ended = harbor.result()
        if handoff is not None and not handoff.keep(ended is None and not stop.is_set()):
            return None
        if ended is not None:
            break
        if stop.is_set() and interrupted_at is None:
            interrupted_at = time.monotonic()
            emit("cancelling", hung_up=hung_up.is_set())
            harbor.signal(signal.SIGINT)
        if interrupted_at and time.monotonic() - interrupted_at > 20:
            harbor.signal(signal.SIGKILL)
        if time.monotonic() - last > 2:
            emit("heartbeat")
            last = time.monotonic()
        time.sleep(0.25)
    harbor.ended.set()
    output.join(5)
    finishing()
    if "code" not in ended:
        terminal(run_dir, "error", message=str(ended.get("error")))
        return 2
    terminal(run_dir, "exit", code=ended["code"], cancelled=interrupted_at is not None)
    return ended["code"]


def take_over(spec_path, report):
    """The newer driver's side of Handoff: take the run of `spec_path` over
    from its driver, then supervise it to the end. `report(outcome)` is
    called once, as soon as the outcome of the takeover is known: only once
    this driver serves every socket of the run."""
    run_dir = Path(spec_path).resolve().parent
    spec = json.loads(Path(spec_path).read_text(encoding="utf-8"))
    grace = float(spec.get("detach_grace") or DETACH_GRACE)
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    conn.settimeout(HANDOFF_TIMEOUT)
    sockets = {}
    try:
        conn.connect(handoff_socket(run_dir))
        conn.sendall(json.dumps({"handoff": HANDOFF}).encode() + b"\n")
        data, fds, _flags, _address = socket.recv_fds(conn, 65536, 4)
        received = [socket.socket(fileno=fd) for fd in fds]
        reader = conn.makefile("rb")
        if not data.endswith(b"\n"):
            data += reader.readline()
        state = json.loads(data)
        if "refused" in state:
            for sock in received:
                sock.close()
            conn.close()
            report({"result": "refused", "message": state["refused"]})
            return 1
        sockets = dict(zip(state["sockets"], received))
        relay = forwarder = None
        if state.get("relay"):
            given = state["relay"]
            relay = start_relay(spec["relay"], run_dir, state["credential"], given["token"], given.get("judge_token"),
                                state.get("judge_credential"), listener=sockets["relay"], sequence=given["sequence"])
        if state.get("forwarder"):
            from scripts.eval.harbor.bench.egress import Forwarder
            forwarder = Forwarder("", tuple(state["forwarder"]["target"]), sock=sockets["forwarder"])
        credential = relay.credential if relay is not None else None
        stop, hung_up = threading.Event(), threading.Event()
        predecessor = Predecessor()
        handoff = Handoff(run_dir, relay, forwarder, state.get("docker_config"), credential,
                          state.get("judge_credential"), listener=sockets["handoff"])
        retarget = (lambda port: handoff.retarget(port, predecessor.report)) if forwarder is not None else None
        control = Control(run_dir, control_lines(stop, credential, run_dir / LIMIT_FILE, retarget), grace)
        control.adopt(sockets["attach"])
        conn.sendall(b'{"ready": true}\n')
        released = json.loads(reader.readline() or b"null")
        if not isinstance(released, dict) or released.get("released") is not True:
            raise ValueError("原驱动没有交出这次运行")
        if forwarder is not None:
            # A session may have brought the old driver a tunnel meanwhile.
            forwarder.target = tuple(released["target"])
    except (OSError, ValueError, KeyError, TypeError) as exc:
        for sock in sockets.values():
            sock.close()  # this process's copies only; the old driver keeps serving
        conn.close()
        report({"result": "failed", "message": f"{type(exc).__name__}: {exc}"})
        return 1
    predecessor.conn = conn
    if forwarder is None:
        predecessor.report()
    if relay is not None:
        relay.resume()
    if forwarder is not None:
        forwarder.start()
    control.quiet = True  # this process writes to DRIVER_LOG until a session attaches
    control.lost_at = time.monotonic() - (state.get("lost_for") or 0)
    control.resume()
    claim(run_dir)
    report({"result": "upgraded", "pid": os.getpid()})
    print(f"驱动 {os.getpid()} 接管了这次运行", file=sys.stderr, flush=True)
    harbor = Harbor(run_dir, state["keeper"], state["harbor"], state["log_offset"])
    try:
        watch_sessions(control, stop, hung_up)
        code = follow(harbor, stop, hung_up, run_dir, control, handoff, lambda: None, spec.get("worker_results"))
        return 0 if code is None else code
    finally:
        control.close()
        wind_down(handoff, relay, forwarder, state.get("docker_config"))
        predecessor.report()  # handed over: only once the successor had its tunnel


def upgrade(target):
    """`upgrade <spec.json | runs directory>`: hand each running run there
    to a driver of this node's version. One JSON line per run: `upgraded`,
    `refused` or `failed` (the run's driver goes on), `unsupported` (a
    driver from before hot upgrade: it finishes the run itself), and, for a
    named spec only, `ended` or `gone`."""
    os.chdir(os.path.expanduser("~"))
    path = Path(target)
    named = path.is_file()
    failed = False
    for spec_path in [path] if named else sorted(path.glob("*/spec.json")):
        outcome = upgrade_run(spec_path)
        if outcome["result"] in ("ended", "gone") and not named:
            continue
        failed = failed or outcome["result"] == "failed"
        print(json.dumps({"run": spec_path.parent.name, **outcome}, ensure_ascii=False), flush=True)
    return 1 if failed else 0


def upgrade_run(spec_path):
    """Start this version's driver for one run, detached from this session;
    its first report on the takeover is the outcome."""
    run_dir = spec_path.resolve().parent
    if (run_dir / END_EVENT).exists():
        return {"result": "ended"}
    if not os.path.exists(handoff_socket(run_dir)):
        return {"result": "unsupported" if driver_alive(run_dir) else "gone"}
    sys.stdout.flush()
    sys.stderr.flush()
    readable, writable = os.pipe()
    if os.fork() == 0:
        os.close(readable)
        os.setsid()
        null = os.open(os.devnull, os.O_RDONLY)
        os.dup2(null, 0)
        log = os.open(str(run_dir / DRIVER_LOG), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        os.dup2(log, 1)
        os.dup2(log, 2)
        reported = []

        def report(outcome):
            if not reported:
                reported.append(outcome)
                os.write(writable, json.dumps(outcome, ensure_ascii=False).encode() + b"\n")
                os.close(writable)

        code = 1
        try:
            code = take_over(str(spec_path), report)
        except BaseException as exc:
            report({"result": "failed", "message": f"{type(exc).__name__}: {exc}"})
            import traceback
            traceback.print_exc()
        finally:
            sys.stdout.flush()
            sys.stderr.flush()
            os._exit(code)
    os.close(writable)
    with os.fdopen(readable, "rb") as reader:
        line = reader.readline()
    try:
        return json.loads(line)
    except ValueError:
        return {"result": "failed", "message": "新驱动没有回报就退出了"}


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
    if len(args) != 2 or args[0] not in ("run", "attach", "upgrade", "manifest", "pack"):
        print("usage: remote.py run <spec> | attach <spec> | upgrade <spec|runs-dir> | manifest <dir> | pack <dir> | "
              "egress-probe <json>", file=sys.stderr)
        return 2
    action, target = args
    if action == "run":
        return run(target)
    if action == "attach":
        return attach(target)
    if action == "upgrade":
        return upgrade(target)
    if action == "manifest":
        print(json.dumps(files(target)))
        return 0
    return pack(target)


if __name__ == "__main__":
    sys.exit(main())
