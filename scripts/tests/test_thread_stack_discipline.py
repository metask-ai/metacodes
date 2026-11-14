"""Every production thread in ``src/`` states its stack (#503).

``std.Thread.spawn`` defaults to a 16 MiB stack. On Windows Zig 0.16 passes it
to ``NtCreateThreadEx`` as the stack *commit*, so every such thread charges
16 MiB of private commit for its whole life; an idle AgentCore Session kept
three of them. Production code therefore spawns through
``platform.thread.spawn(stack, ...)``, which makes the choice explicit (see
src/platform/thread.zig). Test blocks may use ``std.Thread.spawn`` directly:
their threads never reach a Host.
"""
from __future__ import annotations

import os
import re
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
# The wrapper itself.
ALLOWED = {Path("src/platform/thread.zig")}
# Also catches `const Thread = std.Thread;` followed by `Thread.spawn(`.
DIRECT_SPAWN = re.compile(r"\bThread\s*\.\s*spawn\s*\(")
TEST_OPEN = re.compile(r"^(\s*)test\b.*\{\s*$")


def zig_sources(root: Path) -> list[Path]:
    """Root-relative paths of the Zig files under ``src/``, sorted."""
    src = root / "src"
    if not src.is_dir():
        raise NotADirectoryError(str(src))
    found = []
    for current, _dirnames, filenames in os.walk(src):
        here = Path(current).relative_to(root)
        found.extend(here / name for name in filenames if name.endswith(".zig"))
    return sorted(path for path in found if path not in ALLOWED)


def production_lines(text: str):
    """(line number, code) for every line outside a test block, comments cut.

    A test block opens on a ``test ... {`` line (zig fmt keeps it on one line)
    and closes at the ``}`` with the same indentation.
    """
    closing = None
    for number, line in enumerate(text.splitlines(), 1):
        if closing is not None:
            if line.rstrip() == closing:
                closing = None
            continue
        opened = TEST_OPEN.match(line)
        if opened:
            closing = opened.group(1) + "}"
            continue
        yield number, line.split("//", 1)[0]


def violations(root: Path) -> list[str]:
    """`path:line` for every direct Thread.spawn outside a test block under src/."""
    found = []
    for relative in zig_sources(root):
        text = (root / relative).read_text(encoding="utf-8")
        for number, code in production_lines(text):
            if DIRECT_SPAWN.search(code):
                found.append(f"{relative.as_posix()}:{number}")
    return found


class ThreadStackDisciplineTest(unittest.TestCase):
    def test_production_threads_spawn_through_platform_thread(self):
        self.assertEqual(
            violations(ROOT),
            [],
            "spawn production threads with @import(\"platform\").thread.spawn(stack, ...) "
            "and pick the stack class (see src/platform/thread.zig)",
        )

    def test_scanner_skips_tests_comments_and_the_wrapper(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "src" / "platform").mkdir(parents=True)
            (root / "src" / "direct.zig").write_text(
                "fn start() !void {\n"
                "    _ = try std.Thread.spawn(.{}, run, .{});\n"
                "}\n",
                encoding="utf-8",
            )
            (root / "src" / "aliased.zig").write_text(
                "const Thread = std.Thread;\n"
                "fn start() !void {\n"
                "    _ = try Thread.spawn(.{ .stack_size = 1 }, run, .{});\n"
                "}\n",
                encoding="utf-8",
            )
            (root / "src" / "fine.zig").write_text(
                "// std.Thread.spawn is wrapped\n"
                "fn start() !void {\n"
                "    _ = try @import(\"platform\").thread.spawn(.waiter, run, .{});\n"
                "}\n"
                "test \"top-level test\" {\n"
                "    const t = try std.Thread.spawn(.{}, run, .{});\n"
                "    t.join();\n"
                "}\n"
                "const Nested = struct {\n"
                "    test \"nested test\" {\n"
                "        const Helper = struct {\n"
                "            fn go() void {}\n"
                "        };\n"
                "        _ = try std.Thread.spawn(.{}, Helper.go, .{});\n"
                "    }\n"
                "};\n",
                encoding="utf-8",
            )
            (root / "src" / "after_test.zig").write_text(
                "test \"t\" {\n"
                "    _ = try std.Thread.spawn(.{}, run, .{});\n"
                "}\n"
                "fn later() !void {\n"
                "    _ = try std.Thread.spawn(.{}, run, .{});\n"
                "}\n",
                encoding="utf-8",
            )
            (root / "src" / "platform" / "thread.zig").write_text(
                "pub fn spawn() void {\n    _ = std.Thread.spawn(.{}, f, .{});\n}\n",
                encoding="utf-8",
            )
            self.assertEqual(
                violations(root),
                ["src/after_test.zig:5", "src/aliased.zig:3", "src/direct.zig:2"],
            )

    def test_missing_src_is_an_error_not_an_empty_scan(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(NotADirectoryError):
                violations(Path(directory))


if __name__ == "__main__":
    unittest.main()
