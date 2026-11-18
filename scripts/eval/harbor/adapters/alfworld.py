"""ALFWorld (TextWorld, eval_out_of_distribution = valid_unseen: 134 games) as Harbor 0.26 tasks.

Source: the ALFWorld TextWorld game files, release asset
github.com/alfworld/alfworld/releases/download/0.4.0/json_2.1.2_tw-pddl.zip
(tag 0.4.0 = commit beadec4de1de2485e8a260138a9ba2ac27a8865a; MIT), the file
`alfworld-download` (alfworld 0.4.2) fetches. SHA-256 pinned. Each task is one
solvable game.tw-pddl from json_2.1.1/valid_unseen (the split ALFWorld,
ReAct and AgentBench report as "unseen"); movable/sliced trajectories are
excluded as in AlfredTWEnv.collect_game_files (valid_unseen has none).

How a task runs (Harbor 0.26 compose sidecar, as in adapters/gaia2 and
examples/tasks/sidecar-artifacts):

* `alfworld-env` sidecar (environment/alfworld-env/): alfworld 0.4.2 +
  textworld 1.6.2 + fast-downward-textworld serving one game over HTTP
  (alfworld_env/server.py). It holds the game file and the oracle token;
  the agent's container cannot read them.
* agent container: python:3.12-slim with the `alfworld` CLI
  (alfworld_env/alfworld_cli.py). The agent plays step by step:
  `alfworld look`, `alfworld act "<command>"`, `alfworld actions`.
  The budget is 50 actions, ALFWorld's usual evaluation horizon.
* verification: Harbor's collect hook freezes the episode inside the sidecar,
  collects the sidecar's /var/lib/alfworld/result.json as an artifact, and a
  separate offline verifier (graders/alfworld_grader.py) awards 1 iff the
  environment's own `won` flag became true within the budget. Nothing the
  agent writes or says is read.
* oracle: solution/solve.sh calls `alfworld oracle <token>`; the sidecar
  plays alfworld's PDDL planner expert (AlfredExpert "planner") through the
  same step path, so the oracle run validates game, budget and verifier.

Architecture: the sidecar is linux/amd64 only (textworld 1.6.2 has no
linux/arm64 wheel; the compose file pins `platform: linux/amd64`, so an ARM
host needs amd64 emulation and the first build is slow). The agent image is
multi-arch.
"""

from __future__ import annotations

import hashlib
import json
import secrets
import zipfile
from pathlib import Path
from typing import Dict, List, Tuple

from scripts.eval.harbor.adapters import _common as c

GENERATOR_VERSION = "1"
PIN = c.Pin(
    name="json_2.1.2_tw-pddl.zip",
    url="https://github.com/alfworld/alfworld/releases/download/0.4.0/json_2.1.2_tw-pddl.zip",
    sha256="eea90499df27b9cb3147d1d1927264146d38194b575e25f70a82875545742dcb",
    size=36493542,
)
SPLIT_PREFIX = "json_2.1.1/valid_unseen/"
MAX_STEPS = 50
SIDECAR = "alfworld-env"
RESULT_PATH = "/var/lib/alfworld/result.json"
PACKAGES = ("alfworld==0.4.2", "textworld==1.6.2", "fast-downward-textworld==20.6.4", "spacy==3.7.5")
TASK_TYPES = (
    "pick_and_place_simple",
    "look_at_obj_in_light",
    "pick_clean_then_place_in_recep",
    "pick_heat_then_place_in_recep",
    "pick_cool_then_place_in_recep",
    "pick_two_obj_and_place",
)

SUITE_ID = "alfworld"  # catalog id (scripts/eval/harbor/suites ADAPTER_SUITES)

SUITE = {
    "name": "ALFWorld (unseen)",
    "description": "ALFWorld 文本家居任务（valid_unseen 134 局）：智能体通过容器内 `alfworld` 命令逐步与 TextWorld 环境交互，50 步内由环境自身判定完成才得 1 分。",
    # The first game of each task type in task-id order.
    "default_tasks": [
        "alfworld-look_at_obj_in_light-18956eba",
        "alfworld-pick_and_place_simple-1111835c",
        "alfworld-pick_clean_then_place_in_recep-049430f7",
        "alfworld-pick_cool_then_place_in_recep-062ccf61",
        "alfworld-pick_heat_then_place_in_recep-02f08b87",
        "alfworld-pick_two_obj_and_place-00b4d8ba",
    ],
    "max_tasks": 134,
    "max_concurrency": 3,
    "arch": "amd64 only for the environment sidecar (textworld has no linux/arm64 wheel; runs under emulation on ARM hosts)",
}


