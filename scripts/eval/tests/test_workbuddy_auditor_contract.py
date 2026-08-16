"""Auditor-vs-emitter contract tests.

The auditor (trace/launch_gate/progress_analysis) reads artifacts produced by
the Zig runtime.  Both incidents that killed paid arms shared one root shape:
the auditor's assumption about real artifact bytes was validated only against
fixtures written by the auditor's own author — the checker and its test
encoded the same wrong belief, so the suite re-proved the belief instead of
reality.  These tests anchor the other end of the contract:

* the journal event-kind roster is derived from the Zig emitter SOURCE, so a
  new observation event that the auditor cannot read fails here before it
  fails a paid arm at commit time;
* the full-corpus replay gate runs every audit entry point over real run
  artifacts (env-gated), so historical readability is a tested invariant,
  not an assumption.
"""

import glob
import os
import re
import unittest
from pathlib import Path

from scripts.eval.workbuddy.trace import (
    TraceError,
    load_control_metrics,
    load_trace_ir,
)
from scripts.eval.workbuddy.progress_analysis import analyze_progress

REPO_ROOT = Path(__file__).resolve().parents[3]
OBSERVATION_ZIG = REPO_ROOT / "src" / "tools" / "observation.zig"
CORPUS_ENV = "METACODES_WB_CORPUS"


def _zig_event_union_tags(source: str) -> list:
    marker = "pub const Event = union(enum) {"
    start = source.index(marker) + len(marker)
    tags = []
    for line in source[start:].splitlines():
        if line.strip() == "};" and not line.startswith("        "):
            break
        match = re.match(r"^    ([a-z][a-z0-9_]*):", line)
        if match:
            tags.append(match.group(1))
    return tags


class JournalKindRosterTest(unittest.TestCase):
    def _probe(self, tag: str) -> str:
        """Feed one minimal record of `tag`; return the auditor's error text."""
        import json
        import tempfile

        rows = [
            {"schema_version": "metacodes-tool-observation-journal-v1",
             "sequence": 0, "monotonic_elapsed_ns": 1,
             "session_id": "s" * 24, "run_id": "r" * 24,
             "event": {"run_started": {}}},
            {"schema_version": "metacodes-tool-observation-journal-v1",
             "sequence": 1, "monotonic_elapsed_ns": 2,
             "session_id": "s" * 24, "run_id": "r" * 24,
             "event": {"tool_observation": {tag: {}}}},
            {"schema_version": "metacodes-tool-observation-journal-v1",
             "sequence": 2, "monotonic_elapsed_ns": 3,
             "session_id": "s" * 24, "run_id": "r" * 24,
             "event": {"run_finished": {}}},
        ]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            transcript = root / "transcript.jsonl"
            observation = root / "observation.jsonl"
            transcript.write_text("", encoding="utf-8")
            observation.write_text(
                "".join(json.dumps(row) + "\n" for row in rows),
                encoding="utf-8",
            )
            try:
                load_control_metrics(transcript, observation)
            except TraceError as exc:
                return str(exc)
        return ""

    @unittest.skipUnless(OBSERVATION_ZIG.exists(), "Zig emitter source not present")
    def test_auditor_knows_every_zig_observation_kind(self) -> None:
        tags = _zig_event_union_tags(OBSERVATION_ZIG.read_text(encoding="utf-8"))
        self.assertGreaterEqual(len(tags), 8, tags)
        # Negative control first: the probe must actually reach the kind
        # dispatch.  A fixture that dies on an earlier validation would make
        # every roster assertion below pass vacuously — the exact fixture
        # failure mode this suite exists to prevent.
        self.assertIn(
            "kind is unsupported",
            self._probe("kind_that_no_emitter_ever_wrote"),
            "probe no longer reaches the journal kind dispatch",
        )
        for tag in tags:
            error = self._probe(tag)
            # Field-level rejections are fine — the probe record is
            # deliberately minimal.  What must never happen is the
            # roster-level rejection: an emitter kind the auditor does not
            # recognize at all.
            self.assertNotIn(
                "kind is unsupported",
                error,
                f"auditor does not recognize Zig event kind {tag!r}",
            )


class RealCorpusReplayTest(unittest.TestCase):
    """Replay every audit entry point over real run artifacts.

    Set METACODES_WB_CORPUS to a WorkBuddy results root (the directory whose
    children are arm slugs).  Every trial agent dir found underneath must be
    readable by all three auditors — including trials committed by earlier
    binary/bundle generations, because instrument succession is proven by
    recomputing historical metrics.
    """

    @unittest.skipUnless(os.environ.get(CORPUS_ENV), f"{CORPUS_ENV} not set")
    def test_all_auditors_read_the_full_corpus(self) -> None:
        corpus = Path(os.environ[CORPUS_ENV])
        agents = sorted(glob.glob(str(corpus / "*" / "*" / "*" / "agent")))
        self.assertTrue(agents, f"no trial agent dirs under {corpus}")
        replayed = 0
        failures = []
        for agent in agents:
            base = Path(agent)
            transcript = base / "metacodes-transcript.jsonl"
            observation = base / "metacodes-tool-observations.jsonl"
            output = base / "metacodes-output.jsonl"
            if not transcript.exists() or not observation.exists():
                continue
            for name, call in (
                ("control", lambda: load_control_metrics(transcript, observation)),
                ("progress", lambda: analyze_progress(transcript, observation)),
                ("trace_ir", lambda: load_trace_ir(output, transcript)
                 if output.exists() else None),
            ):
                try:
                    call()
                except Exception as exc:  # noqa: BLE001 - collecting all
                    failures.append(f"{name}: {agent}: {exc}")
            replayed += 1
        self.assertGreater(replayed, 0)
        self.assertEqual(failures, [], "\n".join(failures[:20]))


if __name__ == "__main__":
    unittest.main()
