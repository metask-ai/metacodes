#!/usr/bin/env python3
"""Fail a release executable that needs more than its target promises.

Without -Dtarget, zig builds for the host: the build runner's CPU, glibc and
macOS. A release built that way runs on machines like the runner and nowhere
older. The x86_64 Linux unit of `release.yml` dry run 40705387727 carried
13,900 AVX-512 instructions because its runner's CPU had them, and the
published 0.8.0 unit needs GLIBC_2.36, so it does not start on Ubuntu 22.04.
`release.yml` therefore builds each CLI unit for an explicit Zig target. This
script holds the built executable to that target string, the same one the
matrix passes as -Dtarget:

- the CPU is the baseline. On x86_64 that means no VEX- or EVEX-encoded
  instruction at all: no AVX, AVX2 or AVX-512. On aarch64 it means no SVE or
  SME and no Armv8.6 BF16 or Int8 matrix instructions.
- a glibc suffix (`aarch64-linux-gnu.2.31`) caps the GLIBC_x.y symbol
  versions an ELF executable needs.
- a macOS version (`x86_64-macos.13.0`) caps the Mach-O minimum OS version.

The instruction check disassembles with `llvm-objdump` or GNU `objdump`, the
first one found (`--objdump` names one). A disassembler that cannot be found
or fails is a failure, not a pass. The glibc and macOS checks read the ELF
version-needs section and the Mach-O load commands directly. Only executables
this repository builds belong here: a vendored binary such as ripgrep selects
its CPU paths at run time, so its static instruction mix says nothing.

A Mach-O executable keeps data inside `__text`: LLVM places an x86_64 switch's
jump table after its function and the linker lists every such range in
`LC_DATA_IN_CODE`. A linear `objdump -d` decodes those tables as instructions,
and the code after one from a wrong offset; the x86_64 macOS unit of the 0.10.0
release run 41194755285 failed on one such entry of `repl.loop.readLineRaw`'s
key switch, `62 f1 ff ff 59 f0`, two offsets that read as an EVEX `vmulsd`. So
a Mach-O is disassembled in LLVM's Mach-O mode, which prints each listed range
as data and resumes decoding where it ends, over every section that holds
instructions. The check reads `LC_DATA_IN_CODE` itself and fails unless every
range came back as data and no instruction starts inside one: nothing is
skipped that the linker did not record as data, and GNU objdump, which has no
such mode, cannot check a Mach-O.

Python 3.9, stdlib only.
"""

from __future__ import annotations

import argparse
import bisect
import os
import re
import shutil
import struct
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable, Optional

SHT_GNU_VERNEED = 0x6FFFFFFE
LC_SEGMENT_64 = 0x19
LC_DATA_IN_CODE = 0x29
LC_BUILD_VERSION = 0x32
LC_VERSION_MIN_MACOSX = 0x24
S_ATTR_PURE_INSTRUCTIONS = 0x80000000
S_ATTR_SOME_INSTRUCTIONS = 0x00000400
MACHO_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
GLIBC_RE = re.compile(r"^GLIBC_(\d+)\.(\d+)(?:\.(\d+))?$")

# An instruction line of llvm-objdump or GNU objdump with --no-show-raw-insn:
# "  401000:\tvmovdqu\t%ymm0, (%rdi)" or "  401000:\tvmovdqu %ymm0,(%rdi)".
INSN_RE = re.compile(r"^\s*([0-9a-f]+):\s+([a-z][a-z0-9.]*)\b(.*)$")
# How llvm-objdump's Mach-O mode prints a data-in-code entry, one line per
# element: "1000f17b4:\t.long 4294953688\t@ KIND_JUMP_TABLE32".
DICE_LINE_RE = re.compile(r"^\s*([0-9a-f]+):\s+\.(?:byte|short|long)\s+\d+\s+@ ")
MACHO_SECTION_RE = re.compile(r"^Contents of \(([^,()]+),([^,()]+)\) section$")
# x86_64, AT&T syntax. A VEX- or EVEX-encoded instruction is a `v` mnemonic
# with a vector register operand (the VMX `vm*` and `verr`/`verw` take none).
X86_RULES = (
    ("AVX-512", re.compile(r"%zmm\d|%k[0-7]\b")),
    ("AVX/AVX2 256-bit", re.compile(r"%ymm\d")),
)
COMMENT_RE = re.compile(r"<[^>]*>")
X86_VEX_OPERAND = re.compile(r"%[xyz]mm\d")
AARCH64_RULES = (
    ("SVE/SME", re.compile(r"\bz\d{1,2}\.[bhsdq]\b|\bp\d{1,2}(?:/[zm]|\.[bhsd])\b|\bza\b")),
)
AARCH64_V86 = frozenset(("bfdot", "bfmmla", "bfmlalb", "bfmlalt", "bfcvt", "bfcvtn", "bfcvtn2",
                         "smmla", "ummla", "usmmla", "usdot", "sudot"))
