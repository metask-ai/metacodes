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
`METACODES_TASK_HINT` = the task id. Nothing else carries over: the
workspace is the task's frozen snapshot again, and no store crosses chains,
replicates or arms.

Provenance is a hash-chained ledger per arm (`<chain-dir>/<arm>/ledger.jsonl`,
schema `metacodes-chain-ledger-v1`): one row per attempt with the sha256 of
the store it imported (null for attempt 1) and of the store it exported.
Attempt k's import must equal attempt k-1's export, every tar must still
hash to its row, `lib.sh` must have written an import witness with the same
hash (and none for attempt 1), and the ledger and the rollout checkpoint must
name the same attempts. Any break fails closed before another paid rollout:
a forked or silently reset memory would void the comparison. The ledger row
is written before the rollout checkpoint, so an attempt that ran but whose
rollout was never recorded (a crash in between, or evidence that would not
import) shows as a ledger-only attempt; resume refuses it and leaves the
decision to the operator instead of re-running a paid attempt.

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
import math
import os
import stat
import tarfile
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional, Tuple

from .e2e_adapter import import_run
from .model import ValidationError, write_rollouts
from . import paired_runner


LEDGER_SCHEMA = "metacodes-chain-ledger-v1"
VARIANTS = ("baseline", "candidate")
# The local exclusive store and the daemon store (`kgd/install.zig`
# STORE_NAME); whichever transport the session used, both are carried.
STORE_ENTRIES = ("store.kg", "store.kg.v2")
MAX_STORE_EXPORT_BYTES = 512 * 1024 * 1024
MAX_ATTEMPTS = 16
WITNESS_SUFFIX = ".kg-import.sha256"


def chain_trial(replicate: int, attempt: int, attempts: int) -> int:
    """The rollout trial index of attempt `attempt` (1-based) of `replicate`."""
    if not 1 <= attempt <= attempts or replicate < 0:
        raise ValidationError(f"attempt {attempt} of replicate {replicate} is out of range")
    return replicate * attempts + attempt - 1


def chain_position(trial: int, attempts: int) -> Tuple[int, int]:
    """(replicate, attempt) of a rollout trial index."""
    return trial // attempts, trial % attempts + 1


