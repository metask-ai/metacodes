"""WorkBuddy adapter for the metacodes headless CLI.

The real provider credential stays in WorkBuddy's host proxy.  The trial only
receives a non-secret route token, moves it into an inherited anonymous file
descriptor, clears the environment copy, and then starts metacodes.  Every run
gets a fresh HOME and an isolated local TinyKG store.
"""

from __future__ import annotations

import hashlib
import json
import os
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
from workbuddy_bench.agents._metacodes_trace import (
    OBSERVATION_FILENAME,
    TraceError,
    anthropic_messages_endpoint,
    load_control_metrics,
    load_trace_ir,
    project_state_hash,
)


_OUTPUT_FILENAME = "metacodes-output.jsonl"
_TRANSCRIPT_FILENAME = "metacodes-transcript.jsonl"
_RUNTIME_CONTRACT_FILENAME = "metacodes-runtime-contract.json"
_DEFAULT_DISABLED_TOOLS = (
    "Agent,Task,TaskBatch,TeamCreate,TeamDelete,SendMessage,"
    "EnterPlanMode,ExitPlanMode"
)
_PROJECT_CONTROL_MODES = {"disabled", "enforced"}
_REMOTE_TINYKG_ENV = (
    "TINYKG_REMOTE_URL",
    "TINYKG_API_KEY",
    "TINYKG_REMOTE_EXPECTED_BUILD_ID",
    "TINYKG_REMOTE_CONFIG",
    "METACODES_KG_CONFIG",
    "METACODES_KG_URL",
    "METACODES_KG_API_KEY",
    "METACODES_KG_EXPECTED_BUILD_ID",
    "METACODES_KG_EXPECTED_SCHEMA_DIGEST",
    "METASK_API_KEY",
)


def _relative_mount_path(value: object, label: str) -> str:
    raw = str(value or "")
    path = Path(raw)
    if not raw or path.is_absolute() or ".." in path.parts or "." in path.parts:
        raise ValueError(f"{label} must be a normalized relative mount path")
    return path.as_posix()


_CONTINUITY_DIRNAME = "kg-store-continuity"
_CONTINUITY_TAR = "store-latest.tar"
_CONTINUITY_LEDGER = "ledger.jsonl"
# The store accumulates over at most a 16-task arm; a bound far above any
# observed store keeps a runaway artifact from silently monopolizing the
# transfer channel.  Fail loud, never truncate.
_MAX_CONTINUITY_TAR_BYTES = 64 * 1024 * 1024



def _fresh_run_home(logs_dir: Path, step_key: str = "") -> str:
    """Return the deterministic private HOME for one WorkBuddy step.

    In multi-step tasks harbor reuses the SAME agent object and logs_dir for
    every step (per-step outputs are archived under steps/<name>/ only AFTER
    the step finishes), so logs_dir alone does not distinguish step 1 from
    step 2 and the shared HOME would trip the fresh-HOME guard on step 2+.
    The rendered instruction differs per step, so it is folded in to make the
    path unique per step while staying deterministic for a given step.
    """

    step_hash = hashlib.sha256(
        (str(logs_dir) + "\x00" + step_key).encode("utf-8")
    ).hexdigest()
    return f"/tmp/metacodes-workbuddy-home-{step_hash}"

def _continuity_root(logs_dir: Path) -> Path:
    """Arm-level store home: <jobs_dir>/kg-store-continuity.

    Trial layout is <jobs_dir>/<batch>/<trial>/agent; the jobs_dir is the
    per-arm root, so one serial arm shares exactly one ledger.
    """

    return logs_dir.resolve().parents[2] / _CONTINUITY_DIRNAME


def _verifier_reasons(trial_dir: Path) -> dict:
    """JUnit results.xml -> {(Class, test_name): (kind, message)}.

    The verifier has been shipping per-test skip/failure REASONS in
    results.xml since day one; only the names were extracted.  Reasons are
    the same artifact class as names (one report, one channel), and for
    location-sensitive tasks the skip message routinely states exactly which
    artifact the suite could not import — signal the bare name cannot carry.
    Mechanical, task-agnostic extraction; empty dict on any parse trouble.
    """
    import xml.etree.ElementTree as ET

    reasons: dict = {}
    try:
        root = ET.parse(trial_dir / "verifier" / "results.xml").getroot()
    except Exception:
        return reasons
    for case in root.iter("testcase"):
        classname = str(case.get("classname") or "")
        name = str(case.get("name") or "")
        if not name:
            continue
        verdict = None
        for kind in ("skipped", "failure", "error"):
            child = case.find(kind)
            if child is not None:
                label = "skipped" if kind == "skipped" else "failed"
                msg = str(child.get("message") or "")
                # p26 取证:裸错误消息方向模糊("buffer API required"被因果
                # 倒置成"path 签名导致")。pytest longrepr 的 '>' 标记行 =
                # 失败语句原文(测试侧调用现场),方向零歧义,机械附加。
                body = child.text or ""
                callsite = ""
                for line in body.splitlines():
                    stripped = line.strip()
                    if stripped.startswith(">"):
                        callsite = stripped.lstrip("> ").strip()
                if callsite:
                    msg = f"{msg[:90]} AT test code: {callsite[:80]}"
                verdict = (label, msg)
                break
        if verdict is None:
            continue
        cls = classname.rpartition(".")[2]
        reasons.setdefault((cls, name), verdict)
        reasons.setdefault(("", name), verdict)
    return reasons


def _annotate_failing(name: str, reasons: dict) -> str:
    """Append the verifier's own reason to a failing/skipped test name.

    `name` may already carry a bare " (skipped)" marker; the reason replaces
    it.  Brackets are stripped from the message because the outcome row's
    failing=[...] section is bracket-delimited downstream.
    """
    bare = name.split(" (")[0].strip()
    parts = bare.split("::")
    key = (parts[-2] if len(parts) >= 3 else "", parts[-1] if parts else "")
    hit = reasons.get(key) or reasons.get(("", key[1]))
    if not hit:
        return name
    kind, msg = hit
    # 列表定界完整性:失败行以 ", " 连接、下游以 ", " 分割,消息里的逗号
    # 会把条目劈碎产生垃圾针 → 逗号换分号;方括号换圆括号(failing=[...]
    # 括号定界)。
    # 200 帽:AT 子句(≈90 消息 + 16 前缀 + 80 现场)在 120 帽下被截没
    # (p28 取证:6 条 TypeError 只有 1 条保住方向线索)。
    msg = " ".join(
        msg.replace("[", "(").replace("]", ")").replace(",", ";").split()
    )[:200].strip()
    if not msg:
        return name
    if name.endswith(" (skipped)") and kind != "skipped":
        kind = "skipped"
    return f"{bare} ({kind}: {msg})"[:280]