def task_id_for(game_path: str) -> Tuple[str, str]:
    """(task id, task type) for json_2.1.1/valid_unseen/<type>-.../trial_.../game.tw-pddl."""
    rel = game_path[len(SPLIT_PREFIX) :]
    task_type = rel.split("-", 1)[0]
    if task_type not in TASK_TYPES:
        raise c.SourceIntegrityError(f"alfworld: unknown task type in {game_path}")
    digest = hashlib.sha256(rel.encode("utf-8")).hexdigest()[:8]
    return f"alfworld-{task_type}-{digest}", task_type


def games(archive: Path) -> List[Tuple[str, bytes]]:
    """(path, bytes) of the solvable valid_unseen games, sorted by path."""
    out: List[Tuple[str, bytes]] = []
    with zipfile.ZipFile(archive) as zf:
        for name in sorted(zf.namelist()):
            if not (name.startswith(SPLIT_PREFIX) and name.endswith("/game.tw-pddl")):
                continue
            if "movable" in name or "Sliced" in name:
                continue
            data = zf.read(name)
            game = json.loads(data.decode("utf-8"))
            if game.get("solvable") is not True:
                continue
            out.append((name, data))
    return out


INSTRUCTION = """# ALFWorld household task

You are an agent in a simulated household (ALFWorld, the text version of the
ALFRED embodied tasks). The environment runs in a separate service; you act in
it only through the `alfworld` command in this container:

- `alfworld look` prints the task and the latest observation. Start here.
- `alfworld act "<command>"` performs one action and prints what happened.
- `alfworld actions` lists the commands that are valid right now.
- `alfworld status` shows the steps used and whether the task is complete.

Commands look like: `go to countertop 1`, `open fridge 1`, `close fridge 1`,
`take apple 1 from countertop 1`, `move apple 1 to fridge 1`,
`heat potato 1 with microwave 1`, `cool apple 1 with fridge 1`,
`clean mug 1 with sinkbasin 1`, `use desklamp 1`, `examine book 1`,
`inventory`, `look`. An action that does not apply prints "Nothing happens."
and still counts.

You have at most {max_steps} actions (`alfworld act` calls); `look`, `actions`
and `status` are free. The episode is graded by the environment alone: you
succeed only if it reports the task complete within the budget. Nothing you
write to files or say in your reply is graded.
"""


def compose_yaml() -> str:
    return f"""# ALFWorld environment sidecar; Harbor configures `main` itself.
services:
  main:
    environment:
      ALFWORLD_URL: "http://{SIDECAR}:8080"
    depends_on:
      {SIDECAR}:
        condition: service_healthy

  {SIDECAR}:
    build:
      context: ${{CONTEXT_DIR}}/{SIDECAR}
    image: ${{MAIN_IMAGE_NAME}}_{SIDECAR.replace('-', '_')}
    platform: linux/amd64
    expose:
      - "8080"
    healthcheck:
      test: ["CMD", "python3", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=5)"]
      interval: 5s
      timeout: 10s
      retries: 60
      start_period: 30s
"""


def sidecar_dockerfile() -> str:
    packages = " ".join(f'"{p}"' for p in PACKAGES)
    return (
        "# ALFWorld environment sidecar. linux/amd64 only: textworld 1.6.2 has no\n"
        "# linux/arm64 wheel, and fast-downward-textworld and jericho build from source.\n"
        f"FROM --platform=linux/amd64 {c.PYTHON_310_IMAGE}\n"
        "RUN apt-get update \\\n"
        "    && apt-get install -y --no-install-recommends build-essential cmake \\\n"
        "    && rm -rf /var/lib/apt/lists/*\n"
        f"RUN pip install --no-cache-dir {packages}\n"
        "COPY server.py task.json game.tw-pddl oracle_token /opt/alfworld-env/\n"
        "RUN chmod 0600 /opt/alfworld-env/oracle_token && mkdir -p /var/lib/alfworld\n"
        "EXPOSE 8080\n"
        'CMD ["python3", "/opt/alfworld-env/server.py", "--game", "/opt/alfworld-env/game.tw-pddl", '
        '"--task", "/opt/alfworld-env/task.json", "--oracle-token", "/opt/alfworld-env/oracle_token"]\n'
    )


def agent_dockerfile() -> str:
    return (
        "# Agent environment: only the `alfworld` client; the game lives in the sidecar.\n"
        f"FROM {c.PYTHON_312_IMAGE}\n"
        "COPY alfworld_cli.py /usr/local/bin/alfworld\n"
        "RUN chmod 0755 /usr/local/bin/alfworld\n"
        "WORKDIR /app\n"
    )


def verifier_dockerfile() -> str:
    return (
        "# Separate verifier image (owns /tests; Harbor does not upload tests/ in separate mode).\n"
        f"FROM {c.PYTHON_312_IMAGE}\n"
        "COPY test.sh alfworld_grader.py spec.json /tests/\n"
        "RUN chmod 0755 /tests/test.sh && mkdir -p /logs/verifier\n"
    )


