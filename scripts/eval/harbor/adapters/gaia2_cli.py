"""GAIA2 in Harbor's CLI mode (`gaia2-cli`), generated locally.

GAIA2 is in neither Harbor 0.26 registry (the legacy registry nor the Hub;
the only GAIA there is GAIA 1). Harbor's own adapter
(`adapters/gaia2/run_adapter.py --cli` in the Harbor source tree, tag
v0.26.0) writes 800 task directories, `gaia2-<config>-<row id>`, from the
public Hugging Face dataset `meta-agents-research-environments/gaia2`. Each
CLI-mode task runs the agent in `main` and the ARE environment in an
`are-sidecar` container that serves 101 MCP tools; the task declares that
server in `[[environment.mcp_servers]]`, and MetacodesAgent forwards it to
metacodes' `mcpServers` configuration. The verifier calls an LLM judge with
the execution host's `OPENAI_API_KEY` (`OPENAI_BASE_URL`, default
OpenRouter; `JUDGE_MODEL`, default openai/gpt-4o-mini).

`prepare` needs a Harbor source checkout (`METACODES_BENCH_HARBOR_SOURCE`)
and `uv`; it runs the adapter there with `--cli`. A copy already generated
elsewhere (for example harbor-datasets' `datasets/gaia2-cli`) can be
registered instead with `metacodes bench --dataset gaia2-cli=<dir>`.
"""
from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

SOURCE_ENV = "METACODES_BENCH_HARBOR_SOURCE"
JUDGE_KEY_ENV = "OPENAI_API_KEY"

SUITE = {
    "name": "GAIA2（CLI 模式）",
    "description": "Meta GAIA2 的 Harbor CLI 变体：800 个动态场景，agent 通过 MCP 侧车调用 ARE 环境工具；判分使用 LLM judge",
    "max_tasks": 100,
    "max_concurrency": 2,
}


def adapter_command(source: Path, dest: Path, uv: str = "uv"):
    """The Harbor adapter invocation; argv only, no shell."""
    return [uv, "run", "--project", str(source), "python",
            str(source / "adapters" / "gaia2" / "run_adapter.py"),
            "--cli", "--output-dir", str(dest), "--overwrite"]


def prepare(dest: Path) -> Path:
    source = os.environ.get(SOURCE_ENV)
    if not source or not (Path(source) / "adapters" / "gaia2" / "run_adapter.py").is_file():
        raise ValueError(f"请把 {SOURCE_ENV} 设为 Harbor 0.26 源码目录（含 adapters/gaia2/run_adapter.py）")
    uv = shutil.which("uv")
    if not uv:
        raise ValueError("生成 GAIA2 需要 uv")
    dest = Path(dest)
    dest.mkdir(parents=True, exist_ok=True)
    subprocess.run(adapter_command(Path(source).resolve(), dest.resolve(), uv),
                   cwd=str(Path(source).resolve()), check=True, stdin=subprocess.DEVNULL)
    return dest


def check(ctx):
    if not ctx.env.get(JUDGE_KEY_ENV):
        return [f"GAIA2 判分需要执行服务环境变量 {JUDGE_KEY_ENV}（LLM judge；OPENAI_BASE_URL 默认 OpenRouter），设置后重启服务"]
    return []
