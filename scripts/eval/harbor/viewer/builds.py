"""metacodes built from any git revision as Bench bundles.

A launch may name a git ref (commit, branch or tag) instead of a bundle or a
release. The worker resolves it to a commit in a local mirror of the source
repository and, the first time that commit is used, builds its Linux release
unit the way release.yml does (Lean kernels, their pins, release:verify).
Harbor task containers are Linux, and the Lean kernels only build natively,
so the build runs in a Docker container of the execution machine's
architecture. Units are cached per commit and reused by later launches.

A build has two container steps. The first runs only this module's script:
it installs the Zig and Lean versions the revision names (as data) into the
shared toolchain cache and checks their digests. The second runs the
revision's own build with those toolchains mounted read-only and every
writable cache private to that build, so one revision cannot change the
compiler another revision is built with.
"""
from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import tempfile
import time
import uuid
from pathlib import Path

from scripts.eval.harbor.command import check_bundle
from scripts.eval.harbor.viewer import releases

DEFAULT_REPO = "https://github.com/metask-ai/metacodes.git"
# A ref is passed to git as one argv element; the pattern also keeps it from
# reading as an option or a revision range.
REF = re.compile(r"^(?!.*\.\.)(?!.*@\{)[A-Za-z0-9][A-Za-z0-9._/-]{0,199}$")
COMMIT = re.compile(r"^[0-9a-f]{40}$")
ZIG_VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
LEAN_TOOLCHAIN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/:+-]{0,99}$")

DOCKERFILE = """\
FROM debian:bookworm-slim
RUN apt-get update \\
 && apt-get install -y --no-install-recommends bash ca-certificates curl git python3 xz-utils \\
 && rm -rf /var/lib/apt/lists/*
"""

# The pinned elan of scripts/ci/install-elan.sh, kept here so that the
# toolchain step never runs a script from the revision being built.
ELAN_VERSION = "4.2.4"
ELAN_SHA256 = {
    "x86_64": "42b94d4244e8353142c456ec0e4ca6528fd898a6c604d4059f494e706e431f63",
    "aarch64": "05febd124d84ebf994b2e7479922a5650b1e950c17ae3bd1ddd776b65bb72bf9",
}

# Step 1, trusted: install $ZIG_VERSION and $LEAN_TOOLCHAIN into /toolchains.
# Zig is checked against ziglang.org's published SHA-256, elan against the pin
# above. Each toolchain is staged and renamed into place only when complete.
TOOLCHAIN_SCRIPT = r"""
set -euo pipefail
arch=$(uname -m)
tmp=$(mktemp -d)
zig_dir=/toolchains/zig/$ZIG_VERSION
if [ ! -x "$zig_dir/zig" ]; then
  read -r url sum < <(curl -fsSL https://ziglang.org/download/index.json | python3 -c '
import json, sys
entry = json.load(sys.stdin)[sys.argv[1]][sys.argv[2] + "-linux"]
print(entry["tarball"], entry["shasum"])' "$ZIG_VERSION" "$arch")
  curl -fsSL "$url" -o "$tmp/zig.tar.xz"
  echo "$sum  $tmp/zig.tar.xz" | sha256sum -c -
  mkdir -p "$tmp/zig" /toolchains/zig
  tar -xJf "$tmp/zig.tar.xz" -C "$tmp/zig" --strip-components=1
  rm -rf "$zig_dir" && mv "$tmp/zig" "$zig_dir"
fi
lean_dir=/toolchains/lean/$LEAN_DIR
if [ ! -x "$lean_dir/bin/lake" ]; then
  case "$arch" in x86_64) sum=$ELAN_SHA256_X86_64 ;; aarch64) sum=$ELAN_SHA256_AARCH64 ;; *) exit 1 ;; esac
  curl -fsSL "https://github.com/leanprover/elan/releases/download/v$ELAN_VERSION/elan-$arch-unknown-linux-gnu.tar.gz" -o "$tmp/elan.tar.gz"
  echo "$sum  $tmp/elan.tar.gz" | sha256sum -c -
  tar -xzf "$tmp/elan.tar.gz" -C "$tmp"
  export ELAN_HOME=$tmp/elan
  "$tmp/elan-init" -y --no-modify-path --default-toolchain none >/dev/null
  "$ELAN_HOME/bin/elan" toolchain install "$LEAN_TOOLCHAIN"
  set -- "$ELAN_HOME"/toolchains/*/
  [ "$#" -eq 1 ] && [ -x "$1/bin/lake" ]
  mkdir -p /toolchains/lean
  rm -rf "$lean_dir" && mv "$1" "$lean_dir"
fi
rm -rf "$tmp"
"""

