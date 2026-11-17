"""Harbor installed-agent adapter for the metacodes CLI.

Load it with ``harbor run --agent-import-path
scripts.eval.harbor.metacodes_agent:MetacodesAgent`` from the repository root
(``PYTHONPATH=.``); README.md in this directory has the full command.

One trial:

1. ``install`` uploads a Linux release-layout bundle (``bin/metacodes``,
   TinyKG, ripgrep, both Lean kernels) to ``/opt/metacodes`` and checks that
   ``metacodes --version --json`` runs there, so a glibc the task image lacks
   fails at install, not as a silent zero-reward trial.
2. ``run`` uploads the instruction and runs metacodes headless with its own
   ``--state-dir``; see ``command.run_command`` for the script.
3. ``populate_context_post_run`` turns the NDJSON output and the session
   transcript into an ATIF trajectory and fills Harbor's token and cost
   counters.

Credentials are not handled here: pass the provider key with Harbor's
``--ae NAME=value`` (e.g. ``--ae DEEPSEEK_API_KEY=$DEEPSEEK_API_KEY``), which
Harbor forwards to the agent's commands and redacts from its logs.
"""

from __future__ import annotations

import hashlib
import json
import os
import shlex
import tempfile
import uuid
from pathlib import Path
from typing import Any, Optional

from harbor.agents.capabilities import AgentCapabilities
from harbor.agents.installed.base import BaseInstalledAgent, with_prompt_template
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext
from harbor.models.trajectories import (
    Agent,
    FinalMetrics,
    Observation,
    ObservationResult,
    Step,
    ToolCall,
    Trajectory,
)

from scripts.eval.harbor import command as cmd

# Set instead of `--ak bundle=...` when every trial of a job uses one bundle.
BUNDLE_ENV = "METACODES_HARBOR_BUNDLE"


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


