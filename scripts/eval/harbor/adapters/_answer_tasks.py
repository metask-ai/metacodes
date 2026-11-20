"""Task-directory writer shared by the single-artifact adapters.

HumanEval, MBPP, SearchQA and LiveMathBench tasks have one shape: the agent
writes one file under /app, Harbor collects it as an artifact, and a separate
verifier container built from tests/Dockerfile grades it offline with a
grader from ./graders. The verifier image contains the grader, the task's
spec.json (the hidden tests or the gold answer) and test.sh; none of these is
in the agent's image. See _common.py for the Harbor 0.26 sources this follows
(examples/tasks/sidecar-artifacts, examples/tasks/secure-python-worker).
"""

from __future__ import annotations

import json
from typing import Dict, Mapping, Sequence

from scripts.eval.harbor.adapters import _common as c

GRADERS = {
    "code": "code_grader.py",
    "qa": "qa_grader.py",
    "math": "math_grader.py",
}


def grader_source(kind: str) -> str:
    return c.read_template("graders", GRADERS[kind])


def agent_dockerfile(extra_lines: Sequence[str] = ()) -> str:
    lines = [
        "# Agent environment. Holds no tests and no gold answers.",
        f"FROM {c.PYTHON_312_IMAGE}",
        "WORKDIR /app",
        *extra_lines,
    ]
    return "\n".join(lines) + "\n"


def verifier_dockerfile(grader: str) -> str:
    # The code grader runs the submission as uid 65534 inside this image, so
    # its hidden tests (spec.json) are root-only and /logs/verifier is not
    # writable by that uid; the grader itself runs as root (test.sh).
    spec_mode = "0600" if grader == GRADERS["code"] else "0644"
    return (
        "# Separate verifier image (Harbor builds it from tests/ and does not\n"
        "# upload tests/ in separate mode, so the image owns /tests).\n"
        f"FROM {c.PYTHON_312_IMAGE}\n"
        f"COPY test.sh {grader} spec.json /tests/\n"
        "RUN chmod 0755 /tests/test.sh && chmod 0644 /tests/" + grader + " \\\n"
        f"    && chmod {spec_mode} /tests/spec.json \\\n"
        "    && mkdir -p /app /logs/verifier && chmod 0755 /logs /logs/verifier\n"
    )


def test_sh(grader: str, flag: str, artifact: str) -> str:
    return (
        "#!/bin/bash\n"
        "# Grades the submitted artifact; the reward is 0 or 1 in reward.txt.\n"
        "set -u\n"
        "mkdir -p /logs/verifier\n"
        f"python3 /tests/{grader} --spec /tests/spec.json {flag} {artifact} \\\n"
        "  --reward /logs/verifier/reward.txt --details /logs/verifier/grade.json\n"
        "status=$?\n"
        '[ -s /logs/verifier/reward.txt ] || echo 0 > /logs/verifier/reward.txt\n'
        "exit $status\n"
    )


def solve_sh(artifact: str, content: str) -> str:
    return (
        "#!/bin/bash\n"
        "# Oracle: writes the reference answer where the agent would.\n"
        "set -euo pipefail\n"
        f"mkdir -p {artifact.rsplit('/', 1)[0]}\n" + c.shell_heredoc_file(artifact, content)
    )


def answer_task_files(
    *,
    task_id: str,
    kind: str,
    artifact: str,
    description: str,
    keywords: Sequence[str],
    metadata: Mapping[str, object],
    instruction: str,
    oracle: str,
    spec: Mapping[str, object],
    agent_timeout_sec: float,
    verifier_timeout_sec: float = 300.0,
    environment_files: Mapping[str, c.FileContent] = (),  # type: ignore[assignment]
    dockerfile_lines: Sequence[str] = (),
) -> Dict[str, c.FileContent]:
    grader = GRADERS[kind]
    flag = "--solution" if kind == "code" else "--answer"
    config = c.base_task_config(
        task_id=task_id,
        description=description,
        keywords=keywords,
        metadata=metadata,
        artifacts=[artifact],
        agent_timeout_sec=agent_timeout_sec,
        verifier_timeout_sec=verifier_timeout_sec,
    )
    files: Dict[str, c.FileContent] = {
        "task.toml": c.task_toml(config),
        "instruction.md": instruction if instruction.endswith("\n") else instruction + "\n",
        "environment/Dockerfile": agent_dockerfile(dockerfile_lines),
        "solution/solve.sh": solve_sh(artifact, oracle),
        "tests/Dockerfile": verifier_dockerfile(grader),
        "tests/test.sh": test_sh(grader, flag, artifact),
        "tests/" + grader: grader_source(kind),
        "tests/spec.json": json.dumps(spec, indent=1, sort_keys=True, ensure_ascii=False) + "\n",
    }
    for rel, content in dict(environment_files).items():
        files["environment/" + rel] = content
    return files


def grader_paths() -> Sequence:
    return [c.template_path("graders", name) for name in sorted(GRADERS.values())]


def own_sources() -> Sequence:
    """Files whose bytes reach generated tasks (fingerprint inputs)."""
    return [c.template_path("_answer_tasks.py"), c.template_path("_common.py"), *grader_paths()]
