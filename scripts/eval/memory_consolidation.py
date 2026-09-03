"""Host-owned execution-episode consolidation and replay validation."""

from __future__ import annotations

import difflib
import hashlib
import json
import os
import re
import stat
import tempfile
from pathlib import Path, PurePosixPath
from typing import TYPE_CHECKING, Any, Dict, List, Mapping, Tuple

from .model import ValidationError, O_BINARY, fsync_directory, open_nofollow

if TYPE_CHECKING:
    from .memory_tinykg_local import LocalTinyKg


SCHEMA_VERSION = "metacodes-execution-episode-consolidation-v1"
MAX_DIFF_BYTES = 64 * 1024
MAX_EPISODE_BYTES = 256 * 1024
HEX64 = re.compile(r"^[0-9a-f]{64}$")
EPISODE_NAME = re.compile(r"^execution-episode-[0-9a-f]{12}\.md$")
RECEIPT_KEYS = (
    "schema_version",
    "trigger",
    "projection",
    "status",
    "source_events_sha256",
    "episode_file",
    "episode_sha256",
    "memory_index_sha256",
    "changed_files",
    "outcome",
    "truncated",
    "tinykg_document_id",
    "tinykg_projection_node_ids",
    "tinykg_revision_before",
    "tinykg_revision_after",
    "tinykg_raw_digest_before",
    "tinykg_raw_digest_after",
    "tinykg_nodes_before",
    "tinykg_nodes_after",
    "tinykg_edges_before",
    "tinykg_edges_after",
)
TINYKG_KEYS = RECEIPT_KEYS[11:]


def _fail(where: str, message: str) -> None:
    raise ValidationError(f"{where}: {message}")


def _hash_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _hash(value: Any, where: str) -> str:
    if not isinstance(value, str) or HEX64.fullmatch(value) is None:
        _fail(where, "expected a lowercase SHA-256")
    return value


def _integer(value: Any, where: str, *, minimum: int = 0) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < minimum:
        _fail(where, f"expected integer >= {minimum}")
    return value


def _relative(value: Any, where: str) -> PurePosixPath:
    if not isinstance(value, str):
        _fail(where, "expected a relative POSIX path")
    path = PurePosixPath(value)
    if (
        path.is_absolute()
        or value != path.as_posix()
        or any(part in {"", ".", ".."} for part in path.parts)
    ):
        _fail(where, "expected a normalized relative POSIX path")
    return path


def _bounded_utf8(value: str, limit: int) -> Tuple[str, bool]:
    encoded = value.encode("utf-8")
    if len(encoded) <= limit:
        return value, False
    return encoded[:limit].decode("utf-8", errors="ignore"), True


def _write_new(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | O_BINARY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        fd = os.open(path, flags, 0o600)
    except OSError as exc:
        raise ValidationError(f"cannot create fresh memory artifact {path}: {exc}") from exc
    try:
        offset = 0
        while offset < len(payload):
            written = os.write(fd, payload[offset:])
            if written <= 0:
                raise OSError("short write")
            offset += written
        os.fsync(fd)
    except BaseException:
        try:
            path.unlink()
        except OSError:
            pass
        raise
    finally:
        os.close(fd)
    fsync_directory(path.parent)


def _read_regular_file(path: Path, where: str) -> bytes:
    flags = os.O_RDONLY
    try:
        fd = open_nofollow(path, flags)
    except OSError as exc:
        raise ValidationError(f"{where}: cannot open regular file: {exc}") from exc
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            _fail(where, "expected a single-link regular file")
        chunks: List[bytes] = []
        while True:
            chunk = os.read(fd, 1024 * 1024)
            if not chunk:
                return b"".join(chunks)
            chunks.append(chunk)
    except OSError as exc:
        raise ValidationError(f"{where}: cannot read regular file: {exc}") from exc
    finally:
        os.close(fd)


def _replace_regular_file(path: Path, payload: bytes) -> None:
    if path.exists() or path.is_symlink():
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode) or info.st_nlink != 1:
            _fail("memory consolidation", f"refuses unsafe target {path.name!r}")
    fd, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        if hasattr(os, "fchmod"):  # absent on Windows
            os.fchmod(fd, 0o600)
        offset = 0
        while offset < len(payload):
            written = os.write(fd, payload[offset:])
            if written <= 0:
                raise OSError("short write")
            offset += written
        os.fsync(fd)
        os.close(fd)
        fd = -1
        os.replace(temporary, path)
        fsync_directory(path.parent)
    except BaseException:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
        raise
    finally:
        if fd >= 0:
            os.close(fd)


