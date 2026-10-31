#!/usr/bin/env python3
"""AgentCore's half of a main-project release: choose and finalize its version,
decide whether its artifacts are built or reused, package its language SDKs, and
refuse a release whose deliverables are not one consistent AgentCore.

Design: doc/RELEASE_AUTOMATION_DESIGN.md §2a. The cut (`release_cut.py`) calls
`plan_cut` and `apply_cut`, the reopen `apply_reopen`, and the fast path
(`release_fast_path.py`) `apply_cut` / `apply_reopen` again to regenerate the same
bytes from the base. `release.yml` drives the subcommands:

  release-mode            AGENTCORE_REUSE_FROM for the later steps
  package-languages       wheel, and the Node package on POSIX, from a built bundle
  fetch-reused            the built main release's artifacts for one target
  fetch-published-sums    every published release's SHA256SUMS
  verify-dist             the door: nothing is drafted unless this passes

`check_version_state.py` calls `state_findings` on every PR; `rehearse` builds and
checks a formal release of the current tree in a scratch worktree, tagged locally
and never pushed. Python 3.9, stdlib only; every external command is an argv list.
Tests: scripts/tests/test_agentcore_release.py.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Callable, Dict, Iterable, List, Optional, Sequence, Set, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))
import agentcore_contract as contract  # noqa: E402  (same directory, stdlib only)
import release_archive  # noqa: E402
import release_common as common  # noqa: E402
from release_common import CutError  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
# What AgentCore is built from. `src/` whole, on purpose: the library's module root
# is `src/lib.zig`, which reaches nearly every file, and Zig's lazy analysis decides
# what is compiled only during a build. Claiming less could keep a version over
# changed code; claiming more costs a patch version. The rest is the build graph,
# the packaging, and what the bundle ships beside the library.
INPUT_FILES = {
    "LICENSE",
    "build.zig",
    "build.zig.zon",
    "scripts/agentcore_binary.zig",
    "scripts/agentcore_manifest.zig",
    "scripts/agentcore_symbol_gate.zig",
    "scripts/manifest_common.zig",
    "scripts/package_agentcore.py",
    "scripts/release_archive.py",
    "scripts/repack_agentcore_macos_archive.sh",
    "scripts/stage_ripgrep_binary.py",
}
INPUT_PREFIXES = ("src/", "lib/", "sdk/", "vendor/ripgrep/", "deps/")
# What moves on every release without changing what AgentCore is: its own version
# records, documents that ship nowhere, the package tests, and the main project's
# version mirror, which the library compiles but no ABI call reports.
NOT_INPUTS = {contract.SDK_VERSION, contract.SDK_CHANGELOG, contract.LEDGER, "sdk/README.md", common.VERSION_ZIG}
NOT_INPUT_PREFIXES = ("sdk/python/tests/", "sdk/node/test/")
# Files that are inputs apart from their version line, which is blanked before
# hashing: the same package with a new number is the same AgentCore.
VERSION_LINES = {
    contract.PY_PROJECT: contract.PY_PROJECT_VERSION_RE,
    contract.PY_INIT: contract.PY_INIT_VERSION_RE,
    contract.NODE_PACKAGE: contract.NODE_VERSION_RE,
    common.ZON: common.ZON_VERSION_RE,
}
MIGRATION_HEADING = "### Migration"

CHECKSUM_SUFFIX = ".sha256"


# ---------------------------------------------------------------- inputs


def tracked_files(root: Path) -> Set[str]:
    proc = subprocess.run(["git", "-C", str(root), "ls-files", "-z"], capture_output=True, check=False)
    if proc.returncode != 0:
        raise CutError(f"cannot list the tracked files of {root}: {proc.stderr.decode('utf-8', 'replace').strip()}")
    return {name for name in proc.stdout.decode("utf-8").split("\0") if name}


def input_paths(root: Path) -> List[str]:
    selected = []
    for rel in tracked_files(root):
        if rel in NOT_INPUTS or rel.startswith(NOT_INPUT_PREFIXES):
            continue
        if rel in INPUT_FILES or rel.startswith(INPUT_PREFIXES):
            selected.append(rel)
    return sorted(selected)


def input_digest(root: Path) -> str:
    """A digest of what AgentCore is built from. Tracked content only, so a build
    output never moves it, and line endings normalized, so a Windows checkout
    agrees with the POSIX one that cut the release."""
    digest = hashlib.sha256()
    for rel in input_paths(root):
        data = (root / rel).read_bytes()
        if b"\0" not in data:
            data = data.replace(b"\r\n", b"\n")
        pattern = VERSION_LINES.get(rel)
        if pattern is not None:
            data = pattern.sub(lambda m: m.group(1) + "<version>" + m.group(3), data.decode("utf-8")).encode("utf-8")
        digest.update(rel.encode("utf-8") + b"\0" + hashlib.sha256(data).digest())
    return digest.hexdigest()


# ---------------------------------------------------------------- the cut


@dataclass(frozen=True)
class CutPlan:
    """What the cut will do for AgentCore. `built` builds `version` for this main
    release; `reused` keeps the latest release's version and artifacts."""

    kind: str
    version: str
    abi_revision: int
    level: str
    reason: str


def changed_abi(ledger: contract.Ledger, revision: int) -> bool:
    latest = ledger.latest
    return latest is not None and latest.abi_revision != revision


