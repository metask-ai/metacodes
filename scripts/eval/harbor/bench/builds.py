"""Linux bundles built from any git revision of metacodes.

`metacodes bench build --ref <ref>` resolves the ref in a mirror of the
source repository and builds that commit's x86_64 Linux release unit in
Docker, then publishes it under `<state>/bench/bundles/`, where a batch can
choose and freeze it like any other bundle.
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
except ImportError:
    fcntl = None

from scripts.eval.harbor.command import check_bundle

DEFAULT_REPO = "https://github.com/metask-ai/metacodes.git"
TARGET = "x86_64-linux-gnu"
PLATFORM = "linux/amd64"
REF = re.compile(r"^(?!.*\.\.)(?!.*@\{)[A-Za-z0-9][A-Za-z0-9._/-]{0,199}$")
COMMIT = re.compile(r"^[0-9a-f]{40}$")
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

ELAN_VERSION = "4.2.4"
ELAN_SHA256 = "42b94d4244e8353142c456ec0e4ca6528fd898a6c604d4059f494e706e431f63"

TOOLCHAIN_SCRIPT = r"""
set -euo pipefail
root=${TOOLCHAINS:-/toolchains}
fetch() { curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors "$@"; }
mkdir -p "$root/zig" "$root/lean"
if command -v flock >/dev/null 2>&1; then exec 9>"$root/.install-lock" && flock 9; fi
rm -rf "$root"/.staging-*
tmp=$(mktemp -d "$root/.staging-XXXXXX")
zig_dir=$root/zig/$ZIG_VERSION
if [ ! -f "$zig_dir/.bench-complete" ]; then
  read -r url sum < <(fetch https://ziglang.org/download/index.json | python3 -c '
import json, sys
entry = json.load(sys.stdin)[sys.argv[1]]["x86_64-linux"]
print(entry["tarball"], entry["shasum"])' "$ZIG_VERSION")
  fetch "$url" -o "$tmp/zig.tar.xz"
  echo "$sum  $tmp/zig.tar.xz" | sha256sum -c -
  mkdir "$tmp/zig"
  tar -xJf "$tmp/zig.tar.xz" -C "$tmp/zig" --strip-components=1
  [ -x "$tmp/zig/zig" ]
  touch "$tmp/zig/.bench-complete"
  rm -rf "$zig_dir" && mv "$tmp/zig" "$zig_dir"
fi
lean_dir=$root/lean/$LEAN_DIR
if [ ! -f "$lean_dir/.bench-complete" ]; then
  fetch "https://github.com/leanprover/elan/releases/download/v$ELAN_VERSION/elan-x86_64-unknown-linux-gnu.tar.gz" -o "$tmp/elan.tar.gz"
  echo "$ELAN_SHA256  $tmp/elan.tar.gz" | sha256sum -c -
  tar -xzf "$tmp/elan.tar.gz" -C "$tmp"
  export ELAN_HOME=$tmp/elan
  "$tmp/elan-init" -y --no-modify-path --default-toolchain none >/dev/null
  for attempt in 1 2 3 4 5; do
    "$ELAN_HOME/bin/elan" toolchain install "$LEAN_TOOLCHAIN" && break
    [ "$attempt" -lt 5 ] || exit 1
    sleep 5
  done
  set -- "$ELAN_HOME"/toolchains/*/
  [ "$#" -eq 1 ] && [ -x "$1/bin/lake" ]
  touch "$1/.bench-complete"
  rm -rf "$lean_dir" && mv "$1" "$lean_dir"
fi
rm -rf "$tmp"
"""

CHECKOUT_SCRIPT = r"""
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
zig build kernels:stage -Dlean-kernels=on -Doptimize=ReleaseSafe --prefix /out
pins=$(python3 scripts/kernel_pins.py /out)
zig build release:verify -Drelease-layout=true -Doptimize=ReleaseSafe --prefix /out $pins -Dtarget=x86_64-linux-gnu.2.31
"""


class BuildError(ValueError):
    pass


def check_ref(ref):
    if not isinstance(ref, str) or not REF.fullmatch(ref):
        raise BuildError("git 版本应为提交、分支或 tag 名，例如 main 或 54a7a632")
    return ref


def image():
    return "metacodes-bench-builder:" + hashlib.sha256(DOCKERFILE.encode()).hexdigest()[:12]


def source_id(repo):
    return hashlib.sha256(repo.encode()).hexdigest()


def unit_path(bench_dir, commit):
    return Path(bench_dir) / "bundles" / f"metacodes-git-{commit[:12]}-{TARGET}"


def _record_path(unit):
    return unit.parent / (unit.name + ".json")


def build_info(unit):
    try:
        check_bundle(unit)
        info = json.loads(_record_path(unit).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(info, dict):
        return None
    return {key: info.get(key) for key in ("ref", "commit", "version", "built_at", "source_id", "trust_policy")}


def _built_here(info, commit):
    return bool(info) and info["commit"] == commit and info["trust_policy"] is not None \
        and isinstance(info["source_id"], str) and bool(SOURCE_ID.fullmatch(info["source_id"]))


def _verified_by(info, commit, repo):
    return _built_here(info, commit) and info["source_id"] == source_id(repo) \
        and info["trust_policy"] == TRUST_POLICY


def _redact(text, repo):
    return re.sub(r"(://)[^/@\s]+@", r"\1***@", text.replace(repo, "<source_repo>"))


def _last_line(stderr, repo):
    return _redact((stderr.strip().splitlines() or ["?"])[-1], repo)


@contextlib.contextmanager
def _locked(cache_dir, cancelled):
    Path(cache_dir).mkdir(parents=True, exist_ok=True)
    with open(Path(cache_dir) / ".lock", "a+") as handle:
        while fcntl:
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


def _docker(*args):
    return subprocess.run(["docker", *args], stdin=subprocess.DEVNULL,
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode


def _run(argv, cancelled, name=None, input_text=None, cwd=None, quiet=False):
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
                if hasattr(os, "killpg"):
                    os.killpg(process.pid, signal.SIGKILL)
                else:
                    process.kill()
                process.wait()
                raise BuildError("构建已取消")
            time.sleep(0.1)
        errors.seek(0)
        return process.returncode, errors.read().decode(errors="replace")


def _network(argv, cancelled, cwd=None, attempts=3, reset=lambda: None):
    for attempt in range(attempts):
        reset()
        code, stderr = _run(argv, cancelled, cwd=cwd, quiet=True)
        if code == 0 or attempt == attempts - 1:
            return code, stderr
        time.sleep(3)


def _git(*args, cwd=None):
    result = subprocess.run(["git", *args], cwd=cwd, stdin=subprocess.DEVNULL,
                            capture_output=True, text=True)
    return result.returncode, result.stdout.strip()


def _commit(mirror, name):
    code, commit = _git("rev-parse", "--verify", "-q", name + "^{commit}", cwd=mirror)
    return commit if code == 0 and COMMIT.fullmatch(commit) else None


def _refresh_mirror(mirror, repo, cancelled):
    if (mirror / "HEAD").is_file():
        if _git("remote", "set-url", "origin", repo, cwd=mirror)[0]:
            raise BuildError("无法把源码镜像切换到配置的仓库")
        code, stderr = _network(["git", "fetch", "-q", "--prune", "origin"], cancelled, cwd=mirror)
        if code:
            raise BuildError("无法更新源码仓库：" + _last_line(stderr, repo))
        return
    staged = mirror.parent / (".source-" + uuid.uuid4().hex)
    try:
        code, stderr = _network(["git", "clone", "-q", "--mirror", repo, str(staged)], cancelled,
                                reset=lambda: shutil.rmtree(staged, ignore_errors=True))
        if code:
            raise BuildError("无法获取源码仓库：" + _last_line(stderr, repo))
        _git("config", "uploadpack.allowAnySHA1InWant", "true", cwd=staged)
        staged.rename(mirror)
    finally:
        shutil.rmtree(staged, ignore_errors=True)


def _named_commit(mirror, ref):
    if ref.startswith("refs/"):
        return _commit(mirror, ref)
    named = {_commit(mirror, "refs/heads/" + ref), _commit(mirror, "refs/tags/" + ref)} - {None}
    if len(named) > 1:
        raise BuildError(f"{ref} 同时是分支和 tag 且指向不同提交，请写 refs/heads/{ref} 或 refs/tags/{ref}")
    return named.pop() if named else _commit(mirror, ref)


def resolve(ref, cache_dir, repo=None, cancelled=lambda: False):
    check_ref(ref)
    repo = repo or DEFAULT_REPO
    mirror = Path(cache_dir) / "source.git"
    Path(cache_dir).mkdir(parents=True, exist_ok=True)
    _refresh_mirror(mirror, repo, cancelled)
    commit = _named_commit(mirror, ref)
    if not commit:
        raise BuildError("源码仓库中找不到 git 版本 " + ref)
    _, published = _git("for-each-ref", "--count=1", "--contains", commit, "refs/heads", "refs/tags", cwd=mirror)
    if not published:
        raise BuildError(f"提交 {commit[:12]} 不在源码仓库的任何分支或 tag 上（例如外部 PR），"
                         "不会用执行机凭证运行它；请先推送到该仓库的分支")
    return mirror, commit


def tags_at(mirror, commit):
    _, names = _git("tag", "--points-at", commit, cwd=mirror)
    return [name for name in names.split() if REF.fullmatch(name)]


def toolchain_versions(mirror, commit):
    _, zon = _git("show", commit + ":build.zig.zon", cwd=mirror)
    match = re.search(r'minimum_zig_version\s*=\s*"([^"]*)"', zon)
    _, lean = _git("show", commit + ":control-plane/lean/lean-toolchain", cwd=mirror)
    zig, lean = match.group(1) if match else "", lean.strip()
    if not ZIG_VERSION.fullmatch(zig) or not LEAN_TOOLCHAIN.fullmatch(lean):
        raise BuildError(f"提交 {commit[:12]} 没有可识别的 Zig / Lean 版本，不能按发布布局编译")
    return zig, lean


def bundle(ref, bench_dir, repo=None, cancelled=lambda: False):
    check_ref(ref)
    repo = repo or DEFAULT_REPO
    if COMMIT.fullmatch(ref):
        info = build_info(unit_path(bench_dir, ref))
        if _verified_by(info, ref, repo):
            return unit_path(bench_dir, ref), info
    cache_dir = Path(bench_dir) / "git"
    with _locked(cache_dir, cancelled):
        return _build(ref, Path(bench_dir), cache_dir, repo, cancelled)


def _build(ref, bench_dir, cache_dir, repo, cancelled):
    mirror, commit = resolve(ref, cache_dir, repo, cancelled)
    unit = unit_path(bench_dir, commit)
    info = build_info(unit)
    if _built_here(info, commit):
        if not _verified_by(info, commit, repo):
            info = {**info, "source_id": source_id(repo), "trust_policy": TRUST_POLICY}
            _record_path(unit).write_text(json.dumps(info), encoding="utf-8")
        return unit, info
    if cancelled():
        raise BuildError("构建已取消")
    if shutil.which("docker") is None:
        raise BuildError("构建 git 版本需要这台机器上的 Docker")
    zig, lean = toolchain_versions(mirror, commit)
    lean_dir = re.sub(r"[^A-Za-z0-9._-]", "-", lean)
    print(f"bench: building metacodes {ref} ({commit[:12]}) for {TARGET} with Zig {zig}, {lean}", flush=True)
    if _docker("image", "inspect", image()):
        if _run(["docker", "build", "-q", "--platform", PLATFORM, "-t", image(), "-"], cancelled,
                input_text=DOCKERFILE)[0]:
            raise BuildError("无法构建编译镜像 " + image())
    toolchains = (cache_dir / "toolchains").resolve()
    toolchains.mkdir(parents=True, exist_ok=True)
    user = ["--user", f"{os.getuid()}:{os.getgid()}"] if hasattr(os, "getuid") else []
    name = "metacodes-bench-toolchain-" + uuid.uuid4().hex[:12]
    argv = ["docker", "run", "--rm", "--platform", PLATFORM, "--name", name, *user,
            "-v", f"{toolchains}:/toolchains",
            "-e", "ZIG_VERSION=" + zig, "-e", "LEAN_TOOLCHAIN=" + lean, "-e", "LEAN_DIR=" + lean_dir,
            "-e", "ELAN_VERSION=" + ELAN_VERSION, "-e", "ELAN_SHA256=" + ELAN_SHA256]
    if _run(argv + [image(), "bash", "-c", TOOLCHAIN_SCRIPT], cancelled, name=name)[0]:
        raise BuildError(f"无法安装 Zig {zig} / {lean}，详见上方日志")
    work = cache_dir / ("work-" + uuid.uuid4().hex)
    out = work / "unit"
    out.mkdir(parents=True)
    name = "metacodes-bench-build-" + uuid.uuid4().hex[:12]
    argv = ["docker", "run", "--rm", "--platform", PLATFORM, "--name", name, *user,
            "-v", f"{mirror.resolve()}:/mirror:ro", "-v", f"{out.resolve()}:/out",
            "-v", f"{toolchains / 'zig' / zig}:/opt/zig:ro",
            "-v", f"{toolchains / 'lean' / lean_dir}:/opt/lean:ro",
            "-e", "MIRROR=/mirror", "-e", "COMMIT=" + commit,
            "-e", "TAGS=" + " ".join(tags_at(mirror, commit))]
    try:
        if _run(argv + [image(), "bash", "-c", CHECKOUT_SCRIPT + RELEASE_SCRIPT], cancelled, name=name)[0]:
            raise BuildError(f"git 版本 {ref}（{commit[:12]}）编译失败，详见上方日志")
        try:
            manifest = check_bundle(out)
        except ValueError as exc:
            raise BuildError(f"git 版本 {ref} 的产物不能用于 Bench：{exc}") from None
        release = manifest.get("release") if isinstance(manifest.get("release"), dict) else {}
        info = {"ref": ref, "commit": commit, "version": release.get("version"),
                "built_at": dt.datetime.now(dt.timezone.utc).isoformat(),
                "source_id": source_id(repo), "trust_policy": TRUST_POLICY}
        unit.parent.mkdir(parents=True, exist_ok=True)
        staged = unit.parent / (unit.name + ".staging-" + uuid.uuid4().hex[:8])
        shutil.move(str(out), str(staged))
        if unit.exists():
            shutil.rmtree(unit)
        staged.rename(unit)
        _record_path(unit).write_text(json.dumps(info), encoding="utf-8")
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return unit, info
