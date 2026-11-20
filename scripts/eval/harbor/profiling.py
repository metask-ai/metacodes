"""Credential relay with optional streaming timing capture.

Every Harbor run's model traffic goes through one relay on the Docker host.
The task container holds only a run-scoped placeholder token; the relay
accepts exactly that placeholder and forwards each request upstream with the
current real credential, which it reads from a credential source (a fixed
key, a refreshing Metask session, or tokens pushed over the SSH channel).
With metrics enabled it also records numeric timing/usage and the byte size
of each part of the request context (system, tools, messages), never bodies
or keys. One job owns a relay and each trial uses a distinct URL prefix. HTTP
payloads are forwarded unchanged; request clocks exclude task/tool execution.
The loopback/Docker hop is part of the benchmark harness, not a provider SLA.
"""
from __future__ import annotations

import datetime as dt
import hmac
import http.client
import ipaddress
import json
import math
import re
import secrets
import ssl
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._@+-]*$")
HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailer", "transfer-encoding", "upgrade", "host", "content-length"}


def count(value):
    if type(value) is int:
        return value if 0 <= value <= (1 << 64) - 1 else None
    if type(value) is float and math.isfinite(value) and value.is_integer() and 0 <= value <= (1 << 64) - 1:
        return int(value)
    return None


def usage_values(usage):
    if not isinstance(usage, dict):
        return {}
    cached = count(usage.get("cache_read_input_tokens"))
    created = count(usage.get("cache_creation_input_tokens"))
    details = usage.get("prompt_tokens_details") or usage.get("input_tokens_details") or {}
    if cached is None and isinstance(details, dict):
        cached = count(details.get("cached_tokens"))
    prompt = count(usage.get("prompt_tokens"))
    if prompt is None:
        prompt = count(usage.get("input_tokens"))
        # Anthropic's input excludes cache; Responses' input includes it.
        if prompt is not None and ("cache_read_input_tokens" in usage or "cache_creation_input_tokens" in usage):
            prompt += (cached or 0) + (created or 0)
    output = count(usage.get("output_tokens", usage.get("completion_tokens")))
    return {k: v for k, v in {"input_tokens": prompt, "output_tokens": output,
                             "cache_tokens": cached, "cache_creation_tokens": created}.items() if v is not None}


# Parts of a model request's input context, as the page names them.
CONTEXT_PARTS = ("system", "tools", "user", "assistant", "tool_results")


