"""Linux bundles built from any git revision of metacodes.

`metacodes bench build --ref <ref> [--executor <name>]` builds that commit's
x86_64 Linux release unit on the executor's node, the machine whose Docker
also runs the evaluations. Every node builds the same way: it resolves the
ref in its own mirror of the source repository and builds in its own Docker.
A remote node's unit is then copied into the workbench's
`<state>/bench/bundles/`, where a batch can choose and freeze it like any
other bundle. `commits` lists a branch's history, newest first, for the page
to pick a commit by its time.
"""
from __future__ import annotations

import contextlib
import datetime as dt
import hashlib
import json
import os
import posixpath
import re
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import uuid
from pathlib import Path

try:
    import fcntl
except ImportError:
    fcntl = None

from scripts.eval.harbor.bench import executors
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
DATE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
RECORD_KEYS = ("ref", "commit", "version", "committed_at", "built_at", "source_id", "trust_policy")
COMMIT_PAGE = 100
MAX_COMMIT_PAGE = 500
MIRROR_FRESH_S = 60

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
git fetch -q "$SOURCE" "refs/*:refs/*"
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
    return {key: info.get(key) for key in RECORD_KEYS}


def _built_here(info, commit):
    return bool(info) and info["commit"] == commit and info["trust_policy"] is not None \
        and isinstance(info["source_id"], str) and bool(SOURCE_ID.fullmatch(info["source_id"]))


def _verified_by(info, commit, repo):
    return _built_here(info, commit) and info["source_id"] == source_id(repo) \
        and info["trust_policy"] == TRUST_POLICY


def is_git_unit(path):
    return Path(path).name.startswith("metacodes-git-")


def selectable(path, repo=None):
    unit = Path(path)
    if not is_git_unit(unit):
        return True
    info = build_info(unit)
    if not info or unit != unit_path(unit.parent.parent, info["commit"] or ""):
        return False
    source = check_bundle(unit).get("source")
    if not isinstance(source, dict) or source.get("commit") != info["commit"]:
        return False
    return _verified_by(info, info["commit"], repo or DEFAULT_REPO)


def provenance(path):
    if not is_git_unit(path):
        return None
    info = build_info(Path(path))
    return {key: info[key] for key in ("commit", "source_id", "trust_policy")} if info else None


def frozen_problem(frozen, repo=None):
    git = frozen.get("git")
    if not git and not is_git_unit(frozen.get("source_bundle") or ""):
        return None
    refusal = "批次冻结的 metacodes 包由 Git 构建，当前 source_repo 没有验证它，本项不再运行"
    if not isinstance(git, dict) or git.get("trust_policy") != TRUST_POLICY \
            or git.get("source_id") != source_id(repo or DEFAULT_REPO):
        return refusal
    try:
        source = check_bundle(Path(frozen["bundle"])).get("source")
    except ValueError:
        return refusal
    if not isinstance(source, dict) or source.get("commit") != git.get("commit"):
        return refusal
    return None


def _redact(text, repo):
    return re.sub(r"(://)[^/@\s]+@", r"\1***@", text.replace(repo, "<source_repo>"))


def _last_line(stderr, repo):
    return _redact((stderr.strip().splitlines() or ["?"])[-1], repo)


@contextlib.contextmanager
def _locked(cache_dir, cancelled, wait=True):
    """Holds the build lock; yields False instead of waiting when `wait` is false and another holds it."""
    Path(cache_dir).mkdir(parents=True, exist_ok=True)
    with open(Path(cache_dir) / ".lock", "a+") as handle:
        while fcntl:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if not wait:
                    yield False
                    return
                if cancelled():
                    raise BuildError("构建已取消") from None
                time.sleep(0.1)
        try:
            yield True
        finally:
            if fcntl:
                fcntl.flock(handle, fcntl.LOCK_UN)


