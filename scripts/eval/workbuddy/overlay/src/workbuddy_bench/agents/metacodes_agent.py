"""WorkBuddy adapter for the metacodes headless CLI.

The real provider credential stays in WorkBuddy's host proxy.  The trial only
receives a non-secret route token, moves it into an inherited anonymous file
descriptor, clears the environment copy, and then starts metacodes.  Every run
gets a fresh HOME and an isolated local TinyKG store.
"""

from __future__ import annotations

import json
import shlex
from pathlib import Path

from harbor.agents.installed.base import BaseInstalledAgent
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext
from harbor.models.trajectories.agent import Agent
from harbor.models.trajectories.final_metrics import FinalMetrics
from harbor.models.trajectories.observation import Observation
from harbor.models.trajectories.observation_result import ObservationResult
from harbor.models.trajectories.step import Step
from harbor.models.trajectories.tool_call import ToolCall
from harbor.models.trajectories.trajectory import Trajectory

from workbuddy_bench.agents._agent_user import ensure_agent_user
from workbuddy_bench.agents._metacodes_trace import TraceError, load_trace_ir


_OUTPUT_FILENAME = "metacodes-output.jsonl"
_TRANSCRIPT_FILENAME = "metacodes-transcript.jsonl"
_DEFAULT_DISABLED_TOOLS = (
    "Agent,Task,TaskBatch,TeamCreate,TeamDelete,SendMessage"
)