def _size(value):
    if value is None:
        return 0
    if isinstance(value, str):
        return len(value.encode("utf-8", "surrogatepass"))
    return len(json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8", "surrogatepass"))


def request_composition(body):
    """Byte counts of each part of a model request's context, or None.

    Only sizes leave this function, never content: system prompt, tool
    definitions, user/task messages, the model's own earlier output, and tool
    results, for the Anthropic Messages, OpenAI Chat and Responses shapes.
    The page apportions the measured input tokens by these shares."""
    try:
        request = json.loads(body) if body else None
    except (ValueError, UnicodeDecodeError, RecursionError):
        return None
    if not isinstance(request, dict):
        return None
    parts = dict.fromkeys(CONTEXT_PARTS, 0)
    tools = request.get("tools")
    parts["tools"] = _size(tools)
    parts["system"] = _size(request.get("system")) + _size(request.get("instructions"))
    messages = request.get("messages")
    items = request.get("input")
    count = 0
    if isinstance(messages, list):
        for message in messages:
            if not isinstance(message, dict):
                continue
            count += 1
            role, content = message.get("role"), message.get("content")
            if role in ("system", "developer"):
                parts["system"] += _size(content)
            elif role == "assistant":
                parts["assistant"] += _size(content) + _size(message.get("tool_calls"))
            elif role == "tool":
                parts["tool_results"] += _size(content)
            elif isinstance(content, list):  # Anthropic user turn: tool results ride here
                for block in content:
                    key = "tool_results" if isinstance(block, dict) and block.get("type") == "tool_result" else "user"
                    parts[key] += _size(block)
            else:
                parts["user"] += _size(content)
    elif isinstance(items, str):
        parts["user"] += _size(items)
    elif isinstance(items, list):
        for item in items:
            if not isinstance(item, dict):
                continue
            count += 1
            kind, role = item.get("type", "message"), item.get("role")
            if kind in ("function_call_output", "custom_tool_call_output"):
                parts["tool_results"] += _size(item.get("output"))
            elif kind in ("function_call", "custom_tool_call", "reasoning") or role == "assistant":
                parts["assistant"] += _size(item)
            elif role in ("system", "developer"):
                parts["system"] += _size(item.get("content"))
            else:
                parts["user"] += _size(item.get("content"))
    else:
        return None
    return {**parts, "messages": count, "tool_count": len(tools) if isinstance(tools, list) else 0}


class StreamMetrics:
    def __init__(self, clock=time.perf_counter):
        self.clock = clock
        self.started = clock()
        self.first = None
        self.pending = b""
        self.usage = {}
        self.failed = False
        self.terminal = False

    def feed(self, chunk):
        at = self.clock()
        self.pending += chunk
        if len(self.pending) > 2 * 1024 * 1024:
            self.pending = b""  # bounded observer; forwarded data is untouched
            return
        while b"\n" in self.pending:
            line, self.pending = self.pending.split(b"\n", 1)
            if not line.startswith(b"data:"):
                continue
            if line[5:].strip() == b"[DONE]":
                self.terminal = True
                continue
            try:
                value = json.loads(line[5:].strip())
            except (ValueError, UnicodeDecodeError):
                continue
            if not isinstance(value, dict):
                continue
            kind = value.get("type", "")
            if kind in ("error", "response.failed", "response.incomplete"):
                self.failed = True
            if kind in ("message_stop", "response.completed"):
                self.terminal = True
            containers = [value, value.get("message"), value.get("response")]
            for item in containers:
                if isinstance(item, dict):
                    self.usage.update(usage_values(item.get("usage")))
            delta = value.get("delta") or {}
            output = kind in ("response.output_text.delta", "response.reasoning_text.delta", "response.reasoning_summary_text.delta",
                              "response.refusal.delta", "response.function_call_arguments.delta") and bool(delta)
            if isinstance(delta, dict):
                output = output or any(delta.get(k) for k in ("text", "thinking", "partial_json"))
                self.terminal = self.terminal or bool(delta.get("stop_reason"))
            block = value.get("content_block") or value.get("item") or {}
            if isinstance(block, dict):
                output = output or any(block.get(k) for k in ("text", "thinking")) or (block.get("type") in ("tool_use", "function_call") and bool(block.get("name")))
            for choice in value.get("choices") or []:
                if not isinstance(choice, dict):
                    continue
                d = choice.get("delta") or {}
                if not isinstance(d, dict):
                    continue
                output = output or any(d.get(k) for k in ("content", "reasoning_content", "reasoning", "refusal"))
                for call in d.get("tool_calls") or []:
                    function = call.get("function") if isinstance(call, dict) else None
                    if isinstance(function, dict):
                        output = output or function.get("name") or function.get("arguments")
                self.terminal = self.terminal or bool(choice.get("finish_reason"))
            if output and self.first is None:
                self.first = at

    def finish(self, status, complete):
        end = self.clock()
        return {"schema_version": 1, "http_status": status,
                "complete": complete and self.terminal and not self.failed and 200 <= status < 300,
                "duration_ms": (end - self.started) * 1000,
                "ttft_ms": (self.first - self.started) * 1000 if self.first is not None else None,
                "generation_ms": (end - self.first) * 1000 if self.first is not None else None,
                **self.usage}


PLACEHOLDER_PREFIX = "mcb-"

# An LLM-judged suite's verifier reaches the relay at `<relay>/JUDGE_ROUTE/v1`
# with a placeholder of its own (Harbor resolves `${JUDGE_TOKEN_ENV}` from its
# environment when the verifier starts). That token is good for this route and
# POST /v1/chat/completions only; the agent's placeholder is refused there.
JUDGE_ROUTE = "bench-judge"
JUDGE_TOKEN_ENV = "METACODES_BENCH_JUDGE_TOKEN"
# Inside the task container: the system CA bundle plus the relay's CA, copied
# by MetacodesAgent.install. Python's openai/httpx client trusts certifi, not
# the system bundle, unless SSL_CERT_FILE names a bundle.
TRUST_BUNDLE = "/usr/local/share/metacodes-bench/ca-bundle.pem"
JUDGE_ENV_NAME = re.compile(r"^[A-Z][A-Z0-9_]*$")
JUDGE_MODEL = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$")


def judge_argv(judge, relay_url):
    """Harbor `--ve` arguments pointing a suite's LLM judge at the relay.

    `judge` is the launch spec's {"model", "env": {"api_key", "base_url",
    "model", "ca_file"?}}. The values are the judge placeholder's *name*
    (a template Harbor resolves), the relay route, the bare gateway model id
    and the in-container CA bundle: nothing secret reaches Harbor's argv."""
    env = judge["env"]
    if not isinstance(judge.get("model"), str) or not JUDGE_MODEL.fullmatch(judge["model"]):
        raise ValueError("invalid judge model")
    values = {env["api_key"]: "${" + JUDGE_TOKEN_ENV + "}",
              env["base_url"]: relay_url.rstrip("/") + "/" + JUDGE_ROUTE + "/v1",
              env["model"]: judge["model"]}
    if env.get("ca_file"):
        values[env["ca_file"]] = TRUST_BUNDLE
    argv = []
    for name, value in values.items():
        if not isinstance(name, str) or not JUDGE_ENV_NAME.fullmatch(name):
            raise ValueError("invalid judge environment name")
        argv += ["--ve", name + "=" + value]
    return argv


def placeholder(run):
    """A random run-scoped stand-in for the credential inside containers."""
    label = re.sub(r"[^A-Za-z0-9]", "", run or "")[-24:] or "run"
    return PLACEHOLDER_PREFIX + label + "-" + secrets.token_urlsafe(32)


class StaticCredential:
    """A key that does not expire (provider key, legacy account group key)."""
    refreshing = False

    def __init__(self, value):
        if not value:
            raise ValueError("missing credential")
        self.value = value

    def current(self):
        return self.value

    def refresh(self, stale):
        return self.value

    def status(self):
        return {"refreshing": False}


class PushedCredential:
    """The remote half of a refreshing credential: the local worker owns the
    refresh token and sends each new access token over the SSH channel.
    Until a push arrives the previous token stays in use."""
    refreshing = True

    def __init__(self, value):
        if not value:
            raise ValueError("missing credential")
        self.lock = threading.Lock()
        self.value = value
        self.pushes = 0

    def set(self, value):
        if isinstance(value, str) and value:
            with self.lock:
                self.value = value
                self.pushes += 1

    def current(self):
        with self.lock:
            return self.value

    def refresh(self, stale):
        return self.current()

    def status(self):
        return {"refreshing": True, "pushes": self.pushes}


def same_secret(a, b):
    return hmac.compare_digest(a.encode("utf-8", "surrogateescape"), b.encode("utf-8", "surrogateescape"))


def subject_alt_names(*hosts):
    names = []
    for host in dict.fromkeys(hosts):
        try:
            ipaddress.ip_address(host)
            names.append("IP:" + host)
        except ValueError:
            pass
        names.append("DNS:" + host)
    return ",".join(names)


class TimingRelay:
    def __init__(self, target, credential, metrics_dir, *, bind="172.17.0.1", port=0,
                 auth_header="Authorization", auth_prefix="Bearer ", tls=False, public_host=None,
                 token=None, record=True, judge_token=None, judge_credential=None, connect=None):
        # `credential` is the real upstream credential (a string or a source
        # with current()/refresh(stale)); `token` is the placeholder the
        # containers present (a fresh one when omitted). `record=False`
        # proxies auth without writing metrics. `judge_token` opens
        # JUDGE_ROUTE for a verifier's chat completions, forwarded with
        # `judge_credential` (default `credential`) and never recorded.
        # `public_host` is the address containers dial when it differs from
        # the bind address: Colima's VM reaches the Mac's loopback through
        # its user-mode gateway (host.lima.internal, 192.168.5.2).
        public_host = public_host or bind
        origin = urlsplit(target)
        if origin.scheme not in ("http", "https") or not origin.hostname or origin.username or origin.password or origin.query or origin.fragment:
            raise ValueError("invalid profiling upstream")
        self.origin = origin
        self.credential = StaticCredential(credential) if isinstance(credential, str) else credential
        self.token = token or placeholder("relay")
        if judge_token is not None and (not judge_token or judge_token == self.token):
            raise ValueError("the judge placeholder must differ from the agent's")
        self.judge_token = judge_token
        if isinstance(judge_credential, str):
            judge_credential = StaticCredential(judge_credential)
        self.judge_credential = judge_credential or self.credential
        self.recording = record
        self.metrics_dir = Path(metrics_dir)
        self.lock = threading.Lock()
        self.sequence = 0
        self.cert_dir = None
        self.ca_path = None
        owner = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def setup(self):
                self.upstream = None
                if isinstance(self.request, ssl.SSLSocket):
                    self.request.settimeout(15)
                    self.request.do_handshake()
                    self.request.settimeout(1800)
                super().setup()

            def finish(self):
                try:
                    if self.upstream:
                        self.upstream.close()
                finally:
                    super().finish()

            def do_GET(self):
                self.forward(False)

            def do_POST(self):
                self.forward(True)

            def forward(self, measured):
                path = urlsplit(self.path)
                parts = path.path.split("/", 2)
                if len(parts) != 3 or not NAME.fullmatch(parts[1]):
                    self.send_error(404)
                    return
                suffix = "/" + parts[2]
                if suffix not in ("/v1/messages", "/v1/chat/completions", "/v1/responses", "/v1/models"):
                    self.send_error(404)
                    return
                presented = self.headers.get(auth_header, "")
                credential = owner.credential
                if owner.judge_token and same_secret(presented, auth_prefix + owner.judge_token):
                    # The verifier's judge: one route, one endpoint, no metrics.
                    if parts[1] != JUDGE_ROUTE or suffix != "/v1/chat/completions" or not measured:
                        self.send_error(403)
                        return
                    credential, measured = owner.judge_credential, False
                elif not same_secret(presented, auth_prefix + owner.token):
                    self.send_error(401)
                    return
                elif parts[1] == JUDGE_ROUTE:
                    self.send_error(403)  # the agent's token never reaches the judge route
                    return
                try:
                    length = int(self.headers.get("Content-Length", "0"))
                except ValueError:
                    self.send_error(400)
                    return
                if not 0 <= length <= 32 * 1024 * 1024:
                    self.send_error(413)
                    return
                body = self.rfile.read(length) if length else None
                metric = StreamMetrics()
                started_at = dt.datetime.now(dt.timezone.utc).isoformat()
                with owner.lock:
                    owner.sequence += 1
                    sequence = owner.sequence
                secret = credential.current()
                if not secret:
                    # The run's login can no longer be refreshed.
                    self.send_error(401)
                    return
                status, complete = 0, False
                measured = measured and owner.recording
                shape = request_composition(body) if measured and suffix != "/v1/models" else None
                try:
                    headers = {k: v for k, v in self.headers.items()
                               if k.lower() not in HOP and k.lower() != auth_header.lower()}
                    headers["Accept-Encoding"] = "identity"
                    upstream_path = suffix + ("?" + path.query if path.query else "")
                    response = self.exchange(upstream_path, body, headers, secret)
                    if response.status == 401:
                        # Nothing has reached the container yet: refresh the
                        # credential once and repeat the request.
                        fresh = credential.refresh(secret)
                        if fresh and fresh != secret:
                            response.read()
                            response = self.exchange(upstream_path, body, headers, fresh)
                    status = response.status
                    self.send_response(status)
                    for name, value in response.getheaders():
                        if name.lower() not in HOP:
                            self.send_header(name, value)
                    self.send_header("Transfer-Encoding", "chunked")
                    self.end_headers()
                    while True:
                        chunk = response.read1(65536)
                        if not chunk:
                            break
                        try:
                            metric.feed(chunk)
                        except (ValueError, TypeError, AttributeError):
                            metric.failed = True  # observation cannot change the response
                        self.wfile.write(f"{len(chunk):x}\r\n".encode() + chunk + b"\r\n")
                        self.wfile.flush()
                    self.wfile.write(b"0\r\n\r\n")
                    self.wfile.flush()
                    complete = True
                except (OSError, http.client.HTTPException):
                    self.close_connection = True
                finally:
                    if measured:
                        owner.record(parts[1], {"request": sequence, "started_at": started_at, **metric.finish(status, complete),
                                                **({"composition": shape} if shape else {})})

            def exchange(self, upstream_path, body, headers, secret):
                while True:
                    reused = self.upstream is not None
                    if not reused:
                        cls = http.client.HTTPSConnection if origin.scheme == "https" else http.client.HTTPConnection
                        self.upstream = cls(origin.hostname, origin.port, timeout=1800)
                        if connect:
                            self.upstream._create_connection = connect
                    try:
                        self.upstream.request(self.command, upstream_path, body=body,
                                              headers={**headers, auth_header: auth_prefix + secret})
                        return self.upstream.getresponse()
                    except (OSError, http.client.HTTPException):
                        # Only a kept-alive connection the upstream closed
                        # meanwhile is retried, on a new connection.
                        self.upstream.close()
                        self.upstream = None
                        if not reused:
                            raise

            def log_message(self, *_args):
                pass  # URLs, headers and bodies are not diagnostic metrics

        # Avoid HTTPServer's reverse DNS lookup at startup.
        class DirectServer(ThreadingHTTPServer):
            def server_bind(self):
                import socketserver
                socketserver.TCPServer.server_bind(self)
                self.server_name, self.server_port = self.server_address[:2]

            def get_request(self):
                connection, address = super().get_request()
                if owner.tls_context:
                    try:
                        connection = owner.tls_context.wrap_socket(
                            connection, server_side=True, do_handshake_on_connect=False)
                    except Exception:
                        connection.close()
                        raise
                return connection, address

            def handle_error(self, request, client_address):
                if not isinstance(sys.exc_info()[1], (ssl.SSLError, TimeoutError)):
                    super().handle_error(request, client_address)

        self.tls_context = None
        self.server = DirectServer((bind, port), Handler)
        self.server.daemon_threads = True
        try:
            if tls:
                self.cert_dir = tempfile.TemporaryDirectory(prefix="metacodes-bench-relay-")
                self.ca_path = Path(self.cert_dir.name) / "ca.pem"
                key = Path(self.cert_dir.name) / "key.pem"
                subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-days", "2", "-nodes",
                                # Zig 0.16 verifies dNSName SANs only; retain
                                # the IP SAN for other TLS clients as well.
                                "-subj", "/CN=metacodes-bench-relay", "-addext", "subjectAltName=" + subject_alt_names(public_host, bind),
                                "-addext", "basicConstraints=critical,CA:TRUE", "-keyout", str(key), "-out", str(self.ca_path)],
                               check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                context.load_cert_chain(str(self.ca_path), str(key))
                # Handshakes run in request threads, so an idle TCP probe
                # cannot stop other trials or block relay shutdown.
                self.tls_context = context
        except Exception:
            self.server.server_close()
            if self.cert_dir:
                self.cert_dir.cleanup()
            raise
        self.url = f"{'https' if tls else 'http'}://{public_host}:{self.server.server_port}"

    def record(self, trial, metric):
        with self.lock:
            self.metrics_dir.mkdir(parents=True, exist_ok=True)
            with (self.metrics_dir / (trial + ".jsonl")).open("a", encoding="utf-8") as out:
                out.write(json.dumps(metric, allow_nan=False) + "\n")

    def __enter__(self):
        try:
            threading.Thread(target=self.server.serve_forever, daemon=True).start()
        except RuntimeError:
            self.server.server_close()
            if self.cert_dir:
                self.cert_dir.cleanup()
            raise
        return self

    def __exit__(self, *_args):
        self.server.shutdown()
        self.server.server_close()
        if self.cert_dir:
            self.cert_dir.cleanup()