TEST_SH = f"""#!/bin/bash
# Reward from the sidecar's own episode record (collected artifact).
set -u
mkdir -p /logs/verifier
python3 /tests/alfworld_grader.py --spec /tests/spec.json --result {RESULT_PATH} \\
  --reward /logs/verifier/reward.txt --details /logs/verifier/grade.json
status=$?
[ -s /logs/verifier/reward.txt ] || echo 0 > /logs/verifier/reward.txt
exit $status
"""

FINALIZE = (
    "python3 -c \"import urllib.request; urllib.request.urlopen(urllib.request.Request("
    "'http://127.0.0.1:8080/finalize', data=b'{}', method='POST'), timeout=30)\""
)


def task_files(game_path: str, data: bytes, oracle_token: str) -> Tuple[str, Dict[str, c.FileContent]]:
    tid, task_type = task_id_for(game_path)
    game_sha256 = c.sha256_bytes(data)
    trial = game_path[len(SPLIT_PREFIX) :].rsplit("/", 1)[0]
    config = c.base_task_config(
        task_id=tid,
        description=f"ALFWorld valid_unseen {task_type}: {trial}",
        keywords=["alfworld", "textworld", "interactive", task_type],
        metadata={
            "benchmark": "alfworld",
            "split": "valid_unseen",
            "task_type": task_type,
            "source_id": trial,
            "max_steps": MAX_STEPS,
            "source": "alfworld/alfworld@0.4.0:json_2.1.2_tw-pddl.zip",
        },
        artifacts=[{"source": RESULT_PATH, "service": SIDECAR}],
        agent_timeout_sec=1800.0,
        verifier_timeout_sec=120.0,
        cpus=2,
        memory_mb=4096,
        storage_mb=8192,
        build_timeout_sec=2400.0,
        collect=[{"service": SIDECAR, "command": FINALIZE, "timeout_sec": 60.0}],
    )
    task_json = {"task_id": tid, "game_sha256": game_sha256, "max_steps": MAX_STEPS}
    files: Dict[str, c.FileContent] = {
        "task.toml": c.task_toml(config),
        "instruction.md": INSTRUCTION.replace("{max_steps}", str(MAX_STEPS)),
        "environment/Dockerfile": agent_dockerfile(),
        "environment/docker-compose.yaml": compose_yaml(),
        "environment/alfworld_cli.py": c.read_template("alfworld_env", "alfworld_cli.py"),
        f"environment/{SIDECAR}/Dockerfile": sidecar_dockerfile(),
        f"environment/{SIDECAR}/server.py": c.read_template("alfworld_env", "server.py"),
        f"environment/{SIDECAR}/game.tw-pddl": data,
        f"environment/{SIDECAR}/task.json": json.dumps(task_json, indent=1) + "\n",
        f"environment/{SIDECAR}/oracle_token": oracle_token + "\n",
        "solution/solve.sh": (
            "#!/bin/bash\n"
            "# Oracle: the sidecar plays alfworld's PDDL planner expert through its step path.\n"
            "set -euo pipefail\n"
            f"alfworld oracle {oracle_token}\n"
        ),
        "tests/Dockerfile": verifier_dockerfile(),
        "tests/test.sh": TEST_SH,
        "tests/alfworld_grader.py": c.read_template("graders", "alfworld_grader.py"),
        "tests/spec.json": json.dumps(task_json, indent=1, sort_keys=True) + "\n",
    }
    return tid, files


def build(inputs: Dict[str, Path], out: Path) -> None:
    for game_path, data in games(inputs[PIN.name]):
        tid, files = task_files(game_path, data, secrets.token_hex(16))
        c.write_task(out / tid, files)


def fingerprint() -> str:
    return c.fingerprint_of(
        "alfworld",
        GENERATOR_VERSION,
        PIN,
        MAX_STEPS,
        PACKAGES,
        files=[
            Path(__file__).resolve(),
            c.template_path("_common.py"),
            c.template_path("alfworld_env", "server.py"),
            c.template_path("alfworld_env", "alfworld_cli.py"),
            c.template_path("graders", "alfworld_grader.py"),
        ],
    )


def prepare(dest: Path) -> Path:
    """Download the pinned ALFWorld game archive and write the valid_unseen tasks into dest."""
    return c.prepare_dataset(
        Path(dest),
        suite_id=SUITE_ID,
        fingerprint=fingerprint(),
        fetch_sources=lambda cache: {PIN.name: c.fetch(PIN, cache)},
        build=build,
        provenance={"alfworld_games": PIN.describe(), "split": "valid_unseen", "license": "MIT"},
    )


def tasks(dataset: Path) -> List[str]:
    return c.task_ids(Path(dataset))
