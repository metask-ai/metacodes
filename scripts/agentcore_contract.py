#!/usr/bin/env python3
"""What one AgentCore release is: its version, its ledger entry, and the checks
a bundle must pass to be that release.

Design: doc/RELEASE_AUTOMATION_DESIGN.md §2a. AgentCore has its own SemVer
(`sdk/VERSION`, `X.Y.Z-dev` between releases and `X.Y.Z` on a release commit),
apart from the main project's. `sdk/agentcore-releases.json` is the ledger the
release cut appends to: the explicit mapping from a release version to the
binary ABI it implements, to a digest of the inputs it was built from, and to
the main-project releases that carry it. The ABI revision is read from
`sdk/zig/types.zig` at the cut and never written here by hand, so a later bump
needs no change to these scripts.

Everything here refuses with `CutError` (a ValueError). Python 3.9, stdlib only.
Tests: scripts/tests/test_agentcore_release.py.
"""
from __future__ import annotations

import json
import re
import sys
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Callable, Dict, List, Optional, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))
from release_common import CutError, fmt, read, write  # noqa: E402  (same directory, stdlib only)

SDK_VERSION = "sdk/VERSION"
PY_PROJECT = "sdk/python/pyproject.toml"
PY_INIT = "sdk/python/src/metacodes/__init__.py"
NODE_PACKAGE = "sdk/node/package.json"
SDK_CHANGELOG = "sdk/CHANGELOG.md"
LEDGER = "sdk/agentcore-releases.json"
# The files a cut or a reopen rewrites for AgentCore. release_fast_path.py
# regenerates each of them and compares bytes, so a new one belongs here.
GENERATED = (SDK_VERSION, PY_PROJECT, PY_INIT, NODE_PACKAGE, SDK_CHANGELOG, LEDGER)

LEDGER_SCHEMA = "metacodes.agentcore-releases/v1"
# `Migration` is what a Host must change. A release that moves the ABI revision
# has to fill it (agentcore_release.apply_cut).
SDK_SUBSECTIONS = ("Added", "Changed", "Deprecated", "Removed", "Fixed", "Security", "Migration")

# Every copy of the ABI revision a consumer can see. sdk/zig/types.zig is the
# authority; the others are mirrors, and a release refuses them disagreeing.
ABI_AUTHORITY = "sdk/zig/types.zig"
ABI_MIRRORS = {
    ABI_AUTHORITY: re.compile(r"^pub const ABI_REVISION: u32 = (\d+);$", re.M),
    "sdk/metask/agentcore.h": re.compile(r"^#define METASK_AGENTCORE_ABI_REVISION (\d+)u$", re.M),
    "sdk/rust/src/raw.rs": re.compile(r"^pub const METASK_AGENTCORE_ABI_REVISION: u32 = (\d+);$", re.M),
    "sdk/python/src/metacodes/_native.py": re.compile(r"^ABI_REVISION = (\d+)$", re.M),
    "sdk/node/index.js": re.compile(r"^const ABI_REVISION = (\d+);$", re.M),
}
ABI_VERSION_RE = re.compile(r"^pub const ABI_VERSION_V1: u32 = (\d+);$", re.M)

_BARE = r"(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)"
BARE_RE = re.compile(rf"^{_BARE}$")
SOURCE_VERSION_RE = re.compile(rf"^({_BARE})(-dev)?$")
# What `scripts/agentcore_manifest.zig` packageVersion produces.
BUILT_DEV_RE = re.compile(rf"^({_BARE})-dev\+([0-9a-f]{{12}})(\.dirty)?$")
PY_PROJECT_VERSION_RE = re.compile(r'^(version = ")([^"]+)(")$', re.M)
PY_INIT_VERSION_RE = re.compile(r'^(__version__ = ")([^"]+)(")$', re.M)
NODE_VERSION_RE = re.compile(r'^(  "version": ")([^"]+)(",?)$', re.M)
DIGEST_RE = re.compile(r"^[0-9a-f]{64}$")


# ---------------------------------------------------------------- versions


def parse(version: str) -> Tuple[int, int, int]:
    match = SOURCE_VERSION_RE.match(version)
    if match is None:
        raise CutError(f"not an AgentCore version: {version!r} (want X.Y.Z or X.Y.Z-dev)")
    return tuple(int(part) for part in match.group(1).split("."))  # type: ignore[return-value]


def is_dev(version: str) -> bool:
    parse(version)
    return version.endswith("-dev")


def python_version(version: str) -> str:
    """0.13.0-dev -> PEP 440 0.13.0.dev0; a release is itself."""
    return fmt(parse(version)) + (".dev0" if is_dev(version) else "")