def route_problem(spec):
    """Why this run's model route cannot go through the relay, or None.

    The relay forwards only `/v1/{messages,chat/completions,responses,models}`
    of one upstream origin and injects the credential into one header, so
    every channel of the provider must use such a protocol, a base URL whose
    path is empty or `/v1`, the same origin, and a header credential. A route
    that cannot be proxied is refused: the container never gets the key."""
    if spec.get("auth_mode") == "metask":
        return None
    if not spec.get("provider_config"):
        return "第三方 Provider 需要 --provider-config（带 channels 的 custom_providers），凭据只经代理转发"
    provider = spec["model"].split("/", 1)[0]
    try:
        native = json.loads(Path(spec["provider_config"]).read_text(encoding="utf-8"))
        config = native.get("custom_providers", {}).get(provider)
    except (OSError, ValueError, AttributeError):
        return "无法读取 --provider-config"
    if not isinstance(config, dict):
        return f"--provider-config 中没有 Provider {provider}"
    if (config.get("auth") or {}).get("kind", "bearer") not in ("bearer", "api_key_header", "custom_header"):
        return f"Provider {provider} 的认证方式无法由凭据代理注入"
    channels = config.get("channels") or []
    if not channels:
        return f"Provider {provider} 没有配置 channels（base_url），无法经凭据代理转发"
    origins = set()
    for channel in channels:
        if not isinstance(channel, dict):
            return f"Provider {provider} 的 channels 格式无效"
        if channel.get("protocol") not in ("anthropic_messages", "openai_chat", "openai_responses"):
            return f"Provider {provider} 的协议 {channel.get('protocol')} 不受凭据代理支持"
        parts = urlsplit(channel.get("base_url") or "")
        if parts.scheme not in ("http", "https") or not parts.hostname or parts.path.rstrip("/") not in ("", "/v1"):
            return f"Provider {provider} 的 base_url 必须是 http(s)://host 或 http(s)://host/v1，才能经凭据代理转发"
        origins.add((parts.scheme, parts.netloc))
    if len(origins) != 1:
        return f"Provider {provider} 的 channels 指向不同的主机，凭据代理只能转发到一个上游"
    return None


