#!/usr/bin/env python3
"""Native zero-cost smoke for all three memory benchmark adapters."""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import os
import platform
import signal
import socket
import subprocess
import tempfile
import threading
from pathlib import Path
from typing import Any, Mapping

if __package__ in {None, ""}:
    import sys

    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    from scripts.eval.memory_agent_runtime import (  # type: ignore
        PRODUCTION_CHILD_PATH,
        SCRIPTED_PROVIDER_ID,
        ScriptedMemoryProvider,
        _cassette_memory_exposure,
        _materialize_production_sandbox,
        _run_production_sandbox_probe,
        run_memory_agent_schedule,
    )
    from scripts.eval.memory_hotpot_adapter import adapt_hotpot, artifact_bytes  # type: ignore
    from scripts.eval.memory_longmem_adapter import adapt_longmem  # type: ignore
    from scripts.eval.memory_procedural_adapter import adapt_procedural  # type: ignore
    from scripts.eval.memory_query_plan import (  # type: ignore
        load_and_verify_query_plan_sidecar,
    )
    from scripts.eval.memory_tinykg_local import _store_info  # type: ignore
    from scripts.eval.model import stable_json  # type: ignore
else:
    from .memory_agent_runtime import (
        PRODUCTION_CHILD_PATH,
        SCRIPTED_PROVIDER_ID,
        ScriptedMemoryProvider,
        _cassette_memory_exposure,
        _materialize_production_sandbox,
        _run_production_sandbox_probe,
        run_memory_agent_schedule,
    )
    from .memory_hotpot_adapter import adapt_hotpot, artifact_bytes
    from .memory_longmem_adapter import adapt_longmem
    from .memory_procedural_adapter import adapt_procedural
    from .memory_query_plan import load_and_verify_query_plan_sidecar
    from .memory_tinykg_local import _store_info
    from .model import stable_json


REPO_ROOT = Path(__file__).resolve().parents[2]


def _digest(label: str) -> str:
    return hashlib.sha256(label.encode("utf-8")).hexdigest()


def _execution() -> Mapping[str, Any]:
    return {
        "model_id": SCRIPTED_PROVIDER_ID,
        "model_fingerprint": _digest(SCRIPTED_PROVIDER_ID),
        "harness_revision": "native-memory-agent-lifecycle-smoke-v3",
        "arms": [
            {"id": "no_memory", "fingerprint": _digest("no-memory-native-v3")},
            {"id": "markdown_memory", "fingerprint": _digest("markdown-native-v3")},
            {"id": "tinykg_lexical", "fingerprint": _digest("tinykg-native-v3")},
        ],
        "trials": 1,
        "retrieval_limits": {
            "max_k": 10,
            "max_hops": 3,
            "max_semantic_variants": 4,
        },
    }


def _write_json(path: Path, value: Any) -> None:
    path.write_bytes(artifact_bytes(value))


def _hotpot_record() -> Mapping[str, Any]:
    return {
        "_id": "5a8b57f25542995d1e60000a",
        "question": "Which bridge connects the subject to its birthplace?",
        "answer": "Bridge Alpha",
        "type": "bridge",
        "level": "hard",
        "supporting_facts": [["Subject Alpha", 0], ["Bridge Alpha", 1]],
        "context": [
            ["Bridge Alpha", ["Bridge Alpha is a named structure.", "Bridge Alpha is in City Alpha."]],
            ["Subject Alpha", ["Subject Alpha was born in City Alpha.", "The subject later moved."]],
            ["Distractor", ["This sentence is irrelevant."]],
        ],
    }


def _longmem_record() -> Mapping[str, Any]:
    return {
        "question_id": "question_native_smoke",
        "question_type": "single-session-preference",
        "question": "What warning-label color did I prefer?",
        "answer": "amber",
        "question_date": "2024/01/10 (Wed) 12:00",
        "haystack_session_ids": ["distractor", "answer-session"],
        "haystack_dates": ["2024/01/02 (Tue) 09:00", "2024/01/05 (Fri) 10:00"],
        "haystack_sessions": [
            [
                {"role": "user", "content": "Discuss an unrelated subject."},
                {"role": "assistant", "content": "Here is unrelated information.", "has_answer": False},
            ],
            [
                {"role": "user", "content": "I prefer amber warning labels.", "has_answer": True},
                {"role": "assistant", "content": "I will remember that preference.", "has_answer": False},
            ],
        ],
        "answer_session_ids": ["answer-session"],
    }


