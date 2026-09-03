"""Create the frozen WorkBuddy cohort manifest without reading task bodies.

The split is fixed before official task slugs are inspected.  This program only
looks at tar headers for ``tasks/<slug>/task.toml`` regular files; it never
extracts an archive or opens instruction, test, or workspace members.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
import subprocess
import tarfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Dict, Iterable, Mapping, Sequence

from . import WORKBUDDY_PINNED_COMMIT
from ..model import O_BINARY, fsync_directory, open_nofollow



SCHEMA_VERSION = "metacodes-workbuddy-cohorts-v1"
SALT = "metacodes-workbuddy-2026-08-11-v1"
ALGORITHM = "sha256(utf8(salt) || NUL || utf8(subset) || NUL || utf8(task_slug))"
GENERATOR_PATH = "scripts/eval/workbuddy/cohort_manifest.py"


class CohortError(ValueError):
    pass


@dataclass(frozen=True)
class Subset:
    name: str
    dataset_id: str
    archive: str
    task_count: int
    cohort_counts: tuple[tuple[str, int], ...]


SUBSETS: tuple[Subset, ...] = (
    Subset(
        "code",
        "wb-bench-code-v1.0",
        "wb-bench-code-v1.0.tar.gz",
        80,
        (("dev", 16), ("promotion_a", 8), ("promotion_b", 8), ("sealed", 48)),
    ),
    Subset(
        "web",
        "wb-bench-web-v1.0",
        "wb-bench-web-v1.0.tar.gz",
        70,
        (("dev", 14), ("promotion_a", 7), ("promotion_b", 7), ("sealed", 42)),
    ),
    Subset(
        "office",
        "wb-bench-office-v1.0",
        "wb-bench-office-v1.0.tar.gz",
        50,
        (("dev", 10), ("promotion_a", 5), ("promotion_b", 5), ("sealed", 30)),
    ),
    Subset(
        "security",
        "wb-bench-sec-v1.0",
        "wb-bench-sec-v1.0.tar.gz",
        60,
        (("dev", 12), ("promotion_a", 6), ("promotion_b", 6), ("sealed", 36)),
    ),
)


def _canonical_json(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode(
        "utf-8"
    )


def _sha256_reader(handle: object) -> str:
    digest = hashlib.sha256()
    while True:
        chunk = handle.read(1024 * 1024)  # type: ignore[attr-defined]
        if not chunk:
            break
        digest.update(chunk)
    return digest.hexdigest()


def _parse_sha256sums(path: Path) -> Dict[str, str]:
    try:
        text = path.read_text(encoding="ascii")
    except (OSError, UnicodeError) as exc:
        raise CohortError(f"cannot read SHA256SUMS {path}: {exc}") from exc
    result: Dict[str, str] = {}
    for line_number, raw in enumerate(text.splitlines(), 1):
        if not raw.strip():
            continue
        parts = raw.split()
        if len(parts) != 2 or len(parts[0]) != 64:
            raise CohortError(f"malformed SHA256SUMS line {line_number}")
        digest = parts[0].lower()
        if any(character not in "0123456789abcdef" for character in digest):
            raise CohortError(f"non-hex SHA256SUMS line {line_number}")
        name = parts[1].removeprefix("*")
        if name in result:
            raise CohortError(f"duplicate SHA256SUMS entry: {name}")
        result[name] = digest
    return result


def _task_slug(subset: Subset, member: tarfile.TarInfo) -> str | None:
    path = PurePosixPath(member.name)
    if path.is_absolute() or ".." in path.parts or "." in path.parts:
        raise CohortError(f"unsafe archive member path: {member.name!r}")
    expected_prefix = (subset.dataset_id, "tasks")
    if len(path.parts) != 4 or path.parts[:2] != expected_prefix:
        return None
    if path.parts[3] != "task.toml":
        return None
    if not member.isfile() or member.issym() or member.islnk():
        raise CohortError(f"task metadata is not a regular file: {member.name!r}")
    slug = path.parts[2]
    if not slug or slug in {".", ".."} or "/" in slug or "\\" in slug:
        raise CohortError(f"unsafe task slug: {slug!r}")
    try:
        slug.encode("utf-8", errors="strict")
    except UnicodeError as exc:
        raise CohortError(f"task slug is not UTF-8: {slug!r}") from exc
    return slug


def _scan_archive(path: Path, subset: Subset, expected_sha256: str) -> Dict[str, object]:
    flags = os.O_RDONLY
    try:
        descriptor = open_nofollow(path, flags)
    except OSError as exc:
        raise CohortError(f"cannot open archive {path}: {exc}") from exc
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_size <= 0:
            raise CohortError(f"archive is not a non-empty regular file: {path}")
        if before.st_nlink != 1:
            raise CohortError(f"archive must have exactly one hard link: {path}")
        with os.fdopen(descriptor, "rb", closefd=False) as handle:
            actual_sha256 = _sha256_reader(handle)
            if actual_sha256 != expected_sha256:
                raise CohortError(
                    f"archive checksum mismatch for {subset.archive}: "
                    f"expected {expected_sha256}, got {actual_sha256}"
                )
            handle.seek(0)
            slugs: set[str] = set()
            try:
                with tarfile.open(fileobj=handle, mode="r:gz") as archive:
                    for member in archive:
                        slug = _task_slug(subset, member)
                        if slug is None:
                            continue
                        if slug in slugs:
                            raise CohortError(
                                f"duplicate task.toml header for {subset.name}/{slug}"
                            )
                        slugs.add(slug)
            except (tarfile.TarError, OSError) as exc:
                raise CohortError(f"cannot scan archive {path}: {exc}") from exc
        after = os.fstat(descriptor)
        identity = (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
        if identity != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
            raise CohortError(f"archive changed while being scanned: {path}")
    finally:
        os.close(descriptor)
    if len(slugs) != subset.task_count:
        raise CohortError(
            f"{subset.name} archive exposes {len(slugs)} tasks; "
            f"expected {subset.task_count}"
        )
    return {
        "archive": subset.archive,
        "archive_bytes": before.st_size,
        "archive_sha256": actual_sha256,
        "task_slugs": sorted(slugs),
    }


def _rank(subset: str, slug: str) -> str:
    framed = SALT.encode("utf-8") + b"\0" + subset.encode("utf-8") + b"\0" + slug.encode(
        "utf-8"
    )
    return hashlib.sha256(framed).hexdigest()


def _split(subset: Subset, slugs: Sequence[str]) -> Dict[str, object]:
    ranked = sorted(slugs, key=lambda slug: (_rank(subset.name, slug), slug))
    offset = 0
    cohorts: Dict[str, object] = {}
    assigned: set[str] = set()
    for cohort, count in subset.cohort_counts:
        names = ranked[offset : offset + count]
        offset += count
        if len(names) != count or assigned.intersection(names):
            raise CohortError(f"invalid {subset.name}/{cohort} cohort partition")
        assigned.update(names)
        cohorts[cohort] = {
            "count": count,
            "task_selection": {"mode": "name", "names": sorted(names)},
        }
    if offset != len(ranked) or assigned != set(slugs):
        raise CohortError(f"{subset.name} cohorts are not exhaustive and disjoint")
    return cohorts


def _generator_sha256() -> str:
    return hashlib.sha256(Path(__file__).read_bytes()).hexdigest()


def build_manifest(
    *,
    archives: Mapping[str, Path],
    expected_sums: Mapping[str, str],
    workbuddy_commit: str = WORKBUDDY_PINNED_COMMIT,
) -> Dict[str, object]:
    if workbuddy_commit != WORKBUDDY_PINNED_COMMIT:
        raise CohortError(
            f"WorkBuddy commit is {workbuddy_commit}, expected {WORKBUDDY_PINNED_COMMIT}"
        )
    if set(archives) != {subset.name for subset in SUBSETS}:
        raise CohortError("archives must bind exactly code, web, office, and security")

    subset_rows: Dict[str, object] = {}
    totals = {name: 0 for name, _ in SUBSETS[0].cohort_counts}
    for subset in SUBSETS:
        expected_sha256 = expected_sums.get(subset.archive)
        if expected_sha256 is None:
            raise CohortError(f"SHA256SUMS has no entry for {subset.archive}")
        scanned = _scan_archive(archives[subset.name], subset, expected_sha256)
        slugs = scanned.pop("task_slugs")
        assert isinstance(slugs, list)
        cohorts = _split(subset, slugs)
        for name, row in cohorts.items():
            assert isinstance(row, dict)
            totals[name] += int(row["count"])
        subset_rows[subset.name] = {
            **scanned,
            "dataset": f"datasets/{subset.dataset_id}/tasks",
            "task_count": subset.task_count,
            "cohorts": cohorts,
        }

    manifest: Dict[str, object] = {
        "schema_version": SCHEMA_VERSION,
        "quality_evidence": False,
        "workbuddy_commit": workbuddy_commit,
        "generator": {
            "path": GENERATOR_PATH,
            "sha256": _generator_sha256(),
            "algorithm": ALGORITHM,
            "salt": SALT,
            "content_hash": "sha256(canonical-json(manifest without content_sha256))",
        },
        "contamination_boundary": {
            "source": "gzip tar member headers ending in tasks/<slug>/task.toml",
            "tar_header_fields_used": ["name", "type"],
            "task_payload_exposed_to_generator": False,
            "archives_extracted": False,
            "dev_may_inform_changes": True,
            "promotion_or_sealed_may_inform_same_batch": False,
        },
        "cohort_totals": totals,
        "subsets": subset_rows,
    }
    manifest["content_sha256"] = hashlib.sha256(_canonical_json(manifest)).hexdigest()
    return manifest


def _git(repo: Path, *args: str) -> str:
    try:
        return subprocess.run(
            ["git", "-C", str(repo), *args],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError) as exc:
        raise CohortError(f"git {' '.join(args)} failed for {repo}: {exc}") from exc


def _verify_workbuddy(repo: Path) -> str:
    head = _git(repo, "rev-parse", "HEAD")
    if head != WORKBUDDY_PINNED_COMMIT:
        raise CohortError(f"WorkBuddy checkout is {head}, expected {WORKBUDDY_PINNED_COMMIT}")
    origin = _git(repo, "remote", "get-url", "origin").lower()
    if "tencent/workbuddy-bench" not in origin:
        raise CohortError(f"unexpected WorkBuddy origin: {origin}")
    return head


def _write_new(path: Path, payload: bytes) -> None:
    if path.exists() or path.is_symlink():
        raise CohortError(f"refusing to overwrite cohort manifest: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    if temporary.exists() or temporary.is_symlink():
        raise CohortError(f"stale cohort manifest temporary file: {temporary}")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0) | O_BINARY
    descriptor = os.open(temporary, flags, 0o600)
    try:
        with os.fdopen(descriptor, "wb", closefd=False) as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        fsync_directory(path.parent)
    finally:
        os.close(descriptor)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workbuddy-checkout", type=Path, required=True)
    parser.add_argument("--archives-dir", type=Path, required=True)
    parser.add_argument("--sha256sums", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        commit = _verify_workbuddy(args.workbuddy_checkout.resolve())
        expected_sums = _parse_sha256sums(args.sha256sums.resolve())
        archives = {
            subset.name: (args.archives_dir / subset.archive).resolve()
            for subset in SUBSETS
        }
        manifest = build_manifest(
            archives=archives,
            expected_sums=expected_sums,
            workbuddy_commit=commit,
        )
        _write_new(args.output, json.dumps(manifest, sort_keys=True, indent=2).encode("utf-8") + b"\n")
    except (CohortError, OSError) as exc:
        parser.error(str(exc))
    print(json.dumps({"output": str(args.output), "content_sha256": manifest["content_sha256"]}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
