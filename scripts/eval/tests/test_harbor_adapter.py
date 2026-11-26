"""Contract tests for the metacodes Harbor adapter (scripts/eval/harbor).

The Harbor-free core is tested directly; the trial script is run by a real
bash against a stand-in metacodes, so the test sees what the script delivers
(argv, stdin, files, exit status), not just its text.  The end-to-end check
through the real `harbor run` is scripts/eval/harbor/smoke.py.
"""

from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
import tempfile
import textwrap
import time
import unittest
from pathlib import Path

from scripts.eval.harbor import command as cmd
from scripts.eval.harbor import smoke_provider as sp
from scripts.eval.tests.posix_only import POSIX
from scripts.eval.workbuddy.trace import TraceError

BASH = shutil.which("bash")


def _write_bundle(root: Path, os_name: str = "linux") -> Path:
    (root / "bin").mkdir(parents=True)
    (root / "manifest.json").write_text(
        json.dumps({"target": {"id": f"x86_64-{os_name}", "os": os_name}}),
        encoding="utf-8",
    )
    for rel in cmd.BUNDLE_EXECUTABLES:
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"\x7fELF")
    return root


class BundleTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)

    def test_linux_release_prefix_is_accepted(self):
        bundle = _write_bundle(self.tmp / "linux")
        self.assertEqual(cmd.check_bundle(bundle)["target"]["os"], "linux")

    def test_macos_prefix_is_refused(self):
        bundle = _write_bundle(self.tmp / "mac", os_name="macos")
        with self.assertRaisesRegex(cmd.BundleError, "Linux"):
            cmd.check_bundle(bundle)

    def test_missing_runtime_asset_is_named(self):
        bundle = _write_bundle(self.tmp / "partial")
        (bundle / "vendor/tinykg/tinykg").unlink()
        with self.assertRaisesRegex(cmd.BundleError, "vendor/tinykg/tinykg"):
            cmd.check_bundle(bundle)

    def test_directory_without_manifest_is_refused(self):
        (self.tmp / "bare" / "bin").mkdir(parents=True)
        with self.assertRaisesRegex(cmd.BundleError, "manifest.json"):
            cmd.check_bundle(self.tmp / "bare")


