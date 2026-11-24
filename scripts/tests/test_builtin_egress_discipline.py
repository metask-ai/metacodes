"""No built-in destination that is on by default is cleartext to a public host (#474).

The CLI used to fall back to a System-One advisor service at
``http://58.211.6.133:10420`` (``BUILTIN_DEFAULT`` in ``src/jev/runtime.zig``)
whenever ``config.json`` and the environment named none. Every session whose
TinyKG store held a matching memory then sent the first 400 bytes of the request
and up to eight 480-byte memory excerpts over plain HTTP, across the public
network, to an IP literal with no TLS identity, and nobody had been asked.

Two rules over the product's Zig sources (``src``, ``sdk``, ``lib``, ``example``
and the build tools under ``scripts``), outside test blocks and comments:

1. A ``http://`` literal naming a host that is not loopback is a built-in
   cleartext destination. Product code may not contain one unless it is listed
   in ``ALLOWED_CLEARTEXT`` below with the reason it is not on by default, and a
   listed entry whose literal is gone is reported so the exemption goes with it.
2. While a listed destination is the Jev built-in default, nothing may take it
   by default: ``CLI_USES_BUILTIN_DEFAULT`` (the one place the CLI decides, read
   by the session and by ``metacodes doctor``) is located exactly once and is
   ``false``, and no production line assigns ``true`` to anything named
   ``*builtin_default``.

Test blocks are skipped, and so is any file named ``*_test.zig``: their
fixtures name hosts that never see traffic. The behavioural side of the same
promise is in ``tests/component/jev_default_test.zig`` (``metacodes doctor`` of
the real CLI reports the advisor off, and a Run with memories and no advisor
consults nothing).
"""
from __future__ import annotations

import os
import re
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]

# Where product Zig lives. `src` is the binary and its library; the rest ship or
# build with it. Missing `src` is an error, not an empty scan.
SCAN_ROOTS = ("src", "sdk", "lib", "example", "scripts")
SKIPPED_DIRS = {".git", ".zig-cache", "zig-out", ".lake", "node_modules", "deps", "vendor"}

# Cleartext destinations the product is allowed to name, keyed by
# (root-relative POSIX path, `host[:port]` as written) with why each is not on
# by default. Rule 2 below guards the first one.
JEV_DEFAULT = ("src/jev/runtime.zig", "58.211.6.133:10420")
ALLOWED_CLEARTEXT = {
    JEV_DEFAULT: (
        "Jev BUILTIN_DEFAULT: taken only by a host that sets Config.jev_builtin_default; "
        "no host here does (rule 2)"
    ),
}

CLEARTEXT = re.compile(r"\bhttp://(?P<authority>[A-Za-z0-9\[][A-Za-z0-9._\-:\]\[%@]*)", re.IGNORECASE)
TEST_OPEN = re.compile(r"^(\s*)test\b.*\{\s*$")
DECISION = re.compile(r"\bpub\s+const\s+CLI_USES_BUILTIN_DEFAULT\s*(?::\s*bool\s*)?=\s*(true|false)\s*;")
TAKEN_BY_DEFAULT = re.compile(r"builtin_default\b[^;\n=]*=\s*true\b", re.IGNORECASE)
CHAR_LITERAL = re.compile(r"'(?:\\[^']+|[^\\'])'")
IPV4_LOOPBACK = re.compile(r"^127(?:\.\d{1,3}){3}$")


def strip_comment(line: str) -> str:
    """The code of one Zig line: a trailing ``//`` comment cut where it starts
    outside a string or character literal, so ``"http://host"`` survives.

    A multiline string line (first token ``\\\\``) is all string and kept whole.
    """
    if line.lstrip().startswith("\\\\"):
        return line
    kept = []
    index = 0
    in_string = False
    while index < len(line):
        char = line[index]
        if in_string:
            kept.append(char)
            if char == "\\" and index + 1 < len(line):
                kept.append(line[index + 1])
                index += 2
                continue
            if char == '"':
                in_string = False
        elif char == '"':
            in_string = True
            kept.append(char)
        elif char == "'":
            literal = CHAR_LITERAL.match(line, index)
            if literal:
                kept.append(literal.group(0))
                index = literal.end()
                continue
            kept.append(char)
        elif line.startswith("//", index):
            break
        else:
            kept.append(char)
        index += 1
    return "".join(kept)


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
        yield number, strip_comment(line)


