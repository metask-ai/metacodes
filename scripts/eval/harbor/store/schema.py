"""Versioned schema of the Bench evaluation store.

Every schema change is a new entry in MIGRATIONS; an applied entry is never
edited. `schema_migrations` records the applied versions, and a store whose
version is newer than this code is refused rather than misread.

The SQL is written once for SQLite and PostgreSQL: natural keys (job name,
trial name, path) instead of generated ids keep rows identical across the
two backends, so a migration copies them verbatim and compares them exactly.

Layers:

- raw: `blobs` (content-addressed bytes, sha256 of the uncompressed content)
  and `files` (every file of a Harbor job directory) and `runs` (workbench
  launch receipts with their spec and worker log). They alone can rebuild
  everything else.
- normalized: `jobs`, `trials`, `requests`, `usage_events`,
  `verifier_tests`, queryable with SQL.
- projection: `jobs.header_json`, `trials.row_json` and `trials.detail_json`
  are exactly what scripts/eval/harbor/viewer/data.py computes from the stored
  bytes; `projection` names the code that computed them and
  `inputs_digest` the bytes, so either change recomputes them.
"""
from __future__ import annotations

from typing import Dict, List, Tuple

TRIAL_STATUSES = ("pass", "partial", "fail", "timeout", "invalid", "running")
RUN_STATUSES = ("queued", "starting", "running", "cancelling", "finished", "failed", "cancelled", "interrupted")
FILE_KINDS = ("job_config", "job_result", "request_metrics", "trial_config", "trial_result",
              "trajectory", "agent_log", "verifier", "trial_other", "job_other")
FILE_STATES = ("stored", "oversize")
BLOB_ENCODINGS = ("identity", "zlib")
COST_SOURCES = ("metacodes_catalog_estimate", "unavailable")


def _enum(values) -> str:
    return "(" + ", ".join("'" + value + "'" for value in values) + ")"


V1 = [
    """CREATE TABLE store_meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
    )""",
    f"""CREATE TABLE blobs (
        sha256 TEXT PRIMARY KEY CHECK (length(sha256) = 64),
        size BIGINT NOT NULL CHECK (size >= 0),
        encoding TEXT NOT NULL CHECK (encoding IN {_enum(BLOB_ENCODINGS)}),
        content {{blob}} NOT NULL
    )""",
    """CREATE TABLE jobs (
        name TEXT PRIMARY KEY,
        source_dir TEXT NOT NULL,
        agent TEXT,
        model TEXT,
        dataset TEXT,
        attempts BIGINT,
        concurrency BIGINT,
        planned BIGINT,
        started_at TEXT,
        finished_at TEXT,
        header_json TEXT NOT NULL,
        inputs_digest TEXT NOT NULL,
        projection TEXT NOT NULL,
        ingested_at TEXT NOT NULL
    )""",
    f"""CREATE TABLE files (
        job TEXT NOT NULL REFERENCES jobs(name) ON DELETE CASCADE,
        relpath TEXT NOT NULL,
        trial TEXT,
        kind TEXT NOT NULL CHECK (kind IN {_enum(FILE_KINDS)}),
        size BIGINT NOT NULL CHECK (size >= 0),
        mtime_ns BIGINT NOT NULL,
        state TEXT NOT NULL CHECK (state IN {_enum(FILE_STATES)}),
        sha256 TEXT REFERENCES blobs(sha256),
        PRIMARY KEY (job, relpath),
        CHECK ((state = 'stored') = (sha256 IS NOT NULL))
    )""",
    "CREATE INDEX files_sha256 ON files (sha256)",
    f"""CREATE TABLE trials (
        job TEXT NOT NULL REFERENCES jobs(name) ON DELETE CASCADE,
        name TEXT NOT NULL,
        task TEXT NOT NULL,
        status TEXT NOT NULL CHECK (status IN {_enum(TRIAL_STATUSES)}),
        cause TEXT,
        reward DOUBLE PRECISION,
        exception TEXT,
        stop_reason TEXT,
        empty_final BOOLEAN NOT NULL,
        turns BIGINT,
        tool_calls BIGINT,
        input_tokens DOUBLE PRECISION,
        cache_tokens DOUBLE PRECISION,
        output_tokens DOUBLE PRECISION,
        total_tokens DOUBLE PRECISION,
        initial_input_tokens DOUBLE PRECISION,
        tokens_partial BOOLEAN NOT NULL,
        cost_usd DOUBLE PRECISION,
        cost_source TEXT NOT NULL CHECK (cost_source IN {_enum(COST_SOURCES)}),
        requests BIGINT NOT NULL,
        profiled_requests BIGINT NOT NULL,
        ttft_ms DOUBLE PRECISION,
        ttft_p50_ms DOUBLE PRECISION,
        ttft_p95_ms DOUBLE PRECISION,
        tps DOUBLE PRECISION,
        started_at TEXT,
        finished_at TEXT,
        environment_s DOUBLE PRECISION,
        setup_s DOUBLE PRECISION,
        agent_s DOUBLE PRECISION,
        verifier_s DOUBLE PRECISION,
        tests_passed BIGINT,
        tests_failed BIGINT,
        tests_total BIGINT,
        row_json TEXT NOT NULL,
        detail_json TEXT NOT NULL,
        inputs_digest TEXT NOT NULL,
        projection TEXT NOT NULL,
        ingested_at TEXT NOT NULL,
        PRIMARY KEY (job, name),
        CHECK ((cost_usd IS NULL) = (cost_source = 'unavailable')),
        CHECK ((tests_total IS NULL) = (tests_passed IS NULL)),
        CHECK ((tests_total IS NULL) = (tests_failed IS NULL)),
        CHECK (status NOT IN ('pass', 'partial', 'fail') OR reward IS NOT NULL)
    )""",
    """CREATE TABLE requests (
        job TEXT NOT NULL,
        trial TEXT NOT NULL,
        seq BIGINT NOT NULL,
        request BIGINT,
        started_at TEXT,
        http_status BIGINT,
        complete BOOLEAN NOT NULL,
        duration_ms DOUBLE PRECISION,
        ttft_ms DOUBLE PRECISION,
        generation_ms DOUBLE PRECISION,
        input_tokens DOUBLE PRECISION,
        output_tokens DOUBLE PRECISION,
        cache_tokens DOUBLE PRECISION,
        cache_creation_tokens DOUBLE PRECISION,
        raw_json TEXT NOT NULL,
        PRIMARY KEY (job, trial, seq),
        FOREIGN KEY (job, trial) REFERENCES trials(job, name) ON DELETE CASCADE
    )""",
    """CREATE TABLE usage_events (
        job TEXT NOT NULL,
        trial TEXT NOT NULL,
        seq BIGINT NOT NULL,
        input_tokens DOUBLE PRECISION,
        output_tokens DOUBLE PRECISION,
        cache_tokens DOUBLE PRECISION,
        cache_creation_tokens DOUBLE PRECISION,
        PRIMARY KEY (job, trial, seq),
        FOREIGN KEY (job, trial) REFERENCES trials(job, name) ON DELETE CASCADE
    )""",
    """CREATE TABLE verifier_tests (
        job TEXT NOT NULL,
        trial TEXT NOT NULL,
        seq BIGINT NOT NULL,
        name TEXT NOT NULL,
        status TEXT NOT NULL,
        message TEXT NOT NULL,
        PRIMARY KEY (job, trial, seq),
        FOREIGN KEY (job, trial) REFERENCES trials(job, name) ON DELETE CASCADE
    )""",
    f"""CREATE TABLE runs (
        name TEXT PRIMARY KEY,
        status TEXT NOT NULL CHECK (status IN {_enum(RUN_STATUSES)}),
        model TEXT,
        created_at TEXT,
        started_at TEXT,
        finished_at TEXT,
        exit_code BIGINT,
        error TEXT,
        record_json TEXT NOT NULL,
        spec_sha256 TEXT REFERENCES blobs(sha256),
        log_sha256 TEXT REFERENCES blobs(sha256),
        log_size BIGINT,
        log_mtime_ns BIGINT,
        source_dir TEXT NOT NULL,
        ingested_at TEXT NOT NULL,
        CHECK ((log_sha256 IS NULL) = (log_size IS NULL))
    )""",
    "CREATE INDEX runs_spec_sha256 ON runs (spec_sha256)",
    "CREATE INDEX runs_log_sha256 ON runs (log_sha256)",
]

