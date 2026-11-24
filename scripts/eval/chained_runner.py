"""Chained-attempt native E2E runner: K sequential attempts per task on one
carried TinyKG store, two arms, order-balanced.

`run-paired` runs independent rollouts: every attempt starts with a fresh
fake HOME and an empty store, so it cannot measure whether what one attempt
leaves in memory helps the next one. A *chain* here is K sequential attempts
at one task, in one arm, for one replicate. Attempt 1 starts with an empty
store; after every attempt the runner exports the scenario's TinyKG store
(`<workspace>/.home/.metacodes/kg/store.kg[.v2]`) to a tar it owns, and the
next attempt of the same chain imports exactly that tar before its session
starts (`tests/e2e/lib.sh` `import_kg_store`). Every attempt runs with
`METACODES_TASK_HINT` = the task id and `METACODES_KG_DOMAIN` = the task's
chain domain (`chain_kg_domain`): the binary's default domain is derived from
the workspace's git root, which is a new run directory every attempt, and
project-scoped memory - lessons included - is recalled only from the
session's own domain and `global`. Nothing else carries over: the workspace
is the task's frozen snapshot again, and no store crosses chains, replicates
or arms.

Provenance is a hash-chained ledger per arm (`<chain-dir>/<arm>/ledger.jsonl`,
schema `metacodes-chain-ledger-v1`): one row per attempt with the sha256 of
the store it imported (null for attempt 1) and of the store it exported.
Attempt k's import must equal attempt k-1's export, every tar must still
hash to its row, `lib.sh` must have written an import witness with the same
hash (and none for attempt 1), and the ledger and the rollout checkpoint must
name the same attempts. Any break fails closed before another paid rollout:
a forked or silently reset memory would void the comparison.

Spend goes through the durable budget journal (`memory_budget_journal`), as
in every other paid runner: each attempt is reserved against the journal's
authority (the cumulative caps less the prior-spend offsets) at its full
per-rollout allowance, authorized before the session starts and committed
with its measured usage. From authorization on, an attempt is a paid attempt
whatever happens next. If anything after that point fails (the session, the
import witness, the store export, the evidence import, the commit), the
runner appends a `failed` ledger row and the journal keeps the transaction
authorized, so its whole allowance stays charged; resume refuses the chain
instead of running the attempt again. A runner killed before it can write
that row leaves the authorized transaction alone, which resume refuses the
same way.

Rollouts are the ordinary scored rows of `run-paired`, keyed by
`trial = replicate * attempts + (attempt - 1)`, so `cli.py compare` pairs
attempt k of replicate r across arms. The store is exported before the
rollout is imported, so the offline grade (the task's success check, which
`import_run` runs on the final workspace) can never reach the store or any
prompt.
"""

from __future__ import annotations

import fnmatch
import hashlib
import io
import json
import os
import stat
import tarfile
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional, Tuple, Union

from .e2e_adapter import import_run
from .memory_budget_journal import (
    BudgetAuthority,
    BudgetJournal,
    BudgetTransaction,
    TransactionNotAbortable,
    usd_to_microusd,
    usd_to_microusd_ceiling,
)
from .model import ValidationError, stable_json, write_rollouts
from . import paired_runner


LEDGER_SCHEMA = "metacodes-chain-ledger-v1"
STATUS_EXPORTED = "exported"
STATUS_FAILED = "failed"
VARIANTS = ("baseline", "candidate")
# The local exclusive store and the daemon store (`kgd/install.zig`
# STORE_NAME); whichever transport the session used, both are carried.
STORE_ENTRIES = ("store.kg", "store.kg.v2")
MAX_STORE_EXPORT_BYTES = 512 * 1024 * 1024
MAX_ATTEMPTS = 16
MAX_FAILURE_DETAIL = 1024
WITNESS_SUFFIX = ".kg-import.sha256"
BUDGET_AUTHORITY_CONTRACT = "metacodes-chained-budget-authority-v1"
BUDGET_TRANSACTION_CONTRACT = "metacodes-chained-budget-transaction-v1"
KG_DOMAIN_CONTRACT = "metacodes-chain-kg-domain-v1"


def chain_trial(replicate: int, attempt: int, attempts: int) -> int:
    """The rollout trial index of attempt `attempt` (1-based) of `replicate`."""
    if not 1 <= attempt <= attempts or replicate < 0:
        raise ValidationError(f"attempt {attempt} of replicate {replicate} is out of range")
    return replicate * attempts + attempt - 1


