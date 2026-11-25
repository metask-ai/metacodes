"""Terminal I/O in the REPL survives the signals it installs.

The REPL's SIGWINCH handler is installed without SA_RESTART
(``platform.signal.installResize``), so a resize turns any blocked read or
write in the process into EINTR. A key read that takes that for end of input
cancels a reverse search, closes the transcript viewer or denies a permission
prompt; a write loop that stops on it drops the rest of a frame (#340).

In ``apps/cli/src/repl/`` and ``src/permission/prompt.zig``:

* a raw terminal read (``platform_term.readInput(``, ``pfs.read(``,
  ``std.c.read(``) is followed within a few lines by the retry check
  (``retryInterruptedRead(`` or prompt.zig's ``readInterrupted(``). Modal loops
  read whole keys through ``input.readKey``, which does both;
* a raw write (``pfs.write(``, ``std.c.write(``, ``posix.write(``) does not
  appear at all: terminal writes go through ``pfs.writeAll``, which retries;
* the terminal is read through ``platform_term.readInput`` only, never
  ``pfs.read(`` or ``std.c.read(``: readInput is where a Windows console's
  win32-input-mode key records become the VT bytes the readers parse (#386),
  and where the bytes the startup probe hands back are replayed. A read of
  anything else says so on its line: ``// ... not the terminal``.

A call that cannot see EINTR (a regular file, a read after poll reported data)
says why on its own line: ``// no EINTR: <reason>``. Test blocks are not
scanned: their pipes are not the terminal.
"""
from __future__ import annotations

import re
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCOPE_DIRS = (Path("apps/cli/src/repl"),)
SCOPE_FILES = (Path("src/permission/prompt.zig"),)
RAW_READ = re.compile(r"\b(?:platform_term\.readInput|pfs\.read|std\.c\.read)\s*\(")
RAW_WRITE = re.compile(r"\b(?:pfs\.write|std\.c\.write|posix\.write)\s*\(")
RETRY = re.compile(r"\b(?:retryInterruptedRead|readInterrupted)\s*\(")
BYPASS_READ = re.compile(r"\b(?:pfs\.read|std\.c\.read)\s*\(")
NOT_TERMINAL = "not the terminal"
EXEMPT = "no EINTR:"
# The retry check must come right after the read, before another call can
# overwrite errno; three lines covers `const n = read(...); if (n < 0) {`.
RETRY_WINDOW = 3
TEST_BLOCK = re.compile(r'^test\s+"')


def governed_sources(root: Path) -> list[Path]:
    """Root-relative Zig files the rule covers, sorted."""
    found = []
    for directory in SCOPE_DIRS:
        base = root / directory
        if not base.is_dir():
            raise NotADirectoryError(str(base))
        found.extend(path.relative_to(root) for path in base.rglob("*.zig"))
    found.extend(path for path in SCOPE_FILES if (root / path).is_file())
    return sorted(found)


def code_lines(text: str) -> list[tuple[int, str, str]]:
    """(line number, code without its comment, comment) outside test blocks.

    zig fmt puts a top-level test block's `test "..." {` and its closing `}`
    at column 0, which is all the scanner needs to skip it."""
    lines = []
    in_test = False
    for number, line in enumerate(text.splitlines(), 1):
        if in_test:
            if line.startswith("}"):
                in_test = False
            continue
        if TEST_BLOCK.match(line):
            in_test = not line.rstrip().endswith("}")
            continue
        code, _, comment = line.partition("//")
        lines.append((number, code, comment))
    return lines


def violations(root: Path) -> list[str]:
    """`path:line: what` for every raw terminal read without the retry check,
    every read past platform_term.readInput and every raw write, in the
    governed files under root."""
    found = []
    for relative in governed_sources(root):
        lines = code_lines((root / relative).read_text(encoding="utf-8"))
        for index, (number, code, comment) in enumerate(lines):
            where = f"{relative.as_posix()}:{number}"
            if BYPASS_READ.search(code) and NOT_TERMINAL not in comment:
                found.append(f"{where}: read past platform_term.readInput (key records are decoded there)")
            if EXEMPT in comment:
                continue
            if RAW_WRITE.search(code):
                found.append(f"{where}: raw write (use pfs.writeAll)")
            if RAW_READ.search(code):
                window = [later for _, later, _ in lines[index : index + 1 + RETRY_WINDOW]]
                if not any(RETRY.search(later) for later in window):
                    found.append(f"{where}: raw read without the EINTR retry (use input.readKey)")
    return found