class MetacodesAgent(BaseInstalledAgent):
    """Run a split-mounted metacodes artifact under WorkBuddy/Harbor."""

    SUPPORTS_ATIF: bool = True

    def __init__(self, logs_dir: Path, *args, **kwargs):
        version = kwargs.pop("METACODES_VERSION", None)
        self._mount_path = str(kwargs.pop("mount_path", None) or "/opt/metacodes")
        self._disabled_tools = str(
            kwargs.pop("METACODES_DISALLOWED_TOOLS", _DEFAULT_DISABLED_TOOLS)
        )
        model_params = kwargs.pop("model_params", None) or {}
        max_output = model_params.get("max_output_tokens")
        self._max_output_tokens = int(max_output) if max_output is not None else None
        self._model_params = dict(model_params)
        self._context_window = kwargs.pop("context_window", None)
        self._context_compact_pct = kwargs.pop("context_compact_pct", None)
        connection = kwargs.pop("connection", None) or {}
        self._conn_mode = str(connection.get("mode") or "")
        self._proxy_url = str(connection.get("proxy_url") or "")
        kwargs.pop("instance_id", None)
        self._session_id = self._trial_id_from_logs_dir(logs_dir)
        if self._conn_mode != "local_proxy":
            raise ValueError(
                "metacodes WorkBuddy runs are local-proxy-only: the host proxy must "
                "own the real provider credential, request audit, and retry policy"
            )
        if not self._proxy_url:
            raise ValueError("metacodes local_proxy connection is missing proxy_url")
        super().__init__(logs_dir, *args, version=version, **kwargs)

    @staticmethod
    def _trial_id_from_logs_dir(logs_dir: Path | None) -> str:
        try:
            path = Path(logs_dir)
        except TypeError:
            return ""
        return path.parent.name if path.name == "agent" else ""

    @staticmethod
    def name() -> str:
        return "metacodes"

    def get_version_command(self) -> str | None:
        return "metacodes --help >/dev/null && sha256sum /opt/metacodes/bin/metacodes"

    async def install(self, environment: BaseEnvironment) -> None:
        mount = shlex.quote(self._mount_path.rstrip("/"))
        await self.exec_as_root(
            environment,
            command=(
                "set -eu; "
                f"test -d {mount}; cd {mount}; "
                "test -f share/metacodes/SHA256SUMS; "
                "sha256sum -c share/metacodes/SHA256SUMS; "
                "test -x bin/metacodes; test -x bin/tinykg; "
                "test -x libexec/metacodes-formal-kernel; "
                "ln -sf \"$PWD/bin/metacodes\" /usr/local/bin/metacodes; "
                "ln -sf \"$PWD/bin/tinykg\" /usr/local/bin/tinykg"
            ),
        )
        await ensure_agent_user(self, environment)

    async def run(
        self, instruction: str, environment: BaseEnvironment, context: AgentContext
    ) -> None:
        instruction = self.render_instruction(instruction)
        escaped_instruction = shlex.quote(instruction)
        escaped_model = shlex.quote(self.model_name)
        escaped_proxy = self._proxy_url
        if "\n" in escaped_proxy or "\r" in escaped_proxy:
            raise ValueError("proxy_url contains a newline")

        route = self.model_name
        # The WorkBuddy proxy consumes this prefix for per-trial attribution,
        # then resolves the suffix against its registered route table.
        if self._session_id:
            route = f"{self._session_id}::{route}"
        env = {
            # Route authority only.  The real provider credential never crosses
            # the host proxy boundary.
            "METACODES_ROUTE_TOKEN": route,
            "METACODES_PROVIDER": "anthropic",
            "METACODES_BASE_URL": escaped_proxy,
            "METACODES_NO_PROBE": "1",
        }

        mount = self._mount_path.rstrip("/")
        output_path = f"/logs/agent/{_OUTPUT_FILENAME}"
        transcript_path = f"/logs/agent/{_TRANSCRIPT_FILENAME}"
        flags = [
            "--model", escaped_model,
            "--permission", "bypassPermissions",
            "--no-theme",
            "--disallowed-tools", shlex.quote(self._disabled_tools),
        ]
        if self._max_output_tokens is not None:
            flags += ["--max-tokens", str(self._max_output_tokens)]

        # Bash is intentional: WorkBuddy's installed-agent contract already
        # uses shell commands, and anonymous-FD handoff plus PIPESTATUS need a
        # real shell.  No credential value is interpolated into this command.
        command = (
            "set -uo pipefail; umask 077; "
            'run_home="/tmp/metacodes-workbuddy-home"; '
            'test ! -e "$run_home" || { echo "fresh HOME already exists" >&2; exit 70; }; '
            'mkdir -p "$run_home" || exit 70; export HOME="$run_home"; '
            f'export METACODES_KG_BIN={shlex.quote(mount + "/bin/tinykg")}; '
            'export METACODES_KG_STORE="$HOME/.local/share/tinykg/store"; '
            f'export METACODES_FORMAL_KERNEL_PATH={shlex.quote(mount + "/libexec/metacodes-formal-kernel")}; '
            'kernel_sha="$(sha256sum "$METACODES_FORMAL_KERNEL_PATH" | cut -d" " -f1)"; '
            'test "${#kernel_sha}" -eq 64 || exit 71; '
            'export METACODES_FORMAL_KERNEL_SHA256="$kernel_sha"; '
            "unset TINYKG_REMOTE_URL TINYKG_API_KEY TINYKG_REMOTE_EXPECTED_BUILD_ID "
            "TINYKG_REMOTE_CONFIG METASK_API_KEY; "
            'exec 9<<<"$METACODES_ROUTE_TOKEN"; unset METACODES_ROUTE_TOKEN; '
            "export METACODES_API_KEY_FD=9; "
            f"metacodes {' '.join(flags)} -p {escaped_instruction} --json "
            f"2>&1 </dev/null | tee {shlex.quote(output_path)}; "
            "agent_status=${PIPESTATUS[0]}; "
            'mapfile -t transcripts < <(find "$HOME/.metacodes/projects" '
            "-type f -name transcript.jsonl -print 2>/dev/null); "
            'test "${#transcripts[@]}" -eq 1 || { '
            'echo "expected one metacodes transcript, found ${#transcripts[@]}" >&2; '
            "exit 72; }; "
            f'cp -- "${{transcripts[0]}}" {shlex.quote(transcript_path)} || exit 73; '
            'chmod 0600 "${transcripts[0]}" '
            f"{shlex.quote(transcript_path)} {shlex.quote(output_path)} || exit 74; "
            'exit "$agent_status"'
        )
        await self.exec_as_agent(
            environment,
            command=command,
            env=env,
            cwd="/workspace",
        )

    def populate_context_post_run(self, context: AgentContext) -> None:
        try:
            trace = load_trace_ir(
                self.logs_dir / _OUTPUT_FILENAME,
                self.logs_dir / _TRANSCRIPT_FILENAME,
            )
            trajectory = self._build_trajectory(trace)
        except (OSError, TraceError, ValueError) as exc:
            raise RuntimeError(f"cannot build metacodes ATIF trajectory: {exc}") from exc

        trajectory_path = self.logs_dir / "trajectory.json"
        try:
            trajectory_path.write_text(
                json.dumps(
                    trajectory.to_json_dict(), indent=2, ensure_ascii=False
                ) + "\n",
                encoding="utf-8",
            )
        except OSError as exc:
            raise RuntimeError(f"cannot write metacodes trajectory: {exc}") from exc

        metrics = trajectory.final_metrics
        if metrics is not None:
            context.n_input_tokens = metrics.total_prompt_tokens or 0
            context.n_output_tokens = metrics.total_completion_tokens or 0
            context.n_cache_tokens = metrics.total_cached_tokens or 0
            if metrics.total_cost_usd is not None:
                context.cost_usd = metrics.total_cost_usd

    def _build_trajectory(self, trace: dict) -> Trajectory:
        steps = []
        for row in trace["steps"]:
            calls = [ToolCall(**call) for call in row["tool_calls"]] or None
            results = [ObservationResult(**item) for item in row["observations"]]
            observation = Observation(results=results) if results else None
            steps.append(
                Step(
                    step_id=row["step_id"],
                    source=row["source"],
                    model_name=self.model_name if row["source"] == "agent" else None,
                    message=row["message"],
                    reasoning_content=row["reasoning_content"],
                    tool_calls=calls,
                    observation=observation,
                    extra=row["extra"] or None,
                )
            )

        result = trace["result"]
        cache_read = int(result.get("cache_read_input_tokens") or 0)
        cache_creation = int(result.get("cache_creation_input_tokens") or 0)
        final_metrics = FinalMetrics(
            total_prompt_tokens=int(result["input_tokens"]),
            total_completion_tokens=int(result["output_tokens"]),
            total_cached_tokens=cache_read,
            total_cost_usd=float(result["cost_usd"]),
            total_steps=len(steps),
            extra={
                "metacodes_turns": int(result["turns"]),
                "metacodes_tool_calls": int(result["tool_calls"]),
                "metacodes_stop_reason": result["stop_reason"],
                "cache_creation_input_tokens": cache_creation,
                "requested_context_window": self._context_window,
                "requested_context_compact_pct": self._context_compact_pct,
                "model_params_via_host_proxy": self._model_params,
            },
        )
        return Trajectory(
            session_id=self._session_id or None,
            agent=Agent(
                name="metacodes",
                version=self._version or "unknown",
                model_name=self.model_name,
            ),
            steps=steps,
            final_metrics=final_metrics,
            notes=(
                "Tool results are attached as ATIF observations to the owning "
                "metacodes tool-call step. The WorkBuddy host proxy owns the real "
                "provider credential; the container receives only a route token."
            ),
        )