def chain_position(trial: int, attempts: int) -> Tuple[int, int]:
    """(replicate, attempt) of a rollout trial index."""
    return trial // attempts, trial % attempts + 1


def chain_kg_domain(task_id: str) -> str:
    """The TinyKG project domain of every attempt at `task_id`.

    The binary's default is `<git-root basename>-<8 hex of the git-root
    hash>` (apps/cli/src/app.zig `computeKgDomain`). A chained attempt's workspace is
    a new run directory, and with `GIT_INIT=1` a new git root, so the default
    changes every attempt while lessons are written to the session's project
    and recalled only from it and `global` (src/kg/client.zig
    `recallFiltered`): attempt k+1 would never see attempt k's lessons. This
    keeps the default's shape with the task id for the basename and a hash of
    the task id, so it is one value for every attempt, replicate and arm of a
    task. Chains stay apart through their stores, not their domain, and the
    variable is visible to the model's tools, so it must not name the arm or
    the replicate.
    """
    digest = hashlib.sha256(f"{KG_DOMAIN_CONTRACT}\0{task_id}".encode("utf-8")).hexdigest()
    domain = f"{task_id}-{digest[:8]}"
    if not 1 <= len(domain) <= 128 or not all(
        character.isascii() and (character.isalnum() or character in "-_.")
        for character in domain
    ):
        raise ValidationError(f"task id {task_id!r} cannot name a TinyKG domain")
    return domain


def chained_schedule(
    task_ids: List[str], replicates: int, attempts: int
) -> List[Tuple[int, int, str, str]]:
    """(replicate, attempt, task, variant) in run order.

    Replicates run one after another; within a replicate, attempt levels
    advance together (every task's attempt k, both arms, before any attempt
    k+1), so the attempts of one chain stay close in time and the two arms of
    a (task, replicate, attempt) always run back to back, which keeps
    provider drift out of the paired comparison. Within a (replicate, task)
    the arm that goes first alternates with the task index and the replicate.
    """
    if replicates <= 0:
        raise ValidationError("replicates must be > 0")
    if not 1 <= attempts <= MAX_ATTEMPTS:
        raise ValidationError(f"attempts must be 1..{MAX_ATTEMPTS}")
    if not task_ids:
        raise ValidationError("chained schedule requires at least one task")
    schedule: List[Tuple[int, int, str, str]] = []
    for replicate in range(replicates):
        for attempt in range(1, attempts + 1):
            for index, task_id in enumerate(sorted(task_ids)):
                order = VARIANTS if (index + replicate) % 2 == 0 else VARIANTS[::-1]
                schedule.extend((replicate, attempt, task_id, variant) for variant in order)
    return schedule


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _canonical_sha256(value: Any) -> str:
    return hashlib.sha256(stable_json(value).encode("utf-8")).hexdigest()


def _fsync_dir(path: Path) -> None:
    if os.name == "nt":
        return
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def export_store(kg_dir: Path, destination: Path) -> Tuple[str, List[str], int]:
    """Tar the TinyKG store entries under `kg_dir` to `destination`.

    Deterministic (sorted names, zero mtimes and owners, normalized modes) and
    strict: only regular files and directories are carried, because the
    workspace and its fake HOME are writable by the model's tools. A missing
    store is an empty archive, so an attempt that never opened TinyKG still
    advances the chain. Returns (sha256, carried top-level entries, bytes).
    """
    members: List[Tuple[str, Path, bool]] = []
    carried: List[str] = []
    total = 0
    for name in STORE_ENTRIES:
        top = kg_dir / name
        if not os.path.lexists(top):
            continue
        carried.append(name)
        pending = [(name, top)]
        while pending:
            arcname, path = pending.pop()
            info = os.lstat(path)
            if stat.S_ISDIR(info.st_mode):
                members.append((arcname, path, True))
                for child in sorted(os.listdir(path), reverse=True):
                    pending.append((f"{arcname}/{child}", path / child))
            elif stat.S_ISREG(info.st_mode):
                total += info.st_size
                if total > MAX_STORE_EXPORT_BYTES:
                    raise ValidationError(
                        f"TinyKG store under {kg_dir} exceeds {MAX_STORE_EXPORT_BYTES} bytes"
                    )
                members.append((arcname, path, False))
            else:
                raise ValidationError(
                    f"TinyKG store entry is not a regular file or directory: {path}"
                )
    members.sort(key=lambda member: member[0])
    destination.parent.mkdir(parents=True, exist_ok=True)
    temp_path: Optional[Path] = None
    try:
        with tempfile.NamedTemporaryFile(
            dir=destination.parent, prefix=f".{destination.name}.", suffix=".tmp", delete=False
        ) as handle:
            temp_path = Path(handle.name)
            with tarfile.open(fileobj=handle, mode="w", format=tarfile.PAX_FORMAT) as archive:
                for arcname, path, is_dir in members:
                    info = tarfile.TarInfo(arcname)
                    info.mtime = 0
                    info.uid = info.gid = 0
                    info.uname = info.gname = ""
                    if is_dir:
                        info.type = tarfile.DIRTYPE
                        info.mode = 0o700
                        archive.addfile(info)
                    else:
                        payload = path.read_bytes()
                        info.size = len(payload)
                        info.mode = 0o600
                        archive.addfile(info, io.BytesIO(payload))
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_path, destination)
        temp_path = None
        _fsync_dir(destination.parent)
    finally:
        if temp_path is not None:
            try:
                temp_path.unlink()
            except OSError:
                pass
    return _sha256_file(destination), carried, destination.stat().st_size


