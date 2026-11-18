"""Copy Harbor job directories and workbench launch records into the store.

Ingestion is idempotent and safe while Harbor is still writing: files are
compared by size and mtime (or by content with `verify`), only changed files
are read, and a partially written file is simply replaced on the next pass.
Every file is stored as a content-addressed blob; symlinks are never
followed, so a job directory cannot pull outside files into the store.

Derived values come from the stored bytes only: the trial's files are
written to a private temporary directory, with their recorded mtimes, and
scripts/eval/harbor/viewer/data.py computes the row and detail exactly as it
does for a live job directory. The numbers the page shows therefore cannot
diverge between files and database, and a store copied to another machine
recomputes its projections from its own blobs when the code changes.
"""
from __future__ import annotations

import hashlib
import json
import os
import sys
import tempfile
import threading
import zlib
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Optional, Sequence, Tuple

from scripts.eval.harbor import profiling
from scripts.eval.harbor.store import schema
from scripts.eval.harbor.store.backend import Store, Tx, blob_bytes, now
from scripts.eval.harbor.viewer import data

MAX_FILE_BYTES = 256 * 1024 * 1024
BATCH_BYTES = 32 * 1024 * 1024
JOB_FILES = ("config.json", "result.json")
METRICS_DIR = ".bench-metrics"
# Bump when ingestion itself changes how projections are derived.
INGEST_VERSION = "2"


def _projection() -> str:
    digest = hashlib.sha256(INGEST_VERSION.encode())
    for module in (data, profiling):
        digest.update(Path(module.__file__).read_bytes())
    return digest.hexdigest()[:16]


PROJECTION = _projection()


# ------------------------------------------------------------------ blobs


def encode(content: bytes) -> Tuple[str, bytes]:
    packed = zlib.compress(content, 6)
    return ("zlib", packed) if len(packed) < len(content) else ("identity", content)


def decode(encoding: str, content: Any) -> bytes:
    content = blob_bytes(content)
    return zlib.decompress(content) if encoding == "zlib" else content


