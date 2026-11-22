"""`metacodes bench pull`: task images reach the executor's Docker before a run."""
from __future__ import annotations

import contextlib
import io
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts.eval.harbor import cli
from scripts.eval.harbor.bench import executors, images
from scripts.eval.tests.posix_only import requires_posix_exec

FAKE_DOCKER = r'''#!/bin/sh
echo "$*" >> "$FAKE_DOCKER_LOG"
case "$1" in
  image) grep -qx "$3" "$FAKE_DOCKER_IMAGES" ;;
  pull)
    count=$(grep -c "^pull $2\$" "$FAKE_DOCKER_LOG")
    if [ "$2" = "$FAKE_DOCKER_FLAKY" ] && [ "$count" -lt 2 ]; then
      echo "socks connect tcp 127.0.0.1:1080->registry-1.docker.io:443: EOF" >&2; exit 1
    fi
    [ "$2" = "$FAKE_DOCKER_BROKEN" ] && { echo "manifest unknown" >&2; exit 1; }
    echo "$2" >> "$FAKE_DOCKER_IMAGES" ;;
esac
'''


def write_task(dataset: Path, name: str, image=None) -> None:
    task = dataset / name
    (task / "environment").mkdir(parents=True)
    (task / "environment" / "Dockerfile").write_text("FROM python:3.12-slim\n")
    environment = f'docker_image = "{image}"\n' if image else ""
    (task / "task.toml").write_text(f'[task]\nname = "{name}"\n\n[environment]\n{environment}cpus = 1\n')


@requires_posix_exec
class BenchPullTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: subprocess.run(["rm", "-rf", str(self.tmp)], check=False))
        self.dataset = self.tmp / "dataset"
        write_task(self.dataset, "fix-git", "alexgshaw/fix-git:20260403")
        write_task(self.dataset, "fix-git-2", "alexgshaw/fix-git:20260403")
        write_task(self.dataset, "regex-log", "alexgshaw/regex-log:20251031")
        write_task(self.dataset, "overfull-hbox", "alexgshaw/overfull-hbox:20251031")
        write_task(self.dataset, "build-here")
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        (bin_dir / "docker").write_text(FAKE_DOCKER)
        (bin_dir / "docker").chmod(0o755)
        self.log = self.tmp / "docker.log"
        self.present = self.tmp / "images"
        self.present.write_text("alexgshaw/fix-git:20260403\n")
        env = {"PATH": f"{bin_dir}:{os.environ['PATH']}", "FAKE_DOCKER_LOG": str(self.log),
               "FAKE_DOCKER_IMAGES": str(self.present), "FAKE_DOCKER_FLAKY": "alexgshaw/regex-log:20251031",
               "FAKE_DOCKER_BROKEN": "alexgshaw/overfull-hbox:20251031"}
        patcher = patch.dict(os.environ, env)
        patcher.start()
        self.addCleanup(patcher.stop)
        sleep = patch.object(images.time, "sleep", lambda _: None)
        sleep.start()
        self.addCleanup(sleep.stop)

    def bench(self, *args):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = cli.main(["pull", "--state-root", str(self.tmp / "state"), "--suite", "humaneval",
                             "--dataset", f"humaneval={self.dataset}", "--json", *args])
        return code, json.loads(out.getvalue())

    def docker_calls(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def test_dry_run_only_inspects(self) -> None:
        code, value = self.bench("--dry-run")
        self.assertEqual(code, 0)
        self.assertEqual({r["image"]: r["status"] for r in value["images"]},
                         {"alexgshaw/fix-git:20260403": "present", "alexgshaw/regex-log:20251031": "missing",
                          "alexgshaw/overfull-hbox:20251031": "missing"})
        self.assertEqual(value["built"], ["build-here"])
        self.assertFalse([c for c in self.docker_calls() if c.startswith("pull")])

    def test_pulls_missing_images_with_retries_and_reports_failures(self) -> None:
        code, value = self.bench()
        self.assertEqual(code, 1)
        rows = {r["image"]: r for r in value["images"]}
        self.assertEqual(rows["alexgshaw/fix-git:20260403"]["tasks"], ["fix-git", "fix-git-2"])
        self.assertEqual(rows["alexgshaw/fix-git:20260403"]["status"], "present")
        self.assertEqual((rows["alexgshaw/regex-log:20251031"]["status"],
                          rows["alexgshaw/regex-log:20251031"]["attempts"]), ("pulled", 2))
        self.assertEqual(rows["alexgshaw/overfull-hbox:20251031"]["status"], "failed")
        self.assertIn("manifest unknown", rows["alexgshaw/overfull-hbox:20251031"]["error"])
        pulls = [c for c in self.docker_calls() if c.startswith("pull")]
        self.assertNotIn("pull alexgshaw/fix-git:20260403", pulls)
        self.assertEqual(pulls.count("pull alexgshaw/overfull-hbox:20251031"), images.PULL_ATTEMPTS)
        self.assertIn("alexgshaw/regex-log:20251031", self.present.read_text().splitlines())

    def test_selected_tasks_only(self) -> None:
        code, value = self.bench("--task", "regex-log")
        self.assertEqual(code, 0)
        self.assertEqual([r["image"] for r in value["images"]], ["alexgshaw/regex-log:20251031"])
        self.assertEqual(value["built"], [])


class SshPullTest(unittest.TestCase):
    def test_ghcr_image_is_pulled_through_the_executor_mirror_and_tagged_back(self) -> None:
        executor = executors.SshExecutor("relay", "relay.example", ghcr_mirror="ghcr.example")
        calls = []

        def runner(argv, **_):
            calls.append(argv)
            return subprocess.CompletedProcess(argv, 1 if "inspect" in argv[-1] else 0, "", "")

        result = images.pull_one(executor, "ghcr.io/org/task:1", check_only=False, runner=runner,
                                 log=lambda _: None, sleep=lambda _: None)
        self.assertEqual(result["status"], "pulled")
        self.assertEqual(calls[-1][:2], [calls[-1][0], "-o"])
        self.assertIn("relay.example", calls[-1])
        self.assertIn("docker pull ghcr.example/org/task:1 && docker tag ghcr.example/org/task:1 ghcr.io/org/task:1",
                      calls[-1][-1])

    def test_invalid_image_reference_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            write_task(Path(tmp), "bad", "alexgshaw/x; rm -rf /")
            with self.assertRaises(ValueError):
                images.images_of(Path(tmp), ["bad"])


if __name__ == "__main__":
    unittest.main()
