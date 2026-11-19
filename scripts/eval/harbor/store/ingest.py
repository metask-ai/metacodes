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
from scripts.eval.harbor.store.backend import Store, StoreError, Tx, blob_bytes, clean_text, json_text, now
from scripts.eval.harbor.viewer import data

MAX_FILE_BYTES = 256 * 1024 * 1024
# What an oversize file keeps: its last bytes. data.py reads a file over
# data.MAX_JSON_BYTES (always smaller than MAX_FILE_BYTES) only through
# data.tail(), so this tail and the size reproduce its projection exactly.
OVERSIZE_TAIL_BYTES = 64 * 1024
BATCH_BYTES = 32 * 1024 * 1024
JOB_FILES = ("config.json", "result.json")
METRICS_DIR = ".bench-metrics"
# Bump when ingestion itself changes how projections are derived.
INGEST_VERSION = "3"


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
                   "AND NOT EXISTS (SELECT 1 FROM files WHERE tail_sha256 = ?) "
                   "AND NOT EXISTS (SELECT 1 FROM runs WHERE spec_sha256 = ? OR log_sha256 = ?)",
                   (digest, digest, digest, digest, digest))


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
    tail_sha256: Optional[str] = None


def safe_name(name: Any) -> bool:
    """A job name as data.Library admits it: one plain path component."""
    return isinstance(name, str) and bool(data.NAME.match(name)) and "/" not in name


def safe_relpath(relpath: Any) -> bool:
    """A stored relative path that stays inside its job directory on every
    platform: POSIX separators, no empty, `.` or `..` component, no
    absolute path, drive, backslash, NUL or other control character."""
    if not isinstance(relpath, str) or not relpath or len(relpath) > 4096:
        return False
    if relpath.startswith("/") or "\\" in relpath or ":" in relpath.split("/", 1)[0]:
        return False
    if any(ord(ch) < 32 for ch in relpath):
        return False
    return all(part not in ("", ".", "..") for part in relpath.split("/"))


def is_job_dir(path: Path) -> bool:
    """The same admission rule as data.Library: a real, named job directory."""
    return (path.is_dir() and not path.is_symlink() and bool(data.NAME.match(path.name))
            and (path / "config.json").is_file() and (path / "result.json").is_file())


def scan(job_dir: Path) -> Dict[str, Tuple[Stat, Path]]:
    """Every regular file under the job, by POSIX relative path; no symlinks.

    The key is the path as the store holds it (clean_text: a non-UTF-8 name
    is stored with U+FFFD, the first of several such names wins); a path the
    store could not write back safely (a backslash in a POSIX name) is left
    out."""
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
            relpath = clean_text(path.relative_to(job_dir).as_posix())
            if safe_relpath(relpath) and relpath not in found:
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


def trial_locations(relpaths: Iterable[str]) -> List[str]:
    """The trial directories (relative to the job) as data.trial_dirs sees
    them: a candidate directory whose config.json exists. Each directory is
    one trial, keyed by this path: a name repeated in two nested runs is two
    trials, as the live view lists them."""
    return sorted({prefix for prefix, relpath in ((trial_prefix(r), r) for r in relpaths)
                   if prefix is not None and relpath == prefix + "/config.json"})


def _metrics_path(prefix: str) -> str:
    parent, _, name = prefix.rpartition("/")
    return (parent + "/" if parent else "") + f"{METRICS_DIR}/{name}.jsonl"


def classify_file(relpath: str, trials: Iterable[str]) -> Tuple[Optional[str], str]:
    """(trial, kind) of one job file; `trials` holds the trial directories."""
    trials = trials if isinstance(trials, (set, frozenset)) else set(trials)
    prefix = trial_prefix(relpath)
    if prefix is not None and prefix in trials:
        trial, rest = prefix, relpath[len(prefix) + 1:]
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
        owner = "/".join(parts[:-2] + [parts[-1][: -len(".jsonl")]])
        return (owner if owner in trials else None), "request_metrics"
    return None, "job_other"


def trial_inputs(prefix: str, relpaths: Iterable[str]) -> List[str]:
    """The files a trial's projection reads: its directory and its request
    metrics (beside the directory). data.trial_row and trial_detail never
    read the job's config.json or result.json, so a running job rewriting
    its result.json after each trial re-derives no other trial."""
    metrics = _metrics_path(prefix)
    return sorted(r for r in relpaths if r.startswith(prefix + "/") or r == metrics)


def digest_inputs(relpaths: Iterable[str], files: Dict[str, StoredFile]) -> str:
    digest = hashlib.sha256()
    for relpath in sorted(relpaths):
        stored = files[relpath]
        token = stored.sha256 if stored.state == "stored" else f"oversize:{stored.size}:{stored.tail_sha256}"
        digest.update(f"{relpath}\0{token}\n".encode())
    return digest.hexdigest()


