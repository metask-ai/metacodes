"""Install the metacodes adapter into a pinned WorkBuddy-Bench checkout.

The Tencent checkout remains replaceable: all maintained source lives here,
and this installer performs two small deterministic registrations plus file
copies.  It refuses an unexpected checkout, upstream drift, or unrelated dirty
files instead of guessing how to merge them.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
import subprocess
from pathlib import Path
from typing import Dict, Iterable, List, Tuple

from . import WORKBUDDY_PINNED_COMMIT

# Windows portability (see scripts/eval/model.py): os.open text mode must never
# touch artifacts, directory descriptors cannot be opened, and permission bits
# are synthetic there.
_O_BINARY = getattr(os, "O_BINARY", 0)
_POSIX_MODE_BITS = os.name != "nt"


def _fsync_directory(path) -> None:
    if os.name == "nt":
        return
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)



class OverlayError(ValueError):
    pass


_ADAPTER_PATH = Path("src/workbuddy_bench/runner/harness_adapters.py")
_RESOLVER_PATH = Path("src/workbuddy_bench/runner/resolve_manifest.py")
_PREPARE_JOB_PATH = Path("src/workbuddy_bench/runner/prepare_job.py")
_AGENT_PATH = Path("src/workbuddy_bench/agents/metacodes_agent.py")
_TRACE_PATH = Path("src/workbuddy_bench/agents/_metacodes_trace.py")
_KEY_FD_PATH = Path("src/workbuddy_bench/proxy/_metacodes_key_fd.py")
_PROXY_CONFIG_PATH = Path("src/workbuddy_bench/proxy/config.py")
_PROXY_LOGGER_PATH = Path("src/workbuddy_bench/proxy/interceptors/logger.py")
_PROXY_PIPELINE_PATH = Path("src/workbuddy_bench/proxy/pipeline.py")
_ARTIFACT_PREFIX = "configs/harnesses/metacodes/docker/artifacts/"


_ADAPTER_ANCHOR = "HARNESS_ADAPTERS: dict[str, HarnessRuntimeAdapter] = {\n"
_ADAPTER_ENTRY = '''    "metacodes": HarnessRuntimeAdapter(
        harness_name="metacodes",
        canonical_display_name="metacodes",
        harness_protocol="anthropic",
        backend_base_env="ANTHROPIC_BASE_URL",
        backend_key_env="ANTHROPIC_API_KEY",
        proxy_url_env="",
        uses_anthropic_env=True,
    ),
'''


_DISPATCH_OLD = '''    if name in ("cc", "claude-code"):
        return _build_cc_runtime_config(**common)
    return _build_generic_runtime_config(**common)
'''
_DISPATCH_NEW = '''    if name in ("cc", "claude-code"):
        return _build_cc_runtime_config(**common)
    if name == "metacodes":
        return _build_metacodes_runtime_config(**common)
    return _build_generic_runtime_config(**common)
'''


_GENERIC_ANCHOR = "def _build_generic_runtime_config(\n"
_MODEL_ROUTE_OLD = '        model_route = f"{instance_id}__{model_slug}"\n'
_MODEL_ROUTE_NEW = '''        # Harbor uses ``__`` as the serialized eval-group delimiter and its
        # summary parser accepts only agent[__model]__dataset.  Embedding that
        # delimiter inside the opaque local-proxy route makes a fully completed
        # job crash while formatting its final table.  Route lookup is exact, so
        # use a delimiter that cannot be mistaken for Harbor group structure.
        model_route = f"{instance_id}--{model_slug}"
'''
_METACODES_RUNTIME_BUILDER = '''def _build_metacodes_runtime_config(
    *,
    harness: dict[str, Any],
    configs_dir: Path,
    harness_params: dict[str, Any],
    model_params: dict[str, Any],
    context_window: dict[str, Any],
    connection_mode: str,
    backend_url_env: str,
    backend_key_env: str,
    model_route: str,
    backend_model_name: str,
) -> dict[str, Any]:
    """Audit block mirroring MetacodesAgent's fail-closed runtime boundary."""
    del configs_dir
    env: dict[str, str] = {
        str(key): str(value) for key, value in (harness.get("env") or {}).items()
    }
    if connection_mode == "local_proxy":
        env.update({
            "METACODES_PROVIDER": "anthropic",
            "METACODES_BASE_URL": "<proxy_url>",
            "METACODES_API_KEY_FD": "<anonymous-fd:route-token>",
            "METACODES_MODEL": model_route,
        })
    else:
        env.update({
            "METACODES_PROVIDER": "anthropic",
            "METACODES_BASE_URL": f"${{{backend_url_env}}}" if backend_url_env else "",
            "METACODES_API_KEY_FD": "<anonymous-fd:redacted>",
            "METACODES_MODEL": backend_model_name,
        })
    env.update({
        "METACODES_KG_TRANSPORT": "cli-exclusive",
        "METACODES_KG_BIN": "/opt/metacodes/bin/tinykg",
        "METACODES_KG_STORE": "<fresh-home>/.local/share/tinykg/store",
        "METACODES_FORMAL_KERNEL_PATH": "/opt/metacodes/libexec/metacodes-formal-kernel",
        "METACODES_FORMAL_KERNEL_SHA256": "<verified-mount-sha256>",
    })
    project_rules = harness_params.get("METACODES_PROJECT_RULES_RELATIVE")
    project_kernel = harness_params.get("METACODES_PROJECT_KERNEL_RELATIVE")
    project_mode = harness_params.get("METACODES_PROJECT_CONTROL_MODE")
    verification_checkpoint = harness_params.get(
        "METACODES_VERIFICATION_CHECKPOINT", False
    )
    if not isinstance(verification_checkpoint, bool):
        raise ValueError(
            "METACODES_VERIFICATION_CHECKPOINT must be an explicit boolean"
        )
    project_staged = bool(project_rules and project_kernel)
    if project_staged and project_mode not in ("disabled", "enforced"):
        raise ValueError(
            "metacodes staged project control requires explicit disabled/enforced mode"
        )
    if not project_staged and project_mode is not None:
        raise ValueError("metacodes project control mode requires staged artifacts")
    if project_rules or project_kernel:
        env.update({
            "METACODES_PROJECT_RULES_SOURCE": (
                f"/opt/metacodes/{project_rules}" if project_rules else "<missing>"
            ),
            "METACODES_PROJECT_KERNEL_PATH": (
                f"/opt/metacodes/{project_kernel}" if project_kernel else "<missing>"
            ),
            "METACODES_PROJECT_KERNEL_SHA256": "<verified-mount-sha256>",
        })
    return {
        "harness": "metacodes",
        "connection_policy": "local-proxy-only",
        "credential_delivery": "anonymous-fd-route-token",
        "disabled_tools": harness_params.get("METACODES_DISALLOWED_TOOLS"),
        "project_control_staged": project_staged,
        "project_control_mode": project_mode if project_staged else "absent",
        "project_control_configured": project_staged and project_mode == "enforced",
        "transport_model_is_route": connection_mode == "local_proxy",
        "actor_model_identity": backend_model_name,
        "verification_checkpoint": verification_checkpoint,
        "translated_env": {key: value for key, value in env.items() if value},
        "cleared_env": [
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
        ],
        "context_window_request": context_window,
        "context_window_actuation": "metacodes-native-model-catalog",
        "model_params": model_params,
        "backend_key_env": backend_key_env,
    }


