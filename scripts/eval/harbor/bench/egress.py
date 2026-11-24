"""Container egress for SSH executors, and ghcr.io mirror pulls.

An SSH executor whose network cannot reach PyPI, GitHub or a CDN can borrow
the workbench machine's network for its task containers
(`"egress": "workbench"` on the executor):

    container --HTTP(S)_PROXY--> Forwarder (remote, docker0 gateway only)
              --> 127.0.0.1:<tunnel> (remote loopback, `ssh -R`)
              --> EgressProxy (workbench, 127.0.0.1:<ephemeral>) --> internet

- `EgressProxy` runs inside the local worker for one run: an HTTP proxy that
  serves CONNECT (to the allowed ports, 443/80 by default) and absolute-form
  plain HTTP requests, and refuses every destination that is not a public
  (globally routable) address of the workbench machine's network: loopback,
  private, link-local, CGNAT, multicast and reserved ranges are refused, with
  no exception, so a container can never reach the workbench machine's own
  services or its LAN. A name is resolved once and the vetted address is the
  one connected to (no second lookup to rebind).
- `Forwarder` runs inside the remote driver for the duration of the run: it
  listens only on the remote Docker bridge's gateway address (containers
  cannot reach the host's loopback, and sshd's GatewayPorts stays untouched)
  and relays to the tunnel's loopback end.
- The containers learn the proxy from a run-scoped Docker CLI configuration
  directory (`DOCKER_CONFIG`) that holds only `proxies` (and the default
  plugin directory): the docker CLI injects HTTP(S)_PROXY/NO_PROXY into every
  container and build it creates for that run. The user's own
  `~/.docker/config.json` is never read or changed.

`"egress": {"proxy": "http://host:port"}` uses a site proxy the containers
can reach instead (same DOCKER_CONFIG injection, no tunnel).

Python 3.9, stdlib only: the remote driver imports this module.
"""
from __future__ import annotations

import ipaddress
import json
import re
import shutil
import socket
import struct
import subprocess
import tempfile
import threading
from fnmatch import fnmatch
from pathlib import Path
from typing import Callable, Dict, Iterable, List, Optional, Sequence, Tuple
from urllib.parse import urlsplit

DEFAULT_PORTS = (443, 80)
PROBE_PATH = "/metacodes-bench-egress-probe"
PROBE_BODY = b"metacodes-bench-egress-ok"
HEAD_LIMIT = 64 * 1024
# Hop-by-hop headers a forwarding proxy must not pass on (RFC 9110 7.6.1),
# plus the proxy's own credentials header.
HOP_HEADERS = {"connection", "keep-alive", "proxy-connection", "proxy-authorization", "proxy-authenticate",
               "te", "trailer", "transfer-encoding", "upgrade"}
BASE_NO_PROXY = ("localhost", "127.0.0.1", "::1")


# ------------------------------------------------------------------ plumbing

def pipe(left: socket.socket, right: socket.socket) -> None:
    """Copy bytes both ways until both directions ended; closes both."""
    def one_way(source, target):
        try:
            while True:
                chunk = source.recv(65536)
                if not chunk:
                    break
                target.sendall(chunk)
        except OSError:
            pass
        try:
            target.shutdown(socket.SHUT_WR)
        except OSError:
            pass

    other = threading.Thread(target=one_way, args=(right, left), daemon=True)
    other.start()
    one_way(left, right)
    other.join()
    for sock in (left, right):
        try:
            sock.close()
        except OSError:
            pass


def stop_listening(sock: socket.socket) -> None:
    try:
        sock.shutdown(socket.SHUT_RDWR)
    except OSError:
        pass
    try:
        sock.close()
    except OSError:
        pass