class MetacodesAgent(BaseInstalledAgent):
    """Run a metacodes Linux release bundle as a Harbor installed agent."""

    capabilities = AgentCapabilities(atif=True, native_config=True)

    def __init__(
        self,
        logs_dir: Path,
        *args: Any,
        bundle: Optional[str] = None,
        reasoning_effort: Optional[str] = None,
        max_tokens: Optional[Any] = None,
        disallowed_tools: Optional[str] = None,
        **kwargs: Any,
    ):
        bundle_path = bundle or os.environ.get(BUNDLE_ENV)
        if not bundle_path:
            raise ValueError(
                "metacodes needs a Linux release bundle: pass --ak bundle=<dir> "
                f"or set {BUNDLE_ENV}"
            )
        self._bundle = Path(bundle_path).expanduser().resolve()
        manifest = cmd.check_bundle(self._bundle)
        self._bundle_version = str(manifest.get("version") or "")
        self._binary_sha256 = _sha256(self._bundle / "bin" / "metacodes")
        self._reasoning_effort = reasoning_effort
        self._max_tokens = int(max_tokens) if max_tokens is not None else None
        self._disallowed_tools = (
            cmd.DEFAULT_DISALLOWED_TOOLS
            if disallowed_tools is None
            else str(disallowed_tools)
        )
        super().__init__(logs_dir, *args, **kwargs)
        # Validate the model and flags now: a bad value fails the job before
        # any container starts.
        self._provider, self._model = cmd.split_model(self.model_name)
        self._flags = cmd.metacodes_flags(
            provider=self._provider,
            model=self._model,
            disallowed_tools=self._disallowed_tools,
            reasoning_effort=self._reasoning_effort,
            max_tokens=self._max_tokens,
        )

    @staticmethod
    def name() -> str:
        return "metacodes"

    def get_version_command(self) -> Optional[str]:
        return f"{shlex.quote(cmd.REMOTE_BINARY)} --version --json"

    def parse_version(self, stdout: str) -> str:
        for line in reversed(stdout.strip().splitlines()):
            try:
                document = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(document, dict) and isinstance(document.get("version"), str):
                return document["version"]
        return stdout.strip()

    async def install(self, environment: BaseEnvironment) -> None:
        remote = shlex.quote(cmd.REMOTE_BUNDLE)
        await self.exec_as_root(environment, command=f"rm -rf {remote} && mkdir -p {remote}")
        await environment.upload_dir(self._bundle, cmd.REMOTE_BUNDLE)
        executables = " ".join(
            shlex.quote(f"{cmd.REMOTE_BUNDLE}/{rel}") for rel in cmd.BUNDLE_EXECUTABLES
        )
        binary = shlex.quote(cmd.REMOTE_BINARY)
        await self.exec_as_root(
            environment,
            command=(
                f"chmod -R a+rX {remote} && chmod 0755 {executables} && "
                f'test "$(sha256sum {binary} | cut -d" " -f1)" = {self._binary_sha256}'
            ),
        )
        # Fails here, with metacodes' own loader message, when the task image's
        # glibc is older than the bundle needs.
        result = await self.exec_as_agent(environment, command=self.get_version_command())
        self._version = self.parse_version(result.stdout or "") or self._bundle_version
        await self._ensure_ca_bundle(environment)

    async def _ensure_ca_bundle(self, environment: BaseEnvironment) -> None:
        """Install the system CA bundle when the image has none.

        Without one every provider request fails with TlsInitializationFailed;
        agents installed with curl get the same package as a dependency.
        """
        check = await environment.exec(command=cmd.ca_bundle_check(), user="root")
        if check.return_code == 0:
            return
        manager = await self._get_system_package_manager(environment)
        install = cmd.CA_PACKAGE_INSTALL.get(manager or "")
        if install is None:
            raise RuntimeError(
                "the task image has no CA bundle metacodes can read and no "
                "supported package manager to install one"
            )
        await self.exec_as_root(environment, command=f"{install} && ({cmd.ca_bundle_check()})")

    @with_prompt_template
    async def run(
        self,
        instruction: str,
        environment: BaseEnvironment,
        context: AgentContext,
    ) -> None:
        trial = uuid.uuid4().hex
        remote_instruction = f"/tmp/metacodes-instruction-{trial}.md"
        remote_config: Optional[str] = None
        with tempfile.TemporaryDirectory(prefix="metacodes-harbor-") as scratch:
            local_instruction = Path(scratch) / "instruction.md"
            local_instruction.write_text(instruction, encoding="utf-8")
            await environment.upload_file(local_instruction, remote_instruction)
            config = self.config_source
            if config is not None:
                local_config = Path(scratch) / "config.json"
                if isinstance(config, dict):
                    local_config.write_text(json.dumps(config), encoding="utf-8")
                else:
                    local_config.write_bytes(Path(config).read_bytes())
                remote_config = f"/tmp/metacodes-config-{trial}.json"
                await environment.upload_file(local_config, remote_config)
        readable = [remote_instruction] + ([remote_config] if remote_config else [])
        await self.exec_as_root(
            environment,
            command=f"chmod 0444 {' '.join(shlex.quote(p) for p in readable)}",
        )
        script = cmd.run_command(
            state_dir=f"/tmp/metacodes-state-{trial}",
            instruction_path=remote_instruction,
            flags=self._flags,
            config_path=remote_config,
        )
        await self.exec_as_agent(environment, command=f"bash -c {shlex.quote(script)}")

    def populate_context_post_run(self, context: AgentContext) -> None:
        trace = cmd.load_trace(self.logs_dir)
        trajectory = self._trajectory(trace)
        (self.logs_dir / "trajectory.json").write_text(
            json.dumps(trajectory.to_json_dict(), indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        metrics = trajectory.final_metrics
        context.n_input_tokens = metrics.total_prompt_tokens or 0
        context.n_output_tokens = metrics.total_completion_tokens or 0
        context.n_cache_tokens = metrics.total_cached_tokens or 0
        context.cost_usd = metrics.total_cost_usd

    def _trajectory(self, trace: dict) -> Trajectory:
        steps = []
        for row in trace["steps"]:
            calls = [ToolCall(**call) for call in row["tool_calls"]] or None
            results = [ObservationResult(**item) for item in row["observations"]]
            steps.append(
                Step(
                    step_id=row["step_id"],
                    source=row["source"],
                    model_name=self.model_name if row["source"] == "agent" else None,
                    message=row["message"],
                    reasoning_content=row["reasoning_content"],
                    tool_calls=calls,
                    observation=Observation(results=results) if results else None,
                    extra=row["extra"] or None,
                )
            )
        fields = cmd.final_metrics_fields(trace["result"])
        return Trajectory(
            session_id=self.logs_dir.parent.name or None,
            agent=Agent(
                name=self.name(),
                version=self._version or self._bundle_version or "unknown",
                model_name=self.model_name,
            ),
            steps=steps,
            final_metrics=FinalMetrics(total_steps=len(steps), **fields),
        )