def zig_sources(root: Path) -> list[Path]:
    """Root-relative paths of the product Zig files, sorted."""
    src = root / "src"
    if not src.is_dir():
        raise NotADirectoryError(str(src))
    found = []
    for name in SCAN_ROOTS:
        top = root / name
        if not top.is_dir():
            continue
        for current, dirnames, filenames in os.walk(top):
            dirnames[:] = [d for d in dirnames if d not in SKIPPED_DIRS]
            here = Path(current).relative_to(root)
            found.extend(
                here / filename
                for filename in filenames
                if filename.endswith(".zig") and not filename.endswith("_test.zig")
            )
    return sorted(found)


def host_of(authority: str) -> str:
    """The lower-cased host of ``[user@]host[:port]`` (IPv6 brackets dropped)."""
    host = authority.rsplit("@", 1)[-1].lower()
    if host.startswith("["):
        return host[1:].split("]", 1)[0]
    return host.split(":", 1)[0]


def is_loopback(host: str) -> bool:
    return (
        host == "localhost"
        or host.endswith(".localhost")
        or host in {"::1", "0:0:0:0:0:0:0:1"}
        or bool(IPV4_LOOPBACK.match(host))
    )


def production_code(root: Path):
    """(root-relative POSIX path, line number, code) of every production line."""
    for relative in zig_sources(root):
        text = (root / relative).read_text(encoding="utf-8", errors="replace")
        for number, code in production_lines(text):
            yield relative.as_posix(), number, code


def cleartext_destinations(root: Path) -> list[tuple[str, int, str]]:
    """(path, line, authority) of every non-loopback ``http://`` literal."""
    found = []
    for path, number, code in production_code(root):
        for match in CLEARTEXT.finditer(code):
            authority = match.group("authority")
            if not is_loopback(host_of(authority)):
                found.append((path, number, authority))
    return found


def default_on_problems(root: Path) -> list[str]:
    """Rule 2: nothing takes the cleartext built-in default by default."""
    decisions = []
    problems = []
    for path, number, code in production_code(root):
        decision = DECISION.search(code)
        if decision:
            decisions.append((path, number, decision.group(1)))
        if TAKEN_BY_DEFAULT.search(code) and not decision:
            problems.append(
                f"{path}:{number}: sets a built-in default to true while a cleartext default exists; "
                "put the service in config.json or METACODES_JEV_URL instead (#474)"
            )
        if decision and decision.group(1) == "true":
            problems.append(
                f"{path}:{number}: CLI_USES_BUILTIN_DEFAULT is true while the built-in default is cleartext to a "
                "public host: a CLI session would send memory excerpts over plain HTTP unasked (#474)"
            )
    if len(decisions) != 1:
        problems.append(
            "CLI_USES_BUILTIN_DEFAULT must be declared exactly once (it is the one place the CLI decides, read by "
            f"the session and by doctor); found {len(decisions)}"
        )
    return problems


def problems(root: Path, allowed: dict | None = None) -> list[str]:
    """Everything the two rules report for the tree at ``root``."""
    allowed = ALLOWED_CLEARTEXT if allowed is None else allowed
    report = []
    matched = set()
    for path, number, authority in cleartext_destinations(root):
        key = (path, authority)
        if key in allowed:
            matched.add(key)
            continue
        report.append(
            f"{path}:{number}: built-in destination http://{authority} is cleartext to a public host; "
            "use https:// (or a loopback address), or list it in ALLOWED_CLEARTEXT with why it is not on by default (#474)"
        )
    for key in sorted(set(allowed) - matched):
        report.append(
            f"{key[0]}: ALLOWED_CLEARTEXT lists http://{key[1]} but no production literal matches; drop the exemption"
        )
    if JEV_DEFAULT in matched:
        report.extend(default_on_problems(root))
    return report


