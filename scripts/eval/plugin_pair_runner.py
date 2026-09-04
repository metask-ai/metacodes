#!/usr/bin/env python3
"""Plan or execute the frozen plugin coding pair with durable paid authority.

Planning is the default and performs no provider request. Paid execution needs
all three independent gates: ``--allow-paid-rollouts``, a private user-
authority file bound to the exact protocol hash, and a private provider auth
file. Every rollout is durably authorized before its first request and is
bounded again inside metacodes by fixed token and cost caps.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import platform
import shutil
import stat
import subprocess
import sys
import tempfile
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping, Sequence

if __package__ in {None, ""}:
    import sys

    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    from scripts.eval.e2e_adapter import import_run  # type: ignore
    from scripts.eval.memory_agent_runtime_pilot import _load_api_key  # type: ignore
    from scripts.eval.memory_budget_journal import (  # type: ignore
        BudgetAuthority,
        BudgetJournal,
        BudgetTransaction,
        TransactionNotAbortable,
        usd_to_microusd,
        usd_to_microusd_ceiling,
    )
    from scripts.eval.model import (  # type: ignore
        open_nofollow,
        O_BINARY,
        ValidationError,
        load_json,
        stable_json,
        validate_suite,
        write_rollouts,
    )
    from scripts.eval.paired_runner import (  # type: ignore
        TOKEN_METRICS,
        _load_checkpoint,
        _require_external_budget_journal,
        _require_no_orphan_budget_transactions,
        _require_runtime_budget_provenance,
        _require_scoring_rollout,
        _run_once,
        alternating_schedule,
        hermetic_env,
        interpreter_shim,
        scenario_selector,
    )
    from scripts.eval.plugin_release_gate import (  # type: ignore
        PluginGateError,
        attest_runtime_artifact,
        implementation_fingerprint,
        validate_protocol_payload,
        require_clean_pinned_inputs,
        materialize_head,
        git_head,
    )
else:
    from .e2e_adapter import import_run
    from .memory_agent_runtime_pilot import _load_api_key
    from .memory_budget_journal import (
        BudgetAuthority,
        BudgetJournal,
        BudgetTransaction,
        TransactionNotAbortable,
        usd_to_microusd,
        usd_to_microusd_ceiling,
    )
    from .model import O_BINARY, ValidationError, load_json, stable_json, validate_suite, write_rollouts, open_nofollow
    from .paired_runner import (
        TOKEN_METRICS,
        _load_checkpoint,
        _require_external_budget_journal,
        _require_no_orphan_budget_transactions,
        _require_runtime_budget_provenance,
        _require_scoring_rollout,
        _run_once,
        alternating_schedule,
        hermetic_env,
        interpreter_shim,
        scenario_selector,
    )
    from .plugin_release_gate import (
        PluginGateError,
        attest_runtime_artifact,
        implementation_fingerprint,
        validate_protocol_payload,
        require_clean_pinned_inputs,
        materialize_head,
        git_head,
    )


AUTHORITY_SCHEMA = "metacodes.plugin-paid-authority/v2"
FROZEN_RUN_SCHEMA = "metacodes.plugin-frozen-run/v1"
# What the budget journal's authority hash is a function of (see
# `_authority_manifest`); a journal sealed under another contract is refused.
AUTHORITY_MANIFEST_CONTRACT = "metacodes-plugin-pair-authority-v1"
# The hashed projection of an arm's `--dump-plugins` inventory (see
# `_inventory_identity`); versioned so a change to what it binds is a named,
# deliberate change of every inventory hash rather than a silent one.
INVENTORY_IDENTITY = "metacodes.plugin-inventory-identity/v1"


def _sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _sha256(path: Path) -> str:
    return _sha256_bytes(path.read_bytes())


def _canonical_sha256(value: Any) -> str:
    return _sha256_bytes(stable_json(value).encode("utf-8"))


def _git_head(root: Path) -> str:
    result = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=root,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        check=False,
    )
    if result.returncode != 0:
        raise ValidationError("cannot resolve metacodes Git revision")
    return result.stdout.strip()


def path_set_digest(protocol: Mapping[str, Any]) -> str:
    """Identity of *which* paths are pinned, independent of their contents.

    Membership only: both lists are sorted, so reordering is invisible here
    by design. `protocol_sha256` already binds the exact bytes of both lists,
    so this digest adds no protection over it - it adds a *name*. Once a
    narrower list is repinned nothing in protocol.json remembers it used to
    be longer; verification then reports `path_set_digest` next to
    `protocol_sha256` instead of leaving the operator to diff two protocol
    files to learn what moved.
    """
    return _canonical_sha256(
        {
            "implementation_paths": sorted(protocol["implementation_paths"]),
            "pinned_evaluator_files": sorted(protocol["pinned_evaluator_files"]),
        }
    )


def _arm_identities(
    root: Path,
    protocol: Mapping[str, Any],
    runtime_binary: Path,
) -> tuple[dict[str, Path], dict[str, str], dict[str, str]]:
    """The two arm wrappers, their hashes, and their attested inventories -
    the identities the paid pair, the freeze step and the analysis must all
    agree on. One function so they cannot drift apart."""
    pair = protocol["coding_pair"]
    wrappers = {
        "baseline": root / pair["baseline_executable"],
        "candidate": root / pair["treatment_executable"],
    }
    for arm, executable in wrappers.items():
        if not executable.is_file() or not os.access(executable, os.X_OK):
            raise ValidationError(f"{arm} wrapper is not executable")
    wrapper_hashes = {arm: _sha256(path) for arm, path in wrappers.items()}
    inventory_hashes = {
        arm: _verify_arm_inventory(root, protocol, arm, executable, runtime_binary)
        for arm, executable in wrappers.items()
    }
    return wrappers, wrapper_hashes, inventory_hashes


def _execution_environment() -> dict[str, Any]:
    """What the freeze records about the environment a paid run executes in.

    Not a host identity - two identically provisioned machines with the
    same paths and hashes are indistinguishable here - and not a claim that
    the interpreter is pinned: the interpreter, its prefixes and the
    libraries it loads are inside the operator's trust boundary, like the
    binaries on PATH. It exists so that a run or an analysis started in a
    *differently observed* OS/interpreter environment - another OS build,
    another interpreter build, another venv - is a named `environment`
    refusal before any authorization, instead of a batch of honest rows
    failing their environment fingerprint after the money is spent.
    `platform` and `python` are exactly what the harness writes into that
    fingerprint; the rest tells one interpreter installation from another
    with the same version.
    """
    executable = Path(sys.executable).resolve()
    return {
        "platform": platform.platform(),
        "python": platform.python_version(),
        "implementation": platform.python_implementation(),
        "cache_tag": sys.implementation.cache_tag,
        "executable": str(executable),
        "executable_sha256": _sha256(executable),
        "prefix": str(Path(sys.prefix).resolve()),
        "exec_prefix": str(Path(sys.exec_prefix).resolve()),
        "base_prefix": str(Path(sys.base_prefix).resolve()),
    }


def frozen_run_fields(
    root: Path,
    protocol: Mapping[str, Any],
    *,
    protocol_sha256: str,
    runtime_sha256: str,
    wrapper_hashes: Mapping[str, str],
    inventory_hashes: Mapping[str, str],
    schedule: Sequence[Mapping[str, Any]],
    head: str | None = None,
) -> dict[str, Any]:
    """Everything a paid run is frozen against, as observed *now*."""
    return {
        "schema": FROZEN_RUN_SCHEMA,
        "protocol_sha256": protocol_sha256,
        "git_head": head if head is not None else _git_head(root),
        "implementation_fingerprint": implementation_fingerprint(root, protocol),
        "path_set_digest": path_set_digest(protocol),
        "runtime_sha256": runtime_sha256,
        "wrapper_sha256": dict(wrapper_hashes),
        "inventory_sha256": dict(inventory_hashes),
        "schedule_sha256": _canonical_sha256(list(schedule)),
        "model_fingerprint": _canonical_sha256(protocol["coding_pair"]["model"]),
        "environment": _execution_environment(),
    }


def manifest_sha256_of(fields: Mapping[str, Any]) -> str:
    return _canonical_sha256({k: v for k, v in fields.items() if k != "manifest_sha256"})


def freeze_run(root: Path, protocol_path: Path, runtime_binary: Path) -> dict[str, Any]:
    """Produce the frozen-run manifest: the pre-registration a user authority
    binds to *before* any provider request. Strict on every pin."""
    # The manifest can only describe committed bytes: a dirty pinned input is
    # refused, and what is hashed is HEAD materialized, never the live tree.
    with materialized_source_tree(root, protocol_path) as tree:
        fields = _observe(tree, runtime_binary).fields
    return {**fields, "manifest_sha256": manifest_sha256_of(fields)}


def verify_frozen_manifest(manifest: Mapping[str, Any], live: Mapping[str, Any]) -> str:
    """Every field of the frozen manifest must equal what the tree, the
    runtime and the wrappers look like now. Returns the manifest hash so the
    caller can bind authority, journal and rows to it."""
    if not isinstance(manifest, dict) or manifest.get("schema") != FROZEN_RUN_SCHEMA:
        raise ValidationError("frozen-run manifest has an unsupported schema")
    expected_keys = set(live) | {"manifest_sha256"}
    if set(manifest) != expected_keys:
        raise ValidationError("frozen-run manifest has unsupported or missing fields")
    drifted = sorted(key for key, value in live.items() if manifest[key] != value)
    if drifted:
        # All of them, not the first: an operator deciding whether to re-freeze
        # needs to know that the list shrank *and* the protocol bytes moved,
        # not just whichever field happens to sort first.
        raise ValidationError("frozen-run manifest drifted: " + ", ".join(drifted))
    digest = manifest_sha256_of(manifest)
    if manifest["manifest_sha256"] != digest:
        raise ValidationError("frozen-run manifest hash does not match its fields")
    return digest


def _pair_fields(protocol: Mapping[str, Any]) -> tuple[float, int, float, int]:
    pair = protocol["coding_pair"]
    max_output_tokens = pair.get("max_output_tokens")
    values = (
        pair.get("max_rollout_cost_usd"),
        pair.get("max_rollout_metered_tokens"),
        pair.get("max_cumulative_cost_usd"),
        pair.get("max_cumulative_metered_tokens"),
    )
    rollout_cost, rollout_tokens, total_cost, total_tokens = values
    if (
        not isinstance(max_output_tokens, int)
        or isinstance(max_output_tokens, bool)
        or max_output_tokens <= 0
        or not isinstance(rollout_cost, (int, float))
        or isinstance(rollout_cost, bool)
        or not math.isfinite(float(rollout_cost))
        or float(rollout_cost) <= 0
        or not isinstance(total_cost, (int, float))
        or isinstance(total_cost, bool)
        or not math.isfinite(float(total_cost))
        or float(total_cost) <= 0
        or not isinstance(rollout_tokens, int)
        or isinstance(rollout_tokens, bool)
        or rollout_tokens <= 0
        or not isinstance(total_tokens, int)
        or isinstance(total_tokens, bool)
        or total_tokens <= 0
    ):
        raise ValidationError("plugin coding pair has invalid fixed budget fields")
    rollouts = int(pair["rollouts"])
    if float(rollout_cost) * rollouts > float(total_cost):
        raise ValidationError("cumulative cost cap cannot cover the frozen rollout schedule")
    if rollout_tokens * rollouts > total_tokens:
        raise ValidationError("cumulative token cap cannot cover the frozen rollout schedule")
    return float(rollout_cost), rollout_tokens, float(total_cost), total_tokens


def _schedule(
    root: Path,
    protocol: Mapping[str, Any],
) -> tuple[Path, dict[str, Any], dict[str, dict[str, Any]], list[dict[str, Any]]]:
    """The suite and the exact rollout order the protocol commits to. Pure
    given the protocol - no runtime, no subprocess - and the one derivation
    shared by the plan, the freeze, the paid run and the analysis."""
    pair = protocol["coding_pair"]
    suite_path = root / pair["suite"]
    suite = load_json(suite_path)
    validate_suite(suite, root)
    task_ids = sorted(str(value) for value in pair["task_ids"])
    tasks = {task["id"]: task for task in suite["tasks"]}
    if sorted(tasks) != task_ids:
        raise ValidationError("frozen plugin suite tasks do not match the protocol")
    schedule = [
        {"trial": trial, "arm": arm, "task_id": task_id}
        for trial, arm in alternating_schedule(int(pair["trials"]))
        for task_id in task_ids
    ]
    if len(schedule) != pair["rollouts"]:
        raise ValidationError("planned plugin schedule length drifted")
    return suite_path, suite, tasks, schedule


@dataclass(frozen=True)
class SourceTree:
    """What a paid run observes and executes: Git HEAD materialized into a
    private directory, plus the protocol bytes read once. The live checkout is
    consulted for HEAD identity only, so change-and-restore of a pinned input
    between two observations (#61, the paid-path form of the #49 gap) has
    nothing to act on: nothing reads the live tree after this is built."""

    live_root: Path
    root: Path
    protocol_path: Path
    protocol_raw: bytes
    head: str


@contextmanager
def materialized_source_tree(live_root: Path, protocol_path: Path):
    """Read the protocol once, refuse a pinned input that is modified in the
    working tree (the manifest could otherwise describe uncommitted bytes),
    and materialize HEAD for the lifetime of the block. Everything happens
    before the frozen manifest is read and before the user authority is
    opened, so a materialization failure cannot occur mid-run."""
    live_root = live_root.resolve()
    protocol_path = protocol_path.expanduser().resolve()
    try:
        raw = protocol_path.read_bytes()
        structure = json.loads(raw.decode("utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ValidationError(f"cannot read plugin evaluation protocol: {exc}") from exc
    if not isinstance(structure, dict):
        raise ValidationError("unsupported plugin evaluation protocol")
    try:
        require_clean_pinned_inputs(live_root, structure, protocol_path)
    except PluginGateError as exc:
        raise ValidationError(str(exc)) from exc
    head = git_head(live_root)
    with tempfile.TemporaryDirectory(prefix="metacodes-paid-tree-") as temp:
        root = materialize_head(live_root, head, Path(temp) / "tree")
        yield SourceTree(live_root, root, protocol_path, raw, head)


@dataclass(frozen=True)
class _Observation:
    """Everything a paid run is frozen against, as the tree looks *now*, from
    one read of the protocol: the parsed object and the hash the manifest is
    held against come from the same bytes."""

    protocol: dict[str, Any]
    protocol_sha256: str
    runtime_path: Path
    runtime_sha256: str
    wrappers: dict[str, Path]
    wrapper_hashes: dict[str, str]
    inventory_hashes: dict[str, str]
    suite_path: Path
    suite: dict[str, Any]
    tasks: dict[str, dict[str, Any]]
    schedule: list[dict[str, Any]]
    fields: dict[str, Any]


def _observe(tree: SourceTree, runtime_binary: Path) -> _Observation:
    """Strict on every pin. This is the one predicate behind the freeze, the
    start of a paid run, the bracket around every provider request and the
    analysis - the same function everywhere, so there is no weaker second
    definition of "the tree still matches" for a request to slip through."""
    root, raw = tree.root, tree.protocol_raw
    protocol = validate_protocol_payload(root, raw)
    runtime = attest_runtime_artifact(protocol, runtime_binary)
    wrappers, wrapper_hashes, inventory_hashes = _arm_identities(root, protocol, runtime.path)
    suite_path, suite, tasks, schedule = _schedule(root, protocol)
    fields = frozen_run_fields(
        root,
        protocol,
        protocol_sha256=_sha256_bytes(raw),
        runtime_sha256=runtime.sha256,
        wrapper_hashes=wrapper_hashes,
        inventory_hashes=inventory_hashes,
        schedule=schedule,
        head=tree.head,
    )
    return _Observation(
        protocol=protocol,
        protocol_sha256=fields["protocol_sha256"],
        runtime_path=runtime.path,
        runtime_sha256=runtime.sha256,
        wrappers=wrappers,
        wrapper_hashes=wrapper_hashes,
        inventory_hashes=inventory_hashes,
        suite_path=suite_path,
        suite=suite,
        tasks=tasks,
        schedule=schedule,
        fields=fields,
    )


def _require_still_frozen(
    tree: SourceTree,
    runtime_binary: Path,
    manifest: Mapping[str, Any],
    *,
    moment: str,
) -> None:
    """Re-derive every frozen field and hold it against the manifest the user
    authorized. Validating whatever self-consistent protocol is on disk is
    not that: a protocol repinned after the freeze - a swapped candidate
    Skill with its hash updated - passes the strict loader, and the rollout
    would still be labelled with this manifest."""
    # The run never reads the operator's protocol file after the start, but
    # a rewrite of it mid-run is a reason to stop, exactly as the gate refuses
    # to write its receipt when the file no longer holds the bytes it ran with
    # (#49): the bytes on disk must still be the bytes this run was frozen on.
    try:
        live = tree.protocol_path.read_bytes()
    except OSError as exc:
        raise ValidationError(f"frozen-run manifest drifted: protocol_sha256 ({moment}): {exc}") from exc
    if live != tree.protocol_raw:
        raise ValidationError(f"frozen-run manifest drifted: protocol_sha256 ({moment})")
    try:
        verify_frozen_manifest(manifest, _observe(tree, runtime_binary).fields)
    except ValidationError as exc:
        raise ValidationError(f"{exc} ({moment})") from exc


def _revision(fields: Mapping[str, Any]) -> str:
    return f"{fields['git_head']}+{fields['implementation_fingerprint'][:16]}"


def _config_ids(protocol: Mapping[str, Any]) -> dict[str, str]:
    candidate = protocol["candidate"]
    return {
        "baseline": "plugin-v1:none",
        "candidate": f"plugin-v1:{candidate['plugin_id']}@{candidate['plugin_version']}",
    }


def _authority_manifest(
    observation: _Observation,
    *,
    frozen_manifest_sha256: str,
    authorized_cost_microusd: int,
    authorized_metered_tokens: int,
) -> dict[str, Any]:
    """What the budget journal's authority hash is a function of. Built here
    and only here: the paid run seals it into the journal and the analysis
    rebuilds it from the tree, so a journal from another freeze - or one
    whose authority never named a frozen manifest - is a named mismatch."""
    return {
        "contract": AUTHORITY_MANIFEST_CONTRACT,
        "protocol_sha256": observation.protocol_sha256,
        "runtime_sha256": observation.runtime_sha256,
        "wrapper_sha256": dict(observation.wrapper_hashes),
        "inventory_sha256": dict(observation.inventory_hashes),
        "revision": _revision(observation.fields),
        "frozen_manifest_sha256": frozen_manifest_sha256,
        "authorized_cost_microusd": authorized_cost_microusd,
        "authorized_metered_tokens": authorized_metered_tokens,
    }


def build_plan(
    root: Path,
    protocol_path: Path,
    *,
    runtime_binary: Path | None = None,
) -> dict[str, Any]:
    raw = protocol_path.read_bytes()
    protocol = validate_protocol_payload(root, raw)
    pair = protocol["coding_pair"]
    rollout_cost, rollout_tokens, total_cost, total_tokens = _pair_fields(protocol)
    _, _, _, schedule = _schedule(root, protocol)
    if runtime_binary is None:
        runtime = {
            "state": "not_attested",
            "expected_sha256": pair["runtime_binary_sha256"],
        }
    else:
        attestation = attest_runtime_artifact(protocol, runtime_binary)
        runtime = {
            "state": "attested",
            "path": str(attestation.path),
            "sha256": attestation.sha256,
        }
    return {
        "schema": "metacodes.plugin-paid-plan/v2",
        "provider_requests": 0,
        "quality_evidence": False,
        "protocol_sha256": _sha256_bytes(raw),
        "implementation_fingerprint": implementation_fingerprint(root, protocol),
        "model": pair["model"],
        "runtime": runtime,
        "fixed_rollout_budget": {
            "max_cost_usd": rollout_cost,
            "max_metered_tokens": rollout_tokens,
            "max_output_tokens": pair["max_output_tokens"],
        },
        "cumulative_authority_ceiling": {
            "max_cost_usd": total_cost,
            "max_metered_tokens": total_tokens,
        },
        "schedule": schedule,
        "authorization_required": {
            "cli_flag": "--allow-paid-rollouts",
            "authority_schema": AUTHORITY_SCHEMA,
            "provider_auth_file": True,
            "durable_budget_journal": True,
        },
    }


def _write_private_json(path: Path, value: Mapping[str, Any]) -> None:
    """Create `path` 0600, refusing to overwrite: a frozen manifest is a
    commitment, and silently replacing one is how a run ends up bound to a
    manifest nobody looked at."""
    fd = os.open(path, O_BINARY | os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    # The manifest is hashed by bytes, so its trailing newline must stay LF on Windows.
    with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(stable_json(value) + "\n")


def _read_private_json(path: Path, label: str) -> dict[str, Any]:
    flags = os.O_RDONLY
    try:
        fd = open_nofollow(path, flags)
    except OSError as exc:
        raise ValidationError(f"cannot open {label}: {exc}") from exc
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise ValidationError(f"{label} is not a regular file")
        if os.name != "nt" and stat.S_IMODE(info.st_mode) & 0o077:
            raise ValidationError(f"{label} permissions must be 0600 or stricter")
        if info.st_size <= 0 or info.st_size > 64 * 1024:
            raise ValidationError(f"{label} size is invalid")
        chunks: list[bytes] = []
        observed = 0
        while True:
            chunk = os.read(fd, min(8192, info.st_size + 1 - observed))
            if not chunk:
                break
            observed += len(chunk)
            if observed > info.st_size:
                raise ValidationError(f"{label} changed while reading")
            chunks.append(chunk)
        payload = b"".join(chunks)
        if observed != info.st_size:
            raise ValidationError(f"{label} changed while reading")
        value = json.loads(payload.decode("utf-8"))
    except ValidationError:
        raise
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ValidationError(f"cannot read {label}: {exc}") from exc
    finally:
        os.close(fd)
    if not isinstance(value, dict):
        raise ValidationError(f"{label} must be a JSON object")
    return value


def load_user_authority(
    path: Path,
    *,
    protocol_sha256: str,
    manifest_sha256: str,
    max_cost_usd: float,
    max_metered_tokens: int,
) -> dict[str, Any]:
    value = _read_private_json(path, "plugin paid authority")
    expected_keys = {
        "schema",
        "protocol_sha256",
        "manifest_sha256",
        "max_cost_usd",
        "max_metered_tokens",
        "authorized_by_user",
    }
    if set(value) != expected_keys or value.get("schema") != AUTHORITY_SCHEMA:
        raise ValidationError(
            "plugin paid authority has unsupported fields or schema: expected "
            f"{AUTHORITY_SCHEMA} carrying manifest_sha256 - run --freeze first, "
            "then write an authority naming that manifest"
        )
    if value.get("protocol_sha256") != protocol_sha256:
        raise ValidationError("plugin paid authority is bound to another protocol")
    # The authority is the user's commitment *before* the run: it names the
    # frozen manifest, so the run can only proceed against the exact tree,
    # runtime, wrappers and schedule the user saw when they authorized.
    if value.get("manifest_sha256") != manifest_sha256:
        raise ValidationError("plugin paid authority is bound to another frozen-run manifest")
    cost = value.get("max_cost_usd")
    tokens = value.get("max_metered_tokens")
    if (
        value.get("authorized_by_user") is not True
        or not isinstance(cost, (int, float))
        or isinstance(cost, bool)
        or not math.isfinite(float(cost))
        or float(cost) <= 0
        or float(cost) > max_cost_usd
        or not isinstance(tokens, int)
        or isinstance(tokens, bool)
        or tokens <= 0
        or tokens > max_metered_tokens
    ):
        raise ValidationError("plugin paid authority exceeds or violates the frozen ceiling")
    return value


def _inventory(
    root: Path,
    executable: Path,
    runtime_binary: Path,
) -> dict[str, Any]:
    """One arm's credential-free inventory, hermetically.

    The runtime builds a full App before `--dump-plugins` answers; run with
    the caller's HOME it leaves a session directory behind, reads
    ~/.metacodes/config.json (spawning any MCP server declared there) and
    probes the model catalog. Executing the pinned runtime is the point of
    this preflight; executing it against the operator's account is not.
    """
    clean_env = hermetic_env(
        {
            key: value
            for key, value in os.environ.items()
            if not key.startswith("METACODES_")
            and not key.startswith("METASK_")
            and not key.startswith("E2E_")
        }
    )
    clean_env["METACODES_PLUGIN_RUNTIME_BINARY"] = str(runtime_binary)
    clean_env["METACODES_NO_PROBE"] = "1"
    with tempfile.TemporaryDirectory(
        prefix="metacodes-plugin-inventory-home-"
    ) as home, interpreter_shim({**clean_env, "HOME": home}) as child_env:
        completed = subprocess.run(
            [str(executable), "--dump-plugins"],
            cwd=root,
            env=child_env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            check=False,
            timeout=60,
        )
    if completed.returncode != 0:
        raise ValidationError("credential-free plugin inventory preflight failed")
    for line in reversed(completed.stdout.splitlines()):
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict) and value.get("schema") == "metacodes.plugin-inventory/v1":
            return value
    raise ValidationError("plugin inventory preflight returned no inventory")


def _inventory_identity(
    root: Path,
    protocol: Mapping[str, Any],
    arm: str,
    value: Mapping[str, Any],
) -> dict[str, Any]:
    """The location-independent identity of one arm's inventory.

    The runtime reports `source_root` as the realpath of the plugin
    directory, so hashing the raw inventory would tie a frozen manifest to
    the checkout's absolute path: a byte-identical tree at another path
    would fail to verify for no reason the manifest means to express. The
    candidate root is instead *checked* against the root the protocol
    declares and recorded under that repo-relative name. `generation` is a
    counter of the runtime process, not a property of the plugin, and is
    dropped; everything else the runtime says about a plugin is kept.
    """
    plugins = value.get("plugins")
    if value.get("contract_version") != 1 or not isinstance(plugins, list):
        raise ValidationError(f"{arm} plugin inventory has an invalid contract")
    identity = []
    for plugin in plugins:
        if not isinstance(plugin, dict):
            raise ValidationError(f"{arm} plugin inventory has a malformed entry")
        source_root = plugin.get("source_root")
        if arm == "candidate":
            declared = str(protocol["candidate"]["root"])
            if (
                not isinstance(source_root, str)
                or Path(source_root).resolve() != (root / declared).resolve()
            ):
                raise ValidationError(
                    "candidate plugin inventory is not rooted at the frozen candidate root"
                )
            source_root = declared
        identity.append(
            {
                "id": plugin.get("id"),
                "version": plugin.get("version"),
                "form": plugin.get("form"),
                "layer": plugin.get("layer"),
                "lifecycle": plugin.get("lifecycle"),
                "capabilities": plugin.get("capabilities"),
                "contribution_count": plugin.get("contribution_count"),
                "source_root": source_root,
            }
        )
    return {"projection": INVENTORY_IDENTITY, "contract_version": 1, "plugins": identity}


def _verify_arm_inventory(
    root: Path,
    protocol: Mapping[str, Any],
    arm: str,
    executable: Path,
    runtime_binary: Path,
) -> str:
    attest_runtime_artifact(protocol, runtime_binary)
    value = _inventory(root, executable, runtime_binary)
    attest_runtime_artifact(protocol, runtime_binary)
    identity = _inventory_identity(root, protocol, arm, value)
    stable_plugins = [
        {key: plugin[key] for key in ("id", "version", "form", "capabilities")}
        for plugin in identity["plugins"]
    ]
    expected = [] if arm == "baseline" else [
        {
            "id": protocol["candidate"]["plugin_id"],
            "version": protocol["candidate"]["plugin_version"],
            "form": "data_package",
            "capabilities": ["skill_bundle"],
        }
    ]
    if stable_plugins != expected:
        raise ValidationError(f"{arm} plugin inventory does not match its frozen treatment")
    return _canonical_sha256(identity)


def _transaction(
    *,
    authority: BudgetAuthority,
    protocol_sha256: str,
    task: Mapping[str, Any],
    arm: str,
    trial: int,
    revision: str,
    config_id: str,
    wrapper_sha256: str,
    runtime_sha256: str,
    inventory_sha256: str,
    max_cost_usd: float,
    max_metered_tokens: int,
) -> BudgetTransaction:
    run_id = f"plugin-v1:{arm}:{task['id']}:{trial}"
    harness_fingerprint = _canonical_sha256(
        {
            "contract": "metacodes-plugin-pair-transaction-v1",
            "protocol_sha256": protocol_sha256,
            "arm": arm,
            "task": task,
            "trial": trial,
            "revision": revision,
            "config_id": config_id,
            "wrapper_sha256": wrapper_sha256,
            "runtime_sha256": runtime_sha256,
            "inventory_sha256": inventory_sha256,
            "max_cost_microusd": usd_to_microusd(max_cost_usd),
            "max_metered_tokens": max_metered_tokens,
        }
    )
    return BudgetTransaction(
        run_id=run_id,
        manifest_sha256=authority.manifest_sha256,
        model_fingerprint=authority.model_fingerprint,
        harness_fingerprint=harness_fingerprint,
        provider_identity=authority.provider_identity,
        max_cost_microusd=usd_to_microusd(max_cost_usd),
        max_metered_tokens=max_metered_tokens,
    )


def _metered_tokens(rollout: Mapping[str, Any]) -> int:
    return sum(int(rollout["metrics"][key]) for key in TOKEN_METRICS)


def _require_receipt_bound(
    receipt: Mapping[str, Any],
    live: Mapping[str, Any],
    transaction: BudgetTransaction,
) -> None:
    """One receipt-binding rule for resume and analysis: the persisted
    receipt is exactly the journal's projection of that transaction, taken
    at its commit, for the identity this run would have reserved. The two
    entry points calling this same function is what keeps them from
    accepting different checkpoints."""
    if set(receipt) != set(live):
        raise ValidationError("budget receipt has unexpected or missing fields")
    immutable = set(live) - {"journal_revision", "journal_head_sha256"}
    if any(receipt.get(key) != live.get(key) for key in immutable):
        raise ValidationError("budget receipt drifted from the journal")
    if (
        receipt["journal_revision"] != receipt["commit_revision"]
        or receipt["journal_head_sha256"] != receipt["commit_head_sha256"]
    ):
        raise ValidationError("budget receipt is not bound to its commit revision/head")
    if any(receipt.get(key) != value for key, value in transaction.record().items()):
        raise ValidationError("budget receipt transaction identity does not match this frozen run")


def rollout_evidence_sha256(rollout: Mapping[str, Any]) -> str:
    """Canonical digest of everything in a rollout except the budget receipt
    itself - outcome, trajectory, judgement, metrics, artifacts and the
    treatment attestation. Sealed into the journal's committed event, so a
    receipt cannot be transplanted onto a rollout with a different body and
    a body cannot be edited after the run without the journal disagreeing."""
    return _canonical_sha256(
        {key: value for key, value in rollout.items() if key != "budget_transaction"}
    )


def _require_scoring_checkpoints(
    collected: Mapping[str, Sequence[dict[str, Any]]],
) -> None:
    """Keep paid resume fail-closed after an invalid persisted rollout.

    New rows are checked immediately after they are durably committed. Resume
    must enforce the same invariant; otherwise restarting the runner could skip
    over a provider or harness failure that stopped the original process.
    """
    for arm, rows in collected.items():
        for row in rows:
            _require_scoring_rollout(row, variant=arm)


def run_paid_pair(
    root: Path,
    protocol_path: Path,
    *,
    runtime_binary: Path,
    output_dir: Path,
    budget_journal_path: Path,
    provider_auth_file: Path,
    user_authority_file: Path,
    frozen_manifest_file: Path,
) -> dict[str, Any]:
    # Materialize first, freeze second, authorize third: the tree the run
    # observes and executes is fixed before the manifest is read, and the
    # manifest the user signed must describe it before their authority is
    # even opened.
    with materialized_source_tree(root, protocol_path) as tree:
        return _run_paid_pair_materialized(
            tree,
            runtime_binary=runtime_binary,
            output_dir=output_dir,
            budget_journal_path=budget_journal_path,
            provider_auth_file=provider_auth_file,
            user_authority_file=user_authority_file,
            frozen_manifest_file=frozen_manifest_file,
        )


def _preserve_run_dir(run_dir: Path, output_dir: Path) -> Path:
    """Move a run directory the harness created inside the materialized tree
    under ``output_dir/runs``. Refuses to overwrite: two runs with the same
    name would mean two imports claiming the same evidence."""
    destination = output_dir / "runs"
    destination.mkdir(parents=True, exist_ok=True)
    target = destination / run_dir.name
    if target.exists():
        raise ValidationError(f"run directory already preserved: {target}")
    shutil.move(str(run_dir), str(target))
    return target


def _run_paid_pair_materialized(
    tree: SourceTree,
    *,
    runtime_binary: Path,
    output_dir: Path,
    budget_journal_path: Path,
    provider_auth_file: Path,
    user_authority_file: Path,
    frozen_manifest_file: Path,
) -> dict[str, Any]:
    # `root` is the materialized tree from here on: wrappers, scenarios, the
    # candidate and every re-observation resolve against it, never the live
    # checkout. The harness writes each run under that tree; the runner
    # moves it under the output directory before importing it, because the
    # evidence must outlive the temporary tree.
    root = tree.root
    observation = _observe(tree, runtime_binary)
    manifest = _read_private_json(
        frozen_manifest_file.expanduser().resolve(), "frozen-run manifest"
    )
    frozen_manifest_sha256 = verify_frozen_manifest(manifest, observation.fields)
    protocol = observation.protocol
    protocol_sha256 = observation.protocol_sha256
    runtime_binary = observation.runtime_path
    runtime_sha256 = observation.runtime_sha256
    wrappers = observation.wrappers
    wrapper_hashes = observation.wrapper_hashes
    inventory_hashes = observation.inventory_hashes
    pair = protocol["coding_pair"]
    rollout_cost, rollout_tokens, total_cost, total_tokens = _pair_fields(protocol)
    user_authority = load_user_authority(
        user_authority_file.expanduser().resolve(),
        protocol_sha256=protocol_sha256,
        manifest_sha256=frozen_manifest_sha256,
        max_cost_usd=total_cost,
        max_metered_tokens=total_tokens,
    )
    authorized_cost = float(user_authority["max_cost_usd"])
    authorized_tokens = int(user_authority["max_metered_tokens"])
    if rollout_cost * int(pair["rollouts"]) > authorized_cost:
        raise ValidationError("user cost authority cannot cover the complete frozen schedule")
    if rollout_tokens * int(pair["rollouts"]) > authorized_tokens:
        raise ValidationError("user token authority cannot cover the complete frozen schedule")

    suite_path = observation.suite_path
    suite = observation.suite
    expected_tasks = observation.tasks
    revision = _revision(observation.fields)
    config_ids = _config_ids(protocol)
    model = pair["model"]
    authority_manifest = _authority_manifest(
        observation,
        frozen_manifest_sha256=frozen_manifest_sha256,
        authorized_cost_microusd=usd_to_microusd(authorized_cost),
        authorized_metered_tokens=authorized_tokens,
    )
    budget_authority = BudgetAuthority(
        manifest_sha256=_canonical_sha256(authority_manifest),
        model_fingerprint=_canonical_sha256(model),
        provider_identity=f"{model['provider']}:{model['id']}",
        total_cost_microusd=usd_to_microusd(authorized_cost),
        total_metered_tokens=authorized_tokens,
    )
    output_dir = output_dir.resolve()
    outputs = {arm: output_dir / f"{arm}.jsonl" for arm in wrappers}
    journal_path = _require_external_budget_journal(budget_journal_path, output_dir)
    with BudgetJournal(journal_path, budget_authority) as journal:
        collected = {
            arm: _load_checkpoint(
                outputs[arm],
                variant=arm,
                suite=suite,
                repo_root=root,
                binary=wrappers[arm],
                trials=int(pair["trials"]),
                expected_tasks=expected_tasks,
                model_provider=model["provider"],
                model_id=model["id"],
                harness_revision=revision,
                harness_config_id=config_ids[arm],
                require_runtime_budget=True,
            )
            for arm in wrappers
        }
        _require_scoring_checkpoints(collected)
        completed = {
            arm: {(row["task_id"], row["trial"]) for row in rows}
            for arm, rows in collected.items()
        }
        checkpoint_transactions: set[str] = set()
        for arm, rows in collected.items():
            for row in rows:
                _require_runtime_budget_provenance(
                    row,
                    max_metered_tokens=rollout_tokens,
                    max_cost_usd=rollout_cost,
                )
                expected_attestation = {
                    "protocol_sha256": protocol_sha256,
                    "frozen_manifest_sha256": frozen_manifest_sha256,
                    "arm": arm,
                    "inventory_sha256": inventory_hashes[arm],
                }
                if row.get("plugin_treatment") != expected_attestation:
                    raise ValidationError("checkpoint plugin treatment attestation drifted")
                transaction = _transaction(
                    authority=budget_authority,
                    protocol_sha256=protocol_sha256,
                    task=expected_tasks[row["task_id"]],
                    arm=arm,
                    trial=int(row["trial"]),
                    revision=revision,
                    config_id=config_ids[arm],
                    wrapper_sha256=wrapper_hashes[arm],
                    runtime_sha256=runtime_sha256,
                    inventory_sha256=inventory_hashes[arm],
                    max_cost_usd=rollout_cost,
                    max_metered_tokens=rollout_tokens,
                )
                receipt = row.get("budget_transaction")
                if not isinstance(receipt, dict) or receipt.get("state") != "committed":
                    raise ValidationError("checkpoint is missing a committed budget receipt")
                transaction_id = str(receipt.get("transaction_id", ""))
                _require_receipt_bound(
                    receipt, journal.transaction_receipt(transaction_id), transaction
                )
                if (
                    receipt.get("actual_cost_microusd")
                    != usd_to_microusd_ceiling(row["metrics"]["cost_usd"])
                    or receipt.get("actual_metered_tokens") != _metered_tokens(row)
                ):
                    raise ValidationError("checkpoint usage does not match budget receipt")
                if journal.transaction_evidence_sha256(transaction_id) != rollout_evidence_sha256(row):
                    raise ValidationError(
                        "checkpoint rollout body does not match the evidence sealed in the journal"
                    )
                checkpoint_transactions.add(transaction_id)
        _require_no_orphan_budget_transactions(journal, checkpoint_transactions)

        remaining = sum(
            1
            for entry in observation.schedule
            if (entry["task_id"], entry["trial"]) not in completed[entry["arm"]]
        )
        committed_cost = sum(
            int(receipt.get("actual_cost_microusd") or 0)
            for receipt in journal.transaction_receipts()
            if receipt["state"] == "committed"
        )
        committed_tokens = sum(
            int(receipt.get("actual_metered_tokens") or 0)
            for receipt in journal.transaction_receipts()
            if receipt["state"] == "committed"
        )
        if committed_cost + remaining * usd_to_microusd(rollout_cost) > budget_authority.total_cost_microusd:
            raise ValidationError("remaining plugin schedule exceeds durable cost authority")
        if committed_tokens + remaining * rollout_tokens > budget_authority.total_metered_tokens:
            raise ValidationError("remaining plugin schedule exceeds durable token authority")
        if remaining == 0:
            return {"baseline": len(collected["baseline"]), "candidate": len(collected["candidate"])}

        runtime_api_key = _load_api_key(provider_auth_file.expanduser().resolve())
        output_dir.mkdir(parents=True, exist_ok=True)
        for entry in observation.schedule:
            trial, arm, task_id = int(entry["trial"]), str(entry["arm"]), str(entry["task_id"])
            if (task_id, trial) in completed[arm]:
                continue
            # The bracket around every request is the startup check
            # itself: the whole manifest against the whole tree. It
            # cannot see a change made and reverted inside the bracket
            # (#49); it does see everything that is still different
            # when the request ends, before its evidence is imported.
            _require_still_frozen(
                tree, runtime_binary, manifest, moment="before request"
            )
            transaction = _transaction(
                authority=budget_authority,
                protocol_sha256=protocol_sha256,
                task=expected_tasks[task_id],
                arm=arm,
                trial=trial,
                revision=revision,
                config_id=config_ids[arm],
                wrapper_sha256=wrapper_hashes[arm],
                runtime_sha256=runtime_sha256,
                inventory_sha256=inventory_hashes[arm],
                max_cost_usd=rollout_cost,
                max_metered_tokens=rollout_tokens,
            )
            reserved = journal.reserve(transaction)
            transaction_id = str(reserved["transaction_id"])
            try:
                journal.authorize_request(
                    transaction_id,
                    expected_revision=int(reserved["journal_revision"]),
                    expected_head_sha256=str(reserved["journal_head_sha256"]),
                )
            except BaseException as failure:
                # Nothing has been sent. If the authorization never became
                # durable the journal still says `reserved` and the abort
                # lands, so a resume is not blocked by a reservation nobody
                # spent. If it did become durable the journal refuses the
                # abort as not abortable and the transaction stays
                # authorized - the conservative state, a request may have
                # been admitted. Any other failure of the abort means the
                # reservation is stranded on disk: say so, with the original
                # failure as the cause, rather than pretend it was cleaned up.
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
            run_dir = _run_once(
                root,
                wrappers[arm],
                arm,
                trial,
                scenario_selector([task_id]),
                model["provider"],
                model["id"],
                suite_path,
                revision,
                harness_config_id=config_ids[arm],
                timeout_seconds=expected_tasks[task_id]["constraints"]["timeout_seconds"],
                max_metered_tokens=rollout_tokens,
                max_cost_usd=rollout_cost,
                runtime_api_key=runtime_api_key,
                runtime_env={
                    "METACODES_PLUGIN_RUNTIME_BINARY": str(runtime_binary),
                },
            )
            # The harness wrote the run under the materialized tree; the
            # evidence has to outlive that tree, so it moves under the
            # output directory before anything reads it.
            run_dir = _preserve_run_dir(run_dir, output_dir)
            _require_still_frozen(
                tree, runtime_binary, manifest, moment="after request"
            )
            imported = import_run(suite, root, run_dir)
            selected = [
                row
                for row in imported
                if row["task_id"] == task_id
                and row["trial"] == trial
                and row["task_fingerprint_provenance"] == "recorded_at_execution"
            ]
            if len(selected) != 1:
                raise ValidationError("paid plugin rollout produced ambiguous evidence")
            row = selected[0]
            _require_runtime_budget_provenance(
                row,
                max_metered_tokens=rollout_tokens,
                max_cost_usd=rollout_cost,
            )
            # The treatment attestation is part of the evidence: attached
            # before the body is digested, so the digest sealed into the
            # committed event covers it. The receipt is the only field the
            # digest excludes.
            row["plugin_treatment"] = {
                "protocol_sha256": protocol_sha256,
                "frozen_manifest_sha256": frozen_manifest_sha256,
                "arm": arm,
                "inventory_sha256": inventory_hashes[arm],
            }
            receipt = journal.commit(
                transaction_id,
                actual_cost_microusd=usd_to_microusd_ceiling(row["metrics"]["cost_usd"]),
                actual_metered_tokens=_metered_tokens(row),
                evidence_sha256=rollout_evidence_sha256(row),
            )
            row["budget_transaction"] = dict(receipt)
            collected[arm].append(row)
            completed[arm].add((task_id, trial))
            write_rollouts(outputs[arm], collected[arm])
            _require_scoring_rollout(row, variant=arm)
        return {"baseline": len(collected["baseline"]), "candidate": len(collected["candidate"])}


def main(argv: Sequence[str] | None = None) -> int:
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--protocol", type=Path, default=root / "evals/plugin-v1/protocol.json")
    parser.add_argument(
        "--runtime-binary",
        type=Path,
        help="explicit protocol-pinned ReleaseSmall metacodes artifact",
    )
    parser.add_argument("--allow-paid-rollouts", action="store_true")
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--budget-journal", type=Path)
    parser.add_argument("--auth-file", type=Path)
    parser.add_argument("--user-authority", type=Path)
    parser.add_argument(
        "--frozen-manifest",
        type=Path,
        help="frozen-run manifest: written by --freeze, required by --allow-paid-rollouts",
    )
    parser.add_argument(
        "--freeze",
        action="store_true",
        help="write the frozen-run manifest for this tree to --frozen-manifest and exit",
    )
    args = parser.parse_args(argv)
    try:
        runtime_binary = (
            args.runtime_binary.expanduser() if args.runtime_binary is not None else None
        )
        if args.freeze:
            if args.allow_paid_rollouts or runtime_binary is None or args.frozen_manifest is None:
                raise ValidationError("--freeze requires --runtime-binary and --frozen-manifest, and no paid flags")
            manifest = freeze_run(root, args.protocol.resolve(), runtime_binary)
            _write_private_json(args.frozen_manifest.expanduser().resolve(), manifest)
            print(json.dumps(manifest, sort_keys=True))
            return 0
        if not args.allow_paid_rollouts:
            plan = build_plan(
                root,
                args.protocol.resolve(),
                runtime_binary=runtime_binary,
            )
            print(json.dumps(plan, sort_keys=True))
            return 0
        missing = [
            name
            for name, value in (
                ("--output-dir", args.output_dir),
                ("--budget-journal", args.budget_journal),
                ("--auth-file", args.auth_file),
                ("--user-authority", args.user_authority),
                ("--frozen-manifest", args.frozen_manifest),
                ("--runtime-binary", runtime_binary),
            )
            if value is None
        ]
        if missing:
            raise ValidationError(f"paid plugin pair requires {', '.join(missing)}")
        result = run_paid_pair(
            root,
            args.protocol.resolve(),
            runtime_binary=runtime_binary,
            output_dir=args.output_dir,
            budget_journal_path=args.budget_journal,
            provider_auth_file=args.auth_file,
            user_authority_file=args.user_authority,
            frozen_manifest_file=args.frozen_manifest,
        )
    except (OSError, subprocess.SubprocessError, ValidationError, PluginGateError) as exc:
        parser.error(str(exc))
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