EXAMPLES = 3


class CheckError(RuntimeError):
    """The executable or its target cannot be checked at all."""


@dataclass(frozen=True)
class Target:
    arch: str
    os: str
    glibc_max: Optional[tuple]
    macos_max: Optional[tuple]


@dataclass
class Report:
    path: Path
    findings: list = field(default_factory=list)
    notes: list = field(default_factory=list)


def parse_version(text: str) -> tuple:
    parts = text.split(".")
    if not 1 <= len(parts) <= 3 or not all(p.isdigit() for p in parts):
        raise CheckError(f"not a version: {text!r}")
    return tuple(int(p) for p in parts) + (0,) * (3 - len(parts))


def show(version: tuple) -> str:
    return ".".join(str(v) for v in (version[:2] if version[2] == 0 else version))


def parse_target(text: str) -> Target:
    """A Zig target string: `<arch>-<os>[.<min>[...<max>]][-<abi>[.<glibc>]]`."""
    parts = text.split("-")
    if len(parts) not in (2, 3) or not all(parts):
        raise CheckError(f"not a Zig target: {text!r}")
    arch = parts[0]
    if arch not in ("x86_64", "aarch64"):
        raise CheckError(f"no baseline rule for architecture {arch!r}")
    os_name, _, os_range = parts[1].partition(".")
    macos_max = None
    if os_range:
        if os_name != "macos":
            raise CheckError(f"an OS version is checked for macOS only: {text!r}")
        macos_max = parse_version(os_range.split("...")[0])
    glibc_max = None
    if len(parts) == 3:
        abi, _, abi_version = parts[2].partition(".")
        if abi_version:
            if abi != "gnu":
                raise CheckError(f"an ABI version is checked for glibc only: {text!r}")
            glibc_max = parse_version(abi_version)
    return Target(arch=arch, os=os_name, glibc_max=glibc_max, macos_max=macos_max)


# ── ELF: the GLIBC versions an executable needs ─────────────────────────────


def elf_glibc_needs(data: bytes) -> list:
    """Every GLIBC_x.y[.z] the ELF's SHT_GNU_verneed section names, sorted."""
    if data[:4] != b"\x7fELF":
        raise CheckError("not an ELF file")
    if data[4] != 2:
        raise CheckError("not a 64-bit ELF file")
    end = "<" if data[5] == 1 else ">"
    shoff, = struct.unpack_from(end + "Q", data, 0x28)
    shentsize, shnum = struct.unpack_from(end + "HH", data, 0x3A)
    sections = []
    for i in range(shnum):
        base = shoff + i * shentsize
        _, sh_type, _, _, sh_offset, sh_size, sh_link, sh_info = struct.unpack_from(end + "IIQQQQII", data, base)
        sections.append((sh_type, sh_offset, sh_size, sh_link, sh_info))
    needs = set()
    for sh_type, offset, _, link, count in sections:
        if sh_type != SHT_GNU_VERNEED:
            continue
        strtab = sections[link][1]
        entry = offset
        for _ in range(count):
            _, vn_cnt, _, vn_aux, vn_next = struct.unpack_from(end + "HHIII", data, entry)
            aux = entry + vn_aux
            for _ in range(vn_cnt):
                _, _, _, vna_name, vna_next = struct.unpack_from(end + "IHHII", data, aux)
                name_end = data.index(b"\0", strtab + vna_name)
                needs.add(data[strtab + vna_name:name_end].decode("ascii", "replace"))
                aux += vna_next
            entry += vn_next
    versions = []
    for name in needs:
        match = GLIBC_RE.match(name)
        if match:
            versions.append(tuple(int(g or 0) for g in match.groups()))
    return sorted(versions)


