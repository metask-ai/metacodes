"""The real credential behind a Bench run's relay, refreshed on this host.

Task containers hold only a run-scoped placeholder (profiling.placeholder);
the relay swaps it for `current()` on every request. A Metask session login
expires after about an hour, so `SessionCredential` refreshes it here, on the
machine that owns the refresh token:

- proactively, once less than `refresh_margin()` seconds remain (a request
  or the background `keep` loop notices first);
- once on demand when the gateway rejected the current token (`refresh`).

Refreshes go through `Account.session_access`, which holds the state
directory's refresh lock, re-reads `oauth/metask.json` and persists the
rotated pair atomically, so the CLI and catalog reads sharing that state stay
consistent and a rotated refresh token is never reused. Listeners (the SSH
executor's push) receive each new access token. Nothing here writes a token
to a file, argv or log.
"""
from __future__ import annotations

import datetime as dt
import os
import threading
import time

from scripts.eval.harbor.profiling import StaticCredential
from scripts.eval.harbor.bench.account import Account, AccountHTTPError, SessionGatewayChanged

# Refresh once an access token has less than this left (~45 minutes into a
# one-hour token). METACODES_BENCH_REFRESH_MARGIN overrides it (tests).
REFRESH_MARGIN = 15 * 60
# How often the background loop checks the expiry.
CHECK_INTERVAL = 30
# After a transient refresh failure (network, 5xx), wait this long before the
# next attempt; the old token stays in use until it expires.
RETRY_AFTER = 30
EXPIRED_MESSAGE = "Metask 登录已失效，请重新登录（metacodes login）后再运行评测"
UNREACHABLE_MESSAGE = "Metask 登录刷新失败且令牌已过期，请检查网络或重新登录后再运行评测"


def refresh_margin():
    value = os.environ.get("METACODES_BENCH_REFRESH_MARGIN")
    return float(value) if value else REFRESH_MARGIN


def check_interval():
    value = os.environ.get("METACODES_BENCH_REFRESH_INTERVAL")
    return float(value) if value else CHECK_INTERVAL


def iso(stamp):
    return dt.datetime.fromtimestamp(stamp, dt.timezone.utc).isoformat()


class SessionCredential:
    """A refreshing Metask session access token, for one run."""
    refreshing = True

    def __init__(self, account, *, margin=None, clock=time.time):
        self.account = account
        self.margin = refresh_margin() if margin is None else margin
        self.clock = clock
        self.lock = threading.Lock()
        self.token, self.expires_at = account.session_access(margin=self.margin)
        self.refresh_count = 0
        self.last_refresh_at = None
        self.error = None
        self.failed = False
        self.retry_at = 0.0
        self.listeners = []
        self.stopped = threading.Event()

    def current(self):
        """The token to use now; None once the login cannot be refreshed."""
        with self.lock:
            if self.failed:
                return None
            now = self.clock()
            if now < self.expires_at - self.margin:
                return self.token
            if now < self.retry_at:  # backing off after a transient failure
                return self.token if now < self.expires_at else self.fail(UNREACHABLE_MESSAGE)
        return self.update(None)

    def refresh(self, stale):
        return self.update(stale)

    def update(self, stale):
        with self.lock:
            if self.failed:
                return None
            if stale is not None and stale != self.token:
                return self.token  # another request already refreshed
            if stale is None and self.clock() < self.expires_at - self.margin:
                return self.token
            try:
                token, expires_at = self.account.session_access(stale=stale, margin=self.margin)
            except SessionGatewayChanged as exc:
                return self.fail(str(exc))
            except AccountHTTPError as exc:
                if 400 <= exc.status < 500 and exc.status not in (408, 429):
                    return self.fail(EXPIRED_MESSAGE)
                return self.transient()
            except ValueError:
                return self.transient()
            self.error = None
            self.retry_at = 0.0
            changed = token != self.token
            self.token, self.expires_at = token, expires_at
            if changed:
                self.refresh_count += 1
                self.last_refresh_at = iso(self.clock())
                # Under the lock, so pushes arrive in refresh order.
                for listener in self.listeners:
                    try:
                        listener(token)
                    except Exception:  # a failed push keeps the old token remotely
                        pass
            return token

    def fail(self, message):
        self.failed = True
        self.error = message
        return None

    def transient(self):
        # Keep the old token until it expires; then the run cannot continue.
        if self.clock() >= self.expires_at:
            return self.fail(UNREACHABLE_MESSAGE)
        self.error = "Metask 登录刷新暂时失败，将重试"
        self.retry_at = self.clock() + RETRY_AFTER
        return self.token

    def subscribe(self, listener):
        self.listeners.append(listener)

    def keep(self, interval=None):
        """Refresh in the background, also when no request needs it (the
        SSH executor's relay depends on the pushed tokens)."""
        interval = check_interval() if interval is None else interval

        def loop():
            while not self.stopped.wait(interval):
                if self.current() is None:
                    return
        threading.Thread(target=loop, daemon=True).start()
        return self

    def stop(self):
        self.stopped.set()

    def status(self):
        with self.lock:
            return {"refreshing": True, "refresh_count": self.refresh_count,
                    "last_refresh_at": self.last_refresh_at, "expires_at": iso(self.expires_at),
                    "error": self.error}


def for_run(spec, env):
    """(credential source, account gateway or None) for one launch.

    A Metask session login refreshes; a legacy account group key, a
    provider key and an imported provider's key do not expire and stay fixed."""
    if spec.get("auth_mode") == "metask":
        account = Account(spec.get("account_state_dir"), spec.get("account_gateway"))
        # Checks that the chosen group still provides this model.
        secret = account.credential(spec["model"], key_id=spec.get("account_key_id"))
        source = SessionCredential(account) if account.session else StaticCredential(secret)
        return source, account.gateway
    if spec.get("imported_provider"):
        # A provider imported by URL and key: the key is in the private
        # store, taken only from the revision the run's config came from.
        from scripts.eval.harbor.bench.providers import Providers
        store = Providers(spec["providers_root"])
        return StaticCredential(store.secret(spec["imported_provider"], spec.get("imported_revision"))), None
    secret = env.get(spec["key_env"])
    if not secret:
        raise ValueError("执行服务缺少环境变量 " + spec["key_env"])
    return StaticCredential(secret), None


def for_judge(spec, source):
    """The upstream credential of the run's LLM judge (Metask only).

    None means the run's own source serves it (a session login covers every
    model, and so does a group key whose directory lists the judge); else
    the fixed key of the account group that lists the judge model. Raises
    a user-facing ValueError when no group of the account lists it."""
    model = spec["judge"]["model"]
    account = (source.account if isinstance(source, SessionCredential)
               else Account(spec.get("account_state_dir"), spec.get("account_gateway")))
    try:
        secret = account.credential(model, any_endpoint=True)
    except ValueError as exc:
        raise ValueError(f"评委模型 {model} 不在当前 Metask 账号的模型目录中（{exc}）；"
                         f"请在 workbench.json 的 judges.{spec.get('suite') or '<评测集>'}.model 换成可用模型") from None
    if account.session or secret == source.current():
        return None
    return secret
