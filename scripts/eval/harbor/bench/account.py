"""Metask login -> account groups -> model-specific benchmark credentials.

Keys stay in memory. Only model names and non-secret key ids enter the
workbench catalog/specs; workers resolve the chosen route afresh.
"""
from __future__ import annotations

import concurrent.futures
import contextlib
from dataclasses import dataclass
import hashlib
import json
import os
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

GATEWAY = "https://napi.metask-ai.com"
SITE = "https://www.metask-ai.com"


def origin_url(value):
    origin = urllib.parse.urlsplit(value)
    if origin.scheme not in ("https", "http") or not origin.hostname or origin.path or origin.query or origin.fragment or origin.username or origin.password:
        raise ValueError("Metask 账号网关必须是 http(s) origin")
    return value


@dataclass(frozen=True)
class SessionLogin:
    """The current CLI's OAuth store, separate from legacy auth.json."""
    path: Path
    site: str

    def read(self):
        try:
            doc = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            raise ValueError("Metask 会话不可用，请重新运行 metacodes login") from None
        if (not isinstance(doc, dict) or type(doc.get("expires_at")) is not int
                or any(not isinstance(doc.get(k), str) or not doc[k] for k in ("access_token", "refresh_token", "gateway_url"))):
            raise ValueError("Metask 会话格式无效，请重新运行 metacodes login")
        origin_url(doc["gateway_url"])
        return doc

    def bearer(self, request, stale=None):
        return self.access(request, stale)["access_token"]

    def access(self, request, stale=None, margin=300):
        """The current access token and its expiry, refreshed when it expires
        within `margin` seconds (or, with `stale`, when it is still the one
        the gateway rejected). Re-read under the lock: another process may
        have rotated the refresh token, which must not be reused."""
        with refresh_lock(self.path.parent):
            current = self.read()
            if stale is not None and current["access_token"] != stale:
                return current
            if stale is None and current["expires_at"] > time.time() + margin:
                return current
            token = request("/api/oauth/token", origin=self.site, json_body={
                "grant_type": "refresh_token", "client_id": "metacodes",
                "refresh_token": current["refresh_token"]})
            if (not isinstance(token, dict) or type(token.get("expires_in")) is not int or token["expires_in"] <= 0
                    or any(not isinstance(token.get(k), str) or not token[k] for k in ("access_token", "refresh_token"))):
                raise ValueError("Metask 登录刷新失败，请重新运行 metacodes login")
            latest = self.read()
            if latest["refresh_token"] != current["refresh_token"]:
                return latest
            updated = {**latest, **{k: token[k] for k in (
                "access_token", "refresh_token", "token_type", "scope", "gateway_url", "models_url", "client_name") if k in token},
                "expires_at": int(time.time()) + token["expires_in"]}
            origin_url(updated["gateway_url"])
            private_json(self.path, updated)
            return updated


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class AccountHTTPError(ValueError):
    def __init__(self, status):
        self.status = status
        super().__init__(f"Metask 账号请求失败（HTTP {status}），请检查登录状态")


@contextlib.contextmanager
def refresh_lock(state_dir):
    # Catalog reads and workers are separate processes. Serialize refreshes
    # so a rotated refresh token cannot invalidate another Bench worker.
    fd = os.open(state_dir / "bench-oauth.lock", os.O_RDWR | os.O_CREAT, 0o600)
    try:
        if os.name == "nt":
            import msvcrt
            os.lseek(fd, 0, os.SEEK_SET)
            msvcrt.locking(fd, msvcrt.LK_LOCK, 1)
        else:
            import fcntl
            fcntl.flock(fd, fcntl.LOCK_EX)
        try:
            yield
        finally:
            if os.name == "nt":
                os.lseek(fd, 0, os.SEEK_SET)
                msvcrt.locking(fd, msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)