class ModelAndFlagsTest(unittest.TestCase):
    def test_provider_prefix_becomes_provider_flag(self):
        self.assertEqual(
            cmd.split_model("deepseek/deepseek-v4-flash"), ("deepseek", "deepseek-v4-flash")
        )

    def test_only_the_first_slash_splits(self):
        self.assertEqual(
            cmd.split_model("qwen/Qwen/Qwen3-Coder"), ("qwen", "Qwen/Qwen3-Coder")
        )

    def test_bare_model_has_no_provider(self):
        self.assertEqual(cmd.split_model("glm-5.3"), (None, "glm-5.3"))

    def test_missing_or_malformed_model_is_refused(self):
        for bad in (None, "", "/model", "provider/"):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                cmd.split_model(bad)

    def test_flags(self):
        flags = cmd.metacodes_flags(
            provider="zai-coding-plan",
            model="glm-5.3",
            disallowed_tools="EnterPlanMode",
            reasoning_effort="high",
            max_tokens=32000,
        )
        self.assertEqual(
            flags,
            [
                "--provider", "zai-coding-plan",
                "--model", "glm-5.3",
                "--permission", "bypassPermissions",
                "--no-theme",
                "--disallowed-tools", "EnterPlanMode",
                "--reasoning-effort", "high",
                "--max-tokens", "32000",
            ],
        )

    def test_empty_disallowed_tools_enables_every_tool(self):
        flags = cmd.metacodes_flags(
            provider=None, model="m", disallowed_tools="", reasoning_effort=None, max_tokens=None
        )
        self.assertNotIn("--disallowed-tools", flags)
        self.assertNotIn("--provider", flags)

    def test_unknown_reasoning_effort_and_bad_max_tokens_are_refused(self):
        with self.assertRaisesRegex(ValueError, "reasoning_effort"):
            cmd.metacodes_flags(
                provider=None, model="m", disallowed_tools="", reasoning_effort="extreme", max_tokens=None
            )
        for bad in (0, -1, True, "100"):
            with self.subTest(bad=bad), self.assertRaisesRegex(ValueError, "max_tokens"):
                cmd.metacodes_flags(
                    provider=None, model="m", disallowed_tools="", reasoning_effort=None, max_tokens=bad
                )

    def test_features_add_their_flags_and_unknown_names_are_refused(self):
        flags = cmd.metacodes_flags(
            provider=None, model="m", disallowed_tools="", reasoning_effort=None, max_tokens=None,
            features=["test_integrity", "execute_code", "harnessmm"],
        )
        self.assertEqual(flags[-3:], ["--test-integrity", "--preview=execute_code", "--harnessmm"])
        with self.assertRaisesRegex(ValueError, "unknown feature 'bogus'"):
            cmd.metacodes_flags(
                provider=None, model="m", disallowed_tools="", reasoning_effort=None, max_tokens=None,
                features=["bogus"],
            )
        with self.assertRaisesRegex(ValueError, "is an entry"):
            cmd.metacodes_flags(
                provider=None, model="m", disallowed_tools="", reasoning_effort=None, max_tokens=None,
                features=["teamwork"],
            )

    def test_teamwork_flags_carry_the_reasoning_effort_to_the_seats_that_take_one(self):
        self.assertEqual(cmd.teamwork_flags(provider=None, model="m", reasoning_effort=None), ["--model", "m"])
        flags = cmd.teamwork_flags(provider="p", model="m", reasoning_effort="high")
        self.assertEqual(flags[:4], ["--provider", "p", "--model", "m"])
        self.assertEqual(json.loads(flags[flags.index("--config-json") + 1]),
                         {"seats": {"implementer": {"effort": "high"}, "reviewer": {"effort": "high"}}})
        with self.assertRaisesRegex(ValueError, "reasoning_effort"):
            cmd.teamwork_flags(provider=None, model="m", reasoning_effort="turbo")

    def test_teamwork_allows_the_built_in_tools_and_the_tasks_mcp_servers(self):
        self.assertIn("WebFetch", cmd.teamwork_allow_rules())
        self.assertEqual(cmd.teamwork_allow_rules(["are"])[-1], "mcp__are")
        self.assertEqual(cmd.teamwork_allow_rules()[:len(cmd.TEAMWORK_ALLOWED_TOOLS)], list(cmd.TEAMWORK_ALLOWED_TOOLS))

    def test_a_model_price_becomes_the_models_model_prices_entry(self):
        self.assertIsNone(cmd.model_prices_config("m", None))
        self.assertEqual(cmd.model_prices_config("m", {"input": 0.15, "output": 0.6}), {"m": {"input": 0.15, "output": 0.6}})
        self.assertEqual(cmd.model_prices_config("m", '{"input":1,"output":2,"cached_input":0.1}'),
                         {"m": {"input": 1, "output": 2, "cached_input": 0.1}})
        for bad in ({"input": 1}, {"input": 1, "output": -1}, {"input": 1, "output": True},
                    {"input": 1, "output": 1, "currency": "USD"}, [1, 2]):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                cmd.model_prices_config("m", bad)

    def test_teamwork_runs_alone(self):
        self.assertEqual(cmd.checked_features(["teamwork"]), ["teamwork"])
        self.assertEqual(cmd.checked_features(["execute_code", "stall_gate"]), ["execute_code", "stall_gate"])
        with self.assertRaisesRegex(ValueError, "teamwork runs alone"):
            cmd.checked_features(["teamwork", "execute_code"])
        with self.assertRaisesRegex(ValueError, "unknown feature"):
            cmd.checked_features(["bogus"])

    def test_every_feature_flag_is_one_metacodes_parses(self):
        root = Path(__file__).resolve().parents[3]
        main = (root / "apps" / "cli" / "src" / "main.zig").read_text(encoding="utf-8")
        types = (root / "packages/ai/src/types.zig").read_text(encoding="utf-8")
        preview = types.split("pub const PreviewFeature = enum {", 1)[1].split("pub fn", 1)[0]
        for name, entry in cmd.ADVANCED_FEATURES.items():
            flag = entry["flag"]
            with self.subTest(feature=name):
                if flag.startswith("--preview="):
                    self.assertIn(flag[len("--preview="):] + ",", preview)
                else:
                    self.assertIn('std.mem.eql(u8, arg, "' + flag + '")', main)


