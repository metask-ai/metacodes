"""Install the metacodes adapter into a pinned WorkBuddy-Bench checkout.

The Tencent checkout remains replaceable: all maintained source lives here,
and this installer performs two small deterministic registrations plus file
copies.  It refuses an unexpected checkout, upstream drift, or unrelated dirty
files instead of guessing how to merge them.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
import subprocess
from pathlib import Path
from typing import Dict, Iterable, List, Tuple

from . import WORKBUDDY_PINNED_COMMIT


class OverlayError(ValueError):
    pass


_ADAPTER_PATH = Path("src/workbuddy_bench/runner/harness_adapters.py")
_RESOLVER_PATH = Path("src/workbuddy_bench/runner/resolve_manifest.py")
_PREPARE_JOB_PATH = Path("src/workbuddy_bench/runner/prepare_job.py")
_AGENT_PATH = Path("src/workbuddy_bench/agents/metacodes_agent.py")
_TRACE_PATH = Path("src/workbuddy_bench/agents/_metacodes_trace.py")
_KEY_FD_PATH = Path("src/workbuddy_bench/proxy/_metacodes_key_fd.py")
_PROXY_CONFIG_PATH = Path("src/workbuddy_bench/proxy/config.py")
_ARTIFACT_PREFIX = "configs/harnesses/metacodes/docker/artifacts/"


_ADAPTER_ANCHOR = "HARNESS_ADAPTERS: dict[str, HarnessRuntimeAdapter] = {\n"
_ADAPTER_ENTRY = '''    "metacodes": HarnessRuntimeAdapter(
        harness_name="metacodes",
        canonical_display_name="metacodes",
        harness_protocol="anthropic",
        backend_base_env="ANTHROPIC_BASE_URL",
        backend_key_env="ANTHROPIC_API_KEY",
        proxy_url_env="",
        uses_anthropic_env=True,
    ),
'''


_DISPATCH_OLD = '''    if name in ("cc", "claude-code"):
        return _build_cc_runtime_config(**common)
    return _build_generic_runtime_config(**common)
'''
_DISPATCH_NEW = '''    if name in ("cc", "claude-code"):
        return _build_cc_runtime_config(**common)
    if name == "metacodes":
        return _build_metacodes_runtime_config(**common)
    return _build_generic_runtime_config(**common)
'''


_GENERIC_ANCHOR = "def _build_generic_runtime_config(\n"
_MODEL_ROUTE_OLD = '        model_route = f"{instance_id}__{model_slug}"\n'
_MODEL_ROUTE_NEW = '''        # Harbor uses ``__`` as the serialized eval-group delimiter and its
        # summary parser accepts only agent[__model]__dataset.  Embedding that
        # delimiter inside the opaque local-proxy route makes a fully completed
        # job crash while formatting its final table.  Route lookup is exact, so
        # use a delimiter that cannot be mistaken for Harbor group structure.
        model_route = f"{instance_id}--{model_slug}"
'''
_METACODES_RUNTIME_BUILDER = '''def _build_metacodes_runtime_config(
    *,
    harness: dict[str, Any],
    configs_dir: Path,
    harness_params: dict[str, Any],
    model_params: dict[str, Any],
    context_window: dict[str, Any],
    connection_mode: str,
    backend_url_env: str,
    backend_key_env: str,
    model_route: str,
    backend_model_name: str,
) -> dict[str, Any]:
    """Audit block mirroring MetacodesAgent's fail-closed runtime boundary."""
    del configs_dir
    env: dict[str, str] = {
        str(key): str(value) for key, value in (harness.get("env") or {}).items()
    }
    if connection_mode == "local_proxy":
        env.update({
            "METACODES_PROVIDER": "anthropic",
            "METACODES_BASE_URL": "<proxy_url>",
            "METACODES_API_KEY_FD": "<anonymous-fd:route-token>",
            "METACODES_MODEL": model_route,
        })
    else:
        env.update({
            "METACODES_PROVIDER": "anthropic",
            "METACODES_BASE_URL": f"${{{backend_url_env}}}" if backend_url_env else "",
            "METACODES_API_KEY_FD": "<anonymous-fd:redacted>",
            "METACODES_MODEL": backend_model_name,
        })
    env.update({
        "METACODES_KG_TRANSPORT": "cli-exclusive",
        "METACODES_KG_BIN": "/opt/metacodes/bin/tinykg",
        "METACODES_KG_STORE": "<fresh-home>/.local/share/tinykg/store",
        "METACODES_FORMAL_KERNEL_PATH": "/opt/metacodes/libexec/metacodes-formal-kernel",
        "METACODES_FORMAL_KERNEL_SHA256": "<verified-mount-sha256>",
    })
    project_rules = harness_params.get("METACODES_PROJECT_RULES_RELATIVE")
    project_kernel = harness_params.get("METACODES_PROJECT_KERNEL_RELATIVE")
    project_mode = harness_params.get("METACODES_PROJECT_CONTROL_MODE")
    project_staged = bool(project_rules and project_kernel)
    if project_staged and project_mode not in ("disabled", "enforced"):
        raise ValueError(
            "metacodes staged project control requires explicit disabled/enforced mode"
        )
    if not project_staged and project_mode is not None:
        raise ValueError("metacodes project control mode requires staged artifacts")
    if project_rules or project_kernel:
        env.update({
            "METACODES_PROJECT_RULES_SOURCE": (
                f"/opt/metacodes/{project_rules}" if project_rules else "<missing>"
            ),
            "METACODES_PROJECT_KERNEL_PATH": (
                f"/opt/metacodes/{project_kernel}" if project_kernel else "<missing>"
            ),
            "METACODES_PROJECT_KERNEL_SHA256": "<verified-mount-sha256>",
        })
    return {
        "harness": "metacodes",
        "connection_policy": "local-proxy-only",
        "credential_delivery": "anonymous-fd-route-token",
        "disabled_tools": harness_params.get("METACODES_DISALLOWED_TOOLS"),
        "project_control_staged": project_staged,
        "project_control_mode": project_mode if project_staged else "absent",
        "project_control_configured": project_staged and project_mode == "enforced",
        "transport_model_is_route": connection_mode == "local_proxy",
        "actor_model_identity": backend_model_name,
        "translated_env": {key: value for key, value in env.items() if value},
        "cleared_env": [
            "TINYKG_REMOTE_URL",
            "TINYKG_API_KEY",
            "TINYKG_REMOTE_EXPECTED_BUILD_ID",
            "TINYKG_REMOTE_CONFIG",
            "METACODES_KG_CONFIG",
            "METACODES_KG_URL",
            "METACODES_KG_API_KEY",
            "METACODES_KG_EXPECTED_BUILD_ID",
            "METACODES_KG_EXPECTED_SCHEMA_DIGEST",
            "METASK_API_KEY",
        ],
        "context_window_request": context_window,
        "context_window_actuation": "metacodes-native-model-catalog",
        "model_params": model_params,
        "backend_key_env": backend_key_env,
    }


