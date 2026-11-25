from __future__ import annotations

import asyncio
import collections
import datetime
import json
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

DIRECTORY = ".bench-lifecycle"
SCHEMA_VERSION = 1
PREPARE_PARALLEL = 4
ERROR_LIMIT = 600
TRANSITIONS = ("queued_at", "prepare_started_at", "prepare_finished_at", "started_at", "finished_at")


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def record_path(job_dir, trial_name):
    return Path(job_dir) / DIRECTORY / (trial_name + ".json")


def record_file(job_dir, trial_name):
    if not isinstance(trial_name, str) or not trial_name or trial_name in (".", "..") or job_dir is None:
        return None
    if "/" in trial_name or "\\" in trial_name:
        return None
    try:
        return record_path(job_dir, trial_name)
    except (TypeError, ValueError):
        return None


def local_task_dir(trial_config):
    task = getattr(trial_config, "task", None)
    path = getattr(task, "path", None)
    if path is None or getattr(task, "git_url", None):
        return None
    try:
        directory = Path(path).expanduser().resolve()
        return directory if (directory / "task.toml").is_file() else None
    except (OSError, TypeError, ValueError):
        return None


def task_name(trial_config, task_dir):
    if task_dir is not None:
        return task_dir.name
    task = getattr(trial_config, "task", None)
    named = getattr(task, "name", None) or getattr(task, "path", None)
    return str(named).rstrip("/").rsplit("/", 1)[-1] if named else ""


class Operation:
    def __init__(self, key, kind, image, run):
        self.key = key
        self.kind = kind
        self.image = image
        self.run = run


def report(text):
    print("[准备] " + text, file=sys.stderr, flush=True)


def docker_operations(task_dir):
    from scripts.eval.harbor.bench import executors, images

    executor = executors.LocalExecutor()
    pulls, builds = images.images_of(task_dir.parent, [task_dir.name])
    tools = {"runner": subprocess.run, "log": report, "sleep": time.sleep}

    def build(digest, plan):
        ready = images.build_one(executor, digest, plan, check_only=True, ship=None, **tools)
        if ready["status"] == "present":
            return ready
        return images.build_one(executor, digest, plan, check_only=False, ship=None, **tools)

    found = [Operation("pull:" + image, "pull", image,
                       lambda image=image: images.pull_one(executor, image, check_only=False, **tools))
             for image in sorted(pulls)]
    found += [Operation("build:" + digest, "build", images.BUILD_TAG + digest,
                        lambda digest=digest, plan=plan: build(digest, plan))
              for digest, plan in sorted(builds.items())]
    return found


def brief(error):
    return str(error)[-ERROR_LIMIT:]


def failed_item(operation, error, seconds=0.0):
    return {"kind": operation.kind, "image": operation.image, "status": "failed", "seconds": round(seconds, 3),
            "error": brief(error)}


def measured(operation, clock=time.monotonic):
    started = clock()
    try:
        outcome = operation.run()
    except Exception as exc:
        return failed_item(operation, f"{type(exc).__name__}: {exc}", clock() - started)
    item = {"kind": operation.kind, "image": operation.image, "status": str(outcome.get("status") or "failed"),
            "seconds": round(clock() - started, 3)}
    if outcome.get("attempts"):
        item["attempts"] = outcome["attempts"]
    if outcome.get("error"):
        item["error"] = brief(outcome["error"])
    return item


def overall(items):
    statuses = {item["status"] for item in items}
    if "failed" in statuses:
        return "failed"
    return "present" if statuses <= {"present"} else "prepared"


class Ticket:
    def __init__(self, trial_config, now):
        self.config = trial_config
        self.now = now
        self.slot = None
        self.preparation = None
        name = getattr(trial_config, "trial_name", None)
        self.path = record_file(getattr(trial_config, "trials_dir", None), name)
        self.task_dir = local_task_dir(trial_config)
        self.record = {"schema_version": SCHEMA_VERSION, "trial": name if isinstance(name, str) else "",
                       "task": task_name(trial_config, self.task_dir),
                       **{key: None for key in TRANSITIONS}, "prepare": None}
        self.mark("queued_at")

    def mark(self, transition):
        self.record[transition] = self.now()
        self.save()

    def prepared(self, outcome, finished=True):
        self.record["prepare"] = outcome
        if finished:
            self.record["prepare_finished_at"] = self.now()
        self.save()

    def save(self):
        if self.path is None:
            return
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            staging = self.path.with_name(self.path.name + ".tmp")
            staging.write_text(json.dumps(self.record, ensure_ascii=False), encoding="utf-8")
            os.replace(staging, self.path)
        except OSError:
            pass