# -------------------------------------------------------------- projection


@dataclass(frozen=True)
class Entry:
    """One stored file to write back: its whole content, or for an oversize
    file the stored tail and the recorded size."""
    relpath: str
    content: bytes
    mtime_ns: int
    size: Optional[int] = None  # oversize only


def materialize(root: Path, job: str, entries: Iterable[Entry]) -> Path:
    """Write stored bytes back as a job directory with the recorded mtimes.

    Names come from the database, which may be shared or handed over: a job
    name or path that could leave `root` is refused, never written."""
    if not safe_name(job):
        raise StoreError(f"refusing to write stored job {job!r}: not a plain job name")
    job_dir = Path(root).resolve() / job
    job_dir.mkdir()
    for entry in entries:
        if not safe_relpath(entry.relpath):
            raise StoreError(f"refusing to write stored file {entry.relpath!r} of job {job}: unsafe path")
        path = job_dir.joinpath(*entry.relpath.split("/"))
        path.parent.mkdir(parents=True, exist_ok=True)
        if job_dir not in path.resolve().parents:
            raise StoreError(f"refusing to write stored file {entry.relpath!r} of job {job}: outside the job")
        if entry.size is None:
            path.write_bytes(entry.content)
        else:
            # A sparse file of the recorded size ending in the stored tail:
            # the size and the tail are all data.py reads of a large file.
            tail = entry.content[len(entry.content) - min(entry.size, len(entry.content)):]
            with open(path, "wb") as handle:
                handle.truncate(entry.size)
                handle.seek(entry.size - len(tail))
                handle.write(tail)
        os.utime(path, ns=(entry.mtime_ns, entry.mtime_ns))
    return job_dir


def _int(value: Any) -> Optional[int]:
    return value if type(value) is int else None


def _float(value: Any) -> Optional[float]:
    return data.number(value)


def _text(value: Any) -> Optional[str]:
    return value if isinstance(value, str) else None


def _json(value: Any) -> str:
    return json_text(value)


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