'''


_PROXY_IMPORT_ANCHOR = "import yaml\n"
_PROXY_IMPORT = (
    "\nfrom workbuddy_bench.proxy._metacodes_key_fd import resolve_secret_env\n"
)
_PROXY_KEY_OLD = '        key = _resolve_env(backend_raw.get("key", ""), backend_raw.get("key_env", ""))\n'
_PROXY_KEY_NEW = '        key = resolve_secret_env(backend_raw.get("key", ""), backend_raw.get("key_env", ""))\n'


_PROXY_LOGGER_INIT_OLD = '''        self._seq = 0
        # Per-stream accumulators keyed by request_id
        self._stream_bufs: dict[str, _StreamAccumulator] = {}
'''
_PROXY_LOGGER_INIT_NEW = '''        self._seq = 0
        # Sequence numbers are allocated when the request reaches the proxy, not
        # when its response happens to finish.  Completion order is not request
        # order when a client closes a stream immediately after message_stop.
        self._request_seqs: dict[str, int] = {}
        # Per-stream accumulators keyed by request_id
        self._stream_bufs: dict[str, _StreamAccumulator] = {}
'''
_PROXY_LOGGER_REQUEST_OLD = '''        if ctx.client_body is None:
            ctx.client_body = _json_safe(ctx.ensure_parsed())
        if ctx.is_stream:
            self._stream_bufs[ctx.request_id] = _StreamAccumulator()
'''
_PROXY_LOGGER_REQUEST_NEW = '''        if ctx.client_body is None:
            ctx.client_body = _json_safe(ctx.ensure_parsed())
        self._seq += 1
        self._request_seqs[ctx.request_id] = self._seq
        if ctx.is_stream:
            self._stream_bufs[ctx.request_id] = _StreamAccumulator()
'''
_PROXY_LOGGER_DISCARD_OLD = '''    def discard_stream(self, request_id: str) -> None:
        """Drop a stream's accumulator without logging.

        Safe to call from a cancellation/finally path (no I/O, no await): ensures
        the per-request accumulator is freed even when the client disconnects
        mid-stream and on_stream_end never runs. Idempotent.
        """
        self._stream_bufs.pop(request_id, None)

'''
_PROXY_LOGGER_DISCARD_NEW = '''    def discard_stream(self, request_id: str) -> None:
        """Drop a stream that provably never reached the provider."""
        self._stream_bufs.pop(request_id, None)
        self._request_seqs.pop(request_id, None)

    def finalize_aborted_stream(self, ctx: RequestContext) -> None:
        """Persist a provider-attempt record even if the client closes early.

        Some clients stop reading immediately after the terminal SSE event.  The
        async generator is then closed before ``on_stream_end`` resumes, although
        the provider request and its complete response already happened.  Losing
        that record corrupts request counts and can make a later request look like
        the cacheable first request.  This synchronous finally-path is deliberately
        fail-visible: a stream without a terminal event is recorded as status 499.
        """
        buf = self._stream_bufs.pop(ctx.request_id, None)
        if buf is None:
            self._request_seqs.pop(ctx.request_id, None)
            return
        completed = bool(buf.stop_reason or buf.finish_reason)
        status = 200 if completed else 499
        resp = ResponseContext(
            status_code=status,
            is_stream=True,
            duration_ms=(time.time() - ctx.timestamp) * 1000,
            error=None if completed else "client_disconnected_before_terminal_event",
        )
        resp.summary = buf.summarize()
        resp.summary["status"] = status
        self._write_record(self._build_record(ctx, resp), _route_instance_id(ctx))