def upstream_for(spec):
    """The upstream the relay forwards to, or None when it cannot."""
    if spec.get("auth_mode") == "metask":
        return spec.get("account_gateway") or "https://napi.metask-ai.com"
    if route_problem(spec):
        return None
    provider = spec["model"].split("/", 1)[0]
    config = json.loads(Path(spec["provider_config"]).read_text(encoding="utf-8"))["custom_providers"][provider]
    channels = config["channels"]
    return next((c for c in channels if c.get("id") == config.get("default_channel")), channels[0])["base_url"]


def auth_for(spec):
    if spec.get("auth_mode") == "metask":
        return "Authorization", "Bearer "
    native = json.loads(Path(spec["provider_config"]).read_text())
    auth = native["custom_providers"][spec["model"].split("/", 1)[0]].get("auth", {"kind": "bearer"})
    if auth["kind"] == "bearer":
        return "Authorization", "Bearer "
    return auth["header"], auth.get("value_prefix", "") if auth["kind"] == "custom_header" else ""


def routed_config(config, provider, proxy, trial):
    result = json.loads(json.dumps(config))
    for channel in result.get("custom_providers", {}).get(provider, {}).get("channels", []):
        channel["base_url"] = proxy.rstrip("/") + "/" + trial + urlsplit(channel["base_url"]).path.rstrip("/")
    return result
