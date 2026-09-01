"""Unit tests for the trajectory audit.

Synthetic transcripts only: the script's whole point is to run against a real
``~/.metacodes``, so its tests must not need one.
"""
from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from scripts.audit_trajectories import Audit, _is_rerun, per_result_bytes, scan

ARTIFACT_ID = "sha256:" + "a" * 64


def envelope(projection: str, artifact_id: str | None = ARTIFACT_ID) -> str:
    """A projection envelope as the Zig writer emits one: schema first."""
    body = {
        "schema_version": "metacodes.tool-result-projection.v1",
        "projection": projection,
        "artifact_id": artifact_id,
        "original_bytes": 999,
        "recoverable": projection == "artifact",
    }
    return json.dumps(body)


def use(uid: str, name: str, **inp) -> dict:
    return {"type": "tool_use", "id": uid, "name": name, "input": inp}


def result(uid: str, content: str) -> dict:
    return {"type": "tool_result", "tool_use_id": uid, "content": content}


def line(*blocks: dict) -> str:
    return json.dumps({"role": "user", "blocks": list(blocks)})


def bash_envelope(*, truncated: bool, stdout: str = "out") -> str:
    return json.dumps(
        {
            "schema_version": "metacodes.bash-result.v2",
            "stdout": stdout,
            "stdout_truncated": truncated,
            "exit_code": 0,
        }
    )


class PerResultBudgetTest(unittest.TestCase):
    def test_mirrors_the_zig_derivation_including_both_clamps(self):
        self.assertEqual(per_result_bytes(0), 8 * 1024)
        self.assertEqual(per_result_bytes(32_000), 8 * 1024)  # floor
        self.assertEqual(per_result_bytes(200_000), 25_000)
        self.assertEqual(per_result_bytes(10_000_000), 64 * 1024)  # ceiling


class SizeAccountingTest(unittest.TestCase):
    def test_sizes_are_attributed_to_the_tool_that_produced_them(self):
        audit = Audit(budget=100)
        audit.add_session(
            "\n".join(
                [
                    line(use("a", "Bash", command="echo hi"), result("a", "x" * 250)),
                    line(use("b", "Read", file_path="/f"), result("b", "y" * 10)),
                ]
            )
        )
        summary = audit.report(top=10)
        self.assertEqual(summary["results"], 2)
        self.assertEqual(summary["over_budget"], 1)
        by_tool = {row["tool"]: row for row in summary["tools"]}
        self.assertEqual(by_tool["Bash"]["max"], 250)
        self.assertEqual(by_tool["Bash"]["over_budget"], 1)
        self.assertEqual(by_tool["Read"]["over_budget"], 0)

    def test_a_result_whose_tool_use_is_missing_is_counted_but_not_attributed(self):
        # Transcripts are append-only and can be read mid-write; a dangling
        # tool_result must not be dropped silently nor blamed on a tool.
        audit = Audit(budget=1000)
        audit.add_session(line(result("orphan", "z" * 20)))
        summary = audit.report(top=10)
        self.assertEqual(summary["results"], 1)
        self.assertEqual(summary["unattributed_results"], 1)
        self.assertEqual(summary["tools"], [])


class SpillRecoveryTest(unittest.TestCase):
    def test_a_spill_followed_by_a_recovery_call_is_paired(self):
        audit = Audit(budget=1000)
        audit.add_session(
            "\n".join(
                [
                    line(use("a", "Grep", pattern="x"), result("a", envelope("artifact"))),
                    line(use("b", "ReadArtifact", artifact_id=ARTIFACT_ID)),
                ]
            )
        )
        summary = audit.report(top=10)
        self.assertEqual(summary["spilled_to_artifact"], 1)
        self.assertEqual(summary["spills_recovered"], 1)

    def test_a_spill_nobody_reads_back_stays_unrecovered(self):
        # The number worth looking at: a spill that is never recovered from
        # bought a round trip for nothing.
        audit = Audit(budget=1000)
        audit.add_session(
            "\n".join(
                [
                    line(use("a", "Grep", pattern="x"), result("a", envelope("artifact"))),
                    line(use("b", "Edit", file_path="/f")),
                ]
            )
        )
        summary = audit.report(top=10)
        self.assertEqual(summary["spilled_to_artifact"], 1)
        self.assertEqual(summary["spills_recovered"], 0)


    def test_a_fallback_envelope_is_not_a_recoverable_spill(self):
        # `projection:"fallback"` shares the schema prefix but has no artifact
        # behind it. Counting it as a spill and then arming the detector meant
        # any unrelated read that came next was scored as a recovery.
        audit = Audit(budget=1000)
        audit.add_session(
            "\n".join(
                [
                    line(
                        use("a", "Grep", pattern="x"),
                        result("a", envelope("fallback", artifact_id=None)),
                    ),
                    line(use("b", "Read", file_path="/unrelated")),
                ]
            )
        )
        summary = audit.report(top=10)
        self.assertEqual(summary["spilled_to_artifact"], 0)
        self.assertEqual(summary["spills_recovered"], 0)

    def test_a_read_that_does_not_name_the_artifact_is_not_a_recovery(self):
        # Adjacency was the old test. With the staging path gone, only an
        # explicit artifact_id can recover a spill.
        audit = Audit(budget=1000)
        audit.add_session(
            "\n".join(
                [
                    line(use("a", "Grep", pattern="x"), result("a", envelope("artifact"))),
                    line(use("b", "ReadArtifact", artifact_id="sha256:" + "b" * 64)),
                ]
            )
        )
        summary = audit.report(top=10)
        self.assertEqual(summary["spilled_to_artifact"], 1)
        self.assertEqual(summary["spills_recovered"], 0)