class BuiltinEgressDisciplineTest(unittest.TestCase):
    def test_no_default_on_destination_is_cleartext_to_a_public_host(self):
        self.assertEqual(problems(ROOT), [])

    def test_the_cli_decision_is_off_and_is_what_main_and_doctor_read(self):
        runtime = (ROOT / "src" / "jev" / "runtime.zig").read_text(encoding="utf-8")
        main = (ROOT / "src" / "main.zig").read_text(encoding="utf-8")
        self.assertRegex(runtime, r"pub const CLI_USES_BUILTIN_DEFAULT = false;")
        # The session and doctor both take it from the constant, so they cannot disagree.
        self.assertIn("config.jev_builtin_default = @import(\"metacodes-internal\").jev.runtime.CLI_USES_BUILTIN_DEFAULT;", main)
        self.assertIn("jev.resolve(arena, io, state_root, jev.CLI_USES_BUILTIN_DEFAULT, jev.rawFromEnv())", main)

    def test_scanner_reads_literals_not_comments_tests_or_placeholders(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "src").mkdir()
            (root / "src" / "dest.zig").write_text(
                'const a = "http://203.0.113.9:8080/v1";\n'
                'const b = "https://203.0.113.9/v1";\n'
                'const c = "http://127.0.0.1:1";\n'
                'const d = "http://localhost:2";\n'
                'const e = "http://[::1]:3/x";\n'
                'const f = "http://127.9.8.7";\n'
                'const g = "http://dev.localhost/y";\n'
                'const h = "http://example.com/z"; // trailing comment\n'
                "// const i = \"http://198.51.100.1\";\n"
                '/// doc "http://198.51.100.2"\n'
                'const j = "a" ++ "//" ++ "http://198.51.100.3"; // after\n'
                'const k = std.mem.startsWith(u8, url, "http://");\n'
                'const l = try std.fmt.bufPrint(&buf, "http://{f}", .{addr});\n'
                'const m = "http://" ++ name;\n'
                "const n = '\"'; const o = \"http://198.51.100.4\";\n"
                'const p = "http://user:pw@198.51.100.5:9/x";\n'
                "const q =\n"
                "    \\\\http://198.51.100.6/multiline\n"
                ";\n"
                'test "fixtures name hosts" {\n'
                '    const t = "http://203.0.113.77";\n'
                "}\n"
                'const after = "http://198.51.100.7";\n',
                encoding="utf-8",
            )
            (root / "src" / "other_test.zig").write_text('const t = "http://203.0.113.99";\n', encoding="utf-8")
            self.assertEqual(
                [(path, number, authority) for path, number, authority in cleartext_destinations(root)],
                [
                    ("src/dest.zig", 1, "203.0.113.9:8080"),
                    ("src/dest.zig", 8, "example.com"),
                    ("src/dest.zig", 11, "198.51.100.3"),
                    ("src/dest.zig", 15, "198.51.100.4"),
                    ("src/dest.zig", 16, "user:pw@198.51.100.5:9"),
                    ("src/dest.zig", 18, "198.51.100.6"),
                    ("src/dest.zig", 23, "198.51.100.7"),
                ],
            )

    def test_loopback_means_127_localhost_and_ipv6_loopback_only(self):
        for host in ("127.0.0.1", "127.8.9.10", "localhost", "LOCALHOST", "x.localhost", "::1"):
            self.assertTrue(is_loopback(host_of(f"{host}:80" if ":" not in host else f"[{host}]:80")), host)
        for host in ("0.0.0.0", "10.0.0.5", "128.0.0.1", "58.211.6.133", "localhost.example.com", "1270.0.0.1"):
            self.assertFalse(is_loopback(host_of(f"{host}:80")), host)

    def test_an_unlisted_cleartext_destination_is_reported_and_https_is_not(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "src").mkdir()
            (root / "src" / "feature.zig").write_text(
                'pub const telemetry = "http://203.0.113.20:4318";\npub const ok = "https://203.0.113.20/v1";\n',
                encoding="utf-8",
            )
            report = problems(root, {})
            self.assertEqual(len(report), 1)
            self.assertIn("src/feature.zig:1: built-in destination http://203.0.113.20:4318 is cleartext", report[0])

    def test_a_listed_destination_that_is_gone_is_reported_so_the_exemption_goes_too(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "src").mkdir()
            (root / "src" / "runtime.zig").write_text('pub const url = "https://jev.example/";\n', encoding="utf-8")
            report = problems(root, {("src/runtime.zig", "198.51.100.30:1"): "gone"})
            self.assertEqual(len(report), 1)
            self.assertIn("no production literal matches; drop the exemption", report[0])

    def _tree_with_default(self, root: Path, decision: str, main: str = "") -> None:
        (root / "src" / "jev").mkdir(parents=True)
        (root / "src" / "jev" / "runtime.zig").write_text(
            'pub const BUILTIN_DEFAULT: Raw = .{ .url = "http://58.211.6.133:10420" };\n' + decision,
            encoding="utf-8",
        )
        (root / "src" / "main.zig").write_text(main, encoding="utf-8")

    def test_a_host_taking_the_cleartext_default_is_reported(self):
        for label, decision, main in (
            ("the constant is true", "pub const CLI_USES_BUILTIN_DEFAULT = true;\n", ""),
            ("main sets the flag", "pub const CLI_USES_BUILTIN_DEFAULT = false;\n", "fn run() void {\n    config.jev_builtin_default = true;\n}\n"),
            ("a typed default of true", "pub const CLI_USES_BUILTIN_DEFAULT = false;\n", "jev_builtin_default: bool = true,\n"),
        ):
            with self.subTest(label), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self._tree_with_default(root, decision, main)
                report = problems(root, {JEV_DEFAULT: "test"})
                self.assertEqual(len(report), 1, report)

    def test_the_default_may_stay_off_and_tests_may_opt_in(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._tree_with_default(
                root,
                "pub const CLI_USES_BUILTIN_DEFAULT = false;\n"
                'test "a library host opts in" {\n    config.jev_builtin_default = true;\n}\n',
                "fn run() void {\n    config.jev_builtin_default = runtime.CLI_USES_BUILTIN_DEFAULT;\n}\n",
            )
            self.assertEqual(problems(root, {JEV_DEFAULT: "test"}), [])

    def test_the_decision_must_be_declared_exactly_once(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._tree_with_default(root, "")
            report = problems(root, {JEV_DEFAULT: "test"})
            self.assertEqual(len(report), 1)
            self.assertIn("declared exactly once", report[0])
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._tree_with_default(
                root,
                "pub const CLI_USES_BUILTIN_DEFAULT = false;\n",
                "pub const CLI_USES_BUILTIN_DEFAULT = false;\n",
            )
            report = problems(root, {JEV_DEFAULT: "test"})
            self.assertEqual(len(report), 1)
            self.assertIn("found 2", report[0])

    def test_rule_two_stands_down_once_the_default_is_no_longer_cleartext(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "src" / "jev").mkdir(parents=True)
            (root / "src" / "jev" / "runtime.zig").write_text(
                'pub const BUILTIN_DEFAULT: Raw = .{ .url = "https://jev.example" };\n'
                "pub const CLI_USES_BUILTIN_DEFAULT = true;\n",
                encoding="utf-8",
            )
            # The exemption itself is reported as stale; rule 2 no longer applies.
            report = problems(root, {JEV_DEFAULT: "test"})
            self.assertEqual(len(report), 1)
            self.assertIn("drop the exemption", report[0])

    def test_missing_src_is_an_error_not_an_empty_scan(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(NotADirectoryError):
                problems(Path(directory))


if __name__ == "__main__":
    unittest.main()