def chained_schedule(
    task_ids: List[str], replicates: int, attempts: int
) -> List[Tuple[int, int, str, str]]:
    """(replicate, attempt, task, variant) in run order.

    Attempt levels advance together (every chain's attempt k before any
    attempt k+1 of the same replicate), so the two arms of a task are never
    more than one attempt apart in time. Within a (replicate, task) the arm
    that goes first alternates with the task index and the replicate.
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

    def as_json(self) -> Dict[str, Any]:
        return {
            "schema_version": LEDGER_SCHEMA,
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
        }


def _archive_relpath(variant: str, task_id: str, replicate: int, attempt: int) -> str:
    return f"{variant}/{task_id}/r{replicate}/attempt-{attempt}.tar"


def _parse_ledger_row(raw: Any, where: str) -> LedgerRow:
    if not isinstance(raw, dict) or raw.get("schema_version") != LEDGER_SCHEMA:
        raise ValidationError(f"{where}: not a {LEDGER_SCHEMA} row")
    try:
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
        )
    except (KeyError, TypeError) as exc:
        raise ValidationError(f"{where}: malformed ledger row ({exc})") from exc
    for name in ("replicate", "attempt", "trial", "export_bytes"):
        value = getattr(row, name)
        if not isinstance(value, int) or isinstance(value, bool) or value < 0:
            raise ValidationError(f"{where}: {name} must be a non-negative integer")
    return row


def load_ledger(path: Path, variant: str) -> List[LedgerRow]:
    if not path.exists():
        return []
    rows: List[LedgerRow] = []
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


def _append_ledger(path: Path, row: LedgerRow) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    line = json.dumps(row.as_json(), sort_keys=True) + "\n"
    with open(path, "a", encoding="utf-8", newline="\n") as handle:
        handle.write(line)
        handle.flush()
        os.fsync(handle.fileno())


def validate_chains(
    rows: List[LedgerRow],
    *,
    chain_dir: Path,
    attempts: int,
    expected_tasks: Mapping[str, Any],
    replicates: int,
    checkpoint_keys: set,
) -> Dict[Tuple[str, int, int], LedgerRow]:
    """Every ledger row's archive still hashes to it, every chain links, and
    the ledger names exactly the attempts the checkpoint holds."""
    by_key: Dict[Tuple[str, int, int], LedgerRow] = {}
    for row in rows:
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
    suite_path: Path | None = None,
    budget_used_cost_usd: float = 0.0,
    budget_used_tokens: int = 0,
    max_cumulative_cost_usd: float | None = None,
    max_cumulative_tokens: int | None = None,
    max_rollout_cost_usd: float | None = None,
    max_rollout_metered_tokens: int | None = None,
) -> Tuple[List[Dict[str, Any]], List[Dict[str, Any]]]:
    """Run (or resume) every chain of both arms. Returns the scored rollouts."""
    if (
        not math.isfinite(budget_used_cost_usd)
        or budget_used_cost_usd < 0
        or budget_used_tokens < 0
    ):
        raise ValidationError("budget usage offsets must be non-negative")
    if (max_rollout_cost_usd is None) != (max_rollout_metered_tokens is None):
        raise ValidationError("per-rollout budget requires both cost and token caps")
    if max_rollout_cost_usd is not None and (
        not math.isfinite(float(max_rollout_cost_usd)) or float(max_rollout_cost_usd) <= 0
    ):
        raise ValidationError("per-rollout max cost must be finite and > 0")
    if max_rollout_metered_tokens is not None and max_rollout_metered_tokens <= 0:
        raise ValidationError("per-rollout max metered tokens must be > 0")
    for binary in (baseline_binary, candidate_binary):
        if not binary.is_file() or not os.access(binary, os.X_OK):
            raise ValidationError(f"binary is not executable: {binary}")
    binaries = {"baseline": baseline_binary, "candidate": candidate_binary}
    effective_suite_path = suite_path or (repo_root / "evals/suites/core-e2e.json")
    if not effective_suite_path.is_file():
        raise ValidationError(f"evaluation suite file does not exist: {effective_suite_path}")
    expected_tasks = {
        task["id"]: task for task in suite["tasks"] if fnmatch.fnmatch(task["id"], scenario_glob)
    }
    if not expected_tasks:
        raise ValidationError(f"scenario glob matches no scored suite tasks: {scenario_glob}")
    schedule = chained_schedule(list(expected_tasks), replicates, attempts)
    revisions = {"baseline": baseline_revision.strip(), "candidate": candidate_revision.strip()}
    for variant, revision in revisions.items():
        if not revision:
            raise ValidationError(f"{variant} revision must be non-empty")
    outputs = {"baseline": baseline_output, "candidate": candidate_output}
    trials = replicates * attempts
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
        if attempt > 1:
            previous = chains[variant].get((task_id, replicate, attempt - 1))
            if previous is None:
                raise ValidationError(
                    f"{variant} chain {task_id!r} r{replicate} has no attempt {attempt - 1}"
                )
            store_import = (chain_dir / previous.archive, previous.store_export_sha256)
        require_budget()
        options: Dict[str, Any] = {
            "timeout_seconds": expected_tasks[task_id]["constraints"]["timeout_seconds"],
            "task_hint": task_id,
            "store_import": store_import,
        }
        if max_rollout_cost_usd is not None:
            paired_runner._require_rollout_reservation(
                collected,
                used_cost_usd=budget_used_cost_usd,
                used_tokens=budget_used_tokens,
                rollout_cost_usd=float(max_rollout_cost_usd),
                rollout_tokens=max_rollout_metered_tokens,
                max_cumulative_cost_usd=max_cumulative_cost_usd,
                max_cumulative_tokens=max_cumulative_tokens,
            )
            options["max_cost_usd"] = float(max_rollout_cost_usd)
            options["max_metered_tokens"] = max_rollout_metered_tokens
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
            **options,
        )
        _verify_import_witness(
            run_dir, task_id, store_import[1] if store_import is not None else None
        )
        # Export before import_run: the offline grade runs on the workspace
        # only after the store this attempt leaves has been sealed.
        relpath = _archive_relpath(variant, task_id, replicate, attempt)
        export_sha256, entries, export_bytes = export_store(
            run_dir / task_id / ".home" / ".metacodes" / "kg", chain_dir / relpath
        )
        if store_import is not None and not entries:
            raise ValidationError(
                f"{variant} chain {task_id!r} r{replicate} attempt {attempt}: "
                "the imported store vanished"
            )
        row = LedgerRow(
            variant=variant,
            task_id=task_id,
            replicate=replicate,
            attempt=attempt,
            trial=trial,
            store_import_sha256=store_import[1] if store_import is not None else None,
            store_export_sha256=export_sha256,
            store_entries=tuple(entries),
            export_bytes=export_bytes,
            archive=relpath,
            run_dir=str(run_dir),
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
                f"{variant} chain {task_id!r} r{replicate} attempt {attempt}: expected one "
                "execution-grounded rollout"
            )
        collected[variant].extend(selected)
        write_rollouts(outputs[variant], collected[variant])
        paired_runner._require_scoring_rollout(selected[0], variant=variant)
        require_budget()
    return collected["baseline"], collected["candidate"]
