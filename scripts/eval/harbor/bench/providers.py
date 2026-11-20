"""Model providers imported into the Bench workbench by URL and API key.

Each entry is one OpenAI- or Anthropic-compatible endpoint with its key and
model names. The models join the workbench catalog as `<provider>/<model>`
next to the Metask account's. A run of such a model gets a generated native
`custom_providers` config that holds no key, under the internal provider id
`bench-<provider>` (a configured provider may not take a built-in vendor's
id, so `openai` stays importable). The key stays in this machine's
private store (`<state root>/bench/providers.json`, mode 0600) and reaches
upstream only through the run's credential relay, like a `--provider-config`
key. Nothing here returns a key to the page, a spec, argv or a log.

Every change of an entry's route (URL, protocol, auth or key) gives it a new
`revision`. A run records the revision its config was generated from and its
worker takes the key only from that same revision, so a run queued before an
edit never pairs the old upstream with the new key.

A probe sends one real request asking the model to echo a random string and
passes only when the reply is that string.
"""
from __future__ import annotations

import datetime as dt
import json
import re
import secrets
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from scripts.eval.harbor.bench import data
from scripts.eval.harbor.bench.account import NoRedirect, private_json, refresh_lock

PROTOCOLS = {"openai_chat": "OpenAI Chat Completions", "openai_responses": "OpenAI Responses",
             "anthropic_messages": "Anthropic Messages"}
AUTHS = {"bearer": "Authorization: Bearer", "x-api-key": "x-api-key"}
# A native provider id (lowercase slug); `metask` is the account's prefix.
PROVIDER_ID = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}$")
MODEL_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,127}$")
RESERVED = {"metask"}
NATIVE_PREFIX = "bench-"
ROUTE_FIELDS = ("base_url", "protocol", "auth", "api_key")
MAX_PROVIDERS = 32
MAX_MODELS = 64
# The variable inside Harbor that holds the run's placeholder.
KEY_ENV = "METACODES_BENCH_PROVIDER_KEY"
# Paths a pasted endpoint URL may carry; the relay forwards to the origin.
ENDPOINT_SUFFIXES = ("/chat/completions", "/responses", "/messages", "/models")
PROBE_TIMEOUT = 60
REPLY_LIMIT = 200


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def normalize_base_url(value, protocol):
    """The native channel base URL: the origin for Anthropic Messages,
    `<origin>/v1` for the OpenAI protocols (metacodes appends `/v1/messages`
    or `/chat/completions` / `/responses` to it)."""
    if not isinstance(value, str) or not value.strip():
        raise ValueError("请填写 Base URL")
    parts = urllib.parse.urlsplit(value.strip())
    if parts.scheme not in ("http", "https") or not parts.hostname:
        raise ValueError("Base URL 必须是 http(s):// 开头的地址")
    if parts.username or parts.password or parts.query or parts.fragment:
        raise ValueError("Base URL 不能带用户名、密码、查询参数或片段；API Key 单独填写")
    path = parts.path.rstrip("/")
    for suffix in ENDPOINT_SUFFIXES:
        if path.endswith(suffix):
            path = path[: -len(suffix)].rstrip("/")
            break
    if path not in ("", "/v1"):
        raise ValueError("Base URL 只能是 http(s)://主机 或 http(s)://主机/v1（评测时凭据代理只转发到这个上游）")
    origin = parts.scheme + "://" + parts.netloc
    return origin if protocol == "anthropic_messages" else origin + "/v1"


def check_models(models):
    if not isinstance(models, list) or not all(isinstance(m, str) for m in models):
        raise ValueError("models 必须是模型名列表")
    result = []
    for name in (m.strip() for m in models):
        if name and name not in result:
            if not MODEL_NAME.fullmatch(name):
                raise ValueError("模型名无效：" + name[:80])
            result.append(name)
    if len(result) > MAX_MODELS:
        raise ValueError(f"一个 Provider 最多 {MAX_MODELS} 个模型")
    return result


def auth_headers(entry, key):
    if entry["auth"] == "x-api-key":
        return {"x-api-key": key}
    return {"Authorization": "Bearer " + key}