def _run_fd_auth_seatbelt_smoke(root: Path, metacodes: Path) -> None:
    """Exercise the release binary's one-shot FD auth on the paid sandbox path."""

    if platform.system() != "Darwin":
        return
    smoke_root = root / "fd-auth-seatbelt"
    artifact = smoke_root / "rollout"
    workspace = smoke_root / "workspace"
    child_tmp = artifact / "tmp"
    sealed_home = artifact / "sealed-home"
    for path in (artifact, workspace, child_tmp, sealed_home):
        path.mkdir(parents=True, exist_ok=True)
    sibling = smoke_root / "sibling-sentinel.txt"
    sibling.write_text("must remain unreadable\n", encoding="utf-8")
    ripgrep = sealed_home / ".metacodes" / "toolchain" / "rg"
    ripgrep.parent.mkdir(parents=True)
    # This no-tool smoke only needs a sealed executable at the production
    # profile's pinned-ripgrep slot. Reusing the already hash-pinned app keeps
    # the check cross-worktree and avoids depending on a host rg installation.
    ripgrep.write_bytes(metacodes.read_bytes())
    ripgrep.chmod(0o500)
    profile = artifact / "production-seatbelt.sb"
    evidence = artifact / "production-seatbelt-probe.json"
    sandbox = _materialize_production_sandbox(
        profile_path=profile,
        evidence_path=evidence,
        artifact_dir=artifact,
        workspace=workspace,
        store=None,
        metacodes=metacodes,
        tinykg=None,
        ripgrep=ripgrep,
    )
    _run_production_sandbox_probe(
        sandbox,
        host_read_path=REPO_ROOT / "build.zig",
        sibling_read_path=sibling,
        writable_root=child_tmp,
        evidence_path=evidence,
    )

    credential_read_fd, credential_write_fd = os.pipe()
    try:
        secret = b"loopback-only-fd-auth-smoke"
        if os.write(credential_write_fd, secret) != len(secret):
            raise RuntimeError("FD auth smoke wrote a partial credential")
        os.close(credential_write_fd)
        credential_write_fd = -1
        env = {
            "PATH": PRODUCTION_CHILD_PATH,
            "HOME": str(sealed_home),
            "TMPDIR": str(child_tmp),
            "TMP": str(child_tmp),
            "TEMP": str(child_tmp),
            "LC_ALL": "C",
            "LANG": "C",
            "METACODES_API_KEY_FD": str(credential_read_fd),
            "METACODES_NO_PROBE": "1",
            "METACODES_PROVIDER": "anthropic",
            "RG_BIN": str(ripgrep),
        }
        with ScriptedMemoryProvider(
            "Reply briefly.",
            "codex_style",
            "episodic_recall",
            "test",
            memory_file=None,
            memory_index=None,
            memory_marker=None,
        ) as provider:
            completed = subprocess.run(
                sandbox.command(
                    [
                        str(metacodes),
                        "--base-url",
                        provider.url,
                        "--model",
                        "claude-sonnet-4-20250514",
                        "--permission",
                        "bypassPermissions",
                        "--no-theme",
                        "--max-tokens",
                        "128",
                        "-p",
                        "Reply briefly.",
                        "--json",
                    ]
                ),
                cwd=workspace,
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=20,
                check=False,
                pass_fds=(credential_read_fd,),
            )
        if completed.returncode != 0:
            raise RuntimeError(
                "FD auth Seatbelt smoke failed "
                f"returncode={completed.returncode}: {completed.stderr[-1000:]}"
            )
        rows = [json.loads(line) for line in completed.stdout.splitlines() if line.strip()]
        results = [row for row in rows if row.get("type") == "result"]
        if len(results) != 1 or results[0].get("stop_reason") != "end_turn":
            raise RuntimeError("FD auth Seatbelt smoke produced no complete result")
        if len(provider.requests) != 1:
            raise RuntimeError("FD auth Seatbelt smoke did not make exactly one loopback request")
        if secret.decode("ascii") in completed.stdout or secret.decode("ascii") in completed.stderr:
            raise RuntimeError("FD auth Seatbelt smoke leaked its credential")
    finally:
        if credential_write_fd >= 0:
            os.close(credential_write_fd)
        os.close(credential_read_fd)