class Scheduler:
    def __init__(self, limit, poll_seconds, operations=None, now=utc_now, parallel=PREPARE_PARALLEL):
        self.limit = limit
        self.poll_seconds = poll_seconds
        self.operations = operations if operations is not None else docker_operations
        self.now = now
        self.parallel = parallel
        self.waiting = collections.deque()
        self.running = 0
        self.inflight = {}
        self.gate = None

    def dispatch(self):
        limit = self.limit()
        while self.waiting and self.running < limit:
            ticket = self.waiting.popleft()
            self.running += 1
            ticket.slot.set_result(None)
        for position, ticket in enumerate(self.waiting):
            if position >= limit:
                break
            self.prepare(ticket)

    def release(self):
        self.running -= 1
        self.dispatch()

    def prepare(self, ticket):
        if ticket.preparation is None:
            ticket.preparation = asyncio.ensure_future(self.preparing(ticket))

    async def preparing(self, ticket):
        try:
            if ticket.task_dir is None:
                ticket.prepared({"status": "skipped"}, finished=False)
                return
            ticket.mark("prepare_started_at")
            try:
                found = await self.offload(self.operations, ticket.task_dir)
            except Exception as exc:
                ticket.prepared({"status": "skipped", "error": brief(f"{type(exc).__name__}: {exc}"), "items": []})
                return
            items = list(await asyncio.gather(*(self.shared(operation) for operation in found)))
            ticket.prepared({"status": overall(items) if items else "skipped", "items": items})
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            ticket.prepared({"status": "failed", "error": brief(f"{type(exc).__name__}: {exc}"), "items": []})

    async def shared(self, operation):
        running = self.inflight.get(operation.key)
        if running is not None:
            return {**await asyncio.shield(running), "shared": True}
        running = asyncio.ensure_future(self.perform(operation))
        self.inflight[operation.key] = running
        running.add_done_callback(lambda _done: self.inflight.pop(operation.key, None))
        return await asyncio.shield(running)

    async def perform(self, operation):
        if self.gate is None:
            self.gate = asyncio.Semaphore(self.parallel)
        async with self.gate:
            try:
                return await self.offload(measured, operation)
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                return failed_item(operation, f"{type(exc).__name__}: {exc}")

    def offload(self, function, *args):
        loop = asyncio.get_running_loop()
        future = loop.create_future()

        def settle(setter, value):
            if not future.done():
                setter(value)

        def work():
            try:
                call = (future.set_result, function(*args))
            except BaseException as exc:
                call = (future.set_exception, exc)
            try:
                loop.call_soon_threadsafe(settle, *call)
            except RuntimeError:
                pass

        threading.Thread(target=work, daemon=True, name="bench-prepare").start()
        return future

    async def run(self, trial_config, execute):
        ticket = Ticket(trial_config, self.now)
        ticket.slot = asyncio.get_running_loop().create_future()
        self.waiting.append(ticket)
        self.dispatch()
        try:
            while not ticket.slot.done():
                await asyncio.wait({ticket.slot}, timeout=self.poll_seconds())
                self.dispatch()
        except BaseException:
            if ticket.slot.done():
                self.release()
            else:
                self.waiting.remove(ticket)
            self.abandon(ticket)
            raise
        try:
            ticket.mark("started_at")
            self.prepare(ticket)
            await self.settled(ticket.preparation)
            return await execute(trial_config)
        finally:
            self.abandon(ticket)
            ticket.mark("finished_at")
            self.release()

    async def settled(self, preparation):
        try:
            await asyncio.shield(preparation)
        except asyncio.CancelledError:
            if not preparation.cancelled():
                raise
        except Exception:
            pass

    def abandon(self, ticket):
        if ticket.preparation is not None and not ticket.preparation.done():
            ticket.preparation.cancel()
