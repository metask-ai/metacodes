from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import types
import unittest

from scripts import build_project_rule


ROOT = Path(__file__).resolve().parents[2]


def observation() -> dict[str, object]:
    return {
        "session_id": "0123456789abcdef01234567",
        "run_id": "1123456789abcdef01234567",
        "first_sequence": 0,
        "last_sequence": 1,
        "interval_sha256": "c" * 64,
    }


def candidate(
    source: str,
    *,
    schema: str = "metacodes-rule-candidate-v3",
    source_evidence: dict[str, object] | None = None,
    **spec_overrides: object,
) -> tuple[str, bytes]:
    spec = {
        "schema_version": "metacodes-project-rule-spec-v2",
        "target_tool": "Write",
        "target_scope": "all",
        "deny_target": False,
        "max_input_bytes": 8192,
        "max_agent_depth": 4,
        "authoritative_only": True,
        "effect_requirement": "file_mutation_v1_reobserved",
    }
    spec.update(spec_overrides)
    body = {
        "schema_version": schema,
        "project_sha256": "a" * 64,
        "proposer_sha256": "b" * 64,
        "invariant": "Successful Write effects are re-observed.",
        "rule_spec": spec,
        "lean_source": source,
        "source": source_evidence or {
            "agent_reflection": {
                "observation": observation(),
                "reflector_sha256": "b" * 64,
                "falsifier": "A successful Write lacks a matching post-read hash.",
            }
        },
    }
    body_bytes = build_project_rule.stable_json(body)
    identity = build_project_rule.sha256_bytes(body_bytes)
    return identity, build_project_rule.stable_json(
        {"candidate_id": identity, "state": "proposed", "body": body}
    ) + b"\n"


GOOD_SOURCE = """
def spec : RuleSpec := {
  targetTool := "Write"
  denyTarget := false
  maxInputBytes := 8192
  maxAgentDepth := 4
  authoritativeOnly := true
  effectRequirement := .fileMutationV1Reobserved
}

theorem spec_valid : valid spec = true := by rfl
""".strip()


def lake_path() -> Path | None:
    override = os.environ.get("METACODES_LAKE")
    if override:
        result = Path(override)
        return result if result.is_file() else None
    toolchain = Path.home() / ".elan" / "toolchains" / "leanprover--lean4---v4.14.0" / "bin" / "lake"
    return toolchain if toolchain.is_file() else None


def isolation_available() -> bool:
    if sys.platform == "darwin":
        return Path("/usr/bin/sandbox-exec").is_file()
    if sys.platform.startswith("linux"):
        return shutil.which("bwrap") is not None
    return False


