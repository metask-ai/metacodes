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
import subprocess
from pathlib import Path
from typing import Dict, Iterable, List, Tuple

from . import WORKBUDDY_PINNED_COMMIT


class OverlayError(ValueError):
    pass


_ADAPTER_PATH = Path("src/workbuddy_bench/runner/harness_adapters.py")
_RESOLVER_PATH = Path("src/workbuddy_bench/runner/resolve_manifest.py")
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
        "METACODES_KG_BIN": "/opt/metacodes/bin/tinykg",
        "METACODES_KG_STORE": "<fresh-home>/.local/share/tinykg/store",
        "METACODES_FORMAL_KERNEL_PATH": "/opt/metacodes/libexec/metacodes-formal-kernel",
        "METACODES_FORMAL_KERNEL_SHA256": "<verified-mount-sha256>",
    })
    return {
        "harness": "metacodes",
        "connection_policy": "local-proxy-only",
        "credential_delivery": "anonymous-fd-route-token",
        "disabled_tools": harness_params.get("METACODES_DISALLOWED_TOOLS"),
        "translated_env": {key: value for key, value in env.items() if value},
        "cleared_env": [
            "TINYKG_REMOTE_URL",
            "TINYKG_API_KEY",
            "TINYKG_REMOTE_EXPECTED_BUILD_ID",
            "TINYKG_REMOTE_CONFIG",
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


def _verified_previous_overlay(repo: Path, manifest_path: Path) -> set[Path]:
    """Return paths owned by an intact prior overlay, or fail closed.

    The aggregate v1 digest covers every installed file except the generated
    manifest itself.  Recomputing it before replacement makes an overlay
    upgrade possible without treating unrelated edits as ours.
    """
    target = repo / manifest_path
    if not target.exists():
        return set()
    if target.is_symlink() or not target.is_file():
        raise OverlayError(f"overlay manifest is not a regular file: {target}")
    try:
        previous = json.loads(target.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise OverlayError(f"existing overlay manifest is invalid: {exc}") from exc
    if (
        previous.get("schema_version") != "metacodes-workbuddy-overlay-v1"
        or previous.get("workbuddy_commit") != WORKBUDDY_PINNED_COMMIT
    ):
        raise OverlayError("existing overlay manifest has an unrelated identity")
    raw_paths = previous.get("installed_paths")
    if not isinstance(raw_paths, list) or not raw_paths:
        raise OverlayError("existing overlay manifest has no installed paths")
    owned: set[Path] = set()
    rows: List[Tuple[Path, bytes]] = []
    for raw in raw_paths:
        if not isinstance(raw, str):
            raise OverlayError("existing overlay manifest has an invalid path")
        relative = Path(raw)
        if relative.is_absolute() or ".." in relative.parts:
            raise OverlayError(f"existing overlay manifest path escapes checkout: {raw}")
        installed = repo / relative
        if installed.is_symlink() or not installed.is_file():
            raise OverlayError(f"prior overlay path is missing or unsafe: {installed}")
        owned.add(relative)
        rows.append((relative, installed.read_bytes()))
    if _digest(rows, {}) != previous.get("overlay_sha256"):
        raise OverlayError("prior overlay files changed after installation")
    return owned


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