def execution_episode_document(
    *,
    prompt: str,
    stop_reason: str,
    deterministic_success: bool | None,
    baseline: Mapping[str, str],
    candidate: Mapping[str, str],
    source_events_sha256: str,
) -> Tuple[bytes, List[str], bool]:
    changed = sorted(
        relative for relative, before in baseline.items() if candidate.get(relative) != before
    )
    sections = [
        "---",
        f"schema_version: {SCHEMA_VERSION}",
        "memory_type: episodic",
        f"outcome: {'success' if deterministic_success else 'failure' if deterministic_success is False else 'unknown'}",
        f"stop_reason: {stop_reason}",
        f"source_events_sha256: {source_events_sha256}",
        "---",
        "",
        "# Execution episode",
        "",
        "## Task",
        "",
        prompt.strip(),
        "",
        "## Observed workspace changes",
        "",
    ]
    truncated = False
    if not changed:
        sections.append("No tracked file content changed during this run.")
    for relative in changed:
        delta = "".join(
            difflib.unified_diff(
                baseline[relative].splitlines(keepends=True),
                candidate[relative].splitlines(keepends=True),
                fromfile=f"a/{relative}",
                tofile=f"b/{relative}",
                lineterm="\n",
            )
        )
        delta, file_truncated = _bounded_utf8(delta, MAX_DIFF_BYTES)
        truncated = truncated or file_truncated
        sections.extend((f"### `{relative}`", "", "```diff", delta.rstrip(), "```", ""))
    document = "\n".join(sections).rstrip() + "\n"
    document, document_truncated = _bounded_utf8(document, MAX_EPISODE_BYTES)
    truncated = truncated or document_truncated
    if document_truncated:
        document = document.rstrip() + "\n\n[episode truncated by host bound]\n"
    return document.encode("utf-8"), changed, truncated


def _projection_node_ids(
    local: LocalTinyKg,
    store: Path,
    document_id: int,
) -> List[int]:
    raw = local.command(
        "neighbors",
        store,
        (
            str(document_id),
            "--format",
            "json",
            "--meta",
            "--depth",
            "8",
            "--max-nodes",
            "4096",
            "--max-edges",
            "8192",
            "--max-chars",
            str(MAX_EPISODE_BYTES),
        ),
    )
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ValidationError(f"memory consolidation: invalid TinyKG projection: {exc}") from exc
    if not isinstance(payload, dict) or payload.get("schema_version") != "tinykg-agent-retrieval-v1":
        _fail("memory consolidation", "TinyKG projection has an unsupported envelope")
    summary = payload.get("summary")
    if not isinstance(summary, dict) or summary.get("truncated") is not False:
        _fail("memory consolidation", "TinyKG projection traversal was truncated")
    nodes = payload.get("nodes")
    if not isinstance(nodes, list):
        _fail("memory consolidation", "TinyKG projection omitted nodes")
    node_ids: List[int] = []
    for index, node in enumerate(nodes):
        node_id = node.get("id") if isinstance(node, dict) else None
        if not isinstance(node_id, int) or isinstance(node_id, bool) or node_id < 1:
            _fail("memory consolidation", f"TinyKG projection node {index} has no stable id")
        node_ids.append(node_id)
    node_ids = sorted(set(node_ids))
    if document_id not in node_ids:
        _fail("memory consolidation", "TinyKG projection omitted its document root")
    return node_ids


