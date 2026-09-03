"""Build governed static/evolved E3 rule templates for one stable project root.

The output is local setup evidence, not a model-quality result.  Both templates
traverse the transcript/source/candidate/isolated-build/replay/shadow/promotion
and independent-audit lifecycle.  They intentionally use different HOME roots
but the same absolute project root, so later four-arm rollouts can copy the
self-contained ``project-rules`` directory into fresh homes without changing
the project identity or provider-visible working directory.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
from typing import Any, Dict, Mapping, Sequence


if __package__ in {None, ""}:
    import sys

    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    from scripts.eval.project_harness_binary_boundary import _canonical_lake  # type: ignore
    from scripts.eval.project_harness_evolution import (  # type: ignore
        EvolutionError,
        _git_identity,
        _identity,
        _read_json,
        _read_regular,
        _sha256_file,
        _sha256_bytes,
        _wire_json,
        _write_new,
    )
else:
    from .project_harness_binary_boundary import _canonical_lake
    from .project_harness_evolution import (
        EvolutionError,
        _git_identity,
        _identity,
        _read_json,
        _read_regular,
        _sha256_file,
        _sha256_bytes,
        _wire_json,
        _write_new,
    )


SCHEMA = "metacodes-project-harness-e3-templates-v1"
FLAVORS = ("static", "evolved")
MAX_TEMPLATE_BYTES = 64 * 1024 * 1024
KERNEL_PROVENANCE_SCHEMA = "metacodes-project-kernel-artifact-v6"
KERNEL_PROVENANCE_FIELDS = frozenset(
    {
        "schema_version",
        "checker_version",
        "request_schema",
        "verdict_schema",
        "batch_request_schema",
        "batch_verdict_schema",
        "impact_request_schema",
        "impact_verdict_schema",
        "impact_aggregate_request_schema",
        "impact_aggregate_verdict_schema",
        "max_batch_requests",
        "max_impact_aggregate_members",
        "binary_sha256",
        "binary_bytes",
        "kernel_source_sha256",
        "rule_source_sha256",
        "impact_source_sha256",
        "impact_aggregate_source_sha256",
        "formal_kernel_source_sha256",
        "main_source_sha256",
        "axiom_audit_source_sha256",
        "axiom_policy",
        "axiom_audit",
        "host_os",
        "host_arch",
        "linker",
        "lean_version",
        "native_smoke",
        "native_rule_author_promotion_smoke",
        "native_batch_smoke",
        "native_recovery_smoke",
        "native_impact_smoke",
        "native_impact_aggregate_smoke",
    }
)
EXPECTED_SPECS: Mapping[str, Mapping[str, Any]] = {
    "static": {
        "schema_version": "metacodes-project-rule-spec-v3",
        "target_kind": "tool",
        "target": "Write",
        "target_scope": "all",
        "deny_target": False,
        "max_input_bytes": 8192,
        "max_agent_depth": 4,
        "authoritative_only": True,
        "effect_requirement": "file_mutation_v1_reobserved",
    },
    "evolved": {
        "schema_version": "metacodes-project-rule-spec-v3",
        "target_kind": "tool",
        "target": "Write",
        "target_scope": "existing_file",
        "deny_target": True,
        "max_input_bytes": 8192,
        "max_agent_depth": 4,
        "authoritative_only": True,
        "effect_requirement": "none",
    },
}


class TemplateError(RuntimeError):
    """Fail-closed template setup error."""


def _verified_kernel_artifact(repo: Path, kernel: Path) -> Dict[str, Any]:
    """Bind the shipped checker to the exact Lean sources under study."""

    repo = repo.resolve(strict=True)
    kernel = kernel.resolve(strict=True)
    provenance_path = Path(f"{kernel}.provenance.json")
    provenance = _read_json(provenance_path)
    binary_raw = _read_regular(kernel, MAX_TEMPLATE_BYTES)
    expected_sources = {
        "kernel_source_sha256": repo
        / "control-plane/lean/MetaCodesControl/ProjectHarness.lean",
        "rule_source_sha256": repo
        / "control-plane/lean/MetaCodesControl/ProjectRule.lean",
        "impact_source_sha256": repo
        / "control-plane/lean/MetaCodesControl/RuleImpactGovernance.lean",
        "impact_aggregate_source_sha256": repo
        / "control-plane/lean/MetaCodesControl/RuleImpactAggregateGovernance.lean",
        "formal_kernel_source_sha256": repo
        / "control-plane/lean/MetaCodesControl/FormalKernel.lean",
        "main_source_sha256": repo / "control-plane/lean/ProjectHarnessMain.lean",
        "axiom_audit_source_sha256": repo
        / "control-plane/lean/ProjectHarnessAxiomAudit.lean",
    }
    if (
        set(provenance) != KERNEL_PROVENANCE_FIELDS
        or provenance.get("schema_version") != KERNEL_PROVENANCE_SCHEMA
        or provenance.get("checker_version") != "metacodes-project-harness-kernel-v3"
        or provenance.get("request_schema") != "metacodes-project-harness-request-v3"
        or provenance.get("verdict_schema") != "metacodes-project-harness-verdict-v3"
        or provenance.get("batch_request_schema")
        != "metacodes-project-harness-batch-request-v3"
        or provenance.get("batch_verdict_schema")
        != "metacodes-project-harness-batch-verdict-v3"
        or provenance.get("impact_request_schema")
        != "metacodes-rule-impact-governance-request-v1"
        or provenance.get("impact_verdict_schema")
        != "metacodes-rule-impact-governance-verdict-v1"
        or provenance.get("impact_aggregate_request_schema")
        != "metacodes-rule-impact-aggregate-governance-request-v1"
        or provenance.get("impact_aggregate_verdict_schema")
        != "metacodes-rule-impact-aggregate-governance-verdict-v1"
        or provenance.get("max_batch_requests") != 1024
        or provenance.get("max_impact_aggregate_members") != 64
        or provenance.get("binary_sha256") != _sha256_bytes(binary_raw)
        or provenance.get("binary_bytes") != len(binary_raw)
        or provenance.get("axiom_policy") != "propext"
        or provenance.get("axiom_audit") != "passed"
        or provenance.get("native_smoke") != "passed"
        or provenance.get("native_rule_author_promotion_smoke") != "passed"
        or provenance.get("native_batch_smoke") != "passed"
        or provenance.get("native_recovery_smoke") != "passed"
        or provenance.get("native_impact_smoke") != "passed"
        or provenance.get("native_impact_aggregate_smoke") != "passed"
        or not isinstance(provenance.get("lean_version"), str)
        or not provenance["lean_version"]
        or any(
            provenance.get(field) != _sha256_file(source)
            for field, source in expected_sources.items()
        )
    ):
        raise TemplateError("project kernel provenance/source binding drift")
    return {
        "path": str(kernel),
        "sha256": provenance["binary_sha256"],
        "provenance_path": str(provenance_path),
        "provenance_sha256": _sha256_file(provenance_path),
    }


def _run(
    argv: Sequence[str],
    cwd: Path,
    env: Mapping[str, str],
    timeout: int = 120,
) -> None:
    completed = subprocess.run(
        argv,
        cwd=cwd,
        env=dict(env),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        check=False,
    )
    if completed.returncode != 0:
        raise TemplateError(
            f"template command failed exit={completed.returncode}: "
            f"{completed.stderr.decode('utf-8', 'replace')[-2000:]}"
        )


def _tree_digest(root: Path) -> Dict[str, Any]:
    if not root.is_dir() or root.is_symlink():
        raise TemplateError("project-rules template is not a real directory")
    hasher = hashlib.sha256()
    files = 0
    total = 0
    for path in sorted(root.rglob("*")):
        info = path.lstat()
        relative = path.relative_to(root).as_posix()
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
            raise TemplateError(f"invalid project-rules entry: {relative}")
        if info.st_nlink != 1:
            raise TemplateError(f"hard-linked project-rules entry: {relative}")
        raw = _read_regular(path, MAX_TEMPLATE_BYTES - total)
        files += 1
        total += len(raw)
        if total > MAX_TEMPLATE_BYTES:
            raise TemplateError("project-rules template exceeds size cap")
        encoded = relative.encode("utf-8")
        hasher.update(len(encoded).to_bytes(8, "big"))
        hasher.update(encoded)
        hasher.update(len(raw).to_bytes(8, "big"))
        hasher.update(raw)
    if files < 5:
        raise TemplateError("project-rules template is incomplete")
    return {"tree_sha256": hasher.hexdigest(), "files": files, "bytes": total}


def _project_identity(project: Path) -> str:
    return hashlib.sha256(
        b"metacodes-project-identity-v1\x00" + os.fsencode(str(project))
    ).hexdigest()


def _owned_real_directory(path: Path, where: str) -> None:
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or (hasattr(os, "getuid") and info.st_uid != os.getuid()):
        raise TemplateError(f"{where} must be an owned real directory")


def _template_rules_relative(home: Path, rules_dir: Path) -> bool:
    try:
        relative = rules_dir.relative_to(home)
    except ValueError:
        return False
    parts = relative.parts
    return (
        len(parts) == 4
        and parts[0:2] == (".metacodes", "projects")
        and len(parts[2]) == 16
        and all(char in "0123456789abcdef" for char in parts[2])
        and parts[3] == "project-rules"
    )


def verify_templates(
    manifest_path: Path,
    repo: Path,
    *,
    require_clean: bool = True,
    require_kernel_provenance: bool = True,
) -> Dict[str, Any]:
    """Reopen every E3 template identity before it can authorize a rollout."""

    repo = repo.resolve(strict=True)
    manifest = _read_json(manifest_path)
    manifest_path = manifest_path.resolve(strict=True)
    if (
        manifest.get("schema_version") != SCHEMA
        or manifest.get("evidence_level") != "E3-template-setup"
        or manifest.get("quality_evidence") is not False
        or manifest.get("outcome_superiority_claimed") is not False
        or manifest.get("provider_mode") != "none"
        or manifest.get("external_provider_requests") != 0
        or manifest.get("paid_cost_usd") != 0
    ):
        raise TemplateError("template manifest overclaims evidence or provider usage")
    root = Path(str(manifest.get("root", "")))
    if not root.is_absolute() or root != manifest_path.parent:
        raise TemplateError("template manifest/root binding drift")
    _owned_real_directory(root, "E3 template root")
    project = Path(str(manifest.get("project_root", "")))
    if project != root / "workspace":
        raise TemplateError("template project path drift")
    _owned_real_directory(project, "E3 project root")
    project_sha256 = _identity(manifest.get("project_sha256"), "project_sha256")
    if project_sha256 != _project_identity(project):
        raise TemplateError("template project identity drift")

    repository = manifest.get("repository")
    if (
        not isinstance(repository, Mapping)
        or not isinstance(repository.get("commit"), str)
        or len(repository["commit"]) != 40
        or any(char not in "0123456789abcdef" for char in repository["commit"])
        or not isinstance(repository.get("dirty"), bool)
    ):
        raise TemplateError("template repository identity is invalid")
    if manifest.get("paid_rollout_eligible") is not (not repository["dirty"]):
        raise TemplateError("template paid-rollout eligibility drift")
    if require_clean and repository["dirty"]:
        raise TemplateError("dirty repository cannot authorize a paid rollout")
    if dict(_git_identity(repo)) != dict(repository):
        raise TemplateError("template repository identity drift")
    artifacts = manifest.get("artifacts")
    if not isinstance(artifacts, Mapping) or set(artifacts) != {"driver", "kernel", "lake", "builder"}:
        raise TemplateError("template artifact set drift")
    for name, item in artifacts.items():
        if not isinstance(item, Mapping):
            raise TemplateError(f"template artifact is invalid: {name}")
        path = Path(str(item.get("path", "")))
        if not path.is_absolute() or _sha256_file(path) != _identity(item.get("sha256"), f"artifact.{name}"):
            raise TemplateError(f"template artifact identity drift: {name}")
    if require_kernel_provenance:
        kernel_artifact = _verified_kernel_artifact(
            repo,
            Path(str(artifacts["kernel"]["path"])),
        )
        if artifacts["kernel"] != kernel_artifact:
            raise TemplateError("template kernel provenance identity drift")
    elif set(artifacts["kernel"]) != {"path", "sha256"}:
        # Historical manifests can be reopened only under their exact source
        # commit.  They retain their original binary binding, but never gain a
        # retroactive claim to the source-complete v4 provenance contract.
        raise TemplateError("legacy template kernel artifact contract drift")

    templates = manifest.get("templates")
    if not isinstance(templates, Mapping) or set(templates) != set(FLAVORS):
        raise TemplateError("template flavor set drift")
    bundle_ids: set[str] = set()
    for flavor in FLAVORS:
        template = templates.get(flavor)
        if not isinstance(template, Mapping):
            raise TemplateError(f"missing {flavor} template")
        if (
            template.get("flavor") != flavor
            or template.get("quality_evidence") is not False
            or template.get("provider_requests") != 0
            or template.get("paid_cost_usd") != 0
            or template.get("project_sha256") != project_sha256
        ):
            raise TemplateError(f"{flavor} template boundary drift")
        candidate_id = _identity(template.get("candidate_id"), f"{flavor}.candidate_id")
        bundle_id = _identity(template.get("bundle_sha256"), f"{flavor}.bundle_sha256")
        active_id = _identity(template.get("active_pointer_sha256"), f"{flavor}.active_pointer_sha256")
        promotion_id = _identity(template.get("promotion_receipt_id"), f"{flavor}.promotion_receipt_id")
        _identity(template.get("source_receipt_id"), f"{flavor}.source_receipt_id")
        bundle_ids.add(bundle_id)

        flavor_root = root / "templates" / flavor
        home = Path(str(template.get("home_root", "")))
        rules_dir = Path(str(template.get("rules_dir", "")))
        if home != flavor_root / "home" or not _template_rules_relative(home, rules_dir):
            raise TemplateError(f"{flavor} template path binding drift")
        _owned_real_directory(home, f"{flavor} template HOME")
        if _tree_digest(rules_dir) != template.get("tree"):
            raise TemplateError(f"{flavor} project-rules tree drift")

        evidence = flavor_root / "evidence"
        prepared = _read_json(evidence / "lifecycle-prepare.json")
        final = _read_json(evidence / "lifecycle-final.json")
        audit = _read_json(evidence / "lifecycle-audit.json")
        if (
            _sha256_file(evidence / "lifecycle-prepare.json") != template.get("prepare_sha256")
            or _sha256_file(evidence / "lifecycle-final.json") != template.get("final_sha256")
            or _sha256_file(evidence / "lifecycle-audit.json") != template.get("audit_sha256")
            or prepared.get("rule_flavor") != flavor
            or final.get("rule_flavor") != flavor
            or audit.get("rule_flavor") != flavor
            or prepared.get("project_sha256") != project_sha256
            or final.get("project_sha256") != project_sha256
            or prepared.get("candidate_id") != candidate_id
            or final.get("candidate_id") != candidate_id
            or audit.get("candidate_id") != candidate_id
            or final.get("bundle_sha256") != bundle_id
            or audit.get("bundle_sha256") != bundle_id
            or final.get("runtime_task_succeeded") is not True
            or final.get("runtime_blocked_before_dispatch") != (flavor == "evolved")
            or final.get("runtime_recovery_succeeded") != (flavor == "evolved")
        ):
            raise TemplateError(f"{flavor} lifecycle identity drift")

        active = _read_json(rules_dir / "active.json")
        active_body = active.get("body")
        if (
            not isinstance(active_body, Mapping)
            or active.get("pointer_sha256") != active_id
            or _sha256_bytes(_wire_json(active_body)) != active_id
            or active_body.get("project_sha256") != project_sha256
            or active_body.get("bundle_sha256") != bundle_id
            or active_body.get("promotion_receipt_id") != promotion_id
        ):
            raise TemplateError(f"{flavor} active pointer drift")
        bundle = _read_json(rules_dir / f"project-rule-bundle-{bundle_id}.json")
        body = bundle.get("body")
        rules = body.get("rules") if isinstance(body, Mapping) else None
        bundle_revision = body.get("revision") if isinstance(body, Mapping) else None
        if (
            not isinstance(body, Mapping)
            or bundle.get("bundle_sha256") != bundle_id
            or _sha256_bytes(_wire_json(body)) != bundle_id
            or body.get("project_sha256") != project_sha256
            or isinstance(bundle_revision, bool)
            or not isinstance(bundle_revision, int)
            or bundle_revision <= 0
            or active_body.get("revision") != bundle_revision
            or (
                "bundle_revision" in template
                and template.get("bundle_revision") != bundle_revision
            )
            or not isinstance(rules, list)
            or len(rules) != 1
            or not isinstance(rules[0], Mapping)
            or rules[0].get("candidate_id") != candidate_id
            or rules[0].get("rule_spec") != EXPECTED_SPECS[flavor]
            or template.get("rule_spec") != EXPECTED_SPECS[flavor]
        ):
            raise TemplateError(f"{flavor} active bundle drift")
    if len(bundle_ids) != len(FLAVORS):
        raise TemplateError("static/evolved templates unexpectedly share one bundle")
    return manifest


def _run_flavor(
    *,
    repo: Path,
    root: Path,
    project: Path,
    flavor: str,
    driver: Path,
    kernel: Path,
    kernel_sha256: str,
    lake: Path,
    builder: Path,
) -> Dict[str, Any]:
    flavor_root = root / "templates" / flavor
    evidence = flavor_root / "evidence"
    home = flavor_root / "home"
    evidence.mkdir(mode=0o700, parents=True)
    home.mkdir(mode=0o700, parents=True)
    base_env = {
        "PATH": os.defpath,
        "TMPDIR": tempfile.gettempdir(),
        "LANG": "C",
        "LC_ALL": "C",
        "TZ": "UTC",
        "METACODES_PROJECT_KERNEL_PATH": str(kernel),
        "METACODES_PROJECT_KERNEL_SHA256": kernel_sha256,
    }
    common_identity = [
        "--root",
        str(evidence),
        "--project-root",
        str(project),
        "--home-root",
        str(home),
        "--rule-flavor",
        flavor,
    ]
    _run([str(driver), "--phase", "prepare", *common_identity], repo, base_env)
    prepared = _read_json(evidence / "lifecycle-prepare.json")
    if prepared.get("rule_flavor") != flavor:
        raise TemplateError("prepared rule flavor drift")
    candidate = Path(str(prepared.get("candidate_path", "")))
    candidate_id = _identity(prepared.get("candidate_id"), "candidate_id")
    build_dir = evidence / "isolated-build"
    _run(
        [
            os.sys.executable,
            str(builder),
            "--repo",
            str(repo),
            "--candidate",
            str(candidate),
            "--candidate-id",
            candidate_id,
            "--out",
            str(build_dir),
            "--lake",
            str(lake),
        ],
        repo,
        {"PATH": os.defpath, "TMPDIR": tempfile.gettempdir(), "LANG": "C", "LC_ALL": "C", "TZ": "UTC"},
    )
    finalize = [
        *common_identity,
        "--repo",
        str(repo),
        "--build-dir",
        str(build_dir),
        "--lake",
        str(lake),
        "--kernel",
        str(kernel),
        "--kernel-sha256",
        kernel_sha256,
    ]
    _run([str(driver), "--phase", "finalize", *finalize], repo, base_env)
    _run([str(driver), "--phase", "audit", *finalize], repo, base_env)

    final = _read_json(evidence / "lifecycle-final.json")
    audit = _read_json(evidence / "lifecycle-audit.json")
    if (
        final.get("rule_flavor") != flavor
        or audit.get("rule_flavor") != flavor
        or audit.get("audit_passed") is not True
        or final.get("quality_evidence") is not False
        or final.get("provider_requests") != 0
        or final.get("paid_cost_usd") != 0
    ):
        raise TemplateError("template lifecycle overclaimed or did not pass")
    project_sha256 = _identity(final.get("project_sha256"), "project_sha256")
    if project_sha256 != prepared.get("project_sha256"):
        raise TemplateError("template project identity drift")
    bundle_sha256 = _identity(final.get("bundle_sha256"), "bundle_sha256")
    if bundle_sha256 != audit.get("bundle_sha256"):
        raise TemplateError("template bundle audit drift")
    rules_dir = Path(str(prepared.get("rules_dir", "")))
    active = _read_json(rules_dir / "active.json")
    active_body = active.get("body")
    if not isinstance(active_body, dict) or active_body.get("bundle_sha256") != bundle_sha256:
        raise TemplateError("template active pointer drift")
    bundle = _read_json(rules_dir / f"project-rule-bundle-{bundle_sha256}.json")
    body = bundle.get("body")
    rules = body.get("rules") if isinstance(body, dict) else None
    bundle_revision = body.get("revision") if isinstance(body, dict) else None
    if (
        isinstance(bundle_revision, bool)
        or not isinstance(bundle_revision, int)
        or bundle_revision <= 0
        or not isinstance(active_body, dict)
        or active_body.get("revision") != bundle_revision
        or not isinstance(rules, list)
        or len(rules) != 1
        or not isinstance(rules[0], dict)
    ):
        raise TemplateError("template bundle must contain exactly one rule")
    return {
        "flavor": flavor,
        "quality_evidence": False,
        "provider_requests": 0,
        "paid_cost_usd": 0,
        "home_root": str(home),
        "rules_dir": str(rules_dir),
        "project_sha256": project_sha256,
        "candidate_id": candidate_id,
        "source_receipt_id": _identity(prepared.get("source_receipt_id"), "source_receipt_id"),
        "bundle_sha256": bundle_sha256,
        "bundle_revision": bundle_revision,
        "active_pointer_sha256": _identity(final.get("active_pointer_sha256"), "active_pointer_sha256"),
        "promotion_receipt_id": _identity(final.get("promotion_receipt_id"), "promotion_receipt_id"),
        "rule_spec": rules[0]["rule_spec"],
        "tree": _tree_digest(rules_dir),
        "prepare_sha256": _sha256_file(evidence / "lifecycle-prepare.json"),
        "final_sha256": _sha256_file(evidence / "lifecycle-final.json"),
        "audit_sha256": _sha256_file(evidence / "lifecycle-audit.json"),
    }


def build_templates(
    *,
    repo: Path,
    root: Path,
    driver: Path,
    kernel: Path,
    lake: Path,
    builder: Path,
    allow_dirty: bool = False,
) -> Dict[str, Any]:
    repo = repo.resolve(strict=True)
    repository = dict(_git_identity(repo))
    if repository["dirty"] and not allow_dirty:
        raise TemplateError("E3 templates require a clean committed repository")
    driver = driver.resolve(strict=True)
    kernel = kernel.resolve(strict=True)
    lake = _canonical_lake(repo, lake)
    builder = builder.resolve(strict=True)
    if root.exists():
        _owned_real_directory(root, "E3 template root")
        if any(root.iterdir()):
            raise TemplateError("E3 template root must be absent or empty")
    else:
        root.mkdir(mode=0o700, parents=True)
    root = root.resolve(strict=True)
    _owned_real_directory(root, "E3 template root")
    os.chmod(root, 0o700)
    project = root / "workspace"
    project.mkdir(mode=0o700)
    kernel_artifact = _verified_kernel_artifact(repo, kernel)
    kernel_sha256 = str(kernel_artifact["sha256"])
    templates = {
        flavor: _run_flavor(
            repo=repo,
            root=root,
            project=project,
            flavor=flavor,
            driver=driver,
            kernel=kernel,
            kernel_sha256=kernel_sha256,
            lake=lake,
            builder=builder,
        )
        for flavor in FLAVORS
    }
    project_ids = {value["project_sha256"] for value in templates.values()}
    if len(project_ids) != 1:
        raise TemplateError("static/evolved templates do not bind the same project")
    result = {
        "schema_version": SCHEMA,
        "evidence_level": "E3-template-setup",
        "quality_evidence": False,
        "outcome_superiority_claimed": False,
        "provider_mode": "none",
        "external_provider_requests": 0,
        "paid_cost_usd": 0,
        "repository": repository,
        "paid_rollout_eligible": not repository["dirty"],
        "root": str(root),
        "project_root": str(project),
        "project_sha256": next(iter(project_ids)),
        "artifacts": {
            "driver": {"path": str(driver), "sha256": _sha256_file(driver)},
            "kernel": kernel_artifact,
            "lake": {"path": str(lake), "sha256": _sha256_file(lake)},
            "builder": {"path": str(builder), "sha256": _sha256_file(builder)},
        },
        "templates": templates,
        "boundaries": [
            "setup proves governed template identity, not model-task benefit",
            "later rollout homes must be fresh and copy only the self-contained project-rules tree",
            "all four arms must execute serially at the same absolute project root",
        ],
    }
    manifest_path = root / "templates-manifest.json"
    _write_new(manifest_path, result)
    return verify_templates(manifest_path, repo, require_clean=not allow_dirty)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--driver", type=Path, required=True)
    parser.add_argument("--kernel", type=Path, required=True)
    parser.add_argument("--lake", type=Path)
    parser.add_argument("--builder", type=Path, required=True)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        lake = args.lake
        if lake is None:
            lake = Path.home() / ".elan/bin/lake"
        result = build_templates(
            repo=args.repo,
            root=args.root,
            driver=args.driver,
            kernel=args.kernel,
            lake=lake,
            builder=args.builder,
        )
    except (TemplateError, EvolutionError, OSError, subprocess.SubprocessError) as exc:
        print(f"project-Harness E3 template setup failed: {exc}", file=os.sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
