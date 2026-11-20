"""Where the Bench evaluation store lives, as validated, secret-free values.

`workbench.json` may name a store:

    {"backend": "sqlite", "path": "/abs/bench.sqlite3"}
    {"backend": "postgres", "dsn": "postgresql://bench@db:5432/bench",
     "password_env": "BENCH_PG_PASSWORD"}

Without one, the store is `<state root>/bench/bench.sqlite3`, beside
`workbench.json`. A PostgreSQL password never enters the configuration: the
DSN is refused when it carries one, and the password comes from the
environment variable named by `password_env` or from libpq's own
PGPASSWORD / ~/.pgpass. Python 3.9, stdlib only.
"""
from __future__ import annotations

import os
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Optional, Union
from urllib.parse import parse_qs, urlsplit

DEFAULT_SQLITE_NAME = "bench.sqlite3"
ENV_NAME = re.compile(r"^[A-Z][A-Z0-9_]*$")
PG_SCHEMES = ("postgres", "postgresql")
PG_URI = re.compile(r"^\s*postgres(?:ql)?://", re.IGNORECASE)
KEYWORD_PASSWORD = re.compile(r"(^|\s)password\s*=", re.IGNORECASE)
# libpq connection keywords (`host=db user=bench dbname=bench`): a target
# naming any of them is a keyword DSN, never a file name.
LIBPQ_KEYWORDS = frozenset((
    "host", "hostaddr", "port", "dbname", "user", "password", "passfile", "require_auth", "channel_binding",
    "connect_timeout", "client_encoding", "options", "application_name", "fallback_application_name",
    "keepalives", "keepalives_idle", "keepalives_interval", "keepalives_count", "tcp_user_timeout",
    "replication", "gssencmode", "sslmode", "sslnegotiation", "requiressl", "sslcompression", "sslcert",
    "sslkey", "sslpassword", "sslcertmode", "sslrootcert", "sslcrl", "sslcrldir", "sslsni",
    "requirepeer", "ssl_min_protocol_version", "ssl_max_protocol_version", "krbsrvname", "gsslib",
    "gssdelegation", "service", "target_session_attrs", "load_balance_hosts"))
KEYWORD = re.compile(r"(?:^|\s)([A-Za-z_]+)\s*=")


class ConfigError(ValueError):
    """The store configuration is malformed or would carry a secret."""


@dataclass(frozen=True)
class SqliteConfig:
    path: Path

    def __post_init__(self) -> None:
        check_sqlite_path(str(self.path))

    @property
    def backend(self) -> str:
        return "sqlite"

    def to_json(self) -> Dict[str, Any]:
        return {"backend": "sqlite", "path": str(self.path)}

    def describe(self) -> Dict[str, Any]:
        return {"backend": "sqlite", "location": str(self.path)}


@dataclass(frozen=True)
class PostgresConfig:
    dsn: str
    password_env: Optional[str] = None

    def __post_init__(self) -> None:
        check_dsn(self.dsn)
        if self.password_env is not None and not ENV_NAME.fullmatch(self.password_env):
            raise ConfigError("password_env must be an upper-case environment variable name")

    @property
    def backend(self) -> str:
        return "postgres"

    def to_json(self) -> Dict[str, Any]:
        value: Dict[str, Any] = {"backend": "postgres", "dsn": self.dsn}
        if self.password_env:
            value["password_env"] = self.password_env
        return value

    def describe(self) -> Dict[str, Any]:
        value: Dict[str, Any] = {"backend": "postgres", "location": self.dsn}
        if self.password_env:
            value["password_env"] = self.password_env
        return value

    def password(self) -> Optional[str]:
        """The password from `password_env`; None leaves it to libpq."""
        if self.password_env is None:
            return None
        value = os.environ.get(self.password_env)
        if not value:
            raise ConfigError(f"environment variable {self.password_env} (PostgreSQL password) is not set")
        return value


StoreConfig = Union[SqliteConfig, PostgresConfig]


def check_dsn(dsn: Any) -> None:
    if not isinstance(dsn, str) or not dsn.strip():
        raise ConfigError("PostgreSQL dsn must be a non-empty string")
    if "://" in dsn:
        parsed = urlsplit(dsn)
        if parsed.scheme not in PG_SCHEMES:
            raise ConfigError("PostgreSQL dsn must start with postgresql://")
        if parsed.password is not None:
            raise ConfigError("remove the password from the dsn; use password_env, PGPASSWORD or ~/.pgpass")
        if "password" in {key.lower() for key in parse_qs(parsed.query)}:
            raise ConfigError("remove the password from the dsn; use password_env, PGPASSWORD or ~/.pgpass")
    elif KEYWORD_PASSWORD.search(dsn):
        raise ConfigError("remove the password from the dsn; use password_env, PGPASSWORD or ~/.pgpass")


def is_postgres_target(text: str) -> bool:
    """A PostgreSQL URI in any letter case, or a libpq keyword DSN."""
    return bool(PG_URI.match(text)) or any(key.lower() in LIBPQ_KEYWORDS for key in KEYWORD.findall(text))


def check_sqlite_path(text: str) -> None:
    """Refuse a SQLite path that is really a connection string, or that
    carries a password: it would become a file name, appear in reports and
    be saved in workbench.json. The message never repeats the value."""
    if is_postgres_target(text) or "://" in text:
        raise ConfigError("this looks like a database connection string, not a SQLite path; "
                          "use a postgresql:// DSN (without a password) for PostgreSQL")
    if "password" in text.lower():
        raise ConfigError("a SQLite path must not contain 'password'; "
                          "for PostgreSQL use a DSN without a password and password_env")


def from_target(text: str, password_env: Optional[str] = None) -> StoreConfig:
    """A command-line target: a PostgreSQL DSN (URI in any letter case, or
    libpq keywords), otherwise a SQLite path."""
    if not isinstance(text, str) or not text:
        raise ConfigError("store target is empty")
    if is_postgres_target(text):
        return PostgresConfig(text, password_env)
    if password_env:
        raise ConfigError("a password environment variable applies only to PostgreSQL")
    check_sqlite_path(text)  # before resolving: a path collapses `://`
    return SqliteConfig(Path(text).expanduser().resolve())


def parse(value: Any, base: Path) -> StoreConfig:
    """Validate a `store` object from workbench.json; relative paths use `base`."""
    if not isinstance(value, dict):
        raise ConfigError("store must be an object")
    backend = value.get("backend")
    if backend == "sqlite":
        if set(value) - {"backend", "path"}:
            raise ConfigError("sqlite store accepts only backend and path")
        path = value.get("path")
        if not isinstance(path, str) or not path:
            raise ConfigError("sqlite store needs a path")
        check_sqlite_path(path)
        resolved = Path(path).expanduser()
        return SqliteConfig((resolved if resolved.is_absolute() else base / resolved).resolve())
    if backend == "postgres":
        if set(value) - {"backend", "dsn", "password_env"}:
            raise ConfigError("postgres store accepts only backend, dsn and password_env")
        return PostgresConfig(value.get("dsn"), value.get("password_env"))
    raise ConfigError("store backend must be sqlite or postgres")


def for_workbench(settings: Dict[str, Any], config_path: Path) -> StoreConfig:
    """The store a workbench uses: its `store` setting or the default file."""
    root = Path(config_path).expanduser().resolve().parent
    if settings.get("store") is None:
        return SqliteConfig(root / DEFAULT_SQLITE_NAME)
    return parse(settings["store"], root)
