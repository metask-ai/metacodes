from __future__ import annotations

import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

from scripts.check_doc_facts import SCHEMA, FactsError, check, load_facts, main

PROJECT_ROOT = Path(__file__).resolve().parents[2]
REGISTRY = PROJECT_ROOT / "release/doc_facts.json"


def _fact(source_regex: str, assertion_regex: str) -> dict:
    return {
        "schema": SCHEMA,
        "facts": [
            {
                "id": "x",
                "source": {"file": "src.txt", "regex": source_regex},
                "assert_in": [{"file": "doc.md", "regex": assertion_regex}],
            }
        ],
    }


class DocFactsTest(unittest.TestCase):
    """The fact gate on synthetic trees, plus the checked-in registry on the real one."""

    def _tree(self, source: str, document: str, registry: dict) -> tuple[Path, Path]:
        """A throwaway root holding ``src.txt``, ``doc.md`` and a registry."""
        holder = tempfile.TemporaryDirectory()
        self.addCleanup(holder.cleanup)
        root = Path(holder.name)
        (root / "release").mkdir()
        (root / "src.txt").write_text(source, encoding="utf-8")
        (root / "doc.md").write_text(document, encoding="utf-8")
        path = root / "release/facts.json"
        path.write_text(json.dumps(registry), encoding="utf-8")
        return root, path

    def _registry_file(self, data: dict) -> Path:
        holder = tempfile.TemporaryDirectory()
        self.addCleanup(holder.cleanup)
        path = Path(holder.name) / "facts.json"
        path.write_text(json.dumps(data), encoding="utf-8")
        return path

    def _main(self, argv: list[str]) -> tuple[int, str]:
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = main(argv)
        return status, output.getvalue()

    def test_checked_in_registry_holds_on_the_real_tree(self) -> None:
        """Every registered assertion point agrees with its authority in this checkout."""
        self.assertEqual([], check(PROJECT_ROOT, REGISTRY))

    def test_a_tampered_assertion_is_reported_with_file_line_and_both_values(self) -> None:
        """A document stating another value is named with its line and both numbers."""
        root, path = self._tree("v = 7", "header\nv = 6\n", _fact(r"v = (\d+)", r"v = (\d+)"))
        findings = check(root, path)
        self.assertEqual(1, len(findings))
        finding = findings[0]
        self.assertEqual(("doc.md", 2, "x"), (finding.file, finding.line, finding.fact_id))
        self.assertIn("expected 7", finding.message)
        self.assertIn("found 6", finding.message)
        status, output = self._main(["--root", str(root), "--facts", str(path)])
        self.assertEqual(1, status)
        self.assertIn("doc.md:2: x: expected 7", output)

    def test_a_source_that_matches_zero_or_several_times_fails_closed(self) -> None:
        """An authority that cannot be located exactly once is a broken sensor, not a pass."""
        for source, count in ((r"missing (\d+)", 0), (r"v = (\d+)", 2)):
            with self.subTest(matches=count):
                root, path = self._tree("v = 7\nv = 8\n", "v = 7\n", _fact(source, r"v = (\d+)"))
                findings = check(root, path)
                self.assertEqual(1, len(findings))
                self.assertEqual("release/facts.json", findings[0].file)
                self.assertIsNone(findings[0].line)
                self.assertIn(f"matched {count} times", findings[0].message)

    def test_a_pattern_that_matches_nothing_is_a_detached_sensor(self) -> None:
        """A reworded sentence must fail the gate instead of switching it off."""
        root, path = self._tree("v = 7", "v = 7\n", _fact(r"v = (\d+)", r"x = (\d+)"))
        findings = check(root, path)
        self.assertEqual(1, len(findings))
        self.assertIsNone(findings[0].line)
        self.assertIn("sensor detached", findings[0].message)
        status, _ = self._main(["--root", str(root), "--facts", str(path)])
        self.assertEqual(1, status)

    def test_an_unreadable_or_malformed_authority_is_a_finding_not_a_crash(self) -> None:
        """A missing authority file, or JSON that does not parse, ends with a finding and exit 1."""
        registry = {
            "schema": SCHEMA,
            "facts": [
                {
                    "id": "x",
                    "source": {"file": "missing.json", "json": "version"},
                    "assert_in": [{"file": "doc.md", "regex": r"v = (\d+)"}],
                }
            ],
        }
        root, path = self._tree("unused", "v = 7\n", registry)
        findings = check(root, path)
        self.assertEqual(1, len(findings))
        self.assertEqual(("missing.json", None, "x"), (findings[0].file, findings[0].line, findings[0].fact_id))
        self.assertIn("cannot read authority", findings[0].message)

        (root / "missing.json").write_text("{not json", encoding="utf-8")
        findings = check(root, path)
        self.assertEqual(1, len(findings))
        self.assertIn("cannot read authority", findings[0].message)
        status, output = self._main(["--root", str(root), "--facts", str(path)])
        self.assertEqual(1, status)
        self.assertIn("checked 1 facts", output)

    def test_registry_shape_is_validated(self) -> None:
        """A regex without a capture group, a missing assert_in and a wrong schema are refused."""
        no_group = _fact("v", r"v = (\d+)")
        no_assertions = {
            "schema": SCHEMA,
            "facts": [{"id": "x", "source": {"file": "src.txt", "regex": r"v = (\d+)"}}],
        }
        wrong_schema = {"schema": "wrong", "facts": []}
        for word, data in (
            ("capture group", no_group),
            ("assert_in", no_assertions),
            ("schema", wrong_schema),
        ):
            with self.subTest(problem=word):
                with self.assertRaisesRegex(FactsError, word):
                    load_facts(self._registry_file(data))

    def test_main_returns_zero_on_the_real_tree(self) -> None:
        """The command line entry point is green on this checkout and prints its summary."""
        status, output = self._main([])
        self.assertEqual(0, status)
        self.assertRegex(output, r"checked \d+ facts and \d+ assertion points in \d+ files")


if __name__ == "__main__":
    unittest.main()
