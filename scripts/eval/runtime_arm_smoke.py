#!/usr/bin/env python3
"""Zero-network smoke for the real long-horizon runtime treatment wiring."""

from __future__ import annotations

import argparse
import os
import subprocess
import tempfile
from pathlib import Path
from typing import Dict


ARMS = ("codex_style", "claude_style", "tinykg")
KG_TOOL_MARKERS = ("\n----- KgRemember -----\n", "\n----- KgRecall -----\n")
TASK_TOOL_MARKER = "\n----- TaskList -----\n"


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
    _require(
        "TinyKG" not in codex and "kg-*" not in codex and "task_packet" not in codex,
        "codex_style: persistent task-DAG affordances leaked",
    )

    claude = dumps["claude_style"]
    _require("# Memory" in claude, "claude_style: Markdown memory prompt is missing")
    _require("# Knowledge Graph" not in claude, "claude_style: TinyKG prompt leaked")
    _require(not any(marker in claude for marker in KG_TOOL_MARKERS), "claude_style: TinyKG tools leaked")
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
    _require(
        "automatically imported into the knowledge graph" in tinykg,
        "tinykg: Markdown-to-graph projection contract is missing",
    )
    _require(
        "persistent task in TinyKG" in tinykg,
        "tinykg: TaskCreate still advertises session-only storage",
    )
    print("runtime arm smoke: codex_style/claude_style/tinykg PASS (paid=0, network=0)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
