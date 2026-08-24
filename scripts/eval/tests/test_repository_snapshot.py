import copy
import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from scripts.eval.model import load_json


ROOT = Path(__file__).resolve().parents[3]
SUITE = load_json(ROOT / "evals/suites/long-horizon-repository-pk.json")
MATERIALIZER_PATH = ROOT / "tests/e2e/materialize_repo_snapshot.py"
SPEC = importlib.util.spec_from_file_location("materialize_repo_snapshot", MATERIALIZER_PATH)
assert SPEC is not None and SPEC.loader is not None
MATERIALIZER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MATERIALIZER)


class RepositorySnapshotTest(unittest.TestCase):
    def test_sparse_snapshot_materializes_real_parent_and_rejects_unfixed_code(self):
        task = SUITE["tasks"][0]
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory)
            MATERIALIZER.materialize(
                ROOT, workspace, task["environment"]["repository_snapshot"]
            )
            source = workspace / "src/platform/process.zig"
            self.assertTrue(source.is_file())
            self.assertNotIn("const terminal_events", source.read_text(encoding="utf-8"))
            completed = subprocess.run(
                [
                    sys.executable,
                    "-I",
                    str(ROOT / task["success"]["checks"][0]["validator"]),
                    str(workspace),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )
            self.assertNotEqual(completed.returncode, 0)

    def test_historical_fixes_pass_hidden_validators(self):
        fixed_revisions = {
            "83_repo_posix_hup_drain": "269eb59259df88dc8dcccc4d59341e6ce4cf6289",
            "84_repo_windows_lock_liveness": "1de6efc310da0b7cb011e1c7b32164419e6f9af2",
            "85_repo_skill_catalog_identity": "3bfd787377424793b879bc70a81cec33c8183c58",
        }
        handoffs = {
            "83_repo_posix_hup_drain": "POLLHUP buffered-bytes-before-EOF negative-read=ReadError",
            "84_repo_windows_lock_liveness": "stale_ms=10000 retry_budget≈9700ms release_retries=20 windows_probe=mtime_only",
            "85_repo_skill_catalog_identity": "skill_id=sha256(invocation_name) catalog_revision=content_addressed duplicate_ids=reject descriptor_ownership=consumer",
        }
        for task in SUITE["tasks"]:
            with self.subTest(task=task["id"]), tempfile.TemporaryDirectory() as directory:
                workspace = Path(directory)
                snapshot = copy.deepcopy(task["environment"]["repository_snapshot"])
                snapshot["revision"] = fixed_revisions[task["id"]]
                MATERIALIZER.materialize(ROOT, workspace, snapshot)
                (workspace / "HANDOFF.md").write_text(
                    handoffs[task["id"]] + "\n", encoding="utf-8"
                )
                completed = subprocess.run(
                    [
                        sys.executable,
                        "-I",
                        str(ROOT / task["success"]["checks"][0]["validator"]),
                        str(workspace),
                    ],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    check=False,
                )
                self.assertEqual(
                    completed.returncode,
                    0,
                    completed.stdout + completed.stderr,
                )

    def test_materializer_rejects_path_traversal(self):
        for unsafe in ("../secret", "src/./main.zig", "src//main.zig", "src\\main.zig"):
            with self.subTest(unsafe=unsafe):
                snapshot = copy.deepcopy(
                    SUITE["tasks"][0]["environment"]["repository_snapshot"]
                )
                snapshot["paths"] = [unsafe]
                with tempfile.TemporaryDirectory() as directory:
                    with self.assertRaisesRegex(ValueError, "safe repository-relative"):
                        MATERIALIZER.materialize(ROOT, Path(directory), snapshot)


if __name__ == "__main__":
    unittest.main()
