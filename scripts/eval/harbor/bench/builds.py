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

import contextlib
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

try:
    import fcntl
except ImportError:  # Windows: Bench executes trials on POSIX hosts only.
    fcntl = None

from scripts.eval.harbor.command import check_bundle
from scripts.eval.harbor.bench import releases

DEFAULT_REPO = "https://github.com/metask-ai/metacodes.git"
# A ref is passed to git as one argv element; the pattern also keeps it from
# reading as an option or a revision range.
REF = re.compile(r"^(?!.*\.\.)(?!.*@\{)[A-Za-z0-9][A-Za-z0-9._/-]{0,199}$")
COMMIT = re.compile(r"^[0-9a-f]{40}$")
# Bump when the rule deciding which commits may run with credentials changes:
# cached units checked under an older rule are re-verified before reuse.
TRUST_POLICY = 1
SOURCE_ID = re.compile(r"^[0-9a-f]{64}$")
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

# Step 1, trusted: install $ZIG_VERSION and $LEAN_TOOLCHAIN into $TOOLCHAINS.
# Zig is checked against ziglang.org's published SHA-256, elan against the pin
# above. Everything is staged on the toolchain cache's own filesystem and
# renamed into place, marked complete, only once whole: an install cancelled
# halfway leaves only a staging directory, which the next install removes.
TOOLCHAIN_SCRIPT = r"""
set -euo pipefail
root=${TOOLCHAINS:-/toolchains}
arch=$(uname -m)
mkdir -p "$root/zig" "$root/lean"
# The host serializes installs on this cache; flock also guards a direct run.
if command -v flock >/dev/null 2>&1; then exec 9>"$root/.install-lock" && flock 9; fi
# Installs are serialized, so any staging directory is an interrupted one.
rm -rf "$root"/.staging-*
tmp=$(mktemp -d "$root/.staging-XXXXXX")
zig_dir=$root/zig/$ZIG_VERSION
if [ ! -f "$zig_dir/.bench-complete" ]; then
  read -r url sum < <(curl -fsSL https://ziglang.org/download/index.json | python3 -c '
import json, sys
entry = json.load(sys.stdin)[sys.argv[1]][sys.argv[2] + "-linux"]
print(entry["tarball"], entry["shasum"])' "$ZIG_VERSION" "$arch")
  curl -fsSL "$url" -o "$tmp/zig.tar.xz"
  echo "$sum  $tmp/zig.tar.xz" | sha256sum -c -
  mkdir "$tmp/zig"
  tar -xJf "$tmp/zig.tar.xz" -C "$tmp/zig" --strip-components=1
  [ -x "$tmp/zig/zig" ]
  touch "$tmp/zig/.bench-complete"
  rm -rf "$zig_dir" && mv "$tmp/zig" "$zig_dir"
fi
lean_dir=$root/lean/$LEAN_DIR
if [ ! -f "$lean_dir/.bench-complete" ]; then
  case "$arch" in x86_64) sum=$ELAN_SHA256_X86_64 ;; aarch64) sum=$ELAN_SHA256_AARCH64 ;; *) exit 1 ;; esac
  curl -fsSL "https://github.com/leanprover/elan/releases/download/v$ELAN_VERSION/elan-$arch-unknown-linux-gnu.tar.gz" -o "$tmp/elan.tar.gz"
  echo "$sum  $tmp/elan.tar.gz" | sha256sum -c -
  tar -xzf "$tmp/elan.tar.gz" -C "$tmp"
  export ELAN_HOME=$tmp/elan
  "$tmp/elan-init" -y --no-modify-path --default-toolchain none >/dev/null
  "$ELAN_HOME/bin/elan" toolchain install "$LEAN_TOOLCHAIN"
  set -- "$ELAN_HOME"/toolchains/*/
  [ "$#" -eq 1 ] && [ -x "$1/bin/lake" ]
  touch "$1/.bench-complete"
  rm -rf "$lean_dir" && mv "$1" "$lean_dir"
fi
rm -rf "$tmp"
"""

