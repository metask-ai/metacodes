#!/usr/bin/env python3
import argparse
import sys
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TUI_TABLE = ROOT / "apps/cli/src/repl/tui/char_width.zig"
VTERM_TABLE = ROOT / "apps/cli/tests/component/terminal_width.zig"
SCREEN_TABLE = ROOT / "tests/tty/terminal_width.py"

LAST_CODE_POINT = 0x10FFFF
FIRST_TABLE_CODE_POINT = 0xA0
SOFT_HYPHEN = 0x00AD
EMOJI_PRESENTATION_SELECTOR = 0xFE0F
HANGUL_TRAILING_JAMO = range(0x1160, 0x1200)
REGIONAL_INDICATORS = range(0x1F1E6, 0x1F200)


def terminal_width(cp):
    ch = chr(cp)
    if cp == SOFT_HYPHEN:
        return 1
    if unicodedata.category(ch) in ("Mn", "Me", "Cf") or cp in HANGUL_TRAILING_JAMO:
        return 0
    if unicodedata.east_asian_width(ch) in ("W", "F"):
        return 2
    return 1


def tui_width(cp):
    if cp == EMOJI_PRESENTATION_SELECTOR or cp in HANGUL_TRAILING_JAMO or unicodedata.category(chr(cp)) == "Cf":
        return 1
    if cp in REGIONAL_INDICATORS:
        return 2
    return terminal_width(cp)


def ranges_of(width_of, width):
    out = []
    start = None
    for cp in range(FIRST_TABLE_CODE_POINT, LAST_CODE_POINT + 2):
        inside = cp <= LAST_CODE_POINT and not 0xD800 <= cp <= 0xDFFF and width_of(cp) == width
        if inside and start is None:
            start = cp
        elif not inside and start is not None:
            out.append((start, cp - 1))
            start = None
    return out


def zig_table(width_of):
    lines = ['pub const unicode_version = "%s";' % unicodedata.unidata_version, ""]
    for name, width in (("zero", 0), ("wide", 2)):
        lines.append("pub const %s = [_][2]u21{" % name)
        lines.extend("    .{ 0x%04X, 0x%04X }," % r for r in ranges_of(width_of, width))
        lines.append("};")
        lines.append("")
    return "\n".join(lines[:-1]) + "\n"


def python_table(width_of):
    lines = ['UNICODE_VERSION = "%s"' % unicodedata.unidata_version, ""]
    for name, width in (("ZERO", 0), ("WIDE", 2)):
        lines.append("%s = (" % name)
        lines.extend("    (0x%04X, 0x%04X)," % r for r in ranges_of(width_of, width))
        lines.append(")")
        lines.append("")
    return "\n".join(lines[:-1]) + "\n"


def outputs():
    return {
        TUI_TABLE: zig_table(tui_width),
        VTERM_TABLE: zig_table(terminal_width),
        SCREEN_TABLE: python_table(terminal_width),
    }


def main():
    parser = argparse.ArgumentParser(
        description="Write the TUI's character width table and the test terminals' from this Python's unicodedata."
    )
    parser.add_argument("--check", action="store_true", help="fail when a written table differs from what this Python generates")
    args = parser.parse_args()
    stale = []
    for path, text in outputs().items():
        if args.check:
            if not path.exists() or path.read_text(encoding="utf-8") != text:
                stale.append(path.relative_to(ROOT))
        else:
            path.write_text(text, encoding="utf-8")
            print("wrote %s (Unicode %s)" % (path.relative_to(ROOT), unicodedata.unidata_version))
    if stale:
        print("stale for Unicode %s: %s" % (unicodedata.unidata_version, ", ".join(map(str, stale))), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