# ── Mach-O: the minimum OS version ──────────────────────────────────────────


@dataclass(frozen=True)
class MachOSlice:
    minimum: tuple
    # (segment, section) of every section that holds instructions.
    code_sections: tuple
    # (address, length, kind) of every LC_DATA_IN_CODE entry.
    data_in_code: tuple


def _name(raw: bytes) -> str:
    return raw.split(b"\0", 1)[0].decode("ascii", "replace")


def macho_slices(data: bytes) -> list:
    """Each slice's minimum macOS, code sections and data-in-code ranges."""
    magic, = struct.unpack_from(">I", data, 0)
    if magic == FAT_MAGIC:
        count, = struct.unpack_from(">I", data, 4)
        offsets = [struct.unpack_from(">iiIII", data, 8 + 20 * i)[2] for i in range(count)]
    else:
        offsets = [0]
    found = []
    for offset in offsets:
        magic, = struct.unpack_from("<I", data, offset)
        if magic != MACHO_MAGIC_64:
            raise CheckError("not a 64-bit Mach-O file")
        ncmds, = struct.unpack_from("<I", data, offset + 16)
        cursor = offset + 32
        version = None
        segments = []
        code_sections = []
        dice = None
        for _ in range(ncmds):
            cmd, size = struct.unpack_from("<II", data, cursor)
            if cmd == LC_BUILD_VERSION:
                version = struct.unpack_from("<I", data, cursor + 12)[0]
            elif cmd == LC_VERSION_MIN_MACOSX:
                version = struct.unpack_from("<I", data, cursor + 8)[0]
            elif cmd == LC_SEGMENT_64:
                vmaddr, _, fileoff, filesize = struct.unpack_from("<QQQQ", data, cursor + 24)
                segments.append((vmaddr, fileoff, filesize))
                nsects, = struct.unpack_from("<I", data, cursor + 64)
                for i in range(nsects):
                    base = cursor + 72 + 80 * i
                    flags, = struct.unpack_from("<I", data, base + 64)
                    if flags & (S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS):
                        code_sections.append((_name(data[base + 16:base + 32]), _name(data[base:base + 16])))
            elif cmd == LC_DATA_IN_CODE:
                dice = struct.unpack_from("<II", data, cursor + 8)
            cursor += size
        if version is None:
            raise CheckError("a Mach-O slice records no minimum macOS version")
        entries = []
        if dice is not None:
            dataoff, datasize = dice
            for i in range(datasize // 8):
                entry_offset, length, kind = struct.unpack_from("<IHH", data, offset + dataoff + 8 * i)
                # The offset counts from the slice's header; the segment that
                # holds those file bytes gives their address.
                for vmaddr, fileoff, filesize in segments:
                    if fileoff <= entry_offset < fileoff + filesize:
                        entries.append((vmaddr + entry_offset - fileoff, length, kind))
                        break
                else:
                    raise CheckError(f"a data-in-code entry at file offset {entry_offset:#x} lies in no segment")
        found.append(MachOSlice(
            minimum=(version >> 16, (version >> 8) & 0xFF, version & 0xFF),
            code_sections=tuple(code_sections),
            data_in_code=tuple(entries),
        ))
    return found


def macho_min_versions(data: bytes) -> list:
    """The minimum macOS version of each slice (fat files have several)."""
    return [piece.minimum for piece in macho_slices(data)]


# ── Instructions ────────────────────────────────────────────────────────────


def find_disassembler(explicit: Optional[str]) -> str:
    if explicit:
        return explicit
    candidates = ["llvm-objdump", "objdump"]
    if os.name == "nt":
        candidates.append(str(Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "LLVM" / "bin" / "llvm-objdump.exe"))
    for name in candidates:
        found = shutil.which(name) or (name if Path(name).is_file() else None)
        if found:
            return found
    raise CheckError("no disassembler: install llvm-objdump or binutils' objdump, or pass --objdump")


def disassemble(objdump: str, path: Path, arch: str, macho_sections: Optional[list] = None) -> Iterable[str]:
    """The disassembler's lines for every instruction section of `path`.

    `macho_sections` [(segment, section), ...] selects LLVM's Mach-O mode,
    which honors LC_DATA_IN_CODE, over exactly those sections.
    """
    llvm = is_llvm(objdump)
    if macho_sections is None:
        argv = [objdump, "-d", "--no-show-raw-insn"]
    else:
        if not llvm:
            raise CheckError(f"{objdump} is not llvm-objdump: only its Mach-O mode reads a Mach-O's data-in-code ranges as data")
        if not macho_sections:
            raise CheckError(f"{path} has no section that holds instructions")
        # Without -d the Mach-O mode prints the named sections, a section of
        # instructions disassembled; -d would print only (__TEXT,__text).
        argv = [objdump, "--macho", "--arch=all", "--no-show-raw-insn"]
        argv += [f"--section={segment},{section}" for segment, section in macho_sections]
    if arch == "aarch64" and llvm:
        # LLVM decodes only the extensions it is told about; GNU decodes all.
        argv.append("--mattr=+sve,+sve2,+sme,+bf16,+i8mm")
    argv.append(str(path))
    completed = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, errors="replace", check=False)
    if completed.returncode != 0:
        raise CheckError(f"{objdump} failed on {path} ({completed.returncode}): {completed.stderr.strip()[:300]}")
    lines = completed.stdout.splitlines()
    if not any(INSN_RE.match(line) for line in lines[:2000]):
        raise CheckError(f"{objdump} printed no instructions for {path}")
    if macho_sections is not None:
        printed = {match.groups() for match in map(MACHO_SECTION_RE.match, lines) if match}
        missing = [f"{segment},{section}" for segment, section in macho_sections if (segment, section) not in printed]
        if missing:
            raise CheckError(f"{objdump} printed no section {', '.join(missing)} of {path}")
    return lines