def sha256(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()


def put_blob(tx: Tx, digest: str, content: bytes) -> None:
    encoding, packed = encode(content)
    tx.execute("INSERT INTO blobs (sha256, size, encoding, content) VALUES (?, ?, ?, ?) "
               "ON CONFLICT (sha256) DO NOTHING", (digest, len(content), encoding, packed))


def get_blobs(tx: Tx, digests: Iterable[str]) -> Dict[str, bytes]:
    found: Dict[str, bytes] = {}
    pending = sorted(set(digests))
    for start in range(0, len(pending), 200):
        chunk = pending[start:start + 200]
        marks = ", ".join("?" for _ in chunk)
        for digest, encoding, content in tx.query(
                f"SELECT sha256, encoding, content FROM blobs WHERE sha256 IN ({marks})", chunk):
            found[digest] = decode(encoding, content)
    return found


def collect_garbage(tx: Tx, digests: Iterable[str]) -> None:
    for digest in set(d for d in digests if d):
        tx.execute("DELETE FROM blobs WHERE sha256 = ? AND NOT EXISTS (SELECT 1 FROM files WHERE sha256 = ?) "
                   "AND NOT EXISTS (SELECT 1 FROM runs WHERE spec_sha256 = ? OR log_sha256 = ?)",
                   (digest, digest, digest, digest))


# ------------------------------------------------------------- job layout


@dataclass(frozen=True)
class Stat:
    size: int
    mtime_ns: int


@dataclass
class StoredFile:
    size: int
    mtime_ns: int
    state: str
    sha256: Optional[str]
    trial: Optional[str] = None
    kind: str = "job_other"


def is_job_dir(path: Path) -> bool:
    """The same admission rule as data.Library: a real, named job directory."""
    return (path.is_dir() and not path.is_symlink() and bool(data.NAME.match(path.name))
            and (path / "config.json").is_file() and (path / "result.json").is_file())


def scan(job_dir: Path) -> Dict[str, Tuple[Stat, Path]]:
    """Every regular file under the job, by POSIX relative path; no symlinks."""
    found: Dict[str, Tuple[Stat, Path]] = {}
    for directory, dirnames, filenames in os.walk(job_dir, followlinks=False):
        dirnames[:] = [name for name in dirnames if not os.path.islink(os.path.join(directory, name))]
        for name in filenames:
            path = Path(directory) / name
            try:
                info = os.lstat(path)
            except OSError:
                continue
            if not os.path.isfile(path) or os.path.islink(path):
                continue
            relpath = path.relative_to(job_dir).as_posix()
            found[relpath] = (Stat(info.st_size, info.st_mtime_ns), path)
    return found


def trial_prefix(relpath: str) -> Optional[str]:
    """The trial directory (relative to the job) that would own `relpath`, as
    data.trial_dirs admits them: `<task>__<id>/` at the top level, or
    `<NESTED_RUNS>/<run>/<task>__<id>/` for runners that drive Harbor
    themselves (WorkBuddy)."""
    parts = relpath.split("/")
    if parts[0] == data.NESTED_RUNS:
        if len(parts) >= 4 and "__" in parts[2] and parts[1] != METRICS_DIR:
            return "/".join(parts[:3])
        return None
    if len(parts) >= 2 and "__" in parts[0]:
        return parts[0]
    return None


def trial_locations(relpaths: Iterable[str]) -> Dict[str, str]:
    """Trial name -> trial directory, as data.trial_dirs sees them: a
    candidate directory whose config.json exists. A name repeated in two
    nested runs resolves like data.Library.trial_dir: the first by path."""
    found: Dict[str, str] = {}
    for relpath in relpaths:
        prefix = trial_prefix(relpath)
        if prefix is None or relpath != prefix + "/config.json":
            continue
        name = prefix.rsplit("/", 1)[-1]
        if name not in found or prefix < found[name]:
            found[name] = prefix
    return found


def trial_names(relpaths: Iterable[str]) -> List[str]:
    return sorted(trial_locations(relpaths))


def _metrics_path(prefix: str) -> str:
    parent, _, name = prefix.rpartition("/")
    return (parent + "/" if parent else "") + f"{METRICS_DIR}/{name}.jsonl"


def classify_file(relpath: str, trials: Dict[str, str]) -> Tuple[Optional[str], str]:
    """(trial, kind) of one job file; `trials` maps name -> directory."""
    owners = {prefix: name for name, prefix in trials.items()}
    prefix = trial_prefix(relpath)
    if prefix is not None and prefix in owners:
        trial, rest = owners[prefix], relpath[len(prefix) + 1:]
        first = rest.split("/", 1)[0]
        if rest == "config.json":
            return trial, "trial_config"
        if rest == "result.json":
            return trial, "trial_result"
        if rest == "agent/trajectory.json":
            return trial, "trajectory"
        if first == "agent":
            return trial, "agent_log"
        if first == "verifier":
            return trial, "verifier"
        return trial, "trial_other"
    if relpath == "config.json":
        return None, "job_config"
    if relpath == "result.json":
        return None, "job_result"
    parts = relpath.split("/")
    if len(parts) >= 2 and parts[-2] == METRICS_DIR and parts[-1].endswith(".jsonl") and (
            len(parts) == 2 or (len(parts) == 4 and parts[0] == data.NESTED_RUNS)):
        stem = parts[-1][: -len(".jsonl")]
        owner = trials.get(stem)
        return (stem if owner is not None and _metrics_path(owner) == relpath else None), "request_metrics"
    return None, "job_other"


def trial_inputs(prefix: str, relpaths: Iterable[str]) -> List[str]:
    """The files a trial's projection reads: its directory, its request
    metrics (beside the directory) and the job's config/result."""
    metrics = _metrics_path(prefix)
    return sorted(r for r in relpaths if r.startswith(prefix + "/") or r == metrics or r in JOB_FILES)


def digest_inputs(relpaths: Iterable[str], files: Dict[str, StoredFile]) -> str:
    digest = hashlib.sha256()
    for relpath in sorted(relpaths):
        stored = files[relpath]
        token = stored.sha256 if stored.state == "stored" else f"oversize:{stored.size}"
        digest.update(f"{relpath}\0{token}\n".encode())
    return digest.hexdigest()


# -------------------------------------------------------------- projection


def materialize(root: Path, job: str, entries: Iterable[Tuple[str, bytes, int]]) -> Path:
    """Write stored bytes back as a job directory with the recorded mtimes."""
    job_dir = root / job
    job_dir.mkdir()
    for relpath, content, mtime_ns in entries:
        path = job_dir.joinpath(*relpath.split("/"))
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        os.utime(path, ns=(mtime_ns, mtime_ns))
    return job_dir


def _int(value: Any) -> Optional[int]:
    return value if type(value) is int else None


def _float(value: Any) -> Optional[float]:
    return data.number(value)


def _text(value: Any) -> Optional[str]:
    return value if isinstance(value, str) else None


def _json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, allow_nan=False, sort_keys=False)


