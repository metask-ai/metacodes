"""`metacodes bench pull`: pull or build a suite's task images on an executor before a run."""
from __future__ import annotations

import re
import shlex
import subprocess
import time
from pathlib import Path
from typing import Callable, Dict, List, Optional, Sequence

from scripts.eval.harbor import suites
from scripts.eval.harbor.bench import executors
from scripts.eval.harbor.bench.egress import TOML_IMAGE, mirror_ref
from scripts.eval.harbor.bench.executors import Executor, shell_argv

IMAGE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/:@-]{0,255}$")
PULL_ATTEMPTS = 3
PULL_BACKOFF = (10, 30)
PULL_TIMEOUT = 3600
INSPECT_TIMEOUT = 60
BUILD_TAG = "metacodes-prebuild-"
BUILD_COMPOSE = ("services:\n  main:\n    build:\n      context: ${CONTEXT_DIR}\n"
                 "    image: ${MAIN_IMAGE_NAME}\n    pull_policy: build\n")


def suite_dataset(suite: suites.Suite, ctx: suites.Context, cache_root: Path, harbor: Optional[str],
                  log: Callable[[str], None]) -> Path:
    if suite.runner == suites.HARBOR_REGISTRY:
        return executors.registry_dataset(suite.dataset, cache_root, harbor, expected=suite.tasks, log=log)
    if suite.runner == suites.HARBOR_LOCAL:
        return ctx.dataset_dir(suite)
    raise ValueError(suite.name + " 的环境由 WorkBuddy 自己准备，不支持预拉镜像")


def task_image(task_dir: Path) -> Optional[str]:
    try:
        text = (task_dir / "task.toml").read_text(encoding="utf-8")
    except OSError:
        raise ValueError("任务缺少 task.toml：" + task_dir.name) from None
    found = TOML_IMAGE.search(text)
    if not found:
        return None
    if not IMAGE.fullmatch(found.group(1)):
        raise ValueError(f"{task_dir.name} 的 docker_image 无效：{found.group(1)[:80]}")
    return found.group(1)


def images_of(dataset: Path, tasks: Sequence[str]):
    images: Dict[str, List[str]] = {}
    builds: Dict[str, Dict] = {}
    for task in tasks:
        image = task_image(dataset / task)
        if image:
            images.setdefault(image, []).append(task)
            continue
        environment = dataset / task / "environment"
        names = executors.tree_files(environment)
        if not names:
            raise ValueError(f"{task} 既没有 docker_image，也没有 environment 目录")
        digest = executors.tree_digest(environment, names)
        build = builds.setdefault(digest, {"environment": environment, "names": names, "tasks": []})
        build["tasks"].append(task)
    return images, builds


def docker(executor: Executor, script: str, runner, timeout: int):
    try:
        done = runner(shell_argv(executor, script), stdin=subprocess.DEVNULL, capture_output=True, text=True,
                      timeout=timeout)
    except subprocess.TimeoutExpired:
        return False, f"超过 {timeout} 秒"
    except OSError as exc:
        return False, str(exc)
    output = ((done.stdout or "") + (done.stderr or "")).strip()
    return done.returncode == 0, output[-600:]


def pull_one(executor: Executor, image: str, *, check_only: bool, runner, log, sleep) -> Dict:
    q = shlex.quote
    present, _ = docker(executor, f"docker image inspect {q(image)} >/dev/null 2>&1", runner, INSPECT_TIMEOUT)
    if present:
        return {"status": "present"}
    if check_only:
        return {"status": "missing"}
    mirror = getattr(executor, "ghcr_mirror", None)
    source = mirror_ref(image, mirror) if mirror and image.startswith("ghcr.io/") else image
    script = f"docker pull {q(source)}" + (f" && docker tag {q(source)} {q(image)}" if source != image else "")
    error = ""
    for attempt in range(1, PULL_ATTEMPTS + 1):
        log(f"拉取 {source}" + (f"（第 {attempt} 次）" if attempt > 1 else ""))
        ok, error = docker(executor, script, runner, PULL_TIMEOUT)
        if ok:
            return {"status": "pulled", "attempts": attempt}
        if attempt < PULL_ATTEMPTS:
            sleep(PULL_BACKOFF[attempt - 1])
    return {"status": "failed", "attempts": PULL_ATTEMPTS, "error": error}