def _docker(*args):
    return subprocess.run(["docker", *args], stdin=subprocess.DEVNULL,
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode


def _run(argv, cancelled, name=None, input_text=None, cwd=None, quiet=False):
    with tempfile.TemporaryFile() as errors:
        process = subprocess.Popen(argv, cwd=cwd, stdin=subprocess.PIPE if input_text is not None else subprocess.DEVNULL,
                                   stdout=subprocess.DEVNULL if quiet else sys.stderr,
                                   stderr=errors if quiet else sys.stderr, start_new_session=True)
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


def commits(cache_dir, repo=None, ref="main", until=None, limit=COMMIT_PAGE, cancelled=lambda: False):
    """`ref`'s history up to the end of day `until` (YYYY-MM-DD), newest first.
    The mirror is refreshed unless it was a minute ago or a build holds it."""
    check_ref(ref)
    if until is not None and (not isinstance(until, str) or not DATE.fullmatch(until)):
        raise BuildError("日期应为 YYYY-MM-DD")
    if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= MAX_COMMIT_PAGE:
        raise BuildError(f"条数应为 1–{MAX_COMMIT_PAGE}")
    repo = repo or DEFAULT_REPO
    mirror = Path(cache_dir) / "source.git"
    with _locked(cache_dir, cancelled, wait=False) as held:
        if held and not _fresh(mirror):
            _refresh_mirror(mirror, repo, cancelled)
    if not (mirror / "HEAD").is_file():
        raise BuildError("源码仓库还在更新，请稍后再试")
    head = _named_commit(mirror, ref)
    if not head:
        raise BuildError("源码仓库中找不到 git 版本 " + ref)
    argv = ["log", "-z", "--format=%H%x1f%cI%x1f%an%x1f%s", "-n", str(limit)]
    if until:
        argv.append(f"--until={until}T23:59:59")
    code, out = _git(*argv, head, cwd=mirror)
    if code:
        raise BuildError("无法读取提交历史")
    found = []
    for entry in filter(None, out.split("\0")):
        commit, at, author, subject = (entry.strip("\n").split("\x1f") + ["", "", ""])[:4]
        if COMMIT.fullmatch(commit):
            found.append({"commit": commit, "committed_at": at, "author": author, "subject": subject})
    return found


def _fresh(mirror):
    try:
        return time.time() - (mirror / "FETCH_HEAD").stat().st_mtime < MIRROR_FRESH_S
    except OSError:
        return False


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


def source_bundle(mirror, commit, path):
    ref = "refs/bench-build/" + uuid.uuid4().hex
    _git("update-ref", ref, commit, cwd=mirror)
    try:
        code, _ = _git("bundle", "create", str(path), ref, *("refs/tags/" + tag for tag in tags_at(mirror, commit)),
                       cwd=mirror)
    finally:
        _git("update-ref", "-d", ref, cwd=mirror)
    if code:
        raise BuildError(f"无法导出提交 {commit[:12]} 的源码")
    return path


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
    print(f"bench: building metacodes {ref} ({commit[:12]}) for {TARGET} with Zig {zig}, {lean}",
          file=sys.stderr, flush=True)
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
    try:
        source = source_bundle(mirror, commit, work / "source.bundle").resolve()
        argv = ["docker", "run", "--rm", "--platform", PLATFORM, "--name", name, *user,
                "-v", f"{source}:/source.bundle:ro", "-v", f"{out.resolve()}:/out",
                "-v", f"{toolchains / 'zig' / zig}:/opt/zig:ro",
                "-v", f"{toolchains / 'lean' / lean_dir}:/opt/lean:ro",
                "-e", "SOURCE=/source.bundle", "-e", "COMMIT=" + commit]
        if _run(argv + [image(), "bash", "-c", CHECKOUT_SCRIPT + RELEASE_SCRIPT], cancelled, name=name)[0]:
            raise BuildError(f"git 版本 {ref}（{commit[:12]}）编译失败，详见上方日志")
        try:
            manifest = check_bundle(out)
        except ValueError as exc:
            raise BuildError(f"git 版本 {ref} 的产物不能用于 Bench：{exc}") from None
        release = manifest.get("release") if isinstance(manifest.get("release"), dict) else {}
        _, committed_at = _git("show", "-s", "--format=%cI", commit, cwd=mirror)
        info = {"ref": ref, "commit": commit, "version": release.get("version"), "committed_at": committed_at or None,
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


def build_on(executor, ref, bench_dir, repo=None, cancelled=lambda: False, popen=subprocess.Popen):
    """The unit of `ref`, built on `executor`'s node; a remote one is copied here."""
    if not isinstance(executor, executors.SshExecutor):
        return bundle(ref, bench_dir, repo, cancelled)
    check_ref(ref)
    repo = repo or DEFAULT_REPO
    if COMMIT.fullmatch(ref):
        info = build_info(unit_path(bench_dir, ref))
        if _verified_by(info, ref, repo):
            return unit_path(bench_dir, ref), info
    with _locked(Path(bench_dir) / "git", cancelled):
        result = _node_build(executor, ref, repo, cancelled, popen)
        commit = result.get("commit")
        if not isinstance(commit, str) or not COMMIT.fullmatch(commit) \
                or result.get("bundle") != unit_path(bench_dir, commit).name:
            raise BuildError(f"执行机器 {executor.name} 返回的编译结果无法识别")
        unit = unit_path(bench_dir, commit)
        info = build_info(unit)
        if not _verified_by(info, commit, repo):
            info = _fetch_unit(executor, result["path"], unit, commit, repo, cancelled, popen)
        return unit, info


def _node_build(executor, ref, repo, cancelled, popen):
    """`metacodes bench node build` on the executor: the request on stdin,
    the build log on stderr, the result as the last stdout line. Closing
    stdin cancels it there."""
    argv = executors.node_argv(executor, "build")
    print(f"bench: building metacodes {ref} on {executor.name}", file=sys.stderr, flush=True)
    process = popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, start_new_session=True)
    lines = []
    reader = threading.Thread(target=lambda: lines.extend(process.stdout), daemon=True)
    reader.start()
    try:
        process.stdin.write((json.dumps({"ref": ref, "repo": repo}) + "\n").encode())
        process.stdin.flush()
    except (BrokenPipeError, OSError):
        pass
    while process.poll() is None:
        if cancelled():
            _stop(process)
            raise BuildError("构建已取消")
        time.sleep(0.1)
    reader.join(timeout=5)
    _close(process.stdin)
    _close(process.stdout)
    if process.returncode:
        raise BuildError(f"执行机器 {executor.name} 上的编译失败（退出码 {process.returncode}），详见上方日志；"
                         f"节点不认识 build 时，先运行 metacodes bench setup --executor {executor.name} 更新节点")
    try:
        result = json.loads(lines[-1])
    except (IndexError, ValueError):
        raise BuildError(f"执行机器 {executor.name} 没有返回编译结果") from None
    if not isinstance(result, dict) or not isinstance(result.get("path"), str):
        raise BuildError(f"执行机器 {executor.name} 返回的编译结果无法识别")
    return result


def _close(stream):
    if stream is None:
        return
    try:
        stream.close()
    except (BrokenPipeError, OSError):
        pass


def _stop(process):
    _close(process.stdin)
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        if hasattr(os, "killpg"):
            os.killpg(process.pid, signal.SIGKILL)
        else:
            process.kill()
        process.wait()
    _close(process.stdout)
    _close(process.stderr)


def _fetch_unit(executor, remote_unit, unit, commit, repo, cancelled, popen):
    """Copies the unit and its build record from the executor, accepting only
    regular files and directories under the unit's own name."""
    parent, name = posixpath.split(remote_unit)
    if name != unit.name or not parent:
        raise BuildError(f"执行机器 {executor.name} 返回的包路径无法识别")
    record = name + ".json"
    argv = executors.ssh_argv(executor, ["tar", "-cf", "-", "-C", parent, name, record])
    print(f"bench: copying {name} from {executor.name}", file=sys.stderr, flush=True)
    staged = unit.parent / (".fetch-" + uuid.uuid4().hex[:8])
    staged.mkdir(parents=True)
    try:
        process = popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                        start_new_session=True)
        try:
            _extract(process.stdout, staged, name, record, cancelled)
        except (tarfile.TarError, OSError) as exc:
            _stop(process)
            raise BuildError(f"从执行机器 {executor.name} 复制包失败：{exc}") from None
        except BuildError:
            _stop(process)
            raise
        stderr = process.stderr.read().decode(errors="replace")
        _close(process.stdout)
        _close(process.stderr)
        if process.wait():
            raise BuildError(f"从执行机器 {executor.name} 复制包失败：" + _last_line(stderr, repo))
        try:
            manifest = check_bundle(staged / name)
            info = json.loads((staged / record).read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            raise BuildError(f"执行机器 {executor.name} 上的包不能用于 Bench：{exc}") from None
        info = {key: info.get(key) for key in RECORD_KEYS} if isinstance(info, dict) else None
        source = manifest.get("source")
        if not _verified_by(info, commit, repo) or not isinstance(source, dict) or source.get("commit") != commit:
            raise BuildError(f"执行机器 {executor.name} 上的包不是由配置的源码仓库验证的提交 {commit[:12]}")
        if unit.exists():
            shutil.rmtree(unit)
        (staged / name).rename(unit)
        _record_path(unit).write_text(json.dumps(info), encoding="utf-8")
        return info
    finally:
        shutil.rmtree(staged, ignore_errors=True)


def _extract(stream, staged, name, record, cancelled):
    with tarfile.open(fileobj=stream, mode="r|") as archive:
        for member in archive:
            if cancelled():
                raise BuildError("构建已取消")
            path = posixpath.normpath(member.name)
            inside = path == record or path == name or path.startswith(name + "/")
            if not inside or path.startswith("/") or ".." in path.split("/") or not (member.isfile() or member.isdir()):
                raise BuildError("包里有不允许的条目：" + member.name)
            target = staged / path
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            source = archive.extractfile(member)
            with open(target, "wb") as out:
                shutil.copyfileobj(source, out)
            target.chmod(0o755 if member.mode & 0o111 else 0o644)


class BuildManager:
    """Builds started from the page, one at a time, each in its own process
    with a progress record and a log beside it."""

    LOG_TAIL = 80

    def __init__(self, config_path):
        self.config_path = Path(config_path)
        self.directory = self.config_path.parent / "builds"
        self.lock = threading.Lock()
        self.process = None

    def latest(self):
        files = sorted(self.directory.glob("*.json"), key=lambda p: p.stat().st_mtime) if self.directory.is_dir() else []
        if not files:
            return None
        try:
            value = json.loads(files[-1].read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None
        alive = self.process is not None and self.process.poll() is None
        if value.get("status") == "running" and not alive:
            value = {**value, "status": "interrupted"}
        try:
            lines = files[-1].with_suffix(".log").read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            lines = []
        return {**value, "log": lines[-self.LOG_TAIL:]}

    def start(self, request, executor_name, runtime_env, cwd):
        if not isinstance(request, dict) or set(request) - {"ref", "executor"}:
            raise ValueError("只接受 ref、executor")
        ref = check_ref(request.get("ref"))
        with self.lock:
            if self.process is not None and self.process.poll() is None:
                raise ValueError("已有一个编译在进行，请等它结束")
            self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
            ident = dt.datetime.now().strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:6]
            progress = self.directory / (ident + ".json")
            _write(progress, {"id": ident, "ref": ref, "executor": executor_name, "status": "running",
                              "started_at": _now()})
            argv = [sys.executable, "-m", "scripts.eval.harbor.bench.builds", "--config", str(self.config_path),
                    "--executor", executor_name, "--ref", ref, "--progress", str(progress)]
            with progress.with_suffix(".log").open("wb") as log:
                self.process = subprocess.Popen(argv, cwd=cwd, env=runtime_env, stdin=subprocess.DEVNULL,
                                                stdout=log, stderr=log, start_new_session=True)
            threading.Thread(target=self.process.wait, daemon=True).start()
            return {"id": ident, "ref": ref, "executor": executor_name, "status": "running"}

    def cancel(self):
        with self.lock:
            if self.process is None or self.process.poll() is not None:
                raise ValueError("没有正在进行的编译")
            self.process.send_signal(signal.SIGTERM)
            return {"cancel_requested": True}


def _now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def _write(path, value):
    staged = Path(path).with_name(Path(path).name + ".tmp")
    staged.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")
    os.replace(staged, path)


def main(argv=None):
    import getopt
    names = ("config", "executor", "ref", "progress")
    try:
        options, rest = getopt.getopt(sys.argv[1:] if argv is None else argv, "", [n + "=" for n in names])
    except getopt.GetoptError as exc:
        print("bench build: " + str(exc), file=sys.stderr)
        return 2
    options = {key[2:]: value for key, value in options}
    if rest or set(options) != set(names):
        print("usage: builds.py --config <workbench.json> --executor NAME --ref REF --progress FILE", file=sys.stderr)
        return 2
    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    progress = Path(options["progress"])
    value = json.loads(progress.read_text(encoding="utf-8"))
    os.environ["PATH"] = executors.search_path()
    try:
        config = Path(options["config"])
        cfg = json.loads(config.read_text(encoding="utf-8"))
        executor = executors.find(cfg, options["executor"])
        unit, info = build_on(executor, options["ref"], config.parent, cfg.get("source_repo"), cancelled=stop.is_set)
        value.update(status="done", bundle=unit.name, commit=info["commit"], version=info.get("version"),
                     committed_at=info.get("committed_at"))
        code = 0
    except (BuildError, ValueError, OSError) as exc:
        value.update(status="cancelled" if stop.is_set() else "failed", error=str(exc))
        print(f"bench: {exc}", file=sys.stderr, flush=True)
        code = 1
    value["finished_at"] = _now()
    _write(progress, value)
    return code


if __name__ == "__main__":
    sys.exit(main())