@dataclass(frozen=True)
class LedgerRow:
    """A completed attempt: it ran, its witness held and its store is sealed."""

    variant: str
    task_id: str
    replicate: int
    attempt: int
    trial: int
    store_import_sha256: Optional[str]
    store_export_sha256: str
    store_entries: Tuple[str, ...]
    export_bytes: int
    archive: str
    run_dir: str
    kg_domain: str
    budget_transaction_id: str

    def as_json(self) -> Dict[str, Any]:
        return {
            "schema_version": LEDGER_SCHEMA,
            "status": STATUS_EXPORTED,
            "variant": self.variant,
            "task_id": self.task_id,
            "replicate": self.replicate,
            "attempt": self.attempt,
            "trial": self.trial,
            "store_import_sha256": self.store_import_sha256,
            "store_export_sha256": self.store_export_sha256,
            "store_entries": list(self.store_entries),
            "export_bytes": self.export_bytes,
            "archive": self.archive,
            "run_dir": self.run_dir,
            "kg_domain": self.kg_domain,
            "budget_transaction_id": self.budget_transaction_id,
        }


@dataclass(frozen=True)
class FailedAttempt:
    """A paid attempt that did not complete: authorized, then anything after
    that failed. Its transaction stays authorized in the budget journal."""

    variant: str
    task_id: str
    replicate: int
    attempt: int
    trial: int
    store_import_sha256: Optional[str]
    kg_domain: str
    budget_transaction_id: str
    run_dir: Optional[str]
    error: str

    def as_json(self) -> Dict[str, Any]:
        return {
            "schema_version": LEDGER_SCHEMA,
            "status": STATUS_FAILED,
            "variant": self.variant,
            "task_id": self.task_id,
            "replicate": self.replicate,
            "attempt": self.attempt,
            "trial": self.trial,
            "store_import_sha256": self.store_import_sha256,
            "kg_domain": self.kg_domain,
            "budget_transaction_id": self.budget_transaction_id,
            "run_dir": self.run_dir,
            "error": self.error,
        }


LedgerEntry = Union[LedgerRow, FailedAttempt]


def _archive_relpath(variant: str, task_id: str, replicate: int, attempt: int) -> str:
    return f"{variant}/{task_id}/r{replicate}/attempt-{attempt}.tar"


def _parse_ledger_row(raw: Any, where: str) -> LedgerEntry:
    if not isinstance(raw, dict) or raw.get("schema_version") != LEDGER_SCHEMA:
        raise ValidationError(f"{where}: not a {LEDGER_SCHEMA} row")
    status = raw.get("status")
    row: LedgerEntry
    try:
        if status == STATUS_EXPORTED:
            row = LedgerRow(
                variant=raw["variant"],
                task_id=raw["task_id"],
                replicate=raw["replicate"],
                attempt=raw["attempt"],
                trial=raw["trial"],
                store_import_sha256=raw["store_import_sha256"],
                store_export_sha256=raw["store_export_sha256"],
                store_entries=tuple(raw["store_entries"]),
                export_bytes=raw["export_bytes"],
                archive=raw["archive"],
                run_dir=raw["run_dir"],
                kg_domain=raw["kg_domain"],
                budget_transaction_id=raw["budget_transaction_id"],
            )
        elif status == STATUS_FAILED:
            row = FailedAttempt(
                variant=raw["variant"],
                task_id=raw["task_id"],
                replicate=raw["replicate"],
                attempt=raw["attempt"],
                trial=raw["trial"],
                store_import_sha256=raw["store_import_sha256"],
                kg_domain=raw["kg_domain"],
                budget_transaction_id=raw["budget_transaction_id"],
                run_dir=raw["run_dir"],
                error=raw["error"],
            )
        else:
            raise ValidationError(f"{where}: unknown ledger row status {status!r}")
    except (KeyError, TypeError) as exc:
        raise ValidationError(f"{where}: malformed ledger row ({exc})") from exc
    names = ("replicate", "attempt", "trial") + (
        ("export_bytes",) if isinstance(row, LedgerRow) else ()
    )
    for name in names:
        value = getattr(row, name)
        if not isinstance(value, int) or isinstance(value, bool) or value < 0:
            raise ValidationError(f"{where}: {name} must be a non-negative integer")
    return row