def plan_cut(root: Path, level_arg: str = "auto", force: bool = False, messages: Optional[Callable[[str], Sequence[str]]] = None) -> CutPlan:
    """Select the version. `messages(main_tag)` returns the commits touching the
    inputs since that main release; the level comes from them as it does for the
    main project, and a change no commit type explains is still a patch, because
    new bytes may never reuse an old version."""
    ledger = contract.load_ledger(root)
    revision = contract.abi_revision(root)
    floor_text = contract.sdk_version(root)
    if not contract.is_dev(floor_text):
        raise CutError(f"{contract.SDK_VERSION} carries {floor_text} without -dev: a release is mid-flight, reopen first")
    floor = contract.parse(floor_text)
    latest = ledger.latest
    if latest is None:
        if level_arg != "auto" and not force:
            raise CutError(f"no AgentCore release yet: the first one is the {floor_text} floor; --agentcore-level needs --force-level")
        return CutPlan("built", common.fmt(floor), revision, "first", "first formal release, at the -dev floor")
    if input_digest(root) == latest.input_digest:
        if level_arg != "auto":
            raise CutError(f"AgentCore is unchanged since {latest.version}, so it keeps that version; drop --agentcore-level")
        return CutPlan("reused", latest.version, revision, "none", f"inputs unchanged since {latest.version}")
    derived, _ = common.derive_level(list(messages(latest.built_by)) if messages else [])
    if common.LEVELS.index(derived) < common.LEVELS.index("patch"):
        derived = "patch"
    if changed_abi(ledger, revision) and common.LEVELS.index(derived) < common.LEVELS.index("minor"):
        derived = "minor"
    level = derived if level_arg == "auto" else level_arg
    if level_arg != "auto" and not force and common.LEVELS.index(level_arg) < common.LEVELS.index(derived):
        raise CutError(f"--agentcore-level {level_arg} is below the derived level {derived}; add --force-level to override")
    version = common.fmt(max(common.bump(contract.parse(latest.version), level), floor))
    return CutPlan("built", version, revision, level, f"inputs changed since {latest.version}")


def apply_cut(root: Path, version: str, main_version: str, date: str) -> str:
    """Finalize AgentCore in a checkout that carries `-dev`: the packages, the
    ledger and, for a built release, its changelog. Refuses every version the
    rules forbid, so a hand-made bump cannot regenerate through the fast path.
    Returns `built` or `reused`."""
    if not contract.BARE_RE.match(version):
        raise CutError(f"a formal AgentCore release needs a final X.Y.Z, not {version!r}")
    floor_text = contract.sdk_version(root)
    if not contract.is_dev(floor_text):
        raise CutError(f"{contract.SDK_VERSION} carries {floor_text} without -dev: a release is mid-flight, reopen first")
    ledger = contract.load_ledger(root)
    revision = contract.abi_revision(root)
    digest = input_digest(root)
    latest = ledger.latest
    if latest is not None and digest == latest.input_digest:
        if version != latest.version:
            raise CutError(f"AgentCore is unchanged since {latest.version}, so it keeps that version, not {version}")
        updated = ledger.carrying(latest, main_version)
        kind = "reused"
    else:
        if ledger.by_version(version) is not None:
            raise CutError(f"AgentCore {version} is already released with other inputs; a changed AgentCore needs a new version")
        if contract.parse(version) < contract.parse(floor_text):
            raise CutError(f"AgentCore {version} is below the {floor_text} floor")
        release = contract.Release(version, contract.abi_version(root), revision, digest, (main_version,))
        updated = ledger.appended(release)
        text, section = common.rewrite_changelog(
            common.read(root, contract.SDK_CHANGELOG), version, date, contract.SDK_CHANGELOG, contract.SDK_SUBSECTIONS
        )
        if changed_abi(ledger, revision) and not has_migration(section):
            raise CutError(
                f"{contract.SDK_CHANGELOG}: AgentCore {version} moves the ABI revision "
                f"({latest.abi_revision} -> {revision}), so its '{common.UNRELEASED}' block needs a "
                f"'{MIGRATION_HEADING}' entry telling Hosts what to change"
            )
        common.write(root, contract.SDK_CHANGELOG, text)
        kind = "built"
    contract.set_sdk_version(root, version)
    common.write(root, contract.LEDGER, contract.dump_ledger(updated))
    return kind


def has_migration(section: str) -> bool:
    lines = section.splitlines()
    if MIGRATION_HEADING not in lines:
        return False
    start = lines.index(MIGRATION_HEADING) + 1
    end = next((i for i in range(start, len(lines)) if lines[i].startswith("#")), len(lines))
    return any(line.startswith("- ") for line in lines[start:end])


def reopen_target(root: Path, level: str = "patch") -> str:
    """The next `-dev` above the latest release (`sdk/VERSION` itself on a tree
    with no release, which the state gate would have refused anyway)."""
    latest = contract.load_ledger(root).latest
    if latest is None:
        raise CutError(f"{contract.LEDGER} has no AgentCore release to reopen after")
    return common.fmt(common.bump(contract.parse(latest.version), level)) + "-dev"


