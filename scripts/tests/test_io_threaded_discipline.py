"""Every ``std.Io.Threaded`` in this repository is created through
``platform.signal.threadedIo``.

``std.Io.Threaded.init`` replaces SIGPIPE's disposition with a do-nothing
handler installed without SA_RESTART. Unlike SIG_IGN, a handler gets the signal
delivered, so a SIGPIPE (on macOS a write to a closed socket signals the whole
process) turns any thread's blocked recv/poll/accept/waitpid into EINTR.
``threadedIo`` keeps SIGPIPE ignored where the process asked for that (see
src/platform/signal.zig); one direct ``init`` call is enough to undo it.
"""
from __future__ import annotations

import errno
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
# The wrapper itself, plus its control tests that show what std does alone.
ALLOWED = {Path("src/platform/signal.zig")}
# Third-party trees are not ours to change.
THIRD_PARTY_DIRS = {"deps", "vendor", "node_modules"}
# Tool and build output. The scan must not even list these directories: the
# build keeps creating and deleting entries in .zig-cache/tmp while this test
# runs. Matched by name at any depth.
GENERATED_DIRS = {".git", ".zig-cache", ".zig", ".lake", "zig-out", ".claude"}
# Git-ignored output directories with generic names, matched only at the repo
# root (a tracked `src/output/` must stay scanned). Paths are POSIX-style
# relative to the root.
GENERATED_TREES = {
    "dist",
    "output",
    ".home",
    ".metacodes",
    "tests/e2e/runs",
    "evals/reports",
    "evals/runs",
}
SKIPPED_DIRS = THIRD_PARTY_DIRS | GENERATED_DIRS
# Also catches `const Threaded = std.Io.Threaded;` followed by `Threaded.init(`.
DIRECT_INIT = re.compile(r"\bThreaded\s*\.\s*init\s*\(")


def _tolerate_vanished(error: OSError) -> None:
    """``os.walk`` hook: a directory deleted after its parent was listed is gone,
    not a finding. Anything else (permissions, I/O) must not shrink the scan
    silently, so it propagates."""
    if not isinstance(error, (FileNotFoundError, NotADirectoryError)):
        raise error


def zig_sources(root: Path) -> list[Path]:
    """Root-relative paths of the Zig files the rule governs, sorted.

    Skipped directories are pruned during the walk so they are never listed at
    all; filtering ``rglob`` results afterwards would still descend into them.
    """
    if not root.is_dir():
        raise NotADirectoryError(str(root))
    found = []
    for current, dirnames, filenames in os.walk(root, onerror=_tolerate_vanished):
        here = Path(current).relative_to(root)
        dirnames[:] = [
            name
            for name in dirnames
            if name not in SKIPPED_DIRS and (here / name).as_posix() not in GENERATED_TREES
        ]
        found.extend(here / name for name in filenames if name.endswith(".zig"))
    return sorted(path for path in found if path not in ALLOWED)


def violations(root: Path) -> list[str]:
    """`path:line` for every direct Threaded.init call in a Zig file under root."""
    found = []
    for relative in zig_sources(root):
        try:
            text = (root / relative).read_text(encoding="utf-8")
        except FileNotFoundError:
            continue  # deleted between the directory listing and the read
        for number, line in enumerate(text.splitlines(), 1):
            code = line.split("//", 1)[0]
            if DIRECT_INIT.search(code):
                found.append(f"{relative.as_posix()}:{number}")
    return found


class IoThreadedDisciplineTest(unittest.TestCase):
    def test_repository_creates_io_threaded_only_through_threaded_io(self):
        self.assertEqual(
            violations(ROOT),
            [],
            "create std.Io.Threaded with @import(\"platform\").signal.threadedIo "
            "(see src/platform/signal.zig)",
        )

    def test_scanner_reports_direct_and_aliased_calls_but_not_comments(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "src").mkdir()
            (root / "src" / "direct.zig").write_text(
                "var io = std.Io.Threaded.init(gpa, .{});\n", encoding="utf-8"
            )
            (root / "src" / "aliased.zig").write_text(
                "const Threaded = std.Io.Threaded;\nvar io = Threaded.init(gpa, .{});\n",
                encoding="utf-8",
            )
            (root / "src" / "fine.zig").write_text(
                "// std.Io.Threaded.init is wrapped\n"
                "var io = @import(\"platform\").signal.threadedIo(gpa, .{});\n"
                "const single = std.Io.Threaded.init_single_threaded;\n",
                encoding="utf-8",
            )
            (root / "vendor").mkdir()
            (root / "vendor" / "third_party.zig").write_text(
                "var io = std.Io.Threaded.init(gpa, .{});\n", encoding="utf-8"
            )
            self.assertEqual(violations(root), ["src/aliased.zig:2", "src/direct.zig:1"])

    def test_walk_covers_every_tracked_first_party_zig_file(self):
        # Pruning generated directories must never hide tracked source.
        try:
            listing = subprocess.run(
                ["git", "-C", str(ROOT), "ls-files", "-z", "--", "*.zig"],
                check=True,
                capture_output=True,
                text=True,
            ).stdout
        except (OSError, subprocess.CalledProcessError):
            self.skipTest("not a git checkout")
        tracked = {Path(name) for name in listing.split("\0") if name}
        governed = {
            path
            for path in tracked
            if not THIRD_PARTY_DIRS.intersection(path.parts)
            and path not in ALLOWED
            and (ROOT / path).exists()
        }
        self.assertTrue(governed, "git reported no tracked first-party Zig files")
        self.assertEqual(sorted(governed - set(zig_sources(ROOT))), [])