def _run_fd_auth_https_environment_regression(root: Path, metacodes: Path) -> None:
    """HTTPS must fail normally after FD auth, never scan a freed env block."""

    if platform.system() != "Darwin":
        return
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.bind(("127.0.0.1", 0))
    listener.listen(8)
    listener.settimeout(0.25)
    listener_stop = threading.Event()

    def close_connections() -> None:
        while not listener_stop.is_set():
            try:
                connection, _address = listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            connection.close()

    listener_thread = threading.Thread(target=close_connections, daemon=True)
    listener_thread.start()
    credential_read_fd, credential_write_fd = os.pipe()
    try:
        secret = b"loopback-only-https-env-regression"
        if os.write(credential_write_fd, secret) != len(secret):
            raise RuntimeError("HTTPS environment regression wrote a partial credential")
        os.close(credential_write_fd)
        credential_write_fd = -1
        env = {
            "PATH": PRODUCTION_CHILD_PATH,
            "HOME": str(root),
            "TMPDIR": str(root),
            "TMP": str(root),
            "TEMP": str(root),
            "LC_ALL": "C",
            "LANG": "C",
            "METACODES_API_KEY_FD": str(credential_read_fd),
            "METACODES_NO_PROBE": "1",
            "METACODES_PROVIDER": "anthropic",
        }
        completed = subprocess.run(
            [
                str(metacodes),
                "--base-url",
                f"https://127.0.0.1:{listener.getsockname()[1]}/v1/messages",
                "--model",
                "glm-5.2",
                "--permission",
                "bypassPermissions",
                "--no-theme",
                "--max-tokens",
                "16",
                "-p",
                "offline HTTPS environment regression",
                "--json",
            ],
            cwd=root,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=20,
            check=False,
            pass_fds=(credential_read_fd,),
        )
        if completed.returncode in {-signal.SIGSEGV, 128 + signal.SIGSEGV}:
            raise RuntimeError("FD auth HTTPS path crashed while scanning the startup environment")
        if completed.returncode == 0:
            raise RuntimeError("closed loopback HTTPS endpoint unexpectedly succeeded")
        if secret.decode("ascii") in completed.stdout or secret.decode("ascii") in completed.stderr:
            raise RuntimeError("HTTPS environment regression leaked its credential")
    finally:
        if credential_write_fd >= 0:
            os.close(credential_write_fd)
        os.close(credential_read_fd)
        listener_stop.set()
        listener.close()
        listener_thread.join(timeout=5)