def load_ledger(path: Path, variant: str) -> List[LedgerEntry]:
    if not path.exists():
        return []
    rows: List[LedgerEntry] = []
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        try:
            raw = json.loads(line)
        except json.JSONDecodeError as exc:
            raise ValidationError(f"{path}:{number}: invalid JSON ({exc})") from exc
        row = _parse_ledger_row(raw, f"{path}:{number}")
        if row.variant != variant:
            raise ValidationError(f"{path}:{number}: row belongs to arm {row.variant!r}")
        rows.append(row)
    return rows


def _append_ledger(path: Path, row: LedgerEntry) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    line = json.dumps(row.as_json(), sort_keys=True) + "\n"
    with open(path, "a", encoding="utf-8", newline="\n") as handle:
        handle.write(line)
        handle.flush()
        os.fsync(handle.fileno())


def validate_chains(
    rows: List[LedgerEntry],
    *,
    chain_dir: Path,
    attempts: int,
    expected_tasks: Mapping[str, Any],
    replicates: int,
    checkpoint_keys: set,
) -> Dict[Tuple[str, int, int], LedgerRow]:
    """Every ledger row's archive still hashes to it, every chain links, and
    the ledger names exactly the attempts the checkpoint holds. A paid
    attempt that did not complete stops everything: it is never re-run."""
    for row in rows:
        if isinstance(row, FailedAttempt):
            raise ValidationError(
                f"{row.variant} chain {row.task_id!r} r{row.replicate} attempt {row.attempt} "
                f"was authorized and did not complete ({row.error}); its budget transaction "
                f"{row.budget_transaction_id} stays charged at its full allowance and a paid "
                "attempt is never repeated automatically, so the chain needs an operator decision"
            )
    by_key: Dict[Tuple[str, int, int], LedgerRow] = {}
    for row in rows:
        assert isinstance(row, LedgerRow)
        key = (row.task_id, row.replicate, row.attempt)
        if key in by_key:
            raise ValidationError(f"chain ledger repeats attempt {key!r}")
        if (
            row.task_id not in expected_tasks
            or row.replicate >= replicates
            or not 1 <= row.attempt <= attempts
            or row.trial != chain_trial(row.replicate, row.attempt, attempts)
        ):
            raise ValidationError(f"chain ledger row {key!r} is out of scope")
        if row.archive != _archive_relpath(row.variant, row.task_id, row.replicate, row.attempt):
            raise ValidationError(f"chain ledger row {key!r} names an unexpected archive")
        if row.kg_domain != chain_kg_domain(row.task_id):
            raise ValidationError(f"chain ledger row {key!r} ran in another TinyKG domain")
        archive = chain_dir / row.archive
        if not archive.is_file() or _sha256_file(archive) != row.store_export_sha256:
            raise ValidationError(f"chain archive for {key!r} is missing or changed")
        by_key[key] = row
    for (task_id, replicate, attempt), row in by_key.items():
        if attempt == 1:
            if row.store_import_sha256 is not None:
                raise ValidationError(f"chain {task_id!r} r{replicate} attempt 1 imported a store")
            continue
        previous = by_key.get((task_id, replicate, attempt - 1))
        if previous is None or row.store_import_sha256 != previous.store_export_sha256:
            raise ValidationError(
                f"chain {task_id!r} r{replicate} is broken at attempt {attempt}"
            )
    ledger_keys = {(row.task_id, row.trial) for row in by_key.values()}
    if ledger_keys != checkpoint_keys:
        raise ValidationError(
            "chain ledger and rollout checkpoint disagree: "
            f"ledger-only {sorted(ledger_keys - checkpoint_keys)}, "
            f"checkpoint-only {sorted(checkpoint_keys - ledger_keys)}"
        )
    return by_key


