"""Prebuild and bind WorkBuddy task environments before paid authorization.

The official Harbor runner always invokes ``docker compose build``.  This
preflight warms the content-addressed BuildKit cache and records the exact
environment inputs and resulting linux/amd64 image IDs.  The paid launch gate
re-observes this receipt before it persists ``request_authorized``.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import shutil
import stat
import subprocess
import time
from pathlib import Path
from typing import Any, Dict, Sequence

from ..model import stable_json
from . import WORKBUDDY_PINNED_COMMIT
from .stage_artifacts import TARGET_PLATFORM


SCHEMA_VERSION = "metacodes-workbuddy-environment-preflight-v1"
TASK_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{1,191}$")
DEFAULT_HARNESS_IMAGE = "workbuddy-bench/harness/metacodes:0.1.0"


class EnvironmentPreflightError(ValueError):
    pass


def _sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _canonical_sha256(value: object) -> str:
    return _sha256_bytes(stable_json(value).encode("utf-8"))


def _read_regular(path: Path, maximum: int = 2 * 1024 * 1024 * 1024) -> bytes:
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise EnvironmentPreflightError(
                f"environment input is not a single-link regular file: {path}"
            )
        if before.st_size > maximum:
            raise EnvironmentPreflightError(f"environment input is too large: {path}")
        chunks: list[bytes] = []
        observed = 0
        while True:
            chunk = os.read(descriptor, min(1024 * 1024, maximum + 1 - observed))
            if not chunk:
                break
            chunks.append(chunk)
            observed += len(chunk)
            if observed > maximum:
                raise EnvironmentPreflightError(f"environment input is too large: {path}")
        after = os.fstat(descriptor)
        identity = (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
        if identity != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
            raise EnvironmentPreflightError(f"environment input changed while hashing: {path}")
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def _tree_identity(root: Path) -> Dict[str, object]:
    root = root.resolve(strict=True)
    if not root.is_dir():
        raise EnvironmentPreflightError(f"environment path is not a directory: {root}")
    rows: list[Dict[str, object]] = []
    for current, directories, files in os.walk(root, followlinks=False):
        current_path = Path(current)
        for name in sorted([*directories, *files]):
            path = current_path / name
            relative = path.relative_to(root).as_posix()
            info = path.lstat()
            if stat.S_ISLNK(info.st_mode):
                raise EnvironmentPreflightError(
                    f"environment context contains a symlink: {path}"
                )
            if stat.S_ISDIR(info.st_mode):
                rows.append(
                    {"path": relative + "/", "mode": stat.S_IMODE(info.st_mode)}
                )
                continue
            if not stat.S_ISREG(info.st_mode):
                raise EnvironmentPreflightError(
                    f"environment context contains a special file: {path}"
                )
            payload = _read_regular(path)
            rows.append(
                {
                    "path": relative,
                    "mode": stat.S_IMODE(info.st_mode),
                    "bytes": len(payload),
                    "sha256": _sha256_bytes(payload),
                }
            )
    if not rows or not (root / "Dockerfile").is_file():
        raise EnvironmentPreflightError(
            f"environment context has no regular Dockerfile: {root}"
        )
    return {
        "path": str(root),
        "entries": len(rows),
        "content_sha256": _canonical_sha256(rows),
    }


def _private_new_parent(path: Path) -> Path:
    parent = path.parent.resolve(strict=True)
    info = parent.stat()
    if (
        not stat.S_ISDIR(info.st_mode)
        or stat.S_IMODE(info.st_mode) & 0o022
        or (hasattr(os, "geteuid") and info.st_uid != os.geteuid())
    ):
        raise EnvironmentPreflightError(
            "environment preflight receipt parent must be private and owned"
        )
    if path.exists() or path.is_symlink():
        raise EnvironmentPreflightError(
            f"refusing to overwrite environment preflight receipt: {path}"
        )
    if (parent / (path.name + ".tmp")).exists() or (parent / (path.name + ".tmp")).is_symlink():
        raise EnvironmentPreflightError(
            f"incomplete environment preflight receipt requires review: {path}.tmp"
        )
    return parent


def _write_private_new(path: Path, payload: bytes) -> None:
    parent = _private_new_parent(path)
    temporary = parent / (path.name + ".tmp")
    descriptor = os.open(
        temporary,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        0o600,
    )
    try:
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            if written <= 0:
                raise EnvironmentPreflightError("short environment receipt write")
            offset += written
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    os.replace(temporary, parent / path.name)
    parent_descriptor = os.open(parent, os.O_RDONLY)
    try:
        os.fsync(parent_descriptor)
    finally:
        os.close(parent_descriptor)


def _run(
    argv: Sequence[str], *, cwd: Path | None = None, timeout: int = 1800
) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            list(argv),
            cwd=cwd,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
        stderr = getattr(exc, "stderr", "") or ""
        stdout = getattr(exc, "stdout", "") or ""
        raise EnvironmentPreflightError(
            f"environment preflight command failed: {' '.join(argv)}: "
            f"{(stdout + stderr)[-4000:]}"
        ) from exc


def _docker_inspect(docker: Path, image: str) -> Dict[str, str]:
    completed = _run(
        [str(docker), "image", "inspect", image, "--format", "{{json .}}"],
        timeout=30,
    )
    try:
        row = json.loads(completed.stdout)
        result = {
            "image_id": row["Id"],
            "architecture": row["Architecture"],
            "os": row["Os"],
        }
    except (json.JSONDecodeError, KeyError, TypeError) as exc:
        raise EnvironmentPreflightError(f"invalid docker inspect result for {image}") from exc
    if result["architecture"] != "amd64" or result["os"] != "linux":
        raise EnvironmentPreflightError(
            f"prebuilt image {image} is {result['os']}/{result['architecture']}, "
            f"expected {TARGET_PLATFORM}"
        )
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", result["image_id"]):
        raise EnvironmentPreflightError(f"prebuilt image {image} has invalid image ID")
    return result


def _resolve_dataset(workbuddy: Path, dataset: str) -> Path:
    if not dataset or Path(dataset).is_absolute() or ".." in Path(dataset).parts:
        raise EnvironmentPreflightError("dataset must be a relative WorkBuddy path")
    checkout = workbuddy.resolve(strict=True)
    path = (checkout / dataset).resolve(strict=True)
    try:
        path.relative_to(checkout)
    except ValueError as exc:
        raise EnvironmentPreflightError("dataset escapes the WorkBuddy checkout") from exc
    return path


def prebuild(
    *,
    workbuddy: Path,
    dataset: str,
    selected_tasks: Sequence[str],
    output: Path,
    docker: Path,
    harness_image: str = DEFAULT_HARNESS_IMAGE,
) -> Dict[str, object]:
    _private_new_parent(output)
    checkout = workbuddy.resolve(strict=True)
    if _run(["git", "-C", str(checkout), "rev-parse", "HEAD"], timeout=30).stdout.strip() != WORKBUDDY_PINNED_COMMIT:
        raise EnvironmentPreflightError("WorkBuddy checkout commit mismatch")
    if not selected_tasks or len(selected_tasks) != len(set(selected_tasks)):
        raise EnvironmentPreflightError("selected task list is empty or duplicated")
    if any(not TASK_RE.fullmatch(task) for task in selected_tasks):
        raise EnvironmentPreflightError("selected task name is unsafe")
    docker_path = docker.resolve(strict=True)
    if not os.access(docker_path, os.X_OK):
        raise EnvironmentPreflightError("docker executable is not executable")
    dataset_path = _resolve_dataset(checkout, dataset)
    started = time.monotonic()
    harness_context = checkout / "configs/harnesses/metacodes/docker"
    harness_identity = _tree_identity(harness_context)
    _run(
        [
            str(docker_path),
            "buildx",
            "build",
            "--platform",
            TARGET_PLATFORM,
            "--load",
            "--tag",
            harness_image,
            str(harness_context),
        ],
        cwd=checkout,
    )
    if _tree_identity(harness_context) != harness_identity:
        raise EnvironmentPreflightError(
            "WorkBuddy harness context changed during environment preflight"
        )
    harness_mount = {
        "context": harness_identity,
        "image_tag": harness_image,
        **_docker_inspect(docker_path, harness_image),
    }
    rows: Dict[str, object] = {}
    for task in selected_tasks:
        environment = dataset_path / task / "environment"
        identity = _tree_identity(environment)
        tag = "metacodes-workbuddy-preflight:" + str(identity["content_sha256"])[:24]
        _run(
            [
                str(docker_path),
                "buildx",
                "build",
                "--platform",
                TARGET_PLATFORM,
                "--load",
                "--tag",
                tag,
                str(environment),
            ],
            cwd=checkout,
        )
        if _tree_identity(environment) != identity:
            raise EnvironmentPreflightError(
                f"WorkBuddy environment changed during preflight build: {task}"
            )
        image = _docker_inspect(docker_path, tag)
        rows[task] = {"environment": identity, "image_tag": tag, **image}
    docker_version = _run([str(docker_path), "version", "--format", "{{json .Client}}"], timeout=30)
    docker_payload = _read_regular(docker_path, maximum=256 * 1024 * 1024)
    receipt: Dict[str, object] = {
        "schema_version": SCHEMA_VERSION,
        "quality_evidence": False,
        "workbuddy_commit": WORKBUDDY_PINNED_COMMIT,
        "workbuddy_checkout": str(checkout),
        "dataset": dataset,
        "selected_tasks": list(selected_tasks),
        "target_platform": TARGET_PLATFORM,
        "docker": {
            "path": str(docker_path),
            "bytes": len(docker_payload),
            "sha256": _sha256_bytes(docker_payload),
            "client_sha256": _sha256_bytes(docker_version.stdout.encode("utf-8")),
        },
        "harness_mount": harness_mount,
        "tasks": rows,
        "elapsed_seconds": time.monotonic() - started,
    }
    receipt["content_sha256"] = _canonical_sha256(receipt)
    _write_private_new(
        output,
        (json.dumps(receipt, sort_keys=True, indent=2) + "\n").encode("utf-8"),
    )
    return receipt


def validate_receipt(
    path: Path,
    *,
    workbuddy: Path,
    dataset: str,
    selected_tasks: Sequence[str],
    inspect_images: bool,
) -> Dict[str, Any]:
    def unique(pairs: list[tuple[str, Any]]) -> Dict[str, Any]:
        result: Dict[str, Any] = {}
        for key, item in pairs:
            if key in result:
                raise EnvironmentPreflightError(
                    f"duplicate environment preflight field: {key}"
                )
            result[key] = item
        return result

    try:
        value = json.loads(
            _read_regular(path, maximum=16 * 1024 * 1024),
            object_pairs_hook=unique,
        )
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise EnvironmentPreflightError(f"invalid environment preflight receipt: {exc}") from exc
    if not isinstance(value, dict):
        raise EnvironmentPreflightError("environment preflight receipt is not an object")
    content_sha = value.pop("content_sha256", None)
    if content_sha != _canonical_sha256(value):
        raise EnvironmentPreflightError("environment preflight receipt hash mismatch")
    value["content_sha256"] = content_sha
    checkout = workbuddy.resolve(strict=True)
    expected_tasks = list(selected_tasks)
    if (
        value.get("schema_version") != SCHEMA_VERSION
        or value.get("quality_evidence") is not False
        or value.get("workbuddy_commit") != WORKBUDDY_PINNED_COMMIT
        or value.get("workbuddy_checkout") != str(checkout)
        or value.get("dataset") != dataset
        or value.get("selected_tasks") != expected_tasks
        or value.get("target_platform") != TARGET_PLATFORM
        or set(value.get("tasks") or {}) != set(expected_tasks)
    ):
        raise EnvironmentPreflightError("environment preflight receipt contract mismatch")
    dataset_path = _resolve_dataset(checkout, dataset)
    docker_row = value.get("docker") or {}
    if (
        not isinstance(docker_row, dict)
        or not isinstance(docker_row.get("path"), str)
        or not Path(docker_row["path"]).is_absolute()
        or not isinstance(docker_row.get("bytes"), int)
        or docker_row["bytes"] <= 0
        or not re.fullmatch(r"[0-9a-f]{64}", str(docker_row.get("sha256", "")))
        or not re.fullmatch(r"[0-9a-f]{64}", str(docker_row.get("client_sha256", "")))
        or not isinstance(value.get("elapsed_seconds"), (int, float))
        or isinstance(value.get("elapsed_seconds"), bool)
        or not math.isfinite(value["elapsed_seconds"])
        or value["elapsed_seconds"] < 0
    ):
        raise EnvironmentPreflightError("environment preflight runtime metadata is invalid")
    docker = Path(docker_row["path"])
    if inspect_images:
        docker_payload = _read_regular(docker, maximum=256 * 1024 * 1024)
        if (
            len(docker_payload) != docker_row["bytes"]
            or _sha256_bytes(docker_payload) != docker_row["sha256"]
        ):
            raise EnvironmentPreflightError("docker client changed after environment preflight")
        version = _run(
            [str(docker), "version", "--format", "{{json .Client}}"], timeout=30
        )
        if _sha256_bytes(version.stdout.encode("utf-8")) != docker_row["client_sha256"]:
            raise EnvironmentPreflightError("docker client changed after environment preflight")
    tasks = value.get("tasks")
    if not isinstance(tasks, dict):
        raise EnvironmentPreflightError("environment preflight task map is invalid")
    harness = value.get("harness_mount") or {}
    if (
        not isinstance(harness, dict)
        or not isinstance(harness.get("image_tag"), str)
        or harness.get("context")
        != _tree_identity(checkout / "configs/harnesses/metacodes/docker")
    ):
        raise EnvironmentPreflightError("WorkBuddy harness mount changed after preflight")
    if inspect_images:
        image = _docker_inspect(docker, harness["image_tag"])
        if any(image[key] != harness.get(key) for key in image):
            raise EnvironmentPreflightError(
                "WorkBuddy harness mount image changed after preflight"
            )
    for task in expected_tasks:
        row = value["tasks"][task]
        if (
            not isinstance(row, dict)
            or not isinstance(row.get("image_tag"), str)
            or not row["image_tag"].startswith("metacodes-workbuddy-preflight:")
        ):
            raise EnvironmentPreflightError(
                f"WorkBuddy preflight image metadata is invalid: {task}"
            )
        observed = _tree_identity(dataset_path / task / "environment")
        if row.get("environment") != observed:
            raise EnvironmentPreflightError(
                f"WorkBuddy environment changed after preflight: {task}"
            )
        if inspect_images:
            image = _docker_inspect(docker, row.get("image_tag", ""))
            if any(image[key] != row.get(key) for key in image):
                raise EnvironmentPreflightError(
                    f"WorkBuddy preflight image changed after build: {task}"
                )
    return value


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workbuddy-checkout", type=Path, required=True)
    parser.add_argument("--dataset", required=True)
    parser.add_argument("--task", action="append", required=True, dest="tasks")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--harness-image", default=DEFAULT_HARNESS_IMAGE)
    parser.add_argument(
        "--docker",
        type=Path,
        default=Path(shutil.which("docker") or "docker"),
    )
    args = parser.parse_args(argv)
    try:
        receipt = prebuild(
            workbuddy=args.workbuddy_checkout,
            dataset=args.dataset,
            selected_tasks=args.tasks,
            output=args.output,
            docker=args.docker,
            harness_image=args.harness_image,
        )
    except (EnvironmentPreflightError, OSError, ValueError) as exc:
        parser.error(str(exc))
    print(
        json.dumps(
            {
                "tasks": len(receipt["selected_tasks"]),
                "target_platform": receipt["target_platform"],
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
