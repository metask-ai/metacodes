"""SQLite and PostgreSQL behind one small transaction interface.

SQL is written with `?` placeholders and the `{blob}` type; the PostgreSQL
backend translates both. psycopg 3 is imported only when a PostgreSQL store
is opened, so SQLite users need nothing beyond the standard library.
"""
from __future__ import annotations

import datetime as dt
import json
import re
import shutil
import sqlite3
import tempfile
import threading
import uuid
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Dict, Iterator, List, Optional, Sequence, Tuple

from scripts.eval.harbor.store import schema
from scripts.eval.harbor.store.config import PostgresConfig, SqliteConfig, StoreConfig

PSYCOPG_HINT = "PostgreSQL store needs psycopg 3 in the Python that runs bench: python3 -m pip install 'psycopg[binary]'"
MAX_IDLE = 4
# Arbitrary constant: serializes concurrent schema migrations in PostgreSQL.
PG_MIGRATION_LOCK = 0x62656E6368


class StoreError(ValueError):
    """The store cannot be opened or used as asked."""


def now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


# Text the database must refuse: a lone UTF-16 surrogate (a broken emoji in
# a trajectory, a non-UTF-8 file name decoded with surrogateescape) cannot be
# encoded as UTF-8 by either driver, and PostgreSQL TEXT cannot hold NUL.
_UNSTORABLE = re.compile("[\ud800-\udfff\x00]")


def clean_text(value: str) -> str:
    """`value` as both backends store it: lone surrogates and NUL become
    U+FFFD. Applied to every bound string, so SQLite and PostgreSQL hold the
    same text and a migration between them compares equal."""
    return _UNSTORABLE.sub("\ufffd", value) if _UNSTORABLE.search(value) else value


def json_text(value: Any) -> str:
    """JSON text that is valid UTF-8: a lone surrogate inside a string is
    written as its `\\uXXXX` escape (json.loads reads back the same value);
    NUL is always escaped by json.dumps."""
    text = json.dumps(value, ensure_ascii=False, allow_nan=False)
    if not _SURROGATE.search(text):
        return text
    return _SURROGATE.sub(lambda match: "\\u%04x" % ord(match.group()), text)


_SURROGATE = re.compile("[\ud800-\udfff]")


def _bind(params: Sequence[Any]) -> Tuple[Any, ...]:
    return tuple(clean_text(v) if isinstance(v, str) else v for v in params)


class Tx:
    """One transaction on one connection."""

    def __init__(self, store: "Store", connection: Any):
        self.store = store
        self.connection = connection

    def _sql(self, sql: str) -> str:
        return sql.replace("?", "%s") if self.store.dialect == "postgres" else sql

    def execute(self, sql: str, params: Sequence[Any] = ()) -> int:
        cursor = self.connection.cursor()
        try:
            cursor.execute(self._sql(sql), _bind(params))
            return cursor.rowcount
        finally:
            cursor.close()

    def executemany(self, sql: str, rows: Sequence[Sequence[Any]]) -> None:
        if not rows:
            return
        cursor = self.connection.cursor()
        try:
            cursor.executemany(self._sql(sql), [_bind(row) for row in rows])
        finally:
            cursor.close()

    def query(self, sql: str, params: Sequence[Any] = ()) -> List[Tuple[Any, ...]]:
        cursor = self.connection.cursor()
        try:
            cursor.execute(self._sql(sql), _bind(params))
            return [tuple(row) for row in cursor.fetchall()]
        finally:
            cursor.close()

    def one(self, sql: str, params: Sequence[Any] = ()) -> Optional[Tuple[Any, ...]]:
        rows = self.query(sql, params)
        return rows[0] if rows else None

    def stream(self, sql: str, params: Sequence[Any] = (), size: int = 256) -> Iterator[List[Tuple[Any, ...]]]:
        """Batches of rows without holding the whole result in memory."""
        if self.store.dialect == "postgres":
            cursor = self.connection.cursor(name="bench_" + uuid.uuid4().hex)
        else:
            cursor = self.connection.cursor()
        try:
            cursor.execute(self._sql(sql), _bind(params))
            while True:
                rows = cursor.fetchmany(size)
                if not rows:
                    return
                yield [tuple(row) for row in rows]
        finally:
            cursor.close()