def node_version(version: str) -> str:
    """0.13.0-dev -> 0.13.0-dev.0; a release is itself."""
    return fmt(parse(version)) + ("-dev.0" if is_dev(version) else "")


def base_of_built(version: str) -> Tuple[str, bool]:
    """(X.Y.Z, is_development) of a version as a bundle manifest carries it.
    Refuses every other shape: no release candidates, no local suffixes."""
    if BARE_RE.match(version):
        return version, False
    match = BUILT_DEV_RE.match(version)
    if match is None:
        raise CutError(f"bundle version {version!r} is neither a final X.Y.Z nor X.Y.Z-dev+<commit12>[.dirty]")
    return match.group(1), True


# ---------------------------------------------------------------- the source tree


def sdk_version(root: Path) -> str:
    text = read(root, SDK_VERSION).strip()
    parse(text)
    return text


def set_sdk_version(root: Path, version: str) -> None:
    """Write one AgentCore version to every package that declares it."""
    parse(version)
    for rel, pattern, value in (
        (PY_PROJECT, PY_PROJECT_VERSION_RE, python_version(version)),
        (PY_INIT, PY_INIT_VERSION_RE, python_version(version)),
        (NODE_PACKAGE, NODE_VERSION_RE, node_version(version)),
    ):
        text, count = pattern.subn(lambda m: m.group(1) + value + m.group(3), read(root, rel))
        if count != 1:
            raise CutError(f"{rel}: expected exactly one version declaration, found {count}")
        write(root, rel, text)
    write(root, SDK_VERSION, version + "\n")


def package_version_findings(root: Path) -> List[str]:
    version = sdk_version(root)
    findings = []
    for rel, pattern, expected in (
        (PY_PROJECT, PY_PROJECT_VERSION_RE, python_version(version)),
        (PY_INIT, PY_INIT_VERSION_RE, python_version(version)),
        (NODE_PACKAGE, NODE_VERSION_RE, node_version(version)),
    ):
        found = [m.group(2) for m in pattern.finditer(read(root, rel))]
        if found != [expected]:
            findings.append(f"{rel} declares {found or 'no version'}, but {SDK_VERSION} {version} means {expected}")
    return findings


def abi_revisions(root: Path) -> Dict[str, int]:
    """The ABI revision each SDK file declares. Refuses a file that no longer
    declares one, so a reworded declaration cannot drop out of the check."""
    found = {}
    for rel, pattern in ABI_MIRRORS.items():
        match = pattern.search(read(root, rel))
        if match is None:
            raise CutError(f"{rel} no longer declares the ABI revision")
        found[rel] = int(match.group(1))
    return found


def abi_revision(root: Path) -> int:
    """The current revision, after every mirror agreed with the authority."""
    found = abi_revisions(root)
    expected = found[ABI_AUTHORITY]
    wrong = {rel: value for rel, value in found.items() if value != expected}
    if wrong:
        raise CutError(f"ABI revision mismatch: {ABI_AUTHORITY} says {expected}, but {wrong}")
    return expected


def abi_version(root: Path) -> int:
    match = ABI_VERSION_RE.search(read(root, ABI_AUTHORITY))
    if match is None:
        raise CutError(f"{ABI_AUTHORITY} no longer declares ABI_VERSION_V1")
    return int(match.group(1))


# ---------------------------------------------------------------- the ledger


@dataclass(frozen=True)
class Release:
    """One AgentCore release. It is built once, for `main_releases[0]`; every
    later main release in the tuple reuses those artifacts byte for byte."""

    version: str
    abi_version: int
    abi_revision: int
    input_digest: str
    main_releases: Tuple[str, ...]

    @property
    def built_by(self) -> str:
        return self.main_releases[0]


@dataclass(frozen=True)
class Ledger:
    releases: Tuple[Release, ...] = ()

    @property
    def latest(self) -> Optional[Release]:
        return self.releases[-1] if self.releases else None

    def by_version(self, version: str) -> Optional[Release]:
        return next((r for r in self.releases if r.version == version), None)

    def by_main_release(self, main_version: str) -> Optional[Release]:
        return next((r for r in self.releases if main_version in r.main_releases), None)

    def carrying(self, release: Release, main_version: str) -> "Ledger":
        """This ledger with `main_version` added to `release`, its latest."""
        if self.latest != release:
            raise CutError(f"only the latest AgentCore release can be reused, not {release.version}")
        updated = replace(release, main_releases=release.main_releases + (main_version,))
        return validated(Ledger(self.releases[:-1] + (updated,)))

    def appended(self, release: Release) -> "Ledger":
        return validated(Ledger(self.releases + (release,)))


