"""Streaming timing relay. Captures numeric metrics, never bodies or keys.

One job owns a relay and each trial uses a distinct URL prefix. HTTP payloads
are forwarded unchanged; request clocks exclude task/tool execution. The
loopback/Docker hop is part of the benchmark harness, not a provider SLA.
"""
from __future__ import annotations

import datetime as dt
import hmac
import http.client
import json
import math
import re
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


class TimingRelay:
    def __init__(self, target, credential, metrics_dir, *, bind="172.17.0.1", port=0,
                 auth_header="Authorization", auth_prefix="Bearer ", tls=False):
        origin = urlsplit(target)
        if origin.scheme not in ("http", "https") or not origin.hostname or origin.username or origin.password or origin.query or origin.fragment:
            raise ValueError("invalid profiling upstream")
        self.origin = origin
        self.credential = credential
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
                if not hmac.compare_digest(self.headers.get(auth_header, ""), auth_prefix + owner.credential):
                    self.send_error(401)
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
                status, complete = 0, False
                try:
                    if self.upstream is None:
                        cls = http.client.HTTPSConnection if origin.scheme == "https" else http.client.HTTPConnection
                        self.upstream = cls(origin.hostname, origin.port, timeout=1800)
                    headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP}
                    headers["Accept-Encoding"] = "identity"
                    upstream_path = suffix + ("?" + path.query if path.query else "")
                    self.upstream.request(self.command, upstream_path, body=body, headers=headers)
                    response = self.upstream.getresponse()
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
                        owner.record(parts[1], {"request": sequence, "started_at": started_at, **metric.finish(status, complete)})

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
                                "-subj", "/CN=metacodes-bench-relay", "-addext", "subjectAltName=IP:" + bind + ",DNS:" + bind,
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
        self.url = f"{'https' if tls else 'http'}://{bind}:{self.server.server_port}"

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


def upstream_for(spec):
    """Only explicitly configured HTTP streaming routes are profiled."""
    if spec.get("auth_mode") == "metask":
        return spec.get("account_gateway") or "https://napi.metask-ai.com"
    if not spec.get("provider_config"):
        return None
    provider = spec["model"].split("/", 1)[0]
    native = json.loads(Path(spec["provider_config"]).read_text())
    config = native.get("custom_providers", {}).get(provider, {})
    if config.get("auth", {}).get("kind", "bearer") not in ("bearer", "api_key_header", "custom_header"):
        return None
    channels = config.get("channels") or []
    channel = next((c for c in channels if c.get("id") == config.get("default_channel")), channels[0] if channels else {})
    if channel.get("protocol") not in ("anthropic_messages", "openai_chat", "openai_responses"):
        return None
    base = channel.get("base_url")
    return base if base and urlsplit(base).path.rstrip("/") in ("", "/v1") else None


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
