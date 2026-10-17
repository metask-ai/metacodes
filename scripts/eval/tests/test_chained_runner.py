"""Chained-attempt runner: one TinyKG store carried across the attempts of a
chain, never across chains, replicates or arms; a hash-chained ledger that
fails closed on any break; the session's task hint; resume without repeating
a paid attempt."""

import hashlib
import json
import os
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from scripts.eval.chained_runner import (
    LEDGER_SCHEMA,
    chain_position,
    chain_trial,
    chained_schedule,
    export_store,
    load_ledger,
    run_chained,
)
from scripts.eval.e2e_adapter import comparison_fingerprints
from scripts.eval.model import ValidationError
from scripts.eval.paired_runner import _run_once
from scripts.eval.tests.posix_only import POSIX

REPO_ROOT = Path(__file__).resolve().parents[3]
TASKS = ("a_task", "b_task")


def _task(task_id):
    return {
        "id": task_id,
        "scenario": f"{task_id}.txt",
        "layers": ["E", "T", "L", "O", "V"],
        "environment": {"reset": "fresh"},
        "tools": {"profile": "test-tools", "required": []},
        "constraints": {"timeout_seconds": 10, "permission_mode": "default"},
        "success": {"checks": [{"type": "file_exists", "path": "answer.txt"}]},
        "trajectory_constraints": {"max_turns": 2},
        "trajectory_rationale": {"max_turns": "bounded test"},
        "grader": {"kind": "deterministic_workspace", "version": "v1"},
    }


class FakeHarness:
    """Stands in for run_e2e.sh + lib.sh + import_run.

    Each invocation creates a run directory with the scenario's fake HOME,
    imports the offered store the way `import_kg_store` does (sha check,
    extraction, witness), and then 'runs the session', which appends one
    marker naming (arm, task, trial) to the store.
    """

    def __init__(self, root, suite):
        self.root = root
        self.suite = suite
        self.tasks = {task["id"]: task for task in suite["tasks"]}
        self.invocations = []
        self.state = {}
        self.events = []
        self.fail_after = None
        self.skip_witness = False

    def run_once(
        self,
        _repo_root,
        binary,
        variant,
        trial,
        selector,
        model_provider,
        model_id,
        _suite_path,
        revision,
        *,
        timeout_seconds=None,
        task_hint=None,
        store_import=None,
    ):
        if self.fail_after is not None and len(self.invocations) >= self.fail_after:
            raise RuntimeError("simulated interruption")
        task_id = selector
        assert task_hint == task_id, (task_hint, task_id)
        run_dir = self.root / "runs" / f"run-{len(self.invocations)}"
        kg = run_dir / task_id / ".home" / ".metacodes" / "kg"
        kg.mkdir(parents=True)
        if store_import is not None:
            archive, sha = store_import
            assert hashlib.sha256(Path(archive).read_bytes()).hexdigest() == sha
            with tarfile.open(archive) as handle:
                # The runner wrote this archive; `data` is the strict filter where it exists.
                handle.extractall(kg, **({"filter": "data"} if hasattr(tarfile, "data_filter") else {}))
            if not self.skip_witness:
                (run_dir / f"{task_id}.kg-import.sha256").write_text(sha + "\n", encoding="utf-8")
        store = kg / "store.kg.v2"
        store.mkdir(exist_ok=True)
        with open(store / "markers.txt", "a", encoding="utf-8") as handle:
            handle.write(f"{variant}:{task_id}:{trial}\n")
        self.invocations.append((variant, trial, task_id, store_import is not None))
        self.events.append(("run", variant, task_id, trial))
        self.state[run_dir] = (binary, variant, trial, task_id, model_provider, model_id, revision)
        return run_dir

    def import_run(self, _suite, _repo_root, run_dir):
        binary, variant, trial, task_id, provider, model_id, revision = self.state[run_dir]
        self.events.append(("import", variant, task_id, trial))
        task = self.tasks[task_id]
        identity = comparison_fingerprints(
            task,
            self.root,
            model_provider=provider,
            model_id=model_id,
            harness_config_id=variant,
            harness_revision=revision,
            permission_mode=task["constraints"]["permission_mode"],
            binary_path=binary,
        )
        return [
            {
                "schema_version": 1,
                "run_id": f"{variant}:{task_id}:{trial}",
                "suite_id": self.suite["suite_id"],
                "task_id": task_id,
                "task_fingerprint": identity["task_fingerprint"],
                "task_fingerprint_provenance": "recorded_at_execution",
                "trial": trial,
                "layers": task["layers"],
                "model": {"provider": provider, "id": model_id, "fingerprint": identity["model_fingerprint"]},
                "harness": {
                    "config_id": variant,
                    "revision": revision,
                    "fingerprint": identity["harness_fingerprint"],
                    "permission_mode": identity["permission_mode"],
                    "environment_fingerprint": identity["environment_fingerprint"],
                },
                "readiness": {"status": "pass", "checks": []},
                "execution": {"status": "completed", "exit_code": 0, "invalid_reasons": []},
                "outcome": {"status": "pass", "checks": []},
                "trajectory": {"status": "pass", "checks": [], "tool_failures": []},
                "evaluator": {"status": "ready", "kind": "deterministic_workspace", "version": "v1", "fingerprint": identity["grader_fingerprint"], "errors": []},
                "judgement": {"valid_for_scoring": True, "trustworthy_success": True},
                "metrics": {"cost_usd": 0.0, "wall_time_ms": 1, "policy_violations": 0},
                "attribution": [],
                "artifacts": {},
            }
        ]


class ChainedRunnerTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        for task_id in TASKS:
            (self.root / f"{task_id}.txt").write_text(f"run {task_id}\n", encoding="utf-8")
        self.suite = {"schema_version": 1, "suite_id": "chain-suite", "tasks": [_task(t) for t in TASKS]}
        self.suite_path = self.root / "suite.json"
        self.suite_path.write_text("{}\n", encoding="utf-8")
        self.binaries = {}
        for variant in ("baseline", "candidate"):
            binary = self.root / variant
            binary.write_bytes(f"{variant}-v1".encode())
            binary.chmod(0o755)
            self.binaries[variant] = binary
        self.chain_dir = self.root / "chains"
        self.harness = FakeHarness(self.root, self.suite)

    def tearDown(self):
        self._tmp.cleanup()

    def run_chains(self, replicates=2, attempts=3):
        with mock.patch(
            "scripts.eval.paired_runner._run_once", side_effect=self.harness.run_once
        ), mock.patch(
            "scripts.eval.chained_runner.import_run", side_effect=self.harness.import_run
        ):
            return run_chained(
                self.suite,
                self.root,
                self.binaries["baseline"],
                self.binaries["candidate"],
                replicates=replicates,
                attempts=attempts,
                scenario_glob="*",
                model_provider="test",
                model_id="model-a",
                baseline_output=self.root / "baseline.jsonl",
                candidate_output=self.root / "candidate.jsonl",
                baseline_revision="rev-b",
                candidate_revision="rev-c",
                chain_dir=self.chain_dir,
                suite_path=self.suite_path,
            )

    def markers(self, variant, task_id, replicate, attempt):
        archive = self.chain_dir / variant / task_id / f"r{replicate}" / f"attempt-{attempt}.tar"
        with tarfile.open(archive) as handle:
            member = handle.extractfile("store.kg.v2/markers.txt")
            return member.read().decode("utf-8").splitlines()

    def test_trial_mapping_round_trips(self):
        for replicate in range(3):
            for attempt in range(1, 4):
                trial = chain_trial(replicate, attempt, 3)
                self.assertEqual(chain_position(trial, 3), (replicate, attempt))
        self.assertEqual(chain_trial(1, 1, 3), 3)
        with self.assertRaises(ValidationError):
            chain_trial(0, 4, 3)

    def test_schedule_advances_attempt_levels_together_and_balances_arm_order(self):
        schedule = chained_schedule(["b", "a"], replicates=2, attempts=2)
        self.assertEqual(len(schedule), 2 * 2 * 2 * 2)
        # Every chain's attempt 1 precedes any attempt 2 of the same replicate.
        for replicate in range(2):
            levels = [attempt for r, attempt, _t, _v in schedule if r == replicate]
            self.assertEqual(levels, sorted(levels))
        firsts = {}
        for replicate, attempt, task, variant in schedule:
            firsts.setdefault((replicate, attempt, task), variant)
        self.assertEqual(firsts[(0, 1, "a")], "baseline")
        self.assertEqual(firsts[(0, 1, "b")], "candidate")
        self.assertEqual(firsts[(1, 1, "a")], "candidate")
        self.assertEqual(firsts[(1, 1, "b")], "baseline")
        with self.assertRaises(ValidationError):
            chained_schedule(["a"], replicates=0, attempts=2)

    def test_store_carries_within_a_chain_and_never_across_chains_or_arms(self):
        baseline, candidate = self.run_chains(replicates=2, attempts=3)
        self.assertEqual(len(baseline), 2 * 2 * 3)
        self.assertEqual(len(candidate), 2 * 2 * 3)
        for variant in ("baseline", "candidate"):
            for task_id in TASKS:
                for replicate in range(2):
                    trials = [chain_trial(replicate, k, 3) for k in range(1, 4)]
                    expected = [f"{variant}:{task_id}:{t}" for t in trials]
                    # Attempt k's store holds exactly this chain's attempts 1..k.
                    for attempt in range(1, 4):
                        self.assertEqual(
                            self.markers(variant, task_id, replicate, attempt),
                            expected[:attempt],
                        )
        # Attempt 1 of every chain imported nothing; every later attempt did.
        for variant, trial, _task_id, imported in self.harness.invocations:
            self.assertEqual(imported, chain_position(trial, 3)[1] > 1)

    def test_ledger_links_every_attempt_to_the_export_before_it(self):
        self.run_chains(replicates=1, attempts=3)
        rows = load_ledger(self.chain_dir / "candidate" / "ledger.jsonl", "candidate")
        self.assertEqual(len(rows), len(TASKS) * 3)
        by_key = {(row.task_id, row.attempt): row for row in rows}
        for task_id in TASKS:
            self.assertIsNone(by_key[(task_id, 1)].store_import_sha256)
            for attempt in (2, 3):
                self.assertEqual(
                    by_key[(task_id, attempt)].store_import_sha256,
                    by_key[(task_id, attempt - 1)].store_export_sha256,
                )
            self.assertEqual(by_key[(task_id, 3)].store_entries, ("store.kg.v2",))
        raw = json.loads((self.chain_dir / "candidate" / "ledger.jsonl").read_text().splitlines()[0])
        self.assertEqual(raw["schema_version"], LEDGER_SCHEMA)

    def test_store_is_exported_before_the_offline_grade_runs(self):
        self.run_chains(replicates=1, attempts=2)
        ledger_rows = len(load_ledger(self.chain_dir / "baseline" / "ledger.jsonl", "baseline"))
        self.assertEqual(ledger_rows, len(TASKS) * 2)
        # run → (export) → import, strictly alternating per attempt.
        kinds = [event[0] for event in self.harness.events]
        self.assertEqual(kinds, ["run", "import"] * (len(TASKS) * 2 * 2))

    def test_resume_continues_the_chain_without_repeating_a_paid_attempt(self):
        self.harness.fail_after = 5
        with self.assertRaisesRegex(RuntimeError, "simulated interruption"):
            self.run_chains(replicates=1, attempts=3)
        done = list(self.harness.invocations)
        self.harness.fail_after = None
        self.run_chains(replicates=1, attempts=3)
        resumed = self.harness.invocations[len(done):]
        self.assertEqual(len(done) + len(resumed), len(TASKS) * 2 * 3)
        self.assertFalse(set(done) & set(resumed))
        for variant in ("baseline", "candidate"):
            for task_id in TASKS:
                self.assertEqual(
                    self.markers(variant, task_id, 0, 3),
                    [f"{variant}:{task_id}:{t}" for t in range(3)],
                )

    def test_a_changed_archive_fails_closed_on_resume(self):
        self.run_chains(replicates=1, attempts=2)
        archive = self.chain_dir / "baseline" / "a_task" / "r0" / "attempt-1.tar"
        archive.write_bytes(archive.read_bytes() + b"\0")
        with self.assertRaisesRegex(ValidationError, "missing or changed"):
            self.run_chains(replicates=1, attempts=2)

    def test_a_ledger_row_without_its_rollout_fails_closed(self):
        self.run_chains(replicates=1, attempts=2)
        output = self.root / "baseline.jsonl"
        lines = output.read_text(encoding="utf-8").splitlines(keepends=True)
        output.write_text("".join(lines[:-1]), encoding="utf-8")
        with self.assertRaisesRegex(ValidationError, "ledger and rollout checkpoint disagree"):
            self.run_chains(replicates=1, attempts=2)

    def test_a_missing_import_witness_stops_before_the_next_attempt(self):
        self.harness.skip_witness = True
        with self.assertRaisesRegex(ValidationError, "no store import witness"):
            self.run_chains(replicates=1, attempts=2)
        # Attempt 1 of each chain ran; the first attempt 2 was not recorded.
        self.assertEqual(sum(1 for _v, t, _k, _i in self.harness.invocations if t == 1), 1)

    def test_export_is_deterministic_and_empty_without_a_store(self):
        kg = self.root / "kg"
        (kg / "store.kg.v2" / "sub").mkdir(parents=True)
        (kg / "store.kg.v2" / "sub" / "data").write_bytes(b"x" * 10)
        (kg / "daemon.json").write_text("{}", encoding="utf-8")
        first = export_store(kg, self.root / "one.tar")
        second = export_store(kg, self.root / "two.tar")
        self.assertEqual(first[0], second[0])
        self.assertEqual(first[1], ["store.kg.v2"])
        with tarfile.open(self.root / "one.tar") as handle:
            self.assertEqual(handle.getnames(), ["store.kg.v2", "store.kg.v2/sub", "store.kg.v2/sub/data"])
        empty = export_store(self.root / "nothing", self.root / "empty.tar")
        self.assertEqual(empty[1], [])

    @unittest.skipUnless(POSIX, "symlinks need POSIX")
    def test_export_refuses_a_symlink_planted_in_the_store(self):
        kg = self.root / "kg"
        (kg / "store.kg").mkdir(parents=True)
        os.symlink("/etc/passwd", kg / "store.kg" / "leak")
        with self.assertRaisesRegex(ValidationError, "not a regular file"):
            export_store(kg, self.root / "out.tar")

    def test_run_once_passes_task_hint_and_store_import_to_the_harness(self):
        runs = self.root / "tests" / "e2e" / "runs"
        runs.mkdir(parents=True)
        runner = self.root / "tests" / "e2e" / "run_e2e.sh"
        runner.write_text("#!/bin/sh\n", encoding="utf-8")
        runner.chmod(0o755)
        archive = self.root / "store.tar"
        archive.write_bytes(b"tar")
        sha = hashlib.sha256(b"tar").hexdigest()

        def fake_run(*_args, **_kwargs):
            (runs / "one").mkdir()
            return mock.Mock(returncode=0)

        with mock.patch.dict(os.environ, {"METACODES_TASK_HINT": "host-leak"}), mock.patch(
            "scripts.eval.paired_runner.subprocess.run", side_effect=fake_run
        ) as patched:
            _run_once(
                self.root,
                self.binaries["baseline"],
                "baseline",
                1,
                "a_task",
                "anthropic",
                "m",
                self.suite_path,
                "rev",
                task_hint="a_task",
                store_import=(archive, sha),
            )
        env = patched.call_args.kwargs["env"]
        self.assertEqual(env["METACODES_TASK_HINT"], "a_task")
        self.assertEqual(env["E2E_KG_STORE_IMPORT"], str(archive.resolve()))
        self.assertEqual(env["E2E_KG_STORE_IMPORT_SHA256"], sha)
        with self.assertRaisesRegex(ValidationError, "task hint"):
            _run_once(
                self.root, self.binaries["baseline"], "baseline", 1, "a_task", "anthropic", "m",
                self.suite_path, "rev", task_hint="two words",
            )