# (version, description, statements). Append only.
MIGRATIONS: List[Tuple[int, str, List[str]]] = [
    (1, "evaluation store: raw files, jobs, trials, requests, tests, runs", V1),
]
LATEST = MIGRATIONS[-1][0]

# Copy order (foreign keys first) and primary keys, used by migration and
# verification. Every table except the bookkeeping ones is listed.
TABLES: List[Tuple[str, Tuple[str, ...]]] = [
    ("blobs", ("sha256",)),
    ("jobs", ("name",)),
    ("files", ("job", "relpath")),
    ("trials", ("job", "name")),
    ("requests", ("job", "trial", "seq")),
    ("usage_events", ("job", "trial", "seq")),
    ("verifier_tests", ("job", "trial", "seq")),
    ("runs", ("name",)),
]
COLUMNS: Dict[str, Tuple[str, ...]] = {
    "blobs": ("sha256", "size", "encoding", "content"),
    "jobs": ("name", "source_dir", "agent", "model", "dataset", "attempts", "concurrency", "planned",
             "started_at", "finished_at", "header_json", "inputs_digest", "projection", "ingested_at"),
    "files": ("job", "relpath", "trial", "kind", "size", "mtime_ns", "state", "sha256"),
    "trials": ("job", "name", "task", "status", "cause", "reward", "exception", "stop_reason", "empty_final",
               "turns", "tool_calls", "input_tokens", "cache_tokens", "output_tokens", "total_tokens",
               "initial_input_tokens", "tokens_partial", "cost_usd", "cost_source", "requests",
               "profiled_requests", "ttft_ms", "ttft_p50_ms", "ttft_p95_ms", "tps", "started_at", "finished_at",
               "environment_s", "setup_s", "agent_s", "verifier_s", "tests_passed", "tests_failed", "tests_total",
               "row_json", "detail_json", "inputs_digest", "projection", "ingested_at"),
    "requests": ("job", "trial", "seq", "request", "started_at", "http_status", "complete", "duration_ms",
                 "ttft_ms", "generation_ms", "input_tokens", "output_tokens", "cache_tokens",
                 "cache_creation_tokens", "raw_json"),
    "usage_events": ("job", "trial", "seq", "input_tokens", "output_tokens", "cache_tokens", "cache_creation_tokens"),
    "verifier_tests": ("job", "trial", "seq", "name", "status", "message"),
    "runs": ("name", "status", "model", "created_at", "started_at", "finished_at", "exit_code", "error",
             "record_json", "spec_sha256", "log_sha256", "log_size", "log_mtime_ns", "source_dir", "ingested_at"),
}

# SQLite returns BOOLEAN columns as 0/1; PostgreSQL requires real booleans.
BOOLEANS: Dict[str, Tuple[str, ...]] = {
    "trials": ("empty_final", "tokens_partial"),
    "requests": ("complete",),
}


def render(statement: str, dialect: str) -> str:
    return statement.replace("{blob}", "BLOB" if dialect == "sqlite" else "BYTEA")