def project_trial(trial_dir: Path) -> Dict[str, Any]:
    """Everything stored for one trial, computed by data.py from the files."""
    row = data.trial_row(trial_dir)
    detail = data.trial_detail(trial_dir)
    requests = list(data.json_lines(trial_dir.parent / METRICS_DIR / (trial_dir.name + ".jsonl")))
    usage = [profiling.usage_values(event) for event in data.json_lines(trial_dir / "agent" / "metacodes-output.jsonl")
             if event.get("type") == "usage"]
    report = data.read_json(trial_dir / "verifier" / "ctrf.json")
    results = report.get("results") if isinstance(report, dict) else None
    tests = results.get("tests") if isinstance(results, dict) else None
    tests = [t for t in tests if isinstance(t, dict)] if isinstance(tests, list) else []
    return {"row": row, "detail": detail, "requests": requests, "usage": usage, "tests": tests}


def trial_values(job: str, projected: Dict[str, Any], digest: str) -> Tuple[Any, ...]:
    row = projected["row"]
    phases, tests = row["phases"], row["tests"]
    values = {
        "job": job, "name": row["trial"], "task": row["task"], "status": row["status"], "cause": _text(row["cause"]),
        "reward": row["reward"], "exception": _text(row["exception"]), "stop_reason": _text(row["stop_reason"]),
        "empty_final": bool(row["empty_final"]), "turns": _int(row["turns"]), "tool_calls": _int(row["tool_calls"]),
        "input_tokens": _float(row["input_tokens"]), "cache_tokens": _float(row["cache_tokens"]),
        "output_tokens": _float(row["output_tokens"]), "total_tokens": _float(row["total_tokens"]),
        "initial_input_tokens": _float(row["initial_input_tokens"]), "tokens_partial": bool(row["tokens_partial"]),
        "cost_usd": row["cost_usd"], "cost_source": row["cost_source"], "requests": row["requests"],
        "profiled_requests": row["profiled_requests"], "ttft_ms": _float(row["ttft_ms"]),
        "ttft_p50_ms": _float(row["ttft_p50_ms"]), "ttft_p95_ms": _float(row["ttft_p95_ms"]), "tps": _float(row["tps"]),
        "started_at": row["started_at"], "finished_at": row["finished_at"],
        "environment_s": phases.get("environment"), "setup_s": phases.get("setup"), "agent_s": phases.get("agent"),
        "verifier_s": phases.get("verifier"),
        "tests_passed": tests["passed"] if tests else None, "tests_failed": tests["failed"] if tests else None,
        "tests_total": tests["total"] if tests else None,
        "row_json": _json(row), "detail_json": _json(projected["detail"]), "inputs_digest": digest,
        "projection": PROJECTION, "ingested_at": now(),
    }
    return tuple(values[column] for column in schema.COLUMNS["trials"])