class CaBundleTest(unittest.TestCase):
    def test_check_covers_every_path_metacodes_reads(self):
        check = cmd.ca_bundle_check()
        for path in cmd.CA_BUNDLE_PATHS:
            self.assertIn(f"test -s {path}", check)
        self.assertEqual(set(cmd.CA_PACKAGE_INSTALL), {"apt-get", "dnf", "yum", "apk"})

    @unittest.skipIf(BASH is None or not POSIX, "needs a POSIX shell")
    def test_check_is_a_shell_condition(self):
        done = subprocess.run([BASH, "-c", cmd.ca_bundle_check()], capture_output=True)
        has_bundle = any(os.path.getsize(p) > 0 for p in cmd.CA_BUNDLE_PATHS if os.path.isfile(p))
        self.assertEqual(done.returncode == 0, has_bundle)

    @unittest.skipIf(BASH is None or not POSIX, "needs a POSIX shell")
    def test_relay_ca_reaches_system_bundles_and_one_fixed_trust_file(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            ca = root / "relay-ca.pem"
            ca.write_text("RELAY CA\n")
            present, absent = root / "etc/ssl/certs/ca-certificates.crt", root / "etc/pki/tls/certs/ca-bundle.crt"
            present.parent.mkdir(parents=True)
            present.write_text("PUBLIC CAS\n")
            trust = root / "usr/local/share/metacodes-bench/ca-bundle.pem"
            script = cmd.trust_relay_ca(str(ca), str(trust), bundles=(str(absent), str(present)))
            done = subprocess.run([BASH, "-c", script], capture_output=True, text=True)
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertEqual(present.read_text(), "PUBLIC CAS\n\nRELAY CA\n")
            self.assertFalse(absent.exists())
            # SSL_CERT_FILE for the judge: public CAs (pip, PyPI) plus the relay.
            self.assertEqual(trust.read_text(), present.read_text())
            self.assertEqual(stat.S_IMODE(trust.stat().st_mode), 0o644)
            # No bundle at all: the install fails instead of leaving no trust file.
            done = subprocess.run([BASH, "-c", cmd.trust_relay_ca(str(ca), str(root / "t.pem"), bundles=(str(absent),))])
            self.assertNotEqual(done.returncode, 0)


# A stand-in metacodes: records argv, stdin and environment, writes a session
# transcript under --state-dir, emits one NDJSON result and a line on stderr,
# optionally leaves a child running, and exits with $FAKE_STATUS.
FAKE_METACODES = textwrap.dedent(
    """\
    #!/usr/bin/env bash
    state=""
    args=("$@")
    for ((i = 0; i < ${#args[@]}; i++)); do
      if [ "${args[$i]}" = "--state-dir" ]; then state="${args[$((i + 1))]}"; fi
    done
    printf '%s\\n' "$@" > "$RECORD/argv"
    cat > "$RECORD/stdin"
    ls -l "$state/config.json" > "$RECORD/config" 2>/dev/null || true
    env > "$RECORD/env"
    if [ -z "${FAKE_NO_TRANSCRIPT:-}" ]; then
      mkdir -p "$state/projects/p1/s1"
      echo '{"role":"assistant","blocks":[{"type":"text","text":"done"}]}' > "$state/projects/p1/s1/transcript.jsonl"
    fi
    echo '{"type":"result","stop_reason":"end_turn","turns":1,"tool_calls":0,"input_tokens":5,"output_tokens":2,"cost_usd":0,"text":"done"}'
    echo "diagnostic" >&2
    if [ -n "${FAKE_LINGER:-}" ]; then
      # A child that outlives metacodes with every descriptor it had, as an
      # autostarted kgd did (it kept a caller's pipe open).
      sleep 30 &
    fi
    exit "${FAKE_STATUS:-0}"
    """
)


@unittest.skipIf(BASH is None or not POSIX, "the trial script runs in a Linux container")
class RunScriptTest(unittest.TestCase):
    INSTRUCTION = "Kill the server: pkill -f my-service\nthen restart it.\n"

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.binary = self.tmp / "metacodes"
        self.binary.write_text(FAKE_METACODES, encoding="utf-8")
        self.binary.chmod(self.binary.stat().st_mode | stat.S_IXUSR)
        self.record = self.tmp / "record"
        self.record.mkdir()
        self.logs = self.tmp / "logs"
        self.instruction = self.tmp / "instruction.md"
        self.instruction.write_text(self.INSTRUCTION, encoding="utf-8")
        self.flags = cmd.metacodes_flags(
            provider="deepseek", model="deepseek-v4-flash",
            disallowed_tools=cmd.DEFAULT_DISALLOWED_TOOLS, reasoning_effort=None, max_tokens=None,
        )

    def run_script(self, *, config=None, extra_env=None, state=None):
        script = cmd.run_command(
            state_dir=str(state or self.tmp / "state"),
            instruction_path=str(self.instruction),
            flags=self.flags,
            config_path=str(config) if config else None,
            binary=str(self.binary),
            kg_bin="/opt/metacodes/vendor/tinykg/tinykg",
            logs_dir=str(self.logs),
        )
        env = {"PATH": os.environ.get("PATH", ""), "RECORD": str(self.record)}
        env.update(extra_env or {})
        return subprocess.run(
            [BASH, "-c", script], env=env, capture_output=True, text=True, timeout=20
        )

    def recorded_env(self):
        return dict(
            line.split("=", 1)
            for line in (self.record / "env").read_text(encoding="utf-8").splitlines()
            if "=" in line
        )

    def test_instruction_goes_to_stdin_never_argv(self):
        done = self.run_script()
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual((self.record / "stdin").read_text(encoding="utf-8"), self.INSTRUCTION)
        argv = (self.record / "argv").read_text(encoding="utf-8").splitlines()
        self.assertNotIn("my-service", " ".join(argv))
        self.assertEqual(argv[:2], ["--state-dir", str(self.tmp / "state")])
        self.assertEqual(argv[-3:], ["-", "--json", "--stream-json"])
        self.assertIn("deepseek-v4-flash", argv)

    def test_logs_land_on_the_log_mount_with_stderr_apart(self):
        done = self.run_script()
        self.assertEqual(done.returncode, 0, done.stderr)
        output = (self.logs / cmd.OUTPUT_FILENAME).read_text(encoding="utf-8")
        self.assertEqual(json.loads(output)["type"], "result")
        self.assertNotIn("diagnostic", output)
        self.assertIn("diagnostic", (self.logs / cmd.STDERR_FILENAME).read_text(encoding="utf-8"))
        transcript = (self.logs / cmd.TRANSCRIPT_FILENAME).read_text(encoding="utf-8")
        self.assertIn('"done"', transcript)

    def test_config_is_installed_private_in_the_state_dir(self):
        config = self.tmp / "config.json"
        config.write_text("{}", encoding="utf-8")
        done = self.run_script(config=config)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertTrue(
            (self.record / "config").read_text(encoding="utf-8").startswith("-rw-------")
        )

    def test_remote_tinykg_variables_do_not_reach_metacodes(self):
        done = self.run_script(extra_env={name: "x" for name in cmd.REMOTE_TINYKG_ENV})
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertFalse(set(self.recorded_env()) & set(cmd.REMOTE_TINYKG_ENV))

    def test_tinykg_runs_exclusive_on_a_fresh_store_in_the_state_dir(self):
        done = self.run_script()
        self.assertEqual(done.returncode, 0, done.stderr)
        env = self.recorded_env()
        self.assertEqual(env["METACODES_KG_TRANSPORT"], "cli-exclusive")
        self.assertEqual(env["METACODES_KG_AUTOSTART"], "0")
        self.assertEqual(env["METACODES_KG_BIN"], "/opt/metacodes/vendor/tinykg/tinykg")
        self.assertEqual(env["METACODES_KG_STORE"], str(self.tmp / "state" / "kg-store"))

    def test_a_child_that_outlives_metacodes_does_not_hold_the_trial(self):
        started = time.monotonic()
        done = self.run_script(extra_env={"FAKE_LINGER": "1"})
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertLess(time.monotonic() - started, 10)

    def test_metacodes_exit_status_is_returned_after_the_transcript_is_copied(self):
        done = self.run_script(extra_env={"FAKE_STATUS": "3"})
        self.assertEqual(done.returncode, 3)
        self.assertTrue((self.logs / cmd.TRANSCRIPT_FILENAME).is_file())

    def test_a_missing_transcript_fails_a_successful_run(self):
        done = self.run_script(extra_env={"FAKE_NO_TRANSCRIPT": "1"})
        self.assertEqual(done.returncode, 73)
        self.assertIn("expected one metacodes transcript", done.stderr)

    def test_an_existing_state_dir_is_refused(self):
        state = self.tmp / "used-state"
        state.mkdir()
        done = self.run_script(state=state)
        self.assertEqual(done.returncode, 70)
        self.assertFalse((self.record / "argv").exists())


# A stand-in for `metacodes ... teamwork run|status`: records each call's
# argv and the request it was given, answers status with $FAKE_TEAMWORK_STATUS.
FAKE_TEAMWORK = textwrap.dedent(
    """\
    #!/usr/bin/env bash
    args=("$@")
    for ((i = 0; i < ${#args[@]}; i++)); do
      if [ "${args[$i]}" = "--request-file" ]; then cp "${args[$((i + 1))]}" "$RECORD/request"; fi
    done
    case " $* " in
      *" teamwork status "*) printf '%s\\n' "$@" > "$RECORD/argv-status"; printf '%s' "${FAKE_TEAMWORK_STATUS:-}"; exit 0 ;;
      *" teamwork run "*) printf '%s\\n' "$@" > "$RECORD/argv-run"; git log --format=%s > "$RECORD/log"
        run_dir="${args[1]}/teamwork/trial1"; mkdir -p "$run_dir/worktree" "$run_dir/seats/implementer-1"
        echo '{"charge":1}' > "$run_dir/budget.jsonl"; echo seat-log > "$run_dir/seats/implementer-1/session.log"
        echo task-copy > "$run_dir/worktree/main.py"
        exit "${FAKE_STATUS:-0}" ;;
    esac
    exit 9
    """
)


@unittest.skipIf(BASH is None or not POSIX or shutil.which("git") is None, "the trial script runs in a Linux container")
class TeamworkScriptTest(unittest.TestCase):
    STATUS = json.dumps({"state": "done", "detail": None, "dispatched": {"implementer": 2, "reviewer": 1},
                         "audits": 1, "merge_conflicts": 0, "budget": {"cap_usd": 10, "spent_usd": 1.25},
                         "seats": [{"role": "implementer", "status": "failed"},
                                   {"role": "implementer", "status": "done"}, {"role": "reviewer", "status": "done"}]})

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.binary = self.tmp / "metacodes"
        self.binary.write_text(FAKE_TEAMWORK, encoding="utf-8")
        self.binary.chmod(self.binary.stat().st_mode | stat.S_IXUSR)
        self.record = self.tmp / "record"
        self.record.mkdir()
        self.logs = self.tmp / "logs"
        self.work = self.tmp / "app"
        self.work.mkdir()
        (self.work / "main.py").write_text("print(1)\n", encoding="utf-8")
        self.instruction = self.tmp / "instruction.md"

    def run_script(self, instruction="Fix the bug in main.py.\n", status=None, extra_env=None, cwd=None):
        self.instruction.write_text(instruction, encoding="utf-8")
        script = cmd.teamwork_run_command(
            state_dir=str(self.tmp / "state"), instruction_path=str(self.instruction), run_id="trial1",
            budget_usd=10.0, flags=["--provider", "deepseek", "--model", "deepseek-v4-flash"],
            binary=str(self.binary), kg_bin="/opt/metacodes/vendor/tinykg/tinykg", logs_dir=str(self.logs))
        env = {"PATH": os.environ.get("PATH", ""), "RECORD": str(self.record), "HOME": str(self.tmp),
               "FAKE_TEAMWORK_STATUS": self.STATUS if status is None else status}
        env.update(extra_env or {})
        return subprocess.run([BASH, "-c", script], env=env, cwd=str(cwd or self.work), capture_output=True,
                              text=True, timeout=30)

    def test_a_plain_directory_is_snapshotted_and_run_with_the_approved_request(self):
        done = self.run_script()
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual((self.record / "log").read_text(encoding="utf-8").strip(), "bench snapshot before teamwork")
        tracked = subprocess.run(["git", "ls-files"], cwd=self.work, capture_output=True, text=True).stdout.split()
        self.assertEqual(tracked, ["main.py"])
        argv = (self.record / "argv-run").read_text(encoding="utf-8").splitlines()
        self.assertEqual(argv[:6], ["--state-dir", str(self.tmp / "state"), "--preview=teamwork", "teamwork", "run",
                                    "--request-file"])
        for part in (["--approve"], ["--budget-usd", "10"], ["--id", "trial1"], ["--events"],
                     ["--provider", "deepseek", "--model", "deepseek-v4-flash"]):
            self.assertIn(" ".join(part), " ".join(argv))
        self.assertEqual((self.record / "request").read_text(encoding="utf-8"), "Fix the bug in main.py.\n")
        self.assertEqual(cmd.teamwork_status(self.logs)["dispatched"]["implementer"], 2)
        self.assertIsNone(cmd.teamwork_problem(cmd.teamwork_status(self.logs)))
        kept = self.logs / cmd.TEAMWORK_RUN_DIRNAME
        self.assertEqual((kept / "budget.jsonl").read_text(encoding="utf-8").strip(), '{"charge":1}')
        self.assertEqual((kept / "seats" / "implementer-1" / "session.log").read_text(encoding="utf-8").strip(), "seat-log")
        self.assertFalse((kept / "worktree").exists())

    def test_seats_get_allow_rules_and_an_images_own_settings_are_kept(self):
        done = self.run_script()
        self.assertEqual(done.returncode, 0, done.stderr)
        settings = json.loads((self.tmp / ".claude" / "settings.json").read_text(encoding="utf-8"))
        self.assertEqual(settings, {"permissions": {"allow": list(cmd.TEAMWORK_ALLOWED_TOOLS)}})
        (self.tmp / ".claude" / "settings.json").write_text('{"permissions": {"deny": ["Bash"]}}', encoding="utf-8")
        shutil.rmtree(self.tmp / "state")
        done = self.run_script()
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn('"deny"', (self.tmp / ".claude" / "settings.json").read_text(encoding="utf-8"))
        self.assertIn("keeping the image's own", (self.logs / cmd.STDERR_FILENAME).read_text(encoding="utf-8"))

    def test_an_existing_commit_is_kept_and_a_bracket_request_gets_a_heading(self):
        subprocess.run(["git", "init", "-q"], cwd=self.work, check=True)
        subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "task"],
                       cwd=self.work, check=True)
        done = self.run_script(instruction="[WIP] fix it\n")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual((self.record / "log").read_text(encoding="utf-8").strip(), "task")
        self.assertEqual((self.record / "request").read_text(encoding="utf-8"), "Task:\n\n[WIP] fix it\n")

    def test_a_failed_run_is_scored_and_a_run_that_dispatched_nothing_is_a_problem(self):
        done = self.run_script(extra_env={"FAKE_STATUS": "3"})
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("teamwork run exited 3", (self.logs / cmd.STDERR_FILENAME).read_text(encoding="utf-8"))
        failed = json.dumps({"state": "failed", "detail": "rounds_exhausted", "dispatched": {"implementer": 3},
                             "seats": [{"role": "implementer", "status": "failed"}] * 3})
        self.assertIn("no teamwork implementer seat finished", cmd.teamwork_problem(cmd.parse_teamwork_status(failed)))
        self.assertIn("did not start", cmd.teamwork_problem(cmd.parse_teamwork_status("")))
        spent = json.dumps({"state": "budget_exhausted", "seats": [{"role": "implementer", "status": "failed"}]})
        self.assertIsNone(cmd.teamwork_problem(cmd.parse_teamwork_status(spent)))
        self.assertIn("did not start", cmd.teamwork_problem(None))

    def test_the_root_directory_is_refused(self):
        done = self.run_script(cwd="/")
        self.assertEqual(done.returncode, 74)
        self.assertFalse((self.record / "argv-run").exists())

    def test_trace_carries_the_ledger_spend(self):
        self.logs.mkdir()
        (self.logs / cmd.TEAMWORK_STATUS_FILENAME).write_text(self.STATUS, encoding="utf-8")
        trace = cmd.teamwork_trace(self.logs)
        self.assertEqual(trace["result"]["cost_usd"], 1.25)
        self.assertEqual(trace["result"]["stop_reason"], "teamwork_done")
        self.assertEqual(cmd.final_metrics_fields(trace["result"])["total_cost_usd"], 1.25)


