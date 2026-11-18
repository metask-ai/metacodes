"""Copy a whole evaluation store to another backend and prove the copy.

The copy reads the source in one snapshot and writes the target in committed
batches, so an interrupted migration resumes where it stopped. Rows are
compared by primary key across the two backends: a row already present and
identical is skipped, and a row present with different content stops the
migration before anything is written; nothing in a target is overwritten.
Verification then re-reads every source row from the target and re-hashes
every blob the target holds for it.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Sequence, Tuple

from scripts.eval.harbor.store import ingest, schema
from scripts.eval.harbor.store.backend import Store, StoreError, Tx, blob_bytes

BATCH = 200
BLOB_BATCH = 32


class MigrationConflict(StoreError):
    """The target holds a different row under the same key."""


@dataclass
class TableReport:
    source: int = 0
    copied: int = 0
    already_present: int = 0
    verified: int = 0
    target_total: int = 0


@dataclass
class Report:
    source: Dict[str, Any]
    target: Dict[str, Any]
    tables: Dict[str, TableReport] = field(default_factory=dict)

    def to_json(self) -> Dict[str, Any]:
        return {"source": self.source, "target": self.target,
                "tables": {name: table.__dict__ for name, table in self.tables.items()}}


def _normal(value: Any) -> Any:
    """A backend-neutral value: SQLite stores booleans as integers and both
    store DOUBLE PRECISION as IEEE doubles."""
    value = blob_bytes(value)
    if isinstance(value, bool):
        return float(value)
    if isinstance(value, (int, float)):
        return float(value)
    return value


def _comparable(table: str, row: Sequence[Any]) -> Tuple[Any, ...]:
    columns = schema.COLUMNS[table]
    # Blob content is compared by hash during verification, not byte by byte here.
    return tuple(_normal(v) for c, v in zip(columns, row) if not (table == "blobs" and c == "content"))


def _key(table: str, row: Sequence[Any]) -> Tuple[Any, ...]:
    keys = dict(schema.TABLES)[table]
    columns = schema.COLUMNS[table]
    return tuple(row[columns.index(k)] for k in keys)


def _fetch(tx: Tx, table: str, keys: List[Tuple[Any, ...]], columns: Sequence[str]) -> Dict[Tuple[Any, ...], Tuple[Any, ...]]:
    names = dict(schema.TABLES)[table]
    if not keys:
        return {}
    clause = " OR ".join("(" + " AND ".join(f"{k} = ?" for k in names) + ")" for _ in keys)
    params = [value for key in keys for value in key]
    found = {}
    for row in tx.query(f"SELECT {', '.join(columns)} FROM {table} WHERE {clause}", params):
        found[tuple(row[columns.index(k)] for k in names)] = row
    return found


def _source_batches(tx: Tx, table: str):
    columns = schema.COLUMNS[table]
    order = ", ".join(dict(schema.TABLES)[table])
    size = BLOB_BATCH if table == "blobs" else BATCH
    return tx.stream(f"SELECT {', '.join(columns)} FROM {table} ORDER BY {order}", (), size)


def _for_insert(table: str, row: Sequence[Any]) -> Tuple[Any, ...]:
    booleans = schema.BOOLEANS.get(table, ())
    columns = schema.COLUMNS[table]
    return tuple(bool(v) if c in booleans and v is not None else blob_bytes(v) for c, v in zip(columns, row))


def _check_blob(row: Sequence[Any]) -> None:
    digest, size, encoding, content = row
    raw = ingest.decode(encoding, content)
    if ingest.sha256(raw) != digest or len(raw) != int(size):
        raise StoreError(f"blob {digest} does not match its content hash")


def _pass(source: Store, target: Store, report: Report, write: bool,
          progress: Callable[[str], None]) -> None:
    with source.read() as source_tx:
        for table, _ in schema.TABLES:
            columns = schema.COLUMNS[table]
            insert = ingest._insert_sql(table)
            entry = report.tables.setdefault(table, TableReport())
            count = 0
            for batch in _source_batches(source_tx, table):
                keys = [_key(table, row) for row in batch]
                with (target.transaction() if write else target.read()) as target_tx:
                    present = _fetch(target_tx, table, keys,
                                     columns if table != "blobs" else ("sha256", "size", "encoding"))
                    missing = []
                    for key, row in zip(keys, batch):
                        if key in present:
                            if _comparable(table, present[key]) != _comparable(table, row[:len(present[key])]):
                                raise MigrationConflict(
                                    f"target already has a different {table} row {key!r}; "
                                    "refusing to overwrite it (choose an empty target)")
                            if write:
                                entry.already_present += 1
                        else:
                            missing.append(row)
                    if write and missing:
                        if table == "blobs":
                            for row in missing:
                                _check_blob(row)
                        target_tx.executemany(insert, [_for_insert(table, row) for row in missing])
                        entry.copied += len(missing)
                count += len(batch)
            entry.source = count
            if write:
                progress(f"{table}: {entry.copied} copied, {entry.already_present} already present")


def verify(source: Store, target: Store, report: Report) -> None:
    """Every source row is in the target, equal; every blob re-hashes."""
    with source.read() as source_tx, target.read() as target_tx:
        for table, _ in schema.TABLES:
            entry = report.tables.setdefault(table, TableReport())
            columns = schema.COLUMNS[table]
            verified = 0
            count = 0
            for batch in _source_batches(source_tx, table):
                count += len(batch)
                keys = [_key(table, row) for row in batch]
                present = _fetch(target_tx, table, keys, columns)
                for key, row in zip(keys, batch):
                    other = present.get(key)
                    if other is None or _comparable(table, other) != _comparable(table, row):
                        raise StoreError(f"verification failed: {table} row {key!r} differs or is missing")
                    if table == "blobs":
                        _check_blob(other)
                    verified += 1
            entry.source = count
            entry.verified = verified
            entry.target_total = int(target_tx.one(f"SELECT COUNT(*) FROM {table}")[0])


def migrate(source: Store, target: Store, progress: Callable[[str], None] = lambda message: None) -> Report:
    if source.same_database(target):
        raise StoreError("source and target are the same database")
    if source.schema_version != target.schema_version:
        raise StoreError(f"schema versions differ (v{source.schema_version} -> v{target.schema_version})")
    report = Report(source.describe(), target.describe())
    if any(target.counts().values()):
        progress("target is not empty: checking that it holds no conflicting rows")
        _pass(source, target, Report(report.source, report.target), write=False, progress=progress)
    _pass(source, target, report, write=True, progress=progress)
    verify(source, target, report)
    return report