def trial_values(job: str, trial: str, projected: Dict[str, Any], digest: str) -> Tuple[Any, ...]:
    row = projected["row"]
    phases, tests = row["phases"], row["tests"]
    values = {
        "job": job, "name": trial, "task": row["task"], "status": row["status"], "cause": _text(row["cause"]),
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


def write_trial(tx: Tx, job: str, trial: str, projected: Dict[str, Any], digest: str) -> None:
    """`trial` is the trial directory relative to the job: the row's key."""
    tx.execute(_upsert_sql("trials", ("job", "name")), trial_values(job, trial, projected, digest))
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
    trials_failed: int = 0
    reason: Optional[str] = None

    def to_json(self) -> Dict[str, Any]:
        return {k: v for k, v in self.__dict__.items() if v is not None and not (k == "trials_failed" and not v)}


@dataclass
class RootResult:
    root: str
    jobs: List[JobResult] = field(default_factory=list)
    runs_written: int = 0
    batches_written: int = 0

    def to_json(self) -> Dict[str, Any]:
        return {"root": self.root, "jobs": [job.to_json() for job in self.jobs], "runs_written": self.runs_written,
                "batches_written": self.batches_written}


def _stored_files(tx: Tx, job: str) -> Dict[str, StoredFile]:
    """The job's file rows. A path that could not be written back safely
    (a database edited elsewhere) is ignored."""
    return {relpath: StoredFile(int(size), int(mtime), state, sha, trial, kind, tail)
            for relpath, size, mtime, state, sha, trial, kind, tail in tx.query(
                "SELECT relpath, size, mtime_ns, state, sha256, trial, kind, tail_sha256 FROM files WHERE job = ?",
                (job,))
            if safe_relpath(relpath)}


@dataclass(frozen=True)
class Read:
    stat: Stat
    content: Optional[bytes]  # None when oversize
    tail: Optional[bytes] = None  # oversize: the last OVERSIZE_TAIL_BYTES


def _read(path: Path) -> Read:
    """Current bytes, or the size and tail of an oversize file; the stat
    describes what was read."""
    with open(path, "rb") as handle:  # no symlink: scan() admitted regular files only
        info = os.fstat(handle.fileno())
        if info.st_size <= MAX_FILE_BYTES:
            content = handle.read(MAX_FILE_BYTES + 1)
            if len(content) <= MAX_FILE_BYTES:
                return Read(Stat(len(content), info.st_mtime_ns), content)
        size = handle.seek(0, os.SEEK_END)
        handle.seek(max(0, size - OVERSIZE_TAIL_BYTES))
        return Read(Stat(size, info.st_mtime_ns), None, handle.read(OVERSIZE_TAIL_BYTES))


def ingest_job(store: Store, job_dir: Path, *, verify: bool = False,
               log: Callable[[str], None] = lambda message: None) -> JobResult:
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
    trials = set(trial_locations(disk))
    result = JobResult(name, "new" if not existing else "unchanged")

    # Job header first: its row owns every file row.
    header_files: Dict[str, Tuple[bytes, int]] = {}
    for relpath in JOB_FILES:
        read = _read(disk[relpath][1])
        if read.content is None:
            return JobResult(name, "skipped", reason=relpath + " exceeds the size limit")
        header_files[relpath] = (read.content, read.stat.mtime_ns)
    header_digest = hashlib.sha256()
    for relpath in JOB_FILES:
        header_digest.update(f"{relpath}\0{sha256(header_files[relpath][0])}\n".encode())
    header_digest_hex = header_digest.hexdigest()
    replaced: List[str] = []
    if not existing or existing[1] != header_digest_hex or existing[2] != PROJECTION or existing[0] != source:
        with tempfile.TemporaryDirectory(prefix="bench-store-") as temp:
            header = data.job_header(materialize(Path(temp), name, (
                Entry(r, header_files[r][0], header_files[r][1]) for r in JOB_FILES)))
        with store.transaction() as tx:
            tx.execute(_upsert_sql("jobs", ("name",)), header_values(name, source, header, header_digest_hex))
        if existing:
            result.outcome = "updated"

    # Files: only those whose size/mtime moved (or all, when verifying).
    pending: List[Tuple[str, Read]] = []
    pending_bytes = 0

    def flush() -> None:
        nonlocal pending, pending_bytes
        if not pending:
            return
        with store.transaction() as tx:
            for relpath, read in pending:
                trial, kind = classify_file(relpath, trials)
                digest = sha256(read.content) if read.content is not None else None
                tail = sha256(read.tail) if read.tail is not None else None
                for blob, raw in ((digest, read.content), (tail, read.tail)):
                    if blob is not None:
                        put_blob(tx, blob, raw)
                state = "stored" if digest else "oversize"
                tx.execute(_upsert_sql("files", ("job", "relpath")),
                           (name, relpath, trial, kind, read.stat.size, read.stat.mtime_ns, state, digest, tail))
                old = stored.get(relpath)
                if old:
                    replaced.extend(d for d in (old.sha256, old.tail_sha256) if d and d not in (digest, tail))
                stored[relpath] = StoredFile(read.stat.size, read.stat.mtime_ns, state, digest, trial, kind, tail)
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
            pending.append((relpath, Read(Stat(len(content), mtime_ns), content)))
            pending_bytes += len(content)
        else:
            unchanged_stat = old is not None and old.size == stat.size and old.mtime_ns == stat.mtime_ns
            if unchanged_stat and not verify:
                continue
            try:
                read = _read(path)
            except OSError:
                continue  # vanished while scanning; the next pass sees it gone
            if old is not None and (old.size, old.mtime_ns) == (read.stat.size, read.stat.mtime_ns) and (
                    (read.content is not None and old.sha256 == sha256(read.content))
                    or (read.tail is not None and old.tail_sha256 == sha256(read.tail))):
                continue
            pending.append((relpath, read))
            pending_bytes += len(read.content or read.tail or b"")
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
                replaced.extend(d for d in (stored[relpath].sha256, stored[relpath].tail_sha256) if d)
                del stored[relpath]
            collect_garbage(tx, replaced)
        result.files_removed = len(removed)

    derive_trials(store, name, stored, result, log)
    if result.outcome == "unchanged" and (result.files_written or result.files_removed or result.trials_derived
                                          or result.trials_removed):
        result.outcome = "updated"
    return result


def _entries(tx: Tx, relpaths: Sequence[str], stored: Dict[str, StoredFile]) -> List[Entry]:
    """The stored files among `relpaths`, ready to materialize."""
    contents = get_blobs(tx, (d for r in relpaths for d in (stored[r].sha256, stored[r].tail_sha256) if d))
    entries = []
    for relpath in relpaths:
        file = stored[relpath]
        if file.sha256 in contents:
            entries.append(Entry(relpath, contents[file.sha256], file.mtime_ns))
        elif file.state == "oversize" and file.tail_sha256 in contents:
            entries.append(Entry(relpath, contents[file.tail_sha256], file.mtime_ns, file.size))
    return entries


def derive_trials(store: Store, job: str, stored: Dict[str, StoredFile], result: JobResult,
                  log: Callable[[str], None] = lambda message: None) -> None:
    """Recompute trial projections whose input bytes or code changed. A trial
    that cannot be projected or stored is logged and retried on the next
    pass; it never keeps the job's other trials out of the store."""
    trials = trial_locations(stored)
    with store.read() as tx:
        known = {name: (digest, projection) for name, digest, projection in tx.query(
            "SELECT name, inputs_digest, projection FROM trials WHERE job = ?", (job,))}
    for prefix in trials:
        inputs = trial_inputs(prefix, stored)
        digest = digest_inputs(inputs, stored)
        if known.get(prefix) == (digest, PROJECTION):
            continue
        try:
            with store.read() as tx:
                entries = _entries(tx, inputs, stored)
            with tempfile.TemporaryDirectory(prefix="bench-store-") as temp:
                job_dir = materialize(Path(temp), job, entries)
                projected = project_trial(job_dir.joinpath(*prefix.split("/")))
            with store.transaction() as tx:
                write_trial(tx, job, prefix, projected, digest)
        except Exception as exc:
            log(f"bench store: deriving {job}/{prefix} failed: {type(exc).__name__}: {exc}")
            result.trials_failed += 1
            continue
        result.trials_derived += 1
    gone = sorted(set(known) - set(trials))
    if gone:
        with store.transaction() as tx:
            for trial in gone:
                tx.execute("DELETE FROM trials WHERE job = ? AND name = ?", (job, trial))
        result.trials_removed = len(gone)


def refresh_projections(store: Store, log: Callable[[str], None] = lambda message: None) -> List[JobResult]:
    """Recompute stale projections of jobs that exist only in the store
    (copied from another machine, or whose directory was removed). A job
    whose name could not be written back safely is left alone."""
    with store.read() as tx:
        stale = sorted({row[0] for row in tx.query(
            "SELECT name FROM jobs WHERE projection <> ? UNION SELECT job FROM trials WHERE projection <> ?",
            (PROJECTION, PROJECTION))})
    results = []
    for name in stale:
        if not safe_name(name):
            log(f"bench store: ignoring stored job {name!r}: not a plain job name")
            continue
        result = JobResult(name, "updated")
        try:
            with store.read() as tx:
                row = tx.one("SELECT source_dir, inputs_digest FROM jobs WHERE name = ?", (name,))
                stored = _stored_files(tx, name)
                if row is None or any(r not in stored or not stored[r].sha256 for r in JOB_FILES):
                    continue
                entries = _entries(tx, JOB_FILES, stored)
            with tempfile.TemporaryDirectory(prefix="bench-store-") as temp:
                header = data.job_header(materialize(Path(temp), name, entries))
            with store.transaction() as tx:
                tx.execute(_upsert_sql("jobs", ("name",)), header_values(name, row[0], header, row[1]))
        except Exception as exc:
            log(f"bench store: refreshing {name} failed: {type(exc).__name__}: {exc}")
            continue
        derive_trials(store, name, stored, result, log)
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
        read = _read(path)
    except OSError:
        return None
    return (read.content, read.stat) if read.content is not None else None


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


BATCHES_DIR = ".bench-batches"


def ingest_batches(store: Store, batches_dir: Path) -> int:
    """Workbench batch records under `.bench-batches` (one JSON each)."""
    written = 0
    try:
        paths = sorted(p for p in Path(batches_dir).glob("*.json") if p.is_file() and not p.is_symlink())
    except OSError:
        return 0
    for path in paths:
        record = data.read_json(path)
        if not isinstance(record, dict) or record.get("id") != path.stem or not safe_name(record.get("id")):
            continue
        if record.get("status") not in schema.BATCH_STATUSES:
            continue
        record_json = _json(record)
        with store.read() as tx:
            existing = tx.one("SELECT record_json FROM batches WHERE id = ?", (record["id"],))
        if existing is not None and existing[0] == record_json:
            continue
        metacodes = record.get("metacodes") if isinstance(record.get("metacodes"), dict) else {}
        values = {"id": record["id"], "status": record["status"], "name": _text(record.get("name")),
                  "model": _text(record.get("model")), "metacodes_digest": _text(metacodes.get("digest")),
                  "created_at": _text(record.get("created_at")), "finished_at": _text(record.get("finished_at")),
                  "record_json": record_json, "source_dir": str(Path(batches_dir).resolve()), "ingested_at": now()}
        with store.transaction() as tx:
            tx.execute(_upsert_sql("batches", ("id",)), tuple(values[c] for c in schema.COLUMNS["batches"]))
        written += 1
    return written


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
            result.jobs.append(ingest_job(store, child, verify=verify, log=log))
        except Exception as exc:  # one damaged job must not stop the others
            log(f"bench store: ingesting {child.name} failed: {type(exc).__name__}: {exc}")
            result.jobs.append(JobResult(child.name, "skipped", reason=type(exc).__name__))
    result.runs_written = ingest_runs(store, root / ".bench-runs")
    result.batches_written = ingest_batches(store, root / BATCHES_DIR)
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
                ingest_job(store, self.job_dir, verify=verify, log=stderr_log)
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