class _Listener:
    """A TCP listener that hands each connection to `handle` on a thread.
    `sock` is a listening socket to serve instead of binding a new one."""

    def __init__(self, bind: str, port: int = 0, sock: Optional[socket.socket] = None):
        if sock is None:
            family = socket.AF_INET6 if ":" in bind else socket.AF_INET
            sock = socket.socket(family, socket.SOCK_STREAM)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.bind((bind, port))
            sock.listen(64)
        self.sock = sock
        # Polled, so pause() returns without shutting the socket down: another
        # process may be serving it.
        self.sock.settimeout(0.5)
        self.address = self.sock.getsockname()[:2]
        self.closed = threading.Event()
        self.thread = None
        self.connections = threading.Condition()
        self.open = set()

    def start(self):
        self.closed.clear()
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()
        return self

    def _serve(self):
        while not self.closed.is_set():
            try:
                conn, _ = self.sock.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            with self.connections:
                self.open.add(conn)
            threading.Thread(target=self._guarded, args=(conn,), daemon=True).start()

    def _guarded(self, conn):
        try:
            self.handle(conn)
        except Exception:  # one bad connection never stops the listener
            try:
                conn.close()
            except OSError:
                pass
        finally:
            with self.connections:
                self.open.discard(conn)
                self.connections.notify_all()

    def pause(self):
        """Stop accepting; the listening socket stays open."""
        self.closed.set()
        if self.thread is not None:
            self.thread.join()

    def release(self, over: Callable[[], bool]):
        """Once another process serves the listening socket: wait until
        every connection accepted here ended, or until `over()`, then close
        this copy of the socket. A silent connection may be waiting for a
        response, so silence does not end it."""
        self.pause()
        with self.connections:
            while self.open and not over():
                self.connections.wait(1.0)
        self.sock.close()

    def handle(self, conn):  # pragma: no cover - overridden
        conn.close()

    def close(self):
        self.closed.set()
        stop_listening(self.sock)

    def __enter__(self):
        return self.start()

    def __exit__(self, *_exc):
        self.close()


# ------------------------------------------------------------------ workbench proxy

# A fake-IP resolver (Clash/Surge-style transparent proxies, common on cloud
# Macs) answers every public name with an address in the benchmarking range
# 198.18.0.0/15 and forwards the connection itself. Allowed by default: no
# ordinary internal host uses that range. `egress_allow` overrides it.
DEFAULT_ALLOW_NETWORKS = ("198.18.0.0/15",)


def _parse(address: str):
    try:
        ip = ipaddress.ip_address(address.split("%", 1)[0])
    except ValueError:
        return None
    if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped is not None:
        ip = ip.ipv4_mapped
    return ip


def local_address(address: str) -> bool:
    """Whether `address` (IPv4-mapped IPv6 normalized) is a loopback or
    unspecified address: the machine that connects to it, whichever that is."""
    ip = _parse(address)
    return ip is not None and (ip.is_loopback or ip.is_unspecified)


def names_this_machine(host: str, resolve=None) -> bool:
    """Whether connecting to `host` from here reaches this machine: a
    localhost name, a loopback/unspecified literal, or a name that resolves
    to one (an /etc/hosts alias). An unresolvable name is not local here."""
    host = (host or "").lower().rstrip(".")
    if host == "localhost" or host.endswith(".localhost"):
        return True
    if _parse(host) is not None:
        return local_address(host)
    try:
        infos = (resolve or socket.getaddrinfo)(host, None)
    except (OSError, UnicodeError):
        return False
    return any(local_address(str(info[4][0])) for info in infos)


class LocalUpstream(OSError):
    pass


def connect_not_local(address: Tuple[str, int], timeout: Optional[float] = None,
                      source_address: Optional[Tuple[str, int]] = None, resolve=None) -> socket.socket:
    host, port = address
    try:
        infos = (resolve or socket.getaddrinfo)(host, port, 0, socket.SOCK_STREAM)
    except (OSError, UnicodeError) as exc:
        raise LocalUpstream(f"cannot resolve {host}") from exc
    if not infos or any(local_address(str(info[4][0])) for info in infos):
        raise LocalUpstream(f"{host} resolves to this machine")
    error: OSError = LocalUpstream(f"cannot connect to {host}")
    for family, kind, proto, _name, sockaddr in infos:
        sock = None
        try:
            sock = socket.socket(family, kind, proto)
            sock.settimeout(timeout)
            if source_address:
                sock.bind(source_address)
            sock.connect(sockaddr)
            return sock
        except OSError as exc:
            if sock is not None:
                sock.close()
            error = exc
    raise error