def is_llvm(objdump: str) -> bool:
    try:
        out = subprocess.run([objdump, "--version"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False).stdout
    except OSError:
        return False
    return "LLVM" in out


def instruction_findings(lines: Iterable[str], arch: str) -> dict:
    """{class: (count, [example lines])} of instructions beyond the baseline."""
    found: dict = {}

    def hit(name: str, line: str) -> None:
        count, examples = found.get(name, (0, []))
        if len(examples) < EXAMPLES:
            examples.append(line.strip())
        found[name] = (count + 1, examples)

    for line in lines:
        match = INSN_RE.match(line)
        if not match:
            continue
        mnemonic = match.group(2)
        # Drop the disassembler's annotations (`<symbol>`, `# 0x..` on x86,
        # `// =0x..` on aarch64, `; literal pool for: ".."` in Mach-O mode),
        # so a symbol name or string is never read as a register.
        operands = COMMENT_RE.sub("", match.group(3))
        operands = operands.split("#")[0] if arch == "x86_64" else operands.split("//")[0].split(";")[0]
        if arch == "x86_64":
            for name, rule in X86_RULES:
                if rule.search(operands):
                    hit(name, line)
                    break
            else:
                if mnemonic.startswith("v") and X86_VEX_OPERAND.search(operands):
                    hit("AVX 128-bit (VEX)", line)
        else:
            for name, rule in AARCH64_RULES:
                if rule.search(operands):
                    hit(name, line)
                    break
            else:
                if mnemonic in AARCH64_V86:
                    hit("Armv8.6 BF16/Int8 matrix", line)
    return found


def check_data_in_code(lines: Iterable[str], entries: Iterable[tuple]) -> None:
    """Fail unless the disassembly printed every LC_DATA_IN_CODE range as data
    and started no instruction inside one."""
    # An entry of length 0 covers no byte, and the disassembler prints none.
    ranges = sorted(entry for entry in entries if entry[1] > 0)
    if not ranges:
        return
    starts = [start for start, _, _ in ranges]
    as_data = set()
    for line in lines:
        data = DICE_LINE_RE.match(line)
        if data:
            as_data.add(int(data.group(1), 16))
            continue
        match = INSN_RE.match(line)
        if not match:
            continue
        address = int(match.group(1), 16)
        index = bisect.bisect_right(starts, address) - 1
        if index >= 0:
            start, length, kind = ranges[index]
            if address < start + length:
                raise CheckError(f"the disassembler decoded {address:#x}, inside the data-in-code range {start:#x}+{length} (kind {kind}), as an instruction: {line.strip()}")
    for start, length, kind in ranges:
        if start not in as_data:
            raise CheckError(f"the disassembler did not print the data-in-code range {start:#x}+{length} (kind {kind}) as data")


# ── The check ───────────────────────────────────────────────────────────────


def check(path: Path, target: Target, objdump: str) -> Report:
    report = Report(path)
    data = path.read_bytes()
    lines = None
    if data[:4] == b"\x7fELF":
        if target.os != "linux":
            raise CheckError(f"{path} is ELF but the target is {target.os}")
        versions = elf_glibc_needs(data)
        newest = versions[-1] if versions else None
        report.notes.append(f"needs GLIBC_{show(newest)}" if newest else "needs no versioned glibc symbol")
        if target.glibc_max is not None and newest is not None and newest > target.glibc_max:
            report.findings.append(f"needs GLIBC_{show(newest)}, newer than the target's glibc {show(target.glibc_max)}")
    elif data[:4] in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe"):
        if target.os != "macos":
            raise CheckError(f"{path} is Mach-O but the target is {target.os}")
        slices = macho_slices(data)
        for piece in slices:
            report.notes.append(f"minimum macOS {show(piece.minimum)}")
            if target.macos_max is not None and piece.minimum > target.macos_max:
                report.findings.append(f"minimum macOS {show(piece.minimum)}, newer than the target's macOS {show(target.macos_max)}")
        sections = list(dict.fromkeys(section for piece in slices for section in piece.code_sections))
        entries = [entry for piece in slices for entry in piece.data_in_code]
        lines = disassemble(objdump, path, target.arch, macho_sections=sections)
        check_data_in_code(lines, entries)
        if entries:
            report.notes.append(f"{len(entries)} data-in-code range(s), {sum(length for _, length, _ in entries)} bytes, read as data")
    elif data[:2] == b"MZ":
        if target.os != "windows":
            raise CheckError(f"{path} is PE but the target is {target.os}")
    else:
        raise CheckError(f"{path} is not an ELF, Mach-O or PE executable")
    if lines is None:
        lines = disassemble(objdump, path, target.arch)
    for name, (count, examples) in sorted(instruction_findings(lines, target.arch).items()):
        report.findings.append(f"{count} {name} instruction(s) beyond the {target.arch} baseline, e.g. " + " | ".join(examples))
    return report


def main(argv: Optional[list] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--target", required=True, help="the Zig target the executables were built for, e.g. aarch64-linux-gnu.2.31")
    parser.add_argument("--objdump", help="disassembler to use (default: llvm-objdump, then objdump)")
    parser.add_argument("executables", nargs="+", type=Path)
    args = parser.parse_args(argv)
    try:
        target = parse_target(args.target)
        objdump = find_disassembler(args.objdump)
        reports = [check(path, target, objdump) for path in args.executables]
    except (CheckError, OSError, struct.error, ValueError) as error:
        print(f"check_binary_baseline: {error}", file=sys.stderr)
        return 2
    failed = False
    for report in reports:
        status = "FAIL" if report.findings else "ok"
        print(f"{status} {report.path} ({args.target}; {'; '.join(report.notes) or 'baseline CPU'})")
        for finding in report.findings:
            print(f"  - {finding}")
        failed = failed or bool(report.findings)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
