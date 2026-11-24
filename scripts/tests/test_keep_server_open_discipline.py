from __future__ import annotations

import os
import re
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
HELPER = Path("src/api/http_connection.zig")
CLOSES_ITSELF = re.compile(r"\.keep_alive\s*=\s*false\b")
ASKS_TO_KEEP_OPEN = re.compile(r"\bhttp_connection\s*\.\s*keepServerOpen\s*\(")
SENDS = re.compile(r"\bhttp_connection\s*\.\s*(sendBodiless|sendBodyComplete)\s*\(")
MIN_REQUESTS = 11

SOURCE_ROOTS = ("src", "apps")


def zig_sources(root: Path) -> list[Path]:
    src = root / "src"
    if not src.is_dir():
        raise NotADirectoryError(str(src))
    found = []
    for name in SOURCE_ROOTS:
        for current, _dirnames, filenames in os.walk(root / name):
            here = Path(current).relative_to(root)
            found.extend(here / filename for filename in filenames if filename.endswith(".zig"))
    return sorted(path for path in found if path != HELPER)


def code_lines(text: str) -> list[tuple[int, str]]:
    return [
        (number, line)
        for number, line in enumerate(text.splitlines(), 1)
        if not line.lstrip().startswith("//")
    ]


def asks_before_send(lines: list[tuple[int, str]]) -> bool:
    asked = False
    for _number, line in lines:
        if ASKS_TO_KEEP_OPEN.search(line):
            asked = True
        if SENDS.search(line):
            return asked
    return False


def scan(root: Path) -> tuple[list[str], int]:
    violations = []
    requests = 0
    for relative in zig_sources(root):
        lines = code_lines((root / relative).read_text(encoding="utf-8"))
        for index, (number, line) in enumerate(lines):
            if not CLOSES_ITSELF.search(line):
                continue
            if asks_before_send(lines[index + 1 :]):
                requests += 1
            else:
                violations.append(f"{relative.as_posix()}:{number}")
    return violations, requests


class KeepServerOpenDisciplineTest(unittest.TestCase):
    def test_every_request_that_closes_its_own_connection_asks_the_server_to_keep_it_open(self):
        violations, requests = scan(ROOT)
        self.assertEqual(
            violations,
            [],
            "call http_connection.keepServerOpen(&request) before sending a request with keep_alive = false: "
            "std writes connection: close for it, and behind a transparent proxy the server's close can "
            "overtake the end of its answer (#573, #661)",
        )
        self.assertGreaterEqual(requests, MIN_REQUESTS, "the scan no longer sees the requests it counted")

    def test_scanner_pairs_each_request_with_a_call_before_its_send_and_skips_comments(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "src" / "api").mkdir(parents=True)
            (root / "src" / "missing.zig").write_text(
                "fn post(client: *Client) !void {\n"
                "    var request = try client.request(.POST, uri, .{\n"
                "        .keep_alive = false,\n"
                "    });\n"
                "    // http_connection.keepServerOpen(&request);\n"
                "    try http_connection.sendBodyComplete(&request, body);\n"
                "}\n"
                "fn late(client: *Client) !void {\n"
                "    var request = try client.request(.GET, uri, .{ .keep_alive = false });\n"
                "    try http_connection.sendBodiless(&request);\n"
                "    http_connection.keepServerOpen(&request);\n"
                "}\n"
                "fn unsent(client: *Client) !void {\n"
                "    _ = try client.request(.GET, uri, .{ .keep_alive = false });\n"
                "}\n",
                encoding="utf-8",
            )
            (root / "src" / "fine.zig").write_text(
                "// .keep_alive = false used to say connection: close\n"
                "fn get(client: *Client) !void {\n"
                "    var request = try client.request(.GET, uri, .{\n"
                "        .keep_alive = false, // never pooled\n"
                "    });\n"
                "    http_connection.keepServerOpen(&request);\n"
                "    try registry.register(&request);\n"
                "    try http_connection.sendBodiless(&request);\n"
                "}\n"
                "fn pooled(client: *Client) !void {\n"
                "    var request = try client.request(.POST, uri, .{});\n"
                "    try http_connection.sendBodyComplete(&request, body);\n"
                "}\n",
                encoding="utf-8",
            )
            (root / "src" / "api" / "http_connection.zig").write_text(
                "test {\n"
                "    var request = try client.request(.GET, uri, .{ .keep_alive = false });\n"
                "}\n",
                encoding="utf-8",
            )
            violations, requests = scan(root)
            self.assertEqual(violations, ["src/missing.zig:3", "src/missing.zig:9", "src/missing.zig:14"])
            self.assertEqual(requests, 1)

    def test_missing_src_is_an_error_not_an_empty_scan(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(NotADirectoryError):
                scan(Path(directory))


if __name__ == "__main__":
    unittest.main()
