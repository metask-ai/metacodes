"""`metacodes bench db status | import | migrate`."""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Dict, List, Optional

from scripts.eval.harbor.store import config as store_config
from scripts.eval.harbor.store import ingest, migrate as migration
from scripts.eval.harbor.store.backend import Store


def _print(value: Dict[str, Any], as_json: bool, lines: List[str]) -> None:
    if as_json:
        print(json.dumps(value, ensure_ascii=False))
    else:
        for line in lines:
            print(line)


def status(active: store_config.StoreConfig, as_json: bool) -> int:
    store = Store(active)
    try:
        counts = store.counts()
        with store.read() as tx:
            stale = int(tx.one("SELECT COUNT(*) FROM trials WHERE projection <> ?", (ingest.PROJECTION,))[0])
            latest = tx.one("SELECT MAX(ingested_at) FROM jobs")[0]
        value = {**store.describe(), "counts": counts, "stale_projections": stale, "last_ingested_at": latest}
    finally:
        store.close()
    lines = [f"数据库：{value['format']} {value['location']}（schema v{value['schema_version']}）",
             "作业 {jobs}，单题 {trials}，请求 {requests}，文件 {files}，内容块 {blobs}，启动记录 {runs}".format(**counts)]
    if latest:
        lines.append("最近导入：" + latest)
    _print(value, as_json, lines)
    return 0


def import_dirs(active: store_config.StoreConfig, roots: List[Path], verify: bool, as_json: bool) -> int:
    store = Store(active)
    try:
        results = [ingest.ingest_root(store, root, verify=verify, log=ingest.stderr_log) for root in roots]
        ingest.refresh_projections(store, ingest.stderr_log)
    finally:
        store.close()
    value = {"database": active.describe(), "imports": [r.to_json() for r in results]}
    lines = []
    for result in results:
        outcomes: Dict[str, int] = {}
        for job in result.jobs:
            outcomes[job.outcome] = outcomes.get(job.outcome, 0) + 1
        summary = "，".join(f"{k} {v}" for k, v in sorted(outcomes.items())) or "没有作业"
        lines.append(f"{result.root}：{summary}；启动记录 {result.runs_written}")
        lines += [f"  跳过 {job.name}：{job.reason}" for job in result.jobs if job.outcome == "skipped"]
    _print(value, as_json, lines)
    return 0


def migrate(active: store_config.StoreConfig, target: store_config.StoreConfig, as_json: bool,
            switch: bool, config_path: Path, settings: Dict[str, Any], save) -> int:
    source = Store(active)
    try:
        destination = Store(target)
        try:
            report = migration.migrate(source, destination,
                                       progress=(lambda m: None) if as_json else (lambda m: print("  " + m)))
        finally:
            destination.close()
    finally:
        source.close()
    value = report.to_json()
    if switch:
        save(config_path, {**settings, "store": target.to_json()})
        value["switched"] = True
    lines = [f"已迁移并校验：{active.describe()['location']} → {target.describe()['location']}"]
    for name, table in report.tables.items():
        lines.append(f"  {name}: 源 {table.source}，已校验 {table.verified}，目标共 {table.target_total}")
    if switch:
        lines.append("已切换工作台数据库；重启服务后生效：metacodes bench stop && metacodes bench")
    _print(value, as_json, lines)
    return 0


def run(command: Optional[str], *, active: store_config.StoreConfig, jobs_dirs: List[Path], target: Optional[str],
        password_env: Optional[str], switch: bool, verify: bool, as_json: bool, config_path: Path,
        settings: Dict[str, Any], save) -> int:
    if command == "status":
        return status(active, as_json)
    if command == "import":
        return import_dirs(active, jobs_dirs, verify, as_json)
    if command == "migrate":
        if not target:
            raise ValueError("bench db migrate 需要 --to <SQLite 路径 | postgresql://...>")
        return migrate(active, store_config.from_target(target, password_env), as_json, switch,
                       config_path, settings, save)
    raise ValueError("bench db 需要子命令：status、import 或 migrate")