def address_allowed(address: str) -> bool:
    """Whether the proxy may connect to `address`: globally routable unicast
    only (see allow_policy for the configured exceptions)."""
    ip = _parse(address)
    if ip is None:
        return False
    return bool(ip.is_global and not (ip.is_loopback or ip.is_private or ip.is_link_local or ip.is_multicast
                                      or ip.is_reserved or ip.is_unspecified))


def allow_policy(networks: Sequence[str] = DEFAULT_ALLOW_NETWORKS) -> Callable[[str], bool]:
    """address_allowed plus explicitly listed networks (never loopback,
    link-local or unspecified, whatever is listed)."""
    extra = tuple(ipaddress.ip_network(n, strict=False) for n in networks)

    def allowed(address: str) -> bool:
        if address_allowed(address):
            return True
        ip = _parse(address)
        if ip is None or ip.is_loopback or ip.is_link_local or ip.is_unspecified or ip.is_multicast:
            return False
        return any(ip.version == net.version and ip in net for net in extra)
    return allowed


def split_host_port(value: str, default_port: Optional[int] = None) -> Tuple[str, int]:
    """("host", port) of `host:port` / `[v6]:port`; ValueError when invalid."""
    match = re.fullmatch(r"\[([0-9A-Fa-f:.]+)\](?::(\d{1,5}))?|([A-Za-z0-9._-]+)(?::(\d{1,5}))?", value)
    if not match:
        raise ValueError("bad authority")
    host = match.group(1) or match.group(3)
    port = match.group(2) or match.group(4)
    if port is None:
        if default_port is None:
            raise ValueError("missing port")
        return host, default_port
    number = int(port)
    if not 1 <= number <= 65535:
        raise ValueError("bad port")
    return host, number


class Refused(Exception):
    """A request the proxy will not forward; str() is the reason."""

    def __init__(self, status: int, reason: str):
        super().__init__(reason)
        self.status = status