def _upsert_sql(table: str, keys: Sequence[str]) -> str:
    columns = schema.COLUMNS[table]
    updates = ", ".join(f"{c} = excluded.{c}" for c in columns if c not in keys)
    return (f"INSERT INTO {table} ({', '.join(columns)}) VALUES ({', '.join('?' for _ in columns)}) "
            f"ON CONFLICT ({', '.join(keys)}) DO UPDATE SET {updates}")


def _insert_sql(table: str) -> str:
    columns = schema.COLUMNS[table]
    return f"INSERT INTO {table} ({', '.join(columns)}) VALUES ({', '.join('?' for _ in columns)})"


def write_trial(tx: Tx, job: str, projected: Dict[str, Any], digest: str) -> None:
    trial = projected["row"]["trial"]
    tx.execute(_upsert_sql("trials", ("job", "name")), trial_values(job, projected, digest))
    for table in ("requests", "usage_events", "verifier_tests"):
        tx.execute(f"DELETE FROM {table} WHERE job = ? AND trial = ?", (job, trial))
    tx.executemany(_insert_sql("requests"), [
        (job, trial, seq, _int(r.get("request")), _text(r.get("started_at")), _int(r.get("http_status")),
         r.get("complete") is True, _float(r.get("duration_ms")), _float(r.get("ttft_ms")),
         _float(r.get("generation_ms")), _float(r.get("input_tokens")), _float(r.get("output_tokens")),
         _float(r.get("cache_tokens")), _float(r.get("cache_creation_tokens")), _json(r))
        for seq, r in enumerate(projected["requests"])])
    tx.executemany(_insert_sql("usage_events"), [
        (job, trial, seq, _float(u.get("input_tokens")), _float(u.get("output_tokens")),
         _float(u.get("cache_tokens")), _float(u.get("cache_creation_tokens")))
        for seq, u in enumerate(projected["usage"])])
    tx.executemany(_insert_sql("verifier_tests"), [
        (job, trial, seq, str(t.get("name") or ""), str(t.get("status") or ""), str(t.get("message") or ""))
        for seq, t in enumerate(projected["tests"])])


def header_values(name: str, source_dir: str, header: Dict[str, Any], digest: str) -> Tuple[Any, ...]:
    values = {
        "name": name, "source_dir": source_dir, "agent": _text(header.get("agent")), "model": _text(header.get("model")),
        "dataset": _text(header.get("dataset")), "attempts": _int(header.get("attempts")),
        "concurrency": _int(header.get("concurrency")), "planned": _int(header.get("planned")),
        "started_at": header.get("started_at"), "finished_at": header.get("finished_at"),
        "header_json": _json(header), "inputs_digest": digest, "projection": PROJECTION, "ingested_at": now(),
    }
    return tuple(values[column] for column in schema.COLUMNS["jobs"])


# ------------------------------------------------------------------ ingest


@dataclass
class JobResult:
    name: str
    outcome: str  # new | updated | unchanged | skipped
    files_written: int = 0
    files_removed: int = 0
    trials_derived: int = 0
    trials_removed: int = 0
    reason: Optional[str] = None

    def to_json(self) -> Dict[str, Any]:
        return {k: v for k, v in self.__dict__.items() if v is not None}


@dataclass
class RootResult:
    root: str
    jobs: List[JobResult] = field(default_factory=list)
    runs_written: int = 0

    def to_json(self) -> Dict[str, Any]:
        return {"root": self.root, "jobs": [job.to_json() for job in self.jobs], "runs_written": self.runs_written}


def _stored_files(tx: Tx, job: str) -> Dict[str, StoredFile]:
    return {relpath: StoredFile(int(size), int(mtime), state, sha, trial, kind)
            for relpath, size, mtime, state, sha, trial, kind in tx.query(
                "SELECT relpath, size, mtime_ns, state, sha256, trial, kind FROM files WHERE job = ?", (job,))}


