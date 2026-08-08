import os
import shlex
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

from scripts.eval.paired_runner import _run_once


ROOT = Path(__file__).resolve().parents[3]


@unittest.skipUnless(os.name == "posix", "anonymous inherited descriptor requires POSIX")
class PaidMultiArmCredentialFdL2Test(unittest.TestCase):
    @staticmethod
    def _write_fake_metacodes(path: Path) -> None:
        path.write_text(
            textwrap.dedent(
                """\
                #!/usr/bin/python3 -I
                import os
                import sys

                if "METASK_API_KEY" in os.environ or "E2E_API_KEY_FD" in os.environ:
                    raise SystemExit(41)
                fd = int(os.environ["METACODES_API_KEY_FD"])
                if os.read(fd, 8192) != b"paid-fd-private-key":
                    raise SystemExit(42)
                if os.read(fd, 1) != b"":
                    raise SystemExit(43)
                sys.stdin.read()
                print("anonymous-fd-consumed")
                """
            ),
            encoding="utf-8",
        )
        path.chmod(0o700)

    def test_e2e_shell_transports_anonymous_fd_without_secret_environment(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scenario = root / "paid-fd-smoke.txt"
            scenario.write_text("verify the inherited credential\n", encoding="utf-8")
            fake_binary = root / "fake-metacodes"
            self._write_fake_metacodes(fake_binary)
            workdir = root / "not-in-eval-suite"
            logfile = root / "session.log"
            debug_log = root / "session.debug.log"
            missing_conf = root / "missing.conf"

            read_fd, write_fd = os.pipe()
            try:
                os.write(write_fd, b"paid-fd-private-key")
                os.close(write_fd)
                write_fd = -1
                script = """
set -e
source "$1/tests/e2e/lib.sh"
BIN="$2"
E2E_HOST_HOME=""
unset METASK_API_KEY E2E_AUTH_FILE
export E2E_API_KEY_FD="$3"
export E2E_MAX_METERED_TOKENS=1000
export E2E_MAX_COST_USD=1
run_session "$4" "$5" "$6" "$7" "$8"
"""
                completed = subprocess.run(
                    [
                        "/bin/bash",
                        "-c",
                        script,
                        "paid-fd-l2",
                        str(ROOT),
                        str(fake_binary),
                        str(read_fd),
                        str(scenario),
                        str(workdir),
                        str(logfile),
                        str(debug_log),
                        str(missing_conf),
                    ],
                    cwd=ROOT,
                    env={"PATH": os.defpath, "HOME": str(root)},
                    pass_fds=(read_fd,),
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    timeout=20,
                    check=False,
                )
            finally:
                if write_fd >= 0:
                    os.close(write_fd)
                os.close(read_fd)
            diagnostic = (
                completed.stderr
                + "\nstdout="
                + completed.stdout
                + "\nlog="
                + (logfile.read_text(encoding="utf-8") if logfile.exists() else "<missing>")
            )
            self.assertEqual(completed.returncode, 0, diagnostic)
            self.assertEqual(completed.stdout.strip(), "0")
            self.assertIn(
                "anonymous-fd-consumed", logfile.read_text(encoding="utf-8")
            )
            self.assertNotIn("paid-fd-private-key", completed.stdout)
            self.assertNotIn("paid-fd-private-key", completed.stderr)
            self.assertNotIn(
                "paid-fd-private-key", logfile.read_text(encoding="utf-8")
            )

    def test_run_once_crosses_real_shell_bridge_with_one_shot_fd(self):
        """Exercise the production runner seam, not only either side of it."""

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            e2e = root / "tests/e2e"
            scenarios = e2e / "scenarios"
            scenarios.mkdir(parents=True)
            (scenarios / "fd_bridge.txt").write_text(
                "verify the inherited credential\n", encoding="utf-8"
            )
            fake_binary = root / "fake-metacodes"
            self._write_fake_metacodes(fake_binary)

            # _run_once invokes this repository-owned entry point.  The small
            # wrapper delegates the actual process launch to the checked-in
            # lib.sh, so the test spans Python pipe creation, pass_fds, the
            # E2E_API_KEY_FD -> METACODES_API_KEY_FD bridge, and child read.
            run_script = e2e / "run_e2e.sh"
            run_script.write_text(
                textwrap.dedent(
                    f"""\
                    #!/bin/bash
                    set -e
                    source {shlex.quote(str((ROOT / 'tests/e2e/lib.sh').resolve()))}
                    local_e2e="$(cd "$(dirname "$0")" && pwd)"
                    run_dir="$local_e2e/runs/fd-bridge-$$"
                    mkdir -p "$run_dir"
                    rc="$(run_session \\
                      "$local_e2e/scenarios/fd_bridge.txt" \\
                      "$run_dir/fd_bridge" \\
                      "$run_dir/fd_bridge.log" \\
                      "$run_dir/fd_bridge.debug.log" \\
                      "$local_e2e/scenarios/missing.conf")"
                    [[ "$rc" == "0" ]]
                    """
                ),
                encoding="utf-8",
            )
            run_script.chmod(0o700)

            run_dir = _run_once(
                root,
                fake_binary,
                "codex_style",
                0,
                "fd_bridge",
                "anthropic",
                "glm-5.2",
                ROOT / "evals/suites/long-horizon-repository-pk.json",
                "fd-bridge-test",
                harness_config_id="fd-bridge-test",
                runtime_env={},
                timeout_seconds=20,
                max_metered_tokens=1000,
                max_cost_usd=1.0,
                runtime_api_key="paid-fd-private-key",
            )
            logfile = run_dir / "fd_bridge.log"
            self.assertIn("anonymous-fd-consumed", logfile.read_text(encoding="utf-8"))
            for artifact in run_dir.rglob("*"):
                if artifact.is_file():
                    self.assertNotIn(
                        "paid-fd-private-key",
                        artifact.read_text(encoding="utf-8", errors="replace"),
                    )


if __name__ == "__main__":
    unittest.main()