def minor_or_major_apart(older: str, newer: str) -> bool:
    return parse(newer)[:2] > parse(older)[:2]


def validated(ledger: Ledger) -> Ledger:
    """The ledger's own rules: each one holds of every prefix, so a cut that
    appends can only produce a valid ledger."""
    previous: Optional[Release] = None
    last_main: Optional[Tuple[int, int, int]] = None
    digests = set()
    for entry in ledger.releases:
        if not BARE_RE.match(entry.version):
            raise CutError(f"{LEDGER}: {entry.version!r} is not a final X.Y.Z")
        if type(entry.abi_version) is not int or entry.abi_version < 1 or type(entry.abi_revision) is not int or entry.abi_revision < 1:
            raise CutError(f"{LEDGER}: {entry.version} has no valid ABI version and revision")
        if not isinstance(entry.input_digest, str) or not DIGEST_RE.match(entry.input_digest):
            raise CutError(f"{LEDGER}: {entry.version} has no valid input digest")
        if entry.input_digest in digests:
            raise CutError(f"{LEDGER}: {entry.version} has the input digest of an earlier release; unchanged AgentCore keeps its version")
        digests.add(entry.input_digest)
        if not entry.main_releases:
            raise CutError(f"{LEDGER}: {entry.version} names no main-project release")
        for main in entry.main_releases:
            if not isinstance(main, str) or not BARE_RE.match(main):
                raise CutError(f"{LEDGER}: {entry.version} names main-project release {main!r}, not a final X.Y.Z")
            parts = parse(main)
            if last_main is not None and parts <= last_main:
                raise CutError(f"{LEDGER}: main-project release {main} is out of order under {entry.version}")
            last_main = parts
        if previous is not None:
            if parse(entry.version) <= parse(previous.version):
                raise CutError(f"{LEDGER}: {entry.version} does not follow {previous.version}")
            if (entry.abi_version, entry.abi_revision) < (previous.abi_version, previous.abi_revision):
                raise CutError(f"{LEDGER}: {entry.version} lowers the ABI revision of {previous.version}")
            if (entry.abi_version, entry.abi_revision) != (previous.abi_version, previous.abi_revision) and not minor_or_major_apart(previous.version, entry.version):
                raise CutError(
                    f"{LEDGER}: {previous.version} -> {entry.version} moves the ABI revision "
                    f"({previous.abi_revision} -> {entry.abi_revision}), which needs at least a minor version"
                )
        previous = entry
    return ledger


def parse_ledger(text: str) -> Ledger:
    try:
        data = json.loads(text)
    except json.JSONDecodeError as exc:
        raise CutError(f"{LEDGER}: not JSON: {exc}") from None
    if not isinstance(data, dict) or data.get("schema") != LEDGER_SCHEMA or set(data) != {"schema", "releases"} or not isinstance(data["releases"], list):
        raise CutError(f"{LEDGER}: expected schema {LEDGER_SCHEMA} with a releases array")
    keys = {"version", "abi_version", "abi_revision", "input_digest", "main_releases"}
    releases = []
    for item in data["releases"]:
        if not isinstance(item, dict) or set(item) != keys or not isinstance(item["main_releases"], list):
            raise CutError(f"{LEDGER}: an entry must have exactly {sorted(keys)}")
        releases.append(
            Release(item["version"], item["abi_version"], item["abi_revision"], item["input_digest"], tuple(item["main_releases"]))
        )
    return validated(Ledger(tuple(releases)))


def dump_ledger(ledger: Ledger) -> str:
    return (
        json.dumps(
            {
                "schema": LEDGER_SCHEMA,
                "releases": [
                    {
                        "version": r.version,
                        "abi_version": r.abi_version,
                        "abi_revision": r.abi_revision,
                        "input_digest": r.input_digest,
                        "main_releases": list(r.main_releases),
                    }
                    for r in ledger.releases
                ],
            },
            indent=2,
        )
        + "\n"
    )


def load_ledger(root: Path) -> Ledger:
    return parse_ledger(read(root, LEDGER))


def is_prefix_of(older: Ledger, newer: Ledger) -> Optional[str]:
    """The ledger only grows: a finding when `newer` rewrote history in `older`.
    The last entry of `older` may gain main-project releases (a reuse)."""
    if len(newer.releases) < len(older.releases):
        return f"{LEDGER} dropped a release"
    for index, (old, new) in enumerate(zip(older.releases, newer.releases)):
        last = index == len(older.releases) - 1
        same_identity = replace(old, main_releases=()) == replace(new, main_releases=())
        if not same_identity or (new.main_releases[: len(old.main_releases)] != old.main_releases if last else new.main_releases != old.main_releases):
            return f"{LEDGER} changed the released entry {old.version}"
    return None