def _read(path: Path, stat: Stat) -> Tuple[Stat, Optional[bytes]]:
    """Current bytes (None when oversize); the stat describes what was read."""
    info = os.lstat(path)
    if info.st_size > MAX_FILE_BYTES:
        return Stat(info.st_size, info.st_mtime_ns), None
    with open(path, "rb") as handle:  # no symlink: scan() admitted regular files only
        content = handle.read(MAX_FILE_BYTES + 1)
    if len(content) > MAX_FILE_BYTES:
        return Stat(len(content), info.st_mtime_ns), None
    return Stat(len(content), info.st_mtime_ns), content


def ingest_job(store: Store, job_dir: Path, *, verify: bool = False) -> JobResult:
    """Bring one job directory's files and projections up to date."""
    job_dir = Path(job_dir).expanduser().resolve()
    name = job_dir.name
    if not is_job_dir(job_dir):
        return JobResult(name, "skipped", reason="not a Harbor job directory")
    source = str(job_dir)
    with store.read() as tx:
        existing = tx.one("SELECT source_dir, inputs_digest, projection FROM jobs WHERE name = ?", (name,))
        stored = _stored_files(tx, name) if existing else {}
    if existing and existing[0] != source and Path(existing[0]).is_dir():
        # Same name in two live jobs directories: the first one stays, as
        # data.Library does when listing several roots.
        return JobResult(name, "skipped", reason="a job with this name is stored from " + existing[0])
    disk = scan(job_dir)
    trials = trial_locations(disk)
    result = JobResult(name, "new" if not existing else "unchanged")

    # Job header first: its row owns every file row.
    header_files: Dict[str, Tuple[bytes, int]] = {}
    for relpath in JOB_FILES:
        stat, content = _read(disk[relpath][1], disk[relpath][0])
        if content is None:
            return JobResult(name, "skipped", reason=relpath + " exceeds the size limit")
        header_files[relpath] = (content, stat.mtime_ns)
    header_digest = hashlib.sha256()
    for relpath in JOB_FILES:
        header_digest.update(f"{relpath}\0{sha256(header_files[relpath][0])}\n".encode())
    header_digest_hex = header_digest.hexdigest()
    replaced: List[str] = []
    if not existing or existing[1] != header_digest_hex or existing[2] != PROJECTION or existing[0] != source:
        with tempfile.TemporaryDirectory(prefix="bench-store-") as temp:
            header = data.job_header(materialize(Path(temp), name, (
                (r, header_files[r][0], header_files[r][1]) for r in JOB_FILES)))
        with store.transaction() as tx:
            tx.execute(_upsert_sql("jobs", ("name",)), header_values(name, source, header, header_digest_hex))
        if existing:
            result.outcome = "updated"

    # Files: only those whose size/mtime moved (or all, when verifying).
    pending: List[Tuple[str, Stat, Optional[bytes]]] = []
    pending_bytes = 0

    def flush() -> None:
        nonlocal pending, pending_bytes
        if not pending:
            return
        with store.transaction() as tx:
            for relpath, stat, content in pending:
                trial, kind = classify_file(relpath, trials)
                digest = sha256(content) if content is not None else None
                if digest is not None:
                    put_blob(tx, digest, content)
                tx.execute(_upsert_sql("files", ("job", "relpath")),
                           (name, relpath, trial, kind, stat.size, stat.mtime_ns,
                            "stored" if digest else "oversize", digest))
                old = stored.get(relpath)
                if old and old.sha256 and old.sha256 != digest:
                    replaced.append(old.sha256)
                stored[relpath] = StoredFile(stat.size, stat.mtime_ns, "stored" if digest else "oversize", digest,
                                             trial, kind)
                result.files_written += 1
        pending, pending_bytes = [], 0

    for relpath in sorted(disk):
        stat, path = disk[relpath]
        old = stored.get(relpath)
        if relpath in header_files:
            content, mtime_ns = header_files[relpath]
            current = StoredFile(len(content), mtime_ns, "stored", sha256(content))
            if old and (old.sha256, old.size, old.mtime_ns) == (current.sha256, current.size, current.mtime_ns):
                continue
            pending.append((relpath, Stat(len(content), mtime_ns), content))
            pending_bytes += len(content)
        else:
            unchanged_stat = old is not None and old.size == stat.size and old.mtime_ns == stat.mtime_ns
            if unchanged_stat and not verify:
                continue
            try:
                read_stat, content = _read(path, stat)
            except OSError:
                continue  # vanished while scanning; the next pass sees it gone
            if (old is not None and content is not None and old.sha256 == sha256(content)
                    and (old.size, old.mtime_ns) == (read_stat.size, read_stat.mtime_ns)):
                continue
            pending.append((relpath, read_stat, content))
            pending_bytes += len(content or b"")
        if pending_bytes >= BATCH_BYTES:
            flush()
    flush()

    # A trial directory is recognized once its config.json exists; files
    # stored before that are re-labelled without being read again.
    relabel = [(relpath, classify_file(relpath, trials)) for relpath in sorted(set(stored) & set(disk))]
    relabel = [(relpath, label) for relpath, label in relabel if (stored[relpath].trial, stored[relpath].kind) != label]
    if relabel:
        with store.transaction() as tx:
            for relpath, (trial, kind) in relabel:
                tx.execute("UPDATE files SET trial = ?, kind = ? WHERE job = ? AND relpath = ?", (trial, kind, name, relpath))
                stored[relpath].trial, stored[relpath].kind = trial, kind
        result.files_written += len(relabel)

    removed = sorted(set(stored) - set(disk))
    if removed or replaced:
        with store.transaction() as tx:
            for relpath in removed:
                tx.execute("DELETE FROM files WHERE job = ? AND relpath = ?", (name, relpath))
                if stored[relpath].sha256:
                    replaced.append(stored[relpath].sha256)
                del stored[relpath]
            collect_garbage(tx, replaced)
        result.files_removed = len(removed)

    derive_trials(store, name, stored, result)
    if result.outcome == "unchanged" and (result.files_written or result.files_removed or result.trials_derived
                                          or result.trials_removed):
        result.outcome = "updated"
    return result