def commit_execution_episode(
    *,
    local: LocalTinyKg,
    memory_dir: Path,
    memory_index: Path,
    store: Path | None,
    prompt: str,
    stop_reason: str,
    deterministic_success: bool | None,
    baseline: Mapping[str, str],
    candidate: Mapping[str, str],
    source_events_sha256: str,
) -> Mapping[str, Any]:
    # Lazy import keeps the validator independent of the adapter/replay import
    # cycle while the production writer still uses the canonical store helpers.
    from .memory_tinykg_local import _store_info, _tree_digest

    tinykg: Dict[str, Any] = {key: None for key in TINYKG_KEYS}
    if store is not None:
        tinykg["tinykg_revision_before"] = _tree_digest(
            store, normalize_store_manifest=True
        )
        tinykg["tinykg_raw_digest_before"] = _tree_digest(store)
        before_info = _store_info(local.command("store-info", store, ()))
        tinykg["tinykg_nodes_before"] = int(before_info["nodes"])
        tinykg["tinykg_edges_before"] = int(before_info["edges"])

    document, changed_files, truncated = execution_episode_document(
        prompt=prompt,
        stop_reason=stop_reason,
        deterministic_success=deterministic_success,
        baseline=baseline,
        candidate=candidate,
        source_events_sha256=source_events_sha256,
    )
    episode_sha256 = _hash_bytes(document)
    episode_name = f"execution-episode-{episode_sha256[:12]}.md"
    episode_path = memory_dir / episode_name
    _write_new(episode_path, document)
    prior_index = (
        _read_regular_file(memory_index, "pre-consolidation MEMORY.md")
        if memory_index.exists()
        else b""
    )
    summary, _ = _bounded_utf8(" ".join(prompt.split()), 180)
    index_line = f"- [Execution episode]({episode_name}) — {summary}\n".encode("utf-8")
    if episode_name.encode("utf-8") in prior_index:
        _fail("memory consolidation", "fresh episode already appears in MEMORY.md")
    index_payload = prior_index
    if index_payload and not index_payload.endswith(b"\n"):
        index_payload += b"\n"
    index_payload += index_line
    _replace_regular_file(memory_index, index_payload)

    if store is not None:
        imported = local.command(
            "import-md-doc",
            store,
            (str(episode_path), "--source-label", "execution-episode"),
        )
        match = re.search(r"\bdocument=([0-9]+)\b", imported)
        if match is None:
            _fail("memory consolidation", "TinyKG import returned no document id")
        tinykg["tinykg_document_id"] = int(match.group(1))
        local.command("add-edge", store, ("1", "contain", str(tinykg["tinykg_document_id"])))
        tinykg["tinykg_projection_node_ids"] = _projection_node_ids(
            local,
            store,
            int(tinykg["tinykg_document_id"]),
        )
        # TinyKG deliberately keeps BM25 as a derived index.  The online
        # episode import makes that catalog stale; publish it at the explicit
        # consolidation boundary so the next offline rollout can actually
        # exercise lexical recall instead of deterministically receiving
        # `Unsupported` from an unwarmed store.
        local.command("rebuild-text", store, ())
        tinykg["tinykg_revision_after"] = _tree_digest(
            store, normalize_store_manifest=True
        )
        tinykg["tinykg_raw_digest_after"] = _tree_digest(store)
        after_info = _store_info(local.command("store-info", store, ()))
        if after_info.get("text_current") != "1" or after_info.get("text_stale") != "0":
            _fail("memory consolidation", "TinyKG text catalog was not durably published")
        tinykg["tinykg_nodes_after"] = int(after_info["nodes"])
        tinykg["tinykg_edges_after"] = int(after_info["edges"])
        if (
            tinykg["tinykg_revision_after"] == tinykg["tinykg_revision_before"]
            or tinykg["tinykg_raw_digest_after"] == tinykg["tinykg_raw_digest_before"]
            or tinykg["tinykg_nodes_after"] <= tinykg["tinykg_nodes_before"]
            or tinykg["tinykg_edges_after"] <= tinykg["tinykg_edges_before"]
        ):
            _fail("memory consolidation", "TinyKG import was not durably observable")

    return {
        "schema_version": SCHEMA_VERSION,
        "trigger": "run_finished",
        "projection": "bounded_execution_episode",
        "status": "committed",
        "source_events_sha256": source_events_sha256,
        "episode_file": episode_name,
        "episode_sha256": episode_sha256,
        "memory_index_sha256": _hash_bytes(index_payload),
        "changed_files": changed_files,
        "outcome": (
            "success"
            if deterministic_success
            else "failure" if deterministic_success is False else "unknown"
        ),
        "truncated": truncated,
        **tinykg,
    }


