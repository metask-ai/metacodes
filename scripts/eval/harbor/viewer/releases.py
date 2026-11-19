"""Published metacodes releases as Bench bundles.

A launch may name a release version instead of using the configured bundle.
The worker downloads that release's Linux archive once, checks it against
the release's SHA256SUMS, and keeps the unpacked unit in a per-version cache.
"""
from __future__ import annotations

import hashlib
import os
import platform
import re
import shutil
import tarfile
import tempfile
import urllib.request
import uuid
from pathlib import Path

from scripts.eval.harbor.command import check_bundle

VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$")
DEFAULT_BASE = "https://github.com/metask-ai/metacodes/releases"
TARGETS = {"x86_64": "x86_64-linux-gnu", "amd64": "x86_64-linux-gnu",
           "aarch64": "aarch64-linux-gnu", "arm64": "aarch64-linux-gnu"}


class ReleaseError(ValueError):
    """The requested release cannot be used as a Bench bundle."""


def check_version(version):
    if not isinstance(version, str) or not VERSION.fullmatch(version):
        raise ReleaseError("metacodes 版本格式应为 X.Y.Z，例如 0.12.0")
    return version


def bundle_version(manifest):
    release = manifest.get("release") if isinstance(manifest, dict) else None
    value = release.get("version") if isinstance(release, dict) else None
    return value if isinstance(value, str) else None


def linux_target(machine=None):
    """Task containers share the Docker host's architecture."""
    machine = (machine or platform.machine()).lower()
    if machine not in TARGETS:
        raise ReleaseError("执行机器架构 " + machine + " 没有 Linux 发行包")
    return TARGETS[machine]


def cached(cache_dir):
    """Versions already unpacked in the cache, newest name first."""
    result = []
    for path in sorted(Path(cache_dir).glob("metacodes-*"), reverse=True):
        try:
            version = bundle_version(check_bundle(path))
        except ValueError:
            continue
        if version:
            result.append(version)
    return list(dict.fromkeys(result))


def _fetch(url, path):
    with urllib.request.urlopen(url, timeout=60) as response, open(path, "wb") as output:
        shutil.copyfileobj(response, output, 1 << 20)


def _sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _extract(archive, destination):
    """Unpack regular files and directories only, all inside destination."""
    root = Path(destination).resolve()
    with tarfile.open(archive, "r:gz") as tar:
        members = tar.getmembers()
        for member in members:
            target = (root / member.name).resolve()
            if not (member.isfile() or member.isdir()) or (target != root and root not in target.parents):
                raise ReleaseError("发行包含有不安全的路径：" + member.name)
        for member in members:
            target = root / member.name
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with tar.extractfile(member) as source, open(target, "wb") as output:
                shutil.copyfileobj(source, output, 1 << 20)
            os.chmod(target, member.mode & 0o755)


def _unit_root(path):
    if (path / "manifest.json").is_file():
        return path
    for candidate in sorted(path.iterdir()):
        if (candidate / "manifest.json").is_file():
            return candidate
    raise ReleaseError("发行包中没有 manifest.json")


def bundle(version, cache_dir, base=None, target=None):
    """The unpacked Linux unit for `version`, downloading it on first use."""
    version = check_version(version)
    target = target or linux_target()
    base = (base or os.environ.get("METACODES_RELEASE_BASE") or DEFAULT_BASE).rstrip("/")
    cache_dir = Path(cache_dir)
    destination = cache_dir / ("metacodes-" + version + "-" + target)
    try:
        if bundle_version(check_bundle(destination)) == version:
            return destination
    except ValueError:
        pass
    cache_dir.mkdir(parents=True, exist_ok=True)
    name = "metacodes-" + version + "-" + target + ".tar.gz"
    with tempfile.TemporaryDirectory(dir=cache_dir, prefix=".download-") as work:
        work = Path(work)
        try:
            _fetch(f"{base}/download/{version}/metacodes-{version}-SHA256SUMS", work / "SHA256SUMS")
            sums = (work / "SHA256SUMS").read_text(encoding="utf-8").splitlines()
            expected = next((line.split()[0] for line in sums
                             if len(line.split()) == 2 and line.split()[1].lstrip("*") == name), None)
            if not expected:
                raise ReleaseError("版本 " + version + " 没有 " + target + " 发行包")
            _fetch(f"{base}/download/{version}/{name}", work / name)
        except OSError as exc:
            raise ReleaseError("无法下载 metacodes " + version + "：" + str(exc)) from None
        if _sha256(work / name) != expected:
            raise ReleaseError(name + " 的 SHA-256 与 SHA256SUMS 不一致")
        _extract(work / name, work / "unpacked")
        unit = _unit_root(work / "unpacked")
        try:
            found = bundle_version(check_bundle(unit))
        except ValueError as exc:
            raise ReleaseError("metacodes " + version + " 不能用于 Bench：" + str(exc)) from None
        if found != version:
            raise ReleaseError(f"发行包版本是 {found}，不是 {version}")
        staged = cache_dir / (".staged-" + uuid.uuid4().hex)
        unit.rename(staged)
        if destination.exists():
            shutil.rmtree(destination)
        staged.rename(destination)
    return destination