@unittest.skipUnless(POSIX, "tests/e2e/lib.sh is a bash harness")
class LibImportKgStoreTest(unittest.TestCase):
    """`import_kg_store` in tests/e2e/lib.sh, sourced and called directly."""

    def call(self, home, witness, archive=None, sha=None):
        env = {key: value for key, value in os.environ.items() if not key.startswith("E2E_")}
        if archive is not None:
            env["E2E_KG_STORE_IMPORT"] = str(archive)
            env["E2E_KG_STORE_IMPORT_SHA256"] = sha
        script = (
            'source "$1"; import_kg_store "$2" "$3"; rc=$?; '
            'printf "rc=%s left=%s%s\\n" "$rc" "${E2E_KG_STORE_IMPORT:-}" "${E2E_KG_STORE_IMPORT_SHA256:-}"'
        )
        return subprocess.run(
            ["bash", "-c", script, "bash", str(REPO_ROOT / "tests/e2e/lib.sh"), str(home), str(witness)],
            env=env,
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()

    def test_import_extracts_the_store_and_writes_the_witness(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "kg"
            (source / "store.kg.v2").mkdir(parents=True)
            (source / "store.kg.v2" / "data").write_text("lesson", encoding="utf-8")
            sha, _entries, _size = export_store(source, root / "store.tar")
            home = root / "home"
            witness = root / "task.kg-import.sha256"
            self.assertEqual(self.call(home, witness, root / "store.tar", sha), "rc=0 left=")
            self.assertEqual(
                (home / ".metacodes" / "kg" / "store.kg.v2" / "data").read_text(encoding="utf-8"),
                "lesson",
            )
            self.assertEqual(witness.read_text(encoding="utf-8").strip(), sha)

    def test_a_wrong_hash_imports_nothing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "kg" / "store.kg").mkdir(parents=True)
            export_store(root / "kg", root / "store.tar")
            home = root / "home"
            witness = root / "w"
            out = self.call(home, witness, root / "store.tar", "0" * 64)
            self.assertTrue(out.startswith("rc=1"), out)
            self.assertTrue(out.endswith("left="), out)
            self.assertFalse((home / ".metacodes" / "kg").exists())
            self.assertFalse(witness.exists())

    def test_without_an_import_it_does_nothing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.assertEqual(self.call(root / "home", root / "w"), "rc=0 left=")
            self.assertFalse((root / "home").exists())
            self.assertFalse((root / "w").exists())


if __name__ == "__main__":
    unittest.main()
