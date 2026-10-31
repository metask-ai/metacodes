#!/usr/bin/env python3
"""Create one immutable release archive and its SHA-256 sidecar (#81).

The archive core `package_agentcore.py` grew for the AgentCore SDK — sanitized
tar members, epoch-dated zip entries, the manifest whitelist as the only source
of members, a `.sha256` sidecar — serves both release units; `--kind` picks the
manifest identity:

  agentcore  `metask-agentcore-<version>-<target-id>` from the SDK bundle manifest
  cli        `metacodes-<version>-<target-id>`        from the CLI release manifest
             (release/manifest.schema.json)
  symbols    `metacodes-<version>-<target-id>-debug`  a Linux CLI unit's debug
             symbols (`--debug-file`, from `-Drelease-symbols`), held as
             `bin/metacodes.debug`. The unit's `bin/metacodes` must name it:
             the same GNU build ID, and a `.gnu_debuglink` whose file name
             and CRC-32 match. The symbols are never part of the unit itself.

Channels gate what may be archived (#47 Q1/Q3): a pre-release version
(`X.Y.Z-<pre>+<commit12>`) archives from any commit that is not itself a release;
a stable version requires a clean source tree and a tag. For the CLI that is the
bare `X.Y.Z` tag on HEAD. AgentCore has its own version and no tag of its own
(`0.13.0` may one day name a main-project release): a stable SDK archive requires
the main-project tag on HEAD, HEAD at `manifest.source.commit`, and the ledger
(`sdk/agentcore-releases.json`) saying this main release is the one that builds
this AgentCore version. A later main release reuses those artifacts instead, so
it cannot produce a second, different archive under the same version.
Every AgentCore archive also passes `agentcore_contract.check_bundle_contents`.

Two runs over the same bundle produce byte-identical archives: no timestamps,
owners or host names enter the members. Python 3.9, stdlib only; `--self-test`
covers both kinds, the gate, and reproducibility.
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zipfile
import zlib
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

SAFE_COORDINATE = re.compile(r"^[0-9A-Za-z._+-]+$")
ZIP_EPOCH = (1980, 1, 1, 0, 0, 0)
ZIP_COMPRESSION_LEVEL = 9
KINDS = ("agentcore", "cli")

sys.path.insert(0, str(Path(__file__).resolve().parent))
import agentcore_contract  # noqa: E402  (same directory, stdlib only)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sanitized_tar_info(info: tarfile.TarInfo) -> tarfile.TarInfo:
    """Remove build-host identity and timestamps from a tar member."""
    info.uid = 0
    info.gid = 0
    info.uname = ""
    info.gname = ""
    info.mtime = 0
    info.pax_headers = {}
    return info


def write_zip_file(archive: zipfile.ZipFile, source: Path, archive_name: str) -> None:
    """Write a regular file without copying its host timestamp into the zip."""
    info = zipfile.ZipInfo(archive_name, date_time=ZIP_EPOCH)
    archive.writestr(
        info,
        source.read_bytes(),
        compress_type=zipfile.ZIP_DEFLATED,
        compresslevel=ZIP_COMPRESSION_LEVEL,
    )


@dataclass(frozen=True)
class GitFacts:
    """What the channel gate asks of the repository; tests build it directly."""

    head_tag: str | None
    head_commit: str | None = None
    # The main-project release the ledger says builds this AgentCore version.
    agentcore_built_by: str | None = None


def collect_git_facts(repo_root: Path, agentcore_version: str | None = None) -> GitFacts:
    def git(*argv: str) -> str | None:
        completed = subprocess.run(
            ["git", "-C", str(repo_root), *argv],
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
        if completed.returncode != 0:
            return None
        return completed.stdout.strip() or None

    built_by = None
    if agentcore_version is not None:
        entry = agentcore_contract.load_ledger(repo_root).by_version(agentcore_version)
        built_by = None if entry is None else entry.built_by
    return GitFacts(
        head_tag=git("describe", "--tags", "--exact-match", "HEAD"),
        head_commit=git("rev-parse", "HEAD"),
        agentcore_built_by=built_by,
    )


@dataclass(frozen=True)
class Bundle:
    manifest: dict
    kind: str
    version: str
    channel: str
    target_os: str
    coordinate: str
    archive_paths: tuple[str, ...]


def load_bundle(bundle_root: Path, kind: str) -> Bundle:
    if kind not in KINDS:
        raise ValueError(f"unknown archive kind: {kind}")
    if not bundle_root.is_dir():
        raise ValueError(f"bundle root is not a directory: {bundle_root}")
    manifest_path = bundle_root / "manifest.json"
    if manifest_path.is_symlink() or not manifest_path.is_file():
        raise ValueError("manifest.json is not a regular file")
    label = "AgentCore" if kind == "agentcore" else "metacodes CLI"
    expected_name = "agentcore" if kind == "agentcore" else "metacodes-cli"
    # The CLI unit is manifest v2 since it ships the TinyKG daemon and the Lean
    # kernels (release/LAYOUT.md); the AgentCore unit is still v1.
    expected_schema = 1 if kind == "agentcore" else 2
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        schema_version = manifest["schema_version"]
        vendor = manifest["vendor"]
        name = manifest["name"]
    except (OSError, KeyError, TypeError, json.JSONDecodeError) as error:
        raise ValueError(f"invalid {kind} manifest: {error}") from error
    # Identity before shape: a manifest of the other unit is refused by name,
    # not by whichever field it happens to lack.
    if schema_version != expected_schema or vendor != "metask" or name != expected_name:
        raise ValueError(f"manifest is not metask {label} schema {expected_schema}")
    try:
        target_id = manifest["target"]["id"]
        target_os = manifest["target"]["os"]
        files = manifest["files"]
        if kind == "agentcore":
            version = manifest["version"]
            channel = "pre" if "-" in version.partition("+")[0] else "stable"
            coordinate_prefix = "metask-agentcore"
        else:
            version = manifest["release"]["version"]
            channel = manifest["release"]["channel"]
            coordinate_prefix = "metacodes"
    except (KeyError, TypeError) as error:
        raise ValueError(f"invalid {kind} manifest: {error}") from error

    if channel not in ("stable", "pre"):
        raise ValueError(f"manifest channel is not stable or pre: {channel!r}")
    for field_name, value in (("version", version), ("target.id", target_id)):
        if not isinstance(value, str) or not SAFE_COORDINATE.fullmatch(value):
            raise ValueError(f"manifest {field_name} is not archive-name safe")
    if target_os not in ("windows", "linux", "macos"):
        raise ValueError(f"unsupported archive OS: {target_os}")
    if not isinstance(files, list):
        raise ValueError("manifest files must be an array")

    expected_paths = {"manifest.json"}
    for entry in files:
        try:
            relative_text = entry["path"]
            expected_hash = entry["sha256"]
        except (KeyError, TypeError) as error:
            raise ValueError("invalid manifest file entry") from error
        if not isinstance(relative_text, str) or not isinstance(expected_hash, str):
            raise ValueError("invalid manifest file entry")
        relative = PurePosixPath(relative_text)
        if (
            relative.is_absolute()
            or ".." in relative.parts
            or "\\" in relative_text
            or ":" in relative_text
            or relative_text != relative.as_posix()
        ):
            raise ValueError(f"unsafe manifest path: {relative_text}")
        payload = bundle_root
        for part in relative.parts:
            payload /= part
            if payload.is_symlink():
                raise ValueError(f"manifest payload traverses a symlink: {relative_text}")
        if not payload.is_file():
            raise ValueError(f"manifest payload is not a regular file: {relative_text}")
        if sha256_file(payload) != expected_hash:
            raise ValueError(f"manifest SHA-256 mismatch: {relative_text}")
        if relative_text in expected_paths:
            raise ValueError(f"duplicate manifest path: {relative_text}")
        expected_paths.add(relative_text)

    return Bundle(
        manifest=manifest,
        kind=kind,
        version=version,
        channel=channel,
        target_os=target_os,
        coordinate=f"{coordinate_prefix}-{version}-{target_id}",
        archive_paths=tuple(sorted(expected_paths)),
    )


def enforce_channel(bundle: Bundle, git_facts: GitFacts | None) -> None:
    """A pre-release archives from any commit but a release; a stable one only
    from a clean, tagged tree."""
    if bundle.channel == "pre":
        head_tag = None if git_facts is None else git_facts.head_tag
        if bundle.kind == "agentcore" and head_tag is not None and agentcore_contract.BARE_RE.match(head_tag):
            raise ValueError(
                f"AgentCore development version {bundle.version} on release tag {head_tag}: "
                "a formal release carries a final AgentCore version (scripts/release_cut.py finalizes it)"
            )
        return
    source = bundle.manifest.get("source") or {}
    dirty = source.get("dirty")
    commit = source.get("commit")
    head_tag = None if git_facts is None else git_facts.head_tag
    if bundle.kind == "agentcore":
        head_commit = None if git_facts is None else git_facts.head_commit
        built_by = None if git_facts is None else git_facts.agentcore_built_by
        if dirty is not False or not isinstance(commit, str) or commit != head_commit:
            raise ValueError(
                f"stable AgentCore archives require a clean source tree at the manifest's commit "
                f"(tree dirty={dirty!r}, manifest commit={commit!r}, HEAD={head_commit!r})"
            )
        if head_tag is None or not agentcore_contract.BARE_RE.match(head_tag):
            raise ValueError(f"stable AgentCore {bundle.version} archives only from a tagged main-project release (HEAD tag={head_tag!r})")
        if built_by != head_tag:
            raise ValueError(
                f"AgentCore {bundle.version} is built by main-project release {built_by!r} according to "
                f"{agentcore_contract.LEDGER}, not by {head_tag}: same version, same artifacts, so reuse them"
            )
        return
    if dirty is not False or head_tag != bundle.version:
        raise ValueError(
            f"stable metacodes archives require a clean source tree tagged {bundle.version} "
            f"(tree dirty={dirty!r}, HEAD tag={head_tag!r})"
        )


def write_archive(bundle_root: Path, output_dir: Path, kind: str, git_facts: GitFacts | None) -> tuple[Path, Path]:
    bundle_root = bundle_root.resolve()
    output_dir = output_dir.resolve()
    if output_dir == bundle_root or bundle_root in output_dir.parents:
        raise ValueError("archive output directory must not be inside the bundle root")
    bundle = load_bundle(bundle_root, kind)
    if kind == "agentcore":
        agentcore_contract.check_bundle_contents(
            bundle.manifest,
            lambda relative: bundle_root.joinpath(*PurePosixPath(relative).parts).read_bytes(),
        )
    enforce_channel(bundle, git_facts)
    members = [(bundle_root.joinpath(*PurePosixPath(relative).parts), relative) for relative in bundle.archive_paths]
    return write_immutable(output_dir, bundle.coordinate, members, as_zip=bundle.target_os == "windows")


# ── Debug symbols (`--kind symbols`) ─────────────────────────────────────────


def elf_sections(path: Path) -> dict[str, bytes]:
    """Section name -> contents of a 64-bit little-endian ELF file (both Linux
    release targets are)."""
    data = path.read_bytes()
    if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        raise ValueError(f"not a 64-bit little-endian ELF file: {path.name}")
    shoff, = struct.unpack_from("<Q", data, 0x28)
    shentsize, shnum, shstrndx = struct.unpack_from("<HHH", data, 0x3A)
    headers = [struct.unpack_from("<IIQQQQ", data, shoff + i * shentsize) for i in range(shnum)]
    names = headers[shstrndx]
    sections = {}
    for name_offset, sh_type, _, _, offset, size in headers:
        start = names[4] + name_offset
        name = data[start:data.index(b"\0", start)].decode("ascii", "replace")
        sections[name] = b"" if sh_type == 8 else data[offset:offset + size]  # SHT_NOBITS
    return sections


def gnu_build_id(sections: dict[str, bytes], label: str) -> str:
    note = sections.get(".note.gnu.build-id")
    if note is None or len(note) < 16:
        raise ValueError(f"{label} carries no GNU build ID")
    namesz, descsz, note_type = struct.unpack_from("<III", note, 0)
    name_end = 12 + ((namesz + 3) & ~3)
    if note_type != 3 or note[12:12 + namesz] != b"GNU\0":
        raise ValueError(f"{label} carries no GNU build ID")
    return note[name_end:name_end + descsz].hex()


def write_symbols_archive(bundle_root: Path, debug_file: Path, output_dir: Path, git_facts: GitFacts | None) -> tuple[Path, Path]:
    """`metacodes-<version>-<target-id>-debug.tar.gz` holding the unit's
    `bin/metacodes.debug`, refused unless the unit's executable names that
    exact file (build ID, and .gnu_debuglink name and CRC-32)."""
    bundle_root = bundle_root.resolve()
    output_dir = output_dir.resolve()
    if output_dir == bundle_root or bundle_root in output_dir.parents:
        raise ValueError("archive output directory must not be inside the bundle root")
    bundle = load_bundle(bundle_root, "cli")
    if bundle.target_os != "linux":
        raise ValueError(f"debug symbols are archived for Linux units only, not {bundle.target_os}")
    enforce_channel(bundle, git_facts)
    executable = bundle_root / "bin" / "metacodes"
    exe_sections = elf_sections(executable)
    debug_sections = elf_sections(debug_file)
    if any(name.startswith(".debug_") for name in exe_sections):
        raise ValueError("bin/metacodes still carries DWARF; the unit must ship the stripped executable")
    if ".debug_info" not in debug_sections:
        raise ValueError(f"{debug_file.name} carries no .debug_info")
    exe_id = gnu_build_id(exe_sections, "bin/metacodes")
    debug_id = gnu_build_id(debug_sections, debug_file.name)
    if exe_id != debug_id:
        raise ValueError(f"build ID mismatch: bin/metacodes {exe_id}, {debug_file.name} {debug_id}")
    link = exe_sections.get(".gnu_debuglink")
    if link is None:
        raise ValueError("bin/metacodes has no .gnu_debuglink")
    link_name = link[:link.index(b"\0")].decode("ascii", "replace")
    link_crc, = struct.unpack_from("<I", link, len(link) - 4)
    if link_name != "metacodes.debug":
        raise ValueError(f"bin/metacodes links to {link_name!r}, not metacodes.debug")
    actual_crc = zlib.crc32(debug_file.read_bytes()) & 0xFFFFFFFF
    if link_crc != actual_crc:
        raise ValueError(f"{debug_file.name} CRC-32 {actual_crc:08x} is not the {link_crc:08x} bin/metacodes links to")
    return write_immutable(output_dir, f"{bundle.coordinate}-debug", [(debug_file, "bin/metacodes.debug")], as_zip=False)


def write_immutable(output_dir: Path, coordinate: str, members: list[tuple[Path, str]], as_zip: bool) -> tuple[Path, Path]:
    """`<coordinate>.zip|.tar.gz` holding each (file, path) under
    `<coordinate>/`, plus its `.sha256` sidecar; never replaced once written."""
    output_dir.mkdir(parents=True, exist_ok=True)
    archive_path = output_dir / f"{coordinate}{'.zip' if as_zip else '.tar.gz'}"
    checksum_path = output_dir / f"{archive_path.name}.sha256"

    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{coordinate}.", suffix=".tmp", dir=output_dir)
    os.close(descriptor)
    temporary = Path(temporary_name)
    try:
        if as_zip:
            with zipfile.ZipFile(temporary, "w", zipfile.ZIP_DEFLATED, compresslevel=ZIP_COMPRESSION_LEVEL) as archive:
                for path, relative in members:
                    write_zip_file(archive, path, f"{coordinate}/{relative}")
        else:
            # A gzip header carries a file name and an mtime; `tarfile`'s "w:gz"
            # would write the temporary's name and the current time, and two
            # runs would differ. Fixed empty name, epoch mtime.
            with temporary.open("wb") as raw, gzip.GzipFile(
                filename="", mode="wb", fileobj=raw, mtime=0, compresslevel=ZIP_COMPRESSION_LEVEL
            ) as compressed, tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as archive:
                for path, relative in members:
                    archive.add(path, arcname=f"{coordinate}/{relative}", recursive=False, filter=sanitized_tar_info)

        digest = sha256_file(temporary)
        if archive_path.exists() or checksum_path.exists():
            # Immutable, not merely write-once: the build graph re-runs this
            # step (release:sums depends on it), so an existing archive is
            # accepted when it is byte-identical to what would be written now
            # — a reproducibility check for free — and never replaced.
            expected_sidecar = f"{digest}  {archive_path.name}\n"
            if (
                archive_path.is_file()
                and checksum_path.is_file()
                and sha256_file(archive_path) == digest
                and checksum_path.read_text(encoding="ascii") == expected_sidecar
            ):
                return archive_path, checksum_path
            raise FileExistsError(f"archive coordinate already exists with different bytes: {coordinate}")
        archive_created = False
        checksum_created = False
        try:
            with archive_path.open("xb") as destination, temporary.open("rb") as source:
                archive_created = True
                shutil.copyfileobj(source, destination, 1024 * 1024)
            with checksum_path.open("x", encoding="ascii", newline="\n") as checksum:
                checksum_created = True
                checksum.write(f"{digest}  {archive_path.name}\n")
        except BaseException:
            if archive_created:
                archive_path.unlink(missing_ok=True)
            if checksum_created:
                checksum_path.unlink(missing_ok=True)
            raise
    finally:
        temporary.unlink(missing_ok=True)
    return archive_path, checksum_path


# ── self-test ─────────────────────────────────────────────────────────────────

COMMIT = "0123456789abcdef0123456789abcdef01234567"


def _sdk_fixture(root: Path, target_os: str, target_id: str, version: str = "0.1.0-dev+0123456789ab", revision: int = 26,
                 commit: str = COMMIT, overrides: dict[str, str] | None = None, architecture: str = "x86_64", abi: str = "gnu") -> Path:
    """A bundle whose every member describes one release; `overrides` replaces a
    member's text afterwards, with the manifest digest following it, so a test
    states exactly which file disagrees."""
    bundle = root / "sdk-bundle"
    library = "metask_agentcore.dll" if target_os == "windows" else "libmetask_agentcore.so"
    members = {
        "include/metask/agentcore.h": f"#define METASK_AGENTCORE_ABI_REVISION {revision}u\n",
        "bindings/zig/src/types.zig": f"pub const ABI_REVISION: u32 = {revision};\n",
        "bindings/rust/src/raw.rs": f"pub const METASK_AGENTCORE_ABI_REVISION: u32 = {revision};\n",
        "bindings/zig/build.zig.zon": f'.{{\n    .version = "{version}",\n}}\n',
        "bindings/rust/Cargo.toml": f'[package]\nversion = "{version}"\n',
        "bindings/rust/Cargo.lock": f'version = 4\n\n[[package]]\nversion = "{version}"\n',
        "README.md": f"# metask-agentcore {version}\n\nRevision {revision} exposes the tables.\n",
        f"lib/{library}": f"library {version} {target_id}\n",
    }
    members.update(overrides or {})
    files = []
    for relative, text in members.items():
        payload = bundle.joinpath(*PurePosixPath(relative).parts)
        payload.parent.mkdir(parents=True, exist_ok=True)
        payload.write_bytes(text.encode("utf-8"))
        files.append({"path": relative, "sha256": sha256_file(payload)})
    manifest = {
        "schema_version": 1,
        "vendor": "metask",
        "name": "agentcore",
        "version": version,
        "source": {"commit": commit, "dirty": False},
        "target": {"id": target_id, "os": target_os, "architecture": architecture, "abi": abi, "zig_target": target_id},
        "contract": {"binary_abi_version": 1, "binary_abi_revision": revision},
        "shared_library": {"path": f"lib/{library}"},
        "files": files,
    }
    (bundle / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
    return bundle


def _cli_fixture(root: Path, target_os: str, target_id: str, version: str, channel: str, dirty: bool = False,
                 executable_bytes: bytes = b"metacodes") -> Path:
    bundle = root / "cli-bundle"
    executable = bundle / "bin" / ("metacodes.exe" if target_os == "windows" else "metacodes")
    executable.parent.mkdir(parents=True)
    executable.write_bytes(executable_bytes)
    manifest = {
        "schema_version": 2,
        "vendor": "metask",
        "name": "metacodes-cli",
        "release": {"version": version, "channel": channel, "tag": version if channel == "stable" else None},
        "source": {"commit": COMMIT, "dirty": dirty},
        "target": {"id": target_id, "os": target_os},
        "files": [{"path": f"bin/{executable.name}", "sha256": sha256_file(executable)}],
    }
    (bundle / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
    return bundle


def _elf(sections: dict[str, bytes]) -> bytes:
    """A 64-bit little-endian ELF holding exactly `sections` (plus the null
    section and .shstrtab), enough for elf_sections()."""
    names = list(sections) + [".shstrtab"]
    shstrtab = b"\0" + b"".join(name.encode() + b"\0" for name in names)
    offsets, cursor, body = [], 64, b""
    for name in names:
        content = shstrtab if name == ".shstrtab" else sections[name]
        offsets.append((cursor + len(body), len(content)))
        body += content
    shoff = 64 + len(body)
    headers = struct.pack("<IIQQQQIIQQ", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    name_offset = 1
    for name, (offset, size) in zip(names, offsets):
        headers += struct.pack("<IIQQQQIIQQ", name_offset, 3 if name == ".shstrtab" else 1, 0, 0, offset, size, 0, 0, 1, 0)
        name_offset += len(name) + 1
    ident = b"\x7fELF" + bytes([2, 1, 1]) + bytes(9)
    header = ident + struct.pack("<HHIQQQIHHHHHH", 2, 62, 1, 0, 0, shoff, 0, 64, 0, 0, 64, len(names) + 1, len(names))
    return header + body + headers


def _build_id_note(build_id: bytes) -> bytes:
    return struct.pack("<III", 4, len(build_id), 3) + b"GNU\0" + build_id


def _debuglink(name: str, crc: int) -> bytes:
    encoded = name.encode() + b"\0"
    encoded += b"\0" * (-len(encoded) % 4)
    return encoded + struct.pack("<I", crc)


def _symbols_fixture(root: Path, target_os: str = "linux", channel: str = "pre", version: str = "0.2.0-dev+0123456789ab",
                     exe_id: bytes = b"\x11" * 20, debug_id: bytes = b"\x11" * 20, link_name: str = "metacodes.debug",
                     exe_dwarf: bool = False) -> tuple[Path, Path]:
    debug = _elf({".note.gnu.build-id": _build_id_note(debug_id), ".debug_info": b"dwarf"})
    exe_sections = {".note.gnu.build-id": _build_id_note(exe_id), ".gnu_debuglink": _debuglink(link_name, zlib.crc32(debug))}
    if exe_dwarf:
        exe_sections[".debug_info"] = b"dwarf"
    target_id = "x86_64-linux-gnu" if target_os == "linux" else "aarch64-macos"
    bundle = _cli_fixture(root, target_os, target_id, version, channel, executable_bytes=_elf(exe_sections))
    debug_file = root / "split" / "metacodes.debug"
    debug_file.parent.mkdir(parents=True)
    debug_file.write_bytes(debug)
    return bundle, debug_file


class ArchiveTests(unittest.TestCase):
    def test_symbols_archive_holds_the_linked_debug_file_reproducibly(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle, debug_file = _symbols_fixture(root)
            first, checksum = write_symbols_archive(bundle, debug_file, root / "one", None)
            second, _ = write_symbols_archive(bundle, debug_file, root / "two", None)
            self.assertEqual(first.name, "metacodes-0.2.0-dev+0123456789ab-x86_64-linux-gnu-debug.tar.gz")
            self.assertEqual(first.read_bytes(), second.read_bytes())
            self.assertEqual(checksum.read_text(encoding="ascii"), f"{sha256_file(first)}  {first.name}\n")
            with tarfile.open(first, "r:gz") as opened:
                self.assertEqual(opened.getnames(), ["metacodes-0.2.0-dev+0123456789ab-x86_64-linux-gnu-debug/bin/metacodes.debug"])
                member = opened.getmembers()[0]
                self.assertEqual((member.uid, member.gid, member.uname, member.gname, member.mtime), (0, 0, "", "", 0))
                self.assertEqual(opened.extractfile(member).read(), debug_file.read_bytes())
            # The CLI archive of the same unit is untouched by the symbols.
            cli, _ = write_archive(bundle, root / "one", "cli", None)
            with tarfile.open(cli, "r:gz") as opened:
                self.assertFalse(any(name.endswith(".debug") for name in opened.getnames()))

    def test_symbols_archive_refuses_a_debug_file_the_executable_does_not_name(self) -> None:
        cases = (
            ({"debug_id": b"\x22" * 20}, "build ID mismatch"),
            ({"link_name": "other.debug"}, "links to 'other.debug'"),
            ({"exe_dwarf": True}, "still carries DWARF"),
            ({"target_os": "macos"}, "Linux units only"),
        )
        for overrides, message in cases:
            with self.subTest(**{key: str(value) for key, value in overrides.items()}), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                bundle, debug_file = _symbols_fixture(root, **overrides)
                with self.assertRaisesRegex(ValueError, re.escape(message)):
                    write_symbols_archive(bundle, debug_file, root / "out", None)
                self.assertFalse((root / "out").exists() and any((root / "out").iterdir()))
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle, debug_file = _symbols_fixture(root)
            debug_file.write_bytes(debug_file.read_bytes() + b"\0")  # not the file the link names
            with self.assertRaisesRegex(ValueError, "CRC-32"):
                write_symbols_archive(bundle, debug_file, root / "out", None)

    def test_stable_symbols_follow_the_cli_channel_gate(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle, debug_file = _symbols_fixture(root, channel="stable", version="0.2.0")
            with self.assertRaisesRegex(ValueError, "tagged 0.2.0"):
                write_symbols_archive(bundle, debug_file, root / "out", GitFacts(head_tag=None))
            archive, _ = write_symbols_archive(bundle, debug_file, root / "out", GitFacts(head_tag="0.2.0"))
            self.assertEqual(archive.name, "metacodes-0.2.0-x86_64-linux-gnu-debug.tar.gz")

    def test_sdk_windows_zip_has_coordinate_root_and_refuses_overwrite(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = _sdk_fixture(root, "windows", "x86_64-windows-msvc")
            stale = bundle / "sdk" / "old-agentcore.zig"
            stale.parent.mkdir()
            stale.write_text("// ignored local residue\n", encoding="utf-8")
            archive, checksum = write_archive(bundle, root / "out", "agentcore", None)
            self.assertEqual(archive.suffix, ".zip")
            with zipfile.ZipFile(archive) as opened:
                self.assertIn("metask-agentcore-0.1.0-dev+0123456789ab-x86_64-windows-msvc/manifest.json", opened.namelist())
                self.assertTrue(all(info.date_time == ZIP_EPOCH for info in opened.infolist()))
                self.assertFalse(any(name.endswith("sdk/old-agentcore.zig") for name in opened.namelist()))
            self.assertTrue(checksum.read_text(encoding="ascii").startswith(sha256_file(archive)))
            # Re-running over the unchanged bundle is a no-op that proves the
            # bytes reproduce; a changed bundle may not replace the archive.
            self.assertEqual(write_archive(bundle, root / "out", "agentcore", None), (archive, checksum))
            payload = bundle / "lib" / "metask_agentcore.dll"
            payload.write_text("/* changed */\n", encoding="utf-8")
            manifest_path = bundle / "manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            next(entry for entry in manifest["files"] if entry["path"] == "lib/metask_agentcore.dll")["sha256"] = sha256_file(payload)
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaisesRegex(FileExistsError, "different bytes"):
                write_archive(bundle, root / "out", "agentcore", None)

    def test_cli_tar_gz_is_reproducible_and_named_after_the_release(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = _cli_fixture(root, "linux", "x86_64-linux-gnu", "0.2.0-dev+0123456789ab", "pre")
            first, _ = write_archive(bundle, root / "one", "cli", None)
            second, _ = write_archive(bundle, root / "two", "cli", None)
            self.assertEqual(first.name, "metacodes-0.2.0-dev+0123456789ab-x86_64-linux-gnu.tar.gz")
            self.assertEqual(first.read_bytes(), second.read_bytes())
            with tarfile.open(first, "r:gz") as opened:
                self.assertIn("metacodes-0.2.0-dev+0123456789ab-x86_64-linux-gnu/bin/metacodes", opened.getnames())
                for member in opened.getmembers():
                    self.assertEqual((member.uid, member.gid, member.uname, member.gname, member.mtime), (0, 0, "", "", 0))

    def test_stable_cli_requires_clean_tree_and_head_tag(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = _cli_fixture(root, "macos", "aarch64-macos", "0.2.0", "stable")
            with self.assertRaisesRegex(ValueError, "require a clean source tree tagged 0.2.0"):
                write_archive(bundle, root / "out", "cli", GitFacts(head_tag=None))
            with self.assertRaisesRegex(ValueError, "tagged 0.2.0"):
                write_archive(bundle, root / "out", "cli", GitFacts(head_tag="0.1.0"))
            archive, _ = write_archive(bundle, root / "out", "cli", GitFacts(head_tag="0.2.0"))
            self.assertEqual(archive.name, "metacodes-0.2.0-aarch64-macos.tar.gz")
            dirty = _cli_fixture(root / "dirty", "macos", "aarch64-macos", "0.2.0", "stable", dirty=True)
            with self.assertRaisesRegex(ValueError, "dirty=True"):
                write_archive(dirty, root / "out-dirty", "cli", GitFacts(head_tag="0.2.0"))

    def test_stable_sdk_archives_only_from_the_main_release_that_builds_it(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = _sdk_fixture(root, "linux", "x86_64-linux-gnu", version="0.13.0")
            for facts, message in (
                (None, "clean source tree"),
                (GitFacts(head_tag="0.10.0", head_commit="f" * 40, agentcore_built_by="0.10.0"), "clean source tree"),
                (GitFacts(head_tag=None, head_commit=COMMIT, agentcore_built_by="0.10.0"), "tagged main-project release"),
                (GitFacts(head_tag="0.10.0", head_commit=COMMIT, agentcore_built_by=None), "reuse them"),
                (GitFacts(head_tag="0.10.1", head_commit=COMMIT, agentcore_built_by="0.10.0"), "reuse them"),
            ):
                with self.assertRaisesRegex(ValueError, message):
                    write_archive(bundle, root / "out", "agentcore", facts)
            archive, _ = write_archive(bundle, root / "out", "agentcore", GitFacts(head_tag="0.10.0", head_commit=COMMIT, agentcore_built_by="0.10.0"))
            self.assertEqual(archive.name, "metask-agentcore-0.13.0-x86_64-linux-gnu.tar.gz")

    def test_a_development_sdk_refuses_a_release_tag(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = _sdk_fixture(root, "linux", "x86_64-linux-gnu")
            with self.assertRaisesRegex(ValueError, "development version"):
                write_archive(bundle, root / "out", "agentcore", GitFacts(head_tag="0.10.0"))
            write_archive(bundle, root / "out", "agentcore", GitFacts(head_tag=None))

    def test_rejects_payload_hash_mismatch_and_wrong_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = _sdk_fixture(root, "linux", "x86_64-linux-gnu")
            (bundle / "include" / "metask" / "agentcore.h").write_text("changed", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
                write_archive(bundle, root / "out", "agentcore", None)
            cli = _cli_fixture(root, "linux", "x86_64-linux-gnu", "0.2.0-dev+0123456789ab", "pre")
            with self.assertRaisesRegex(ValueError, "not metask AgentCore"):
                write_archive(cli, root / "out", "agentcore", None)
            with self.assertRaisesRegex(ValueError, "must not be inside"):
                write_archive(cli, cli / "archives", "cli", None)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("bundle_root", nargs="?", type=Path)
    parser.add_argument("output_dir", nargs="?", type=Path)
    parser.add_argument("--kind", choices=KINDS + ("symbols",), default="cli")
    parser.add_argument("--debug-file", type=Path, help="--kind symbols: the unit's split symbol file (metacodes.debug)")
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[1], help="repository the channel gate asks git about")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(ArchiveTests)
        return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1
    if args.bundle_root is None or args.output_dir is None:
        parser.error("bundle_root and output_dir are required")
    if (args.kind == "symbols") != (args.debug_file is not None):
        parser.error("--debug-file goes with --kind symbols, and only with it")
    try:
        bundle = load_bundle(args.bundle_root.resolve(), "cli" if args.kind == "symbols" else args.kind)
        git_facts = collect_git_facts(args.repo_root, bundle.version if args.kind == "agentcore" and bundle.channel == "stable" else None)
        if args.kind == "symbols":
            archive, checksum = write_symbols_archive(args.bundle_root.resolve(), args.debug_file.resolve(), args.output_dir.resolve(), git_facts)
        else:
            archive, checksum = write_archive(args.bundle_root.resolve(), args.output_dir.resolve(), args.kind, git_facts)
    except (FileExistsError, OSError, ValueError) as error:
        print(f"release archive: {error}", file=sys.stderr)
        return 1
    print(archive)
    print(checksum)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
