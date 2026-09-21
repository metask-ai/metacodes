#!/usr/bin/env python3
"""Deterministic synthetic codebases for the delivery-cadence evaluation.

Each case is an open-ended investigation over a small package whose answer is
machine-checkable and cannot be read off a single grep: the hazard is
"explore without ever writing the deliverable" (the vim-tabpanel failure
class), so every case rewards breadth of reading and punishes a run that
never writes `report.md`. No benchmark task content appears here; every
file is authored by this generator. Re-running it must reproduce the tree
byte-for-byte (no randomness, no timestamps).

Cases (each <= 64 files so it fits a suite repository_snapshot):

* taint_trace     -- which request-controlled value reaches a shell execution
                     without validation (six chains, one unguarded).
* unused_setting  -- which configuration key is never read by any module
                     (48 keys, indirect reads, documentation decoys).
* invariant_break -- which worker violates the documented ack-once contract
                     (44 workers, one early return without ack).
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def write(files: dict[str, str], case: str) -> None:
    base = ROOT / case
    if base.exists():
        for path in sorted(base.rglob("*"), reverse=True):
            if path.is_file():
                path.unlink()
            elif path.is_dir():
                path.rmdir()
    for relative, body in sorted(files.items()):
        target = base / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        with open(target, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(body)
    assert len(files) <= 64, (case, len(files))


# ---------------------------------------------------------------------------
# Case 1: taint trace
# ---------------------------------------------------------------------------

def taint_trace() -> dict[str, str]:
    f: dict[str, str] = {}
    f["README.md"] = (
        "# svc\n\nA small asset service. Request handlers live in `svc/handlers.py`;\n"
        "helpers are under `svc/pipeline/` and `svc/util/`. Shell-level work is\n"
        "centralised in `svc/pipeline/exec_backend.py`.\n"
    )
    f["svc/__init__.py"] = '"""svc package."""\n'
    f["svc/pipeline/__init__.py"] = ""
    f["svc/util/__init__.py"] = ""
    # Six request handlers; each starts a chain that ends in exec_backend or a
    # safe sink. Only `export` reaches run_command with an unvalidated value.
    f["svc/handlers.py"] = '''"""HTTP-ish request handlers. `request.args` is untrusted client input."""

from svc.pipeline import normalize, exporters, thumbnails, archive, search, mirror
from svc.util import audit


def download(request):
    raw = request.args.get("path", "")
    target = normalize.normalize_target(raw)
    audit.record("download", target)
    return archive.fetch(target)


def export(request):
    fmt = request.args.get("format", "pdf")
    target = request.args.get("target", "")
    audit.record("export", fmt)
    return exporters.select(fmt, target)


def thumbnail(request):
    size = request.args.get("size", "128")
    name = request.args.get("name", "")
    return thumbnails.render(name, size)


def compress(request):
    level = request.args.get("level", "6")
    name = request.args.get("name", "")
    return archive.compress(name, level)


def find(request):
    query = request.args.get("q", "")
    return search.run_query(query)


def sync(request):
    remote = request.args.get("remote", "origin")
    return mirror.pull(remote)
'''
    f["svc/pipeline/normalize.py"] = '''"""Target path normalisation used by the download chain."""

import os.path

from svc.pipeline import validate


def normalize_target(raw):
    cleaned = raw.replace("\\\\", "/")
    cleaned = os.path.normpath(cleaned)
    return validate.assert_relative(cleaned)
'''
    f["svc/pipeline/validate.py"] = '''"""Input validation helpers. Every function raises on unsafe input."""

import re

SAFE_TOKEN = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")
SAFE_FORMAT = ("pdf", "png", "svg", "txt")


class UnsafeInput(ValueError):
    pass


def assert_relative(path):
    if path.startswith("/") or ".." in path.split("/"):
        raise UnsafeInput(path)
    return path


def assert_token(value):
    if not SAFE_TOKEN.match(value or ""):
        raise UnsafeInput(value)
    return value


def assert_format(value):
    if value not in SAFE_FORMAT:
        raise UnsafeInput(value)
    return value


def assert_int(value, low, high):
    number = int(value)
    if number < low or number > high:
        raise UnsafeInput(value)
    return number
'''
    f["svc/pipeline/exporters.py"] = '''"""Export dispatch: picks a renderer for the requested format."""

from svc.pipeline import render, validate


def select(fmt, target):
    # The format is whitelisted; the target is passed through as given
    # because renderers were expected to quote it themselves.
    fmt = validate.assert_format(fmt)
    plan = render.plan(fmt, target)
    return render.execute(plan)
'''
    f["svc/pipeline/render.py"] = '''"""Build and execute an export plan."""

from svc.pipeline import exec_backend, quoting


def plan(fmt, target):
    return {"fmt": fmt, "target": target, "tool": "convert"}


def execute(plan):
    command = build_command(plan)
    return exec_backend.run_command(command)


def build_command(plan):
    # NOTE: quoting.shell_quote is imported but the target is interpolated raw.
    return "%s --format %s %s" % (plan["tool"], plan["fmt"], plan["target"])
'''
    f["svc/pipeline/exec_backend.py"] = '''"""The only place that touches the shell."""

import subprocess


def run_command(command):
    """Run a fully assembled command line through the shell."""
    return subprocess.run(command, shell=True, capture_output=True, text=True, check=False)


def run_argv(argv):
    """Run an argument vector without a shell."""
    return subprocess.run(list(argv), capture_output=True, text=True, check=False)
'''
    f["svc/pipeline/quoting.py"] = '''"""Shell quoting helpers."""

import shlex


def shell_quote(value):
    return shlex.quote(str(value))


def join(parts):
    return " ".join(shell_quote(p) for p in parts)
'''
    f["svc/pipeline/thumbnails.py"] = '''"""Thumbnail rendering chain (guarded)."""

from svc.pipeline import exec_backend, quoting, validate


def render(name, size):
    name = validate.assert_token(name)
    size = validate.assert_int(size, 16, 1024)
    command = "thumb --size %d %s" % (size, quoting.shell_quote(name))
    return exec_backend.run_command(command)
'''
    f["svc/pipeline/archive.py"] = '''"""Archive chain: fetch is a file read, compress shells out with argv."""

from svc.pipeline import exec_backend, validate
from svc.util import storage


def fetch(target):
    return storage.read_bytes(target)


def compress(name, level):
    name = validate.assert_token(name)
    level = validate.assert_int(level, 1, 9)
    return exec_backend.run_argv(["gzip", "-%d" % level, name])
'''
    f["svc/pipeline/search.py"] = '''"""Search chain: the query never reaches a shell."""

from svc.util import index


def run_query(query):
    terms = [t for t in query.split() if t]
    return index.lookup(terms)
'''
    f["svc/pipeline/mirror.py"] = '''"""Mirror chain: remote names are validated against a fixed table."""

from svc.pipeline import exec_backend
from svc.util import remotes


def pull(remote):
    url = remotes.resolve(remote)  # raises for unknown remotes
    return exec_backend.run_argv(["git", "fetch", url])
'''
    f["svc/util/audit.py"] = '''"""Audit log."""

_LOG = []


def record(action, detail):
    _LOG.append((action, str(detail)[:200]))


def entries():
    return list(_LOG)
'''
    f["svc/util/storage.py"] = '''"""Filesystem access rooted at the asset directory."""

import os

ASSET_ROOT = os.environ.get("SVC_ASSET_ROOT", "/var/lib/svc/assets")


def read_bytes(relative):
    with open(os.path.join(ASSET_ROOT, relative), "rb") as handle:
        return handle.read()


def exists(relative):
    return os.path.exists(os.path.join(ASSET_ROOT, relative))
'''
    f["svc/util/index.py"] = '''"""In-memory search index."""

_INDEX = {}


def add(term, doc_id):
    _INDEX.setdefault(term, set()).add(doc_id)


def lookup(terms):
    hits = None
    for term in terms:
        found = _INDEX.get(term, set())
        hits = found if hits is None else hits & found
    return sorted(hits or [])
'''
    f["svc/util/remotes.py"] = '''"""Known mirror remotes."""

_REMOTES = {
    "origin": "https://mirror.example.com/assets.git",
    "backup": "https://backup.example.com/assets.git",
}


def resolve(name):
    try:
        return _REMOTES[name]
    except KeyError:
        raise ValueError("unknown remote: %s" % name)
'''
    # Filler modules: realistic, unrelated to the shell.
    fillers = {
        "svc/util/cache.py": ("cache", "get, put and evict entries with a fixed capacity"),
        "svc/util/clock.py": ("clock", "monotonic timestamps for rate limiting"),
        "svc/util/config.py": ("config", "typed access to environment settings"),
        "svc/util/errors.py": ("errors", "error hierarchy for the service"),
        "svc/util/headers.py": ("headers", "parse and render HTTP headers"),
        "svc/util/hashing.py": ("hashing", "content hashes for cache keys"),
        "svc/util/json_io.py": ("json_io", "strict JSON encode and decode"),
        "svc/util/limits.py": ("limits", "request size and rate limits"),
        "svc/util/metrics.py": ("metrics", "counters and timers"),
        "svc/util/mime.py": ("mime", "extension to media type mapping"),
        "svc/util/paging.py": ("paging", "offset/limit pagination helpers"),
        "svc/util/retry.py": ("retry", "bounded retry with backoff"),
        "svc/util/session.py": ("session", "session token parsing"),
        "svc/util/text.py": ("text", "string helpers"),
        "svc/util/units.py": ("units", "byte and duration formatting"),
        "svc/util/uuid_gen.py": ("uuid_gen", "opaque identifiers"),
        "svc/util/version.py": ("version", "service version string"),
        "svc/util/warmup.py": ("warmup", "cache warmup on startup"),
        "svc/util/tracing.py": ("tracing", "span helpers"),
        "svc/util/tz.py": ("tz", "timezone conversion"),
        "svc/util/csv_io.py": ("csv_io", "CSV reading"),
        "svc/util/ratelimit.py": ("ratelimit", "token bucket"),
        "svc/util/hooks.py": ("hooks", "startup and shutdown hooks"),
        "svc/util/lockfile.py": ("lockfile", "advisory lock files"),
        "svc/util/pool.py": ("pool", "bounded worker pool"),
        "svc/util/schema.py": ("schema", "request schema validation"),
    }
    for path, (name, purpose) in fillers.items():
        f[path] = filler_module(name, purpose)
    f["svc/pipeline/manifest.py"] = '''"""Export manifests (data only)."""


def build(entries):
    return {"count": len(entries), "entries": sorted(entries)}
'''
    f["svc/pipeline/formats.py"] = '''"""Format metadata table."""

TABLE = {
    "pdf": {"mime": "application/pdf", "binary": True},
    "png": {"mime": "image/png", "binary": True},
    "svg": {"mime": "image/svg+xml", "binary": False},
    "txt": {"mime": "text/plain", "binary": False},
}


def is_binary(fmt):
    return TABLE.get(fmt, {}).get("binary", True)
'''
    f["svc/pipeline/scheduler.py"] = '''"""Deferred export scheduling (no execution here)."""

_QUEUE = []


def enqueue(plan):
    _QUEUE.append(plan)
    return len(_QUEUE)


def drain():
    items, _QUEUE[:] = list(_QUEUE), []
    return items
'''
    f["tests/test_validate.py"] = '''from svc.pipeline import validate


def test_token_rejects_shell_metacharacters():
    for bad in ("a;b", "a|b", "$(x)", "a b"):
        try:
            validate.assert_token(bad)
        except validate.UnsafeInput:
            continue
        raise AssertionError(bad)


def test_format_whitelist():
    assert validate.assert_format("pdf") == "pdf"
'''
    return f


def filler_module(name: str, purpose: str) -> str:
    return f'''"""{purpose[0].upper()}{purpose[1:]}."""


class {name.title().replace("_", "")}Error(Exception):
    pass


def configure(options):
    """Apply a mapping of options; unknown keys are ignored."""
    known = {{k: v for k, v in dict(options).items() if isinstance(k, str)}}
    return known


def describe():
    return "{name}: {purpose}"
'''


# ---------------------------------------------------------------------------
# Case 2: unused setting
# ---------------------------------------------------------------------------

SETTINGS = {
    "core": ["instance_name", "listen_port", "worker_count", "shutdown_grace_s", "debug_endpoints"],
    "db": ["dsn", "pool_min", "pool_max", "statement_timeout_ms", "read_replica_dsn", "migrate_on_boot"],
    "cache": ["backend", "ttl_s", "max_entries", "namespace", "warm_keys"],
    "mail": ["smtp_host", "smtp_port", "sender", "retry_limit", "retry_backoff_ms", "tls_required"],
    "auth": ["token_ttl_s", "issuer", "audience", "jwks_url", "clock_skew_s"],
    "storage": ["bucket", "region", "prefix", "signed_url_ttl_s", "multipart_chunk_mb"],
    "metrics": ["namespace", "flush_interval_s", "histogram_buckets", "tags"],
    "queue": ["url", "visibility_s", "max_receive", "dead_letter_url", "poll_interval_ms"],
    "search": ["index_name", "shards", "replicas", "refresh_interval_s"],
    "billing": ["currency", "tax_rate", "invoice_prefix"],
}
UNUSED_KEY = "mail.retry_backoff_ms"


def unused_setting() -> dict[str, str]:
    f: dict[str, str] = {}
    keys = [f"{section}.{key}" for section, names in SETTINGS.items() for key in names]
    assert len(keys) == 48, len(keys)
    ini = ["# Service settings. Every key is read somewhere in app/ ... or so we believe.\n"]
    for section, names in SETTINGS.items():
        ini.append(f"[{section}]\n")
        for key in names:
            ini.append(f"{key} = {default_for(section, key)}\n")
        ini.append("\n")
    f["conf/settings.ini"] = "".join(ini)
    f["app/__init__.py"] = ""
    f["app/settings.py"] = '''"""Settings access. `get("section.key")` is the only read path."""

import configparser
import os

_PARSER = configparser.ConfigParser()
_PARSER.read(os.environ.get("APP_SETTINGS", "conf/settings.ini"))


def get(dotted, default=None):
    section, _, key = dotted.partition(".")
    if _PARSER.has_option(section, key):
        return _PARSER.get(section, key)
    return default


def get_int(dotted, default=0):
    value = get(dotted)
    return int(value) if value is not None else default


def get_bool(dotted, default=False):
    value = get(dotted)
    return value.lower() in ("1", "true", "yes") if value is not None else default
'''
    # Direct readers: each module reads 1-3 keys literally.
    direct = {
        "app/server.py": ["core.instance_name", "core.listen_port", "core.debug_endpoints"],
        "app/workers.py": ["core.worker_count", "core.shutdown_grace_s"],
        "app/db_pool.py": ["db.dsn", "db.pool_min", "db.pool_max"],
        "app/db_query.py": ["db.statement_timeout_ms"],
        "app/db_replica.py": ["db.read_replica_dsn"],
        "app/migrate.py": ["db.migrate_on_boot"],
        "app/cache_backend.py": ["cache.backend", "cache.namespace"],
        "app/cache_policy.py": ["cache.ttl_s", "cache.max_entries"],
        "app/mailer.py": ["mail.smtp_host", "mail.smtp_port", "mail.sender"],
        "app/mail_retry.py": ["mail.retry_limit"],
        "app/mail_tls.py": ["mail.tls_required"],
        "app/auth_tokens.py": ["auth.token_ttl_s", "auth.issuer", "auth.audience"],
        "app/auth_keys.py": ["auth.jwks_url", "auth.clock_skew_s"],
        "app/storage_client.py": ["storage.bucket", "storage.region", "storage.prefix"],
        "app/storage_urls.py": ["storage.signed_url_ttl_s"],
        "app/storage_upload.py": ["storage.multipart_chunk_mb"],
        "app/metrics_sink.py": ["metrics.namespace", "metrics.flush_interval_s"],
        "app/metrics_hist.py": ["metrics.histogram_buckets", "metrics.tags"],
        "app/queue_client.py": ["queue.url", "queue.visibility_s"],
        "app/queue_consumer.py": ["queue.max_receive", "queue.poll_interval_ms"],
        "app/queue_dlq.py": ["queue.dead_letter_url"],
        "app/search_index.py": ["search.index_name"],
        "app/search_topology.py": ["search.shards", "search.replicas"],
        "app/search_refresh.py": ["search.refresh_interval_s"],
        "app/billing_rates.py": ["billing.currency", "billing.tax_rate"],
        "app/billing_invoice.py": ["billing.invoice_prefix"],
    }
    # Indirect reader: cache.warm_keys is read through a computed name, so a
    # literal grep for the key misses it.
    f["app/cache_warm.py"] = '''"""Warm the cache from a configured key list (computed setting name)."""

from app import settings

_SECTION = "cache"


def warm():
    names = ["warm_keys"]
    for name in names:
        raw = settings.get("%s.%s" % (_SECTION, name), "")
        for key in raw.split(","):
            if key.strip():
                yield key.strip()
'''
    for path, dotted_keys in direct.items():
        f[path] = direct_reader(path, dotted_keys)
    # Documentation decoys: mention several keys (including the unused one)
    # so a grep for the key name finds prose, not a read.
    f["docs/operations.md"] = (
        "# Operations\n\n"
        "Tune `mail.retry_limit` and `mail.retry_backoff_ms` together when the\n"
        "provider throttles. `queue.poll_interval_ms` controls consumer latency.\n"
        "`cache.warm_keys` is a comma-separated list applied at boot.\n"
    )
    f["docs/settings.md"] = "# Settings reference\n\n" + "".join(
        f"- `{k}`\n" for k in keys
    )
    f["docs/CHANGELOG.md"] = (
        "# Changelog\n\n- 1.4: added `mail.retry_backoff_ms` (planned; not wired yet)\n"
        "- 1.3: `search.refresh_interval_s` is honoured by the refresh loop\n"
    )
    f["README.md"] = (
        "# app\n\nConfiguration lives in `conf/settings.ini` and is read only via\n"
        "`app.settings.get()` (and its `get_int`/`get_bool` wrappers).\n"
    )
    f["tests/test_settings.py"] = '''from app import settings


def test_missing_key_returns_default():
    assert settings.get("nope.nothing", "x") == "x"
'''
    # Sanity: exactly one key is never read in app/ code.
    read = set()
    for path, body in f.items():
        if path.startswith("app/") and path != "app/settings.py":
            for k in keys:
                if f'"{k}"' in body:
                    read.add(k)
    read.add("cache.warm_keys")  # computed read in cache_warm.py
    unread = sorted(set(keys) - read)
    assert unread == [UNUSED_KEY], unread
    return f


def default_for(section: str, key: str) -> str:
    if key.endswith("_s") or key.endswith("_ms") or key in ("pool_min", "pool_max", "worker_count", "shards", "replicas", "max_receive", "max_entries", "listen_port", "smtp_port", "multipart_chunk_mb", "retry_limit"):
        return str(sum(ord(c) for c in key) % 900 + 10)
    if key.endswith("_url") or key == "url" or key.endswith("dsn"):
        return f"https://{section}.internal/{key}"
    if key in ("debug_endpoints", "migrate_on_boot", "tls_required"):
        return "false"
    if key == "tax_rate":
        return "0.0725"
    if key == "histogram_buckets":
        return "5,10,25,50,100,250"
    if key == "warm_keys":
        return "home,pricing,status"
    if key == "tags":
        return "env=prod,tier=api"
    return f"{section}-{key}"


def direct_reader(path: str, dotted_keys: list[str]) -> str:
    stem = Path(path).stem
    lines = [f'"""{stem.replace("_", " ").title()} (reads its settings at import time)."""', "", "from app import settings", ""]
    for dotted in dotted_keys:
        const = dotted.split(".")[1].upper()
        getter = "get_int" if dotted.endswith(("_s", "_ms", "_mb")) or dotted.split(".")[1] in ("pool_min", "pool_max", "worker_count", "shards", "replicas", "max_receive", "max_entries", "listen_port", "smtp_port", "retry_limit") else ("get_bool" if dotted.split(".")[1] in ("debug_endpoints", "migrate_on_boot", "tls_required") else "get")
        lines.append(f'{const} = settings.{getter}("{dotted}")')
    lines += ["", "", f"def describe():", f'    return "{stem}"', ""]
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Case 3: invariant break
# ---------------------------------------------------------------------------

WORKERS = [
    "archive_logs", "backfill_index", "build_thumbnails", "check_quotas", "clean_tmp",
    "compact_segments", "dedupe_uploads", "export_ledger", "flush_metrics", "gc_sessions",
    "index_documents", "invalidate_cache", "mirror_bucket", "notify_admins", "prune_snapshots",
    "rebuild_search", "reconcile_billing", "refresh_tokens", "reindex_shards", "replay_events",
    "resize_images", "rotate_keys", "scan_malware", "seal_audit", "send_digests",
    "sync_contacts", "tally_usage", "trim_history", "unpack_bundles", "update_geoip",
    "verify_checksums", "warm_caches", "watch_quotas", "zip_reports", "audit_permissions",
    "expire_links", "merge_profiles", "purge_trash", "rank_results", "score_spam",
    "stamp_versions", "sweep_orphans", "tag_releases", "vacuum_tables",
]
BROKEN_WORKER = "reindex_shards"


def invariant_break() -> dict[str, str]:
    f: dict[str, str] = {}
    f["CONTRACT.md"] = (
        "# Worker contract\n\n"
        "Every module under `workers/` exposes `run(job, ctx)`.\n\n"
        "1. `job.ack()` MUST be called exactly once on every path that returns\n"
        "   normally, including early returns and paths that skip the work.\n"
        "2. A path that raises MUST NOT call `job.ack()` (the queue redelivers).\n"
        "3. Helpers may perform the ack on behalf of `run` as long as rule 1 holds\n"
        "   for the combined control flow.\n\n"
        "The queue treats a missing ack as a redelivery after the visibility\n"
        "timeout, so a worker that returns without acking duplicates its side\n"
        "effects forever.\n"
    )
    f["workers/__init__.py"] = ""
    f["workers/_base.py"] = '''"""Shared helpers for workers."""


def ack_and_return(job, value):
    job.ack()
    return value


def guarded(job, fn, *args):
    """Run fn; ack once whether or not it did any work."""
    try:
        return fn(*args)
    finally:
        job.ack()
'''
    for index, name in enumerate(WORKERS):
        f[f"workers/{name}.py"] = worker_module(name, index, broken=(name == BROKEN_WORKER))
    f["README.md"] = "# workers\n\nSee CONTRACT.md. Jobs come from the queue in `queue/`.\n"
    f["queue/__init__.py"] = ""
    f["queue/job.py"] = '''"""Queue job handle."""


class Job:
    def __init__(self, job_id, payload):
        self.id = job_id
        self.payload = payload
        self.acked = 0

    def ack(self):
        self.acked += 1
'''
    f["queue/dispatch.py"] = '''"""Dispatch a job to its worker module by name."""

import importlib


def dispatch(job, ctx):
    module = importlib.import_module("workers.%s" % job.payload["kind"])
    return module.run(job, ctx)
'''
    return f


def worker_module(name: str, index: int, broken: bool) -> str:
    shape = index % 6
    title = name.replace("_", " ")
    if broken:
        return f'''"""Reindex shards that drifted from the primary index."""

from workers import _base


def run(job, ctx):
    shards = ctx.index.shards(job.payload.get("index"))
    if not shards:
        job.ack()
        return 0
    reindexed = 0
    for shard in shards:
        if shard.is_locked():
            # Another reindex owns this shard; hand the job back for later.
            return reindexed
        ctx.index.reindex(shard)
        reindexed += 1
    job.ack()
    return reindexed
'''
    if shape == 0:
        return f'''"""{title.capitalize()}."""


def run(job, ctx):
    items = ctx.store.list(job.payload.get("scope", "*"))
    if not items:
        job.ack()
        return 0
    done = 0
    for item in items:
        ctx.store.{name.split("_")[0]}(item)
        done += 1
    job.ack()
    return done
'''
    if shape == 1:
        return f'''"""{title.capitalize()} (ack in finally)."""


def run(job, ctx):
    handled = 0
    try:
        for item in ctx.store.list(job.payload.get("scope", "*")):
            if ctx.policy.skip(item):
                continue
            ctx.store.{name.split("_")[0]}(item)
            handled += 1
        return handled
    finally:
        job.ack()
'''
    if shape == 2:
        return f'''"""{title.capitalize()} (ack through a helper)."""

from workers import _base


def run(job, ctx):
    scope = job.payload.get("scope")
    if scope is None:
        return _base.ack_and_return(job, 0)
    count = ctx.store.count(scope)
    if count == 0:
        return _base.ack_and_return(job, 0)
    ctx.store.{name.split("_")[0]}(scope)
    return _base.ack_and_return(job, count)
'''
    if shape == 3:
        return f'''"""{title.capitalize()} (guarded helper)."""

from workers import _base


def _work(ctx, scope):
    total = 0
    for item in ctx.store.list(scope):
        ctx.store.{name.split("_")[0]}(item)
        total += 1
    return total


def run(job, ctx):
    return _base.guarded(job, _work, ctx, job.payload.get("scope", "*"))
'''
    if shape == 4:
        return f'''"""{title.capitalize()} (raise path never acks)."""


def run(job, ctx):
    scope = job.payload.get("scope")
    if scope is None:
        raise ValueError("scope required")
    try:
        result = ctx.store.{name.split("_")[0]}(scope)
    except ctx.store.Transient:
        raise
    job.ack()
    return result
'''
    return f'''"""{title.capitalize()} (loop with continue)."""


def run(job, ctx):
    processed = 0
    for item in ctx.store.list(job.payload.get("scope", "*")):
        if item.stale():
            continue
        ctx.store.{name.split("_")[0]}(item)
        processed += 1
    job.ack()
    return processed
'''


def main(argv: list[str]) -> int:
    cases = {
        "taint_trace": taint_trace,
        "unused_setting": unused_setting,
        "invariant_break": invariant_break,
    }
    selected = argv[1:] or list(cases)
    for case in selected:
        files = cases[case]()
        write(files, case)
        print(f"{case}: {len(files)} files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