def _verify_import_witness(run_dir: Path, task_id: str, expected: Optional[str]) -> None:
    witness = run_dir / f"{task_id}{WITNESS_SUFFIX}"
    if expected is None:
        if os.path.lexists(witness):
            raise ValidationError(f"attempt 1 of {task_id!r} reports a store import: {witness}")
        return
    try:
        observed = witness.read_text(encoding="utf-8").strip()
    except OSError as exc:
        raise ValidationError(f"no store import witness for {task_id!r} at {witness}") from exc
    if observed != expected:
        raise ValidationError(f"store import witness for {task_id!r} does not match the chain")


def _require_journal_outside(journal: Path, directories: List[Path]) -> Path:
    """The journal is the spend record that outlives a discarded run: it may
    not live under the chain directory or next to the rollout outputs."""
    path = journal.expanduser()
    if not path.is_absolute():
        path = (Path.cwd() / path).absolute()
    path = path.resolve(strict=False)
    for directory in directories:
        owned = directory.expanduser()
        if not owned.is_absolute():
            owned = (Path.cwd() / owned).absolute()
        owned = owned.resolve(strict=False)
        if path == owned or owned in path.parents:
            raise ValidationError(
                f"budget journal must be outside the chain directory and the output "
                f"directories: {path} is under {owned}"
            )
    return path


def rollout_evidence_sha256(rollout: Mapping[str, Any]) -> str:
    """Digest of a rollout without its budget receipt, sealed into the
    journal's committed event so a receipt cannot move to another body."""
    return _canonical_sha256(
        {key: value for key, value in rollout.items() if key != "budget_transaction"}
    )


def _chain_transaction(
    authority: BudgetAuthority,
    *,
    task: Mapping[str, Any],
    variant: str,
    replicate: int,
    attempt: int,
    trial: int,
    revision: str,
    binary_sha256: str,
    store_import_sha256: Optional[str],
    kg_domain: str,
    max_cost_usd: float,
    max_metered_tokens: int,
) -> BudgetTransaction:
    harness_fingerprint = _canonical_sha256(
        {
            "contract": BUDGET_TRANSACTION_CONTRACT,
            "variant": variant,
            "task_id": task["id"],
            "task_sha256": _canonical_sha256(task),
            "replicate": replicate,
            "attempt": attempt,
            "trial": trial,
            "revision": revision,
            "binary_sha256": binary_sha256,
            "store_import_sha256": store_import_sha256,
            "kg_domain": kg_domain,
            "max_cost_microusd": usd_to_microusd(max_cost_usd),
            "max_metered_tokens": max_metered_tokens,
        }
    )
    return BudgetTransaction(
        run_id=f"chained:{variant}:{task['id']}:r{replicate}:a{attempt}",
        manifest_sha256=authority.manifest_sha256,
        model_fingerprint=authority.model_fingerprint,
        harness_fingerprint=harness_fingerprint,
        provider_identity=authority.provider_identity,
        max_cost_microusd=usd_to_microusd(max_cost_usd),
        max_metered_tokens=max_metered_tokens,
    )


def _failure_detail(exc: BaseException) -> str:
    detail = f"{type(exc).__name__}: {exc}"
    return detail[:MAX_FAILURE_DETAIL]