def endpoint(entry, path):
    base = entry["base_url"]
    return base + ("/v1" + path if entry["protocol"] == "anthropic_messages" else path)


def call(entry, key, path, body=None, timeout=PROBE_TIMEOUT, opener=None):
    """One request to the provider; (status, parsed JSON or None, text).

    Redirects are not followed, so the key goes to the configured host only."""
    headers = {"Accept": "application/json", "User-Agent": "metacodes-bench", **auth_headers(entry, key)}
    if entry["protocol"] == "anthropic_messages":
        headers["anthropic-version"] = "2023-06-01"
    payload = None
    if body is not None:
        payload = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(endpoint(entry, path), data=payload, headers=headers)
    try:
        with (opener or urllib.request.build_opener(NoRedirect)).open(request, timeout=timeout) as response:
            status, raw = response.status, response.read(4 * 1024 * 1024)
    except urllib.error.HTTPError as exc:
        status, raw = exc.code, exc.read(64 * 1024)
        exc.close()
    text = raw.decode("utf-8", "replace")
    try:
        return status, json.loads(text), text
    except ValueError:
        return status, None, text


def redact(text, key):
    """Error text for display: the key masked, whitespace collapsed."""
    text = (text or "").replace(key, "***") if key else (text or "")
    return " ".join(text.split())[:REPLY_LIMIT]


def redact_reply(text, key):
    """A probe reply as received (whitespace kept: it decides the probe)."""
    return (text.replace(key, "***") if key else text)[:REPLY_LIMIT]


def reply_text(protocol, body):
    """The assistant text of a non-streaming response, or None."""
    if not isinstance(body, dict):
        return None
    if protocol == "anthropic_messages":
        parts = [b.get("text") for b in body.get("content") or [] if isinstance(b, dict) and b.get("type") == "text"]
    elif protocol == "openai_responses":
        if isinstance(body.get("output_text"), str):
            return body["output_text"]
        parts = [c.get("text") for item in body.get("output") or [] if isinstance(item, dict)
                 for c in item.get("content") or [] if isinstance(c, dict) and c.get("type") == "output_text"]
    else:
        choices = body.get("choices") or []
        message = choices[0].get("message") if choices and isinstance(choices[0], dict) else None
        content = message.get("content") if isinstance(message, dict) else None
        if isinstance(content, list):  # content parts
            parts = [c.get("text") for c in content if isinstance(c, dict)]
        else:
            parts = [content]
    parts = [p for p in parts if isinstance(p, str)]
    return "".join(parts) if parts else None


def echoed(reply, expected):
    """Whether the decoded reply text is exactly `expected`: any extra
    character, whitespace included, means the model did not echo verbatim."""
    return reply == expected


def origin(url):
    parts = urllib.parse.urlsplit(url)
    return parts.scheme, parts.netloc.lower()


def loopback(url):
    """Whether `url` reaches the workbench machine itself, which another
    machine would read as itself: localhost names, loopback or unspecified
    addresses (IPv4-mapped too) and names that resolve to them here."""
    from scripts.eval.harbor.bench.egress import names_this_machine
    return names_this_machine(urllib.parse.urlsplit(url).hostname or "")


def native_id(provider_id):
    return NATIVE_PREFIX + provider_id


def probe_request(entry, model, expected):
    prompt = f"Reply with exactly the following string and nothing else: {expected}"
    if entry["protocol"] == "anthropic_messages":
        return "/messages", {"model": model, "max_tokens": 1024, "messages": [{"role": "user", "content": prompt}]}
    if entry["protocol"] == "openai_responses":
        return "/responses", {"model": model, "input": prompt}
    # No token cap: a reasoning model could spend a small one before it answers.
    return "/chat/completions", {"model": model, "messages": [{"role": "user", "content": prompt}]}