'''
_PROXY_LOGGER_SEQ_OLD = '''        """Build a JSONL record."""
        self._seq += 1

        client_request_body = _json_safe(ctx.client_body or ctx.parsed_body or {})
'''
_PROXY_LOGGER_SEQ_NEW = '''        """Build a JSONL record."""
        request_seq = self._request_seqs.pop(ctx.request_id, None)
        if request_seq is None:
            # Defensive compatibility for direct test callers that bypassed
            # on_request; production paths always allocate before provider I/O.
            self._seq += 1
            request_seq = self._seq

        client_request_body = _json_safe(ctx.client_body or ctx.parsed_body or {})
'''
_PROXY_LOGGER_RECORD_SEQ_OLD = '''            "seq": self._seq,
'''
_PROXY_LOGGER_RECORD_SEQ_NEW = '''            "seq": request_seq,
'''
_PROXY_PIPELINE_FINALLY_OLD = '''            if not stream_ended:
                for interceptor in self._interceptors.values():
                    discard = getattr(interceptor, "discard_stream", None)
                    if discard:
                        discard(ctx.request_id)
'''
_PROXY_PIPELINE_FINALLY_NEW = '''            if not stream_ended:
                for interceptor in self._interceptors.values():
                    finalize = (
                        getattr(interceptor, "finalize_aborted_stream", None)
                        if provider_state["started"]
                        else None
                    )
                    if finalize is not None:
                        finalize(ctx)
                        continue
                    discard = getattr(interceptor, "discard_stream", None)
                    if discard:
                        discard(ctx.request_id)
'''
_PROXY_PIPELINE_STREAM_STATE_OLD = '''        stream_ended = False
        try:
'''
_PROXY_PIPELINE_STREAM_STATE_NEW = '''        stream_ended = False
        provider_state = {"started": False}
        try:
'''
_PROXY_PIPELINE_STREAM_LOOP_OLD = '''            if substream is not None:
                async for event in substream:
                    yield event
'''
_PROXY_PIPELINE_STREAM_LOOP_NEW = '''            if substream is not None:
                async for event in substream:
                    yield event
'''
_PROXY_PIPELINE_SUBSTREAM_CALLS_OLD = '''                    ctx, route, interceptor_names, upstream_url, upstream_body, t0, sink
                )
            elif route.mode == ProxyMode.PASSTHROUGH:
                substream = self._stream_passthrough(
                    ctx, route, interceptor_names, upstream_url, upstream_body, t0, sink
'''
_PROXY_PIPELINE_SUBSTREAM_CALLS_NEW = '''                    ctx, route, interceptor_names, upstream_url, upstream_body, t0, sink,
                    provider_state,
                )
            elif route.mode == ProxyMode.PASSTHROUGH:
                substream = self._stream_passthrough(
                    ctx, route, interceptor_names, upstream_url, upstream_body, t0, sink,
                    provider_state,
'''
_PROXY_PIPELINE_A2O_SIGNATURE_OLD = '''        sink: list[ResponseContext],
    ) -> AsyncIterator[bytes]:
        """A2O streaming: convert OpenAI chunks to Anthropic SSE. Yields client
'''
_PROXY_PIPELINE_A2O_SIGNATURE_NEW = '''        sink: list[ResponseContext],
        provider_state: dict[str, bool],
    ) -> AsyncIterator[bytes]:
        """A2O streaming: convert OpenAI chunks to Anthropic SSE. Yields client