def run_chained(
    suite: Dict[str, Any],
    repo_root: Path,
    baseline_binary: Path,
    candidate_binary: Path,
    *,
    replicates: int,
    attempts: int,
    scenario_glob: str,
    model_provider: str,
    model_id: str,
    baseline_output: Path,
    candidate_output: Path,
    baseline_revision: str,
    candidate_revision: str,
    chain_dir: Path,
    budget_journal_path: Path,
    max_cumulative_cost_usd: float,
    max_cumulative_tokens: int,
    max_rollout_cost_usd: float,
    max_rollout_metered_tokens: int,
    suite_path: Path | None = None,
    budget_used_cost_usd: float = 0.0,
    budget_used_tokens: int = 0,
) -> Tuple[List[Dict[str, Any]], List[Dict[str, Any]]]:
    """Run (or resume) every chain of both arms. Returns the scored rollouts.

    Every attempt is a paid request, so all four caps and the budget journal
    are required; the caps follow `run-paired`'s rules exactly.
    """
    caps = (
        max_cumulative_cost_usd,
        max_cumulative_tokens,
        max_rollout_cost_usd,
        max_rollout_metered_tokens,
    )
    if any(value is None for value in caps):
        raise ValidationError(
            "run-chained requires cumulative and per-rollout caps for both cost and tokens"
        )
    if budget_journal_path is None:
        raise ValidationError("run-chained requires an explicit budget journal")
    paired_runner._validate_budget_caps(
        budget_used_cost_usd=budget_used_cost_usd,
        budget_used_tokens=budget_used_tokens,
        max_cumulative_cost_usd=max_cumulative_cost_usd,
        max_cumulative_tokens=max_cumulative_tokens,
        max_rollout_cost_usd=max_rollout_cost_usd,
        max_rollout_metered_tokens=max_rollout_metered_tokens,
    )
    for binary in (baseline_binary, candidate_binary):
        if not binary.is_file() or not os.access(binary, os.X_OK):
            raise ValidationError(f"binary is not executable: {binary}")
    binaries = {"baseline": baseline_binary, "candidate": candidate_binary}
    binary_sha256 = {variant: _sha256_file(binaries[variant]) for variant in VARIANTS}
    effective_suite_path = suite_path or (repo_root / "evals/suites/core-e2e.json")
    if not effective_suite_path.is_file():
        raise ValidationError(f"evaluation suite file does not exist: {effective_suite_path}")
    expected_tasks = {
        task["id"]: task for task in suite["tasks"] if fnmatch.fnmatch(task["id"], scenario_glob)
    }
    if not expected_tasks:
        raise ValidationError(f"scenario glob matches no scored suite tasks: {scenario_glob}")
    kg_domains = {task_id: chain_kg_domain(task_id) for task_id in expected_tasks}
    schedule = chained_schedule(list(expected_tasks), replicates, attempts)
    revisions = {"baseline": baseline_revision.strip(), "candidate": candidate_revision.strip()}
    for variant, revision in revisions.items():
        if not revision:
            raise ValidationError(f"{variant} revision must be non-empty")
    outputs = {"baseline": baseline_output, "candidate": candidate_output}
    journal_path = _require_journal_outside(
        budget_journal_path, [chain_dir, baseline_output.parent, candidate_output.parent]
    )
    rollout_cost_usd = float(max_rollout_cost_usd)
    prior_cost_microusd = usd_to_microusd_ceiling(budget_used_cost_usd)
    authority_cost = usd_to_microusd(max_cumulative_cost_usd) - prior_cost_microusd
    authority_tokens = max_cumulative_tokens - budget_used_tokens
    if authority_cost <= 0 or authority_tokens <= 0:
        raise ValidationError("the budget-used offsets already exhaust the cumulative caps")
    authority_manifest = {
        "contract": BUDGET_AUTHORITY_CONTRACT,
        "suite_id": suite["suite_id"],
        "suite_sha256": _canonical_sha256(suite),
        "tasks": sorted(expected_tasks),
        "replicates": replicates,
        "attempts": attempts,
        "model": {"provider": model_provider, "id": model_id},
        "revisions": revisions,
        "binary_sha256": binary_sha256,
        "prior_cost_microusd": prior_cost_microusd,
        "prior_metered_tokens": budget_used_tokens,
        "max_cumulative_cost_microusd": usd_to_microusd(max_cumulative_cost_usd),
        "max_cumulative_tokens": max_cumulative_tokens,
        "max_rollout_cost_microusd": usd_to_microusd(rollout_cost_usd),
        "max_rollout_metered_tokens": max_rollout_metered_tokens,
    }
    authority = BudgetAuthority(
        manifest_sha256=_canonical_sha256(authority_manifest),
        model_fingerprint=_canonical_sha256({"provider": model_provider, "id": model_id}),
        provider_identity=f"{model_provider}:{model_id}",
        total_cost_microusd=authority_cost,
        total_metered_tokens=authority_tokens,
    )
    trials = replicates * attempts
    with BudgetJournal(journal_path, authority) as journal:
        collected = {
            variant: paired_runner._load_checkpoint(
                outputs[variant],
                variant=variant,
                suite=suite,
                repo_root=repo_root,
                binary=binaries[variant],
                trials=trials,
                expected_tasks=expected_tasks,
                model_provider=model_provider,
                model_id=model_id,
                harness_revision=revisions[variant],
                require_runtime_budget=True,
            )
            for variant in VARIANTS
        }
        ledger_paths = {variant: chain_dir / variant / "ledger.jsonl" for variant in VARIANTS}
        chains = {
            variant: validate_chains(
                load_ledger(ledger_paths[variant], variant),
                chain_dir=chain_dir,
                attempts=attempts,
                expected_tasks=expected_tasks,
                replicates=replicates,
                checkpoint_keys={(item["task_id"], item["trial"]) for item in collected[variant]},
            )
            for variant in VARIANTS
        }

        def transaction_for(
            variant: str, task_id: str, replicate: int, attempt: int, store_import: Optional[str]
        ) -> BudgetTransaction:
            return _chain_transaction(
                authority,
                task=expected_tasks[task_id],
                variant=variant,
                replicate=replicate,
                attempt=attempt,
                trial=chain_trial(replicate, attempt, attempts),
                revision=revisions[variant],
                binary_sha256=binary_sha256[variant],
                store_import_sha256=store_import,
                kg_domain=kg_domains[task_id],
                max_cost_usd=rollout_cost_usd,
                max_metered_tokens=max_rollout_metered_tokens,
            )

        # Every checkpoint row carries the receipt of the transaction that
        # paid for it, the ledger names the same transaction, and nothing in
        # the journal is authorized or spent without a checkpoint row.
        checkpoint_transactions: set = set()
        for variant in VARIANTS:
            for rollout in collected[variant]:
                replicate, attempt = chain_position(rollout["trial"], attempts)
                row = chains[variant][(rollout["task_id"], replicate, attempt)]
                paired_runner._require_runtime_budget_provenance(
                    rollout,
                    max_metered_tokens=max_rollout_metered_tokens,
                    max_cost_usd=rollout_cost_usd,
                )
                transaction_id = paired_runner._validate_checkpoint_budget_receipt(
                    rollout,
                    journal=journal,
                    transaction=transaction_for(
                        variant, row.task_id, replicate, attempt, row.store_import_sha256
                    ),
                )
                if transaction_id != row.budget_transaction_id:
                    raise ValidationError(
                        f"{variant} chain {row.task_id!r} r{replicate} attempt {attempt}: the "
                        "ledger and the rollout name different budget transactions"
                    )
                if journal.transaction_evidence_sha256(transaction_id) != rollout_evidence_sha256(
                    rollout
                ):
                    raise ValidationError(
                        f"{variant} rollout {(row.task_id, rollout['trial'])!r} does not match "
                        "the evidence sealed in the budget journal"
                    )
                if transaction_id in checkpoint_transactions:
                    raise ValidationError(
                        "a budget transaction is attached to more than one rollout"
                    )
                checkpoint_transactions.add(transaction_id)
        paired_runner._require_no_orphan_budget_transactions(journal, checkpoint_transactions)

        def require_budget() -> None:
            paired_runner._require_budget(
                collected,
                used_cost_usd=budget_used_cost_usd,
                used_tokens=budget_used_tokens,
                max_cumulative_cost_usd=max_cumulative_cost_usd,
                max_cumulative_tokens=max_cumulative_tokens,
            )

        require_budget()
        for replicate, attempt, task_id, variant in schedule:
            if (task_id, replicate, attempt) in chains[variant]:
                continue
            trial = chain_trial(replicate, attempt, attempts)
            store_import: Optional[Tuple[Path, str]] = None
            imported_entries: Tuple[str, ...] = ()
            if attempt > 1:
                previous = chains[variant].get((task_id, replicate, attempt - 1))
                if previous is None:
                    raise ValidationError(
                        f"{variant} chain {task_id!r} r{replicate} has no attempt {attempt - 1}"
                    )
                store_import = (chain_dir / previous.archive, previous.store_export_sha256)
                imported_entries = previous.store_entries
            import_sha256 = store_import[1] if store_import is not None else None
            require_budget()
            paired_runner._require_rollout_reservation(
                collected,
                used_cost_usd=budget_used_cost_usd,
                used_tokens=budget_used_tokens,
                rollout_cost_usd=rollout_cost_usd,
                rollout_tokens=max_rollout_metered_tokens,
                max_cumulative_cost_usd=max_cumulative_cost_usd,
                max_cumulative_tokens=max_cumulative_tokens,
            )
            paired_runner._require_sha256(
                binaries[variant], binary_sha256[variant], f"{variant} binary"
            )
            # The journal re-checks the reservation against everything it
            # has charged, including attempts that never committed.
            reserved = journal.reserve(
                transaction_for(variant, task_id, replicate, attempt, import_sha256)
            )
            transaction_id = str(reserved["transaction_id"])
            try:
                journal.authorize_request(
                    transaction_id,
                    expected_revision=int(reserved["journal_revision"]),
                    expected_head_sha256=str(reserved["journal_head_sha256"]),
                )
            except BaseException as failure:
                # Nothing has been sent. An authorization that never became
                # durable leaves the reservation, which the abort releases; a
                # durable one is refused as not abortable and stays charged.
                try:
                    journal.abort_pre_request(transaction_id)
                except TransactionNotAbortable:
                    pass
                except ValidationError as abort_failure:
                    raise ValidationError(
                        f"pre-authorization failure left transaction {transaction_id} "
                        f"reserved and its abort could not be recorded: {abort_failure}"
                    ) from failure
                raise
            # From here the attempt may have spent money: whatever fails is
            # recorded as a failed attempt before the error propagates.
            run_dir: Optional[Path] = None
            try:
                run_dir = paired_runner._run_once(
                    repo_root,
                    binaries[variant],
                    variant,
                    trial,
                    paired_runner.scenario_selector([task_id]),
                    model_provider,
                    model_id,
                    effective_suite_path,
                    revisions[variant],
                    timeout_seconds=expected_tasks[task_id]["constraints"]["timeout_seconds"],
                    task_hint=task_id,
                    kg_domain=kg_domains[task_id],
                    store_import=store_import,
                    max_cost_usd=rollout_cost_usd,
                    max_metered_tokens=max_rollout_metered_tokens,
                )
                _verify_import_witness(run_dir, task_id, import_sha256)
                # Export before import_run: the offline grade runs on the
                # workspace only after the store this attempt leaves is sealed.
                relpath = _archive_relpath(variant, task_id, replicate, attempt)
                export_sha256, entries, export_bytes = export_store(
                    run_dir / task_id / ".home" / ".metacodes" / "kg", chain_dir / relpath
                )
                # An attempt that never opened TinyKG exports an empty archive
                # and the next one imports nothing; what was imported, though,
                # must still be there to be carried on.
                vanished = sorted(set(imported_entries) - set(entries))
                if vanished:
                    raise ValidationError(
                        f"{variant} chain {task_id!r} r{replicate} attempt {attempt}: "
                        f"the imported store vanished ({', '.join(vanished)})"
                    )
                row = LedgerRow(
                    variant=variant,
                    task_id=task_id,
                    replicate=replicate,
                    attempt=attempt,
                    trial=trial,
                    store_import_sha256=import_sha256,
                    store_export_sha256=export_sha256,
                    store_entries=tuple(entries),
                    export_bytes=export_bytes,
                    archive=relpath,
                    run_dir=str(run_dir),
                    kg_domain=kg_domains[task_id],
                    budget_transaction_id=transaction_id,
                )
                _append_ledger(ledger_paths[variant], row)
                chains[variant][(task_id, replicate, attempt)] = row
                rollouts = import_run(suite, repo_root, run_dir)
                selected = [
                    rollout
                    for rollout in rollouts
                    if rollout["task_id"] == task_id
                    and rollout["trial"] == trial
                    and rollout["task_fingerprint_provenance"] == "recorded_at_execution"
                ]
                if len(selected) != 1:
                    raise ValidationError(
                        f"{variant} chain {task_id!r} r{replicate} attempt {attempt}: expected "
                        "one execution-grounded rollout"
                    )
                paired_runner._require_runtime_budget_provenance(
                    selected[0],
                    max_metered_tokens=max_rollout_metered_tokens,
                    max_cost_usd=rollout_cost_usd,
                )
                receipt = journal.commit(
                    transaction_id,
                    actual_cost_microusd=usd_to_microusd_ceiling(
                        selected[0]["metrics"]["cost_usd"]
                    ),
                    actual_metered_tokens=paired_runner._rollout_metered_tokens(selected[0]),
                    evidence_sha256=rollout_evidence_sha256(selected[0]),
                )
                selected[0]["budget_transaction"] = dict(receipt)
                collected[variant].extend(selected)
                write_rollouts(outputs[variant], collected[variant])
            except BaseException as failure:
                try:
                    _append_ledger(
                        ledger_paths[variant],
                        FailedAttempt(
                            variant=variant,
                            task_id=task_id,
                            replicate=replicate,
                            attempt=attempt,
                            trial=trial,
                            store_import_sha256=import_sha256,
                            kg_domain=kg_domains[task_id],
                            budget_transaction_id=transaction_id,
                            run_dir=str(run_dir) if run_dir is not None else None,
                            error=_failure_detail(failure),
                        ),
                    )
                except Exception as record_failure:  # pragma: no cover - disk failure
                    raise ValidationError(
                        f"paid attempt {(variant, task_id, trial)!r} failed and its failure "
                        f"could not be recorded: {record_failure}; the journal still holds "
                        f"transaction {transaction_id} as authorized"
                    ) from failure
                raise
            paired_runner._require_scoring_rollout(selected[0], variant=variant)
            require_budget()
    return collected["baseline"], collected["candidate"]