'''


_PROXY_IMPORT_ANCHOR = "import yaml\n"
_PROXY_IMPORT = (
    "\nfrom workbuddy_bench.proxy._metacodes_key_fd import resolve_secret_env\n"
)
_PROXY_KEY_OLD = '        key = _resolve_env(backend_raw.get("key", ""), backend_raw.get("key_env", ""))\n'
_PROXY_KEY_NEW = '        key = resolve_secret_env(backend_raw.get("key", ""), backend_raw.get("key_env", ""))\n'


_RESOLVER_MOUNT_OLD = '''    dataset_runtime = load_dataset_runtime_contract(dataset, repo_root=_repo_root())
    dataset_requires_mount = dataset_runtime.requires_split_mount_for(harness_name)
    backend_for_mount = "local"
'''
_RESOLVER_MOUNT_NEW = '''    dataset_runtime = load_dataset_runtime_contract(dataset, repo_root=_repo_root())
    # Official v1 datasets predate metacodes and therefore enumerate only the
    # original split-mount harnesses.  The metacodes harness itself declares a
    # pinned mount and is never baked into task images, so treat that declaration
    # as the authoritative delivery requirement instead of silently omitting it.
    metacodes_declares_mount = (
        harness_name == "metacodes" and isinstance(harness.get("mount"), dict)
    )
    dataset_requires_mount = (
        dataset_runtime.requires_split_mount_for(harness_name)
        or metacodes_declares_mount
    )
    backend_for_mount = "local"