class Store:
    """A pooled connection to one evaluation database at the latest schema."""

    def __init__(self, config: StoreConfig, *, ephemeral_dir: Optional[Path] = None):
        self.config = config
        self.dialect = config.backend
        self._idle: List[Any] = []
        self._lock = threading.Lock()
        self._ephemeral_dir = ephemeral_dir
        self._psycopg = None
        if isinstance(config, PostgresConfig):
            try:
                import psycopg  # noqa: F401 - optional dependency, PostgreSQL only
            except ImportError:
                raise StoreError(PSYCOPG_HINT) from None
            self._psycopg = psycopg
        else:
            config.path.parent.mkdir(parents=True, exist_ok=True)
        try:
            self.schema_version = self._migrate()
        except sqlite3.Error as exc:
            raise StoreError(f"cannot open SQLite store {config.path}: {exc}") from None

    # ------------------------------------------------------------ connections

    def _connect(self) -> Any:
        if isinstance(self.config, SqliteConfig):
            connection = sqlite3.connect(str(self.config.path), timeout=60, isolation_level=None,
                                         check_same_thread=False)
            connection.execute("PRAGMA foreign_keys = ON")
            connection.execute("PRAGMA journal_mode = WAL")
            connection.execute("PRAGMA synchronous = NORMAL")
            return connection
        kwargs: Dict[str, Any] = {"autocommit": True}
        password = self.config.password()
        if password is not None:
            kwargs["password"] = password
        try:
            return self._psycopg.connect(self.config.dsn, **kwargs)
        except self._psycopg.Error as exc:
            # libpq's message names host/user, never the password.
            raise StoreError("cannot connect to PostgreSQL: " + str(exc).strip()) from None

    @contextmanager
    def _connection(self) -> Iterator[Any]:
        with self._lock:
            connection = self._idle.pop() if self._idle else None
        if connection is None:
            connection = self._connect()
        healthy = False
        try:
            yield connection
            healthy = True
        finally:
            if healthy:
                with self._lock:
                    if len(self._idle) < MAX_IDLE:
                        self._idle.append(connection)
                        connection = None
            if connection is not None:
                try:
                    connection.close()
                except Exception:
                    pass

    @contextmanager
    def transaction(self, write: bool = True, snapshot: bool = False) -> Iterator[Tx]:
        """A transaction; `write` takes SQLite's write lock up front and
        `snapshot` gives a repeatable read view for multi-statement reads."""
        with self._connection() as connection:
            if self.dialect == "sqlite":
                connection.execute("BEGIN IMMEDIATE" if write else "BEGIN")
                try:
                    yield Tx(self, connection)
                except BaseException:
                    if connection.in_transaction:
                        connection.execute("ROLLBACK")
                    raise
                connection.execute("COMMIT")
            else:
                with connection.transaction():
                    if snapshot and not write:  # first statement of the transaction
                        connection.execute("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY")
                    yield Tx(self, connection)

    def read(self) -> Any:
        return self.transaction(write=False, snapshot=True)

    def close(self) -> None:
        with self._lock:
            idle, self._idle = self._idle, []
        for connection in idle:
            try:
                connection.close()
            except Exception:
                pass
        if self._ephemeral_dir is not None:
            shutil.rmtree(self._ephemeral_dir, ignore_errors=True)
            self._ephemeral_dir = None

    # ----------------------------------------------------------------- schema

    def _migrate(self) -> int:
        with self.transaction() as tx:
            if self.dialect == "postgres":
                tx.execute("SELECT pg_advisory_xact_lock(?)", (PG_MIGRATION_LOCK,))
            tx.execute("CREATE TABLE IF NOT EXISTS schema_migrations ("
                       "version BIGINT PRIMARY KEY, description TEXT NOT NULL, applied_at TEXT NOT NULL)")
            row = tx.one("SELECT MAX(version) FROM schema_migrations")
            current = int(row[0]) if row and row[0] is not None else 0
            if current > schema.LATEST:
                raise StoreError(f"store schema v{current} is newer than this metacodes (v{schema.LATEST}); upgrade metacodes")
            for version, description, statements in schema.MIGRATIONS:
                if version <= current:
                    continue
                for statement in statements:
                    tx.execute(schema.render(statement, self.dialect))
                tx.execute("INSERT INTO schema_migrations (version, description, applied_at) VALUES (?, ?, ?)",
                           (version, description, now()))
                if version == 1:
                    tx.execute("INSERT INTO store_meta (key, value) VALUES (?, ?)", ("store_id", uuid.uuid4().hex))
                current = version
            return current

    # ---------------------------------------------------------------- helpers

    def describe(self) -> Dict[str, Any]:
        return {**self.config.describe(), "schema_version": self.schema_version,
                "format": "SQLite" if self.dialect == "sqlite" else "PostgreSQL"}

    def counts(self) -> Dict[str, int]:
        with self.read() as tx:
            return {table: int(tx.one(f"SELECT COUNT(*) FROM {table}")[0]) for table, _ in schema.TABLES}

    def identity(self) -> str:
        with self.read() as tx:
            return tx.one("SELECT value FROM store_meta WHERE key = 'store_id'")[0]

    def same_database(self, other: "Store") -> bool:
        if self.dialect != other.dialect:
            return False
        if self.dialect == "sqlite":
            return self.config.path == other.config.path
        return self.identity() == other.identity()


def open_store(config: StoreConfig) -> Store:
    return Store(config)


def open_ephemeral() -> Store:
    """A private SQLite store removed on close (read-only viewer mode)."""
    directory = Path(tempfile.mkdtemp(prefix="bench-store-"))
    return Store(SqliteConfig(directory / "bench.sqlite3"), ephemeral_dir=directory)


def blob_bytes(value: Any) -> bytes:
    return bytes(value) if isinstance(value, (memoryview, bytearray)) else value