'''
_PROXY_PIPELINE_PASSTHROUGH_SIGNATURE_OLD = '''        sink: list[ResponseContext],
    ) -> AsyncIterator[bytes]:
        """Same-protocol passthrough: relay upstream bytes verbatim (event names,
'''
_PROXY_PIPELINE_PASSTHROUGH_SIGNATURE_NEW = '''        sink: list[ResponseContext],
        provider_state: dict[str, bool],
    ) -> AsyncIterator[bytes]:
        """Same-protocol passthrough: relay upstream bytes verbatim (event names,
'''
_PROXY_PIPELINE_A2O_SENDER_OLD = '''        try:
            async for chunk in self.sender.send_stream(
'''
_PROXY_PIPELINE_A2O_SENDER_NEW = '''        try:
            # A2O emits a synthetic message_start before touching the upstream.
            # Mark the physical attempt only when execution reaches the sender.
            provider_state["started"] = True
            async for chunk in self.sender.send_stream(
'''
_PROXY_PIPELINE_PASSTHROUGH_SENDER_OLD = '''        try:
            async for chunk in self.sender.send_stream_raw(
'''
_PROXY_PIPELINE_PASSTHROUGH_SENDER_NEW = '''        try:
            provider_state["started"] = True
            async for chunk in self.sender.send_stream_raw(
'''
_PROXY_PIPELINE_A2O_START_OLD = '''        start_event = converter.start()
        yield start_event
        await self._broadcast_chunk(
            ctx, names, StreamChunk(client_raw_bytes=start_event, summarize=False)
        )
'''
_PROXY_PIPELINE_A2O_START_NEW = '''        start_event = converter.start()
        await self._broadcast_chunk(
            ctx, names, StreamChunk(client_raw_bytes=start_event, summarize=False)
        )
        yield start_event
'''
_PROXY_PIPELINE_A2O_EVENTS_OLD = '''                for event in events:
                    yield event
                await self._broadcast_chunk(
                    ctx, names,
                    StreamChunk(client_raw_bytes=b"".join(events), upstream_parsed=chunk),
                )
'''
_PROXY_PIPELINE_A2O_EVENTS_NEW = '''                await self._broadcast_chunk(
                    ctx, names,
                    StreamChunk(client_raw_bytes=b"".join(events), upstream_parsed=chunk),
                )
                for event in events:
                    yield event
'''
_PROXY_PIPELINE_A2O_FINISH_OLD = '''            finish_events = converter.finish()
            for event in finish_events:
                yield event
            await self._broadcast_chunk(
                ctx, names,
                StreamChunk(client_raw_bytes=b"".join(finish_events), summarize=False),
            )
'''
_PROXY_PIPELINE_A2O_FINISH_NEW = '''            finish_events = converter.finish()
            await self._broadcast_chunk(
                ctx, names,
                StreamChunk(client_raw_bytes=b"".join(finish_events), summarize=False),
            )
            for event in finish_events:
                yield event
'''
_PROXY_PIPELINE_PASSTHROUGH_OLD = '''                if not rewrite:
                    yield chunk
                    await self._broadcast_chunk(ctx, names, StreamChunk(raw_bytes=chunk))
                    continue
'''
_PROXY_PIPELINE_PASSTHROUGH_NEW = '''                if not rewrite:
                    await self._broadcast_chunk(ctx, names, StreamChunk(raw_bytes=chunk))
                    yield chunk
                    continue
'''
_PROXY_PIPELINE_REWRITE_OLD = '''                    out = _rewrite_reasoning_sse(head + sep)
                    yield out
                    await self._broadcast_chunk(ctx, names, StreamChunk(raw_bytes=out))
'''
_PROXY_PIPELINE_REWRITE_NEW = '''                    out = _rewrite_reasoning_sse(head + sep)
                    await self._broadcast_chunk(ctx, names, StreamChunk(raw_bytes=out))
                    yield out
'''
_PROXY_PIPELINE_REWRITE_TAIL_OLD = '''                out = _rewrite_reasoning_sse(buf)
                yield out
                await self._broadcast_chunk(ctx, names, StreamChunk(raw_bytes=out))
'''
_PROXY_PIPELINE_REWRITE_TAIL_NEW = '''                out = _rewrite_reasoning_sse(buf)
                await self._broadcast_chunk(ctx, names, StreamChunk(raw_bytes=out))
                yield out
'''


_RESOLVER_MOUNT_OLD = '''    dataset_runtime = load_dataset_runtime_contract(dataset, repo_root=_repo_root())
    dataset_requires_mount = dataset_runtime.requires_split_mount_for(harness_name)
    backend_for_mount = "local"
'''
_RESOLVER_MOUNT_NEW = '''    dataset_runtime = load_dataset_runtime_contract(dataset, repo_root=_repo_root())
    # Official v1 datasets predate metacodes and therefore enumerate only the
    # original split-mount harnesses.  The metacodes harness itself declares a
    # pinned mount and is never baked into task images, so treat that declaration
    # as the authoritative delivery requirement instead of silently omitting it.
    metacodes_declares_mount = (
        harness_name == "metacodes" and isinstance(harness.get("mount"), dict)
    )
    dataset_requires_mount = (
        dataset_runtime.requires_split_mount_for(harness_name)
        or metacodes_declares_mount
    )
    backend_for_mount = "local"
'''


_PREPARE_MOUNT_OLD = '''    harness_name = harness.get("name", "")
    dataset_requires_mount = dataset_runtime.requires_split_mount_for(str(harness_name))
    harness_mount = harness.get("mount")
    if dataset_requires_mount:
'''
_PREPARE_MOUNT_NEW = '''    harness_name = harness.get("name", "")
    metacodes_declares_mount = (
        harness_name == "metacodes" and isinstance(harness.get("mount"), dict)
    )
    dataset_requires_mount = (
        dataset_runtime.requires_split_mount_for(str(harness_name))
        or metacodes_declares_mount
    )
    manifest_mount = (manifest or {}).get("harness_mount")
    if isinstance(manifest_mount, dict):
        if manifest_mount.get("required") is not dataset_requires_mount:
            raise ValueError(
                f"{job_path}: resolved harness-mount requirement drifted before prepare_job"
            )
    harness_mount = harness.get("mount")
    if dataset_requires_mount:
'''

_PREPARE_AGENT_IDENTITY_OLD = '''    kwargs: dict[str, Any] = dict(harness_params)
    if model_params:
        kwargs["model_params"] = model_params
'''
_PREPARE_AGENT_IDENTITY_NEW = '''    kwargs: dict[str, Any] = dict(harness_params)
    if harness.get("name") == "metacodes":
        backend_model_name = str(
            (manifest or {}).get("backend_model_name") or model.get("name") or ""
        )
        if not backend_model_name:
            raise ValueError("metacodes requires a stable backend model identity")
        kwargs["METACODES_MODEL_DISPLAY_NAME"] = backend_model_name
    if model_params:
        kwargs["model_params"] = model_params
'''


def _run(repo: Path, *args: str) -> str:
    try:
        return subprocess.run(
            ["git", "-C", str(repo), *args],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
        ).stdout
    except (OSError, subprocess.CalledProcessError) as exc:
        raise OverlayError(f"git {' '.join(args)} failed: {exc}") from exc


def _head_file(repo: Path, relative: Path) -> bytes:
    try:
        return subprocess.run(
            ["git", "-C", str(repo), "show", f"HEAD:{relative.as_posix()}"],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        ).stdout
    except (OSError, subprocess.CalledProcessError) as exc:
        raise OverlayError(f"cannot read pinned upstream {relative}: {exc}") from exc


_RESUME_SUBSET_OLD = """    try:
        task_selection, selected_tasks = resolve_task_selection(
            selection_spec, task_listing, dataset=dataset
        )
    except ValueError as exc:
        raise ValueError(f"{job_config_path}: {exc}") from exc
"""
# Trial-resume(增量 B):重跑调用通过环境变量把选择收窄到账本授权的
# trial 子集。此机制本身不需要被信任——审计端强制 attempt-2 目录恰好
# 匹配 journal 的 trial_resume_authorized 集合;越界名在此 fail-closed
# 只是为了更早更清晰地失败。
_RESUME_SUBSET_NEW = _RESUME_SUBSET_OLD + """
    resume_subset_raw = os.environ.get("METACODES_WB_RESUME_TASKS")
    if resume_subset_raw:
        if not selected_tasks:
            raise ValueError(
                f"{job_config_path}: resume subset requires a name-mode "
                "task selection; mode-all jobs cannot be resumed"
            )
        resume_subset = [name for name in resume_subset_raw.split(",") if name]
        unknown = sorted(set(resume_subset) - set(selected_tasks))
        if unknown:
            raise ValueError(
                f"{job_config_path}: resume subset names outside the job "
                f"selection: {unknown}"
            )
        keep = set(resume_subset)
        selected_tasks = [name for name in selected_tasks if name in keep]
        task_selection = {
            "mode": "name",
            "names": list(selected_tasks),
            "count_selected": len(selected_tasks),
            "resume_subset": True,
        }
"""


def _patched_upstream(repo: Path) -> Dict[Path, bytes]:
    adapter = _head_file(repo, _ADAPTER_PATH).decode("utf-8")
    if adapter.count(_ADAPTER_ANCHOR) != 1:
        raise OverlayError("WorkBuddy harness adapter registry anchor drifted")
    if '"metacodes": HarnessRuntimeAdapter(' in adapter:
        raise OverlayError("pinned WorkBuddy already contains a metacodes adapter")
    adapter = adapter.replace(_ADAPTER_ANCHOR, _ADAPTER_ANCHOR + _ADAPTER_ENTRY, 1)

    resolver = _head_file(repo, _RESOLVER_PATH).decode("utf-8")
    if resolver.count(_DISPATCH_OLD) != 1:
        raise OverlayError("WorkBuddy runtime-config dispatch anchor drifted")
    if resolver.count(_GENERIC_ANCHOR) != 1:
        raise OverlayError("WorkBuddy generic runtime-config anchor drifted")
    resolver = resolver.replace(_DISPATCH_OLD, _DISPATCH_NEW, 1)
    resolver = resolver.replace(
        _GENERIC_ANCHOR, _METACODES_RUNTIME_BUILDER + _GENERIC_ANCHOR, 1
    )
    if resolver.count(_MODEL_ROUTE_OLD) != 1:
        raise OverlayError("WorkBuddy local-proxy route anchor drifted")
    resolver = resolver.replace(_MODEL_ROUTE_OLD, _MODEL_ROUTE_NEW, 1)
    if resolver.count(_RESOLVER_MOUNT_OLD) != 1:
        raise OverlayError("WorkBuddy resolver mount-requirement anchor drifted")
    resolver = resolver.replace(_RESOLVER_MOUNT_OLD, _RESOLVER_MOUNT_NEW, 1)
    if resolver.count(_RESUME_SUBSET_OLD) != 1:
        raise OverlayError("WorkBuddy resolver task-selection anchor drifted")
    resolver = resolver.replace(_RESUME_SUBSET_OLD, _RESUME_SUBSET_NEW, 1)

    prepare_job = _head_file(repo, _PREPARE_JOB_PATH).decode("utf-8")
    if prepare_job.count(_PREPARE_AGENT_IDENTITY_OLD) != 1:
        raise OverlayError("WorkBuddy prepare_job model-identity anchor drifted")
    prepare_job = prepare_job.replace(
        _PREPARE_AGENT_IDENTITY_OLD,
        _PREPARE_AGENT_IDENTITY_NEW,
        1,
    )
    if prepare_job.count(_PREPARE_MOUNT_OLD) != 1:
        raise OverlayError("WorkBuddy prepare_job mount-requirement anchor drifted")
    prepare_job = prepare_job.replace(_PREPARE_MOUNT_OLD, _PREPARE_MOUNT_NEW, 1)

    proxy_config = _head_file(repo, _PROXY_CONFIG_PATH).decode("utf-8")
    if proxy_config.count(_PROXY_IMPORT_ANCHOR) != 1:
        raise OverlayError("WorkBuddy proxy import anchor drifted")
    if proxy_config.count(_PROXY_KEY_OLD) != 1:
        raise OverlayError("WorkBuddy proxy credential resolver anchor drifted")
    proxy_config = proxy_config.replace(
        _PROXY_IMPORT_ANCHOR,
        _PROXY_IMPORT_ANCHOR + _PROXY_IMPORT,
        1,
    ).replace(_PROXY_KEY_OLD, _PROXY_KEY_NEW, 1)
    proxy_logger = _head_file(repo, _PROXY_LOGGER_PATH).decode("utf-8")
    for old, new, label in (
        (_PROXY_LOGGER_INIT_OLD, _PROXY_LOGGER_INIT_NEW, "logger init"),
        (_PROXY_LOGGER_REQUEST_OLD, _PROXY_LOGGER_REQUEST_NEW, "request sequence"),
        (_PROXY_LOGGER_DISCARD_OLD, _PROXY_LOGGER_DISCARD_NEW, "stream finalizer"),
        (_PROXY_LOGGER_SEQ_OLD, _PROXY_LOGGER_SEQ_NEW, "record sequence"),
        (_PROXY_LOGGER_RECORD_SEQ_OLD, _PROXY_LOGGER_RECORD_SEQ_NEW, "record field"),
    ):
        if proxy_logger.count(old) != 1:
            raise OverlayError(f"WorkBuddy proxy {label} anchor drifted")
        proxy_logger = proxy_logger.replace(old, new, 1)
    proxy_pipeline = _head_file(repo, _PROXY_PIPELINE_PATH).decode("utf-8")
    for old, new, label in (
        (_PROXY_PIPELINE_STREAM_STATE_OLD, _PROXY_PIPELINE_STREAM_STATE_NEW, "stream state"),
        (_PROXY_PIPELINE_STREAM_LOOP_OLD, _PROXY_PIPELINE_STREAM_LOOP_NEW, "stream loop"),
        (_PROXY_PIPELINE_SUBSTREAM_CALLS_OLD, _PROXY_PIPELINE_SUBSTREAM_CALLS_NEW, "substream calls"),
        (_PROXY_PIPELINE_A2O_SIGNATURE_OLD, _PROXY_PIPELINE_A2O_SIGNATURE_NEW, "A2O signature"),
        (
            _PROXY_PIPELINE_PASSTHROUGH_SIGNATURE_OLD,
            _PROXY_PIPELINE_PASSTHROUGH_SIGNATURE_NEW,
            "passthrough signature",
        ),
        (_PROXY_PIPELINE_A2O_SENDER_OLD, _PROXY_PIPELINE_A2O_SENDER_NEW, "A2O sender"),
        (
            _PROXY_PIPELINE_PASSTHROUGH_SENDER_OLD,
            _PROXY_PIPELINE_PASSTHROUGH_SENDER_NEW,
            "passthrough sender",
        ),
        (_PROXY_PIPELINE_A2O_START_OLD, _PROXY_PIPELINE_A2O_START_NEW, "A2O start"),
        (_PROXY_PIPELINE_A2O_EVENTS_OLD, _PROXY_PIPELINE_A2O_EVENTS_NEW, "A2O events"),
        (_PROXY_PIPELINE_A2O_FINISH_OLD, _PROXY_PIPELINE_A2O_FINISH_NEW, "A2O finish"),
        (_PROXY_PIPELINE_PASSTHROUGH_OLD, _PROXY_PIPELINE_PASSTHROUGH_NEW, "passthrough"),
        (_PROXY_PIPELINE_REWRITE_OLD, _PROXY_PIPELINE_REWRITE_NEW, "rewrite"),
        (_PROXY_PIPELINE_REWRITE_TAIL_OLD, _PROXY_PIPELINE_REWRITE_TAIL_NEW, "rewrite tail"),
        (_PROXY_PIPELINE_FINALLY_OLD, _PROXY_PIPELINE_FINALLY_NEW, "stream finally"),
    ):
        if proxy_pipeline.count(old) != 1:
            raise OverlayError(f"WorkBuddy proxy {label} anchor drifted")
        proxy_pipeline = proxy_pipeline.replace(old, new, 1)
    return {
        _ADAPTER_PATH: adapter.encode("utf-8"),
        _RESOLVER_PATH: resolver.encode("utf-8"),
        _PREPARE_JOB_PATH: prepare_job.encode("utf-8"),
        _PROXY_CONFIG_PATH: proxy_config.encode("utf-8"),
        _PROXY_LOGGER_PATH: proxy_logger.encode("utf-8"),
        _PROXY_PIPELINE_PATH: proxy_pipeline.encode("utf-8"),
    }


def _overlay_sources() -> List[Tuple[Path, bytes]]:
    root = Path(__file__).resolve().parent
    overlay = root / "overlay"
    rows: List[Tuple[Path, bytes]] = [
        (_TRACE_PATH, (root / "trace.py").read_bytes()),
        (_KEY_FD_PATH, (root / "key_fd.py").read_bytes()),
    ]
    for source in sorted(overlay.rglob("*")):
        if source.is_file():
            rows.append((source.relative_to(overlay), source.read_bytes()))
    return rows


def _digest(rows: Iterable[Tuple[Path, bytes]], patched: Dict[Path, bytes]) -> str:
    digest = hashlib.sha256()
    all_rows = list(rows) + sorted(patched.items(), key=lambda item: item[0].as_posix())
    for relative, content in sorted(all_rows, key=lambda item: item[0].as_posix()):
        name = relative.as_posix().encode("utf-8")
        digest.update(len(name).to_bytes(4, "big"))
        digest.update(name)
        digest.update(len(content).to_bytes(8, "big"))
        digest.update(content)
    return digest.hexdigest()


def _dirty_paths(repo: Path) -> List[str]:
    changed = _run(repo, "diff", "--name-only", "HEAD").splitlines()
    untracked = _run(repo, "ls-files", "--others", "--exclude-standard").splitlines()
    return sorted(set(changed + untracked))


def _allowed_dirty(path: str, owned: set[Path], manifest_path: Path) -> bool:
    return (
        Path(path) in owned
        or path == manifest_path.as_posix()
        or path.startswith(_ARTIFACT_PREFIX)
    )


def _write_expected(target: Path, content: bytes, *, replace_owned: bool = False) -> None:
    if target.exists():
        if target.is_symlink() or not target.is_file():
            raise OverlayError(f"overlay target is not a regular file: {target}")
        if target.read_bytes() == content:
            return
        if not replace_owned:
            raise OverlayError(f"overlay target contains conflicting content: {target}")
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_name(target.name + ".metacodes-overlay.tmp")
    if temporary.exists():
        raise OverlayError(f"stale overlay temporary file: {temporary}")
    with temporary.open("xb") as handle:
        handle.write(content)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, target)


def _read_single_link_regular(path: Path, *, maximum: int = 32 * 1024 * 1024) -> bytes:
    try:
        descriptor = os.open(path, _O_BINARY | os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    except OSError as exc:
        raise OverlayError(f"cannot open overlay file {path}: {exc}") from exc
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise OverlayError(f"overlay file is not a single-link regular file: {path}")
        if before.st_size > maximum:
            raise OverlayError(f"overlay file size is outside the safety bound: {path}")
        chunks: List[bytes] = []
        observed = 0
        while True:
            chunk = os.read(descriptor, min(1024 * 1024, maximum + 1 - observed))
            if not chunk:
                break
            chunks.append(chunk)
            observed += len(chunk)
            if observed > maximum:
                raise OverlayError(f"overlay file exceeds the safety bound: {path}")
        after = os.fstat(descriptor)
        identity = (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
        if identity != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
            raise OverlayError(f"overlay file changed while hashing: {path}")
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def validate_installed_overlay(
    repo: Path,
    manifest_path: Path = Path("configs/harnesses/metacodes/OVERLAY.json"),
) -> Dict[str, object]:
    """Validate every installed overlay byte against its aggregate manifest.

    The aggregate v1 digest covers every installed file except the generated
    manifest itself.  Paid launch creation and re-observation share this exact
    verifier with upgrades so the installer and execution gate cannot drift.
    """
    checkout = repo.resolve(strict=True)
    if manifest_path.is_absolute() or ".." in manifest_path.parts:
        raise OverlayError("overlay manifest path escapes checkout")
    target = checkout / manifest_path

    def unique(pairs: List[Tuple[str, object]]) -> Dict[str, object]:
        result: Dict[str, object] = {}
        for key, value in pairs:
            if key in result:
                raise OverlayError(f"duplicate overlay manifest field: {key}")
            result[key] = value
        return result

    try:
        previous = json.loads(
            _read_single_link_regular(target).decode("utf-8"),
            object_pairs_hook=unique,
        )
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise OverlayError(f"overlay manifest is invalid: {exc}") from exc
    if not isinstance(previous, dict):
        raise OverlayError("overlay manifest is not an object")
    if (
        previous.get("schema_version") != "metacodes-workbuddy-overlay-v1"
        or previous.get("workbuddy_commit") != WORKBUDDY_PINNED_COMMIT
        or previous.get("quality_evidence") is not False
    ):
        raise OverlayError("overlay manifest has an unrelated identity")
    overlay_sha = previous.get("overlay_sha256")
    if (
        not isinstance(overlay_sha, str)
        or len(overlay_sha) != 64
        or any(character not in "0123456789abcdef" for character in overlay_sha)
    ):
        raise OverlayError("overlay manifest has an invalid aggregate digest")
    raw_paths = previous.get("installed_paths")
    if (
        not isinstance(raw_paths, list)
        or not raw_paths
        or any(not isinstance(raw, str) for raw in raw_paths)
        or len(raw_paths) != len(set(raw_paths))
        or raw_paths != sorted(raw_paths)
    ):
        raise OverlayError("overlay manifest has invalid or duplicate installed paths")
    rows: List[Tuple[Path, bytes]] = []
    for raw in raw_paths:
        relative = Path(raw)
        if relative.is_absolute() or not relative.parts or ".." in relative.parts:
            raise OverlayError(f"overlay manifest path escapes checkout: {raw}")
        installed = checkout / relative
        try:
            installed.resolve(strict=True).relative_to(checkout)
        except (OSError, ValueError) as exc:
            raise OverlayError(f"overlay path is missing or escapes checkout: {raw}") from exc
        rows.append((relative, _read_single_link_regular(installed)))
    if _digest(rows, {}) != overlay_sha:
        raise OverlayError("installed overlay files changed after installation")
    return previous


def _verified_previous_overlay(repo: Path, manifest_path: Path) -> set[Path]:
    """Return paths owned by an intact prior overlay, or fail closed."""
    target = repo / manifest_path
    if not target.exists() and not target.is_symlink():
        return set()
    previous = validate_installed_overlay(repo, manifest_path)
    return {Path(raw) for raw in previous["installed_paths"]}


def _write_generated_manifest(target: Path, content: bytes) -> None:
    if target.exists():
        if target.is_symlink() or not target.is_file():
            raise OverlayError(f"overlay manifest is not a regular file: {target}")
        if target.read_bytes() == content:
            return
        try:
            previous = json.loads(target.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise OverlayError(f"existing overlay manifest is invalid: {exc}") from exc
        if (
            previous.get("schema_version") != "metacodes-workbuddy-overlay-v1"
            or previous.get("workbuddy_commit") != WORKBUDDY_PINNED_COMMIT
        ):
            raise OverlayError("existing overlay manifest has an unrelated identity")
    else:
        target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_name(target.name + ".metacodes-overlay.tmp")
    if temporary.exists():
        raise OverlayError(f"stale overlay temporary file: {temporary}")
    with temporary.open("xb") as handle:
        handle.write(content)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, target)


def install(repo: Path) -> Dict[str, object]:
    repo = repo.resolve()
    head = _run(repo, "rev-parse", "HEAD").strip()
    if head != WORKBUDDY_PINNED_COMMIT:
        raise OverlayError(
            f"WorkBuddy checkout is {head}, expected {WORKBUDDY_PINNED_COMMIT}"
        )
    origin = _run(repo, "remote", "get-url", "origin").strip().lower()
    if "tencent/workbuddy-bench" not in origin:
        raise OverlayError(f"unexpected WorkBuddy origin: {origin}")

    manifest_path = Path("configs/harnesses/metacodes/OVERLAY.json")
    previous_owned = _verified_previous_overlay(repo, manifest_path)
    patched = _patched_upstream(repo)
    sources = _overlay_sources()
    next_owned = {path for path, _ in sources} | set(patched)
    allowed_owned = previous_owned | next_owned
    unrelated = [
        path
        for path in _dirty_paths(repo)
        if not _allowed_dirty(path, allowed_owned, manifest_path)
    ]
    if unrelated:
        raise OverlayError(f"checkout has unrelated dirty paths: {unrelated}")
    stale_owned = previous_owned - next_owned
    if stale_owned:
        raise OverlayError(
            "overlay upgrade would leave stale owned paths: "
            f"{sorted(path.as_posix() for path in stale_owned)}"
        )
    overlay_sha = _digest(sources, patched)
    manifest = {
        "schema_version": "metacodes-workbuddy-overlay-v1",
        "workbuddy_commit": WORKBUDDY_PINNED_COMMIT,
        "overlay_sha256": overlay_sha,
        "quality_evidence": False,
        "installed_paths": sorted(
            [path.as_posix() for path, _ in sources]
            + [path.as_posix() for path in patched]
        ),
    }
    manifest_bytes = (
        json.dumps(manifest, sort_keys=True, indent=2) + "\n"
    ).encode("utf-8")

    for relative, expected in patched.items():
        target = repo / relative
        current = target.read_bytes()
        base = _head_file(repo, relative)
        if current not in (base, expected) and relative not in previous_owned:
            raise OverlayError(f"upstream patch target was modified independently: {relative}")
        if current != expected:
            temporary = target.with_name(target.name + ".metacodes-overlay.tmp")
            with temporary.open("xb") as handle:
                handle.write(expected)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, target)
    for relative, content in sources:
        _write_expected(
            repo / relative,
            content,
            replace_owned=relative in previous_owned,
        )
    _write_generated_manifest(repo / manifest_path, manifest_bytes)
    return manifest


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("workbuddy_checkout", type=Path)
    args = parser.parse_args(argv)
    try:
        manifest = install(args.workbuddy_checkout)
    except (OSError, OverlayError) as exc:
        parser.error(str(exc))
    print(json.dumps(manifest, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
