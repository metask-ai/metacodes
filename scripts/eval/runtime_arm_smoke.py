#!/usr/bin/env python3
"""Zero-network smoke for the real long-horizon runtime treatment wiring."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Dict


ARMS = ("codex_style", "claude_style", "tinykg")
KG_TOOL_MARKERS = ("\n----- KgRemember -----\n", "\n----- KgRecall -----\n")
TASK_TOOL_MARKER = "\n----- TaskList -----\n"
FORMAL_TOOL_MARKER = "\n----- FormalAuditTask -----\n"
WORKBUDDY_DISABLED_TOOLS = (
    "Agent,Task,TaskBatch,TeamCreate,TeamDelete,SendMessage,"
    "EnterPlanMode,ExitPlanMode"
)


def _headless_protocol_smoke(binary: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="metacodes-headless-protocol-") as directory:
        root = Path(directory)
        home = root / "home"
        work = root / "work"
        home.mkdir()
        work.mkdir()
        target = work / ".gitignore"
        ready = root / "ready.json"
        request_log = root / "requests.jsonl"
        repo = Path(__file__).resolve().parents[2]
        provider = subprocess.Popen(
            [
                sys.executable,
                "-m",
                "scripts.eval.workbuddy.mock_provider",
                "--ready",
                str(ready),
                "--request-log",
                str(request_log),
                "--scenario",
                "headless-permission-v1",
            ],
            cwd=repo,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )
        deadline = time.monotonic() + 5
        while not ready.exists() and provider.poll() is None and time.monotonic() < deadline:
            time.sleep(0.02)
        _require(ready.exists(), "headless protocol mock provider did not become ready")
        port = int(json.loads(ready.read_text(encoding="utf-8"))["port"])
        env = _base_env()
        env.update(
            {
                "HOME": str(home),
                "USERPROFILE": str(home),
                "METACODES_NO_PROBE": "1",
            }
        )
        try:
            completed = subprocess.run(
                [
                    str(binary),
                    "--api-key",
                    "metacodes-workbuddy-mock-only",
                    "--base-url",
                    f"http://127.0.0.1:{port}/v1/messages",
                    "--model",
                    "offline",
                    "--permission",
                    "bypassPermissions",
                    "--no-theme",
                    "--json",
                    "-p",
                    "exercise the protected write boundary",
                ],
                cwd=work,
                env=env,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=20,
                check=False,
            )
        finally:
            provider.terminate()
            try:
                provider.wait(timeout=2)
            except subprocess.TimeoutExpired:
                provider.kill()
                provider.wait(timeout=2)

        requests = request_log.read_text(encoding="utf-8").splitlines()
        _require(
            len(requests) == 2,
            "headless protocol request count drifted: "
            f"{len(requests)}; exit={completed.returncode}; "
            f"stdout={completed.stdout!r}; stderr={completed.stderr[-1000:]!r}; "
            f"target_exists={target.exists()}",
        )
        _require(completed.returncode == 0, f"headless protocol exited {completed.returncode}: {completed.stderr[-1000:]}")
        lines = completed.stdout.splitlines()
        _require(len(lines) == 1, f"headless --json stdout is not exactly one NDJSON event: {completed.stdout!r}")
        try:
            result = json.loads(lines[0])
        except json.JSONDecodeError as exc:
            raise SystemExit("headless --json stdout is not valid NDJSON") from exc
        _require(result.get("type") == "result", "headless --json omitted its result event")
        _require(result.get("text") == "protected write was denied safely", "headless continuation result drifted")
        _require("[Permission]" not in completed.stdout and "Allow?" not in completed.stdout, "permission prompt polluted NDJSON stdout")
        _require("[Permission]" not in completed.stderr and "Allow?" not in completed.stderr, "headless attempted an interactive permission prompt")
        _require(not target.exists(), "protected Write mutated the workspace")


def _workbuddy_tool_policy_smoke(binary: Path, tinykg_binary: Path) -> None:
    """Exercise the actual CLI-to-provider schema used by WorkBuddy."""

    with tempfile.TemporaryDirectory(prefix="metacodes-workbuddy-tool-policy-") as directory:
        root = Path(directory)
        ready = root / "ready.json"
        request_log = root / "requests.jsonl"
        repo = Path(__file__).resolve().parents[2]
        provider = subprocess.Popen(
            [
                sys.executable,
                "-m",
                "scripts.eval.workbuddy.mock_provider",
                "--ready",
                str(ready),
                "--request-log",
                str(request_log),
                "--scenario",
                "guessed-disabled-tool-v1",
            ],
            cwd=repo,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )
        deadline = time.monotonic() + 5
        while not ready.exists() and provider.poll() is None and time.monotonic() < deadline:
            time.sleep(0.02)
        _require(ready.exists(), "WorkBuddy tool-policy provider did not become ready")
        port = int(json.loads(ready.read_text(encoding="utf-8"))["port"])
        try:
            for run in range(2):
                home = root / f"home-{run}"
                work = root / "work"
                home.mkdir()
                work.mkdir(exist_ok=True)
                env = _base_env()
                env.update(
                    {
                        "HOME": str(home),
                        "USERPROFILE": str(home),
                        "METACODES_LONG_HORIZON_ARM": "tinykg",
                        "METACODES_KG_TRANSPORT": "cli-exclusive",
                        "METACODES_KG_BIN": str(tinykg_binary),
                        "METACODES_KG_STORE": str(home / "tinykg-store"),
                        "METACODES_NO_PROBE": "1",
                    }
                )
                completed = subprocess.run(
                    [
                        str(binary),
                        "--api-key",
                        "metacodes-workbuddy-mock-only",
                        "--base-url",
                        f"http://127.0.0.1:{port}/v1/messages",
                        "--model",
                        "offline",
                        "--permission",
                        "bypassPermissions",
                        "--disallowed-tools",
                        WORKBUDDY_DISABLED_TOOLS,
                        "--no-theme",
                        "--json",
                        "-p",
                        "inspect the task and finish",
                    ],
                    cwd=work,
                    env=env,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    timeout=20,
                    check=False,
                )
                _require(
                    completed.returncode == 0,
                    "WorkBuddy tool-policy run failed: " + completed.stderr[-1000:],
                )
        finally:
            provider.terminate()
            try:
                provider.wait(timeout=2)
            except subprocess.TimeoutExpired:
                provider.kill()
                provider.wait(timeout=2)

        rows = [
            json.loads(line)
            for line in request_log.read_text(encoding="utf-8").splitlines()
        ]
        _require(len(rows) == 4, "WorkBuddy tool-policy request count drifted")
        hidden = set(WORKBUDDY_DISABLED_TOOLS.split(","))
        required = {"KgRecall", "KgContext", "KgRemember", "TaskCreate", "TaskList", "TaskUpdate"}
        for row in rows:
            exposed = set(row.get("tool_names", []))
            _require(exposed.isdisjoint(hidden), "WorkBuddy exposed a disabled interactive/swarm tool")
            _require(required <= exposed, "WorkBuddy tool policy disabled TinyKG task/memory tools")
        schema_hashes = {row.get("tool_schema_sha256") for row in rows}
        _require(
            len(schema_hashes) == 1,
            "WorkBuddy tool schema drifted within or across identical fresh runs",
        )


def _base_env() -> Dict[str, str]:
    return {
        key: value
        for key, value in os.environ.items()
        if not key.startswith("METACODES_")
        and not key.startswith("TINYKG_")
        and not key.startswith("CLAUDE_CODE_")
        and key != "RG_BIN"
    }


def _dump(binary: Path, tinykg_binary: Path, arm: str) -> str:
    with tempfile.TemporaryDirectory(prefix=f"metacodes-{arm}-") as directory:
        root = Path(directory)
        home = root / "home"
        work = root / "work"
        home.mkdir()
        work.mkdir()
        env = _base_env()
        env.update(
            {
                "HOME": str(home),
                "USERPROFILE": str(home),
                "METACODES_LONG_HORIZON_ARM": arm,
                "METACODES_NO_PROBE": "1",
            }
        )
        if arm == "tinykg":
            # Rule 8: benchmark memory is an isolated, single-run local Store.
            # Setting only the binary path must not accidentally opt production
            # Metacodes out of its daemon-default shared-Store boundary.
            env["METACODES_KG_TRANSPORT"] = "cli-exclusive"
            env["METACODES_KG_BIN"] = str(tinykg_binary)
        try:
            completed = subprocess.run(
                [
                    str(binary),
                    "--api-key",
                    "sk-offline-runtime-arm-smoke",
                    "--dump-prompt",
                    "--no-theme",
                ],
                cwd=work,
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=20,
                check=False,
            )
        except subprocess.TimeoutExpired as exc:
            raise SystemExit(f"{arm}: --dump-prompt timed out") from exc
    if completed.returncode != 0:
        raise SystemExit(
            f"{arm}: --dump-prompt exited {completed.returncode}: "
            f"{completed.stderr[-1000:]}"
        )
    return completed.stdout


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--tinykg-binary", required=True, type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve()
    tinykg_binary = args.tinykg_binary.resolve()
    for label, path in (("metacodes", binary), ("TinyKG", tinykg_binary)):
        _require(path.is_file() and os.access(path, os.X_OK), f"{label} is not executable: {path}")

    dumps = {arm: _dump(binary, tinykg_binary, arm) for arm in ARMS}
    for arm, output in dumps.items():
        _require(TASK_TOOL_MARKER in output, f"{arm}: common TaskList tool is missing")

    codex = dumps["codex_style"]
    _require("# Memory" not in codex, "codex_style: Markdown memory leaked into prompt")
    _require("# Knowledge Graph" not in codex, "codex_style: TinyKG prompt leaked")
    _require(not any(marker in codex for marker in KG_TOOL_MARKERS), "codex_style: TinyKG tools leaked")
    _require(FORMAL_TOOL_MARKER not in codex, "codex_style: formal TinyKG audit tool leaked")
    _require(
        "TinyKG" not in codex and "kg-*" not in codex and "task_packet" not in codex,
        "codex_style: persistent task-DAG affordances leaked",
    )

    claude = dumps["claude_style"]
    _require("# Memory" in claude, "claude_style: Markdown memory prompt is missing")
    _require("# Knowledge Graph" not in claude, "claude_style: TinyKG prompt leaked")
    _require(not any(marker in claude for marker in KG_TOOL_MARKERS), "claude_style: TinyKG tools leaked")
    _require(FORMAL_TOOL_MARKER not in claude, "claude_style: formal TinyKG audit tool leaked")
    _require(
        "automatically imported into the knowledge graph" not in claude
        and "KgRemember" not in claude
        and "/kg sync" not in claude,
        "claude_style: Markdown-only instructions mention TinyKG",
    )
    _require(
        "TinyKG" not in claude and "kg-*" not in claude and "task_packet" not in claude,
        "claude_style: persistent task-DAG affordances leaked",
    )

    tinykg = dumps["tinykg"]
    _require("# Memory" in tinykg, "tinykg: Markdown memory prompt is missing")
    _require("# Knowledge Graph" in tinykg, "tinykg: knowledge-graph prompt is missing")
    _require(all(marker in tinykg for marker in KG_TOOL_MARKERS), "tinykg: KG tools are missing")
    _require(FORMAL_TOOL_MARKER in tinykg, "tinykg: formal TinyKG audit tool is missing")
    _require(
        "automatically imported into the knowledge graph" in tinykg,
        "tinykg: Markdown-to-graph projection contract is missing",
    )
    _require(
        "persistent task in TinyKG" in tinykg,
        "tinykg: TaskCreate still advertises session-only storage",
    )
    _headless_protocol_smoke(binary)
    _workbuddy_tool_policy_smoke(binary, tinykg_binary)
    print(
        "runtime arm smoke: codex_style/claude_style/tinykg + headless NDJSON "
        "permission + WorkBuddy provider-schema boundaries PASS "
        "(paid=0, external_network=0)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