def derive_trials(store: Store, job: str, stored: Dict[str, StoredFile], result: JobResult) -> None:
    """Recompute trial projections whose input bytes or code changed."""
    trials = trial_locations(stored)
    with store.read() as tx:
        known = {name: (digest, projection) for name, digest, projection in tx.query(
            "SELECT name, inputs_digest, projection FROM trials WHERE job = ?", (job,))}
    for trial, prefix in sorted(trials.items()):
        inputs = trial_inputs(prefix, stored)
        digest = digest_inputs(inputs, stored)
        if known.get(trial) == (digest, PROJECTION):
            continue
        with store.read() as tx:
            contents = get_blobs(tx, (stored[r].sha256 for r in inputs if stored[r].sha256))
        entries = [(r, contents[stored[r].sha256], stored[r].mtime_ns) for r in inputs
                   if stored[r].sha256 in contents]
        with tempfile.TemporaryDirectory(prefix="bench-store-") as temp:
            job_dir = materialize(Path(temp), job, entries)
            projected = project_trial(job_dir.joinpath(*prefix.split("/")))
        with store.transaction() as tx:
            write_trial(tx, job, projected, digest)
        result.trials_derived += 1
    gone = sorted(set(known) - set(trials))
    if gone:
        with store.transaction() as tx:
            for trial in gone:
                tx.execute("DELETE FROM trials WHERE job = ? AND name = ?", (job, trial))
        result.trials_removed = len(gone)