# Step 2: the revision's build, as the caller's uid. The checkout and every
# writable cache live in a fresh temporary directory; the commit is fetched
# by id, so a commit only a custom or pull-request ref names is found too.
BUILD_SCRIPT = r"""
set -euo pipefail
work=$(mktemp -d)
export HOME=$work/home ZIG_GLOBAL_CACHE_DIR=$work/zig-cache
mkdir -p "$HOME"
git init -q "$work/src"
cd "$work/src"
git fetch -q --no-tags "$MIRROR" "$COMMIT"
git checkout -q --detach "$COMMIT"
"""

RELEASE_SCRIPT = r"""
export PATH="/opt/zig:/opt/lean/bin:$PATH"
arch=$(uname -m)
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


def _destination(cache_dir, commit, target):
    return Path(cache_dir) / "builds" / ("metacodes-" + commit[:12] + "-" + target)


def _run(argv, cancelled, name=None, input_text=None, cwd=None, quiet=False):
    """Run argv to completion; a cancel stops it (and its container) promptly.

    Returns the exit status and, when quiet, the captured stderr.
    """
    with tempfile.TemporaryFile() as errors:
        process = subprocess.Popen(argv, cwd=cwd, stdin=subprocess.PIPE if input_text is not None else subprocess.DEVNULL,
                                   stdout=subprocess.DEVNULL if quiet else None,
                                   stderr=errors if quiet else None, start_new_session=True)
        if input_text is not None:
            process.stdin.write(input_text.encode())
            process.stdin.close()
        while process.poll() is None:
            if cancelled():
                if name:
                    _docker("kill", name)
                # The whole group: git's transport helpers too.
                if hasattr(os, "killpg"):
                    os.killpg(process.pid, signal.SIGKILL)
                else:
                    process.kill()
                process.wait()
                raise BuildError("构建已取消")
            time.sleep(0.1)
        errors.seek(0)
        return process.returncode, errors.read().decode(errors="replace")


def _git(*args, cwd=None):
    result = subprocess.run(["git", *args], cwd=cwd, stdin=subprocess.DEVNULL,
                            capture_output=True, text=True)
    return result.returncode, result.stdout.strip()


def _commit(mirror, name):
    code, commit = _git("rev-parse", "--verify", "-q", name + "^{commit}", cwd=mirror)
    return commit if code == 0 and COMMIT.fullmatch(commit) else None


def resolve(ref, cache_dir, repo=None, cancelled=lambda: False):
    """Fetch the source mirror and return it with the full commit `ref` names."""
    check_ref(ref)
    mirror = Path(cache_dir) / "source.git"
    repo = repo or DEFAULT_REPO
    if not (mirror / "HEAD").is_file():
        Path(cache_dir).mkdir(parents=True, exist_ok=True)
        staged = Path(cache_dir) / (".source-" + uuid.uuid4().hex)
        try:
            code, stderr = _run(["git", "clone", "-q", "--mirror", repo, str(staged)], cancelled, quiet=True)
            if code:
                raise BuildError("无法获取源码仓库：" + (stderr.strip().splitlines() or ["?"])[-1])
            # Builds fetch one resolved commit by id from this mirror.
            _git("config", "uploadpack.allowAnySHA1InWant", "true", cwd=staged)
            staged.rename(mirror)
        finally:
            shutil.rmtree(staged, ignore_errors=True)
    else:
        _git("remote", "set-url", "origin", repo, cwd=mirror)
        code, stderr = _run(["git", "fetch", "-q", "--prune", "origin"], cancelled, cwd=mirror, quiet=True)
        if code:
            raise BuildError("无法更新源码仓库：" + (stderr.strip().splitlines() or ["?"])[-1])
    if ref.startswith("refs/"):
        commit = _commit(mirror, ref)
    else:
        # A branch and a tag of the same name: git would quietly pick the tag.
        named = {_commit(mirror, "refs/heads/" + ref), _commit(mirror, "refs/tags/" + ref)} - {None}
        if len(named) > 1:
            raise BuildError(f"{ref} 同时是分支和 tag 且指向不同提交，请写 refs/heads/{ref} 或 refs/tags/{ref}")
        commit = named.pop() if named else _commit(mirror, ref)
    if not commit:
        raise BuildError("源码仓库中找不到 git 版本 " + ref)
    return mirror, commit


def _docker(*args):
    return subprocess.run(["docker", *args], stdin=subprocess.DEVNULL,
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode


def toolchain_versions(mirror, commit):
    """The Zig and Lean versions a revision names, read as data from the mirror."""
    _, zon = _git("show", commit + ":build.zig.zon", cwd=mirror)
    match = re.search(r'minimum_zig_version\s*=\s*"([^"]*)"', zon)
    _, lean = _git("show", commit + ":control-plane/lean/lean-toolchain", cwd=mirror)
    zig, lean = match.group(1) if match else "", lean.strip()
    if not ZIG_VERSION.fullmatch(zig) or not LEAN_TOOLCHAIN.fullmatch(lean):
        raise BuildError(f"提交 {commit[:12]} 没有可识别的 Zig / Lean 版本，不能按发布布局编译")
    return zig, lean


def bundle(ref, cache_dir, repo=None, target=None, cancelled=lambda: False):
    """The Linux unit built from `ref`, and its build record."""
    target = target or releases.linux_target()
    cache_dir = Path(cache_dir)
    if COMMIT.fullmatch(ref):
        # A full commit id names one unit forever: no fetch when it is cached.
        info = build_info(_destination(cache_dir, ref, target))
        if info and info["commit"] == ref:
            return _destination(cache_dir, ref, target), info
    mirror, commit = resolve(ref, cache_dir, repo, cancelled)
    destination = _destination(cache_dir, commit, target)
    info = build_info(destination)
    if info and info["commit"] == commit:
        return destination, info
    if cancelled():
        raise BuildError("构建已取消")
    if shutil.which("docker") is None:
        raise BuildError("构建 git 版本需要执行机器上的 Docker")
    zig, lean = toolchain_versions(mirror, commit)
    lean_dir = re.sub(r"[^A-Za-z0-9._-]", "-", lean)
    print(f"bench: building metacodes {ref} ({commit[:12]}) for {target} with Zig {zig}, {lean}", flush=True)
    if _docker("image", "inspect", image()):
        if _run(["docker", "build", "-q", "-t", image(), "-"], cancelled, input_text=DOCKERFILE)[0]:
            raise BuildError("无法构建编译镜像 " + image())
    toolchains = (cache_dir / "toolchains").resolve()
    toolchains.mkdir(parents=True, exist_ok=True)
    user = ["--user", f"{os.getuid()}:{os.getgid()}"] if hasattr(os, "getuid") else []
    name = "metacodes-bench-toolchain-" + uuid.uuid4().hex[:12]
    argv = ["docker", "run", "--rm", "--name", name, *user, "-v", f"{toolchains}:/toolchains",
            "-e", "ZIG_VERSION=" + zig, "-e", "LEAN_TOOLCHAIN=" + lean, "-e", "LEAN_DIR=" + lean_dir,
            "-e", "ELAN_VERSION=" + ELAN_VERSION, "-e", "ELAN_SHA256_X86_64=" + ELAN_SHA256["x86_64"],
            "-e", "ELAN_SHA256_AARCH64=" + ELAN_SHA256["aarch64"]]
    if _run(argv + [image(), "bash", "-c", TOOLCHAIN_SCRIPT], cancelled, name=name)[0]:
        raise BuildError(f"无法安装 Zig {zig} / {lean}，详见执行日志")
    work = destination.parent / (".build-" + uuid.uuid4().hex)
    out = work / "unit"
    out.mkdir(parents=True)
    name = "metacodes-bench-build-" + uuid.uuid4().hex[:12]
    argv = ["docker", "run", "--rm", "--name", name, *user,
            "-v", f"{mirror.resolve()}:/mirror:ro", "-v", f"{out.resolve()}:/out",
            "-v", f"{toolchains / 'zig' / zig}:/opt/zig:ro",
            "-v", f"{toolchains / 'lean' / lean_dir}:/opt/lean:ro",
            "-e", "MIRROR=/mirror", "-e", "COMMIT=" + commit]
    try:
        if _run(argv + [image(), "bash", "-c", BUILD_SCRIPT + RELEASE_SCRIPT], cancelled, name=name)[0]:
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