class EgressProxy(_Listener):
    """HTTP CONNECT + absolute-form HTTP proxy for one run's containers.

    Bound to the workbench machine's loopback (only the run's `ssh -R`
    reaches it). `ports` limits CONNECT and plain HTTP destinations; `allow`
    decides which resolved addresses may be connected to (tests inject a
    permissive one to reach a loopback echo server)."""

    def __init__(self, ports: Sequence[int] = DEFAULT_PORTS, bind: str = "127.0.0.1",
                 allow: Optional[Callable[[str], bool]] = None, resolve=socket.getaddrinfo,
                 connect_timeout: float = 15.0, log: Optional[Callable[[str], None]] = None):
        super().__init__(bind, 0)
        self.ports = frozenset(int(p) for p in ports)
        self.allow, self.resolve = allow or allow_policy(), resolve
        self.connect_timeout = connect_timeout
        self.log = log or (lambda _text: None)
        self.lock = threading.Lock()
        self.counts = {"connect": 0, "http": 0, "refused": 0, "probe": 0}

    @property
    def port(self) -> int:
        return self.address[1]

    def count(self, key):
        with self.lock:
            self.counts[key] += 1

    def destination(self, host: str, port: int) -> socket.socket:
        if port not in self.ports:
            raise Refused(403, f"port {port} is not allowed")
        if "." not in host and ":" not in host:
            # A single-label name (a compose service such as `alfworld-env`)
            # only exists inside the executor's Docker network; it belongs in
            # NO_PROXY. Refused at once, without a DNS lookup.
            raise Refused(502, f"{host} is a single-label name the workbench proxy cannot reach; "
                               "add it to NO_PROXY (compose service names must not use the proxy)")
        try:
            infos = self.resolve(host, port, 0, socket.SOCK_STREAM)
        except (OSError, UnicodeError):
            raise Refused(502, "cannot resolve " + host) from None
        addresses = []
        for family, kind, proto, _name, sockaddr in infos:
            if not self.allow(sockaddr[0]):
                # Any non-public answer refuses the name: a name that mixes
                # private and public answers is not trusted at all.
                raise Refused(403, f"{host} resolves to a non-public address")
            addresses.append((family, kind, proto, sockaddr))
        if not addresses:
            raise Refused(502, "cannot resolve " + host)
        last = None
        for family, kind, proto, sockaddr in addresses:
            upstream = socket.socket(family, kind, proto)
            upstream.settimeout(self.connect_timeout)
            try:
                upstream.connect(sockaddr)
                upstream.settimeout(None)
                return upstream
            except OSError as exc:
                last = exc
                upstream.close()
        raise Refused(502, f"cannot connect to {host}:{port}: {last}")

    @staticmethod
    def reply(conn, status: int, reason: str, body: bytes = b"") -> None:
        head = (f"HTTP/1.1 {status} {reason}\r\nContent-Type: text/plain\r\n"
                f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n").encode()
        try:
            conn.sendall(head + body)
        except OSError:
            pass
        conn.close()

    def handle(self, conn):
        conn.settimeout(30)
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = conn.recv(8192)
            if not chunk:
                conn.close()
                return
            data += chunk
            if len(data) > HEAD_LIMIT:
                return self.reply(conn, 431, "Request Header Fields Too Large")
        conn.settimeout(None)
        head, rest = data.split(b"\r\n\r\n", 1)
        lines = head.decode("latin-1").split("\r\n")
        parts = lines[0].split(" ")
        if len(parts) != 3:
            return self.reply(conn, 400, "Bad Request")
        method, target, version = parts
        try:
            if method == "CONNECT":
                host, port = split_host_port(target)
                upstream = self.destination(host, port)
                self.count("connect")
                conn.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
                if rest:
                    upstream.sendall(rest)
                return pipe(conn, upstream)
            if target.lower().startswith("http://"):
                url = urlsplit(target)
                host, port = split_host_port(url.netloc.rsplit("@", 1)[-1], 80)
                upstream = self.destination(host, port)
                self.count("http")
                path = (url.path or "/") + ("?" + url.query if url.query else "")
                headers = [line for line in lines[1:] if line and
                           line.split(":", 1)[0].strip().lower() not in HOP_HEADERS]
                # One request per upstream connection: the next request on
                # this client connection may name another host.
                rebuilt = "\r\n".join([f"{method} {path} {version}"] + headers + ["Connection: close", "", ""])
                upstream.sendall(rebuilt.encode("latin-1") + rest)
                return pipe(conn, upstream)
            if method == "GET" and target == PROBE_PATH:
                self.count("probe")
                return self.reply(conn, 200, "OK", PROBE_BODY)
            return self.reply(conn, 400, "Bad Request")
        except Refused as exc:
            self.count("refused")
            self.log(f"出网代理拒绝 {method} {target[:200]}：{exc}")
            return self.reply(conn, exc.status, "Refused", str(exc).encode())
        except ValueError:
            return self.reply(conn, 400, "Bad Request")


# ------------------------------------------------------------------ remote forwarder

class Forwarder(_Listener):
    """Listen on `bind` (the Docker bridge gateway) and relay every
    connection to `target` (the tunnel's loopback end)."""

    def __init__(self, bind: str, target: Tuple[str, int], port: int = 0, sock: Optional[socket.socket] = None):
        super().__init__(bind, port, sock)
        self.target = target

    def handle(self, conn):
        try:
            upstream = socket.create_connection(self.target, timeout=15)
            upstream.settimeout(None)
        except OSError:
            conn.close()
            return
        pipe(conn, upstream)


def interface_ipv4(name: str) -> Optional[str]:
    """IPv4 address of a network interface (Linux SIOCGIFADDR), or None."""
    try:
        import fcntl
    except ImportError:
        return None
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        try:
            raw = fcntl.ioctl(sock.fileno(), 0x8915, struct.pack("256s", name.encode()[:15]))
        except OSError:
            return None
    return socket.inet_ntoa(raw[20:24])


def docker_gateway(env=None, run=subprocess.run) -> Optional[str]:
    """The default Docker bridge's gateway on this host: docker0's address,
    else what `docker network inspect bridge` reports."""
    found = interface_ipv4("docker0")
    if found:
        return found
    try:
        done = run(["docker", "network", "inspect", "bridge", "--format", "{{(index .IPAM.Config 0).Gateway}}"],
                   stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=20, env=env)
    except (OSError, subprocess.TimeoutExpired):
        return None
    value = (done.stdout or "").strip()
    try:
        return str(ipaddress.IPv4Address(value)) if done.returncode == 0 and value else None
    except ValueError:
        return None


def no_proxy(hosts: Iterable[Optional[str]]) -> str:
    seen: List[str] = []
    for host in list(BASE_NO_PROXY) + [h for h in hosts if h]:
        if host not in seen:
            seen.append(host)
    return ",".join(seen)


def write_docker_config(directory: Path, proxy_url: str, no_proxy_value: str,
                        home: Optional[Path] = None) -> Path:
    """A Docker CLI config dir holding only the proxies (no credentials).

    Harbor's compose plugin may live in ~/.docker/cli-plugins, which the CLI
    stops looking at once DOCKER_CONFIG moves; that directory (not the user's
    config file) is listed as an extra plugin directory."""
    directory = Path(directory)
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    config: Dict = {"proxies": {"default": {"httpProxy": proxy_url, "httpsProxy": proxy_url,
                                            "noProxy": no_proxy_value}}}
    plugins = Path(home or Path.home()) / ".docker" / "cli-plugins"
    if plugins.is_dir():
        config["cliPluginsExtraDirs"] = [str(plugins)]
    (directory / "config.json").write_text(json.dumps(config, indent=1) + "\n", encoding="utf-8")
    return directory


class Session:
    """The remote driver's egress for one run: forwarder (workbench mode) and
    the run-scoped DOCKER_CONFIG directory, both removed by close()."""

    def __init__(self, options: Dict, parent: Path, relay_hosts: Sequence[Optional[str]] = (),
                 env=None, run=subprocess.run, home: Optional[Path] = None):
        self.forwarder = None
        self.directory = Path(tempfile.mkdtemp(prefix="docker-config-", dir=str(parent)))
        try:
            hosts = list(relay_hosts)
            if options["mode"] == "workbench":
                gateway = docker_gateway(env, run) or options.get("bind") or "172.17.0.1"
                self.forwarder = Forwarder(gateway, ("127.0.0.1", int(options["tunnel_port"]))).start()
                host, port = self.forwarder.address[:2]
                url = f"http://{host}:{port}"
                hosts.insert(0, gateway)
            elif options["mode"] == "proxy":
                url = options["url"]
            else:
                raise ValueError("unknown egress mode")
            self.proxy_url = url
            self.no_proxy = no_proxy(hosts + list(options.get("no_proxy") or ()))
            write_docker_config(self.directory, url, self.no_proxy, home)
        except Exception:
            self.close()
            raise

    def close(self):
        if self.forwarder is not None:
            self.forwarder.close()
            self.forwarder = None
        shutil.rmtree(self.directory, ignore_errors=True)


# ------------------------------------------------------------------ ghcr.io mirror

FROM_LINE = re.compile(r"^\s*FROM\s+(?:--\S+\s+)*(\S+)", re.I | re.M)
COMPOSE_IMAGE = re.compile(r"^\s*image:\s*[\"']?([^\"'\s#]+)", re.M)
TOML_IMAGE = re.compile(r"^\s*docker_image\s*=\s*[\"']([^\"']+)[\"']", re.M)
IMAGE_REF = re.compile(r"^ghcr\.io/[a-z0-9][a-z0-9._/-]*(?::[A-Za-z0-9._-]{1,128})?(?:@sha256:[0-9a-f]{64})?$")


def task_images(task_dir: Path) -> List[str]:
    """Image references a task's Dockerfiles, compose files and task.toml name."""
    found = []
    for path in sorted(Path(task_dir).rglob("*")):
        if not path.is_file() or path.is_symlink():
            continue
        name = path.name.lower()
        if name.startswith("dockerfile") or name.endswith(".dockerfile"):
            pattern = FROM_LINE
        elif name.endswith((".yaml", ".yml")) and "compose" in name:
            pattern = COMPOSE_IMAGE
        elif name == "task.toml":
            pattern = TOML_IMAGE
        else:
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        found += pattern.findall(text)
    return found


def selected_tasks(dataset: Path, patterns: Sequence[str]) -> List[Path]:
    """Task directories of a `-p` dataset that Harbor's `-i` patterns select."""
    try:
        children = sorted(Path(dataset).iterdir())
    except OSError:
        return []
    return [child for child in children if child.is_dir() and not child.name.startswith(".")
            and (not patterns or any(fnmatch(child.name, p) for p in patterns))]


def ghcr_images(dataset: Path, patterns: Sequence[str]) -> List[str]:
    """ghcr.io images the selected tasks of a `-p` dataset need."""
    result = set()
    for child in selected_tasks(dataset, patterns):
        for ref in task_images(child):
            if IMAGE_REF.fullmatch(ref):
                result.add(ref)
    return sorted(result)


# Harbor names a task's own container `main` in its compose project.
HARBOR_SERVICES = ("main",)
SERVICE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$")


def compose_services(text: str) -> List[str]:
    """The keys under a compose file's top-level `services:` (no YAML
    library: block style, the form task compose files use)."""
    names, inside, indent = [], False, None
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].rstrip()
        if not line.strip():
            continue
        depth = len(line) - len(line.lstrip(" "))
        if depth == 0:
            inside = line.strip() == "services:"
            indent = None
            continue
        if not inside:
            continue
        if indent is None:
            indent = depth
        if depth == indent:
            key = line.strip()
            if key.endswith(":"):
                key = key[:-1].strip().strip("\"'")
                if SERVICE_NAME.fullmatch(key):
                    names.append(key)
    return names