def build_one(executor: Executor, digest: str, build: Dict, *, check_only: bool, runner, log, sleep, ship) -> Dict:
    q = shlex.quote
    tag = BUILD_TAG + digest
    if check_only:
        present, _ = docker(executor, f"docker image inspect {q(tag)} >/dev/null 2>&1", runner, INSPECT_TIMEOUT)
        return {"status": "present" if present else "missing"}
    context = str(build["environment"])
    if isinstance(executor, executors.SshExecutor):
        context = executor.remote("prebuild", digest)
        ship(executor, build["environment"], build["names"], context, log=log)
    task_compose = ' -f "$ctx/docker-compose.yaml"' if "docker-compose.yaml" in build["names"] else ""
    script = (f'ctx=$(cd {q(context)} && pwd) || exit 1; f=$(mktemp) || exit 1; printf %s {q(BUILD_COMPOSE)} > "$f"; '
              f'CONTEXT_DIR="$ctx" MAIN_IMAGE_NAME={q(tag)} docker compose -p {q(tag)} --project-directory "$ctx" '
              f'-f "$f"{task_compose} build; rc=$?; rm -f "$f"; exit $rc')
    error = ""
    for attempt in range(1, PULL_ATTEMPTS + 1):
        log(f"构建 {build['tasks'][0]} 的环境" + (f"（第 {attempt} 次）" if attempt > 1 else ""))
        ok, error = docker(executor, script, runner, PULL_TIMEOUT)
        if ok:
            return {"status": "built", "attempts": attempt}
        if attempt < PULL_ATTEMPTS:
            sleep(PULL_BACKOFF[attempt - 1])
    return {"status": "failed", "attempts": PULL_ATTEMPTS, "error": error}


def prepull(cfg: Dict, root: Path, suite_id: str, tasks: Sequence[str], executor_name: Optional[str], *,
            check_only=False, runner=subprocess.run, log: Callable[[str], None] = print,
            sleep: Optional[Callable[[float], None]] = None, ship=None) -> Dict:
    suite = suites.resolved(suites.get(suite_id))
    ctx = suites.Context(cfg, root)
    executor = executors.find(cfg, executor_name)
    dataset = suite_dataset(suite, ctx, root / "registry-cache", executors.workbench_harbor(cfg), log)
    chosen = suites.validate_tasks(suite, ctx, list(tasks)) if tasks else suites.task_ids(suite, ctx)
    images, builds = images_of(dataset, chosen)
    if images or builds:
        ready, error = docker(executor, "docker info >/dev/null", runner, INSPECT_TIMEOUT)
        if not ready:
            raise ValueError(f"执行机器 {executor.name} 的 Docker 不可用：{error or '无输出'}")
    sleep = sleep or time.sleep
    rows = []
    for image, users in sorted(images.items()):
        result = pull_one(executor, image, check_only=check_only, runner=runner, log=log, sleep=sleep)
        log(f"{image}：{result['status']}" + (f"（{result['error']}）" if result.get("error") else ""))
        rows.append({"kind": "pull", "image": image, "tasks": users, **result})
    for digest, build in sorted(builds.items()):
        result = build_one(executor, digest, build, check_only=check_only, runner=runner, log=log, sleep=sleep,
                           ship=ship or executors.ship)
        log(f"{BUILD_TAG + digest}：{result['status']}" + (f"（{result['error']}）" if result.get("error") else ""))
        rows.append({"kind": "build", "image": BUILD_TAG + digest, "tasks": build["tasks"], **result})
    counts: Dict[str, int] = {}
    for row in rows:
        counts[row["status"]] = counts.get(row["status"], 0) + 1
    return {"suite": suite.id, "executor": executor.name, "check_only": check_only, "images": rows,
            "counts": counts}