class TeamworkBudgetTest(unittest.TestCase):
    def test_budget_follows_the_difficulty_the_task_declares(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            task, trial = root / "task", root / "trial"
            task.mkdir()
            trial.mkdir()
            (trial / "config.json").write_text(json.dumps({"task": {"path": str(task)}}), encoding="utf-8")
            self.assertEqual(cmd.task_difficulty(trial), "unknown")
            (task / "task.toml").write_text('[metadata]\nauthor_name = "x"\ndifficulty = "Hard"\n', encoding="utf-8")
            self.assertEqual(cmd.task_difficulty(trial), "hard")
        self.assertEqual(cmd.teamwork_budget("hard"), cmd.TEAMWORK_BUDGET_USD["hard"])
        self.assertEqual(cmd.teamwork_budget("unknown"), cmd.TEAMWORK_DEFAULT_BUDGET_USD)
        self.assertLess(cmd.TEAMWORK_BUDGET_USD["easy"], cmd.TEAMWORK_BUDGET_USD["medium"])
        self.assertLess(cmd.TEAMWORK_BUDGET_USD["medium"], cmd.TEAMWORK_BUDGET_USD["hard"])


class TraceTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)

    def write(self, name, rows):
        (self.tmp / name).write_text(
            "".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8"
        )

    def test_no_output_is_a_killed_trial(self):
        trace = cmd.load_trace(self.tmp)
        self.assertEqual(trace["result"]["stop_reason"], "killed_no_result")
        self.assertEqual(len(trace["steps"]), 1)

    def test_output_without_a_result_event_is_a_killed_trial(self):
        self.write(cmd.OUTPUT_FILENAME, [{"type": "text", "text": "partial"}])
        self.assertEqual(cmd.load_trace(self.tmp)["result"]["stop_reason"], "killed_no_result")

    def test_two_result_events_are_a_defect(self):
        result = {
            "type": "result", "stop_reason": "end_turn", "turns": 1, "tool_calls": 0,
            "input_tokens": 1, "output_tokens": 1, "cost_usd": 0, "text": "",
        }
        self.write(cmd.OUTPUT_FILENAME, [result, result])
        self.write(cmd.TRANSCRIPT_FILENAME, [])
        with self.assertRaises(TraceError):
            cmd.load_trace(self.tmp)

    def test_tool_call_and_result_share_a_step(self):
        self.write(
            cmd.OUTPUT_FILENAME,
            [{
                "type": "result", "stop_reason": "end_turn", "turns": 2, "tool_calls": 1,
                "input_tokens": 10, "output_tokens": 4, "cost_usd": 0.5, "text": "ok",
            }],
        )
        self.write(
            cmd.TRANSCRIPT_FILENAME,
            [
                {"role": "user", "blocks": [{"type": "text", "text": "do it"}]},
                {"role": "assistant", "blocks": [
                    {"type": "tool_use", "id": "c1", "name": "Bash", "input": {"command": "ls"}},
                ]},
                {"role": "user", "blocks": [
                    {"type": "tool_result", "tool_use_id": "c1", "content": "a.txt"},
                ]},
                {"role": "assistant", "blocks": [{"type": "text", "text": "ok"}]},
            ],
        )
        steps = cmd.load_trace(self.tmp)["steps"]
        self.assertEqual([step["source"] for step in steps], ["user", "agent", "agent"])
        self.assertEqual(steps[1]["tool_calls"][0]["function_name"], "Bash")
        self.assertEqual(steps[1]["observations"][0]["content"], "a.txt")

    def test_prompt_tokens_include_the_cached_part(self):
        fields = cmd.final_metrics_fields({
            "stop_reason": "end_turn", "turns": 3, "tool_calls": 2,
            "input_tokens": 100, "output_tokens": 20, "cost_usd": 0.0,
            "cache_read_input_tokens": 64, "cache_creation_input_tokens": 8,
        })
        self.assertEqual(fields["total_prompt_tokens"], 172)
        self.assertEqual(fields["total_cached_tokens"], 64)
        self.assertIsNone(fields["total_cost_usd"])
        self.assertEqual(fields["extra"]["metacodes_tool_calls"], 2)