def task_services(dataset: Path, patterns: Sequence[str]) -> List[str]:
    """Compose service names of the selected tasks plus Harbor's `main`:
    containers address their sidecars by these names, which must never go
    through the proxy (it cannot resolve them)."""
    found = list(HARBOR_SERVICES)
    for task in selected_tasks(dataset, patterns):
        for path in sorted(task.rglob("*")):
            name = path.name.lower()
            if path.is_file() and not path.is_symlink() and name.endswith((".yaml", ".yml")) and "compose" in name:
                try:
                    found += compose_services(path.read_text(encoding="utf-8", errors="replace"))
                except OSError:
                    continue
    return list(dict.fromkeys(found))


def mirror_ref(ref: str, mirror: str) -> str:
    return mirror.rstrip("/") + ref[len("ghcr.io"):]


def ensure_ghcr(images: Sequence[str], mirror: str, env=None, run=subprocess.run,
                log: Callable[[str], None] = print, stop: Optional[threading.Event] = None) -> List[str]:
    """Pull each missing ghcr.io image through `mirror` and tag it back to
    its ghcr.io name; returns the images it tagged. Failures are logged:
    Harbor then tries ghcr.io itself."""
    def docker(*args, timeout=60):
        try:
            return run(["docker", *args], stdin=subprocess.DEVNULL, capture_output=True, env=env,
                       timeout=timeout).returncode == 0
        except (OSError, subprocess.TimeoutExpired):
            return False

    tagged = []
    for ref in images:
        if stop is not None and stop.is_set():
            break
        if docker("image", "inspect", ref):
            continue
        source = mirror_ref(ref, mirror)
        log(f"ghcr 镜像：经 {mirror} 拉取 {ref}")
        if not docker("pull", source, timeout=3600):
            log(f"经镜像拉取 {source} 失败，交给 Harbor 直接拉取 {ref}")
            continue
        if docker("tag", source, ref):
            tagged.append(ref)
    return tagged
