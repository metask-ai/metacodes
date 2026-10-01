"""Refuse a Lean kernel that depends on a library the target machine may lack.

Release archives ship both Lean governance kernels (doc/INSTALL_DESIGN.md §5),
so a kernel must start on a clean machine of its platform. The build host is
not such a machine: a Darwin relink that searched `/opt/homebrew/lib` produced
kernels needing Homebrew's `libgmp`/`libuv`, which start everywhere the
developer looked and nowhere else. This check reads the binary's own dynamic
dependency list and allows only libraries every installation of the OS has.

Formats are parsed here, with no `otool`/`readelf`/`objdump` dependency:
Mach-O (thin and fat) load commands, ELF `DT_NEEDED`, PE import descriptors.

usage: check_kernel_self_contained.py <binary>...      Python 3.9, stdlib only.
"""
from __future__ import annotations

import struct
import sys
from pathlib import Path

# Darwin: everything the OS itself provides lives in these trees.
DARWIN_SYSTEM_PREFIXES = ("/usr/lib/", "/System/Library/")
# Linux: the C library family that every glibc system carries.
LINUX_ALLOWED = frozenset((
    "libc.so.6",
    "libm.so.6",
    "libpthread.so.0",
    "libdl.so.2",
    "librt.so.1",
))
LINUX_LOADER_PREFIXES = ("ld-linux", "ld64.so")
# Windows: system DLLs present on every supported installation.
WINDOWS_ALLOWED = frozenset((
    "kernel32.dll", "ntdll.dll", "advapi32.dll", "user32.dll", "ws2_32.dll",
    "bcrypt.dll", "msvcrt.dll", "ucrtbase.dll", "shell32.dll", "ole32.dll",
    "iphlpapi.dll", "psapi.dll", "userenv.dll", "dbghelp.dll", "secur32.dll",
    "crypt32.dll", "shlwapi.dll",
))
WINDOWS_ALLOWED_PREFIXES = ("api-ms-win-",)


class FormatError(Exception):
    pass


def dependencies(data: bytes) -> tuple[str, list[str]]:
    """(format, dynamic dependencies) of an executable image."""
    if data[:4] == b"\x7fELF":
        return "elf", _elf_needed(data)
    if data[:2] == b"MZ":
        return "pe", _pe_imports(data)
    magic = struct.unpack_from(">I", data, 0)[0] if len(data) >= 4 else 0
    if magic in (0xCAFEBABE, 0xCAFEBABF):
        return "macho", _fat_dylibs(data)
    if magic in (0xFEEDFACE, 0xFEEDFACF, 0xCEFAEDFE, 0xCFFAEDFE):
        return "macho", _macho_dylibs(data, 0)
    raise FormatError("not an ELF, PE or Mach-O image")


def disallowed(fmt: str, deps: list[str]) -> list[str]:
    bad = []
    for dep in deps:
        if fmt == "macho":
            ok = dep.startswith(DARWIN_SYSTEM_PREFIXES)
        elif fmt == "elf":
            ok = dep in LINUX_ALLOWED or dep.startswith(LINUX_LOADER_PREFIXES)
        else:
            low = dep.lower()
            ok = low in WINDOWS_ALLOWED or low.startswith(WINDOWS_ALLOWED_PREFIXES)
        if not ok:
            bad.append(dep)
    return bad


# ── Mach-O ──────────────────────────────────────────────────────────────────

_LC_REQ_DYLD = 0x80000000
_DYLIB_COMMANDS = {0x0C, 0x18 | _LC_REQ_DYLD, 0x1F | _LC_REQ_DYLD, 0x20, 0x23 | _LC_REQ_DYLD}


def _fat_dylibs(data: bytes) -> list[str]:
    magic, count = struct.unpack_from(">II", data, 0)
    wide = magic == 0xCAFEBABF
    entry = 32 if wide else 20
    deps: list[str] = []
    for index in range(count):
        base = 8 + index * entry
        if wide:
            _, _, offset, _, _, _ = struct.unpack_from(">iiQQII", data, base)
        else:
            _, _, offset, _, _ = struct.unpack_from(">iiIII", data, base)
        for dep in _macho_dylibs(data, offset):
            if dep not in deps:
                deps.append(dep)
    return deps


