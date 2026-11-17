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
