from __future__ import annotations

import os
import re
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
HELPER = Path("src/api/http_connection.zig")
HELPER_METHOD = re.compile(r"(\w+)\s*\.\s*(receiveHead|bodyReader|bodyReaderDecompressing|readerDecompressing)\s*\(")
READER_CALL = re.compile(r"(\w+)\s*\.\s*reader\s*\(")
RESPONSE_NAME = re.compile(r"(response|resp)$", re.IGNORECASE)
MIN_RECEIVES = 27
MIN_READS = 25

SOURCE_ROOTS = ("src", "apps", "packages")


def zig_sources(root: Path) -> list[Path]:
    src = root / "src"
    if not src.is_dir():
        raise NotADirectoryError(str(src))
    found = []
    for name in SOURCE_ROOTS:
        for current, dirnames, filenames in os.walk(root / name):
            here = Path(current).relative_to(root)
            if name != "src" and len(here.parts) == 2:
                dirnames[:] = [d for d in dirnames if d != "tests"]
            found.extend(here / filename for filename in filenames if filename.endswith(".zig"))
    return sorted(path for path in found if path != HELPER)


def code_lines(text: str):
    for number, line in enumerate(text.splitlines(), 1):
        if not line.lstrip().startswith("//"):
            yield number, line


def scan(root: Path) -> tuple[list[str], int, int]:
    violations = []
    receives = 0
    reads = 0
    for relative in zig_sources(root):
        text = (root / relative).read_text(encoding="utf-8")
        for number, line in code_lines(text):
            bypasses = False
            for match in HELPER_METHOD.finditer(line):
                if match.group(1) != "http_connection":
                    bypasses = True
                elif match.group(2) == "receiveHead":
                    receives += 1
                else:
                    reads += 1
            for match in READER_CALL.finditer(line):
                if RESPONSE_NAME.search(match.group(1)):
                    bypasses = True
            if bypasses:
                violations.append(f"{relative.as_posix()}:{number}")
    return violations, receives, reads


class HttpAnswerDisciplineTest(unittest.TestCase):
    def test_every_answer_is_received_and_read_through_http_connection(self):
        violations, receives, reads = scan(ROOT)
        self.assertEqual(
            violations,
            [],
            "receive a response head with http_connection.receiveHead(&request, buffer) and read its body "
            "with http_connection.bodyReader(&response, buffer): std 0.16 reads the body of a 1xx, 204 or "
            "304 answer, and drains it in Request.deinit, until the server closes the connection (#579)",
        )
        self.assertGreaterEqual(receives, MIN_RECEIVES, "the scan no longer sees the receives it counted")
        self.assertGreaterEqual(reads, MIN_READS, "the scan no longer sees the body reads it counted")

    def test_scanner_reports_direct_receives_and_reads_and_skips_comments(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "src" / "api").mkdir(parents=True)
            (root / "src" / "direct.zig").write_text(
                "fn get(request: *Request) !void {\n"
                "    var response = try request.receiveHead(&redirect);\n"
                "    const reader = req.reader.bodyReader(&transfer, head.transfer_encoding, head.content_length);\n"
                "    const input = self.stream_response.reader(&self.stream_transfer);\n"
                "    const plain = resp.reader(&transfer);\n"
                "    const inflated = response.readerDecompressing(&transfer, &decompress, &window);\n"
                "}\n",
                encoding="utf-8",
            )
            (root / "src" / "fine.zig").write_text(
                "// response.reader(&transfer) reads a 204 to the end of the connection\n"
                "    /// request.receiveHead(&redirect) is wrapped\n"
                "fn get(request: *Request) !void {\n"
                "    const head = try http_connection.receiveHead(&request, &redirect);\n"
                "    const body = http_connection.bodyReader(&head, &transfer);\n"
                "    var file_reader = file.reader(io, &buffer);\n"
                "    const keys = teamwork_reader.reader();\n"
                "}\n",
                encoding="utf-8",
            )
            (root / "src" / "api" / "http_connection.zig").write_text(
                "pub fn receiveHead(request: *Request, buffer: []u8) !Response {\n"
                "    return request.receiveHead(buffer);\n"
                "}\n",
                encoding="utf-8",
            )
            violations, receives, reads = scan(root)
            self.assertEqual(
                violations,
                ["src/direct.zig:2", "src/direct.zig:3", "src/direct.zig:4", "src/direct.zig:5", "src/direct.zig:6"],
            )
            self.assertEqual((receives, reads), (1, 1))

    def test_missing_src_is_an_error_not_an_empty_scan(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(NotADirectoryError):
                scan(Path(directory))


if __name__ == "__main__":
    unittest.main()
