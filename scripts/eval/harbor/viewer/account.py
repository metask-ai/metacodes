"""Metask login -> account groups -> model-specific benchmark credentials.

Keys stay in memory. Only model names and non-secret key ids enter the
workbench catalog/specs; workers resolve the chosen route afresh.
"""
from __future__ import annotations

import concurrent.futures
import contextlib
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
            if not os.fstat(fd).st_size:
                os.write(fd, b"\0")
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
        self.gateway = (gateway or GATEWAY).rstrip("/")
        origin = urllib.parse.urlsplit(self.gateway)
        if origin.scheme not in ("https", "http") or not origin.hostname or origin.path or origin.query or origin.fragment or origin.username or origin.password:
            raise ValueError("Metask 账号网关必须是 http(s) origin")

    def login(self):
        try:
            doc = json.loads((self.state_dir / "auth.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            raise ValueError("执行机器尚未登录 Metask，请在同一状态目录运行 metacodes login") from None
        if not isinstance(doc, dict) or not (doc.get("api_key") or isinstance(doc.get("oauth"), dict)):
            raise ValueError("执行机器尚未登录 Metask，请运行 metacodes login")
        return doc

    def request(self, path, bearer=None, form=None):
        headers = {"Accept": "application/json"}
        if bearer:
            headers["Authorization"] = "Bearer " + bearer
        body = None
        if form is not None:
            body = urllib.parse.urlencode(form).encode()
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        request = urllib.request.Request(self.gateway + path, data=body, headers=headers)
        try:
            with urllib.request.build_opener(NoRedirect).open(request, timeout=10) as response:
                body = response.read(8 * 1024 * 1024 + 1)
                if len(body) > 8 * 1024 * 1024:
                    raise ValueError("catalog too large")
                return json.loads(body)
        except urllib.error.HTTPError as exc:
            raise AccountHTTPError(exc.code) from None
        except (OSError, ValueError):
            raise ValueError("无法读取 Metask 账号目录，请检查执行机器的网络和登录状态") from None

    def oauth_bearer(self, stale=None):
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
            private_json(self.state_dir / "auth.json", current)
            return updated["access_token"]

    def keys(self):
        login = self.login()
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

    def model_directory(self, key):
        document = self.request("/v1/models", key["secret"])
        rows = document.get("data") if isinstance(document, dict) else None
        if not isinstance(rows, list):
            raise ValueError("Metask 模型目录格式无效")
        return [m for m in rows if isinstance(m, dict) and isinstance(m.get("id"), str) and m["id"]]

    def credential(self, model=None, key_id=None):
        for key in self.keys():
            if key_id is not None and key["id"] != key_id:
                continue
            name = model.removeprefix("metask/") if model else None
            if name is None or any(m["id"] == name for m in self.model_directory(key)):
                return key["secret"]
        raise ValueError("所选模型的账号 Key 已不可用，请刷新模型目录后重试")

    def catalog(self):
        login = self.login()
        keys = self.keys()
        models, routes, warnings = {}, {}, []
        if not login.get("oauth"):
            warnings.append("当前为 Key 登录，仅显示此 Key 的模型；完成 Metask 账号登录后可读取全部模型组")
        groups = []
        if login.get("oauth"):
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
                "reasoning_effort": effort if effort in ("low", "medium", "high", "xhigh") else None}