def _run_adapter(
    root: Path,
    label: str,
    source_slice: Mapping[str, Any],
    manifest: Mapping[str, Any],
    metacodes: Path,
    metacodes_sha: str,
    tinykg: Path,
    tinykg_sha: str,
    validators: Mapping[str, Any] | None = None,
) -> None:
    adapter_root = root / label
    adapter_root.mkdir()
    source_path = adapter_root / "source.json"
    manifest_path = adapter_root / "manifest.json"
    _write_json(source_path, source_slice)
    _write_json(manifest_path, manifest)
    validator_path = None
    if validators is not None:
        validator_path = adapter_root / "validators.json"
        _write_json(validator_path, validators)
    run_dir = adapter_root / "native-run"
    observations, receipt = run_memory_agent_schedule(
        metacodes_binary=metacodes,
        expected_metacodes_sha256=metacodes_sha,
        tinykg_binary=tinykg,
        expected_tinykg_sha256=tinykg_sha,
        source_path=source_path,
        manifest_path=manifest_path,
        run_dir=run_dir,
        observations_path=run_dir / "observations.jsonl",
        runtime_receipt_path=run_dir / "runtime-receipt.json",
        validator_bundle_path=validator_path,
        timeout_seconds=45,
    )
    if len(observations) != len(manifest["schedule"]):
        raise RuntimeError(f"{label}: incomplete native schedule")
    if any(row["trajectory"]["model_requests"] < 1 for row in observations):
        raise RuntimeError(f"{label}: replay-only observation escaped native gate")
    benchmarks = {case["id"]: case["benchmark"] for case in manifest["cases"]}
    receipts = {
        (rollout["case_id"], rollout["trial"], rollout["arm"]): rollout
        for rollout in receipt["rollouts"]
    }
    for row in observations:
        rollout = receipts[(row["case_id"], row["trial"], row["arm"])]
        cassette = run_dir / rollout["artifact_paths"]["cassette"]
        split = next(
            case["split"] for case in manifest["cases"] if case["id"] == row["case_id"]
        )
        if (
            benchmarks[row["case_id"]] == "procedural_transfer"
            and split != "online"
            and row["arm"] == "markdown_memory"
        ):
            memory_root = run_dir / rollout["artifact_paths"]["memory_state"]
            memory_index = memory_root / "MEMORY.md"
            exposure = _cassette_memory_exposure(
                cassette,
                f"{label} native offline memory injection",
                memory_root=memory_root,
                expected_memory_index=memory_index.read_bytes(),
                count_graph_context=False,
            )
            if exposure["auto_injected_bytes"] < memory_index.stat().st_size:
                raise RuntimeError(f"{label}: durable MEMORY.md was not injected")
        query_plan_trace = load_and_verify_query_plan_sidecar(
            cassette,
            run_id=rollout["run_id"],
            arm=rollout["arm"],
            memory_backend=rollout["memory_backend"],
            required=True,
            where=f"{label} native query plan",
        )
        assert query_plan_trace is not None
        if row["arm"] == "tinykg_lexical":
            if row["trajectory"]["tool_calls"] < 1 or not row["retrieval"]["query_variants"]:
                raise RuntimeError(f"{label}: TinyKG treatment did not reach real tools")
            if query_plan_trace["status"] != "verified":
                raise RuntimeError(f"{label}: TinyKG query-plan receipt was not host-verified")
            store = run_dir / rollout["artifact_paths"]["store"]
            completed = subprocess.run(
                [str(tinykg), "store-info", str(store)],
                env={key: value for key, value in os.environ.items() if not key.startswith("TINYKG_")},
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=15,
                check=False,
            )
            if completed.returncode != 0:
                raise RuntimeError(f"{label}: cannot re-observe TinyKG store-info")
            actual_text_stale = _store_info(completed.stdout).get("text_stale") == "1"
            if row["graph"]["text_stale"] is not actual_text_stale:
                raise RuntimeError(f"{label}: observation misreported TinyKG text_stale")
            if benchmarks[row["case_id"]] != "procedural_transfer":
                if not row["retrieval"]["retrieved_evidence_ids"]:
                    raise RuntimeError(f"{label}: real KgRecall returned no mapped evidence")
                if not row["retrieval"]["verified_evidence_ids"]:
                    raise RuntimeError(f"{label}: real KgContext did not verify a candidate")
        elif row["arm"] == "markdown_memory":
            if query_plan_trace["status"] != "not_applicable":
                raise RuntimeError(f"{label}: Markdown arm reported TinyKG query-plan activity")
            if row["trajectory"]["tool_calls"] < 1:
                raise RuntimeError(f"{label}: Markdown treatment did not reach real tools")
            if benchmarks[row["case_id"]] != "procedural_transfer" or next(
                case["split"] for case in manifest["cases"] if case["id"] == row["case_id"]
            ) != "online":
                if not row["retrieval"]["query_variants"]:
                    raise RuntimeError(f"{label}: Markdown treatment did not recall durable memory")
        else:
            if query_plan_trace["status"] != "not_applicable":
                raise RuntimeError(f"{label}: no-memory arm reported TinyKG query-plan activity")
            if row["trajectory"]["tool_calls"] != 0:
                raise RuntimeError(f"{label}: no-memory control exposed treatment tools")
    if receipt["quality_evidence"] is not False:
        raise RuntimeError(f"{label}: wiring smoke was mislabeled as quality evidence")
    if receipt["external_network_calls"] != 0 or receipt["paid_cost_usd"] != 0:
        raise RuntimeError(f"{label}: scripted runtime escaped zero-cost boundary")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True)
    parser.add_argument("--tinykg-binary", required=True)
    parser.add_argument(
        "--output-dir",
        help="optional fresh local directory that keeps the native artifacts",
    )
    args = parser.parse_args(argv)
    metacodes = Path(args.binary).resolve()
    tinykg = Path(args.tinykg_binary).resolve()
    metacodes_sha = hashlib.sha256(metacodes.read_bytes()).hexdigest()
    tinykg_sha = hashlib.sha256(tinykg.read_bytes()).hexdigest()

    if args.output_dir:
        output_root = Path(args.output_dir).expanduser().resolve()
        if output_root.exists():
            raise RuntimeError("--output-dir must not already exist")
        output_root.mkdir(parents=True)
        directory_context = contextlib.nullcontext(str(output_root))
    else:
        directory_context = tempfile.TemporaryDirectory(prefix="metacodes-memory-native-")

    with directory_context as directory:
        root = Path(directory)
        remote_config = root / "remote-config-sentinel.json"
        remote_store = root / "remote-store-sentinel.kg"
        remote_config.write_text('{"sentinel":"remote-config"}\n', encoding="utf-8")
        remote_store.write_text("remote-store-must-not-change\n", encoding="utf-8")
        before_config = hashlib.sha256(remote_config.read_bytes()).hexdigest()
        before_store = hashlib.sha256(remote_store.read_bytes()).hexdigest()
        isolation_sentinels = {
            "TINYKG_REMOTE_CONFIG": str(remote_config),
            "TINYKG_STORE": str(remote_store),
            "METACODES_KG_CONFIG": str(remote_config),
            "METACODES_KG_URL": "http://127.0.0.1:1",
            "METACODES_KG_API_KEY": "local-daemon-must-not-reach-child",
            "METACODES_KG_EXPECTED_BUILD_ID": "sha256:" + "f" * 64,
            "METACODES_KG_EXPECTED_SCHEMA_DIGEST": "e" * 64,
        }
        previous = {key: os.environ.get(key) for key in isolation_sentinels}
        os.environ.update(isolation_sentinels)
        try:
            _run_fd_auth_https_environment_regression(root, metacodes)
            _run_fd_auth_seatbelt_smoke(root, metacodes)
            raw_hotpot = root / "hotpot-upstream.json"
            raw_hotpot.write_text(stable_json([_hotpot_record()]) + "\n", encoding="utf-8")
            hotpot_slice, hotpot_manifest = adapt_hotpot(
                raw_hotpot,
                _execution(),
                expected_source_sha256=hashlib.sha256(raw_hotpot.read_bytes()).hexdigest(),
                limit=1,
                split_seed=20260807,
                source_url="https://example.invalid/native-hotpot-smoke.json",
                source_revision="native-smoke-v1",
            )
            _run_adapter(
                root,
                "hotpot",
                hotpot_slice,
                hotpot_manifest,
                metacodes,
                metacodes_sha,
                tinykg,
                tinykg_sha,
            )

            raw_longmem = root / "longmem-upstream.json"
            raw_longmem.write_text(stable_json([_longmem_record()]) + "\n", encoding="utf-8")
            longmem_slice, longmem_manifest = adapt_longmem(
                raw_longmem,
                _execution(),
                expected_source_sha256=hashlib.sha256(raw_longmem.read_bytes()).hexdigest(),
                limit=1,
                split_seed=20260807,
                source_url="https://example.invalid/native-longmem-smoke.json",
                source_revision="native-smoke-v1",
            )
            _run_adapter(
                root,
                "longmem",
                longmem_slice,
                longmem_manifest,
                metacodes,
                metacodes_sha,
                tinykg,
                tinykg_sha,
            )

            procedural_fixture = REPO_ROOT / "evals/memory/fixtures/procedural-coding-source-v3.json"
            procedural_slice, validators, procedural_manifest = adapt_procedural(
                procedural_fixture,
                _execution(),
                expected_source_sha256=hashlib.sha256(procedural_fixture.read_bytes()).hexdigest(),
                limit_families=1,
                split_seed=20260807,
            )
            _run_adapter(
                root,
                "procedural",
                procedural_slice,
                procedural_manifest,
                metacodes,
                metacodes_sha,
                tinykg,
                tinykg_sha,
                validators,
            )
        finally:
            for key, value in previous.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value
        if hashlib.sha256(remote_config.read_bytes()).hexdigest() != before_config:
            raise RuntimeError("remote TinyKG config sentinel changed")
        if hashlib.sha256(remote_store.read_bytes()).hexdigest() != before_store:
            raise RuntimeError("remote TinyKG store sentinel changed")
        if args.output_dir:
            summary = {
                "schema_version": 1,
                "mode": "native-agent-loop-scripted-lifecycle-smoke",
                "quality_evidence": False,
                "adapters": [
                    "hotpotqa-distractor",
                    "longmemeval-s-cleaned",
                    "coding-intent-families",
                ],
                "metacodes_binary_sha256": metacodes_sha,
                "tinykg_binary_sha256": tinykg_sha,
                "paid_cost_usd": 0.0,
                "external_network_calls": 0,
                "remote_tinykg_writes": 0,
            }
            (root / "SUMMARY.json").write_text(
                stable_json(summary) + "\n",
                encoding="utf-8",
            )
    suffix = f", artifacts={Path(args.output_dir).resolve()}" if args.output_dir else ""
    print(
        "memory-agent-runtime-smoke: FD auth Seatbelt + 3 adapters, 3 arms, durable lifecycle, native agent loop, "
        f"paid=0, external_network=0{suffix}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
