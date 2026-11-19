"""metacodes built from any git revision as Bench bundles.

A launch may name a git ref (commit, branch or tag) instead of a bundle or a
release. The worker resolves it to a commit in a local mirror of the source
repository and, the first time that commit is used, builds its Linux release
unit the way release.yml does (Lean kernels, their pins, release:verify).
Harbor task containers are Linux, and the Lean kernels only build natively,
so the build runs in a Docker container of the execution machine's
architecture. Units are cached per commit and reused by later launches.
"""
from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
import re
import shutil
import subprocess
import time
import uuid
from pathlib import Path

from scripts.eval.harbor.command import check_bundle
from scripts.eval.harbor.viewer import releases

DEFAULT_REPO = "https://github.com/metask-ai/metacodes.git"
# A ref is passed to git as one argv element; the pattern also keeps it from
# reading as an option or a revision range.
REF = re.compile(r"^(?!.*\.\.)(?!.*@\{)[A-Za-z0-9][A-Za-z0-9._/-]{0,199}$")

DOCKERFILE = """\
FROM debian:bookworm-slim
RUN apt-get update \\
 && apt-get install -y --no-install-recommends bash ca-certificates curl git python3 xz-utils \\
 && rm -rf /var/lib/apt/lists/*
"""

# Runs in the builder as the caller's uid. Zig follows the checkout's own
# minimum_zig_version (checked against ziglang.org's published SHA-256) and
# elan comes from the checkout's pinned installer, so an older revision builds
# with the toolchain it was written for. Both are cached in /toolchains.
BUILD_SCRIPT = r"""
set -euo pipefail
git clone -q --no-local --no-checkout /mirror /src
cd /src
git checkout -q --detach "$COMMIT"
version=$(sed -n 's/.*minimum_zig_version *= *"\([^"]*\)".*/\1/p' build.zig.zon)
arch=$(uname -m)
zig_dir=/toolchains/zig/$version
if [ ! -x "$zig_dir/zig" ]; then
  read -r url sum < <(curl -fsSL https://ziglang.org/download/index.json | python3 -c '
import json, sys
entry = json.load(sys.stdin)[sys.argv[1]][sys.argv[2] + "-linux"]
print(entry["tarball"], entry["shasum"])' "$version" "$arch")
  curl -fsSL "$url" -o /tmp/zig.tar.xz
  echo "$sum  /tmp/zig.tar.xz" | sha256sum -c -
  rm -rf "$zig_dir.tmp" && mkdir -p "$zig_dir.tmp"
  tar -xJf /tmp/zig.tar.xz -C "$zig_dir.tmp" --strip-components=1
  mv "$zig_dir.tmp" "$zig_dir"
fi
export PATH="$zig_dir:$ELAN_HOME/bin:$PATH"
bash scripts/ci/install-elan.sh
zig build kernels:stage -Dlean-kernels=on -Doptimize=ReleaseSafe --prefix /out
pins=$(python3 scripts/kernel_pins.py /out)
# $pins is two -D options; it is split on purpose.
zig build release:verify -Drelease-layout=true -Doptimize=ReleaseSafe --prefix /out $pins -Dtarget="$arch-linux-gnu.2.31"
"""


class BuildError(ValueError):
    """The requested revision cannot be built into a Bench bundle."""


def check_ref(ref):
    if not isinstance(ref, str) or not REF.fullmatch(ref):
        raise BuildError("git 版本应为提交、分支或 tag 名，例如 main 或 54a7a632")
    return ref


def image():
    return "metacodes-bench-builder:" + hashlib.sha256(DOCKERFILE.encode()).hexdigest()[:12]


def cached(cache_dir):
    """Builds already in the cache, most recent first."""
    result = []
    for path in Path(cache_dir).glob("builds/metacodes-*"):
        info = build_info(path)
        if info:
            result.append(info)
    return sorted(result, key=lambda i: i.get("built_at", ""), reverse=True)


def _info_path(unit):
    # Beside the unit, not inside it: the unit stays exactly what release:verify checked.
    return unit.parent / (unit.name + ".json")