# ---------------------------------------------------------------- bundles

Reader = Callable[[str], bytes]


def text_of(data: bytes) -> str:
    """A packaged text file. A Windows checkout installs the SDK files with CRLF,
    and the declarations are matched line by line."""
    return data.decode("utf-8").replace("\r\n", "\n")


def _single(pattern: "re.Pattern[str]", text: str, label: str) -> str:
    found = pattern.findall(text)
    if len(found) != 1:
        raise CutError(f"bundle {label}: expected one declaration, found {len(found)}")
    return found[0]


def check_bundle_contents(manifest: dict, reader: Reader) -> None:
    """A bundle's manifest, header, bindings and generated documents describe
    one AgentCore release. `reader` returns a bundle member's bytes, whether the
    bundle is a directory or an archive being checked at the door."""
    try:
        version = manifest["version"]
        contract = manifest["contract"]
        revision = contract["binary_abi_revision"]
        source = manifest["source"]
        commit = source["commit"]
        dirty = source["dirty"]
        shared = manifest["shared_library"]["path"]
        listed = {entry["path"] for entry in manifest["files"]}
    except (KeyError, TypeError) as exc:
        raise CutError(f"bundle manifest lacks {exc}") from None
    if not isinstance(version, str):
        raise CutError("bundle manifest version is not a string")
    _, development = base_of_built(version)
    if development:
        built = BUILT_DEV_RE.match(version)
        if not isinstance(commit, str) or not commit.startswith(built.group(2)):
            raise CutError(f"bundle version {version} does not name its source commit {commit}")
        if bool(built.group(3)) != (dirty is True):
            raise CutError(f"bundle version {version} disagrees with source.dirty={dirty!r}")
    if shared not in listed:
        raise CutError(f"bundle shared library {shared} is not pinned in manifest files")

    def text(rel: str) -> str:
        if rel not in listed:
            raise CutError(f"bundle manifest does not list {rel}")
        return text_of(reader(rel))

    for rel, pattern in (
        ("include/metask/agentcore.h", ABI_MIRRORS["sdk/metask/agentcore.h"]),
        ("bindings/zig/src/types.zig", ABI_MIRRORS[ABI_AUTHORITY]),
        ("bindings/rust/src/raw.rs", ABI_MIRRORS["sdk/rust/src/raw.rs"]),
    ):
        declared = int(_single(pattern, text(rel), rel))
        if declared != revision:
            raise CutError(f"ABI revision mismatch: bundle manifest says {revision}, {rel} says {declared}")
    for rel, pattern in (
        ("bindings/zig/build.zig.zon", re.compile(r'^\s*\.version = "([^"]+)",$', re.M)),
        ("bindings/rust/Cargo.toml", re.compile(r'^version = "([^"]+)"$', re.M)),
        ("bindings/rust/Cargo.lock", re.compile(r'^version = "([^"]+)"$', re.M)),
    ):
        declared = _single(pattern, text(rel), rel)
        if declared != version:
            raise CutError(f"version mismatch: bundle manifest says {version}, {rel} says {declared}")
    readme = text("README.md")
    if not readme.startswith(f"# metask-agentcore {version}\n"):
        raise CutError(f"bundle README.md does not name version {version}")
    stated = {int(n) for n in re.findall(r"\bRevision (\d+)\b", readme)}
    if stated != {revision}:
        raise CutError(f"bundle README.md describes ABI revision {sorted(stated)}, but the manifest says {revision}")


def correspondence_findings(manifest: dict, root: Path) -> List[str]:
    """What a language package needs of its bundle: the package version and the
    ABI its sources speak come from the checkout, the library from the bundle,
    and the two must be one AgentCore release."""
    version = sdk_version(root)
    base, development = base_of_built(manifest.get("version", ""))
    findings = []
    if base != fmt(parse(version)) or development != is_dev(version):
        findings.append(f"the bundle is AgentCore {manifest['version']}, but this checkout is {version} ({SDK_VERSION})")
    found = abi_revisions(root)
    revision = (manifest.get("contract") or {}).get("binary_abi_revision")
    wrong = {rel: value for rel, value in found.items() if value != revision}
    if wrong:
        findings.append(f"the bundle implements ABI revision {revision}, but this checkout's bindings declare {wrong}")
    return findings
