"""Unit tests for scripts/check_kernel_self_contained.py on synthetic images of
each format, so every host checks all three parsers. Python 3.9, stdlib only."""
from __future__ import annotations

import struct
import tempfile
import unittest
from pathlib import Path

from scripts import check_kernel_self_contained as check


def elf64(needed: list[str], dynamic: bool = True) -> bytes:
    """A little-endian ELF64 image with one PT_LOAD over the whole file and,
    when `dynamic`, a PT_DYNAMIC listing `needed`."""
    base = 0x400000
    header_size, phentsize = 64, 56
    phnum = 2 if dynamic else 1
    strtab = b"\0" + b"".join(name.encode() + b"\0" for name in needed)
    dyn_offset = header_size + phnum * phentsize
    entries = []
    offset = 1
    for name in needed:
        entries.append((1, offset))
        offset += len(name) + 1
    strtab_offset = dyn_offset + (len(entries) + 2) * 16
    entries.append((5, base + strtab_offset))
    entries.append((0, 0))
    dyn = b"".join(struct.pack("<qQ", tag, value) for tag, value in entries)
    total = strtab_offset + len(strtab)
    ident = b"\x7fELF" + bytes((2, 1, 1)) + b"\0" * 9
    header = ident + struct.pack("<HHIQQQIHHHHHH", 2, 0x3E, 1, base, header_size, 0, 0, header_size, phentsize, phnum, 64, 0, 0)
    phdrs = struct.pack("<IIQQQQQQ", 1, 5, 0, base, base, total, total, 0x1000)
    if dynamic:
        phdrs += struct.pack("<IIQQQQQQ", 2, 6, dyn_offset, base + dyn_offset, base + dyn_offset, len(dyn), len(dyn), 8)
        return header + phdrs + dyn + strtab
    return header + phdrs


def pe32plus(imports: list[str]) -> bytes:
    """A PE32+ image whose one section holds the import descriptors and names."""
    e_lfanew = 0x40
    optional_size = 240
    section_table = e_lfanew + 24 + optional_size
    raw = 0x200
    rva = 0x1000
    descriptors_size = (len(imports) + 1) * 20
    names = b""
    name_rvas = []
    for name in imports:
        name_rvas.append(rva + descriptors_size + len(names))
        names += name.encode() + b"\0"
    descriptors = b"".join(struct.pack("<IIIII", 0, 0, 0, name_rva, 0) for name_rva in name_rvas) + b"\0" * 20
    section = descriptors + names
    dos = b"MZ" + b"\0" * (0x3C - 2) + struct.pack("<I", e_lfanew)
    dos += b"\0" * (e_lfanew - len(dos))
    coff = b"PE\0\0" + struct.pack("<HHIIIHH", 0x8664, 1, 0, 0, 0, optional_size, 0x22)
    optional = bytearray(optional_size)
    struct.pack_into("<H", optional, 0, 0x20B)
    struct.pack_into("<II", optional, 112 + 8, rva, len(descriptors))
    header = struct.pack("<8sIIIIIIHHI", b".idata\0\0", len(section), rva, len(section), raw, 0, 0, 0, 0, 0xC0000040)
    image = dos + coff + bytes(optional) + header
    image += b"\0" * (raw - len(image))
    return image + section


def macho64(dylibs: list[str]) -> bytes:
    commands = b""
    for path in dylibs:
        name = path.encode() + b"\0"
        size = (24 + len(name) + 7) // 8 * 8
        commands += struct.pack("<IIIIII", 0x0C, size, 24, 2, 0x10000, 0x10000) + name.ljust(size - 24, b"\0")
    header = struct.pack("<IiiIIIII", 0xFEEDFACF, 0x0100000C, 0, 2, len(dylibs), len(commands), 0, 0)
    return header + commands


class DependenciesTest(unittest.TestCase):
    def test_elf_lists_needed_entries(self) -> None:
        fmt, deps = check.dependencies(elf64(["libc.so.6", "libgmp.so.10"]))
        self.assertEqual(fmt, "elf")
        self.assertEqual(deps, ["libc.so.6", "libgmp.so.10"])
        self.assertEqual(check.disallowed(fmt, deps), ["libgmp.so.10"])

    def test_static_elf_has_no_dependencies(self) -> None:
        self.assertEqual(check.dependencies(elf64([], dynamic=False)), ("elf", []))

    def test_elf_glibc_family_and_loader_are_allowed(self) -> None:
        deps = ["libc.so.6", "libm.so.6", "libpthread.so.0", "ld-linux-x86-64.so.2"]
        self.assertEqual(check.disallowed("elf", check.dependencies(elf64(deps))[1]), [])

    def test_pe_lists_imported_dlls(self) -> None:
        fmt, deps = check.dependencies(pe32plus(["KERNEL32.dll", "libgmp-10.dll", "api-ms-win-crt-runtime-l1-1-0.dll"]))
        self.assertEqual(fmt, "pe")
        self.assertEqual(deps, ["KERNEL32.dll", "libgmp-10.dll", "api-ms-win-crt-runtime-l1-1-0.dll"])
        self.assertEqual(check.disallowed(fmt, deps), ["libgmp-10.dll"])

    def test_macho_system_paths_only(self) -> None:
        fmt, deps = check.dependencies(macho64(["/usr/lib/libSystem.B.dylib", "/opt/homebrew/opt/gmp/lib/libgmp.10.dylib"]))
        self.assertEqual(fmt, "macho")
        self.assertEqual(check.disallowed(fmt, deps), ["/opt/homebrew/opt/gmp/lib/libgmp.10.dylib"])

    def test_unknown_format_is_refused(self) -> None:
        with self.assertRaises(check.FormatError):
            check.dependencies(b"#!/bin/sh\necho hi\n")


class MainTest(unittest.TestCase):
    def test_exit_status_names_the_offending_library(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            good = Path(tmp) / "good"
            bad = Path(tmp) / "bad"
            good.write_bytes(elf64(["libc.so.6"]))
            bad.write_bytes(macho64(["/usr/local/lib/libuv.1.dylib"]))
            self.assertEqual(check.main(["check", str(good)]), 0)
            self.assertEqual(check.main(["check", str(good), str(bad)]), 1)
            self.assertEqual(check.main(["check"]), 2)


if __name__ == "__main__":
    unittest.main()