'''


_PREPARE_MOUNT_OLD = '''    harness_name = harness.get("name", "")
    dataset_requires_mount = dataset_runtime.requires_split_mount_for(str(harness_name))
    harness_mount = harness.get("mount")
    if dataset_requires_mount:
'''
_PREPARE_MOUNT_NEW = '''    harness_name = harness.get("name", "")
    metacodes_declares_mount = (
        harness_name == "metacodes" and isinstance(harness.get("mount"), dict)
    )
    dataset_requires_mount = (
        dataset_runtime.requires_split_mount_for(str(harness_name))
        or metacodes_declares_mount
    )
    manifest_mount = (manifest or {}).get("harness_mount")
    if isinstance(manifest_mount, dict):
        if manifest_mount.get("required") is not dataset_requires_mount:
            raise ValueError(
                f"{job_path}: resolved harness-mount requirement drifted before prepare_job"
            )
    harness_mount = harness.get("mount")
    if dataset_requires_mount:
'''

_PREPARE_AGENT_IDENTITY_OLD = '''    kwargs: dict[str, Any] = dict(harness_params)
    if model_params:
        kwargs["model_params"] = model_params
'''
_PREPARE_AGENT_IDENTITY_NEW = '''    kwargs: dict[str, Any] = dict(harness_params)
    if harness.get("name") == "metacodes":
        backend_model_name = str(
            (manifest or {}).get("backend_model_name") or model.get("name") or ""
        )
        if not backend_model_name:
            raise ValueError("metacodes requires a stable backend model identity")
        kwargs["METACODES_MODEL_DISPLAY_NAME"] = backend_model_name
    if model_params:
        kwargs["model_params"] = model_params