class SmokeProviderTest(unittest.TestCase):
    BASH_TOOL = {"name": "Bash", "input_schema": {}}

    def test_first_request_must_offer_bash(self):
        with self.assertRaises(sp.ScenarioError):
            sp.scripted_response(1, {"model": sp.SMOKE_MODEL, "tools": []})
        body = sp.scripted_response(1, {"model": sp.SMOKE_MODEL, "tools": [self.BASH_TOOL]})
        self.assertIn(b'"tool_use"', body)
        self.assertIn(sp.EXPECTED_FILE.encode(), body)

    def test_second_request_must_carry_the_bash_result(self):
        request = {
            "model": sp.SMOKE_MODEL,
            "messages": [{"role": "user", "content": [
                {"type": "tool_result", "tool_use_id": sp.CALL_ID, "content": "unrelated"},
            ]}],
        }
        with self.assertRaises(sp.ScenarioError):
            sp.scripted_response(2, request)
        request["messages"][0]["content"][0]["content"] = [
            {"type": "text", "text": sp.EXPECTED_TEXT + "\n"}
        ]
        self.assertIn(sp.FINAL_TEXT.encode(), sp.scripted_response(2, request))

    def test_a_third_request_or_other_model_is_refused(self):
        with self.assertRaises(sp.ScenarioError):
            sp.scripted_response(3, {"model": sp.SMOKE_MODEL})
        with self.assertRaises(sp.ScenarioError):
            sp.scripted_response(1, {"model": "other", "tools": [self.BASH_TOOL]})

    def test_config_routes_the_smoke_provider_to_the_endpoint(self):
        config = sp.provider_config("http://host.docker.internal:1234/")
        provider = config["custom_providers"][sp.SMOKE_PROVIDER]
        self.assertEqual(provider["channels"][0]["base_url"], "http://host.docker.internal:1234")
        self.assertEqual(provider["env_aliases"][0]["name"], sp.SMOKE_KEY_ENV)


if __name__ == "__main__":
    unittest.main()