def refresh_projections(store: Store) -> List[JobResult]:
    """Recompute stale projections of jobs that exist only in the store
    (copied from another machine, or whose directory was removed)."""
    with store.read() as tx:
        stale = sorted({row[0] for row in tx.query(
            "SELECT name FROM jobs WHERE projection <> ? UNION SELECT job FROM trials WHERE projection <> ?",
            (PROJECTION, PROJECTION))})
    results = []
    for name in stale:
        result = JobResult(name, "updated")
        with store.read() as tx:
            row = tx.one("SELECT source_dir, inputs_digest FROM jobs WHERE name = ?", (name,))
            stored = _stored_files(tx, name)
        if row is None or any(r not in stored or not stored[r].sha256 for r in JOB_FILES):
            continue
        with store.read() as tx:
            contents = get_blobs(tx, (stored[r].sha256 for r in JOB_FILES))
        with tempfile.TemporaryDirectory(prefix="bench-store-") as temp:
            header = data.job_header(materialize(Path(temp), name, (
                (r, contents[stored[r].sha256], stored[r].mtime_ns) for r in JOB_FILES)))
        with store.transaction() as tx:
            tx.execute(_upsert_sql("jobs", ("name",)), header_values(name, row[0], header, row[1]))
        derive_trials(store, name, stored, result)
        results.append(result)
    return results


# -------------------------------------------------------------------- runs


def ingest_runs(store: Store, records_dir: Path) -> int:
    """Workbench launch receipts, specs and worker logs under `.bench-runs`."""
    records_dir = Path(records_dir)
    written = 0
    try:
        paths = sorted(p for p in records_dir.glob("*.json") if p.is_file() and not p.is_symlink())
    except OSError:
        return 0
    for path in paths:
        record = data.read_json(path)
        if not isinstance(record, dict) or not data.NAME.fullmatch(str(record.get("name", ""))):
            continue
        if record["name"] != path.stem or record.get("status") not in schema.RUN_STATUSES:
            continue
        written += ingest_run(store, records_dir, record)
    return written


def _small_file(path: Path) -> Optional[Tuple[bytes, Stat]]:
    try:
        if path.is_symlink() or not path.is_file():
            return None
        stat, content = _read(path, Stat(0, 0))
    except OSError:
        return None
    return (content, stat) if content is not None else None


def ingest_run(store: Store, records_dir: Path, record: Dict[str, Any]) -> int:
    name = record["name"]
    record_json = _json(record)
    with store.read() as tx:
        existing = tx.one("SELECT record_json, spec_sha256, log_sha256, log_size, log_mtime_ns FROM runs WHERE name = ?",
                          (name,))
    log_path = records_dir / (name + ".log")
    try:
        log_info = os.lstat(log_path) if log_path.is_file() and not log_path.is_symlink() else None
    except OSError:
        log_info = None
    log_unchanged = (existing is not None and log_info is not None and existing[3] is not None
                     and (int(existing[3]), int(existing[4])) == (log_info.st_size, log_info.st_mtime_ns))
    if existing is not None and existing[0] == record_json and existing[1] is not None and (
            log_unchanged or (log_info is None and existing[2] is None)):
        return 0
    spec = _small_file(records_dir / (name + ".spec"))
    log = None if log_unchanged else _small_file(log_path)
    with store.transaction() as tx:
        spec_sha = existing[1] if existing else None
        if spec is not None:
            spec_sha = sha256(spec[0])
            put_blob(tx, spec_sha, spec[0])
        if log_unchanged:
            log_sha, log_size, log_mtime = existing[2], existing[3], existing[4]
        elif log is not None:
            log_sha, log_size, log_mtime = sha256(log[0]), log[1].size, log[1].mtime_ns
            put_blob(tx, log_sha, log[0])
        else:
            log_sha, log_size, log_mtime = None, None, None
        values = {
            "name": name, "status": record["status"], "model": _text(record.get("model")),
            "created_at": _text(record.get("created_at")), "started_at": _text(record.get("started_at")),
            "finished_at": _text(record.get("finished_at")), "exit_code": _int(record.get("exit_code")),
            "error": _text(record.get("error")), "record_json": record_json, "spec_sha256": spec_sha,
            "log_sha256": log_sha, "log_size": log_size, "log_mtime_ns": log_mtime,
            "source_dir": str(records_dir.resolve()), "ingested_at": now(),
        }
        tx.execute(_upsert_sql("runs", ("name",)), tuple(values[c] for c in schema.COLUMNS["runs"]))
        if existing:
            collect_garbage(tx, [d for d in existing[1:3] if d and d not in (spec_sha, log_sha)])
    return 1