'''


def _run(repo: Path, *args: str) -> str:
    try:
        return subprocess.run(
            ["git", "-C", str(repo), *args],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError) as exc:
        raise OverlayError(f"git {' '.join(args)} failed: {exc}") from exc


def _head_file(repo: Path, relative: Path) -> bytes:
    try:
        return subprocess.run(
            ["git", "-C", str(repo), "show", f"HEAD:{relative.as_posix()}"],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        ).stdout
    except (OSError, subprocess.CalledProcessError) as exc:
        raise OverlayError(f"cannot read pinned upstream {relative}: {exc}") from exc


def _patched_upstream(repo: Path) -> Dict[Path, bytes]:
    adapter = _head_file(repo, _ADAPTER_PATH).decode("utf-8")
    if adapter.count(_ADAPTER_ANCHOR) != 1:
        raise OverlayError("WorkBuddy harness adapter registry anchor drifted")
    if '"metacodes": HarnessRuntimeAdapter(' in adapter:
        raise OverlayError("pinned WorkBuddy already contains a metacodes adapter")
    adapter = adapter.replace(_ADAPTER_ANCHOR, _ADAPTER_ANCHOR + _ADAPTER_ENTRY, 1)

    resolver = _head_file(repo, _RESOLVER_PATH).decode("utf-8")
    if resolver.count(_DISPATCH_OLD) != 1:
        raise OverlayError("WorkBuddy runtime-config dispatch anchor drifted")
    if resolver.count(_GENERIC_ANCHOR) != 1:
        raise OverlayError("WorkBuddy generic runtime-config anchor drifted")
    resolver = resolver.replace(_DISPATCH_OLD, _DISPATCH_NEW, 1)
    resolver = resolver.replace(
        _GENERIC_ANCHOR, _METACODES_RUNTIME_BUILDER + _GENERIC_ANCHOR, 1
    )
    if resolver.count(_MODEL_ROUTE_OLD) != 1:
        raise OverlayError("WorkBuddy local-proxy route anchor drifted")
    resolver = resolver.replace(_MODEL_ROUTE_OLD, _MODEL_ROUTE_NEW, 1)
    if resolver.count(_RESOLVER_MOUNT_OLD) != 1:
        raise OverlayError("WorkBuddy resolver mount-requirement anchor drifted")
    resolver = resolver.replace(_RESOLVER_MOUNT_OLD, _RESOLVER_MOUNT_NEW, 1)

    prepare_job = _head_file(repo, _PREPARE_JOB_PATH).decode("utf-8")
    if prepare_job.count(_PREPARE_AGENT_IDENTITY_OLD) != 1:
        raise OverlayError("WorkBuddy prepare_job model-identity anchor drifted")
    prepare_job = prepare_job.replace(
        _PREPARE_AGENT_IDENTITY_OLD,
        _PREPARE_AGENT_IDENTITY_NEW,
        1,
    )
    if prepare_job.count(_PREPARE_MOUNT_OLD) != 1:
        raise OverlayError("WorkBuddy prepare_job mount-requirement anchor drifted")
    prepare_job = prepare_job.replace(_PREPARE_MOUNT_OLD, _PREPARE_MOUNT_NEW, 1)

    proxy_config = _head_file(repo, _PROXY_CONFIG_PATH).decode("utf-8")
    if proxy_config.count(_PROXY_IMPORT_ANCHOR) != 1:
        raise OverlayError("WorkBuddy proxy import anchor drifted")
    if proxy_config.count(_PROXY_KEY_OLD) != 1:
        raise OverlayError("WorkBuddy proxy credential resolver anchor drifted")
    proxy_config = proxy_config.replace(
        _PROXY_IMPORT_ANCHOR,
        _PROXY_IMPORT_ANCHOR + _PROXY_IMPORT,
        1,
    ).replace(_PROXY_KEY_OLD, _PROXY_KEY_NEW, 1)
    return {
        _ADAPTER_PATH: adapter.encode("utf-8"),
        _RESOLVER_PATH: resolver.encode("utf-8"),
        _PREPARE_JOB_PATH: prepare_job.encode("utf-8"),
        _PROXY_CONFIG_PATH: proxy_config.encode("utf-8"),
    }


def _overlay_sources() -> List[Tuple[Path, bytes]]:
    root = Path(__file__).resolve().parent
    overlay = root / "overlay"
    rows: List[Tuple[Path, bytes]] = [
        (_TRACE_PATH, (root / "trace.py").read_bytes()),
        (_KEY_FD_PATH, (root / "key_fd.py").read_bytes()),
    ]
    for source in sorted(overlay.rglob("*")):
        if source.is_file():
            rows.append((source.relative_to(overlay), source.read_bytes()))
    return rows


def _digest(rows: Iterable[Tuple[Path, bytes]], patched: Dict[Path, bytes]) -> str:
    digest = hashlib.sha256()
    all_rows = list(rows) + sorted(patched.items(), key=lambda item: item[0].as_posix())
    for relative, content in sorted(all_rows, key=lambda item: item[0].as_posix()):
        name = relative.as_posix().encode("utf-8")
        digest.update(len(name).to_bytes(4, "big"))
        digest.update(name)
        digest.update(len(content).to_bytes(8, "big"))
        digest.update(content)
    return digest.hexdigest()


def _dirty_paths(repo: Path) -> List[str]:
    changed = _run(repo, "diff", "--name-only", "HEAD").splitlines()
    untracked = _run(repo, "ls-files", "--others", "--exclude-standard").splitlines()
    return sorted(set(changed + untracked))


def _allowed_dirty(path: str, owned: set[Path], manifest_path: Path) -> bool:
    return (
        Path(path) in owned
        or path == manifest_path.as_posix()
        or path.startswith(_ARTIFACT_PREFIX)
    )


def _write_expected(target: Path, content: bytes, *, replace_owned: bool = False) -> None:
    if target.exists():
        if target.is_symlink() or not target.is_file():
            raise OverlayError(f"overlay target is not a regular file: {target}")
        if target.read_bytes() == content:
            return
        if not replace_owned:
            raise OverlayError(f"overlay target contains conflicting content: {target}")
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_name(target.name + ".metacodes-overlay.tmp")
    if temporary.exists():
        raise OverlayError(f"stale overlay temporary file: {temporary}")
    with temporary.open("xb") as handle:
        handle.write(content)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, target)


def _read_single_link_regular(path: Path, *, maximum: int = 32 * 1024 * 1024) -> bytes:
    try:
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    except OSError as exc:
        raise OverlayError(f"cannot open overlay file {path}: {exc}") from exc
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise OverlayError(f"overlay file is not a single-link regular file: {path}")
        if before.st_size > maximum:
            raise OverlayError(f"overlay file size is outside the safety bound: {path}")
        chunks: List[bytes] = []
        observed = 0
        while True:
            chunk = os.read(descriptor, min(1024 * 1024, maximum + 1 - observed))
            if not chunk:
                break
            chunks.append(chunk)
            observed += len(chunk)
            if observed > maximum:
                raise OverlayError(f"overlay file exceeds the safety bound: {path}")
        after = os.fstat(descriptor)
        identity = (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
        if identity != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
            raise OverlayError(f"overlay file changed while hashing: {path}")
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def validate_installed_overlay(
    repo: Path,
    manifest_path: Path = Path("configs/harnesses/metacodes/OVERLAY.json"),
) -> Dict[str, object]:
    """Validate every installed overlay byte against its aggregate manifest.

    The aggregate v1 digest covers every installed file except the generated
    manifest itself.  Paid launch creation and re-observation share this exact
    verifier with upgrades so the installer and execution gate cannot drift.
    """
    checkout = repo.resolve(strict=True)
    if manifest_path.is_absolute() or ".." in manifest_path.parts:
        raise OverlayError("overlay manifest path escapes checkout")
    target = checkout / manifest_path

    def unique(pairs: List[Tuple[str, object]]) -> Dict[str, object]:
        result: Dict[str, object] = {}
        for key, value in pairs:
            if key in result:
                raise OverlayError(f"duplicate overlay manifest field: {key}")
            result[key] = value
        return result

    try:
        previous = json.loads(
            _read_single_link_regular(target).decode("utf-8"),
            object_pairs_hook=unique,
        )
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise OverlayError(f"overlay manifest is invalid: {exc}") from exc
    if not isinstance(previous, dict):
        raise OverlayError("overlay manifest is not an object")
    if (
        previous.get("schema_version") != "metacodes-workbuddy-overlay-v1"
        or previous.get("workbuddy_commit") != WORKBUDDY_PINNED_COMMIT
        or previous.get("quality_evidence") is not False
    ):
        raise OverlayError("overlay manifest has an unrelated identity")
    overlay_sha = previous.get("overlay_sha256")
    if (
        not isinstance(overlay_sha, str)
        or len(overlay_sha) != 64
        or any(character not in "0123456789abcdef" for character in overlay_sha)
    ):
        raise OverlayError("overlay manifest has an invalid aggregate digest")
    raw_paths = previous.get("installed_paths")
    if (
        not isinstance(raw_paths, list)
        or not raw_paths
        or any(not isinstance(raw, str) for raw in raw_paths)
        or len(raw_paths) != len(set(raw_paths))
        or raw_paths != sorted(raw_paths)
    ):
        raise OverlayError("overlay manifest has invalid or duplicate installed paths")
    rows: List[Tuple[Path, bytes]] = []
    for raw in raw_paths:
        relative = Path(raw)
        if relative.is_absolute() or not relative.parts or ".." in relative.parts:
            raise OverlayError(f"overlay manifest path escapes checkout: {raw}")
        installed = checkout / relative
        try:
            installed.resolve(strict=True).relative_to(checkout)
        except (OSError, ValueError) as exc:
            raise OverlayError(f"overlay path is missing or escapes checkout: {raw}") from exc
        rows.append((relative, _read_single_link_regular(installed)))
    if _digest(rows, {}) != overlay_sha:
        raise OverlayError("installed overlay files changed after installation")
    return previous


def _verified_previous_overlay(repo: Path, manifest_path: Path) -> set[Path]:
    """Return paths owned by an intact prior overlay, or fail closed."""
    target = repo / manifest_path
    if not target.exists() and not target.is_symlink():
        return set()
    previous = validate_installed_overlay(repo, manifest_path)
    return {Path(raw) for raw in previous["installed_paths"]}


def _write_generated_manifest(target: Path, content: bytes) -> None:
    if target.exists():
        if target.is_symlink() or not target.is_file():
            raise OverlayError(f"overlay manifest is not a regular file: {target}")
        if target.read_bytes() == content:
            return
        try:
            previous = json.loads(target.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise OverlayError(f"existing overlay manifest is invalid: {exc}") from exc
        if (
            previous.get("schema_version") != "metacodes-workbuddy-overlay-v1"
            or previous.get("workbuddy_commit") != WORKBUDDY_PINNED_COMMIT
        ):
            raise OverlayError("existing overlay manifest has an unrelated identity")
    else:
        target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_name(target.name + ".metacodes-overlay.tmp")
    if temporary.exists():
        raise OverlayError(f"stale overlay temporary file: {temporary}")
    with temporary.open("xb") as handle:
        handle.write(content)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, target)


def install(repo: Path) -> Dict[str, object]:
    repo = repo.resolve()
    head = _run(repo, "rev-parse", "HEAD").strip()
    if head != WORKBUDDY_PINNED_COMMIT:
        raise OverlayError(
            f"WorkBuddy checkout is {head}, expected {WORKBUDDY_PINNED_COMMIT}"
        )
    origin = _run(repo, "remote", "get-url", "origin").strip().lower()
    if "tencent/workbuddy-bench" not in origin:
        raise OverlayError(f"unexpected WorkBuddy origin: {origin}")

    manifest_path = Path("configs/harnesses/metacodes/OVERLAY.json")
    previous_owned = _verified_previous_overlay(repo, manifest_path)
    patched = _patched_upstream(repo)
    sources = _overlay_sources()
    next_owned = {path for path, _ in sources} | set(patched)
    allowed_owned = previous_owned | next_owned
    unrelated = [
        path
        for path in _dirty_paths(repo)
        if not _allowed_dirty(path, allowed_owned, manifest_path)
    ]
    if unrelated:
        raise OverlayError(f"checkout has unrelated dirty paths: {unrelated}")
    stale_owned = previous_owned - next_owned
    if stale_owned:
        raise OverlayError(
            "overlay upgrade would leave stale owned paths: "
            f"{sorted(path.as_posix() for path in stale_owned)}"
        )
    overlay_sha = _digest(sources, patched)
    manifest = {
        "schema_version": "metacodes-workbuddy-overlay-v1",
        "workbuddy_commit": WORKBUDDY_PINNED_COMMIT,
        "overlay_sha256": overlay_sha,
        "quality_evidence": False,
        "installed_paths": sorted(
            [path.as_posix() for path, _ in sources]
            + [path.as_posix() for path in patched]
        ),
    }
    manifest_bytes = (
        json.dumps(manifest, sort_keys=True, indent=2) + "\n"
    ).encode("utf-8")

    for relative, expected in patched.items():
        target = repo / relative
        current = target.read_bytes()
        base = _head_file(repo, relative)
        if current not in (base, expected) and relative not in previous_owned:
            raise OverlayError(f"upstream patch target was modified independently: {relative}")
        if current != expected:
            temporary = target.with_name(target.name + ".metacodes-overlay.tmp")
            with temporary.open("xb") as handle:
                handle.write(expected)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, target)
    for relative, content in sources:
        _write_expected(
            repo / relative,
            content,
            replace_owned=relative in previous_owned,
        )
    _write_generated_manifest(repo / manifest_path, manifest_bytes)
    return manifest


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("workbuddy_checkout", type=Path)
    args = parser.parse_args(argv)
    try:
        manifest = install(args.workbuddy_checkout)
    except (OSError, OverlayError) as exc:
        parser.error(str(exc))
    print(json.dumps(manifest, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