# Step 2: the revision's build, as the caller's uid. The checkout and every
# writable cache live in a fresh temporary directory. The commit is fetched by
# id, with the tags that point at it ($TAGS): a stable version's release
# manifest requires HEAD to carry its version tag.
BUILD_SCRIPT = r"""
set -euo pipefail
work=$(mktemp -d)
export HOME=$work/home ZIG_GLOBAL_CACHE_DIR=$work/zig-cache
mkdir -p "$HOME"
git init -q "$work/src"
cd "$work/src"
refspecs=()
for tag in $TAGS; do refspecs+=("refs/tags/$tag:refs/tags/$tag"); done
git fetch -q --no-tags "$MIRROR" "$COMMIT" ${refspecs[@]+"${refspecs[@]}"}
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


PUBLIC = ("ref", "commit", "version", "target", "built_at")


def cached(cache_dir):
    """Builds already in the cache, most recent first: only what the page shows."""
    result = []
    for path in Path(cache_dir).glob("builds/metacodes-*"):
        info = build_info(path)
        if info:
            result.append({k: info[k] for k in PUBLIC})
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
    return {k: info.get(k) for k in PUBLIC + ("source_id", "trust_policy")}


def source_id(repo):
    """The repository's identity in a build record: a digest, never the URL,
    which may carry an access token."""
    return hashlib.sha256(repo.encode()).hexdigest()


def _redact(text, repo):
    """Git messages without the repository URL or any URL credentials."""
    return re.sub(r"(://)[^/@\s]+@", r"\1***@", text.replace(repo, "<source_repo>"))


def _trusted_for(info, commit, repo):
    """Whether a cached unit was verified for `commit` by this repository and rule."""
    return bool(info) and info["commit"] == commit and info["source_id"] == source_id(repo) \
        and info["trust_policy"] == TRUST_POLICY


@contextlib.contextmanager
def _locked(cache_dir, cancelled):
    """Serialize fetch, toolchain install, build and publish across processes.

    Several workbench services (one per jobs directory) can share one state
    root and so this cache. Waiting stays cancellable.
    """
    Path(cache_dir).mkdir(parents=True, exist_ok=True)
    with open(Path(cache_dir) / ".lock", "a+") as handle:
        if fcntl:
            while True:
                try:
                    fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if cancelled():
                        raise BuildError("构建已取消") from None
                    time.sleep(0.1)
        try:
            yield
        finally:
            if fcntl:
                fcntl.flock(handle, fcntl.LOCK_UN)


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
                raise BuildError("无法获取源码仓库：" + _redact((stderr.strip().splitlines() or ["?"])[-1], repo))
            # Builds fetch one resolved commit by id from this mirror.
            _git("config", "uploadpack.allowAnySHA1InWant", "true", cwd=staged)
            staged.rename(mirror)
        finally:
            shutil.rmtree(staged, ignore_errors=True)
    else:
        # Never verify against whatever origin was before: that result would be
        # recorded under this repository's name.
        if _git("remote", "set-url", "origin", repo, cwd=mirror)[0]:
            raise BuildError("无法把源码镜像切换到配置的仓库")
        code, stderr = _run(["git", "fetch", "-q", "--prune", "origin"], cancelled, cwd=mirror, quiet=True)
        if code:
            raise BuildError("无法更新源码仓库：" + _redact((stderr.strip().splitlines() or ["?"])[-1], repo))
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
    # The built binary runs with the execution machine's model credential, so
    # only commits the repository itself publishes, on a branch or a tag, are
    # built: not code that only a pull-request or other foreign ref names.
    _, trusted = _git("for-each-ref", "--count=1", "--contains", commit, "refs/heads", "refs/tags", cwd=mirror)
    if not trusted:
        raise BuildError(f"提交 {commit[:12]} 不在源码仓库的任何分支或 tag 上（例如外部 PR），"
                         "不会用执行机凭证运行它；请先推送到该仓库的分支")
    return mirror, commit


def tags_at(mirror, commit):
    """The tag names that point at `commit`, for its release manifest."""
    _, names = _git("tag", "--points-at", commit, cwd=mirror)
    return [name for name in names.split() if REF.fullmatch(name)]


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
    repo = repo or DEFAULT_REPO
    if COMMIT.fullmatch(ref):
        # A full commit id names one unit forever: no fetch when this
        # repository, under the current rule, already verified and built it.
        info = build_info(_destination(cache_dir, ref, target))
        if _trusted_for(info, ref, repo):
            return _destination(cache_dir, ref, target), info
    with _locked(cache_dir, cancelled):
        return _build(ref, cache_dir, repo, target, cancelled)


def _build(ref, cache_dir, repo, target, cancelled):
    mirror, commit = resolve(ref, cache_dir, repo, cancelled)
    destination = _destination(cache_dir, commit, target)
    info = build_info(destination)
    # A unit this builder made (its trust record has a rule version and a
    # source digest; records from before digests are not proof) is the commit's own
    # tree, whichever repository it was verified for; the commit has now been
    # verified against this one, so record that. A unit without that
    # provenance is rebuilt rather than trusted on its layout alone.
    if info and info["commit"] == commit and info["trust_policy"] is not None \
            and isinstance(info["source_id"], str) and SOURCE_ID.fullmatch(info["source_id"]):
        if not _trusted_for(info, commit, repo):
            info = {**info, "source_id": source_id(repo), "trust_policy": TRUST_POLICY}
            _info_path(destination).write_text(json.dumps(info), encoding="utf-8")
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
            "-e", "MIRROR=/mirror", "-e", "COMMIT=" + commit,
            "-e", "TAGS=" + " ".join(tags_at(mirror, commit))]
    try:
        if _run(argv + [image(), "bash", "-c", BUILD_SCRIPT + RELEASE_SCRIPT], cancelled, name=name)[0]:
            raise BuildError(f"git 版本 {ref}（{commit[:12]}）编译失败，详见执行日志")
        try:
            version = releases.bundle_version(check_bundle(out))
        except ValueError as exc:
            raise BuildError(f"git 版本 {ref} 的产物不能用于 Bench：{exc}") from None
        info = {"ref": ref, "commit": commit, "version": version, "target": target,
                "built_at": dt.datetime.now(dt.timezone.utc).isoformat(),
                "source_id": source_id(repo), "trust_policy": TRUST_POLICY}
        if destination.exists():
            shutil.rmtree(destination)
        out.rename(destination)
        _info_path(destination).write_text(json.dumps(info), encoding="utf-8")
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return destination, info