def _best_artifact(trial_dir: Path) -> str:
    """Best attempt's newly created non-test files, verbatim from agent.patch.

    Copy-and-patch beats re-derivation: across p18-p23 the model re-derived
    the implementation every round and never integrated more than one
    correction at a time.  Quoting the best attempt's actual artifact removes
    the degrees of freedom where its priors (async, full-hash) re-enter.
    Mechanical and task-agnostic; 1600-byte cap, at most two files.
    """
    try:
        patch = (trial_dir / "verifier" / "agent.patch").read_text(
            encoding="utf-8", errors="replace"
        )
    except OSError:
        return ""
    # v43 多文件工件(p32etag 取证:1.0 方案 = 新建模块 + 既有文件的接线
    # hunks,旧通道只取 new-file → 接线整个丢失 → 声明 1.0 的重放永远
    # 5/11,且 v35 静默拒载全部压力针 → 平台自锁)。新建文件递送全文
    # (逐字重放),修改型文件递送 unified-diff hunks(段头标注 apply-diff,
    # 消费端切换 diff 语义指令);新建段在前;总帽 4096、至多 4 文件。
    new_pieces = []
    mod_pieces = []
    for chunk in patch.split("diff --git ")[1:]:
        header = chunk.splitlines()[0]
        path = header.split(" b/")[-1].strip()
        if path.startswith("tests/"):
            continue
        if "\nnew file mode" in chunk:
            added = [
                line[1:]
                for line in chunk.splitlines()
                if line.startswith("+") and not line.startswith("+++")
            ]
            body = "\n".join(added)
            if body.strip():
                new_pieces.append((f"--- {path} ---", body))
        else:
            lines = chunk.splitlines()
            first_hunk = next(
                (i for i, line in enumerate(lines) if line.startswith("@@")), None
            )
            if first_hunk is None:
                continue
            body = "\n".join(lines[first_hunk:])
            if body.strip():
                mod_pieces.append((f"--- {path} (apply-diff) ---", body))
    pieces = []
    total = 0
    for tag, body in new_pieces + mod_pieces:
        if len(pieces) >= 4 or total >= 4096:
            break
        content = body[: 4096 - total]
        if not content.strip():
            continue
        # 截断必须显式标注:被截半的文件配上"逐字写入"指令是毒药
        # (review 抓出;etag 工件 ~25 行从未触发=侥幸)。
        if len(content) < len(body):
            content += "\n(HOST-TRUNCATED: file exceeds quota, do NOT copy verbatim)"
        pieces.append(f"{tag}\n{content}")
        total += len(content)
    return "\n".join(pieces)


