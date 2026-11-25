"""Copy a whole evaluation store to another backend and prove the copy.

The copy and its verification read the source in one snapshot, so a source
that keeps changing (the service or a running worker ingesting) is copied
and verified as of one moment; what is ingested later reaches the target on
the next sync after `--switch`, or on a later migration. The target is
written in committed batches, so an interrupted migration resumes where it
stopped.

Rows are compared by primary key across the two backends. A row already
present and identical is skipped. A row present with different content is
updated only when it is an older version of the source row: an earlier
ingestion of the same job, trial or launch record (`ingested_at` older), of
the same file (`mtime_ns` older, or only its trial label differs), or the
request/usage/test rows of such a trial. Any other difference stops the
migration before anything is written; nothing else in a target is
overwritten. Verification then compares every source row of the snapshot
with the target and re-hashes every blob the target holds for it.
"""
from __future__ import annotations

import datetime as dt
from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Optional, Sequence, Set, Tuple

from scripts.eval.harbor.store import ingest, schema
from scripts.eval.harbor.store.backend import Store, StoreError, Tx, blob_bytes, clean_text

BATCH = 200
BLOB_BATCH = 32
# Rows derived from one trial, replaced together with it.
TRIAL_CHILDREN = ("requests", "usage_events", "verifier_tests")


class MigrationConflict(StoreError):
    """The target holds a different row under the same key."""


@dataclass
class TableReport:
    source: int = 0
    copied: int = 0
    updated: int = 0
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
    """A backend-neutral value: SQLite stores booleans as integers, both
    store DOUBLE PRECISION as IEEE doubles, and text is stored as
    backend.clean_text binds it (a SQLite file written before that may hold
    a NUL or a lone surrogate; PostgreSQL never can)."""
    value = blob_bytes(value)
    if isinstance(value, bool):
        return float(value)
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        return clean_text(value)
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
        found[tuple(_normal(row[columns.index(k)]) for k in names)] = row
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


def _check_names(table: str, row: Sequence[Any]) -> None:
    """Names that later become paths on disk (projection refresh writes
    `<temp>/<job>/<relpath>`) must be safe in the copy as well."""
    values = dict(zip(schema.COLUMNS[table], row))
    job = values.get("job", values.get("name") if table in ("jobs", "runs") else None)
    if job is not None and not ingest.safe_name(job):
        raise StoreError(f"source {table} row names an unsafe job {job!r}; remove it from the source first")
    for column in ("relpath", "trial") + (("name",) if table == "trials" else ()):
        value = values.get(column)
        if value is not None and not ingest.safe_relpath(value):
            raise StoreError(f"source {table} row has an unsafe path {value!r}; remove it from the source first")


def _when(value: Any) -> Optional[dt.datetime]:
    try:
        parsed = dt.datetime.fromisoformat(str(value))
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=dt.timezone.utc)


def _older(table: str, target_row: Sequence[Any], source_row: Sequence[Any], stale_trials: Set[Tuple[Any, ...]]) -> bool:
    """Whether the target's row is an earlier version of the source's."""
    columns = schema.COLUMNS[table]
    mine, theirs = dict(zip(columns, target_row)), dict(zip(columns, source_row))
    if table in ("jobs", "trials", "runs", "profiles", "worker_jobs"):
        before, after = _when(mine["ingested_at"]), _when(theirs["ingested_at"])
        return before is not None and after is not None and before < after
    if table == "files":
        if int(mine["mtime_ns"]) < int(theirs["mtime_ns"]):
            return True
        same = ("size", "mtime_ns", "state", "sha256", "tail_sha256")
        return all(_normal(mine[c]) == _normal(theirs[c]) for c in same)  # only the trial label moved
    if table in TRIAL_CHILDREN:
        return (_normal(mine["job"]), _normal(mine["trial"])) in stale_trials
    return False


def _pass(source_tx: Tx, target: Store, report: Report, write: bool,
          progress: Callable[[str], None]) -> None:
    stale_trials: Set[Tuple[Any, ...]] = set()
    for table, _ in schema.TABLES:
        columns = schema.COLUMNS[table]
        insert = ingest._insert_sql(table)
        upsert = ingest._upsert_sql(table, dict(schema.TABLES)[table])
        entry = report.tables.setdefault(table, TableReport())
        count = 0
        for batch in _source_batches(source_tx, table):
            keys = [_key(table, row) for row in batch]
            with (target.transaction() if write else target.read()) as target_tx:
                present = _fetch(target_tx, table, keys,
                                 columns if table != "blobs" else ("sha256", "size", "encoding"))
                missing, newer = [], []
                for key, row in zip(keys, batch):
                    _check_names(table, row)
                    found = present.get(tuple(_normal(v) for v in key))
                    if found is None:
                        missing.append(row)
                    elif _comparable(table, found) == _comparable(table, row[:len(found)]):
                        if write:
                            entry.already_present += 1
                    elif table != "blobs" and _older(table, found, row, stale_trials):
                        newer.append(row)
                        if table == "trials":
                            stale_trials.add((_normal(key[0]), _normal(key[1])))
                    else:
                        raise MigrationConflict(
                            f"target already has a different {table} row {key!r} that is not an older "
                            "version of the source row; refusing to overwrite it (choose an empty target)")
                if write and table == "blobs":
                    for row in missing:
                        _check_blob(row)
                if write and table == "trials":
                    # The trial's derived rows are replaced with it: the
                    # source's are copied as missing rows below.
                    for row in newer:
                        for child in TRIAL_CHILDREN:
                            target_tx.execute(f"DELETE FROM {child} WHERE job = ? AND trial = ?",
                                              (row[0], row[1]))
                if write and missing:
                    target_tx.executemany(insert, [_for_insert(table, row) for row in missing])
                    entry.copied += len(missing)
                if write and newer:
                    target_tx.executemany(upsert, [_for_insert(table, row) for row in newer])
                    entry.updated += len(newer)
            count += len(batch)
        entry.source = count
        if write:
            progress(f"{table}: {entry.copied} copied, {entry.updated} updated, "
                     f"{entry.already_present} already present")


def _verify(source_tx: Tx, target: Store, report: Report) -> None:
    with target.read() as target_tx:
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
                    other = present.get(tuple(_normal(v) for v in key))
                    if other is None or _comparable(table, other) != _comparable(table, row):
                        raise StoreError(f"verification failed: {table} row {key!r} differs or is missing")
                    if table == "blobs":
                        _check_blob(other)
                    verified += 1
            entry.source = count
            entry.verified = verified
            entry.target_total = int(target_tx.one(f"SELECT COUNT(*) FROM {table}")[0])


def verify(source: Store, target: Store, report: Report) -> None:
    """Every source row is in the target, equal; every blob re-hashes."""
    with source.read() as source_tx:
        _verify(source_tx, target, report)


def migrate(source: Store, target: Store, progress: Callable[[str], None] = lambda message: None) -> Report:
    if source.same_database(target):
        raise StoreError("source and target are the same database")
    if source.schema_version != target.schema_version:
        raise StoreError(f"schema versions differ (v{source.schema_version} -> v{target.schema_version})")
    report = Report(source.describe(), target.describe())
    # One source snapshot for the conflict check, the copy and the
    # verification: rows a running job keeps re-ingesting cannot make the
    # copy disagree with what is verified.
    with source.read() as source_tx:
        if any(target.counts().values()):
            progress("target is not empty: checking that it holds no conflicting rows")
            _pass(source_tx, target, Report(report.source, report.target), write=False, progress=progress)
        _pass(source_tx, target, report, write=True, progress=progress)
        _verify(source_tx, target, report)
    return report