def write(root: Path, relative: str, text: str) -> None:
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


DIRECT = "var io = std.Io.Threaded.init(gpa, .{});\n"


class ScanIsDeterministicTest(unittest.TestCase):
    def listed_directories(self, root: Path, spy):
        """Run the scan with os.scandir wrapped; return the directories it listed."""
        listed = []
        real = os.scandir

        def scandir(path="."):
            listed.append(Path(path).relative_to(root).as_posix())
            return spy(real, Path(path), path)

        with mock.patch("os.scandir", scandir):
            result = violations(root)
        return result, sorted(listed)

    def test_generated_and_third_party_directories_are_never_listed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write(root, "src/bad.zig", DIRECT)
            write(root, "src/ok.zig", "const x = 1;\n")
            # Name-matched at any depth, including inside source trees.
            write(root, ".zig-cache/tmp/abc/leak.zig", DIRECT)
            write(root, "zig-out/lib/leak.zig", DIRECT)
            write(root, ".git/leak.zig", DIRECT)
            write(root, "src/vendor/leak.zig", DIRECT)
            write(root, "src/node_modules/leak.zig", DIRECT)
            # Root-anchored generic names and nested ignored trees.
            write(root, "output/leak.zig", DIRECT)
            write(root, "tests/e2e/runs/r1/leak.zig", DIRECT)
            write(root, "tests/unit.zig", "const x = 1;\n")
            result, listed = self.listed_directories(
                root, lambda real, path, raw: real(raw)
            )
            self.assertEqual(result, ["src/bad.zig:1"])
            # Pruned while walking: the excluded directories were never opened.
            self.assertEqual(listed, [".", "src", "tests", "tests/e2e"])

    def test_generic_names_are_pruned_only_at_the_repo_root(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write(root, "output/hidden.zig", DIRECT)
            write(root, "src/output/kept.zig", DIRECT)
            write(root, "src/dist/kept.zig", DIRECT)
            self.assertEqual(violations(root), ["src/dist/kept.zig:1", "src/output/kept.zig:1"])

    def test_directory_vanishing_mid_walk_is_not_an_error(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write(root, "src/gone/a.zig", DIRECT)
            write(root, "src/kept/direct.zig", DIRECT)

            def spy(real, path, raw):
                if path.name == "gone":  # removed after src/ was listed
                    raise FileNotFoundError(errno.ENOENT, os.strerror(errno.ENOENT), raw)
                return real(raw)

            result, listed = self.listed_directories(root, spy)
            self.assertEqual(result, ["src/kept/direct.zig:1"])
            self.assertIn("src/gone", listed)  # the scan really tried to enter it

    def test_file_vanishing_between_listing_and_read_is_not_an_error(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write(root, "src/gone.zig", DIRECT)
            write(root, "src/direct.zig", DIRECT)
            real_read_text = Path.read_text

            def read_text(self, *args, **kwargs):
                if self.name == "gone.zig":
                    raise FileNotFoundError(errno.ENOENT, os.strerror(errno.ENOENT), str(self))
                return real_read_text(self, *args, **kwargs)

            with mock.patch.object(Path, "read_text", read_text):
                self.assertEqual(violations(root), ["src/direct.zig:1"])

    def test_unreadable_directory_still_fails_loudly(self):
        # Only "it is gone" is tolerated; a directory the scan cannot read would
        # otherwise shrink coverage without anyone noticing.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write(root, "src/locked/a.zig", DIRECT)

            def spy(real, path, raw):
                if path.name == "locked":
                    raise PermissionError(errno.EACCES, os.strerror(errno.EACCES), raw)
                return real(raw)

            with self.assertRaises(PermissionError):
                self.listed_directories(root, spy)

    def test_missing_root_is_an_error_not_an_empty_scan(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(NotADirectoryError):
                violations(Path(directory) / "missing")


if __name__ == "__main__":
    unittest.main()
