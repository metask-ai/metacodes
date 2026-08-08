"""Run one explicitly authorized paid memory schedule with production GLM-5.2.

The CLI is intentionally narrow: it consumes an already frozen adapter source
and manifest, performs a zero-network dry run by default, and requires a
separate authority flag before any provider request. Credentials stay in host
memory and cross into metacodes through a one-shot inherited descriptor, never
through the child's initial environment, sealed HOME, command line, receipt,
cassette, or runner-source bundle.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
import subprocess
import tempfile
from pathlib import Path
from typing import Any, Mapping

if __package__ in {None, ""}:
    import sys

    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    from scripts.eval.memory_agent_runtime import (  # type: ignore
        PRODUCTION_MODEL_FINGERPRINT,
        PRODUCTION_MODEL_ID,
        ProductionRuntimeConfig,
        _write_new,
        _validate_production_manifest,
        run_memory_agent_schedule,
        validate_memory_agent_resume,
    )
    from scripts.eval.memory_benchmark import file_sha256  # type: ignore
    from scripts.eval.memory_budget_journal import (  # type: ignore
        BudgetAuthority,
        BudgetJournal,
        usd_to_microusd,
    )
    from scripts.eval.memory_replay import (  # type: ignore
        PRODUCTION_AUTO_COMPACT_POLICY,
        PRODUCTION_ALLOWED_PROVIDER_TOOLS,
        PRODUCTION_DISALLOWED_PROVIDER_TOOLS,
        PRODUCTION_FILESYSTEM_ISOLATION,
        PRODUCTION_TOOL_NETWORK_ISOLATION,
        _artifact_tree_digest,
        load_manifest,
        validate_runtime_artifacts,
    )
    from scripts.eval.model import ValidationError, stable_json  # type: ignore
else:
    from .memory_agent_runtime import (
        PRODUCTION_MODEL_FINGERPRINT,
        PRODUCTION_MODEL_ID,
        ProductionRuntimeConfig,
        _write_new,
        _validate_production_manifest,
        run_memory_agent_schedule,
        validate_memory_agent_resume,
    )
    from .memory_benchmark import file_sha256
    from .memory_budget_journal import BudgetAuthority, BudgetJournal, usd_to_microusd
    from .memory_replay import (
        PRODUCTION_AUTO_COMPACT_POLICY,
        PRODUCTION_ALLOWED_PROVIDER_TOOLS,
        PRODUCTION_DISALLOWED_PROVIDER_TOOLS,
        PRODUCTION_FILESYSTEM_ISOLATION,
        PRODUCTION_TOOL_NETWORK_ISOLATION,
        _artifact_tree_digest,
        load_manifest,
        validate_runtime_artifacts,
    )
    from .model import ValidationError, stable_json


def _load_api_key(auth_file: Path) -> str:
    explicit = os.environ.get("METASK_API_KEY", "").strip()
    if explicit:
        raise ValidationError(
            "production pilot rejects METASK_API_KEY because a tool subprocess could inspect "
            "the Python parent's initial environment; use a private auth file"
        )
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        fd = os.open(auth_file, flags)
    except OSError as exc:
        raise ValidationError(f"cannot open production auth file: {exc}") from exc
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise ValidationError("production auth file is not regular")
        if os.name != "nt" and stat.S_IMODE(info.st_mode) & 0o077:
            raise ValidationError("production auth file permissions must be 0600 or stricter")
        if info.st_size > 64 * 1024:
            raise ValidationError("production auth file exceeds 64 KiB")
        chunks: list[bytes] = []
        observed = 0
        while True:
            chunk = os.read(fd, 8192)
            if not chunk:
                break
            observed += len(chunk)
            if observed > 64 * 1024:
                raise ValidationError("production auth file exceeds 64 KiB")
            chunks.append(chunk)
        value = json.loads(b"".join(chunks).decode("utf-8"))
    except ValidationError:
        raise
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ValidationError(f"cannot read production auth file: {exc}") from exc
    finally:
        os.close(fd)
    key = value.get("api_key") if isinstance(value, dict) else None
    if not isinstance(key, str) or not key.strip():
        raise ValidationError("production auth file has no API key")
    return key.strip()


def _config(args: argparse.Namespace, api_key: str, *, authorized: bool) -> ProductionRuntimeConfig:
    return ProductionRuntimeConfig(
        api_key=api_key,
        allow_paid_rollouts=authorized,
        max_total_cost_usd=args.max_total_cost_usd,
        max_total_metered_tokens=args.max_total_metered_tokens,
        max_rollout_cost_usd=args.max_rollout_cost_usd,
        max_rollout_metered_tokens=args.max_rollout_metered_tokens,
        max_output_tokens=args.max_output_tokens,
        ripgrep_binary=args.ripgrep_binary.expanduser().resolve(),
        ripgrep_binary_sha256=file_sha256(args.ripgrep_binary.expanduser().resolve()),
    )


def _probe_tinykg_compatibility(binary: Path, expected_sha256: str) -> Mapping[str, Any]:
    """Exercise the exact local-store commands required before any paid arm."""

    def run(command: str, *arguments: str) -> str:
        try:
            completed = subprocess.run(
                [str(binary), command, *arguments],
                env={"PATH": os.defpath},
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=30,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise ValidationError(f"TinyKG compatibility preflight {command} failed: {exc}") from exc
        if completed.returncode != 0:
            detail = completed.stderr.strip()[-500:]
            raise ValidationError(
                f"TinyKG compatibility preflight {command} failed with exit "
                f"{completed.returncode}: {detail!r}"
            )
        return completed.stdout

    if file_sha256(binary) != expected_sha256:
        raise ValidationError("TinyKG binary changed before compatibility preflight")
    with tempfile.TemporaryDirectory(prefix="metacodes-tinykg-preflight-") as directory:
        root = Path(directory)
        store = root / "store.kg"
        batch = root / "batch.jsonl"
        batch.write_text(
            stable_json({"version": 1})
            + "\n"
            + stable_json(
                {
                    "id": 1,
                    "kind": "project",
                    "name": "preflight-domain",
                    "op": "node",
                }
            )
            + "\n",
            encoding="utf-8",
        )
        run("init", str(store))
        run("apply", str(store), str(batch))
        info = {}
        for line in run("store-info", str(store)).splitlines():
            if "=" in line:
                key, value = line.split("=", 1)
                info[key] = value
        required = {
            "nodes": "1",
            "edges": "0",
            "storage_format_version": "2",
            "schema_version": "3",
        }
        if any(info.get(key) != value for key, value in required.items()):
            raise ValidationError("TinyKG compatibility preflight returned an incompatible store contract")
    if file_sha256(binary) != expected_sha256:
        raise ValidationError("TinyKG binary changed during compatibility preflight")
    return {
        "commands": ["init", "apply", "store-info"],
        "storage_format_version": 2,
        "schema_version": 3,
    }


def _public_plan(
    args: argparse.Namespace,
    manifest: Mapping[str, Any],
    metacodes_sha256: str,
    tinykg_sha256: str,
    tinykg_preflight: Mapping[str, Any],
) -> Mapping[str, Any]:
    budget = _config(args, "dry-run-placeholder", authorized=True)
    _validate_production_manifest(manifest, budget)
    return {
        "dry_run": True,
        "network_requests": 0,
        "paid_rollouts_authorized": False,
        "model_id": PRODUCTION_MODEL_ID,
        "model_fingerprint": PRODUCTION_MODEL_FINGERPRINT,
        "manifest_id": manifest["manifest_id"],
        "rollouts": len(manifest["schedule"]),
        "budget": budget.public_budget(),
        "disallowed_provider_tools": list(PRODUCTION_DISALLOWED_PROVIDER_TOOLS),
        "allowed_provider_tools": list(PRODUCTION_ALLOWED_PROVIDER_TOOLS),
        "ripgrep_binary_sha256": file_sha256(args.ripgrep_binary.expanduser().resolve()),
        "tool_network_isolation": PRODUCTION_TOOL_NETWORK_ISOLATION,
        "filesystem_isolation": PRODUCTION_FILESYSTEM_ISOLATION,
        "auto_compact_policy": PRODUCTION_AUTO_COMPACT_POLICY,
        "metacodes_binary_sha256": metacodes_sha256,
        "tinykg_binary_sha256": tinykg_sha256,
        "tinykg_preflight": tinykg_preflight,
        "source_sha256": file_sha256(args.source.resolve()),
        "credential_loaded": False,
    }


def _write_failed_run_checkpoint(
    run_dir: Path,
    budget_journal: BudgetJournal,
    error: BaseException,
) -> Mapping[str, Any]:
    """Preserve paid evidence when a schedule fails before final publication."""

    if not run_dir.is_dir():
        raise ValidationError("failed paid run has no owned artifact directory")
    budget_payload = budget_journal.checkpoint_payload()
    budget_path = run_dir / "failed-run-budget-checkpoint.json"
    _write_new(budget_path, budget_payload)
    budget_snapshot = budget_journal.snapshot()
    transaction_states = budget_snapshot["transaction_states"]
    automatic_retry_forbidden = any(
        int(transaction_states.get(state, 0)) > 0
        for state in ("request_authorized", "committed")
    )
    try:
        partial_artifact_tree_sha256 = _artifact_tree_digest(run_dir)
        artifact_tree_error_type = None
        artifact_tree_error_sha256 = None
    except BaseException as artifact_error:
        partial_artifact_tree_sha256 = None
        artifact_tree_error_type = type(artifact_error).__name__
        artifact_tree_error_sha256 = hashlib.sha256(
            str(artifact_error).encode("utf-8")
        ).hexdigest()
    rollout_root = run_dir / "rollouts"
    rollout_directories = (
        sum(1 for path in rollout_root.iterdir() if path.is_dir())
        if rollout_root.is_dir()
        else 0
    )
    diagnostic = {
        "schema_version": "metacodes-memory-paid-run-failure-v1",
        "status": "invalid",
        "classification": "mid-schedule-runtime-failure",
        "error_type": type(error).__name__,
        "error_sha256": hashlib.sha256(str(error).encode("utf-8")).hexdigest(),
        "partial_artifact_tree_sha256_with_budget_checkpoint": partial_artifact_tree_sha256,
        "artifact_tree_error_type": artifact_tree_error_type,
        "artifact_tree_error_sha256": artifact_tree_error_sha256,
        "rollout_directories": rollout_directories,
        "budget_checkpoint_file": budget_path.name,
        "budget_checkpoint_sha256": hashlib.sha256(budget_payload).hexdigest(),
        "budget_snapshot": budget_snapshot,
        "automatic_retry_forbidden": automatic_retry_forbidden,
    }
    _write_new(
        run_dir / "failed-run-diagnostic.json",
        (stable_json(diagnostic) + "\n").encode("utf-8"),
    )
    return diagnostic


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--tinykg-binary", type=Path, required=True)
    parser.add_argument("--ripgrep-binary", type=Path, required=True)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--validators", type=Path)
    parser.add_argument("--run-dir", type=Path)
    parser.add_argument("--budget-journal", type=Path)
    parser.add_argument("--auth-file", type=Path, default=Path.home() / ".metacodes" / "auth.json")
    parser.add_argument("--timeout-seconds", type=int, default=300)
    parser.add_argument("--max-output-tokens", type=int, default=4096)
    parser.add_argument("--max-rollout-metered-tokens", type=int, default=300_000)
    parser.add_argument("--max-rollout-cost-usd", type=float, default=0.90)
    parser.add_argument("--max-total-metered-tokens", type=int, default=3_100_000)
    parser.add_argument("--max-total-cost-usd", type=float, default=10.0)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--allow-paid-rollouts", action="store_true")
    parser.add_argument("--resume-paid-run", action="store_true")
    args = parser.parse_args(argv)

    metacodes = args.binary.expanduser().resolve()
    tinykg = args.tinykg_binary.expanduser().resolve()
    ripgrep = args.ripgrep_binary.expanduser().resolve()
    source = args.source.expanduser().resolve()
    manifest_path = args.manifest.expanduser().resolve()
    for path, label in (
        (metacodes, "metacodes binary"),
        (tinykg, "TinyKG binary"),
        (ripgrep, "ripgrep binary"),
        (source, "adapter source"),
        (manifest_path, "manifest"),
    ):
        if not path.is_file():
            raise ValidationError(f"{label} is unavailable")
    if not all(os.access(path, os.X_OK) for path in (metacodes, tinykg, ripgrep)):
        raise ValidationError("production binaries and toolchain must be executable")
    metacodes_sha = file_sha256(metacodes)
    tinykg_sha = file_sha256(tinykg)
    manifest = load_manifest(manifest_path)
    if file_sha256(source) != manifest["dataset"]["source_sha256"]:
        raise ValidationError("adapter source SHA-256 does not match the frozen manifest")
    tinykg_preflight = _probe_tinykg_compatibility(tinykg, tinykg_sha)

    if args.dry_run:
        print(
            stable_json(
                _public_plan(
                    args,
                    manifest,
                    metacodes_sha,
                    tinykg_sha,
                    tinykg_preflight,
                )
            )
        )
        return 0
    if not args.allow_paid_rollouts:
        raise ValidationError("production pilot requires --allow-paid-rollouts")
    if args.run_dir is None:
        raise ValidationError("production pilot requires a fresh --run-dir")
    if args.budget_journal is None:
        raise ValidationError("production pilot requires --budget-journal")
    run_dir = args.run_dir.expanduser().resolve()
    if args.resume_paid_run and not run_dir.is_dir():
        raise ValidationError("production --resume-paid-run requires an existing --run-dir")
    if not args.resume_paid_run and run_dir.exists():
        raise ValidationError("production --run-dir must not already exist")

    journal_candidate = args.budget_journal.expanduser()
    if not journal_candidate.is_absolute():
        journal_candidate = (Path.cwd() / journal_candidate).absolute()
    try:
        journal_candidate.relative_to(run_dir.resolve(strict=False))
    except ValueError:
        pass
    else:
        raise ValidationError("budget journal must be outside the fresh run directory")
    journal_parent = journal_candidate.parent.resolve(strict=True)
    journal_path = journal_parent / journal_candidate.name
    try:
        journal_path.relative_to(run_dir.resolve(strict=False))
    except ValueError:
        pass
    else:
        raise ValidationError("budget journal must be outside the fresh run directory")
    authority = BudgetAuthority(
        manifest_sha256=hashlib.sha256(stable_json(manifest).encode("utf-8")).hexdigest(),
        model_fingerprint=manifest["execution"]["model_fingerprint"],
        provider_identity="metask-anthropic-compatible-v1",
        total_cost_microusd=usd_to_microusd(args.max_total_cost_usd),
        total_metered_tokens=args.max_total_metered_tokens,
    )
    with BudgetJournal(journal_path, authority) as budget_journal:
        if args.resume_paid_run:
            # This preflight deliberately precedes credential loading. A stale,
            # corrupt, or ambiguous checkpoint must fail with zero secret reads
            # and zero opportunity for a provider request.
            validate_memory_agent_resume(
                run_dir=run_dir,
                manifest=manifest,
                source_sha=file_sha256(source),
                metacodes_sha=metacodes_sha,
                tinykg_sha=tinykg_sha,
                ripgrep_sha=file_sha256(ripgrep),
                budget_journal=budget_journal,
            )
        api_key = _load_api_key(args.auth_file.expanduser().resolve())
        # The key was never present in this process's initial environment. The
        # metacodes child receives it only through an anonymous inherited FD and
        # closes that descriptor before App/tools/subprocesses are initialized.
        production = _config(args, api_key, authorized=True)
        production.validate(len(manifest["schedule"]))
        try:
            observations, receipt = run_memory_agent_schedule(
                metacodes_binary=metacodes,
                expected_metacodes_sha256=metacodes_sha,
                tinykg_binary=tinykg,
                expected_tinykg_sha256=tinykg_sha,
                source_path=source,
                manifest_path=manifest_path,
                run_dir=run_dir,
                observations_path=run_dir / "observations.jsonl",
                runtime_receipt_path=run_dir / "runtime-receipt.json",
                validator_bundle_path=(
                    args.validators.expanduser().resolve() if args.validators else None
                ),
                timeout_seconds=args.timeout_seconds,
                production=production,
                budget_journal=budget_journal,
                resume_paid_run=args.resume_paid_run,
            )
            validate_runtime_artifacts(receipt, run_dir)
        except BaseException as exc:
            try:
                _write_failed_run_checkpoint(run_dir, budget_journal, exc)
            except BaseException as checkpoint_error:
                raise ValidationError(
                    "paid run failed and its failure checkpoint could not be persisted: "
                    f"{type(checkpoint_error).__name__}"
                ) from exc
            raise
        summary = {
            "dry_run": False,
            "quality_evidence": receipt["quality_evidence"],
            "run_dir": str(run_dir),
            "rollouts": len(observations),
            "provider_requests": receipt["provider_requests"],
            "tool_network_isolation": receipt["tool_network_isolation"],
            "filesystem_isolation": receipt["filesystem_isolation"],
            "auto_compact_policy": receipt["auto_compact_policy"],
            "provider_billed_cost_usd": receipt["provider_billed_cost_usd"],
            "estimated_cost_usd": receipt["estimated_cost_usd"],
            "metered_tokens": receipt["metered_tokens"],
            "budget_journal_id": receipt["budget_journal"]["journal_id"],
            "budget_journal_revision": receipt["budget_journal"]["revision"],
            "budget_journal_head_sha256": receipt["budget_journal"]["head_sha256"],
            "receipt_sha256": hashlib.sha256(
                (stable_json(receipt) + "\n").encode("utf-8")
            ).hexdigest(),
        }
    print(stable_json(summary))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