class Providers:
    """The private store of imported providers beside workbench.json."""

    def __init__(self, root, *, opener=None, clock=time.monotonic):
        self.root = Path(root)
        self.path = self.root / "providers.json"
        self.lock = threading.Lock()
        self.opener = opener
        self.clock = clock

    # -------------------------------------------------------------- storage
    def entries(self):
        value = data.read_json(self.path) if self.path.exists() else None
        items = (value or {}).get("providers") if isinstance(value, dict) else None
        return [e for e in items or [] if isinstance(e, dict) and PROVIDER_ID.fullmatch(str(e.get("id", "")))]

    def save(self, entries):
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        private_json(self.path, {"schema_version": 1, "providers": entries})

    def change(self, update):
        """Apply `update(entries)` under the store's lock (the page's server
        and the CLI may both write)."""
        with self.lock:
            self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
            with refresh_lock(self.root):
                entries = self.entries()
                result = update(entries)
                self.save(entries)
                return result

    def find(self, provider_id, entries=None):
        entry = next((e for e in (self.entries() if entries is None else entries) if e["id"] == provider_id), None)
        if entry is None:
            raise ValueError("Provider 不存在：" + str(provider_id)[:40])
        return entry

    # -------------------------------------------------------------- views
    @staticmethod
    def public(entry):
        key = entry.get("api_key") or ""
        return {"id": entry["id"], "name": entry.get("name") or entry["id"], "base_url": entry["base_url"],
                "protocol": entry["protocol"], "protocol_label": PROTOCOLS[entry["protocol"]],
                "auth": entry["auth"], "key_hint": ("…" + key[-4:]) if len(key) >= 12 else "已保存",
                "created_at": entry.get("created_at"), "updated_at": entry.get("updated_at"),
                "models": [{"name": m, "id": entry["id"] + "/" + m, "probe": (entry.get("probes") or {}).get(m)}
                           for m in entry.get("models") or []]}

    def listing(self):
        return {"providers": [self.public(e) for e in self.entries()], "protocols": PROTOCOLS, "auths": AUTHS}

    def models(self):
        """Catalog entries: ids and labels only."""
        result = []
        for entry in self.entries():
            for model in entry.get("models") or []:
                probe = (entry.get("probes") or {}).get(model) or {}
                status = "" if not probe else " · 探测通过" if probe.get("ok") else " · 探测失败"
                # Pass/fail only: replies and error bodies stay on the
                # authorized provider page.
                result.append({"id": entry["id"] + "/" + model, "label": (entry.get("name") or entry["id"]) + " / " + model + status,
                               "source": "provider", "provider": entry["id"],
                               "probe": {"ok": bool(probe.get("ok")), "at": probe.get("at")} if probe else None})
        return result

    def owner(self, model_id):
        """The imported provider serving catalog id `model_id`, or None."""
        provider, sep, model = (model_id or "").partition("/")
        if not sep:
            return None
        entry = next((e for e in self.entries() if e["id"] == provider), None)
        return entry if entry and model in (entry.get("models") or []) else None

    # -------------------------------------------------------------- changes
    def add(self, request, reserved=()):
        """Import (or with `replace`, update) one provider; returns its public view.

        `reserved` are provider ids the workbench already lists models under
        (a `--provider-config` setup); an import may not shadow them."""
        allowed = {"id", "name", "base_url", "api_key", "protocol", "auth", "models", "replace", "probe"}
        if not isinstance(request, dict) or set(request) - allowed:
            raise ValueError("只接受 " + "、".join(sorted(allowed - {"probe"})))
        provider_id = str(request.get("id") or "").strip().lower()
        if not PROVIDER_ID.fullmatch(provider_id):
            raise ValueError("Provider 标识只能用小写字母、数字、- 和 _（1–32 个字符，字母或数字开头）")
        if provider_id in RESERVED:
            raise ValueError("Provider 标识 " + provider_id + " 已被 Metask 账号模型占用")
        if provider_id in set(reserved):
            raise ValueError("Provider 标识 " + provider_id + " 已被 --provider-config 中的 Provider 使用，请换一个标识")
        protocol = request.get("protocol") or "openai_chat"
        if protocol not in PROTOCOLS:
            raise ValueError("协议只能是 " + "、".join(PROTOCOLS))
        auth = request.get("auth") or ("x-api-key" if protocol == "anthropic_messages" else "bearer")
        if auth not in AUTHS:
            raise ValueError("认证方式只能是 bearer 或 x-api-key")
        name = request.get("name") or provider_id
        if not isinstance(name, str) or len(name) > 80:
            raise ValueError("显示名称不超过 80 个字符")
        base_url = normalize_base_url(request.get("base_url"), protocol)
        key = request.get("api_key")
        replace = request.get("replace") is True
        existing = next((e for e in self.entries() if e["id"] == provider_id), None)
        if existing and not replace:
            raise ValueError("Provider " + provider_id + " 已存在；要更新请勾选覆盖")
        if key is None or key == "":
            if not existing:
                raise ValueError("请填写 API Key")
            # The saved key is only ever sent where it was given for.
            if origin(existing["base_url"]) != origin(base_url):
                raise ValueError("Base URL 换了主机或端口，请重新填写 API Key（不会把原 Key 发给新地址）")
            key = existing["api_key"]  # updating other fields keeps the saved key
        if not isinstance(key, str) or not key.strip() or len(key) > 4096 or any(c in key for c in "\r\n"):
            raise ValueError("API Key 无效")
        key = key.strip()
        entry = {"id": provider_id, "name": name.strip() or provider_id, "base_url": base_url,
                 "protocol": protocol, "auth": auth, "api_key": key}
        models = check_models(request.get("models") or [])
        if not models:
            models = self.discover(entry)
        entry["models"] = models
        keep = bool(existing) and existing.get("revision") and all(existing.get(k) == entry[k] for k in ROUTE_FIELDS)
        # A probe describes this endpoint and key; changing either voids it,
        # and so does a run queued against the old route (`revision`).
        entry["probes"] = {m: p for m, p in ((existing or {}).get("probes") or {}).items() if m in models} if keep else {}
        entry["revision"] = existing["revision"] if keep else secrets.token_hex(8)
        entry["created_at"] = (existing or {}).get("created_at") or now()
        entry["updated_at"] = now()

        def update(entries):
            current = next((e for e in entries if e["id"] == provider_id), None)
            # The entry was read before the lock (and before a slow model
            # discovery). Another request that rotated the key, edited or
            # removed it meanwhile wins; this one would restore a stale key
            # and revive the old revision.
            if (current is None) != (existing is None) or (
                    current is not None and current.get("revision") != existing.get("revision")):
                raise ValueError("Provider " + provider_id + " 在此期间被其他请求修改或删除，请刷新后重试")
            if current is not None:
                if not replace:
                    raise ValueError("Provider " + provider_id + " 已存在；要更新请勾选覆盖")
                if keep:
                    # A probe that finished during discovery belongs to the
                    # same route; keep the latest ones, not the snapshot's.
                    entry["probes"] = {m: p for m, p in (current.get("probes") or {}).items() if m in models}
                entries[:] = [entry if e["id"] == provider_id else e for e in entries]
            else:
                if len(entries) >= MAX_PROVIDERS:
                    raise ValueError(f"最多导入 {MAX_PROVIDERS} 个 Provider")
                entries.append(entry)
        self.change(update)
        return self.public(entry)

    def remove(self, provider_id):
        def update(entries):
            self.find(provider_id, entries)
            entries[:] = [e for e in entries if e["id"] != provider_id]
        self.change(update)
        return {"id": provider_id, "removed": True}

    def discover(self, entry):
        """The endpoint's `/models` list (used when no model was given)."""
        try:
            status, body, text = call(entry, entry["api_key"], "/models", timeout=20, opener=self.opener)
        except (OSError, ValueError) as exc:
            raise ValueError(f"无法连接 {entry['base_url']} 读取模型列表（{type(exc).__name__}），请检查地址或手动填写模型") from None
        if status != 200 or not isinstance(body, dict) or not isinstance(body.get("data"), list):
            raise ValueError(f"读取模型列表失败（HTTP {status}：{redact(text, entry['api_key'])}），请手动填写模型")
        names = [m.get("id") for m in body["data"] if isinstance(m, dict) and isinstance(m.get("id"), str)]
        models = [n for n in dict.fromkeys(names) if MODEL_NAME.fullmatch(n)][:MAX_MODELS]
        if not models:
            raise ValueError("模型列表为空，请手动填写模型")
        return models

    def probe(self, provider_id, model=None):
        """Ask `model` to echo a fresh random string; record and return the result."""
        entry = self.find(provider_id)
        models = entry.get("models") or []
        model = model or (models[0] if models else None)
        if model not in models:
            raise ValueError("请选择该 Provider 已导入的模型")
        expected = "mc-echo-" + secrets.token_hex(6)
        path, body = probe_request(entry, model, expected)
        started = self.clock()
        result = {"model": model, "at": now(), "expected": expected}
        try:
            status, parsed, text = call(entry, entry["api_key"], path, body, opener=self.opener)
        except (OSError, ValueError) as exc:
            result.update(ok=False, error=f"请求失败：{type(exc).__name__}" + (f"（{redact(str(exc), entry['api_key'])}）" if str(exc) else ""))
        else:
            reply = reply_text(entry["protocol"], parsed) if status == 200 else None
            result["http_status"] = status
            if status != 200:
                result.update(ok=False, error=f"HTTP {status}：{redact(text, entry['api_key'])}")
            elif reply is None:
                result.update(ok=False, error="响应里没有文本回复：" + redact(text, entry["api_key"]))
            else:
                result.update(ok=echoed(reply, expected), reply=redact_reply(reply, entry["api_key"]))
                if not result["ok"]:
                    result["error"] = "回复与发送的字符串不一致"
        result["latency_ms"] = round((self.clock() - started) * 1000)

        def update(entries):
            current = next((e for e in entries if e["id"] == provider_id), None)
            # Kept only while the probed endpoint and key are still the saved ones.
            if current and model in (current.get("models") or []) and current.get("revision") == entry.get("revision"):
                current.setdefault("probes", {})[model] = result
        self.change(update)
        return {"provider": provider_id, **result}

    # -------------------------------------------------------------- runs
    def upgrade(self):
        """Give entries saved before revisions existed one, once, under the
        store's lock (their runs could otherwise never take a key)."""
        if all(e.get("revision") for e in self.entries()):
            return

        def update(entries):
            for entry in entries:
                entry.setdefault("revision", None)
                if not entry["revision"]:
                    entry["revision"] = secrets.token_hex(8)
                    entry["probes"] = {}
        self.change(update)

    def run_route(self, model_id):
        """For a run of catalog id `<provider>/<model>`, from one read of the
        store: the native config, the native model id and the revision the
        worker must find again to take the key."""
        provider_id, _, model = model_id.partition("/")
        self.upgrade()
        entry = self.find(provider_id)
        if model not in (entry.get("models") or []):
            raise ValueError("Provider " + provider_id + " 没有模型 " + model[:80])
        return {"config": self.native_config(entry), "model": native_id(provider_id) + "/" + model,
                "revision": entry.get("revision"), "base_url": entry["base_url"]}

    @staticmethod
    def native_config(entry):
        """A `custom_providers` config: endpoint and model names, the key
        only by variable name."""
        auth = {"kind": "bearer"} if entry["auth"] == "bearer" else {"kind": "api_key_header", "header": "x-api-key"}
        return {"schema_version": 1, "custom_providers": {native_id(entry["id"]): {
            "display_name": entry.get("name") or entry["id"], "auth": auth,
            "env_aliases": [{"name": KEY_ENV, "kind": "api_key", "canonical": True}],
            "channels": [{"id": "default", "base_url": entry["base_url"], "protocol": entry["protocol"]}],
            "models": [{"request_model_id": m} for m in entry.get("models") or []]}}}

    def secret(self, provider_id, revision):
        """The key of `provider_id` as of `revision` (the one its run was
        configured from); refuses once the route changed."""
        entry = self.find(provider_id)
        if not revision or entry.get("revision") != revision:
            raise ValueError("Provider " + provider_id + " 在评测排队期间被修改（地址或 Key 已变），请重新发起评测")
        return entry["api_key"]


def write_config(path, document):
    """A run's generated provider config (no key), private like the store."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    private_json(path, document)
    return str(path)
