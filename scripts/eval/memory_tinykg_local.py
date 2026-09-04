"""Run memory-adapter corpus smokes against an explicit local TinyKG store.

This module deliberately does not import or execute the TinyKG skill harness.
Every child process receives an absolute TinyKG binary, an explicit store path
inside a fresh run directory, a sealed HOME, and no ``TINYKG_*`` environment
variables, including Metacodes' own local-daemon namespace. Read-only retrieval
is guarded by a content digest of the complete store before and after
search/traversal.

The smoke proves corpus materialization, lexical retrieval plumbing, graph
traversal, and local-store isolation.  It does not claim benchmark accuracy.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Sequence, Tuple

from .memory_benchmark import file_sha256
from .memory_procedural_adapter import artifact_bytes as stable_artifact_bytes
from .memory_replay import load_manifest
from .model import ValidationError, stable_json


TRACE_SCHEMA_VERSION = 1
SUPPORTED_ADAPTERS = frozenset(
    {
        "hotpotqa-distractor",
        "longmemeval-s-cleaned",
        "coding-intent-families",
    }
)
REMOTE_ENV_KEYS = (
    "TINYKG_REMOTE_URL",
    "TINYKG_API_KEY",
    "TINYKG_REMOTE_EXPECTED_BUILD_ID",
    "TINYKG_REMOTE_CONFIG",
    "TINYKG_STORE",
    "METACODES_KG_CONFIG",
    "METACODES_KG_URL",
    "METACODES_KG_API_KEY",
    "METACODES_KG_EXPECTED_BUILD_ID",
    "METACODES_KG_EXPECTED_SCHEMA_DIGEST",
)


def _fail(where: str, message: str) -> None:
    raise ValidationError(f"{where}: {message}")


def _object(value: Any, where: str, keys: Iterable[str]) -> Mapping[str, Any]:
    if not isinstance(value, dict):
        _fail(where, "expected an object")
    expected = frozenset(keys)
    missing = expected - set(value)
    unknown = set(value) - expected
    if missing:
        _fail(where, f"missing fields: {sorted(missing)}")
    if unknown:
        _fail(where, f"unknown fields: {sorted(unknown)}")
    return value


def _string(value: Any, where: str) -> str:
    if not isinstance(value, str) or not value.strip():
        _fail(where, "expected non-empty string")
    return value


def _text(value: Any, where: str) -> str:
    if not isinstance(value, str):
        _fail(where, "expected a string")
    return value


def _integer(value: Any, where: str, *, minimum: int = 0) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < minimum:
        _fail(where, f"expected integer >= {minimum}")
    return value


def _hash(value: Any, where: str) -> str:
    result = _string(value, where).lower()
    if len(result) != 64 or any(ch not in "0123456789abcdef" for ch in result):
        _fail(where, "expected lowercase SHA-256 hex")
    return result


def _load_unique_json(path: Path, label: str) -> Mapping[str, Any]:
    def reject_duplicates(pairs: Sequence[Tuple[str, Any]]) -> Dict[str, Any]:
        result: Dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                _fail(label, f"duplicate field {key!r}")
            result[key] = value
        return result

    try:
        value = json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=reject_duplicates,
        )
    except ValidationError:
        raise
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ValidationError(f"cannot read {label} {path}: {exc}") from exc
    if not isinstance(value, dict):
        _fail(label, "expected an object")
    return value


def _case_map(manifest: Mapping[str, Any]) -> Dict[str, Mapping[str, Any]]:
    return {case["id"]: case for case in manifest["cases"]}


def _safe_component(value: str) -> str:
    prefix = re.sub(r"[^a-z0-9]+", "-", value.casefold()).strip("-")[:32] or "case"
    digest = hashlib.sha256(value.encode("utf-8")).hexdigest()[:12]
    return f"{prefix}-{digest}"


def _batch_bytes(nodes: Sequence[Mapping[str, Any]], edges: Sequence[Mapping[str, Any]]) -> bytes:
    lines = [stable_json({"version": 1})]
    lines.extend(stable_json(node) for node in nodes)
    lines.extend(stable_json(edge) for edge in edges)
    return ("\n".join(lines) + "\n").encode("utf-8")


def _hotpot_batch(
    source: Mapping[str, Any],
    case_id: str,
) -> Tuple[bytes, Dict[int, str], int, str]:
    raw_cases = source.get("cases")
    if not isinstance(raw_cases, list):
        _fail("HotpotQA source slice.cases", "expected an array")
    case = next((item for item in raw_cases if isinstance(item, dict) and item.get("id") == case_id), None)
    if case is None:
        _fail("HotpotQA source slice", f"case {case_id!r} is absent")
    documents = case.get("documents")
    if not isinstance(documents, list) or not documents:
        _fail(f"HotpotQA case {case_id}.documents", "expected a non-empty array")
    nodes: List[Mapping[str, Any]] = []
    edges: List[Mapping[str, Any]] = []
    logical: Dict[int, str] = {}
    next_node = 1
    next_edge = 1
    root_id = 0
    for doc_index, raw_document in enumerate(documents):
        document = _object(
            raw_document,
            f"HotpotQA case {case_id}.documents[{doc_index}]",
            ("id", "title", "sentences"),
        )
        title = _string(document["title"], f"HotpotQA document[{doc_index}].title")
        document_id = next_node
        next_node += 1
        if root_id == 0:
            root_id = document_id
        nodes.append(
            {
                "op": "node",
                "id": document_id,
                "kind": "concept",
                "name": f"Document title: {title}",
            }
        )
        logical[document_id] = _string(document["id"], f"HotpotQA document[{doc_index}].id")
        sentences = document["sentences"]
        if not isinstance(sentences, list) or not sentences:
            _fail(f"HotpotQA document[{doc_index}].sentences", "expected a non-empty array")
        for sentence_index, raw_sentence in enumerate(sentences):
            sentence = _object(
                raw_sentence,
                f"HotpotQA document[{doc_index}].sentences[{sentence_index}]",
                ("id", "sentence_id", "text"),
            )
            source_id = _string(sentence["id"], "HotpotQA sentence.id")
            sentence_id = _integer(sentence["sentence_id"], "HotpotQA sentence.sentence_id")
            text = _text(sentence["text"], "HotpotQA sentence.text")
            node_id = next_node
            next_node += 1
            nodes.append(
                {
                    "op": "node",
                    "id": node_id,
                    "kind": "evidence",
                    "name": f"{title} sentence {sentence_id}: {text}",
                }
            )
            logical[node_id] = source_id
            edges.append(
                {
                    "op": "edge",
                    "id": next_edge,
                    "src": document_id,
                    "rel": "based_on",
                    "dst": node_id,
                }
            )
            next_edge += 1
    return _batch_bytes(nodes, edges), logical, root_id, case_id


def _longmem_batch(
    source: Mapping[str, Any],
    case_id: str,
) -> Tuple[bytes, Dict[int, str], int, str]:
    raw_cases = source.get("cases")
    if not isinstance(raw_cases, list):
        _fail("LongMemEval-S source slice.cases", "expected an array")
    case = next((item for item in raw_cases if isinstance(item, dict) and item.get("id") == case_id), None)
    if case is None:
        _fail("LongMemEval-S source slice", f"case {case_id!r} is absent")
    sessions = case.get("sessions")
    if not isinstance(sessions, list) or not sessions:
        _fail(f"LongMemEval-S case {case_id}.sessions", "expected a non-empty array")
    nodes: List[Mapping[str, Any]] = []
    edges: List[Mapping[str, Any]] = []
    logical: Dict[int, str] = {}
    next_node = 1
    next_edge = 1
    root_id = 0
    for session_index, raw_session in enumerate(sessions):
        session = _object(
            raw_session,
            f"LongMemEval-S case {case_id}.sessions[{session_index}]",
            ("id", "source_position", "date", "turns"),
        )
        source_session_id = _string(session["id"], "LongMemEval-S session.id")
        date = _string(session["date"], "LongMemEval-S session.date")
        turns = session["turns"]
        if not isinstance(turns, list) or not turns:
            _fail(f"LongMemEval-S session[{session_index}].turns", "expected a non-empty array")
        joined_turns: List[str] = []
        for turn_index, raw_turn in enumerate(turns):
            turn = _object(
                raw_turn,
                f"LongMemEval-S session[{session_index}].turns[{turn_index}]",
                ("id", "turn_index", "role", "content"),
            )
            role = _string(turn["role"], "LongMemEval-S turn.role")
            content = _text(turn["content"], "LongMemEval-S turn.content")
            joined_turns.append(f"{role}: {content}")
        session_node_id = next_node
        next_node += 1
        if root_id == 0:
            root_id = session_node_id
        nodes.append(
            {
                "op": "node",
                "id": session_node_id,
                "kind": "concept",
                "name": f"Session {date}\n" + "\n".join(joined_turns),
            }
        )
        logical[session_node_id] = source_session_id
        for turn_index, raw_turn in enumerate(turns):
            role = str(raw_turn["role"])
            content = str(raw_turn["content"])
            node_id = next_node
            next_node += 1
            nodes.append(
                {
                    "op": "node",
                    "id": node_id,
                    "kind": "evidence",
                    "name": f"Session {date} {role}: {content}",
                }
            )
            # Retrieval is scored at the official session unit, not turn unit.
            logical[node_id] = source_session_id
            edges.append(
                {
                    "op": "edge",
                    "id": next_edge,
                    "src": session_node_id,
                    "rel": "based_on",
                    "dst": node_id,
                }
            )
            next_edge += 1
    return _batch_bytes(nodes, edges), logical, root_id, case_id


def _procedural_batch(
    source: Mapping[str, Any],
    manifest: Mapping[str, Any],
    requested_case_id: str,
) -> Tuple[bytes, Dict[int, str], int, str]:
    raw_families = source.get("families")
    if not isinstance(raw_families, list):
        _fail("procedural source slice.families", "expected an array")
    family = next(
        (
            item
            for item in raw_families
            if isinstance(item, dict)
            and isinstance(item.get("cases"), list)
            and any(
                isinstance(case, dict) and case.get("id") == requested_case_id
                for case in item["cases"]
            )
        ),
        None,
    )
    if family is None:
        _fail("procedural source slice", f"case {requested_case_id!r} is absent")
    family_cases = family["cases"]
    online = next((case for case in family_cases if case.get("split") == "online"), None)
    offline = next((case for case in family_cases if case.get("split") == "offline"), None)
    if online is None or offline is None:
        _fail("procedural source slice", "family must have online and offline cases")
    family_id = _string(family.get("id"), "procedural family.id")
    evidence_id = _string(family.get("procedure_evidence_id"), "procedural family.procedure_evidence_id")
    online_prompt = _string(online.get("prompt"), "procedural online prompt")
    concept_text = (
        f"Reusable procedure learned from completed {family_id} online task. "
        f"Preserve every compatibility constraint and update every named layer. {online_prompt}"
    )
    nodes = [
        {"op": "node", "id": 1, "kind": "concept", "name": concept_text},
        {
            "op": "node",
            "id": 2,
            "kind": "evidence",
            "name": f"Completed online execution evidence: {online_prompt}",
        },
    ]
    edges = [{"op": "edge", "id": 1, "src": 1, "rel": "based_on", "dst": 2}]
    logical = {1: evidence_id, 2: str(online["id"])}
    return _batch_bytes(nodes, edges), logical, 1, str(offline["id"])


def build_case_batch(
    source: Mapping[str, Any],
    manifest: Mapping[str, Any],
    case_id: str,
) -> Tuple[bytes, Dict[int, str], int, str]:
    adapter_id = manifest["dataset"]["adapter_id"]
    if adapter_id == "hotpotqa-distractor":
        return _hotpot_batch(source, case_id)
    if adapter_id == "longmemeval-s-cleaned":
        return _longmem_batch(source, case_id)
    if adapter_id == "coding-intent-families":
        return _procedural_batch(source, manifest, case_id)
    _fail("memory manifest.dataset.adapter_id", f"unsupported adapter {adapter_id!r}")


def _tree_digest(root: Path, *, normalize_store_manifest: bool = False) -> str:
    records: List[Mapping[str, Any]] = []
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root).as_posix()
        if path.is_symlink():
            _fail("local TinyKG store", f"unexpected symlink {relative!r}")
        if path.is_dir():
            records.append({"path": relative, "type": "directory"})
            continue
        if not path.is_file() or path.name.endswith(".lock"):
            continue
        data = path.read_bytes()
        if normalize_store_manifest and relative == ".tinykg/store-manifest.json":
            try:
                manifest = json.loads(data)
            except (UnicodeError, json.JSONDecodeError) as exc:
                raise ValidationError(f"local TinyKG store manifest is invalid: {exc}") from exc
            migration = manifest.get("migration") if isinstance(manifest, dict) else None
            if isinstance(migration, dict) and "recorded_ns" in migration:
                migration["recorded_ns"] = 0
            data = stable_artifact_bytes(manifest)
        records.append(
            {
                "path": relative,
                "type": "file",
                "bytes": len(data),
                "sha256": hashlib.sha256(data).hexdigest(),
            }
        )
    return hashlib.sha256(stable_json(records).encode("utf-8")).hexdigest()


def _write_atomic(path: Path, value: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb",
            dir=path.parent,
            prefix=f".{path.name}.",
            suffix=".tmp",
            delete=False,
        ) as handle:
            temporary = Path(handle.name)
            handle.write(stable_artifact_bytes(value))
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass


class LocalTinyKg:
    def __init__(
        self,
        binary: Path,
        *,
        expected_sha256: str,
        run_dir: Path,
        timeout_seconds: int = 60,
        resume: bool = False,
    ) -> None:
        self.binary = binary.expanduser().resolve()
        if not self.binary.is_file() or not os.access(self.binary, os.X_OK):
            _fail("local TinyKG binary", f"not an executable file: {self.binary}")
        self.binary_sha256 = file_sha256(self.binary)
        if self.binary_sha256 != _hash(expected_sha256, "expected local TinyKG binary SHA-256"):
            _fail("local TinyKG binary", "SHA-256 mismatch")
        self.run_dir = run_dir.expanduser().resolve()
        self.store_root = self.run_dir / "stores"
        self.batch_root = self.run_dir / "batches"
        self.sealed_home = self.run_dir / "sealed-home"
        self.child_tmp = self.run_dir / "tmp"
        directories = (self.store_root, self.batch_root, self.sealed_home, self.child_tmp)
        if resume:
            if not self.run_dir.is_dir() or self.run_dir.is_symlink():
                _fail("local TinyKG resume directory", "must be an existing real directory")
            for directory in directories:
                if not directory.is_dir() or directory.is_symlink():
                    _fail("local TinyKG resume directory", f"invalid layout entry {directory.name!r}")
        else:
            if self.run_dir.exists():
                _fail("local TinyKG run directory", "must not already exist")
            self.run_dir.mkdir(parents=True)
            for directory in directories:
                directory.mkdir()
        self.timeout_seconds = timeout_seconds
        self.parent_tinykg_env_keys = sorted(
            key
            for key in os.environ
            if key.startswith("TINYKG_") or key.startswith("METACODES_KG_")
        )
        self.commands: List[Mapping[str, Any]] = []

    def _environment(self) -> Dict[str, str]:
        env = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith("TINYKG_")
            and not key.startswith("METACODES_KG_")
            and key not in {"HOME", "TMPDIR", "TMP", "TEMP"}
        }
        env.update(
            {
                "HOME": str(self.sealed_home),
                "TMPDIR": str(self.child_tmp),
                "TMP": str(self.child_tmp),
                "TEMP": str(self.child_tmp),
                "LC_ALL": "C",
                "LANG": "C",
            }
        )
        return env

    def _normalized(self, value: str) -> str:
        return value.replace(str(self.run_dir), "<RUN_DIR>").replace(str(self.binary), "<TINYKG_BINARY>")

    def command(self, action: str, store: Path, extra: Sequence[str]) -> str:
        if action not in {
            "init",
            "apply",
            "search",
            "rebuild-text",
            "neighbors",
            "store-info",
            "import-md-doc",
            "add-edge",
        }:
            _fail("local TinyKG command", f"unsupported action {action!r}")
        resolved_store = store.resolve()
        try:
            resolved_store.relative_to(self.store_root)
        except ValueError as exc:
            raise ValidationError("local TinyKG store escapes the isolated store root") from exc
        argv = [str(self.binary), action, str(resolved_store), *map(str, extra)]
        env = self._environment()
        leaked = sorted(
            key
            for key in env
            if key.startswith("TINYKG_") or key.startswith("METACODES_KG_")
        )
        if leaked:
            _fail("local TinyKG child environment", f"contains forbidden keys: {leaked}")
        try:
            completed = subprocess.run(
                argv,
                cwd=self.run_dir,
                env=env,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                timeout=self.timeout_seconds,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise ValidationError(f"local TinyKG {action} failed to execute: {exc}") from exc
        normalized_stdout = self._normalized(completed.stdout)
        normalized_stderr = self._normalized(completed.stderr)
        self.commands.append(
            {
                "action": action,
                # argv entries are paths: canonical separators after redaction keep the
                # trace host-independent (no-op on POSIX). stdout/stderr are hashed as
                # emitted; rewriting backslashes there would corrupt JSON escapes.
                "argv": [self._normalized(item).replace(os.sep, "/") for item in argv],
                "exit_code": completed.returncode,
                "stdout_sha256": hashlib.sha256(normalized_stdout.encode("utf-8")).hexdigest(),
                "stderr_sha256": hashlib.sha256(normalized_stderr.encode("utf-8")).hexdigest(),
                "child_tinykg_env_keys": leaked,
            }
        )
        if completed.returncode != 0:
            _fail(
                f"local TinyKG {action}",
                f"exit={completed.returncode}, stderr={normalized_stderr.strip()!r}",
            )
        return completed.stdout


def _store_info(text: str) -> Mapping[str, str]:
    result: Dict[str, str] = {}
    for line in text.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        result[key] = value
    for required in ("nodes", "edges", "storage_format_version"):
        if required not in result:
            _fail("local TinyKG store-info", f"missing {required!r}")
    return result


def _search_hits(text: str, logical_ids: Mapping[int, str]) -> List[Mapping[str, Any]]:
    try:
        value = json.loads(text)
    except json.JSONDecodeError as exc:
        raise ValidationError(f"local TinyKG search returned invalid JSON: {exc}") from exc
    hits = value.get("hits") if isinstance(value, dict) else None
    if not isinstance(hits, list):
        _fail("local TinyKG search", "missing hits array")
    result: List[Mapping[str, Any]] = []
    for raw_hit in hits:
        node = raw_hit.get("node") if isinstance(raw_hit, dict) else None
        node_id = node.get("id") if isinstance(node, dict) else None
        if not isinstance(node_id, int) or isinstance(node_id, bool):
            _fail("local TinyKG search hit", "missing numeric node id")
        result.append(
            {
                "node_id": node_id,
                "logical_id": logical_ids.get(node_id),
                "score": raw_hit.get("score"),
            }
        )
    return result


def run_local_tinykg_smoke(
    *,
    binary: Path,
    expected_binary_sha256: str,
    source_path: Path,
    manifest_path: Path,
    run_dir: Path,
    output_path: Path,
    case_limit: int = 1,
) -> Mapping[str, Any]:
    if not isinstance(case_limit, int) or isinstance(case_limit, bool) or case_limit < 1:
        _fail("local TinyKG smoke.case_limit", "expected integer >= 1")
    source = _load_unique_json(source_path, "memory source slice")
    manifest = load_manifest(manifest_path)
    adapter_id = manifest["dataset"]["adapter_id"]
    if adapter_id not in SUPPORTED_ADAPTERS:
        _fail("memory manifest.dataset.adapter_id", f"unsupported adapter {adapter_id!r}")
    observed_source_sha256 = file_sha256(source_path)
    if observed_source_sha256 != manifest["dataset"]["source_sha256"]:
        _fail("memory source slice", "SHA-256 does not match manifest")
    if source.get("adapter_id") != adapter_id or source.get("adapter_revision") != manifest["dataset"]["adapter_revision"]:
        _fail("memory source slice", "adapter identity does not match manifest")

    resolved_run_dir = run_dir.expanduser().resolve()
    resolved_output = output_path.expanduser().resolve()
    try:
        resolved_output.relative_to(resolved_run_dir)
    except ValueError as exc:
        raise ValidationError("local TinyKG smoke output must stay inside the fresh run directory") from exc
    local = LocalTinyKg(
        binary,
        expected_sha256=expected_binary_sha256,
        run_dir=resolved_run_dir,
    )
    manifest_cases = list(manifest["cases"])
    if adapter_id == "coding-intent-families":
        manifest_cases = [case for case in manifest_cases if case["split"] == "online"]
    if case_limit > len(manifest_cases):
        _fail(
            "local TinyKG smoke.case_limit",
            f"requested {case_limit} cases but only {len(manifest_cases)} are eligible",
        )
    selected_cases = manifest_cases[:case_limit]
    if not selected_cases:
        _fail("local TinyKG smoke", "no eligible cases")
    cases_by_id = _case_map(manifest)
    case_traces: List[Mapping[str, Any]] = []
    for manifest_case in selected_cases:
        requested_case_id = manifest_case["id"]
        batch, logical_ids, root_node_id, query_case_id = build_case_batch(
            source,
            manifest,
            requested_case_id,
        )
        query_case = cases_by_id.get(query_case_id)
        if query_case is None:
            _fail("local TinyKG smoke", f"query case {query_case_id!r} is absent from manifest")
        component = _safe_component(requested_case_id)
        store = local.store_root / adapter_id / f"{component}.kg"
        store.parent.mkdir(parents=True, exist_ok=True)
        batch_path = local.batch_root / adapter_id / f"{component}.jsonl"
        batch_path.parent.mkdir(parents=True, exist_ok=True)
        batch_path.write_bytes(batch)
        local.command("init", store, ())
        apply_output = local.command("apply", store, (str(batch_path),))
        raw_before_reads = _tree_digest(store)
        graph_revision_before = _tree_digest(store, normalize_store_manifest=True)
        info_before = _store_info(local.command("store-info", store, ()))
        prompt = _string(query_case["prompt"], f"manifest case {query_case_id}.prompt")
        search_output = local.command(
            "search",
            store,
            (prompt, "--profile", "agent-memory", "--limit", "10", "--format", "json"),
        )
        hits = _search_hits(search_output, logical_ids)
        neighbor_output = local.command(
            "neighbors",
            store,
            (str(root_node_id), "--depth", "1", "--format", "json"),
        )
        try:
            neighbor_packet = json.loads(neighbor_output)
        except json.JSONDecodeError as exc:
            raise ValidationError(f"local TinyKG neighbors returned invalid JSON: {exc}") from exc
        info_after = _store_info(local.command("store-info", store, ()))
        raw_after_reads = _tree_digest(store)
        graph_revision_after = _tree_digest(store, normalize_store_manifest=True)
        if raw_before_reads != raw_after_reads:
            _fail(
                f"local TinyKG case {requested_case_id}",
                "read-only search/traversal changed store contents",
            )
        if info_before["nodes"] != info_after["nodes"] or info_before["edges"] != info_after["edges"]:
            _fail(f"local TinyKG case {requested_case_id}", "read-only node/edge counts changed")
        if not isinstance(neighbor_packet, dict) or not neighbor_packet.get("nodes"):
            _fail(f"local TinyKG case {requested_case_id}", "graph traversal returned no nodes")
        case_traces.append(
            {
                "case_id": requested_case_id,
                "query_case_id": query_case_id,
                "store": store.relative_to(local.run_dir).as_posix(),
                "batch": {
                    "path": batch_path.relative_to(local.run_dir).as_posix(),
                    "sha256": hashlib.sha256(batch).hexdigest(),
                    "apply_stdout_sha256": hashlib.sha256(
                        local._normalized(apply_output).encode("utf-8")
                    ).hexdigest(),
                },
                "store_info": {
                    "nodes": int(info_after["nodes"]),
                    "edges": int(info_after["edges"]),
                    "storage_format_version": int(info_after["storage_format_version"]),
                },
                "graph_revision_before_reads": graph_revision_before,
                "graph_revision_after_reads": graph_revision_after,
                "read_only_preserved": True,
                "retrieval": {
                    "query_sha256": hashlib.sha256(prompt.encode("utf-8")).hexdigest(),
                    "hit_count": len(hits),
                    "hits": hits,
                },
                "graph_probe": {
                    "root_node_id": root_node_id,
                    "node_count": neighbor_packet.get("summary", {}).get("node_count"),
                    "edge_count": neighbor_packet.get("summary", {}).get("edge_count"),
                    "truncated": neighbor_packet.get("summary", {}).get("truncated"),
                },
            }
        )
    trace: Mapping[str, Any] = {
        "schema_version": TRACE_SCHEMA_VERSION,
        "mode": "local-tinykg-memory-isolation-smoke",
        "identity": {
            "adapter_id": adapter_id,
            "adapter_revision": manifest["dataset"]["adapter_revision"],
            "source_sha256": observed_source_sha256,
            "manifest_file_sha256": file_sha256(manifest_path),
            "tinykg_binary_sha256": local.binary_sha256,
        },
        "isolation": {
            "direct_cli": True,
            "skill_harness_invocations": 0,
            "remote_api_calls": 0,
            "remote_store_writes": 0,
            "child_home": "sealed-home",
            "parent_tinykg_env_keys_detected": local.parent_tinykg_env_keys,
            "removed_environment_keys": list(REMOTE_ENV_KEYS),
            "stores_are_below_run_dir": True,
        },
        "cases": case_traces,
        "commands": local.commands,
    }
    _write_atomic(resolved_output, trace)
    return trace