def validate_receipt(
    raw: Any,
    *,
    required: bool,
    tinykg_enabled: bool,
    native_events_sha256: str,
    deterministic_success: bool | None,
    final_store_revision: str,
    final_raw_store_digest: str,
    where: str,
) -> Mapping[str, Any] | None:
    if not required:
        if raw is not None:
            _fail(where, "only online memory arms may consolidate")
        return None
    if not isinstance(raw, dict) or set(raw) != set(RECEIPT_KEYS):
        _fail(where, "expected an exact consolidation receipt")
    if raw["schema_version"] != SCHEMA_VERSION:
        _fail(f"{where}.schema_version", "unsupported receipt")
    if (
        raw["trigger"] != "run_finished"
        or raw["projection"] != "bounded_execution_episode"
        or raw["status"] != "committed"
    ):
        _fail(where, "invalid commit semantics")
    if _hash(raw["source_events_sha256"], f"{where}.source_events_sha256") != native_events_sha256:
        _fail(f"{where}.source_events_sha256", "does not bind native events")
    episode = _relative(raw["episode_file"], f"{where}.episode_file")
    if len(episode.parts) != 1 or EPISODE_NAME.fullmatch(episode.name) is None:
        _fail(f"{where}.episode_file", "must be a content-addressed memory basename")
    episode_sha = _hash(raw["episode_sha256"], f"{where}.episode_sha256")
    if episode.name != f"execution-episode-{episode_sha[:12]}.md":
        _fail(f"{where}.episode_file", "does not bind episode content")
    _hash(raw["memory_index_sha256"], f"{where}.memory_index_sha256")
    changed = raw["changed_files"]
    if not isinstance(changed, list):
        _fail(f"{where}.changed_files", "expected an array")
    normalized = [
        _relative(value, f"{where}.changed_files[{index}]").as_posix()
        for index, value in enumerate(changed)
    ]
    if normalized != sorted(set(normalized)):
        _fail(f"{where}.changed_files", "must be sorted and unique")
    expected_outcome = (
        "success"
        if deterministic_success is True
        else "failure" if deterministic_success is False else "unknown"
    )
    if raw["outcome"] != expected_outcome:
        _fail(f"{where}.outcome", "does not bind validator outcome")
    if not isinstance(raw["truncated"], bool):
        _fail(f"{where}.truncated", "expected a boolean")

    if not tinykg_enabled:
        if any(raw[key] is not None for key in TINYKG_KEYS):
            _fail(where, "Markdown arm must use null TinyKG fields")
        return raw
    document_id = _integer(
        raw["tinykg_document_id"],
        f"{where}.tinykg_document_id",
        minimum=1,
    )
    projection_nodes = raw["tinykg_projection_node_ids"]
    if not isinstance(projection_nodes, list):
        _fail(f"{where}.tinykg_projection_node_ids", "expected an array")
    normalized_projection = [
        _integer(value, f"{where}.tinykg_projection_node_ids[{index}]", minimum=1)
        for index, value in enumerate(projection_nodes)
    ]
    if (
        not normalized_projection
        or normalized_projection != sorted(set(normalized_projection))
        or document_id not in normalized_projection
    ):
        _fail(
            f"{where}.tinykg_projection_node_ids",
            "must be sorted, unique, and include the document root",
        )
    for key in (
        "tinykg_revision_before",
        "tinykg_revision_after",
        "tinykg_raw_digest_before",
        "tinykg_raw_digest_after",
    ):
        _hash(raw[key], f"{where}.{key}")
    for key in (
        "tinykg_nodes_before",
        "tinykg_nodes_after",
        "tinykg_edges_before",
        "tinykg_edges_after",
    ):
        _integer(raw[key], f"{where}.{key}")
    if (
        raw["tinykg_revision_before"] == raw["tinykg_revision_after"]
        or raw["tinykg_raw_digest_before"] == raw["tinykg_raw_digest_after"]
        or raw["tinykg_nodes_after"] <= raw["tinykg_nodes_before"]
        or raw["tinykg_edges_after"] <= raw["tinykg_edges_before"]
    ):
        _fail(where, "TinyKG migration has no durable graph gain")
    if (
        raw["tinykg_revision_after"] != final_store_revision
        or raw["tinykg_raw_digest_after"] != final_raw_store_digest
    ):
        _fail(where, "TinyKG migration does not bind final store state")
    return raw