def build_info(path):
    try:
        check_bundle(path)
        info = json.loads(_info_path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(info, dict):
        return None
    return {k: info.get(k) for k in ("ref", "commit", "version", "target", "built_at")}


def _git(*args, cwd=None):
    result = subprocess.run(["git", *args], cwd=cwd, stdin=subprocess.DEVNULL,
                            capture_output=True, text=True)
    if result.returncode:
        raise BuildError("git " + args[0] + " 失败：" + (result.stderr.strip().splitlines() or ["?"])[-1])
    return result.stdout.strip()


def resolve(ref, cache_dir, repo=None):
    """Fetch the source mirror and return the full commit `ref` names."""
    check_ref(ref)
    mirror = Path(cache_dir) / "source.git"
    repo = repo or DEFAULT_REPO
    if not (mirror / "HEAD").is_file():
        Path(cache_dir).mkdir(parents=True, exist_ok=True)
        staged = Path(cache_dir) / (".source-" + uuid.uuid4().hex)
        _git("clone", "-q", "--mirror", repo, str(staged))
        staged.rename(mirror)
    else:
        _git("remote", "set-url", "origin", repo, cwd=mirror)
        _git("fetch", "-q", "--prune", "origin", cwd=mirror)
    try:
        return mirror, _git("rev-parse", "--verify", "-q", ref + "^{commit}", cwd=mirror)
    except BuildError:
        raise BuildError("源码仓库中找不到 git 版本 " + ref) from None


def _docker(*args):
    return subprocess.run(["docker", *args], stdin=subprocess.DEVNULL,
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode


def _run(argv, cancelled, name=None, input_text=None):
    process = subprocess.Popen(argv, stdin=subprocess.PIPE if input_text is not None else subprocess.DEVNULL)
    if input_text is not None:
        process.stdin.write(input_text.encode())
        process.stdin.close()
    while process.poll() is None:
        if cancelled():
            if name:
                _docker("kill", name)
            process.terminate()
            process.wait()
            raise BuildError("构建已取消")
        time.sleep(0.25)
    return process.returncode


def bundle(ref, cache_dir, repo=None, target=None, cancelled=lambda: False):
    """The Linux unit built from `ref`, and its build record."""
    target = target or releases.linux_target()
    cache_dir = Path(cache_dir)
    mirror, commit = resolve(ref, cache_dir, repo)
    destination = cache_dir / "builds" / ("metacodes-" + commit[:12] + "-" + target)
    info = build_info(destination)
    if info and info["commit"] == commit:
        return destination, info
    if cancelled():
        raise BuildError("构建已取消")
    if shutil.which("docker") is None:
        raise BuildError("构建 git 版本需要执行机器上的 Docker")
    print(f"bench: building metacodes {ref} ({commit[:12]}) for {target}", flush=True)
    if _docker("image", "inspect", image()):
        if _run(["docker", "build", "-q", "-t", image(), "-"], cancelled, input_text=DOCKERFILE):
            raise BuildError("无法构建编译镜像 " + image())
    toolchains = cache_dir / "toolchains"
    toolchains.mkdir(parents=True, exist_ok=True)
    work = destination.parent / (".build-" + uuid.uuid4().hex)
    out = work / "unit"
    out.mkdir(parents=True)
    name = "metacodes-bench-build-" + uuid.uuid4().hex[:12]
    argv = ["docker", "run", "--rm", "--name", name,
            "-v", f"{mirror.resolve()}:/mirror:ro", "-v", f"{out.resolve()}:/out",
            "-v", f"{toolchains.resolve()}:/toolchains",
            "-e", "COMMIT=" + commit, "-e", "HOME=/toolchains/home",
            "-e", "ELAN_HOME=/toolchains/elan", "-e", "ZIG_GLOBAL_CACHE_DIR=/toolchains/zig-cache"]
    if hasattr(os, "getuid"):
        argv += ["--user", f"{os.getuid()}:{os.getgid()}"]
    try:
        if _run(argv + [image(), "bash", "-c", BUILD_SCRIPT], cancelled, name=name):
            raise BuildError(f"git 版本 {ref}（{commit[:12]}）编译失败，详见执行日志")
        try:
            version = releases.bundle_version(check_bundle(out))
        except ValueError as exc:
            raise BuildError(f"git 版本 {ref} 的产物不能用于 Bench：{exc}") from None
        info = {"ref": ref, "commit": commit, "version": version, "target": target,
                "built_at": dt.datetime.now(dt.timezone.utc).isoformat()}
        if destination.exists():
            shutil.rmtree(destination)
        out.rename(destination)
        _info_path(destination).write_text(json.dumps(info), encoding="utf-8")
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return destination, info