class ProjectRuleBuildTests(unittest.TestCase):
    def test_v3_rejects_rule_author_source(self) -> None:
        identity, raw = candidate(
            GOOD_SOURCE,
            source_evidence={
                "rule_author": {
                    "receipt_id": "d" * 64,
                    "observation": observation(),
                    "falsifier": "A successful Write lacks a matching post-read hash.",
                }
            },
        )
        with self.assertRaisesRegex(build_project_rule.BuildError, "unsupported by schema"):
            build_project_rule.validate_candidate(raw, identity)

    def test_v4_rule_author_source_is_strictly_validated(self) -> None:
        valid = {
            "receipt_id": "d" * 64,
            "observation": observation(),
            "falsifier": "A successful Write lacks a matching post-read hash.",
        }
        identity, raw = candidate(
            GOOD_SOURCE,
            schema="metacodes-rule-candidate-v4",
            source_evidence={"rule_author": valid},
        )
        build_project_rule.validate_candidate(raw, identity)

        malformed: list[dict[str, object]] = [
            {**valid, "receipt_id": "D" * 64},
            {**valid, "falsifier": ""},
            {**valid, "unknown": True},
            {**valid, "observation": {**observation(), "first_sequence": 2}},
            {**valid, "observation": {**observation(), "unknown": True}},
        ]
        for evidence in malformed:
            with self.subTest(evidence=evidence):
                bad_id, bad_raw = candidate(
                    GOOD_SOURCE,
                    schema="metacodes-rule-candidate-v4",
                    source_evidence={"rule_author": evidence},
                )
                with self.assertRaises(build_project_rule.BuildError):
                    build_project_rule.validate_candidate(bad_raw, bad_id)

    def test_existing_file_scope_is_typed_and_write_only(self) -> None:
        identity, raw = candidate(
            GOOD_SOURCE,
            target_tool="Edit",
            target_scope="existing_file",
        )
        with self.assertRaisesRegex(build_project_rule.BuildError, "requires Write"):
            build_project_rule.validate_candidate(raw, identity)

    def test_duplicate_json_field_is_rejected(self) -> None:
        identity, raw = candidate(GOOD_SOURCE)
        duplicated = raw.replace(
            b'"state":"proposed"',
            b'"state":"proposed","state":"proposed"',
            1,
        )
        with self.assertRaisesRegex(build_project_rule.BuildError, "duplicate JSON field"):
            build_project_rule.validate_candidate(duplicated, identity)

    def test_forbidden_axiom_is_rejected_before_build(self) -> None:
        identity, raw = candidate(GOOD_SOURCE + "\naxiom escape : False")
        with self.assertRaisesRegex(build_project_rule.BuildError, "forbidden Lean"):
            build_project_rule.validate_candidate(raw, identity)

    def test_real_isolated_build_exports_exact_spec_and_empty_axiom_set(self) -> None:
        lake = lake_path()
        if lake is None or not isolation_available():
            self.skipTest("Lean 4.14 plus native OS sandbox is unavailable")
        identity, raw = candidate(GOOD_SOURCE)
        with tempfile.TemporaryDirectory(prefix="metacodes-rule-build-") as directory:
            root = Path(directory)
            os.chmod(root, 0o700)
            candidate_path = root / f"rule-candidate-{identity}.json"
            candidate_path.write_bytes(raw)
            os.chmod(candidate_path, 0o600)
            output = root / "published"
            result = build_project_rule.build(types.SimpleNamespace(
                repo=ROOT,
                candidate=candidate_path,
                candidate_id=identity,
                out=output,
                lake=lake,
            ))
            manifest = json.loads((output / "manifest.json").read_text(encoding="utf-8"))
            self.assertEqual("metacodes-project-rule-build-v1", manifest["schema_version"])
            self.assertTrue(manifest["network_disabled"])
            self.assertTrue(manifest["secrets_absent"])
            self.assertEqual(0, manifest["forbidden_declaration_count"])
            self.assertEqual(0, manifest["unexpected_axiom_count"])
            self.assertRegex(manifest["sdk_olean_sha256"], r"^[0-9a-f]{64}$")
            self.assertGreater(manifest["sdk_olean_bytes"], 0)
            self.assertEqual(identity, result["candidate_id"])
            self.assertEqual(
                "'CandidateRule.spec_valid' does not depend on any axioms\n",
                (output / "axiom.stdout").read_text(encoding="utf-8"),
            )

    def test_real_isolated_build_accepts_v4_rule_author_candidate(self) -> None:
        lake = lake_path()
        if lake is None or not isolation_available():
            self.skipTest("Lean 4.14 plus native OS sandbox is unavailable")
        identity, raw = candidate(
            GOOD_SOURCE,
            schema="metacodes-rule-candidate-v4",
            source_evidence={
                "rule_author": {
                    "receipt_id": "d" * 64,
                    "observation": observation(),
                    "falsifier": "A successful Write lacks a matching post-read hash.",
                }
            },
        )
        with tempfile.TemporaryDirectory(prefix="metacodes-rule-author-build-") as directory:
            root = Path(directory)
            os.chmod(root, 0o700)
            candidate_path = root / f"rule-candidate-{identity}.json"
            candidate_path.write_bytes(raw)
            os.chmod(candidate_path, 0o600)
            output = root / "published"
            result = build_project_rule.build(types.SimpleNamespace(
                repo=ROOT,
                candidate=candidate_path,
                candidate_id=identity,
                out=output,
                lake=lake,
            ))
            manifest = json.loads((output / "manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(identity, result["candidate_id"])
            self.assertEqual(identity, manifest["candidate_id"])
            self.assertEqual(0, manifest["unexpected_axiom_count"])


if __name__ == "__main__":
    unittest.main()
