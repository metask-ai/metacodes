"""Shared machinery for the metacodes Harbor dataset adapters.

Python 3.9, standard library only: the `metacodes bench` workbench imports
these modules from its embedded runtime (scripts/bench_assets.zig).

What lives here:

* `Pin`: one pinned source file (URL at an immutable revision plus a content
  hash). `fetch` downloads it into a cache and fails closed on a mismatch.
* `RemoteZip`: reads single members of a large pinned zip through HTTP range
  requests, so an adapter can take a small subset without the whole archive.
* `prepare_dataset`: the idempotent prepare flow every adapter shares. A
  complete dataset is recognised from its marker and the tree hashes of its
  task directories without touching the network; anything else is rebuilt in
  a scratch directory and swapped in whole.
* `task_toml`: a deterministic writer for the Harbor 0.26 `task.toml` subset
  the adapters use, and `write_task` for one task directory.

The task layout follows Harbor 0.26 (github.com/harbor-framework/harbor tag
v0.26.0, commit 3cb627394b95d3ae605f31e0d694edf508cf4b7b):
src/harbor/models/task/paths.py (instruction.md, task.toml, environment/,
solution/solve.sh, tests/test.sh), src/harbor/models/task/config.py
(TaskConfig schema 1.4), src/harbor/models/trial/paths.py (reward at
/logs/verifier/reward.txt) and examples/tasks/sidecar-artifacts (separate
verifier built from tests/Dockerfile, artifacts re-materialised at their
source paths).
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import struct
import urllib.error
import urllib.request
import zlib
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple, Union

MARKER_NAME = ".metacodes-dataset.json"
CACHE_DIR_NAME = ".cache"
USER_AGENT = "metacodes-bench-adapter/1"
CHUNK = 1 << 20

# Harbor 0.26 task names: src/harbor/constants.py ORG_NAME_PATTERN.
TASK_ORG = "metacodes-bench"

# Base images, pinned by multi-arch index digest (linux/amd64 + linux/arm64).
PYTHON_312_IMAGE = (
    "python:3.12-slim-bookworm@sha256:935c3c5b12357a7e10caa9c1e6ca5692344d97cf229832ef584be2cec9fc03df"
)
PYTHON_310_IMAGE = (
    "python:3.10-slim-bookworm@sha256:5be5aaecb962a41567bc8041f1e9e3432cb085b037fe057f9a562630b2e4b370"
)


class SourceIntegrityError(RuntimeError):
    """A downloaded source did not match its pin; nothing was kept."""


class SourceUnavailableError(RuntimeError):
    """A pinned source could not be downloaded (network, auth, HTTP status)."""


@dataclass(frozen=True)
class Pin:
    """One source file at an immutable revision.

    Exactly one content check is set: `sha256` (preferred) or, for a gated
    file whose bytes could not be fetched when the adapter was written,
    `git_blob_sha1` (the object id the hosting git repository reports for
    the file at the pinned commit). `size`, when set, is checked too.
    """

    name: str
    url: str
    sha256: Optional[str] = None
    git_blob_sha1: Optional[str] = None
    size: Optional[int] = None
    hf_auth: bool = False

    def __post_init__(self) -> None:
        if (self.sha256 is None) == (self.git_blob_sha1 is None):
            raise ValueError(f"pin {self.name}: set exactly one of sha256 / git_blob_sha1")
        if "/" in self.name or self.name.startswith("."):
            raise ValueError(f"pin {self.name}: name must be a plain file name")

    def describe(self) -> Dict[str, object]:
        out: Dict[str, object] = {"url": self.url}
        if self.sha256:
            out["sha256"] = self.sha256
        if self.git_blob_sha1:
            out["git_blob_sha1"] = self.git_blob_sha1
        if self.size is not None:
            out["size"] = self.size
        return out


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(CHUNK), b""):
            digest.update(chunk)
    return digest.hexdigest()


def git_blob_sha1_file(path: Path) -> str:
    size = path.stat().st_size
    digest = hashlib.sha1(b"blob %d\0" % size)
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(CHUNK), b""):
            digest.update(chunk)
    return digest.hexdigest()


def huggingface_token() -> Optional[str]:
    """HF_TOKEN / HUGGING_FACE_HUB_TOKEN, else the huggingface-cli token file."""
    for name in ("HF_TOKEN", "HUGGING_FACE_HUB_TOKEN"):
        value = os.environ.get(name, "").strip()
        if value:
            return value
    home = os.environ.get("HF_HOME") or os.path.join(os.path.expanduser("~"), ".cache", "huggingface")
    try:
        token = Path(home, "token").read_text(encoding="utf-8").strip()
    except OSError:
        return None
    return token or None


def _request(url: str, *, hf_auth: bool = False, byte_range: Optional[Tuple[int, int]] = None) -> urllib.request.Request:
    headers = {"User-Agent": USER_AGENT}
    if byte_range is not None:
        headers["Range"] = "bytes=%d-%d" % byte_range
    if hf_auth:
        token = huggingface_token()
        if token is None:
            raise SourceUnavailableError(
                f"{url} is a gated Hugging Face file: accept its terms on huggingface.co "
                "and set HF_TOKEN (or run `huggingface-cli login`)"
            )
        headers["Authorization"] = "Bearer " + token
    return urllib.request.Request(url, headers=headers)


def _verify(pin: Pin, path: Path) -> Optional[str]:
    """None when `path` matches `pin`, else a description of the mismatch."""
    size = path.stat().st_size
    if pin.size is not None and size != pin.size:
        return f"size {size} != pinned {pin.size}"
    if pin.sha256 is not None:
        actual = sha256_file(path)
        if actual != pin.sha256:
            return f"sha256 {actual} != pinned {pin.sha256}"
    if pin.git_blob_sha1 is not None:
        actual = git_blob_sha1_file(path)
        if actual != pin.git_blob_sha1:
            return f"git blob sha1 {actual} != pinned {pin.git_blob_sha1}"
    return None


def fetch(pin: Pin, cache_dir: Path) -> Path:
    """The verified local copy of `pin`, downloading it once into `cache_dir`.

    A cached file that no longer matches is deleted and fetched again; a
    download that does not match is deleted and raises SourceIntegrityError.
    """
    cache_dir.mkdir(parents=True, exist_ok=True)
    target = cache_dir / pin.name
    if target.is_file():
        if _verify(pin, target) is None:
            return target
        target.unlink()
    partial = cache_dir / (pin.name + ".partial-%d" % os.getpid())
    try:
        try:
            with urllib.request.urlopen(_request(pin.url, hf_auth=pin.hf_auth), timeout=120) as response, open(
                partial, "wb"
            ) as out:
                shutil.copyfileobj(response, out, CHUNK)
        except urllib.error.HTTPError as error:
            raise SourceUnavailableError(f"{pin.url}: HTTP {error.code}") from error
        except (urllib.error.URLError, OSError) as error:
            raise SourceUnavailableError(f"{pin.url}: {error}") from error
        problem = _verify(pin, partial)
        if problem is not None:
            raise SourceIntegrityError(f"{pin.name} from {pin.url}: {problem}")
        os.replace(partial, target)
    finally:
        if partial.exists():
            partial.unlink()
    return target


# --- remote zip ------------------------------------------------------------


class RangeSource:
    """Random access to the bytes of one remote (or local) file."""

    size: int

    def read(self, offset: int, length: int) -> bytes:  # pragma: no cover - interface
        raise NotImplementedError


class HttpRangeSource(RangeSource):
    def __init__(self, url: str, size: int, *, hf_auth: bool = False) -> None:
        self.url = url
        self.size = size
        self.hf_auth = hf_auth
        self._resolved: Optional[str] = None

    def _target(self) -> str:
        """The redirect target (a CDN URL), resolved once instead of per read."""
        if self._resolved is None:
            request = _request(self.url, hf_auth=self.hf_auth, byte_range=(0, 0))
            try:
                with urllib.request.urlopen(request, timeout=60) as response:
                    self._resolved = response.geturl()
            except (urllib.error.URLError, OSError):
                return self.url
        return self._resolved

    def read(self, offset: int, length: int) -> bytes:
        if length <= 0:
            return b""
        end = min(self.size, offset + length) - 1
        last: Optional[BaseException] = None
        for attempt in range(5):
            if attempt == 2:
                self._resolved = None  # a signed CDN URL may have expired
            target = self._target()
            request = _request(target, hf_auth=self.hf_auth and target == self.url, byte_range=(offset, end))
            try:
                with urllib.request.urlopen(request, timeout=60) as response:
                    if response.status != 206:
                        raise SourceUnavailableError(f"{self.url}: range request answered {response.status}")
                    data = response.read()
            except urllib.error.HTTPError as error:
                if error.code < 500 and error.code != 403:
                    raise SourceUnavailableError(f"{self.url}: HTTP {error.code}") from error
                last = error
                self._resolved = None
                continue
            except (urllib.error.URLError, OSError) as error:
                last = error
                continue
            if len(data) != end - offset + 1:
                raise SourceUnavailableError(f"{self.url}: short range read at {offset}")
            return data
        raise SourceUnavailableError(f"{self.url}: {last}") from last


class FileRangeSource(RangeSource):
    def __init__(self, path: Path) -> None:
        self.path = path
        self.size = path.stat().st_size

    def read(self, offset: int, length: int) -> bytes:
        with open(self.path, "rb") as handle:
            handle.seek(offset)
            return handle.read(max(0, min(length, self.size - offset)))


@dataclass(frozen=True)
class ZipMember:
    name: str
    offset: int
    compressed_size: int
    size: int
    method: int
    crc32: int


class RemoteZip:
    """Members of a classic (non-zip64) zip archive read by byte range."""

    def __init__(self, source: RangeSource) -> None:
        self.source = source
        tail_len = min(source.size, 65536 + 22)
        tail = source.read(source.size - tail_len, tail_len)
        eocd = tail.rfind(b"PK\x05\x06")
        if eocd < 0:
            raise SourceIntegrityError("zip: end of central directory not found")
        (_, _, _, _, count, cd_size, cd_offset, _) = struct.unpack("<IHHHHIIH", tail[eocd : eocd + 22])
        if cd_offset == 0xFFFFFFFF or count == 0xFFFF:
            raise SourceIntegrityError("zip: zip64 archives are not supported")
        directory = source.read(cd_offset, cd_size)
        self.members: Dict[str, ZipMember] = {}
        pos = 0
        for _ in range(count):
            if directory[pos : pos + 4] != b"PK\x01\x02":
                raise SourceIntegrityError("zip: corrupt central directory")
            fields = struct.unpack("<IHHHHHHIIIHHHHHII", directory[pos : pos + 46])
            method, crc, csize, usize = fields[4], fields[7], fields[8], fields[9]
            name_len, extra_len, comment_len, offset = fields[10], fields[11], fields[12], fields[16]
            name = directory[pos + 46 : pos + 46 + name_len].decode("utf-8")
            self.members[name] = ZipMember(name, offset, csize, usize, method, crc)
            pos += 46 + name_len + extra_len + comment_len

    def names(self) -> List[str]:
        return list(self.members)

    def read(self, name: str) -> bytes:
        member = self.members[name]
        # One request covers the local header, a typical extra field and the
        # data; a longer extra field costs a second request.
        guess = 30 + len(name.encode("utf-8")) + 64
        blob = self.source.read(member.offset, guess + member.compressed_size)
        if blob[:4] != b"PK\x03\x04":
            raise SourceIntegrityError(f"zip: bad local header for {name}")
        name_len, extra_len = struct.unpack("<HH", blob[26:30])
        start = 30 + name_len + extra_len
        raw = blob[start : start + member.compressed_size]
        if len(raw) != member.compressed_size:
            raw = self.source.read(member.offset + start, member.compressed_size)
        if member.method == 0:
            data = raw
        elif member.method == 8:
            data = zlib.decompress(raw, -15)
        else:
            raise SourceIntegrityError(f"zip: unsupported compression {member.method} for {name}")
        if len(data) != member.size or (zlib.crc32(data) & 0xFFFFFFFF) != member.crc32:
            raise SourceIntegrityError(f"zip: CRC/size mismatch for {name}")
        return data


# --- task directories -------------------------------------------------------

TomlValue = Union[str, int, float, bool, List[str], List[int]]


def _toml_value(value: object) -> str:
    """A TOML value that is also valid JSON (no inline tables)."""
    if isinstance(value, bool) or isinstance(value, (int, float)) or value is None:
        if value is None:
            raise ValueError("TOML has no null")
        return json.dumps(value)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False).replace("\x7f", "\\u007f")
    if isinstance(value, (list, tuple)):
        return "[" + ", ".join(_toml_value(item) for item in value) + "]"
    raise TypeError(f"unsupported TOML value {value!r}")


def task_toml(config: Mapping[str, object]) -> str:
    """Render a nested dict as TOML: scalars first, then tables in order.

    Lists of dicts become arrays of tables. Keys are bare (ASCII words).
    """
    lines: List[str] = []

    def emit(prefix: str, table: Mapping[str, object], header: Optional[str]) -> None:
        scalars = [(k, v) for k, v in table.items() if not isinstance(v, Mapping) and not _is_table_list(v)]
        if header is not None:
            lines.append("")
            lines.append(header)
        for key, value in scalars:
            lines.append(f"{key} = {_toml_value(value)}")
        for key, value in table.items():
            path = f"{prefix}{key}"
            if isinstance(value, Mapping):
                emit(path + ".", value, f"[{path}]")
            elif _is_table_list(value):
                for item in value:  # type: ignore[union-attr]
                    emit(path + ".", item, f"[[{path}]]")

    emit("", config, None)
    return "\n".join(lines).lstrip("\n") + "\n"


def _is_table_list(value: object) -> bool:
    return isinstance(value, (list, tuple)) and bool(value) and all(isinstance(item, Mapping) for item in value)


def base_task_config(
    *,
    task_id: str,
    description: str,
    keywords: Sequence[str],
    metadata: Mapping[str, object],
    artifacts: Sequence[object],
    agent_timeout_sec: float,
    verifier_timeout_sec: float,
    cpus: int = 1,
    memory_mb: int = 2048,
    storage_mb: int = 4096,
    build_timeout_sec: float = 900.0,
    collect: Sequence[Mapping[str, object]] = (),
) -> Dict[str, object]:
    """The task.toml every adapter writes: a separate, offline verifier.

    The agent environment keeps Harbor's default public network (the agent
    reaches its model provider from inside the container). The verifier runs
    in a fresh container built from tests/Dockerfile with no network and sees
    only the declared artifacts, never the agent's filesystem.
    """
    config: Dict[str, object] = {
        "schema_version": "1.4",
        "task": {
            "name": f"{TASK_ORG}/{task_id}",
            "version": "1.0.0",
            "description": description,
            "keywords": list(keywords),
        },
        "metadata": dict(metadata),
        "agent": {"timeout_sec": float(agent_timeout_sec)},
        "verifier": {
            "timeout_sec": float(verifier_timeout_sec),
            "environment_mode": "separate",
            "environment": {
                "network_mode": "no-network",
                "build_timeout_sec": float(build_timeout_sec),
                "cpus": cpus,
                "memory_mb": memory_mb,
                "storage_mb": storage_mb,
            },
        },
        "environment": {
            "build_timeout_sec": float(build_timeout_sec),
            "cpus": cpus,
            "memory_mb": memory_mb,
            "storage_mb": storage_mb,
        },
    }
    if collect:
        config["verifier"]["collect"] = [dict(item) for item in collect]  # type: ignore[index]
    # Plain string artifacts are a TOML array; service-scoped ones are an
    # array of tables. Harbor accepts both (config.py `artifacts`).
    config["artifacts"] = list(artifacts)
    return _artifacts_first(config)


def _artifacts_first(config: Dict[str, object]) -> Dict[str, object]:
    # A root-level array of strings must precede the first [table] header;
    # an array of tables may come anywhere. Keep schema_version first.
    ordered: Dict[str, object] = {"schema_version": config.pop("schema_version")}
    artifacts = config.pop("artifacts")
    if not _is_table_list(artifacts):
        ordered["artifacts"] = artifacts
        artifacts = None
    ordered.update(config)
    if artifacts is not None:
        ordered["artifacts"] = artifacts
    return ordered


FileContent = Union[str, bytes]
EXECUTABLE_NAMES = frozenset({"solve.sh", "test.sh"})


def write_task(task_dir: Path, files: Mapping[str, FileContent]) -> None:
    """Write one task directory; *.sh scripts Harbor runs are made executable."""
    for rel, content in sorted(files.items()):
        path = task_dir / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        data = content.encode("utf-8") if isinstance(content, str) else content
        path.write_bytes(data)
        if path.name in EXECUTABLE_NAMES or rel.endswith(".sh"):
            path.chmod(0o755)
        else:
            path.chmod(0o644)


def shell_heredoc_file(path: str, content: str) -> str:
    """Shell lines that write `content` verbatim to `path` (quoted heredoc)."""
    tag = "METACODES_EOF"
    while tag in content:
        tag += "_X"
    body = content if content.endswith("\n") else content + "\n"
    return f"cat > {path} <<'{tag}'\n{body}{tag}\n"


def tree_sha256(root: Path) -> str:
    """Content hash of a directory: relative paths, exec bits and bytes."""
    digest = hashlib.sha256()
    for path in sorted(p for p in root.rglob("*") if p.is_file()):
        rel = path.relative_to(root).as_posix()
        executable = os.access(path, os.X_OK) if os.name != "nt" else rel.endswith(".sh")
        digest.update(rel.encode("utf-8") + b"\0" + (b"x" if executable else b"-") + b"\0")
        digest.update(sha256_file(path).encode("ascii") + b"\n")
    return digest.hexdigest()


def task_ids(dataset_dir: Path) -> List[str]:
    """Task directory names, the names `harbor run -p <dir> -i <name>` matches.

    Harbor 0.26 lists a local dataset as the sorted child directories that
    hold a task.toml (src/harbor/models/job/config.py `_get_local_task_configs`;
    LocalTaskId.get_name is the directory name).
    """
    if not dataset_dir.is_dir():
        return []
    return sorted(p.name for p in dataset_dir.iterdir() if p.is_dir() and (p / "task.toml").is_file())


# --- idempotent prepare -------------------------------------------------------


def files_digest(paths: Iterable[Path]) -> str:
    digest = hashlib.sha256()
    for path in paths:
        digest.update(path.name.encode("utf-8") + b"\0" + sha256_file(path).encode("ascii") + b"\n")
    return digest.hexdigest()


def read_marker(dataset_dir: Path) -> Optional[Dict[str, object]]:
    try:
        data = json.loads((dataset_dir / MARKER_NAME).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def dataset_complete(dataset_dir: Path, suite_id: str, fingerprint: str) -> bool:
    """True when the marker matches and every recorded task tree is intact."""
    marker = read_marker(dataset_dir)
    if not marker or marker.get("suite") != suite_id or marker.get("fingerprint") != fingerprint:
        return False
    tasks = marker.get("tasks")
    if not isinstance(tasks, dict) or not tasks:
        return False
    if sorted(tasks) != task_ids(dataset_dir):
        return False
    return all(tree_sha256(dataset_dir / name) == digest for name, digest in tasks.items())


Fetcher = Callable[[Path], Dict[str, Path]]
Builder = Callable[[Dict[str, Path], Path], None]


def prepare_dataset(
    dest: Path,
    *,
    suite_id: str,
    fingerprint: str,
    fetch_sources: Fetcher,
    build: Builder,
    provenance: Mapping[str, object],
) -> Path:
    """`dest` itself as the dataset directory, built once and reused while intact.

    The workbench calls prepare with dest = <state>/bench/datasets/<suite id>
    and runs `harbor run -p dest`; task directories are dest's children.
    Downloads are cached in dest/.cache/ (Harbor and the catalog skip
    children without task.toml, and dot names are not task ids).

    `fingerprint` must change whenever the pins or the generated bytes would
    (adapters hash their pins, generator version and template files). When
    the marker matches and every task tree hash still matches, nothing is
    downloaded or written. Otherwise `fetch_sources(cache_dir)` returns the
    verified inputs, `build(inputs, scratch)` writes the tasks into a hidden
    scratch directory, the old task directories and marker are removed, the
    new ones are moved in, and the marker is written last, so an interrupted
    prepare leaves a dataset that reads as incomplete and is rebuilt.
    """
    dataset_dir = Path(dest)
    if dataset_complete(dataset_dir, suite_id, fingerprint):
        return dataset_dir
    dataset_dir.mkdir(parents=True, exist_ok=True)
    inputs = fetch_sources(dataset_dir / CACHE_DIR_NAME)
    scratch = dataset_dir / (".partial-%d" % os.getpid())
    if scratch.exists():
        shutil.rmtree(scratch)
    scratch.mkdir()
    try:
        build(inputs, scratch)
        names = task_ids(scratch)
        if not names:
            raise RuntimeError(f"{suite_id}: the build produced no tasks")
        marker = {
            "suite": suite_id,
            "fingerprint": fingerprint,
            "sources": {name: sha256_file(path) for name, path in sorted(inputs.items())},
            "provenance": dict(provenance),
            "tasks": {name: tree_sha256(scratch / name) for name in names},
        }
        if dataset_complete(dataset_dir, suite_id, fingerprint):
            return dataset_dir  # a concurrent prepare finished first
        (dataset_dir / MARKER_NAME).unlink(missing_ok=True)
        for stale in task_ids(dataset_dir):
            shutil.rmtree(dataset_dir / stale)
        for name in names:
            os.replace(scratch / name, dataset_dir / name)
        marker_tmp = dataset_dir / (MARKER_NAME + ".tmp")
        marker_tmp.write_text(json.dumps(marker, indent=1, sort_keys=True) + "\n", encoding="utf-8")
        os.replace(marker_tmp, dataset_dir / MARKER_NAME)
    finally:
        if scratch.exists():
            shutil.rmtree(scratch, ignore_errors=True)
    return dataset_dir


def fingerprint_of(*parts: object, files: Sequence[Path] = ()) -> str:
    digest = hashlib.sha256(json.dumps(parts, sort_keys=True, default=_jsonable).encode("utf-8"))
    for path in files:
        digest.update(path.name.encode("utf-8") + b"\0" + path.read_bytes())
    return digest.hexdigest()


def _jsonable(value: object) -> object:
    if isinstance(value, Pin):
        return {"name": value.name, **value.describe()}
    raise TypeError(repr(value))


def template_path(*parts: str) -> Path:
    return Path(__file__).resolve().parent.joinpath(*parts)


def read_template(*parts: str) -> str:
    return template_path(*parts).read_text(encoding="utf-8")