def ingest_root(store: Store, root: Path, *, verify: bool = False,
                log: Callable[[str], None] = lambda message: None) -> RootResult:
    """Every job directory and launch record under one Harbor jobs directory."""
    root = Path(root).expanduser().resolve()
    result = RootResult(str(root))
    try:
        children = sorted(root.iterdir())
    except OSError as exc:
        raise ValueError(f"cannot read jobs directory {root}: {exc.strerror}") from None
    for child in children:
        if not is_job_dir(child):
            continue
        try:
            result.jobs.append(ingest_job(store, child, verify=verify))
        except Exception as exc:  # one damaged job must not stop the others
            log(f"bench store: ingesting {child.name} failed: {type(exc).__name__}: {exc}")
            result.jobs.append(JobResult(child.name, "skipped", reason=type(exc).__name__))
    result.runs_written = ingest_runs(store, root / ".bench-runs")
    return result


def stderr_log(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


# ----------------------------------------------------------- worker trigger


class WorkerSync:
    """Periodic ingestion of one running job, owned by its worker.

    Failures are logged to the worker log and never change the run's
    outcome: the files stay authoritative and the service catches up.
    """

    def __init__(self, spec: Dict[str, Any], interval: float = 15.0):
        from scripts.eval.harbor.store import config as store_config

        self.interval = interval
        self.job_dir = Path(spec.get("jobs_dir", ".")) / str(spec.get("name", ""))
        self.records_dir = Path(spec.get("jobs_dir", ".")) / ".bench-runs"
        self.config = None
        self.store: Optional[Store] = None
        self.stop = threading.Event()
        self.thread: Optional[threading.Thread] = None
        self.failed = False
        if spec.get("store") is not None:
            try:
                self.config = store_config.parse(spec["store"], Path(spec.get("jobs_dir", ".")))
            except ValueError as exc:
                stderr_log(f"bench store: disabled ({exc})")

    def _open(self) -> Optional[Store]:
        if self.store is None and self.config is not None:
            self.store = Store(self.config)
        return self.store

    def once(self, verify: bool = False) -> None:
        try:
            store = self._open()
            if store is not None and is_job_dir(self.job_dir):
                ingest_job(store, self.job_dir, verify=verify)
        except Exception as exc:
            if not self.failed:
                stderr_log(f"bench store: ingestion failed: {type(exc).__name__}: {exc}")
            self.failed = True

    def start(self) -> None:
        if self.config is None:
            return

        def loop() -> None:
            while not self.stop.wait(self.interval):
                self.once()

        self.thread = threading.Thread(target=loop, name="bench-store-sync", daemon=True)
        self.thread.start()

    def finish(self, heartbeat: Callable[[], None]) -> None:
        """Final verified ingestion; `heartbeat` keeps the run visibly alive."""
        if self.config is None:
            return
        self.stop.set()
        final = threading.Thread(target=lambda: (self.thread.join() if self.thread else None, self.once(verify=True)),
                                 name="bench-store-final", daemon=True)
        final.start()
        while final.is_alive():
            final.join(2)
            if final.is_alive():
                heartbeat()

    def record(self, name: str) -> None:
        """Store the run's final receipt, spec and worker log."""
        try:
            store = self._open()
            if store is None:
                return
            record = data.read_json(self.records_dir / (name + ".json"))
            if isinstance(record, dict) and record.get("status") in schema.RUN_STATUSES and record.get("name") == name:
                ingest_run(store, self.records_dir, record)
        except Exception as exc:
            stderr_log(f"bench store: recording run failed: {type(exc).__name__}: {exc}")
        finally:
            if self.store is not None:
                self.store.close()
                self.store = None
