"""`metacodes bench pull`: task images are pulled or built on the executor before a run."""
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
  info) [ -z "$FAKE_DOCKER_DOWN" ] || { echo "Cannot connect to the Docker daemon" >&2; exit 1; } ;;
  image) grep -qx "$3" "$FAKE_DOCKER_IMAGES" ;;
  pull)
    count=$(grep -c "^pull $2\$" "$FAKE_DOCKER_LOG")
    if [ "$2" = "$FAKE_DOCKER_FLAKY" ] && [ "$count" -lt 2 ]; then
      echo "socks connect tcp 127.0.0.1:1080->registry-1.docker.io:443: EOF" >&2; exit 1
    fi
    [ "$2" = "$FAKE_DOCKER_BROKEN" ] && { echo "manifest unknown" >&2; exit 1; }
    echo "$2" >> "$FAKE_DOCKER_IMAGES" ;;
  compose)
    echo "context=$CONTEXT_DIR" >> "$FAKE_DOCKER_LOG"
    [ -e "$CONTEXT_DIR/BROKEN" ] && { echo "pip install failed" >&2; exit 1; }
    while [ $# -gt 0 ]; do [ "$1" = "-f" ] && cat "$2" >> "$FAKE_DOCKER_LOG.compose"; shift; done
    echo "$MAIN_IMAGE_NAME" >> "$FAKE_DOCKER_IMAGES" ;;
esac
'''


def write_task(dataset: Path, name: str, image=None, extra=None) -> None:
    task = dataset / name
    (task / "environment").mkdir(parents=True)
    (task / "environment" / "Dockerfile").write_text("FROM python:3.12-slim\n")
    for file, text in (extra or {}).items():
        (task / "environment" / file).write_text(text)
    environment = f'docker_image = "{image}"\n' if image else ""
    (task / "task.toml").write_text(f'[task]\nname = "{name}"\n\n[environment]\n{environment}cpus = 1\n')


@requires_posix_exec
class BenchPullTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp()).resolve()
        self.addCleanup(lambda: subprocess.run(["rm", "-rf", str(self.tmp)], check=False))
        self.dataset = self.tmp / "dataset"
        write_task(self.dataset, "fix-git", "alexgshaw/fix-git:20260403")
        write_task(self.dataset, "fix-git-2", "alexgshaw/fix-git:20260403")
        write_task(self.dataset, "regex-log", "alexgshaw/regex-log:20251031")
        write_task(self.dataset, "overfull-hbox", "alexgshaw/overfull-hbox:20251031")
        write_task(self.dataset, "build-here")
        write_task(self.dataset, "build-here-2")
        write_task(self.dataset, "with-sidecar", extra={"docker-compose.yaml": "services:\n  side:\n    build: ./side\n"})
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
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = cli.main(["pull", "--state-root", str(self.tmp / "state"), "--suite", "humaneval",
                             "--dataset", f"humaneval={self.dataset}", "--json", *args])
        self.stderr = err.getvalue()
        return code, json.loads(out.getvalue()) if out.getvalue() else None

    def docker_calls(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def builds(self, value):
        return {tuple(r["tasks"]): r for r in value["images"] if r["kind"] == "build"}

    def test_dry_run_only_inspects(self) -> None:
        code, value = self.bench("--dry-run")
        self.assertEqual(code, 0)
        self.assertEqual({r["image"]: r["status"] for r in value["images"] if r["kind"] == "pull"},
                         {"alexgshaw/fix-git:20260403": "present", "alexgshaw/regex-log:20251031": "missing",
                          "alexgshaw/overfull-hbox:20251031": "missing"})
        self.assertEqual({tasks: r["status"] for tasks, r in self.builds(value).items()},
                         {("build-here", "build-here-2"): "missing", ("with-sidecar",): "missing"})
        self.assertFalse([c for c in self.docker_calls() if c.startswith(("pull", "compose"))])

    def test_builds_each_distinct_environment_like_harbor(self) -> None:
        code, value = self.bench("--task", "build-here", "--task", "build-here-2", "--task", "with-sidecar")
        self.assertEqual(code, 0)
        builds = self.builds(value)
        self.assertEqual({tasks: r["status"] for tasks, r in builds.items()},
                         {("build-here", "build-here-2"): "built", ("with-sidecar",): "built"})
        calls = self.docker_calls()
        composes = [c for c in calls if c.startswith("compose")]
        self.assertEqual(len(composes), 2)
        for tasks, row in builds.items():
            context = self.dataset / tasks[0] / "environment"
            command = next(c for c in composes if row["image"] in c)
            self.assertIn(f"compose -p {row['image']} --project-directory {context} -f ", command)
            self.assertEqual(command.endswith(f"{context}/docker-compose.yaml build"), tasks == ("with-sidecar",))
            self.assertIn(f"context={context}", calls)
        self.assertIn("context: ${CONTEXT_DIR}", Path(str(self.log) + ".compose").read_text())
        code, value = self.bench("--dry-run", "--task", "build-here", "--task", "with-sidecar")
        self.assertEqual([r["status"] for r in value["images"]], ["present", "present"])

    def test_failed_build_is_retried_then_reported(self) -> None:
        (self.dataset / "build-here" / "environment" / "BROKEN").write_text("")
        code, value = self.bench("--task", "build-here")
        self.assertEqual(code, 1)
        row = value["images"][0]
        self.assertEqual((row["status"], row["attempts"]), ("failed", images.PULL_ATTEMPTS))
        self.assertIn("pip install failed", row["error"])

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

    def test_unreachable_docker_fails_before_any_image(self) -> None:
        for args in (("--dry-run",), ()):
            with self.subTest(args=args), patch.dict(os.environ, {"FAKE_DOCKER_DOWN": "1"}):
                code, value = self.bench(*args)
                self.assertEqual((code, value), (1, None))
                self.assertIn("Cannot connect to the Docker daemon", self.stderr)
        self.assertEqual(self.docker_calls(), ["info", "info"])

    def test_selected_tasks_only(self) -> None:
        code, value = self.bench("--task", "regex-log")
        self.assertEqual(code, 0)
        self.assertEqual([r["image"] for r in value["images"]], ["alexgshaw/regex-log:20251031"])


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

    def test_build_ships_the_environment_and_builds_it_on_the_executor(self) -> None:
        executor = executors.SshExecutor("relay", "relay.example")
        calls, shipped = [], []

        def runner(argv, **_):
            calls.append(argv)
            return subprocess.CompletedProcess(argv, 0, "", "")

        with tempfile.TemporaryDirectory() as tmp:
            write_task(Path(tmp), "task")
            _, builds = images.images_of(Path(tmp), ["task"])
            [(digest, build)] = builds.items()
            result = images.build_one(executor, digest, build, check_only=False, runner=runner, log=lambda _: None,
                                      sleep=lambda _: None, ship=lambda *a, **k: shipped.append(a))
        self.assertEqual(result["status"], "built")
        remote = executor.remote("prebuild", digest)
        self.assertEqual([(a[0], a[2], a[3]) for a in shipped], [(executor, ["Dockerfile"], remote)])
        self.assertIn("relay.example", calls[-1])
        self.assertIn(f"ctx=$(cd {remote} && pwd)", calls[-1][-1])
        self.assertIn(f"docker compose -p {images.BUILD_TAG}{digest}", calls[-1][-1])

    def test_invalid_image_reference_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            write_task(Path(tmp), "bad", "alexgshaw/x; rm -rf /")
            with self.assertRaises(ValueError):
                images.images_of(Path(tmp), ["bad"])


if __name__ == "__main__":
    unittest.main()