def apply_reopen(root: Path, target: str) -> None:
    if contract.is_dev(contract.sdk_version(root)):
        raise CutError(f"{contract.SDK_VERSION} already carries -dev; nothing to reopen")
    if target not in (reopen_target(root, "patch"), reopen_target(root, "minor")):
        raise CutError(f"AgentCore reopens at {reopen_target(root, 'patch')} or {reopen_target(root, 'minor')}, not {target}")
    contract.set_sdk_version(root, target)
    common.write(root, contract.SDK_CHANGELOG, common.ensure_unreleased(common.read(root, contract.SDK_CHANGELOG), contract.SDK_CHANGELOG))


# ---------------------------------------------------------------- the state gate


def ledger_at(root: Path, rev: str) -> Optional[contract.Ledger]:
    proc = subprocess.run(["git", "-C", str(root), "show", f"{rev}:{contract.LEDGER}"], capture_output=True, check=False)
    if proc.returncode != 0:
        return None  # a tag older than the ledger
    return contract.parse_ledger(proc.stdout.decode("utf-8"))


def state_findings(root: Path, main_version: str, last_tag: Optional[str]) -> List[str]:
    """The AgentCore half of the version state, on every PR: the same facts a
    release needs, checked long before one is cut. The ABI revision is read, not
    pinned, so a bump on `main` is legal until the cut records it."""
    try:
        ledger = contract.load_ledger(root)
        version = contract.sdk_version(root)
        contract.abi_revision(root)
        findings = contract.package_version_findings(root)
    except CutError as exc:
        return [str(exc)]
    main_dev = main_version.endswith("-dev")
    if main_dev != contract.is_dev(version):
        findings.append(f"build.zig.zon is {main_version} but {contract.SDK_VERSION} is {version}: AgentCore is finalized and reopened with the main project")
    if contract.is_dev(version):
        latest = ledger.latest
        if latest is not None and contract.parse(version) <= contract.parse(latest.version):
            findings.append(f"{contract.SDK_VERSION} {version} is not above the released AgentCore {latest.version}")
    else:
        findings.extend(release_state_findings(root, ledger, version, main_version))
    if last_tag:
        try:
            older = ledger_at(root, last_tag)
        except CutError as exc:
            older = None
            findings.append(f"at tag {last_tag}: {exc}")
        if older is not None:
            rewritten = contract.is_prefix_of(older, ledger)
            if rewritten:
                findings.append(f"{rewritten} (since tag {last_tag}); released entries are immutable")
    return findings


def release_state_findings(root: Path, ledger: contract.Ledger, version: str, main_version: str) -> List[str]:
    entry = ledger.by_main_release(main_version)
    if entry is None:
        return [f"{contract.LEDGER} does not say which AgentCore main-project release {main_version} carries"]
    findings = []
    if entry.version != version:
        findings.append(f"{contract.LEDGER} says release {main_version} carries AgentCore {entry.version}, but {contract.SDK_VERSION} is {version}")
    revision = contract.abi_revision(root)
    if entry.abi_revision != revision:
        findings.append(f"{contract.LEDGER} maps AgentCore {entry.version} to ABI revision {entry.abi_revision}, but {contract.ABI_AUTHORITY} says {revision}")
    if input_digest(root) != entry.input_digest:
        findings.append(f"the AgentCore inputs differ from what {contract.LEDGER} records for {entry.version}: a changed AgentCore needs a new version")
    return findings


# ---------------------------------------------------------------- language packages


def probe_library_abi(library: Path) -> Tuple[int, int]:
    """(abi_version, abi_revision) a shared library itself reports."""
    import ctypes

    handle = ctypes.CDLL(str(library))
    entry = handle.metask_agentcore_get_api
    entry.restype = ctypes.c_void_p
    entry.argtypes = [ctypes.c_uint32]
    api = entry(1)
    if not api:
        raise CutError(f"{library.name} refused ABI v1")
    words = (ctypes.c_uint32 * 3).from_address(api)
    return int(words[1]), int(words[2])


def host_runs(target: dict) -> bool:
    """Whether this interpreter can load a library built for `target`."""
    import platform

    machine = {"amd64": "x86_64", "arm64": "aarch64"}.get(platform.machine().lower(), platform.machine().lower())
    system = {"darwin": "macos"}.get(platform.system().lower(), platform.system().lower())
    return target.get("architecture") == machine and target.get("os") == system


def verify_package_inputs(
    bundle_root: Path,
    root: Path = ROOT,
    formal: bool = False,
    probe: Callable[[Path], Tuple[int, int]] = probe_library_abi,
    head: Optional[str] = None,
) -> dict:
    """Refuse to put this bundle's library under this checkout's package metadata
    unless both are one AgentCore release. Returns the manifest.

    The file digests, the bundle's own consistency, the version and ABI against
    the checkout, then the source: a development bundle must come from this very
    commit, and a release from a tree the ledger records for its version. Where
    this host can load the library, the library itself must report the revision."""
    bundle = release_archive.load_bundle(bundle_root, "agentcore")
    manifest = bundle.manifest
    contract.check_bundle_contents(manifest, lambda rel: bundle_root.joinpath(*PurePosixPath(rel).parts).read_bytes())
    if formal and bundle.channel != "stable":
        raise CutError(f"development version {bundle.version} cannot go into a formal release package")
    findings = contract.correspondence_findings(manifest, root)
    if bundle.channel == "stable":
        entry = contract.load_ledger(root).by_version(bundle.version)
        if entry is None:
            findings.append(f"{contract.LEDGER} has no AgentCore {bundle.version}")
        else:
            if entry.abi_revision != manifest["contract"]["binary_abi_revision"]:
                findings.append(f"{contract.LEDGER} maps AgentCore {bundle.version} to ABI revision {entry.abi_revision}, the bundle says {manifest['contract']['binary_abi_revision']}")
            if entry.input_digest != input_digest(root):
                findings.append(f"this checkout is not the source of AgentCore {bundle.version}: its inputs differ from {contract.LEDGER}")
    else:
        current = head if head is not None else git_head(root)
        if manifest["source"]["commit"] != current:
            findings.append(f"the bundle was built from {manifest['source']['commit']}, but this checkout is {current}")
    if findings:
        raise CutError("; ".join(findings))
    library = bundle_root.joinpath(*PurePosixPath(manifest["shared_library"]["path"]).parts)
    if host_runs(manifest["target"]) or probe is not probe_library_abi:
        version, revision = probe(library)
        expected = (manifest["contract"]["binary_abi_version"], manifest["contract"]["binary_abi_revision"])
        if (version, revision) != expected:
            raise CutError(f"{library.name} reports ABI v{version} revision {revision}, but its manifest says v{expected[0]} revision {expected[1]}")
    return manifest