def write(root: Path, relative: str, text: str) -> None:
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


class TerminalIoDisciplineTest(unittest.TestCase):
    def test_repl_terminal_io_retries_interrupted_calls(self):
        self.assertEqual(
            violations(ROOT),
            [],
            "a resize (SIGWINCH, no SA_RESTART) interrupts these calls with EINTR: read keys "
            "through input.readKey or check input.retryInterruptedRead right after the read, "
            "write through pfs.writeAll, or say `// no EINTR: <reason>` on the line; read the "
            "terminal through platform_term.readInput, and say `// ... not the terminal` on any "
            "other pfs.read",
        )

    def test_the_rule_still_sees_the_repl(self):
        # An empty scan would pass trivially; the seam itself must be in it.
        self.assertIn(Path("apps/cli/src/repl/input.zig"), governed_sources(ROOT))
        self.assertIn(Path("src/permission/prompt.zig"), governed_sources(ROOT))

    def test_scanner_reports_unchecked_reads_and_raw_writes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write(
                root,
                "apps/cli/src/repl/viewer.zig",
                "fn run() void {\n"
                "    const n = platform_term.readInput(fd, &b);\n"
                "    if (n <= 0) break;\n"
                "    _ = pfs.write(fd, frame);\n"
                "    _ = std.c.write(fd, frame.ptr, frame.len);\n"
                "}\n",
            )
            write(
                root,
                "apps/cli/src/repl/fine.zig",
                "fn run() void {\n"
                "    const n = platform_term.readInput(fd, &b);\n"
                "    if (n < 0) {\n"
                "        if (input.retryInterruptedRead(fd)) continue;\n"
                "    }\n"
                "    _ = pfs.writeAll(fd, frame);\n"
                "    _ = pfs.write(log_fd, line); // no EINTR: regular file\n"
                "    _ = pfs.read(cfg_fd, &raw); // no EINTR: regular file, not the terminal\n"
                "    // pfs.write(fd, frame) in a comment is not a call\n"
                "}\n"
                'test "pipes are not the terminal" {\n'
                "    _ = std.c.write(pipe[1], \"x\", 1);\n"
                "    _ = pfs.read(pipe[0], &b);\n"
                "}\n",
            )
            write(
                root,
                "apps/cli/src/repl/dialog.zig",
                "fn run() void {\n"
                "    const n = pfs.read(in_fd, &buf);\n"
                "    if (n < 0 and input.retryInterruptedRead(in_fd)) continue;\n"
                "    _ = std.c.read(0, &b, 1); // no EINTR: poll reported data\n"
                "}\n",
            )
            write(root, "src/permission/prompt.zig", "const n = platform_term.readInput(0, &buf);\n")
            write(root, "src/other/elsewhere.zig", "_ = pfs.write(fd, x);\n")
            self.assertEqual(
                violations(root),
                [
                    "apps/cli/src/repl/dialog.zig:2: read past platform_term.readInput (key records are decoded there)",
                    "apps/cli/src/repl/dialog.zig:4: read past platform_term.readInput (key records are decoded there)",
                    "apps/cli/src/repl/viewer.zig:2: raw read without the EINTR retry (use input.readKey)",
                    "apps/cli/src/repl/viewer.zig:4: raw write (use pfs.writeAll)",
                    "apps/cli/src/repl/viewer.zig:5: raw write (use pfs.writeAll)",
                    "src/permission/prompt.zig:1: raw read without the EINTR retry (use input.readKey)",
                ],
            )

    def test_a_retry_too_far_from_the_read_does_not_count(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write(
                root,
                "apps/cli/src/repl/late.zig",
                "const n = platform_term.readInput(in_fd, &buf);\n"
                "log(n);\n"
                "redraw();\n"
                "flush();\n"
                "if (n < 0 and input.retryInterruptedRead(in_fd)) continue;\n",
            )
            self.assertEqual(
                violations(root),
                ["apps/cli/src/repl/late.zig:1: raw read without the EINTR retry (use input.readKey)"],
            )

    def test_missing_scope_is_an_error_not_an_empty_scan(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(NotADirectoryError):
                violations(Path(directory))


if __name__ == "__main__":
    unittest.main()