def validate_artifacts(
    rollout: Mapping[str, Any],
    memory_root: Path,
    where: str,
) -> None:
    consolidation = rollout.get("consolidation")
    if not isinstance(consolidation, dict):
        _fail(f"{where}.consolidation", "expected a committed receipt")
    episode = _relative(
        consolidation.get("episode_file"),
        f"{where}.consolidation.episode_file",
    )
    if len(episode.parts) != 1:
        _fail(f"{where}.consolidation.episode_file", "must be a basename")
    episode_path = memory_root / episode.name
    index_path = memory_root / "MEMORY.md"
    payloads: Dict[str, bytes] = {}
    for label, artifact in (("episode", episode_path), ("memory index", index_path)):
        try:
            info = artifact.lstat()
            if (
                stat.S_ISLNK(info.st_mode)
                or not stat.S_ISREG(info.st_mode)
                or info.st_nlink != 1
                or (os.name != "nt" and info.st_mode & 0o077)  # mode bits are synthetic on Windows
            ):
                _fail(
                    f"{where}.consolidation.{label}",
                    "expected a private single-link regular file",
                )
            artifact.resolve(strict=True).relative_to(memory_root.resolve(strict=True))
            payloads[label] = artifact.read_bytes()
        except (OSError, ValueError) as exc:
            raise ValidationError(
                f"{where}.consolidation.{label}: cannot re-open artifact: {exc}"
            ) from exc
    episode_payload = payloads["episode"]
    if _hash_bytes(episode_payload) != consolidation.get("episode_sha256"):
        _fail(f"{where}.consolidation.episode_sha256", "episode bytes drifted")
    if len(episode_payload) > MAX_EPISODE_BYTES + 64:
        _fail(f"{where}.consolidation.episode_file", "episode exceeds the host bound")
    try:
        episode_text = episode_payload.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ValidationError(
            f"{where}.consolidation.episode_file: episode is not UTF-8: {exc}"
        ) from exc
    required_lines = (
        f"schema_version: {SCHEMA_VERSION}",
        f"outcome: {consolidation.get('outcome')}",
        f"stop_reason: {rollout.get('stop_reason')}",
        f"source_events_sha256: {consolidation.get('source_events_sha256')}",
    )
    if any(line not in episode_text.splitlines() for line in required_lines):
        _fail(f"{where}.consolidation.episode_file", "episode metadata does not bind receipt")
    index_payload = payloads["memory index"]
    if _hash_bytes(index_payload) != consolidation.get("memory_index_sha256"):
        _fail(f"{where}.consolidation.memory_index_sha256", "MEMORY.md bytes drifted")
    try:
        index_text = index_payload.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ValidationError(
            f"{where}.consolidation.memory_index_sha256: MEMORY.md is not UTF-8: {exc}"
        ) from exc
    if index_text.count(f"]({episode.name})") != 1:
        _fail(
            f"{where}.consolidation.memory_index_sha256",
            "MEMORY.md does not uniquely reference the episode",
        )