def _advance_continuity_chain(
    logs_dir: Path,
    continuity_root: Path,
    session_id: str,
    store_import_sha: "str | None",
) -> None:
    """v42 导出门 host 侧:只有通过容器内深探针的导出才推进
    `store-latest.tar`。

    p41 取证:trial 1 的 GC 删除把店写进引擎读不回的状态,无门导出把毒店
    推进链头,整臂 + 后代 trial 的记忆系统静默死亡。探针结果由容器内
    `kg-export-probe.rc` 携带;rc 缺失/不可读按失败处理(fail-closed)。
    探针不过时写降级账本行:`export_sha256` 保持上一个好 tar 的 sha(链
    校验语义 = 本 trial 未推进,下一 trial 的导入见证仍对得上保留的
    tar),被拒导出的 sha 记进 `rejected_export_sha256` 供取证。
    """
    export_host = logs_dir / "kg-export.tar"
    if not export_host.is_file():
        raise ValueError(
            "kg store continuity export did not appear on the log mount"
        )
    exported = export_host.read_bytes()
    if len(exported) > _MAX_CONTINUITY_TAR_BYTES:
        raise ValueError("kg store continuity export exceeds its bound")
    export_sha = hashlib.sha256(exported).hexdigest()
    ledger_path = continuity_root / _CONTINUITY_LEDGER
    try:
        probe_rc = int(
            (logs_dir / "kg-export-probe.rc").read_text(encoding="utf-8").strip()
            or "1"
        )
    except (OSError, ValueError):
        probe_rc = 1
    if probe_rc == 0:
        staging = continuity_root / f".export-{session_id}.tar"
        staging.write_bytes(exported)
        row = {
            "trial": session_id,
            "import_sha256": store_import_sha or "empty",
            "export_sha256": export_sha,
            "bytes": len(exported),
        }
        with open(ledger_path, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(row, sort_keys=True) + "\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(staging, continuity_root / _CONTINUITY_TAR)
        return
    prev_rows = _read_continuity_ledger(ledger_path)
    prev_sha = prev_rows[-1].get("export_sha256") if prev_rows else None
    row = {
        "trial": session_id,
        "import_sha256": store_import_sha or "empty",
        "export_sha256": prev_sha or "empty",
        "bytes": len(exported),
        "degraded": True,
        "export_probe_rc": probe_rc,
        "rejected_export_sha256": export_sha,
    }
    with open(ledger_path, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(row, sort_keys=True) + "\n")
        handle.flush()
        os.fsync(handle.fileno())
    print(
        "metacodes adapter: kg export failed the integrity probe "
        f"(rc={probe_rc}); continuity chain NOT advanced, previous good "
        "store retained",
        flush=True,
    )


def _read_continuity_ledger(path: Path) -> list:
    if not path.exists():
        return []
    rows = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.strip():
            rows.append(json.loads(line))
    return rows


_PROXY_PROVIDER_ID = "workbuddy-proxy"


def _proxy_provider_config(proxy_url: str, model_name: str) -> str:
    """User-defined provider document that routes the actor at the job proxy.

    ``custom_providers`` in ``~/.metacodes/config.json`` goes through the same
    registry validation as a built-in profile.  The only difference from the
    ``anthropic`` profile is the endpoint policy, which names the plaintext
    hop to the audited WorkBuddy host proxy explicitly instead of relying on
    the loopback exemption; the channel base URL is the proxy root and the
    anthropic_messages wire appends ``/v1/messages``.
    """
    root = str(proxy_url or "").strip().rstrip("/")
    if not root.startswith(("http://", "https://")):
        raise ValueError("metacodes local_proxy connection has no http(s) proxy_url")
    if "@" in root.split("//", 1)[1].split("/", 1)[0]:
        raise ValueError("metacodes local_proxy proxy_url must not carry userinfo")
    document = {
        "schema_version": 1,
        "custom_providers": {
            _PROXY_PROVIDER_ID: {
                "display_name": "WorkBuddy job proxy",
                "auth": {"kind": "api_key_header", "header": "x-api-key"},
                "env_aliases": [
                    {"name": "METACODES_ROUTE_TOKEN", "kind": "api_key", "canonical": True}
                ],
                "endpoint_policy": {"require_tls": False},
                "channels": [
                    {"id": "proxy", "base_url": root, "protocol": "anthropic_messages"}
                ],
                "models": [{"request_model_id": model_name}],
            }
        },
    }
    return json.dumps(document, sort_keys=True, separators=(",", ":"))


class MetacodesAgent(BaseInstalledAgent):
    """Run a split-mounted metacodes artifact under WorkBuddy/Harbor."""

    SUPPORTS_ATIF: bool = True

    def __init__(self, logs_dir: Path, *args, **kwargs):
        version = kwargs.pop("METACODES_VERSION", None)
        self._mount_path = str(kwargs.pop("mount_path", None) or "/opt/metacodes")
        self._disabled_tools = str(
            kwargs.pop("METACODES_DISALLOWED_TOOLS", _DEFAULT_DISABLED_TOOLS)
        )
        verification_checkpoint = kwargs.pop(
            "METACODES_VERIFICATION_CHECKPOINT", False
        )
        if not isinstance(verification_checkpoint, bool):
            raise ValueError(
                "METACODES_VERIFICATION_CHECKPOINT must be an explicit boolean"
            )
        self._verification_checkpoint = verification_checkpoint
        final_gate = kwargs.pop("METACODES_VERIFICATION_FINAL_GATE", False)
        final_observe = kwargs.pop("METACODES_VERIFICATION_FINAL_OBSERVE", False)
        if not isinstance(final_gate, bool) or not isinstance(final_observe, bool):
            raise ValueError(
                "METACODES_VERIFICATION_FINAL_GATE/OBSERVE must be explicit booleans"
            )
        if final_gate and final_observe:
            raise ValueError(
                "verification final gate and observe modes are mutually exclusive"
            )
        self._verification_final_gate = final_gate
        self._verification_final_observe = final_observe
        ledger = kwargs.pop("METACODES_REQUIREMENT_LEDGER", False)
        ledger_observe = kwargs.pop("METACODES_REQUIREMENT_LEDGER_OBSERVE", False)
        if not isinstance(ledger, bool) or not isinstance(ledger_observe, bool):
            raise ValueError(
                "METACODES_REQUIREMENT_LEDGER/OBSERVE must be explicit booleans"
            )
        if ledger and ledger_observe:
            raise ValueError(
                "requirement ledger enforce and observe modes are mutually exclusive"
            )
        self._requirement_ledger = ledger
        self._requirement_ledger_observe = ledger_observe
        memory_accumulation = kwargs.pop("METACODES_MEMORY_ACCUMULATION", False)
        if not isinstance(memory_accumulation, bool):
            raise ValueError(
                "METACODES_MEMORY_ACCUMULATION must be an explicit boolean"
            )
        self._memory_accumulation = memory_accumulation
        self_evolution = kwargs.pop("METACODES_SELF_EVOLUTION", False)
        if not isinstance(self_evolution, bool):
            raise ValueError(
                "METACODES_SELF_EVOLUTION must be an explicit boolean"
            )
        if self_evolution and not memory_accumulation:
            raise ValueError(
                "self evolution requires memory accumulation: provisional "
                "rules ride the store continuity chain"
            )
        self._self_evolution = self_evolution
        outcome_feedback = kwargs.pop("METACODES_OUTCOME_FEEDBACK", False)
        if not isinstance(outcome_feedback, bool):
            raise ValueError(
                "METACODES_OUTCOME_FEEDBACK must be an explicit boolean"
            )
        if outcome_feedback and not memory_accumulation:
            raise ValueError(
                "outcome feedback requires memory accumulation: outcome "
                "nodes ride the store continuity chain"
            )
        if outcome_feedback and not self_evolution:
            raise ValueError(
                "outcome feedback requires self evolution: ingestion runs "
                "inside the self-evolution runtime gate"
            )
        self._outcome_feedback = outcome_feedback
        outcome_roots = kwargs.pop("METACODES_OUTCOME_ROOTS", None)
        if outcome_roots is not None and (
            not isinstance(outcome_roots, list)
            or any(not isinstance(row, str) or not row for row in outcome_roots)
        ):
            raise ValueError(
                "METACODES_OUTCOME_ROOTS must be a list of directory paths"
            )
        self._outcome_roots = list(outcome_roots or [])
        continuity_seed = kwargs.pop("METACODES_CONTINUITY_SEED_SHA256", None)
        if continuity_seed is not None and (
            not isinstance(continuity_seed, str)
            or len(continuity_seed) != 64
            or any(c not in "0123456789abcdef" for c in continuity_seed)
        ):
            raise ValueError(
                "METACODES_CONTINUITY_SEED_SHA256 must be a 64-hex sha or null"
            )
        if continuity_seed is not None and not memory_accumulation:
            raise ValueError(
                "a continuity seed requires memory accumulation"
            )
        self._continuity_seed_sha256 = continuity_seed
        project_rules = kwargs.pop("METACODES_PROJECT_RULES_RELATIVE", None)
        project_kernel = kwargs.pop("METACODES_PROJECT_KERNEL_RELATIVE", None)
        project_control_mode = kwargs.pop("METACODES_PROJECT_CONTROL_MODE", None)
        if (project_rules is None) != (project_kernel is None):
            raise ValueError(
                "metacodes project rules and project kernel must be configured together"
            )
        if project_rules is None:
            if project_control_mode is not None:
                raise ValueError(
                    "metacodes project control mode requires staged rules and kernel"
                )
            project_control_mode = "absent"
        elif project_control_mode not in _PROJECT_CONTROL_MODES:
            raise ValueError(
                "metacodes staged project control requires explicit disabled/enforced mode"
            )
        self._project_control_mode = str(project_control_mode)
        if self._self_evolution and self._project_control_mode != "enforced":
            raise ValueError(
                "self evolution requires enforced project control: the fixed "
                "kernel identity comes from the staged bundle environment"
            )
        self._project_rules_relative = (
            _relative_mount_path(project_rules, "project rules")
            if project_rules is not None
            else None
        )
        self._project_kernel_relative = (
            _relative_mount_path(project_kernel, "project kernel")
            if project_kernel is not None
            else None
        )
        model_params = kwargs.pop("model_params", None) or {}
        model_display_name = str(kwargs.pop("METACODES_MODEL_DISPLAY_NAME", ""))
        if not model_display_name:
            raise ValueError(
                "metacodes WorkBuddy runs require a stable backend model identity"
            )
        self._model_display_name = model_display_name
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
        project_check = ""
        if self._project_kernel_relative is not None and self._project_rules_relative is not None:
            project_check = (
                f"; test -x {shlex.quote(self._mount_path.rstrip('/') + '/' + self._project_kernel_relative)}"
                f"; test -f {shlex.quote(self._mount_path.rstrip('/') + '/' + self._project_rules_relative + '/active.json')}"
            )
        await self.exec_as_root(
            environment,
            command=(
                "set -eu; "
                f"test -d {mount}; cd {mount}; "
                "test -f share/metacodes/SHA256SUMS; "
                "sha256sum -c share/metacodes/SHA256SUMS; "
                "test -x bin/metacodes; test -x bin/tinykg; test -x bin/rg; "
                "test -x libexec/metacodes-formal-kernel"
                f"{project_check}; "
                "ln -sf \"$PWD/bin/metacodes\" /usr/local/bin/metacodes; "
                "ln -sf \"$PWD/bin/tinykg\" /usr/local/bin/tinykg"
            ),
        )
        await ensure_agent_user(self, environment)
        run_user = getattr(environment, "default_user", None)
        task_workdir = getattr(
            getattr(environment, "task_env_config", None), "workdir", None
        )
        if run_user not in (None, "", "root", 0, "0"):
            escaped_user = shlex.quote(str(run_user))
            escaped_workdir = shlex.quote(str(task_workdir)) if task_workdir else '""'
            # Repair only the task workdir.  The explicit protected-path cases
            # keep a malformed task declaration from making verifier/grading
            # state writable; the command is best effort by design.
            await self.exec_as_root(
                environment,
                command=(
                    f"(target={escaped_workdir}; "
                    'if [ -z "$target" ]; then target="$(pwd)"; fi; '
                    "case \"$target\" in "
                    "/|//|//*|/tests|/tests/*|/logs/verifier|/logs/verifier/*|"
                    "*/verifier|*/verifier/*|*/grading|*/grading/*) ;; "
                    "*/..|*/../*|*/.|*/./*) ;; "
                    '/*) if [ -d "$target" ] && [ ! -L "$target" ]; then '
                    f"chown {escaped_user} \"$target\" && chmod u+rwx \"$target\"; "
                    "fi ;; esac) || true"
                ),
                # A configured workdir may be absent.  Run from / so that the
                # fail-soft repair cannot fail before its guarded body runs.
                cwd="/" if task_workdir else None,
            )
            # Sec-style audit tasks instruct the agent to write its report
            # beside the audited source (e.g. /app/report.jsonl) while the
            # image owns that directory as root:root 755 and the rollout runs
            # as the non-root agent user.  Without this grant the agent's
            # report silently never reaches the verifier's path.  Grant the
            # directory itself only — never recurse, so task source files
            # keep their original ownership for the verifier's diff checks.
            # Best effort: tasks without /app (or with it already writable)
            # are unaffected.
            await self.exec_as_root(
                environment,
                command=(
                    "if [ -d /app ] && [ ! -L /app ]; then "
                    f"chown {escaped_user} /app && chmod u+rwx /app; "
                    "fi"
                ),
                cwd="/",
            )

    def _collect_outcomes(self):
        """已完成 trial 的 verifier 结局(本 run 的兄弟 trial + 声明的
        额外根,如 pass 1 的 jobs_dir)。有界、只读、失败静默。"""
        rows = []
        roots = [str(_continuity_root(self.logs_dir).parent)]
        roots.extend(self._outcome_roots)
        seen = set()
        if len(roots) > 8:
            print(f"metacodes adapter: truncating outcome roots {len(roots)} -> 8", flush=True)
        for root in roots[:8]:
            root_path = Path(root)
            if not root_path.is_dir():
                continue
            for result_path in sorted(root_path.glob("*/*/result.json"))[:128]:
                if len(rows) >= 64:
                    return rows
                trial_dir = result_path.parent
                try:
                    result = json.loads(result_path.read_text(encoding="utf-8"))
                except (OSError, json.JSONDecodeError):
                    continue
                task = str(result.get("task_name") or "").rpartition("/")[2]
                if not task or result.get("exception_info") is not None:
                    continue
                score_path = trial_dir / "verifier" / "score.json"
                try:
                    score = json.loads(score_path.read_text(encoding="utf-8"))
                except (OSError, json.JSONDecodeError):
                    continue
                reward = score.get("reward")
                if not isinstance(reward, (int, float)):
                    continue
                attempt_key = trial_dir.name[-24:]
                dedupe = f"{task}#{attempt_key}"
                if dedupe in seen:
                    continue
                seen.add(dedupe)
                failing = []
                # 结构化优先:WorkBuddy 自定义 verifier 把逐测名字放在
                # judges[].metadata.raw.tests[](两遍法取证:pytest FAILED 行
                # 只覆盖 1/16 任务,其余 15 题错题名全丢)。pytest 行回退。
                structured = None
                for judge in score.get("judges") or []:
                    raw_meta = (judge.get("metadata") or {}).get("raw") or {}
                    if isinstance(raw_meta.get("tests"), list):
                        structured = raw_meta["tests"]
                        break
                reasons = _verifier_reasons(trial_dir)
                if structured is not None:
                    for test in structured:
                        if isinstance(test, dict) and test.get("passed") is False:
                            name = str(test.get("name") or "")[:160]
                            if name:
                                failing.append(_annotate_failing(name, reasons))
                        if len(failing) >= 20:
                            break
                else:
                    try:
                        for line in (trial_dir / "verifier" / "test_output.txt").read_text(
                            encoding="utf-8", errors="replace"
                        ).splitlines():
                            if line.startswith("FAILED "):
                                failing.append(_annotate_failing(line[len("FAILED "):][:160], reasons))
                            elif "::" in line and " SKIPPED" in line:
                                # pytest -v 的 SKIPPED 行同样是未满足的面
                                # (p4 etag 取证:8/11 SKIPPED=实现不在验证
                                # 器预期的模块位置,行为测试全过仍 0.27,
                                # 而该信号此前被当"无名"整体丢弃)。
                                name = line.split(" SKIPPED")[0].strip()
                                if name:
                                    failing.append(_annotate_failing((name + " (skipped)")[:160], reasons))
                            if len(failing) >= 20:
                                break
                    except OSError:
                        pass
                # 自我历史对质(p7 etag 取证):agent 上次的收尾结论是最强的
                # 反重复/反理性化材料——"这些名字是幻觉"会撞上它自己上次写
                # 下的话。取上次 transcript 的最后一段 assistant 文本,单行化
                # 并剥方括号(结局行的 failing=[...] 解析按括号定界)。
                final_note = ""
                try:
                    transcript = trial_dir / "agent" / "metacodes-transcript.jsonl"
                    for line in reversed(
                        transcript.read_text(encoding="utf-8", errors="replace").splitlines()
                    ):
                        entry = json.loads(line)
                        if entry.get("role") != "assistant":
                            continue
                        for block in entry.get("blocks", []):
                            if block.get("type") == "text" and len(block.get("text", "")) > 40:
                                final_note = (
                                    block["text"][:300]
                                    .replace("\n", " ")
                                    .replace("[", "(")
                                    .replace("]", ")")
                                )
                                break
                        if final_note:
                            break
                except (OSError, json.JSONDecodeError):
                    pass
                row = {
                    "task": task,
                    "attempt_key": attempt_key,
                    "reward": float(reward),
                    "tests_passed": int(score.get("tests_passed") or 0),
                    "tests_total": int(score.get("tests_total") or 0),
                    # 溯源:评测验证器 = 外部权威(binary 缺省同值,这里显式)。
                    "provenance": "external_oracle",
                    "failing_tests": failing,
                    "_trial_dir": str(trial_dir),
                }
                if final_note:
                    row["final_note"] = final_note
                rows.append(row)
        return rows

    async def run(
        self, instruction: str, environment: BaseEnvironment, context: AgentContext
    ) -> None:
        instruction = self.render_instruction(instruction)
        escaped_instruction = shlex.quote(instruction)
        escaped_model = shlex.quote(self.model_name)
        escaped_model_display_name = shlex.quote(self._model_display_name)
        try:
            escaped_proxy = anthropic_messages_endpoint(self._proxy_url)
        except TraceError as exc:
            raise ValueError(str(exc)) from exc
        # metacodes treats METACODES_BASE_URL as the complete Anthropic
        # messages endpoint, not as a server root.  WorkBuddy supplies the host
        # proxy root, so make the protocol endpoint explicit.  Otherwise the
        # request arrives at `/`, the proxy classifies it as auxiliary traffic,
        # and the internal route slug leaks upstream instead of being rewritten
        # to the configured backend model.
        route = self.model_name
        # The WorkBuddy proxy consumes this prefix for per-trial attribution,
        # then resolves the suffix against its registered route table.
        if self._session_id:
            route = f"{self._session_id}::{route}"
        env = {
            # Route authority only.  The real provider credential never crosses
            # the host proxy boundary.
            "METACODES_ROUTE_TOKEN": route,
            # The job proxy is plain HTTP on a non-loopback name
            # (host.docker.internal).  Since the provider endpoint policy
            # (2026-09-01) a built-in profile refuses that, so the trial
            # declares a user-defined provider whose only channel *is* the
            # audited local proxy and whose policy states the plaintext hop
            # explicitly.  The route token still arrives over the anonymous
            # descriptor; nothing else about the request changes.
            "METACODES_PROVIDER": _PROXY_PROVIDER_ID,
            "METACODES_NO_PROBE": "1",
        }
        provider_config = _proxy_provider_config(self._proxy_url, self.model_name)

        mount = self._mount_path.rstrip("/")
        output_path = f"/logs/agent/{_OUTPUT_FILENAME}"
        transcript_path = f"/logs/agent/{_TRANSCRIPT_FILENAME}"
        observation_path = f"/logs/agent/{OBSERVATION_FILENAME}"
        runtime_contract_path = f"/logs/agent/{_RUNTIME_CONTRACT_FILENAME}"
        flags = [
            "--model", escaped_model,
            "--model-display-name", escaped_model_display_name,
            "--permission", "bypassPermissions",
            "--no-theme",
            "--disallowed-tools", shlex.quote(self._disabled_tools),
        ]
        if self._max_output_tokens is not None:
            flags += ["--max-tokens", str(self._max_output_tokens)]
        if self._verification_checkpoint:
            flags.append("--verification-checkpoint")
        if self._verification_final_gate:
            flags.append("--verification-final-gate")
        if self._verification_final_observe:
            flags.append("--verification-final-observe")
        if self._requirement_ledger:
            flags.append("--requirement-ledger")
        if self._requirement_ledger_observe:
            flags.append("--requirement-ledger-observe")

        project_setup = ""
        project_postcheck = ""
        project_contract = {
            "staged": False,
            "mode": "absent",
            "configured": False,
            "project_state_hash": None,
            "artifacts_verified": False,
            "runtime_active_bundle_absent": True,
        }
        project_staged = (
            self._project_kernel_relative is not None
            and self._project_rules_relative is not None
        )
        if project_staged:
            project_hash = project_state_hash("/workspace")
            project_contract = {
                "staged": True,
                "mode": self._project_control_mode,
                "configured": self._project_control_mode == "enforced",
                "project_state_hash": (
                    project_hash if self._project_control_mode == "enforced" else None
                ),
                "artifacts_verified": True,
                "runtime_active_bundle_absent": (
                    self._project_control_mode == "disabled"
                ),
            }
            project_source = mount + "/" + self._project_rules_relative
            project_kernel = mount + "/" + self._project_kernel_relative
            project_setup = (
                f'project_source={shlex.quote(project_source)}; '
                f'project_kernel={shlex.quote(project_kernel)}; '
                'test -d "$project_source" || exit 78; '
                'test -x "$project_kernel" || exit 83; '
            )
            if self._project_control_mode == "enforced":
                project_setup += (
                    f'project_state="$HOME/.metacodes/projects/{project_hash}"; '
                    'mkdir -p "$project_state" || exit 77; '
                    'test -z "$(find "$project_source" -type l -print -quit)" || exit 79; '
                    'test ! -e "$project_state/project-rules" || exit 80; '
                    'cp -R -- "$project_source" "$project_state/project-rules" || exit 81; '
                    'chmod -R u=rwX,go= "$project_state/project-rules" || exit 82; '
                    'export METACODES_PROJECT_KERNEL_PATH="$project_kernel"; '
                    'project_kernel_sha="$(sha256sum "$METACODES_PROJECT_KERNEL_PATH" | cut -d" " -f1)"; '
                    'test "${#project_kernel_sha}" -eq 64 || exit 83; '
                    'export METACODES_PROJECT_KERNEL_SHA256="$project_kernel_sha"; '
                )
            else:
                disabled_bundle_check = (
                    'test ! -e "$HOME/.metacodes/projects/'
                    + project_hash
                    + '/project-rules/active.json" || exit 88; '
                )
                project_setup += disabled_bundle_check
                project_postcheck = disabled_bundle_check
        else:
            project_contract = {
                "staged": False,
                "mode": "absent",
                "configured": False,
                "project_state_hash": None,
                "artifacts_verified": False,
                "runtime_active_bundle_absent": True,
            }

        remote_tinykg_env_absent = all(name not in env for name in _REMOTE_TINYKG_ENV)
        if not remote_tinykg_env_absent:
            raise ValueError("metacodes WorkBuddy trial received remote TinyKG authority")
        # Arm-level store continuity: single-transaction lifecycle over the
        # serial arm.  The store starts empty at the arm's first task and is
        # imported/exported through a hash-chained ledger; a broken chain
        # fails loud instead of silently forking memory.
        store_import_sha = None
        if self._memory_accumulation:
            continuity_root = _continuity_root(self.logs_dir)
            continuity_root.mkdir(parents=True, exist_ok=True)
            continuity_tar = continuity_root / _CONTINUITY_TAR
            continuity_ledger = continuity_root / _CONTINUITY_LEDGER
            # 两遍法种子:声明的 sha 必须是本链 export 历史的一员(pass 1
            # 的终态 tar 由 driver 预置为链头;后续 trial 延长链,声明值
            # 恒在历史里)。声明了但根空/历史无此 sha = fail loud。
            if self._continuity_seed_sha256 is not None:
                seed_rows = _read_continuity_ledger(continuity_ledger)
                seed_history = {
                    row.get("export_sha256") for row in seed_rows
                }
                if (
                    not continuity_tar.exists()
                    or self._continuity_seed_sha256 not in seed_history
                ):
                    raise ValueError(
                        "declared continuity seed is not part of this "
                        "arm's export history — the driver must pre-populate "
                        "the continuity root with the seeded ledger and tar"
                    )
            if continuity_tar.exists():
                tar_bytes = continuity_tar.read_bytes()
                if len(tar_bytes) > _MAX_CONTINUITY_TAR_BYTES:
                    raise ValueError(
                        "kg store continuity tar exceeds its transfer bound"
                    )
                store_import_sha = hashlib.sha256(tar_bytes).hexdigest()
                ledger_rows = _read_continuity_ledger(continuity_ledger)
                if not ledger_rows:
                    raise ValueError(
                        "kg store continuity tar has no ledger provenance"
                    )
                if ledger_rows[-1].get("export_sha256") != store_import_sha:
                    raise ValueError(
                        "kg store continuity ledger chain is broken"
                    )
                # /logs/agent is the bind mount the transcript itself uses;
                # /tmp is not shared across Harbor exec containers.
                import_host = self.logs_dir / "kg-import.tar"
                import_host.write_bytes(tar_bytes)
        outcomes_env = ""
        if self._outcome_feedback:
            # 确定性同题注入的 host 侧:把本 trial 的任务全名交给 runtime
            # (trial 目录名被 harbor 截断,不可用;config.json task.path 的
            # basename 是权威全名)。两遍法取证:被动 BM25 召回 4/16 命中
            # 且全是别题成绩单——同题结局必须由 host 定向声明。
            try:
                trial_config = json.loads(
                    (self.logs_dir.parent / "config.json").read_text(encoding="utf-8")
                )
                task_hint = str(trial_config["task"]["path"]).rstrip("/").rpartition("/")[2]
            except (OSError, json.JSONDecodeError, KeyError, TypeError):
                task_hint = ""
            if task_hint and len(task_hint) <= 200:
                outcomes_env += (
                    "export METACODES_TASK_HINT=" + shlex.quote(task_hint) + "; "
                )
            outcome_rows = self._collect_outcomes()
            best_by_task = {}
            for row in outcome_rows:
                task_name = row["task"]
                if (
                    task_name not in best_by_task
                    or row["reward"] > best_by_task[task_name]["reward"]
                ):
                    best_by_task[task_name] = row
            for row in best_by_task.values():
                artifact = _best_artifact(Path(row["_trial_dir"]))
                if artifact:
                    row["best_artifact"] = artifact
            for row in outcome_rows:
                row.pop("_trial_dir", None)
            if outcome_rows:
                (self.logs_dir / "task-outcomes.json").write_text(
                    json.dumps(
                        {
                            "schema_version": "task-outcome-v1",
                            "outcomes": outcome_rows,
                        },
                        sort_keys=True,
                    )
                    + "\n",
                    encoding="utf-8",
                )
                # += 而非 =:hint 导出已在前面追加,赋值会整个覆盖(p3/p4
                # 生产事故:METACODES_TASK_HINT 被此行蒸发,确定性注入从未
                # 发生,p3 的到达层归因因此作废)。
                outcomes_env += (
                    "export METACODES_TASK_OUTCOMES="
                    "/logs/agent/task-outcomes.json; "
                )
        runtime_contract = json.dumps(
            {
                "schema_version": "metacodes-workbuddy-runtime-contract-v2",
                "quality_evidence": False,
                "fresh_home": True,
                "local_tinykg": True,
                "remote_tinykg_env_absent": remote_tinykg_env_absent,
                "tinykg_store_absent_before_first_provider_request": store_import_sha is None,
                "memory_accumulation": self._memory_accumulation,
                "self_evolution": self._self_evolution,
                "outcome_feedback": self._outcome_feedback,
                "continuity_seed_sha256": self._continuity_seed_sha256,
                "store_import_sha256": store_import_sha,
                "credential_delivery": "env-route-token",
                "transport_model_is_route": True,
                "actor_model_identity": self._model_display_name,
                "verification_checkpoint": self._verification_checkpoint,
                "verification_final_gate": self._verification_final_gate,
                "verification_final_observe": self._verification_final_observe,
                "requirement_ledger": self._requirement_ledger,
                "requirement_ledger_observe": self._requirement_ledger_observe,
                "project_control": project_contract,
            },
            sort_keys=True,
            separators=(",", ":"),
        )

        if store_import_sha is None:
            store_gate = 'test ! -e "$METACODES_KG_STORE" || exit 85; '
        else:
            # Continuity witness replaces the empty-start assertion: the
            # imported bytes must hash to the ledger head before extraction.
            store_gate = (
                "test -f /logs/agent/kg-import.tar || exit 89; "
                'test "$(sha256sum /logs/agent/kg-import.tar | cut -d" " -f1)" = '
                + shlex.quote(store_import_sha)
                + " || exit 89; "
                + 'mkdir -p "$(dirname "$METACODES_KG_STORE")" || exit 89; '
                + 'tar -xf /logs/agent/kg-import.tar -C "$(dirname "$METACODES_KG_STORE")" || exit 89; '
                + 'test -d "$METACODES_KG_STORE" || exit 89; '
            )
        if self._memory_accumulation:
            # Always produce an export: an untouched store still advances the
            # ledger chain deterministically (empty dir tars are tiny), so the
            # next trial's import witness never has to guess.
            # v42 导出侧完整性门:导出前在容器内用会话同款读形态深探针店。
            # p41 取证:trial 1 的 GC 删除把店写进引擎读不回的状态,无门导出
            # 把毒店推进链头,之后整臂 + 以其为种子的后代 trial 的记忆系统
            # 静默死亡(15/16 InvalidRecord 全灭)。探针结果落
            # kg-export-probe.rc,host 侧据此决定链是否推进;空店(会话未建
            # 店)按 0 记——空导出无毒,importer 只会 init fresh。
            store_export = (
                'if [ -d "$METACODES_KG_STORE" ] '
                '&& [ -n "$(ls -A "$METACODES_KG_STORE" 2>/dev/null)" ]; then '
                '"$METACODES_KG_BIN" list-recent "$METACODES_KG_STORE" '
                "--kind project --limit 200 >/dev/null 2>/dev/null; "
                'printf "%s" "$?" > /logs/agent/kg-export-probe.rc; '
                'else printf "0" > /logs/agent/kg-export-probe.rc; fi; '
                'mkdir -p "$METACODES_KG_STORE" || exit 78; '
                'tar -cf /logs/agent/kg-export.tar -C "$(dirname "$METACODES_KG_STORE")" '
                '"$(basename "$METACODES_KG_STORE")" || exit 78; '
            )
        else:
            store_export = ""
        # Bash is intentional: WorkBuddy's installed-agent contract already
        # uses shell commands, and anonymous-FD handoff plus PIPESTATUS need a
        # real shell.  No credential value is interpolated into this command.
        run_home = _fresh_run_home(self.logs_dir, step_key=instruction)
        command = (
            "set -uo pipefail; umask 077; "
            f'run_home="{run_home}"; '
            'test ! -e "$run_home" || { echo "fresh HOME already exists" >&2; exit 70; }; '
            'mkdir -p "$run_home" || exit 70; export HOME="$run_home"; '
            'mkdir -p "$HOME/.metacodes" || exit 70; '
            f"printf '%s' {shlex.quote(provider_config)} > \"$HOME/.metacodes/config.json\" || exit 70; "
            "unset METACODES_PROJECT_KERNEL_PATH METACODES_PROJECT_KERNEL_SHA256; "
            f"{project_setup}"
            "export METACODES_KG_TRANSPORT=cli-exclusive; "
            # warn 级诊断上 Harbor stderr(r1/r2 教训:自演化静默降级三层,
            # 零日志可判;stdout 是 NDJSON 机器协议,不受影响)。
            "export METACODES_LOG='*:warn'; "
            + (
                "export METACODES_SELF_EVOLUTION=1; "
                "export METACODES_SELF_EVOLUTION_REPORT="
                "/logs/agent/self-evolution-report.json; "
                if self._self_evolution
                else ""
            )
            + outcomes_env
            + f'export METACODES_KG_BIN={shlex.quote(mount + "/bin/tinykg")}; '
            'export METACODES_KG_STORE="$HOME/.local/share/tinykg/store"; '
            f'export METACODES_FORMAL_KERNEL_PATH={shlex.quote(mount + "/libexec/metacodes-formal-kernel")}; '
            'kernel_sha="$(sha256sum "$METACODES_FORMAL_KERNEL_PATH" | cut -d" " -f1)"; '
            'test "${#kernel_sha}" -eq 64 || exit 71; '
            'export METACODES_FORMAL_KERNEL_SHA256="$kernel_sha"; '
            "unset TINYKG_REMOTE_URL TINYKG_API_KEY TINYKG_REMOTE_EXPECTED_BUILD_ID "
            "TINYKG_REMOTE_CONFIG METACODES_KG_CONFIG METACODES_KG_URL "
            "METACODES_KG_API_KEY METACODES_KG_EXPECTED_BUILD_ID "
            "METACODES_KG_EXPECTED_SCHEMA_DIGEST METASK_API_KEY; "
            'test -z "${TINYKG_REMOTE_URL+x}${TINYKG_API_KEY+x}'
            '${TINYKG_REMOTE_EXPECTED_BUILD_ID+x}${TINYKG_REMOTE_CONFIG+x}'
            '${METACODES_KG_CONFIG+x}${METACODES_KG_URL+x}${METACODES_KG_API_KEY+x}'
            '${METACODES_KG_EXPECTED_BUILD_ID+x}${METACODES_KG_EXPECTED_SCHEMA_DIGEST+x}'
            '${METASK_API_KEY+x}" || exit 84; '
            f"{store_gate}"
            f"printf '%s\\n' {shlex.quote(runtime_contract)} > "
            f"{shlex.quote(runtime_contract_path)} || exit 86; "
            f"chmod 0600 {shlex.quote(runtime_contract_path)} || exit 87; "
            # The route token stays in the environment: it is the credential
            # the user-defined provider declares (env alias METACODES_ROUTE_TOKEN),
            # and the registry credential path (resolveProviderScopedSecret)
            # consults CLI/env material only - the anonymous-descriptor hand-off
            # exists on the legacy Metask path alone.  The token is per-trial
            # route authority for the host proxy, never the provider secret.
            # --stream-json: live per-event NDJSON on stdout (text/tool/usage/
            # turn) so watchers can tail metacodes-output.jsonl mid-run and
            # kill a doomed trial early instead of waiting for the terminal
            # result line.  trace.py's final_result already filters
            # type=="result", so the extra event lines are forward-compatible.
            f"metacodes {' '.join(flags)} -p {escaped_instruction} --json --stream-json "
            # NDJSON stdout is a machine protocol; stderr must never merge
            # with the exactly-once result event.  It also must not vanish:
            # p3 forensics found the "Harbor-owned stderr stream" reaches no
            # exported artifact, so every METACODES_LOG=warn diagnostic
            # (self-evolution degradations, author parse failures, injection
            # receipts) fell into a void.  Tee it onto the /logs/agent bind
            # mount the trial already exports.
            "</dev/null 2> >(tee /logs/agent/metacodes-stderr.log >&2) "
            f"| tee {shlex.quote(output_path)}; "
            "agent_status=${PIPESTATUS[0]}; "
            f"{project_postcheck}"
            'mapfile -t transcripts < <(find "$HOME/.metacodes/projects" '
            "-type f -name transcript.jsonl -print 2>/dev/null); "
            'test "${#transcripts[@]}" -eq 1 || { '
            'echo "expected one metacodes transcript, found ${#transcripts[@]}" >&2; '
            "exit 72; }; "
            f'cp -- "${{transcripts[0]}}" {shlex.quote(transcript_path)} || exit 73; '
            'mapfile -t observations < <(find "$HOME/.metacodes/projects" '
            "-type f -name tool-observations.jsonl -print 2>/dev/null); "
            'test "${#observations[@]}" -eq 1 || { '
            'echo "expected one metacodes observation journal, found ${#observations[@]}" >&2; '
            "exit 74; }; "
            f'cp -- "${{observations[0]}}" {shlex.quote(observation_path)} || exit 75; '
            'chmod 0600 "${transcripts[0]}" "${observations[0]}" '
            f"{shlex.quote(transcript_path)} {shlex.quote(observation_path)} {shlex.quote(output_path)} || exit 76; "
            f"{store_export}"
            'exit "$agent_status"'
        )
        await self.exec_as_agent(
            environment,
            command=command,
            env=env,
            cwd="/workspace",
        )
        if self._memory_accumulation:
            _advance_continuity_chain(
                self.logs_dir,
                _continuity_root(self.logs_dir),
                self._session_id,
                store_import_sha,
            )

    def populate_context_post_run(self, context: AgentContext) -> None:
        try:
            try:
                trace = load_trace_ir(
                    self.logs_dir / _OUTPUT_FILENAME,
                    self.logs_dir / _TRANSCRIPT_FILENAME,
                )
            except (TraceError, FileNotFoundError) as exc:
                # A killed or timed-out agent (harbor SIGTERM -> exit 143, or an
                # OOM kill) is torn down before it can emit its single terminal
                # `result` event, so the NDJSON stream carries zero results.
                # That is a legitimately failed trial worth zero reward, not a
                # harness fault. Raising here propagates out of harbor's
                # per-trial exception-recovery path (_recover_outputs runs
                # inside the trial's own `except`) and cancels every sibling in
                # the TaskGroup — observed 2026-09-05 on kunshan security-sealed
                # where a single exit-143 trial aborted the whole 24-task cohort
                # after only 3 were graded. Tolerate *exactly* the no-result
                # case as a degenerate zero trajectory; every other trace defect
                # (malformed JSON, more than one result, bad field types) must
                # still fail loudly.
                if (
                    isinstance(exc, TraceError)
                    and "result event, found 0" not in str(exc)
                ):
                    raise
                trace = {
                    "result": {
                        "stop_reason": "killed_no_result",
                        "turns": 0,
                        "tool_calls": 0,
                        "input_tokens": 0,
                        "output_tokens": 0,
                        "cost_usd": 0.0,
                        "text": "",
                        "cache_read_input_tokens": 0,
                        "cache_creation_input_tokens": 0,
                    },
                    # Trajectory requires >= 1 step; emit a single marker step so
                    # the degenerate trajectory validates. transcript_ir row shape.
                    "steps": [
                        {
                            "step_id": 1,
                            "source": "agent",
                            "message": (
                                "metacodes agent was terminated before emitting "
                                "a result event (timeout / SIGTERM / OOM); this "
                                "trial is recorded as a failed zero-reward run."
                            ),
                            "reasoning_content": None,
                            "tool_calls": [],
                            "observations": [],
                            "extra": {"killed_no_result": True},
                        }
                    ],
                    "control_metrics": {"killed_no_result": True},
                }
            if "control_metrics" not in trace:
                control_metrics = load_control_metrics(
                    self.logs_dir / _TRANSCRIPT_FILENAME,
                    self.logs_dir / OBSERVATION_FILENAME,
                )
                # Runtime receipt for the enforced arm, symmetric with the
                # disabled arm's exit-88 bundle-absence postcheck: the binary
                # derives the project-rules directory from its own XxHash64 of
                # the cwd and silently runs bare-rules when the lookup misses
                # (harness review 2026-08-17 finding #2 — the treatment dose
                # would drop to zero with no error anywhere). A dispatching
                # enforced run whose journal carries zero rule_filter events
                # means the bundle was never loaded; fail the trial loudly.
                if self._project_control_mode == "enforced":
                    runtime = control_metrics.get("tool_runtime") or {}
                    lean = control_metrics.get("lean") or {}
                    if runtime.get("dispatch_started", 0) > 0 and not lean.get(
                        "rule_filter_events", 0
                    ):
                        raise RuntimeError(
                            "enforced project control produced no rule_filter "
                            "events across a dispatching run: the rule bundle "
                            "was staged but never loaded by the binary"
                        )
                trace["control_metrics"] = control_metrics
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
                "control_metrics": trace.get("control_metrics"),
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