def _macho_dylibs(data: bytes, base: int) -> list[str]:
    magic = struct.unpack_from("<I", data, base)[0]
    if magic in (0xFEEDFACE, 0xFEEDFACF):
        order = "<"
    elif magic in (0xCEFAEDFE, 0xCFFAEDFE):
        order = ">"
        magic = struct.unpack_from(">I", data, base)[0]
    else:
        raise FormatError("bad Mach-O slice")
    header = 32 if magic == 0xFEEDFACF else 28
    ncmds = struct.unpack_from(order + "I", data, base + 16)[0]
    offset = base + header
    deps = []
    for _ in range(ncmds):
        cmd, size = struct.unpack_from(order + "II", data, offset)
        if size < 8:
            raise FormatError("bad Mach-O load command")
        if cmd in _DYLIB_COMMANDS:
            name_offset = struct.unpack_from(order + "I", data, offset + 8)[0]
            raw = data[offset + name_offset:offset + size]
            deps.append(raw.split(b"\0", 1)[0].decode("utf-8", "replace"))
        offset += size
    return deps


# ── ELF ─────────────────────────────────────────────────────────────────────

def _elf_needed(data: bytes) -> list[str]:
    is64 = data[4] == 2
    order = "<" if data[5] == 1 else ">"
    if is64:
        phoff, = struct.unpack_from(order + "Q", data, 32)
        phentsize, phnum = struct.unpack_from(order + "HH", data, 54)
    else:
        phoff, = struct.unpack_from(order + "I", data, 28)
        phentsize, phnum = struct.unpack_from(order + "HH", data, 42)
    loads = []
    dynamic = None
    for index in range(phnum):
        at = phoff + index * phentsize
        if is64:
            p_type, _, p_offset, p_vaddr, _, p_filesz = struct.unpack_from(order + "IIQQQQ", data, at)
        else:
            p_type, p_offset, p_vaddr, _, p_filesz = struct.unpack_from(order + "IIIII", data, at)
        if p_type == 1:
            loads.append((p_vaddr, p_offset, p_filesz))
        elif p_type == 2:
            dynamic = (p_offset, p_filesz)
    if dynamic is None:
        return []  # statically linked

    def file_offset(vaddr: int) -> int:
        for start, off, size in loads:
            if start <= vaddr < start + size:
                return off + (vaddr - start)
        raise FormatError("ELF address outside every PT_LOAD")

    entry = 16 if is64 else 8
    fmt = order + ("qQ" if is64 else "iI")
    needed, strtab = [], None
    for at in range(dynamic[0], dynamic[0] + dynamic[1], entry):
        tag, value = struct.unpack_from(fmt, data, at)
        if tag == 0:
            break
        if tag == 1:
            needed.append(value)
        elif tag == 5:
            strtab = file_offset(value)
    if needed and strtab is None:
        raise FormatError("ELF DT_NEEDED without DT_STRTAB")
    return [data[strtab + n:data.index(b"\0", strtab + n)].decode("utf-8", "replace") for n in needed]


# ── PE ──────────────────────────────────────────────────────────────────────

def _pe_imports(data: bytes) -> list[str]:
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe:pe + 4] != b"PE\0\0":
        raise FormatError("bad PE signature")
    sections, optional_size = struct.unpack_from("<H12xH", data, pe + 6)
    optional = pe + 24
    magic = struct.unpack_from("<H", data, optional)[0]
    directories = optional + (112 if magic == 0x20B else 96)
    import_rva, import_size = struct.unpack_from("<II", data, directories + 8)
    if import_rva == 0:
        return []
    table = optional + optional_size
    spans = []
    for index in range(sections):
        at = table + index * 40
        vsize, vaddr, rsize, roff = struct.unpack_from("<IIII", data, at + 8)
        spans.append((vaddr, max(vsize, rsize), roff))

    def file_offset(rva: int) -> int:
        for vaddr, size, roff in spans:
            if vaddr <= rva < vaddr + size:
                return roff + (rva - vaddr)
        raise FormatError("PE RVA outside every section")

    deps = []
    at = file_offset(import_rva)
    while True:
        descriptor = struct.unpack_from("<IIIII", data, at)
        if not any(descriptor):
            break
        name = file_offset(descriptor[3])
        deps.append(data[name:data.index(b"\0", name)].decode("ascii", "replace"))
        at += 20
    return deps


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    failed = False
    for name in argv[1:]:
        try:
            fmt, deps = dependencies(Path(name).read_bytes())
        except (OSError, FormatError, struct.error, ValueError) as err:
            print(f"{name}: cannot read dynamic dependencies: {err}", file=sys.stderr)
            failed = True
            continue
        bad = disallowed(fmt, deps)
        if bad:
            print(f"{name}: depends on libraries a clean {fmt} host may lack: {', '.join(bad)}", file=sys.stderr)
            failed = True
        else:
            print(f"{name}: self-contained ({fmt}; {', '.join(deps) or 'no dynamic dependencies'})")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