class ByteCountingTest(unittest.TestCase):
    def test_sizes_are_utf8_bytes_not_code_points(self):
        # 3000 Chinese characters are 9000 UTF-8 bytes. Counting code points
        # under-reports exactly the results most likely to be over budget.
        audit = Audit(budget=8 * 1024)
        audit.add_session(line(use("a", "Read", file_path="/f"), result("a", "汉" * 3000)))
        summary = audit.report(top=10)
        self.assertEqual(summary["max"], 9000)
        self.assertEqual(summary["over_budget"], 1)


class RerunDetectionTest(unittest.TestCase):
    def test_the_issue_29_shape_is_a_rerun(self):
        self.assertTrue(_is_rerun("./build.sh", "./build.sh 2>&1 | grep NEEDLE"))
        self.assertTrue(_is_rerun("make test", "make test"))

    def test_unrelated_and_trivially_short_commands_are_not(self):
        self.assertFalse(_is_rerun("./build.sh", "git status --short"))
        # "ls" twice is not evidence of anything.
        self.assertFalse(_is_rerun("ls", "ls -la"))

    def test_a_truncated_bash_result_followed_by_a_rerun_is_counted(self):
        audit = Audit(budget=10_000)
        audit.add_session(
            "\n".join(
                [
                    line(
                        use("a", "Bash", command="./build.sh --release"),
                        result("a", bash_envelope(truncated=True)),
                    ),
                    line(use("b", "Bash", command="./build.sh --release | grep FAIL")),
                ]
            )
        )
        summary = audit.report(top=10)
        self.assertEqual(summary["bash_truncated"], 1)
        self.assertEqual(summary["reruns_after_truncation"], 1)

    def test_recovering_instead_of_rerunning_is_not_counted_as_a_rerun(self):
        audit = Audit(budget=10_000)
        audit.add_session(
            "\n".join(
                [
                    line(
                        use("a", "Bash", command="./build.sh --release"),
                        result("a", bash_envelope(truncated=True)),
                    ),
                    line(use("b", "Grep", pattern="FAIL", artifact_id="sha256:" + "b" * 64)),
                ]
            )
        )
        summary = audit.report(top=10)
        self.assertEqual(summary["bash_truncated"], 1)
        self.assertEqual(summary["reruns_after_truncation"], 0)

    def test_an_untruncated_result_does_not_arm_the_detector(self):
        audit = Audit(budget=10_000)
        audit.add_session(
            "\n".join(
                [
                    line(
                        use("a", "Bash", command="./build.sh --release"),
                        result("a", bash_envelope(truncated=False)),
                    ),
                    line(use("b", "Bash", command="./build.sh --release | grep FAIL")),
                ]
            )
        )
        self.assertEqual(audit.report(top=10)["reruns_after_truncation"], 0)


class PrivacyTest(unittest.TestCase):
    def test_no_result_content_or_command_text_reaches_the_summary(self):
        # The script reads real transcripts, so the report must carry sizes and
        # names only. Command text is held in memory to detect a re-run and
        # must not survive into the output.
        secret_output = "SECRET-RESULT-CONTENT-" + "q" * 200
        secret_command = "deploy --token SECRET-COMMAND-TOKEN"
        audit = Audit(budget=50)
        audit.add_session(
            "\n".join(
                [
                    line(use("a", "Bash", command=secret_command), result("a", secret_output)),
                    line(use("b", "Read", file_path="/home/someone/private/notes.md")),
                ]
            )
        )
        rendered = json.dumps(audit.report(top=10))
        self.assertNotIn("SECRET-RESULT-CONTENT", rendered)
        self.assertNotIn("SECRET-COMMAND-TOKEN", rendered)
        self.assertNotIn("private/notes.md", rendered)
        # Tool names and sizes are the point, and are present.
        self.assertIn("Bash", rendered)
        self.assertIn(str(len(secret_output)), rendered)


class ToleranceTest(unittest.TestCase):
    def test_a_malformed_line_does_not_abort_the_scan(self):
        audit = Audit(budget=1000)
        audit.add_session(
            "\n".join(
                [
                    '{"type":"tool_result" this is not json',
                    line(use("a", "Bash", command="echo hi"), result("a", "ok")),
                ]
            )
        )
        self.assertEqual(audit.report(top=10)["results"], 1)

    def test_scan_walks_the_project_session_layout(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            session = root / "projecthash" / "sessionid"
            session.mkdir(parents=True)
            (session / "transcript.jsonl").write_text(
                line(use("a", "Bash", command="echo hi"), result("a", "x" * 40)),
                encoding="utf-8",
            )
            (root / "projecthash" / "memory").mkdir()  # not a session; must be ignored
            summary = scan(root, budget=10)
            self.assertEqual(summary["sessions"], 1)
            self.assertEqual(summary["results"], 1)
            self.assertEqual(summary["over_budget"], 1)


if __name__ == "__main__":
    unittest.main()