def git_head(root: Path) -> str:
    return common.run(["git", "rev-parse", "HEAD"], root).strip()


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_sidecar(path: Path) -> Path:
    sidecar = path.with_name(path.name + CHECKSUM_SUFFIX)
    with sidecar.open("w", encoding="ascii", newline="\n") as handle:
        handle.write(f"{release_archive.sha256_file(path)}  {path.name}\n")
    return sidecar


def node_package_name(version: str, target_id: str) -> str:
    """One package per platform: each carries one platform's prebuilt addon."""
    return f"metacodes-node-{version}-{target_id}.tgz"


def load_build_wheel():
    import importlib.util

    spec = importlib.util.spec_from_file_location("build_wheel", ROOT / "sdk" / "python" / "build_wheel.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def single_bundle(sdk_prefix: Path) -> Path:
    bundles = sorted(p for p in (sdk_prefix / "agentcore").glob("*") if (p / "manifest.json").is_file())
    if len(bundles) != 1:
        raise CutError(f"expected one AgentCore bundle under {sdk_prefix}, found {[p.name for p in bundles]}")
    return bundles[0]


def package_languages(sdk_prefix: Path, dist: Path, node: bool, formal: bool, root: Path = ROOT) -> List[Path]:
    """The Python wheel, and on POSIX the Node package, from the bundle the job
    just archived, each with its `.sha256`. The Node package is assembled outside
    the checkout: a `prebuilds/` inside it would mark the tree dirty for the
    release steps that follow."""
    bundle = single_bundle(sdk_prefix)
    made = []
    wheel = load_build_wheel().build(bundle, dist, "", formal=formal, root=root)
    write_sidecar(wheel)
    made.append(wheel)
    if node:
        with tempfile.TemporaryDirectory() as scratch:
            package = Path(scratch) / "node"
            shutil.copytree(root / "sdk" / "node", package, ignore=shutil.ignore_patterns("prebuilds", "test", "node_modules"))
            platform_dir = subprocess.run(
                ["node", "-p", "process.platform + '-' + process.arch"], capture_output=True, check=True
            ).stdout.decode("utf-8").strip()
            build = ["node", str(root / "sdk" / "node" / "scripts" / "build.js"), "--bundle", str(bundle), "--out", str(package / "prebuilds" / platform_dir)]
            if formal:
                build.append("--release")
            subprocess.run(build, check=True, cwd=str(root))
            npm = shutil.which("npm") or "npm"
            packed = subprocess.run([npm, "pack", "--silent", "--pack-destination", scratch], cwd=str(package), capture_output=True, check=True)
            source = Path(scratch) / packed.stdout.decode("utf-8").strip().splitlines()[-1]
            manifest = json.loads((bundle / "manifest.json").read_text(encoding="utf-8"))
            target = dist / node_package_name(manifest["version"], manifest["target"]["id"])
            shutil.copyfile(source, target)
        write_sidecar(target)
        made.append(target)
    return made


# ---------------------------------------------------------------- reuse


def release_mode(root: Path, main_version: str) -> str:
    """The main release that built this AgentCore, when that is an earlier one;
    empty when this release builds it (or this is a development build)."""
    if main_version.endswith("-dev"):
        return ""
    entry = contract.load_ledger(root).by_main_release(main_version)
    if entry is None:
        raise CutError(f"{contract.LEDGER} does not say which AgentCore main-project release {main_version} carries")
    return "" if entry.built_by == main_version else entry.built_by


def sums_name(main_version: str) -> str:
    return f"metacodes-{main_version}-SHA256SUMS"


def parse_sums(text: str) -> Dict[str, str]:
    entries = {}
    for line in text.splitlines():
        digest, separator, name = line.partition("  ")
        if not separator or not contract.DIGEST_RE.match(digest) or not name or name in entries:
            raise CutError(f"malformed SHA256SUMS line: {line!r}")
        entries[name] = digest
    return entries


Downloader = Callable[[str, str, Path], None]


def gh_download(release: str, name: str, directory: Path) -> None:
    subprocess.run(["gh", "release", "download", release, "--pattern", name, "--dir", str(directory), "--clobber"], check=True)


def fetch_reused(root: Path, main_version: str, target_id: str, dist: Path, download: Downloader = gh_download) -> List[Path]:
    """Copy this target's artifacts of the reused AgentCore from the release that
    built it, each proven against that release's SHA256SUMS. Absent means fail:
    a reused AgentCore is delivered whole or the release stops here."""
    entry = contract.load_ledger(root).by_main_release(main_version)
    if entry is None or entry.built_by == main_version:
        raise CutError(f"release {main_version} does not reuse an AgentCore")
    with tempfile.TemporaryDirectory() as scratch:
        work = Path(scratch)
        name = sums_name(entry.built_by)
        download(entry.built_by, name, work)
        sums = parse_sums((work / name).read_text(encoding="ascii"))
    dist.mkdir(parents=True, exist_ok=True)
    made = []

    def fetch(asset: str) -> Path:
        digest = sums.get(asset)
        if digest is None:
            raise CutError(f"release {entry.built_by} has no {asset} to reuse for AgentCore {entry.version}")
        download(entry.built_by, asset, dist)
        path = dist / asset
        if release_archive.sha256_file(path) != digest:
            path.unlink()
            raise CutError(f"{asset} downloaded from release {entry.built_by} is not the file its SHA256SUMS names")
        write_sidecar(path)
        made.append(path)
        return path

    suffix = ".zip" if "-windows-" in target_id else ".tar.gz"
    archive = fetch(f"metask-agentcore-{entry.version}-{target_id}{suffix}")
    members = read_archive(archive)
    manifest = json.loads(members[f"metask-agentcore-{entry.version}-{target_id}/manifest.json"].decode("utf-8"))
    tag = load_build_wheel().platform_tag(manifest["target"])
    fetch(f"metacodes-{contract.python_version(entry.version)}-py3-none-{tag}.whl")
    node = node_package_name(entry.version, target_id)
    if node in sums:
        fetch(node)
    elif "-windows-" not in target_id:
        raise CutError(f"release {entry.built_by} has no {node} to reuse for AgentCore {entry.version}")
    return made


def gh_json(argv: Sequence[str]):
    return json.loads(subprocess.run(["gh", *argv], capture_output=True, check=True).stdout.decode("utf-8"))


def fetch_published_sums(out: Path, skip: str, query: Callable[[Sequence[str]], object] = gh_json, download: Downloader = gh_download) -> List[Path]:
    """Every published (not draft) release's SHA256SUMS. A failed command stops
    the release: the conflict check cannot pass by not looking. The early releases
    that predate SHA256SUMS have nothing to compare, and are named in the log."""
    out.mkdir(parents=True, exist_ok=True)
    fetched = []
    for release in query(["release", "list", "--limit", "1000", "--json", "tagName,isDraft"]):
        tag = release["tagName"]
        if release["isDraft"] or tag == skip:
            continue
        assets = query(["release", "view", tag, "--json", "assets"])["assets"]
        if sums_name(tag) not in [asset["name"] for asset in assets]:
            print(f"release {tag} has no {sums_name(tag)}; nothing to compare with it")
            continue
        download(tag, sums_name(tag), out)
        fetched.append(out / sums_name(tag))
    return fetched


# ---------------------------------------------------------------- the door


def read_archive(path: Path) -> Dict[str, bytes]:
    """Every regular member by name; nothing is written to disk."""
    members: Dict[str, bytes] = {}
    if path.name.endswith((".zip", ".whl")):
        with zipfile.ZipFile(path) as archive:
            for info in archive.infolist():
                if not info.is_dir():
                    members[info.filename] = archive.read(info)
        return members
    with tarfile.open(path, "r:gz") as archive:
        for member in archive.getmembers():
            if member.isfile():
                members[member.name] = archive.extractfile(member).read()
    return members


def assets_in(dist: Path) -> List[Path]:
    return sorted(p for p in dist.rglob("*") if p.is_file() and not p.name.endswith(CHECKSUM_SUFFIX) and not p.name.endswith("-SHA256SUMS"))


def check_published(dist: Path, published_sums: Iterable[Path]) -> List[str]:
    """A published artifact keeps its bytes: the same asset name with another
    digest anywhere in the published history is a conflict. Covers every asset,
    so a rebuilt AgentCore under a reused version cannot get past it."""
    published: Dict[str, Tuple[str, str]] = {}
    for sums_path in published_sums:
        for name, digest in parse_sums(sums_path.read_text(encoding="ascii")).items():
            known = published.get(name)
            if known is not None and known[0] != digest:
                raise CutError(f"{name} already differs between {known[1]} and {sums_path.name}; resolve that by hand before releasing")
            published[name] = (digest, sums_path.name)
    findings = []
    for path in assets_in(dist):
        known = published.get(path.name)
        if known is not None and known[0] != release_archive.sha256_file(path):
            findings.append(f"{path.name} is already published in {known[1]} with different contents; a published artifact is never replaced")
    return findings


def _check_agentcore_archive(path: Path, entry: contract.Release, expected_commit: Optional[str]) -> Tuple[dict, Dict[str, bytes], List[str]]:
    findings: List[str] = []
    suffix = ".zip" if path.name.endswith(".zip") else ".tar.gz"
    coordinate = path.name[: -len(suffix)]
    members = read_archive(path)
    manifest_bytes = members.get(f"{coordinate}/manifest.json")
    if manifest_bytes is None:
        return {}, members, [f"{path.name} has no manifest.json at its root"]
    manifest = json.loads(manifest_bytes.decode("utf-8"))

    def reader(rel: str) -> bytes:
        return members[f"{coordinate}/{rel}"]

    try:
        contract.check_bundle_contents(manifest, reader)
    except (CutError, KeyError) as exc:
        return manifest, members, [f"{path.name}: {exc}"]
    for item in manifest["files"]:
        data = members.get(f"{coordinate}/{item['path']}")
        if data is None or sha256_bytes(data) != item["sha256"]:
            findings.append(f"{path.name}: {item['path']} is not the file its manifest pins")
    if manifest["version"] != entry.version:
        findings.append(f"{path.name} carries version {manifest['version']}, but the ledger says AgentCore {entry.version}")
    if f"metask-agentcore-{manifest['version']}-{manifest['target']['id']}" != coordinate:
        findings.append(f"{path.name} does not match its manifest ({manifest['version']}, {manifest['target']['id']})")
    pinned = (manifest["contract"]["binary_abi_version"], manifest["contract"]["binary_abi_revision"])
    if pinned != (entry.abi_version, entry.abi_revision):
        findings.append(f"{path.name} implements ABI v{pinned[0]} revision {pinned[1]}, but the ledger maps AgentCore {entry.version} to v{entry.abi_version} revision {entry.abi_revision}")
    if manifest["source"]["dirty"] is not False:
        findings.append(f"{path.name} was built from a dirty tree")
    if expected_commit is not None and manifest["source"]["commit"] != expected_commit:
        findings.append(f"{path.name} was built from {manifest['source']['commit']}, but AgentCore {entry.version} is built by {entry.built_by} at {expected_commit}")
    return manifest, members, findings


def _library_digest(manifest: dict) -> str:
    shared = manifest["shared_library"]["path"]
    return next(item["sha256"] for item in manifest["files"] if item["path"] == shared)


def _check_wheel(path: Path, entry: contract.Release, libraries: Dict[str, str]) -> List[str]:
    expected = contract.python_version(entry.version)
    prefix = f"metacodes-{expected}-py3-none-"
    if not path.name.startswith(prefix) or not path.name.endswith(".whl"):
        return [f"{path.name} is not a wheel of AgentCore {entry.version} ({expected})"]
    tag = path.name[len(prefix) : -len(".whl")]
    members = read_archive(path)
    findings = []
    metadata = contract.text_of(members.get(f"metacodes-{expected}.dist-info/METADATA", b""))
    if f"\nVersion: {expected}\n" not in metadata:
        findings.append(f"{path.name}: METADATA does not say Version: {expected}")
    if f"\nTag: py3-none-{tag}\n" not in contract.text_of(members.get(f"metacodes-{expected}.dist-info/WHEEL", b"")):
        findings.append(f"{path.name}: WHEEL does not carry its tag {tag}")
    init = contract.PY_INIT_VERSION_RE.findall(contract.text_of(members.get("metacodes/__init__.py", b"")))
    if [item[1] for item in init] != [expected]:
        findings.append(f"{path.name}: metacodes.__version__ is not {expected}")
    native = contract.ABI_MIRRORS["sdk/python/src/metacodes/_native.py"].findall(contract.text_of(members.get("metacodes/_native.py", b"")))
    if native != [str(entry.abi_revision)]:
        findings.append(f"{path.name}: the binding speaks ABI revision {native}, but AgentCore {entry.version} is {entry.abi_revision}")
    findings.extend(_check_packaged_library(path.name, members, "metacodes/_lib/", libraries.get(tag), f"platform tag {tag}"))
    return findings


def _check_node(path: Path, entry: contract.Release, libraries: Dict[str, str]) -> List[str]:
    prefix = f"metacodes-node-{entry.version}-"
    if not path.name.startswith(prefix):
        return [f"{path.name} is not a Node package of AgentCore {entry.version}"]
    target_id = path.name[len(prefix) : -len(".tgz")]
    members = read_archive(path)
    findings = []
    try:
        declared = json.loads(members["package/package.json"].decode("utf-8"))["version"]
    except (KeyError, ValueError) as exc:
        return [f"{path.name}: no package version ({exc})"]
    if declared != contract.node_version(entry.version):
        findings.append(f"{path.name}: package.json says {declared}, but AgentCore is {entry.version}")
    binding = contract.ABI_MIRRORS["sdk/node/index.js"].findall(contract.text_of(members.get("package/index.js", b"")))
    if binding != [str(entry.abi_revision)]:
        findings.append(f"{path.name}: the binding speaks ABI revision {binding}, but AgentCore {entry.version} is {entry.abi_revision}")
    findings.extend(_check_packaged_library(path.name, members, "package/prebuilds/", libraries.get(target_id), f"target {target_id}"))
    return findings


def _check_packaged_library(asset: str, members: Dict[str, bytes], prefix: str, expected: Optional[str], label: str) -> List[str]:
    if expected is None:
        return [f"{asset}: no AgentCore archive in this release for {label}"]
    found = [data for name, data in members.items() if name.startswith(prefix) and re.search(r"(^|/)(lib)?metask_agentcore\.(so|dylib|dll)$", name)]
    if len(found) != 1:
        return [f"{asset}: expected one AgentCore library, found {len(found)}"]
    if sha256_bytes(found[0]) != expected:
        return [f"{asset}: its library is not the one in the AgentCore archive for {label}"]
    return []


def verify_dist(
    root: Path,
    dist: Path,
    main_version: str,
    commit_of: Callable[[str], Optional[str]],
    published_sums: Iterable[Path] = (),
    sdk_only: bool = False,
    platform_tag: Optional[Callable[[dict], str]] = None,
) -> List[str]:
    """Every deliverable of a formal release, read back from the files about to
    be drafted: no development identifier, one AgentCore version with one ABI
    across every archive and package, each package around the very library of its
    archive, the source the ledger names, and nothing that contradicts a published
    artifact. Returns the findings; `sdk_only` skips what only the main-project
    units provide (the rehearsal)."""
    findings = []
    if not contract.BARE_RE.match(main_version):
        return [f"main-project version {main_version!r} is not a final X.Y.Z; development builds are never drafted"]
    ledger = contract.load_ledger(root)
    entry = ledger.by_main_release(main_version)
    if entry is None:
        return [f"{contract.LEDGER} does not say which AgentCore main-project release {main_version} carries"]
    for rel, problem in ((contract.SDK_VERSION, contract.sdk_version(root) != entry.version), (contract.ABI_AUTHORITY, contract.abi_revision(root) != entry.abi_revision)):
        if problem:
            findings.append(f"{rel} disagrees with the ledger entry of AgentCore {entry.version}")
    findings.extend(contract.package_version_findings(root))
    if input_digest(root) != entry.input_digest:
        findings.append(f"this tree's AgentCore inputs differ from what {contract.LEDGER} records for {entry.version}")
    assets = assets_in(dist)
    for path in assets:
        if "-dev" in path.name or ".dev0" in path.name or "+" in path.name:
            findings.append(f"{path.name} carries a development version or a commit hash; a formal release does not")
    sdk_archives = [p for p in assets if p.name.startswith("metask-agentcore-")]
    if not sdk_archives:
        findings.append("this release has no AgentCore archive")
    expected_commit = commit_of(entry.built_by)
    if expected_commit is None:
        findings.append(f"no tag {entry.built_by}, the main release that builds AgentCore {entry.version}")
    tag_of = platform_tag or load_build_wheel().platform_tag
    wheel_libraries: Dict[str, str] = {}
    node_libraries: Dict[str, str] = {}
    sdk_targets = set()
    for path in sdk_archives:
        manifest, _, problems = _check_agentcore_archive(path, entry, expected_commit)
        findings.extend(problems)
        if not manifest or problems:
            continue
        sdk_targets.add(manifest["target"]["id"])
        wheel_libraries[tag_of(manifest["target"])] = _library_digest(manifest)
        node_libraries[manifest["target"]["id"]] = _library_digest(manifest)
    wheels = [p for p in assets if p.name.endswith(".whl")]
    nodes = [p for p in assets if p.name.startswith("metacodes-node-")]
    for path in wheels:
        findings.extend(_check_wheel(path, entry, wheel_libraries))
    for path in nodes:
        findings.extend(_check_node(path, entry, node_libraries))
    wheel_tags = {p.name[: -len(".whl")].rpartition("-")[2] for p in wheels}
    for tag in sorted(set(wheel_libraries) - wheel_tags):
        findings.append(f"this release has no Python wheel for {tag}")
    node_targets = {p.name[len(f"metacodes-node-{entry.version}-") : -len(".tgz")] for p in nodes}
    for target in sorted(t for t in sdk_targets - node_targets if "-windows-" not in t):
        findings.append(f"this release has no Node package for {target}")
    if not sdk_only:
        findings.extend(_check_main_units(assets, main_version, entry, sdk_targets))
    findings.extend(check_published(dist, published_sums))
    return findings


def _check_main_units(assets: Sequence[Path], main_version: str, entry: contract.Release, sdk_targets: Set[str]) -> List[str]:
    findings = []
    prefix = f"metacodes-{main_version}-"
    units = [p for p in assets if p.name.startswith(prefix) and p.name.endswith((".tar.gz", ".zip")) and not p.name.endswith("-debug.tar.gz")]
    if not units:
        findings.append(f"this release has no metacodes {main_version} unit")
    for path in units:
        coordinate = path.name[: -len(".zip" if path.name.endswith(".zip") else ".tar.gz")]
        target = coordinate[len(prefix) :]
        if target not in sdk_targets:
            findings.append(f"this release has no AgentCore archive for {target}")
        manifest_bytes = read_archive(path).get(f"{coordinate}/manifest.json")
        if manifest_bytes is None:
            findings.append(f"{path.name} has no manifest.json at its root")
            continue
        manifest = json.loads(manifest_bytes.decode("utf-8"))
        revision = (manifest.get("contract") or {}).get("binary_abi_revision")
        if revision != entry.abi_revision:
            findings.append(f"{path.name} states ABI revision {revision}, but it ships with AgentCore {entry.version} at {entry.abi_revision}")
    return findings


# ---------------------------------------------------------------- rehearsal


def rehearse(root: Path, target: str, work: Path, zig: str = "zig", optimize: str = "ReleaseSafe") -> str:
    """Prove the formal path on the real build without releasing anything: in a
    scratch worktree, finalize AgentCore as a cut would, commit and tag locally,
    build the stable archive through the real `agentcore:archive`, package the
    languages, and pass the door. Nothing leaves the scratch directory, and the
    worktree and the local tag are removed. Returns what happened: a tree that is
    already a release, or would reuse one, has nothing to build."""
    if not contract.is_dev(contract.sdk_version(root)):
        return f"nothing to rehearse: this tree already carries AgentCore {contract.sdk_version(root)}"
    tree = work / "tree"
    dist = work / "dist"
    main_version = main_version_of(root).replace("-dev", "")
    tagged = False
    common.run(["git", "worktree", "add", "--detach", "--quiet", str(tree), "HEAD"], root)
    try:
        plan = plan_cut(tree)
        if plan.kind != "built":
            return f"nothing to rehearse: this tree would reuse AgentCore {plan.version}"
        apply_cut(tree, plan.version, main_version, "2000-01-01")
        common.run(["git", "-c", "user.name=rehearsal", "-c", "user.email=rehearsal@metacodes.invalid", "commit", "-q", "-am", "rehearsal: formal AgentCore"], tree)
        common.run(["git", "tag", main_version], tree)
        tagged = True
        prefix = work / "sdk"
        subprocess.run(
            [zig, "build", "agentcore:archive", f"-Dtarget={target}", f"-Doptimize={optimize}", "--prefix", str(prefix), f"-Dagentcore-archive-dir={dist}"],
            cwd=str(tree),
            check=True,
        )
        package_languages(prefix, dist, node=os.name != "nt", formal=True, root=tree)
        findings = verify_dist(
            tree,
            dist,
            main_version,
            lambda tag: common.run(["git", "rev-parse", f"{tag}^{{commit}}"], tree).strip(),
            sdk_only=True,
        )
        if findings:
            raise CutError("the rehearsed release was refused:\n  " + "\n  ".join(findings))
        return f"rehearsed a formal AgentCore {plan.version} for {target}: {len(assets_in(dist))} deliverables passed"
    finally:
        subprocess.run(["git", "-C", str(root), "worktree", "remove", "--force", str(tree)], capture_output=True, check=False)
        if tagged:
            subprocess.run(["git", "-C", str(root), "tag", "-d", main_version], capture_output=True, check=False)


# ---------------------------------------------------------------- command line


def main_version_of(root: Path) -> str:
    match = common.ZON_VERSION_RE.search(common.read(root, common.ZON))
    if match is None:
        raise CutError(f"{common.ZON}: no .version declaration")
    return match.group(2)


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo-root", type=Path, default=ROOT)
    commands = parser.add_subparsers(dest="command", required=True)
    mode = commands.add_parser("release-mode", help="print the main release this one reuses AgentCore from, if any")
    mode.add_argument("--github-env", type=Path)
    package = commands.add_parser("package-languages")
    package.add_argument("--sdk-prefix", type=Path, required=True)
    package.add_argument("--dist", type=Path, required=True)
    package.add_argument("--node", action="store_true")
    fetch = commands.add_parser("fetch-reused")
    fetch.add_argument("--target", required=True)
    fetch.add_argument("--dist", type=Path, required=True)
    sums = commands.add_parser("fetch-published-sums")
    sums.add_argument("--out", type=Path, required=True)
    door = commands.add_parser("verify-dist")
    door.add_argument("--dist", type=Path, required=True)
    door.add_argument("--published-sums", type=Path)
    run_it = commands.add_parser("rehearse")
    run_it.add_argument("--target", required=True)
    run_it.add_argument("--work", type=Path, required=True)
    commands.add_parser("digest", help="print the AgentCore input digest of this tree")
    args = parser.parse_args(argv)
    root = args.repo_root
    try:
        if args.command == "digest":
            print(input_digest(root))
        elif args.command == "release-mode":
            source = release_mode(root, main_version_of(root))
            print(f"AGENTCORE_REUSE_FROM={source}")
            if args.github_env:
                with args.github_env.open("a", encoding="utf-8") as handle:
                    handle.write(f"AGENTCORE_REUSE_FROM={source}\n")
        elif args.command == "package-languages":
            args.dist.mkdir(parents=True, exist_ok=True)
            version = main_version_of(root)
            for path in package_languages(args.sdk_prefix, args.dist, args.node, formal=not version.endswith("-dev"), root=root):
                print(path)
        elif args.command == "fetch-reused":
            for path in fetch_reused(root, main_version_of(root), args.target, args.dist):
                print(path)
        elif args.command == "fetch-published-sums":
            for path in fetch_published_sums(args.out, main_version_of(root)):
                print(path)
        elif args.command == "verify-dist":
            published = sorted(args.published_sums.glob("*-SHA256SUMS")) if args.published_sums else []
            findings = verify_dist(
                root,
                args.dist,
                main_version_of(root),
                lambda tag: common.run(["git", "rev-parse", "--verify", "--quiet", f"{tag}^{{commit}}"], root, check=False).strip() or None,
                published,
            )
            if findings:
                for finding in findings:
                    print(f"agentcore_release: {finding}", file=sys.stderr)
                return 1
            print(f"{len(assets_in(args.dist))} deliverables are one consistent release")
        elif args.command == "rehearse":
            args.work.mkdir(parents=True, exist_ok=True)
            print(rehearse(root, args.target, args.work))
    except (CutError, OSError, subprocess.CalledProcessError, ValueError) as exc:
        print(f"agentcore_release: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