def private_json(path, doc):
    fd, temporary = tempfile.mkstemp(prefix=".bench-oauth-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as out:
            json.dump(doc, out, ensure_ascii=False)
            out.flush()
            os.fsync(out.fileno())
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def items(document):
    if isinstance(document, list):
        return document
    if isinstance(document, dict):
        for name in ("data", "api_keys", "keys", "items"):
            if name in document:
                found = items(document[name])
                if found is not None:
                    return found
    return None


class Account:
    def __init__(self, state_dir, gateway=None):
        if not state_dir:
            raise ValueError("请设置 --account-state-dir，指向已登录 metacodes 的状态目录")
        self.state_dir = Path(state_dir).expanduser().resolve()
        self.auth_path = Path(os.environ.get("METACODES_AUTH_FILE") or self.state_dir / "auth.json")
        session_path = Path(os.environ.get("METACODES_OAUTH_DIR") or self.state_dir / "oauth") / "metask.json"
        self.session = SessionLogin(session_path, origin_url(os.environ.get("METASK_SITE_URL", SITE).rstrip("/"))) if session_path.exists() else None
        self.gateway_override = origin_url(gateway.rstrip("/")) if gateway else None

    @property
    def gateway(self):
        return self.gateway_override or (self.session.read()["gateway_url"] if self.session else GATEWAY)

    def fingerprint(self):
        def stamp(path):
            try:
                stat = path.stat()
                return stat.st_mtime_ns, stat.st_size
            except OSError:
                return None
        return (str(self.state_dir), self.gateway, stamp(self.auth_path),
                (str(self.session.path), stamp(self.session.path)) if self.session else None)

    def login(self):
        try:
            doc = json.loads(self.auth_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            if self.session:
                self.session.read()
                return {}
            raise ValueError("执行机器尚未登录 Metask，请在同一状态目录运行 metacodes login") from None
        if self.session and isinstance(doc, dict):
            self.session.read()
            return doc
        if not isinstance(doc, dict) or not (doc.get("api_key") or isinstance(doc.get("oauth"), dict)):
            raise ValueError("执行机器尚未登录 Metask，请运行 metacodes login")
        return doc

    def request(self, path, bearer=None, form=None, *, origin=None, json_body=None):
        headers = {"Accept": "application/json"}
        if bearer:
            headers["Authorization"] = "Bearer " + bearer
        body = None
        if form is not None:
            body = urllib.parse.urlencode(form).encode()
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        if json_body is not None:
            body = json.dumps(json_body).encode()
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request((origin or self.gateway) + path, data=body, headers=headers)
        try:
            with urllib.request.build_opener(NoRedirect).open(request, timeout=10) as response:
                body = response.read(8 * 1024 * 1024 + 1)
                if len(body) > 8 * 1024 * 1024:
                    raise ValueError("catalog too large")
                return json.loads(body)
        except urllib.error.HTTPError as exc:
            exc.close()
            raise AccountHTTPError(exc.code) from None
        except (OSError, ValueError):
            raise ValueError("无法读取 Metask 账号目录，请检查执行机器的网络和登录状态") from None

    def oauth_bearer(self, stale=None):
        if self.session:
            return self.session.bearer(self.request, stale)
        with refresh_lock(self.state_dir):
            login = self.login()
            oauth = login.get("oauth") or {}
            access = oauth.get("access_token")
            if not isinstance(access, str) or not access:
                raise ValueError("查看全部模型组需要 Metask 账号登录，请运行 metacodes login")
            if stale is not None and access != stale:
                return access
            if stale is None and oauth.get("expires_at", 0) > time.time() + 300:
                return access
            refresh = oauth.get("refresh_token")
            if not isinstance(refresh, str) or not refresh:
                raise ValueError("Metask 登录已过期，请重新运行 metacodes login")
            token = self.request("/oauth/token", form={"grant_type": "refresh_token",
                                                       "client_id": "metacode-cli", "refresh_token": refresh})
            if not isinstance(token, dict) or not isinstance(token.get("access_token"), str) or not token["access_token"] or type(token.get("expires_in")) is not int or token["expires_in"] <= 0:
                raise ValueError("Metask 登录刷新失败，请重新运行 metacodes login")
            # Preserve key/model preferences saved by another CLI meanwhile.
            current = self.login()
            latest = current.get("oauth") or {}
            if latest.get("refresh_token") != refresh:
                return latest["access_token"]
            updated = {**latest, "access_token": token["access_token"],
                       "refresh_token": token.get("refresh_token") or refresh,
                       "expires_at": int(time.time()) + token["expires_in"],
                       "token_type": token.get("token_type", "Bearer")}
            for name in ("scope", "account_id", "profile"):
                if name in token:
                    updated[name] = token[name]
            current["oauth"] = updated
            private_json(self.auth_path, current)
            return updated["access_token"]

    def session_access(self, stale=None, margin=300):
        """(access token, expires_at) of the current CLI session login."""
        if not self.session:
            raise ValueError("当前登录没有可刷新的 Metask 会话")
        doc = self.session.access(self.request, stale, margin)
        return doc["access_token"], doc["expires_at"]

    def keys(self):
        login = self.login()
        if self.session:
            return [{"id": "session", "secret": self.oauth_bearer(), "group": "Metask", "group_id": ""}]
        if not login.get("oauth"):
            key = login.get("api_key")
            if not isinstance(key, str) or not key.strip():
                raise ValueError("执行机器尚未登录 Metask，请运行 metacodes login")
            return [{"id": "current", "secret": key.strip(), "group": "", "group_id": ""}]
        bearer = self.oauth_bearer()
        result = []
        for page in range(1, 101):
            path = f"/api/v1/keys?page={page}&page_size=100"
            try:
                document = self.request(path, bearer)
            except AccountHTTPError as exc:
                if exc.status != 401:
                    raise
                bearer = self.oauth_bearer(stale=bearer)
                document = self.request(path, bearer)
            rows = items(document)
            if rows is None:
                raise ValueError("Metask 账号 Key 目录格式无效")
            for row in rows:
                if not isinstance(row, dict) or str(row.get("status", "active")).lower() not in ("active", "enabled", "available"):
                    continue
                secret = next((row[k] for k in ("api_key", "key", "token", "secret", "value") if isinstance(row.get(k), str) and row[k]), None)
                if not secret:
                    continue
                key_id = str(row.get("id") or row.get("uuid") or hashlib.sha256(secret.encode()).hexdigest()[:24])
                group = next((row[k] for k in ("group_name", "model_group", "profile", "team", "group") if row.get(k)), "")
                group_id = row.get("group_id")
                if isinstance(group, dict):
                    group_id = group_id or group.get("id")
                    group = group.get("name") or group.get("label") or str(group.get("id", ""))
                result.append({"id": key_id, "secret": secret, "group": str(group), "group_id": str(group_id or "")})
            if len(rows) < 100:
                break
        else:
            raise ValueError("Metask 账号 Key 目录超过分页限制")
        result.sort(key=lambda key: key["secret"] != login.get("api_key"))
        return result

    def model_directory(self, key, any_endpoint=False):
        """The models a key serves; Anthropic Messages capable ones unless
        `any_endpoint` (an LLM judge calls Chat Completions)."""
        try:
            document = self.request("/v1/models", key["secret"])
        except AccountHTTPError as exc:
            if not self.session or exc.status != 401:
                raise
            document = self.request("/v1/models", self.oauth_bearer(stale=key["secret"]))
        rows = document.get("data") if isinstance(document, dict) else None
        if not isinstance(rows, list):
            raise ValueError("Metask 模型目录格式无效")
        def messages_supported(model):
            value = model
            for name in ("capabilities", "endpoints", "messages"):
                value = value.get(name) if isinstance(value, dict) else None
            return not isinstance(value, dict) or value.get("supported") is not False
        return [m for m in rows if isinstance(m, dict) and isinstance(m.get("id"), str) and m["id"]
                and (any_endpoint or messages_supported(m))]

    def credential(self, model=None, key_id=None, any_endpoint=False):
        for key in self.keys():
            if key_id is not None and key["id"] != key_id:
                continue
            name = model.removeprefix("metask/") if model else None
            if name is None or any(m["id"] == name for m in self.model_directory(key, any_endpoint)):
                return self.oauth_bearer() if self.session else key["secret"]
        raise ValueError("所选模型的账号 Key 已不可用，请刷新模型目录后重试")

    def catalog(self):
        login = self.login()
        keys = self.keys()
        models, routes, warnings = {}, {}, []
        if not self.session and not login.get("oauth"):
            warnings.append("当前为 Key 登录，仅显示此 Key 的模型；完成 Metask 账号登录后可读取全部模型组")
        groups = []
        if not self.session and login.get("oauth"):
            try:
                directory = items(self.request("/api/v1/groups/available", self.oauth_bearer()))
                if directory is None:
                    raise ValueError("invalid groups")
                for group in directory:
                    if not isinstance(group, dict) or group.get("status", "active") != "active":
                        continue
                    gid, name = str(group.get("id", "")), str(group.get("name", ""))
                    configured = any(key["group_id"] == gid or (name and key["group"] == name) for key in keys)
                    groups.append({"id": gid, "name": name, "configured": configured})
            except ValueError:
                warnings.append("暂时无法读取其他可选模型组；已配置 Key 的模型仍可选择")

        def probe(key):
            try:
                return self.model_directory(key)
            except ValueError:
                return None

        available = 0
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            for key, directory in zip(keys, pool.map(probe, keys)):
                if directory is None:
                    warnings.append("一个账号模型组的目录暂时不可用，刷新后重试")
                    continue
                available += 1
                for item in directory:
                    model_id = "metask/" + item["id"]
                    if model_id not in models:
                        models[model_id] = {"id": model_id, "label": item.get("display_name") or item["id"]}
                        routes[model_id] = key["id"]
        if not models:
            raise ValueError("Metask 账号没有可读取的模型目录，请检查模型组和登录状态")
        default = "metask/" + str(login.get("selected_model") or "")
        if default not in models:
            default = next(iter(models))
        effort = login.get("reasoning_effort")
        return {"models": list(models.values()), "routes": routes, "default_model": default,
                "account_groups": groups,
                "warnings": warnings, "account_summary": {"groups": len(keys), "available_groups": available, "models": len(models)},
                "reasoning_effort": effort if effort in ("none", "low", "medium", "high", "xhigh", "max") else None}
