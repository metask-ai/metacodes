#!/usr/bin/env python3
"""Build one untrusted project-rule candidate in an OS sandbox.

This is an offline evidence producer, not a runtime compiler and not a
promotion command.  It emits an immutable build bundle which Zig re-reads
before creating build/axiom lifecycle receipts.  Missing sandbox support,
unexpected declarations/axioms, spec drift, output overflow, timeout, and
partial destinations all fail closed.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import shutil
import stat
import subprocess
import sys
import time
from typing import Any, Sequence


CANDIDATE_SCHEMA = "metacodes-rule-candidate-v3"
SPEC_SCHEMA = "metacodes-project-rule-spec-v2"
MANIFEST_SCHEMA = "metacodes-project-rule-build-v1"
MAX_CANDIDATE_BYTES = 128 * 1024
MAX_SOURCE_BYTES = 32 * 1024
MAX_LOG_BYTES = 1024 * 1024
MAX_ARTIFACT_BYTES = 16 * 1024 * 1024
TIMEOUT_SECONDS = 90
FORBIDDEN = {
    "admit",
    "axiom",
    "elab",
    "eval",
    "extern",
    "import",
    "macro",
    "opaque",
    "run_tac",
    "set_option",
    "sorry",
    "unsafe",
}


class BuildError(RuntimeError):
    pass


def strict_json_loads(raw: bytes) -> Any:
    def object_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise BuildError(f"duplicate JSON field: {key}")
            result[key] = value
        return result

    def invalid_constant(value: str) -> None:
        raise BuildError(f"invalid JSON constant: {value}")

    try:
        return json.loads(raw, object_pairs_hook=object_pairs, parse_constant=invalid_constant)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise BuildError(f"candidate is not strict UTF-8 JSON: {exc}") from exc


def stable_json(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path, maximum: int = MAX_ARTIFACT_BYTES) -> tuple[str, int]:
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_size <= 0 or before.st_size > maximum:
            raise BuildError(f"invalid artifact size/type: {path}")
        digest = hashlib.sha256()
        total = 0
        while chunk := os.read(fd, 64 * 1024):
            total += len(chunk)
            if total > maximum:
                raise BuildError(f"artifact exceeds bound: {path}")
            digest.update(chunk)
        after = os.fstat(fd)
        if (
            before.st_dev,
            before.st_ino,
            before.st_size,
            before.st_mtime_ns,
            before.st_ctime_ns,
        ) != (
            after.st_dev,
            after.st_ino,
            after.st_size,
            after.st_mtime_ns,
            after.st_ctime_ns,
        ):
            raise BuildError(f"artifact changed during hash: {path}")
        return digest.hexdigest(), total
    finally:
        os.close(fd)


def read_regular(path: Path, maximum: int) -> bytes:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size <= 0 or info.st_size > maximum:
            raise BuildError(f"invalid input file: {path}")
        value = b""
        while len(value) < info.st_size:
            chunk = os.read(fd, min(64 * 1024, info.st_size - len(value)))
            if not chunk:
                raise BuildError(f"short read: {path}")
            value += chunk
        after = os.fstat(fd)
        if (
            info.st_dev,
            info.st_ino,
            info.st_size,
            info.st_mtime_ns,
            info.st_ctime_ns,
        ) != (
            after.st_dev,
            after.st_ino,
            after.st_size,
            after.st_mtime_ns,
            after.st_ctime_ns,
        ):
            raise BuildError(f"input changed during read: {path}")
        return value
    finally:
        os.close(fd)


def strip_lean_noncode(source: str) -> str:
    # Candidate source is bounded.  Nested block comments are rejected below;
    # this scanner intentionally accepts comments/strings containing words like
    # "axiom" while preserving executable tokens.
    source = re.sub(r"/-.*?-/", "", source, flags=re.DOTALL)
    source = re.sub(r"--.*$", "", source, flags=re.MULTILINE)
    return re.sub(r'"(?:\\.|[^"\\])*"', '""', source)


def validate_candidate(raw: bytes, expected_id: str | None) -> tuple[dict[str, Any], str, str, bytes]:
    record = strict_json_loads(raw)
    if not isinstance(record, dict) or set(record) != {"candidate_id", "state", "body"}:
        raise BuildError("candidate record shape mismatch")
    body = record["body"]
    if not isinstance(body, dict) or body.get("schema_version") != CANDIDATE_SCHEMA or record["state"] != "proposed":
        raise BuildError("unsupported candidate schema/state")
    if set(body) != {
        "schema_version",
        "project_sha256",
        "proposer_sha256",
        "invariant",
        "rule_spec",
        "lean_source",
        "source",
    }:
        raise BuildError("candidate body shape mismatch")
    candidate_id = record["candidate_id"]
    if not isinstance(candidate_id, str) or not re.fullmatch(r"[0-9a-f]{64}", candidate_id):
        raise BuildError("invalid candidate id")
    if expected_id is not None and candidate_id != expected_id:
        raise BuildError("candidate id does not match requested identity")
    if sha256_bytes(stable_json(body)) != candidate_id:
        raise BuildError("candidate body hash mismatch")
    for name in ("project_sha256", "proposer_sha256"):
        if not isinstance(body[name], str) or not re.fullmatch(r"[0-9a-f]{64}", body[name]):
            raise BuildError(f"candidate {name} is invalid")
    invariant = body["invariant"]
    if not isinstance(invariant, str) or not invariant.strip() or len(invariant.encode("utf-8")) > 8 * 1024:
        raise BuildError("candidate invariant is missing or oversized")
    if not isinstance(body["source"], dict) or len(body["source"]) != 1:
        raise BuildError("candidate source union is invalid")
    source = body.get("lean_source")
    if not isinstance(source, str) or not source.strip() or len(source.encode("utf-8")) > MAX_SOURCE_BYTES:
        raise BuildError("candidate Lean source is missing or oversized")
    if "/-" in strip_lean_noncode(source) or "-/" in strip_lean_noncode(source):
        raise BuildError("malformed or nested Lean block comment")
    executable = strip_lean_noncode(source)
    forbidden = sorted(FORBIDDEN.intersection(re.findall(r"\b[A-Za-z_][A-Za-z0-9_]*\b", executable)))
    if forbidden:
        raise BuildError("forbidden Lean declarations/tokens: " + ", ".join(forbidden))
    if not re.search(r"\bdef\s+spec\b", executable) or not re.search(r"\btheorem\s+spec_valid\b", executable):
        raise BuildError("candidate must define spec and theorem spec_valid")
    spec = body.get("rule_spec")
    if not isinstance(spec, dict) or spec.get("schema_version") != SPEC_SCHEMA:
        raise BuildError("candidate rule spec is missing or unsupported")
    expected_keys = {
        "schema_version",
        "target_tool",
        "target_scope",
        "deny_target",
        "max_input_bytes",
        "max_agent_depth",
        "authoritative_only",
        "effect_requirement",
    }
    if set(spec) != expected_keys:
        raise BuildError("candidate rule spec shape mismatch")
    target_tool = spec["target_tool"]
    if (
        not isinstance(target_tool, str)
        or not re.fullmatch(r"[A-Za-z0-9_-]+", target_tool)
        or len(target_tool.encode("ascii")) > 128
    ):
        raise BuildError("candidate target tool syntax is invalid")
    target_scope = spec["target_scope"]
    if target_scope not in {"all", "existing_file"}:
        raise BuildError("candidate target scope is invalid")
    if target_scope == "existing_file" and target_tool != "Write":
        raise BuildError("existing_file target scope requires Write")
    for name in ("deny_target", "authoritative_only"):
        if type(spec[name]) is not bool:
            raise BuildError(f"candidate {name} must be boolean")
    max_input_bytes = spec["max_input_bytes"]
    max_agent_depth = spec["max_agent_depth"]
    if type(max_input_bytes) is not int or not 0 < max_input_bytes <= 16 * 1024 * 1024:
        raise BuildError("candidate input bound is invalid")
    if type(max_agent_depth) is not int or not 0 <= max_agent_depth <= 16:
        raise BuildError("candidate depth bound is invalid")
    effect_requirement = spec["effect_requirement"]
    if effect_requirement not in {"none", "file_mutation_v1_reobserved"}:
        raise BuildError("candidate effect requirement is invalid")
    if spec["deny_target"] and effect_requirement != "none":
        raise BuildError("denied target cannot require a post effect")
    return record, candidate_id, source, stable_json(spec)


def lean_wrapper(source: str, trailer: str) -> str:
    return (
        "import MetaCodesControl.ProjectRule\n\n"
        "namespace CandidateRule\n"
        "open MetaCodesControl.ProjectRule\n\n"
        + source
        + "\n\nend CandidateRule\n\n"
        + trailer
        + "\n"
    )


def sbpl_quote(path: Path) -> str:
    return str(path).replace("\\", "\\\\").replace('"', '\\"')


def sandbox_command(repo: Path, work: Path, lake: Path, argv: Sequence[str]) -> tuple[list[str], str]:
    if sys.platform == "darwin":
        sandbox_exec = Path("/usr/bin/sandbox-exec")
        if not sandbox_exec.is_file():
            raise BuildError("macOS sandbox-exec is unavailable")
        toolchain_root = lake.parent.parent
        read_roots = [
            Path("/System"),
            Path("/usr"),
            Path("/bin"),
            Path("/sbin"),
            Path("/Library"),
            Path("/Applications/Xcode.app"),
            Path("/private/etc"),
            Path("/private/var"),
            repo,
            toolchain_root,
            work,
        ]
        # A deny-default profile aborts before main on current macOS because
        # dyld needs non-filesystem bootstrap operations which are not exposed
        # as a stable public SBPL surface.  Preserve those OS primitives, then
        # close the capabilities that matter to this build: network, reading
        # arbitrary files, writing outside the scratch directory, and
        # inspecting other processes.
        rules = [
            "(version 1)",
            "(allow default)",
            "(deny network*)",
            "(deny process-info* (target others))",
            '(deny file-read* (subpath "/"))',
            '(deny file-write* (subpath "/"))',
            "(allow file-read*",
            '  (literal "/")',
        ]
        for root in read_roots:
            if root.exists():
                rules.append(f'  (subpath "{sbpl_quote(root)}")')
        rules.extend(
            [
                '  (literal "/dev/null")',
                '  (literal "/dev/random")',
                '  (literal "/dev/urandom")',
            ]
        )
        rules.append(")")
        ancestors: set[Path] = set()
        for root in (*read_roots, work):
            current = root.parent
            while current != current.parent:
                ancestors.add(current)
                current = current.parent
        rules.append("(allow file-read-metadata")
        for ancestor in sorted(ancestors, key=str):
            rules.append(f'  (literal "{sbpl_quote(ancestor)}")')
        rules.extend(
            [
                ")",
                "(allow file-write*",
                f'  (subpath "{sbpl_quote(work)}")',
                '  (literal "/dev/null")',
                '  (literal "/dev/stdout")',
                '  (literal "/dev/stderr")',
                '  (literal "/dev/random")',
                '  (literal "/dev/urandom")',
                '  (regex #"^/dev/fd/")',
                ")",
            ]
        )
        return [str(sandbox_exec), "-p", "\n".join(rules), *argv], "macos-seatbelt-v1"
    if sys.platform.startswith("linux"):
        bwrap = shutil.which("bwrap")
        if not bwrap:
            raise BuildError("Linux bubblewrap is unavailable")
        toolchain_root = lake.parent.parent
        command = [bwrap, "--unshare-all", "--die-with-parent", "--new-session", "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp"]
        for root in ("/usr", "/bin", "/sbin", "/lib", "/lib64", "/etc"):
            if Path(root).exists():
                command.extend(["--ro-bind", root, root])
        for root in (repo, toolchain_root):
            command.extend(["--ro-bind", str(root), str(root)])
        command.extend(["--bind", str(work), str(work), "--chdir", str(repo / "control-plane" / "lean"), *argv])
        return command, "linux-bwrap-v1"
    raise BuildError("project-rule build isolation is unsupported on this OS")


def resource_limits() -> None:
    resource.setrlimit(resource.RLIMIT_CPU, (60, 60))
    resource.setrlimit(resource.RLIMIT_FSIZE, (MAX_ARTIFACT_BYTES, MAX_ARTIFACT_BYTES))
    resource.setrlimit(resource.RLIMIT_NOFILE, (64, 64))
    # Darwin accounts RLIMIT_NPROC against every process owned by the user,
    # not just this sandbox.  Lowering it below an already-running desktop
    # session makes Lean unable to create even its first worker thread.  Linux
    # runs inside a fresh bubblewrap PID namespace, where the bound is local
    # enough to be useful.
    if sys.platform.startswith("linux") and hasattr(resource, "RLIMIT_NPROC"):
        resource.setrlimit(resource.RLIMIT_NPROC, (64, 64))


def run_isolated(
    repo: Path,
    work: Path,
    lake: Path,
    args: Sequence[str],
    label: str,
) -> tuple[bytes, bytes, str, int]:
    argv, backend = sandbox_command(repo, work, lake, [str(lake), *args])
    stdout_path = work / f"{label}.stdout"
    stderr_path = work / f"{label}.stderr"
    env = {
        "HOME": str(work / "empty-home"),
        "TMPDIR": str(work / "tmp"),
        "PATH": "/usr/bin:/bin",
        "LANG": "C",
        "LC_ALL": "C",
        "TZ": "UTC",
    }
    started = time.monotonic_ns()
    with stdout_path.open("xb") as stdout, stderr_path.open("xb") as stderr:
        try:
            result = subprocess.run(
                argv,
                cwd=repo / "control-plane" / "lean",
                env=env,
                stdin=subprocess.DEVNULL,
                stdout=stdout,
                stderr=stderr,
                timeout=TIMEOUT_SECONDS,
                check=False,
                close_fds=True,
                preexec_fn=resource_limits if os.name == "posix" else None,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise BuildError(f"{label} could not complete: {exc}") from exc
    elapsed = time.monotonic_ns() - started
    out = read_regular(stdout_path, MAX_LOG_BYTES) if stdout_path.stat().st_size else b""
    err = read_regular(stderr_path, MAX_LOG_BYTES) if stderr_path.stat().st_size else b""
    if result.returncode != 0:
        raise BuildError(f"{label} failed with exit {result.returncode}: {err[-4000:].decode('utf-8', 'replace')}")
    return out, err, backend, elapsed


def write_checked(path: Path, value: bytes, mode: int = 0o600) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), mode)
    try:
        offset = 0
        while offset < len(value):
            wrote = os.write(fd, value[offset:])
            if wrote <= 0:
                raise BuildError(f"short write: {path}")
            offset += wrote
        os.fsync(fd)
    finally:
        os.close(fd)


def fsync_dir(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def build(args: argparse.Namespace) -> dict[str, Any]:
    repo = args.repo.resolve(strict=True)
    candidate_path = args.candidate.resolve(strict=True)
    # Canonicalize the existing parent before deriving the new destination.
    # macOS exposes /var as a symlink to /private/var; letting the spelling
    # drift between Seatbelt, Lean and rename would make a correctly confined
    # output fail (or make the policy describe a different path than the I/O).
    out = args.out.parent.resolve(strict=True) / args.out.name
    if not repo.is_dir() or not (repo / "control-plane" / "lean" / "lakefile.toml").is_file():
        raise BuildError("repository/control-plane Lean project is invalid")
    if not out.is_absolute() or out.exists() or not out.parent.is_dir() or out.parent.is_symlink():
        raise BuildError("output must be a new directory under an existing regular parent")
    parent_info = out.parent.stat()
    if parent_info.st_uid != os.getuid() or parent_info.st_mode & 0o022:
        raise BuildError("output parent must be owner-only and not group/world writable")
    lake = args.lake.resolve(strict=True)
    if not lake.is_file() or not os.access(lake, os.X_OK):
        raise BuildError("lake executable is invalid")
    raw = read_regular(candidate_path, MAX_CANDIDATE_BYTES)
    record, candidate_id, source, spec_json = validate_candidate(raw, args.candidate_id)

    staging = out.parent / f".{out.name}.staging-{os.getpid()}"
    staging.mkdir(mode=0o700)
    work = staging / "work"
    work.mkdir(mode=0o700)
    (work / "empty-home").mkdir(mode=0o700)
    (work / "tmp").mkdir(mode=0o700)
    source_path = work / "CandidateRule.lean"
    export_path = work / "CandidateExport.lean"
    audit_path = work / "CandidateAxiomAudit.lean"
    olean_path = work / "CandidateRule.olean"
    write_checked(source_path, lean_wrapper(source, "").encode("utf-8"))
    write_checked(export_path, lean_wrapper(source, "def main : IO Unit := IO.println (MetaCodesControl.ProjectRule.renderCanonical CandidateRule.spec)").encode("utf-8"))
    write_checked(audit_path, lean_wrapper(source, "#print axioms CandidateRule.spec_valid").encode("utf-8"))

    sdk_path = repo / "control-plane" / "lean" / "MetaCodesControl" / "ProjectRule.lean"
    sdk_olean_path = repo / "control-plane" / "lean" / ".lake" / "build" / "lib" / "MetaCodesControl" / "ProjectRule.olean"
    if not sdk_olean_path.is_file():
        raise BuildError("prebuilt project-rule SDK artifact is missing; run lake build first")
    lake_identity = sha256_file(lake)
    sdk_identity = sha256_file(sdk_path)
    sdk_olean_identity = sha256_file(sdk_olean_path)

    compile_out, compile_err, backend, compile_ns = run_isolated(
        repo, work, lake, ["env", "lean", f"--root={work}", "-o", str(olean_path), str(source_path)], "compile"
    )
    if compile_out or compile_err:
        raise BuildError("candidate compilation emitted unexpected diagnostics")
    export_out, export_err, export_backend, export_ns = run_isolated(
        repo, work, lake, ["env", "lean", f"--root={work}", "--run", str(export_path)], "export"
    )
    if export_backend != backend or export_err or export_out != spec_json + b"\n":
        raise BuildError("Lean-exported rule spec does not exactly match candidate rule_spec")
    audit_out, audit_err, audit_backend, audit_ns = run_isolated(
        repo, work, lake, ["env", "lean", f"--root={work}", str(audit_path)], "axiom"
    )
    expected_audit = b"'CandidateRule.spec_valid' does not depend on any axioms\n"
    if audit_backend != backend or audit_err or audit_out != expected_audit:
        raise BuildError("candidate axiom audit expanded the empty trust set")

    if sha256_file(lake) != lake_identity or sha256_file(sdk_path) != sdk_identity or sha256_file(sdk_olean_path) != sdk_olean_identity:
        raise BuildError("toolchain or project-rule SDK changed during candidate build")
    lake_sha, lake_bytes = lake_identity
    sdk_sha, sdk_bytes = sdk_identity
    sdk_olean_sha, sdk_olean_bytes = sdk_olean_identity
    olean_sha, olean_bytes = sha256_file(olean_path)
    files: dict[str, bytes] = {
        "candidate.json": raw,
        "rule-spec.json": spec_json,
        "candidate.olean": read_regular(olean_path, MAX_ARTIFACT_BYTES),
        "compile.stdout": compile_out,
        "compile.stderr": compile_err,
        "export.stdout": export_out,
        "export.stderr": export_err,
        "axiom.stdout": audit_out,
        "axiom.stderr": audit_err,
    }
    records = []
    for name, value in files.items():
        destination = staging / name
        write_checked(destination, value)
        records.append({"name": name, "bytes": len(value), "sha256": sha256_bytes(value)})
    manifest = {
        "schema_version": MANIFEST_SCHEMA,
        "candidate_id": candidate_id,
        "project_sha256": record["body"]["project_sha256"],
        "lean_source_sha256": sha256_bytes(source.encode("utf-8")),
        "rule_spec_sha256": sha256_bytes(spec_json),
        "compiled_artifact_sha256": olean_sha,
        "compiled_artifact_bytes": olean_bytes,
        "toolchain_sha256": lake_sha,
        "toolchain_bytes": lake_bytes,
        "sdk_sha256": sdk_sha,
        "sdk_bytes": sdk_bytes,
        "sdk_olean_sha256": sdk_olean_sha,
        "sdk_olean_bytes": sdk_olean_bytes,
        "axiom_policy": "empty",
        "forbidden_declaration_count": 0,
        "unexpected_axiom_count": 0,
        "network_disabled": True,
        "secrets_absent": True,
        "source_bounded": True,
        "output_bounded": True,
        "isolation_backend": backend,
        "compile_elapsed_ns": compile_ns,
        "export_elapsed_ns": export_ns,
        "axiom_elapsed_ns": audit_ns,
        "files": records,
        "completion_marker": True,
    }
    manifest_bytes = stable_json(manifest)
    write_checked(staging / "manifest.json", manifest_bytes)
    fsync_dir(staging)
    work_manifest = work / "manifest.json"
    write_checked(work_manifest, manifest_bytes)
    fsync_dir(work)
    # Work files are build scratch, not published evidence.
    shutil.rmtree(work)
    fsync_dir(staging)
    os.rename(staging, out)
    fsync_dir(out.parent)
    return {
        "candidate_id": candidate_id,
        "manifest_sha256": sha256_bytes(manifest_bytes),
        "compiled_artifact_sha256": olean_sha,
        "isolation_backend": backend,
    }


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    result.add_argument("--repo", type=Path, required=True)
    result.add_argument("--candidate", type=Path, required=True)
    result.add_argument("--candidate-id")
    result.add_argument("--out", type=Path, required=True)
    result.add_argument("--lake", type=Path, required=True)
    return result


def main() -> int:
    try:
        result = build(parser().parse_args())
    except (BuildError, OSError, ValueError) as exc:
        print(f"build-project-rule: {exc}", file=sys.stderr)
        return 1
    print(stable_json(result).decode("utf-8"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
