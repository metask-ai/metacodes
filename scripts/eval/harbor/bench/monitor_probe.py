from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

SIZE = re.compile(r"^\s*([0-9]+(?:\.[0-9]+)?)\s*([kKMGTP]?i?B)")
SIZE_UNITS = {"B": 1, "kB": 1000, "KB": 1000, "MB": 1000 ** 2, "GB": 1000 ** 3, "TB": 1000 ** 4, "PB": 1000 ** 5,
              "KiB": 1024, "MiB": 1024 ** 2, "GiB": 1024 ** 3, "TiB": 1024 ** 4, "PiB": 1024 ** 5}
DF_TYPES = {"Images": "images", "Containers": "containers", "Local Volumes": "volumes", "Build Cache": "build_cache"}
APT_LOG_LIMIT = 64 * 1024 * 1024
ROUTE_COUNTERS = ("requests", "hits", "misses", "stale", "errors", "bytes_cached", "bytes_fetched")
PREPARED = {"present": "hits", "pulled": "misses", "built": "misses", "failed": "failed"}
READY = ("present", "prepared")


def read_text(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            return handle.read()
    except OSError:
        return None


def whole(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def cpu_times(text):
    for line in (text or "").splitlines():
        fields = line.split()
        if fields[:1] == ["cpu"] and len(fields) >= 5:
            values = [whole(v) or 0 for v in fields[1:9]]
            idle = values[3] + (values[4] if len(values) > 4 else 0)
            return sum(values) - idle, sum(values)
    return None


def cpu_busy(before, after):
    if not before or not after or after[1] <= before[1]:
        return None
    return round(100.0 * (after[0] - before[0]) / (after[1] - before[1]), 1)


def memory(text):
    values = {}
    for line in (text or "").splitlines():
        name, _, rest = line.partition(":")
        amount = whole(rest.split()[0]) if rest.split() else None
        if amount is not None:
            values[name.strip()] = amount * 1024
    if "MemTotal" not in values:
        return None
    return {"total": values["MemTotal"], "available": values.get("MemAvailable"),
            "swap_total": values.get("SwapTotal"), "swap_free": values.get("SwapFree")}


def interfaces(text):
    found = {}
    for line in (text or "").splitlines():
        name, separator, rest = line.partition(":")
        fields = rest.split()
        if not separator or len(fields) < 9 or name.strip() == "lo":
            continue
        rx, tx = whole(fields[0]), whole(fields[8])
        if rx is not None and tx is not None:
            found[name.strip()] = (rx, tx)
    return found


def interface_rates(before, after, seconds, devices="/sys/class/net"):
    rows = []
    for name, (rx, tx) in sorted(after.items()):
        row = {"name": name, "physical": os.path.exists(os.path.join(devices, name, "device")),
               "rx_bytes": rx, "tx_bytes": tx, "rx_rate": None, "tx_rate": None}
        if name in before and seconds > 0:
            row["rx_rate"] = max(0.0, (rx - before[name][0]) / seconds)
            row["tx_rate"] = max(0.0, (tx - before[name][1]) / seconds)
        rows.append(row)
    return rows


def load_average(text):
    fields = (text or "").split()
    try:
        return [float(v) for v in fields[:3]] if len(fields) >= 3 else None
    except ValueError:
        return None


def uptime(text):
    try:
        return float((text or "").split()[0])
    except (IndexError, ValueError):
        return None


def size_bytes(text):
    found = SIZE.match(str(text or ""))
    if not found or found.group(2) not in SIZE_UNITS:
        return None
    return int(float(found.group(1)) * SIZE_UNITS[found.group(2)])


def system_df(text):
    usage = {}
    for line in (text or "").splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        key = DF_TYPES.get(row.get("Type")) if isinstance(row, dict) else None
        if key:
            usage[key] = {"count": whole(row.get("TotalCount")), "active": whole(row.get("Active")),
                          "bytes": size_bytes(row.get("Size")), "reclaimable_bytes": size_bytes(row.get("Reclaimable"))}
    return usage


def docker_info(text):
    try:
        info = json.loads(text)
    except (TypeError, ValueError):
        return None
    if not isinstance(info, dict) or not info.get("ServerVersion"):
        return None
    registry = info.get("RegistryConfig") if isinstance(info.get("RegistryConfig"), dict) else {}
    return {"version": info.get("ServerVersion"), "root": info.get("DockerRootDir"), "driver": info.get("Driver"),
            "registry_mirrors": [m for m in registry.get("Mirrors") or [] if isinstance(m, str)],
            "containers_running": whole(info.get("ContainersRunning")),
            "containers_total": whole(info.get("Containers")), "images_total": whole(info.get("Images"))}


def apt_log(text):
    counts = {"requests": 0, "misses": 0, "errors": 0, "bytes_served": 0, "bytes_fetched": 0}
    for line in (text or "").splitlines():
        fields = line.split("|", 4)
        if len(fields) < 3:
            continue
        size = whole(fields[2]) or 0
        if fields[1] == "O":
            counts["requests"] += 1
            counts["bytes_served"] += size
        elif fields[1] == "I":
            counts["misses"] += 1
            counts["bytes_fetched"] += size
        elif fields[1] == "E":
            counts["errors"] += 1
    counts["hits"] = max(0, counts["requests"] - counts["misses"])
    return counts


def download_stats(value):
    if not isinstance(value, dict) or not isinstance(value.get("routes"), dict):
        return None
    routes = {}
    for kind, route in sorted(value["routes"].items()):
        if isinstance(route, dict):
            routes[str(kind)] = {"upstream": route.get("upstream") if isinstance(route.get("upstream"), str) else None,
                                 **{key: whole(route.get(key)) or 0 for key in ROUTE_COUNTERS}}
    totals = {key: sum(route[key] for route in routes.values()) for key in ROUTE_COUNTERS}
    return {"started_at": value.get("started_at") if isinstance(value.get("started_at"), str) else None,
            "entries": whole(value.get("entries")), "disk_bytes": whole(value.get("disk_bytes")),
            "routes": routes, "totals": totals}


def job_active(jobs_dir, runs_dir, job, newest, now, window):
    run_dir = os.path.join(runs_dir, job) if runs_dir else None
    if run_dir and os.path.isdir(run_dir):
        return os.path.exists(os.path.join(run_dir, "harbor.pid")) and not os.path.exists(os.path.join(run_dir, "harbor.exit"))
    try:
        result = json.loads(read_text(os.path.join(jobs_dir, job, "result.json")) or "null")
    except ValueError:
        result = None
    finished = isinstance(result, dict) and result.get("finished_at")
    return not finished and now - newest <= window


def jobs_run_elsewhere(records_dir):
    elsewhere = set()
    try:
        entries = list(os.scandir(records_dir)) if records_dir else []
    except OSError:
        return elsewhere
    for entry in entries:
        if not entry.name.endswith(".spec") or not entry.is_file(follow_symlinks=False):
            continue
        try:
            spec = json.loads(read_text(entry.path) or "null")
        except ValueError:
            continue
        executor = spec.get("executor") if isinstance(spec, dict) else None
        if isinstance(executor, dict) and executor.get("kind") == "ssh":
            elsewhere.add(entry.name[:-len(".spec")])
    return elsewhere


def waiting_stage(record, prepare):
    if record.get("finished_at"):
        return None
    if record.get("prepare_started_at") and not record.get("prepare_finished_at"):
        return "preparing"
    if record.get("started_at"):
        return None
    if not record.get("prepare_finished_at"):
        return "queued"
    return "ready" if prepare.get("status") in READY else "unprepared"


def lifecycle(jobs_dir, runs_dir=None, cap=2000, now=None, window=86400, records_dir=None):
    now = time.time() if now is None else now
    result = {"trials": 0, "hits": 0, "misses": 0, "failed": 0, "pulled": 0, "built": 0,
              "pull_seconds": 0.0, "build_seconds": 0.0, "queued": 0, "preparing": 0, "ready": 0, "unprepared": 0}
    files, newest = [], {}
    try:
        jobs = sorted(entry.name for entry in os.scandir(jobs_dir) if entry.is_dir(follow_symlinks=False))
    except OSError:
        return result
    elsewhere = jobs_run_elsewhere(records_dir)
    for job in jobs:
        if job in elsewhere:
            continue
        try:
            entries = list(os.scandir(os.path.join(jobs_dir, job, ".bench-lifecycle")))
        except OSError:
            continue
        for entry in entries:
            if not entry.name.endswith(".json") or not entry.is_file(follow_symlinks=False):
                continue
            modified = entry.stat(follow_symlinks=False).st_mtime
            files.append((modified, job, entry.path))
            newest[job] = max(newest.get(job, 0.0), modified)
    active = {job: job_active(jobs_dir, runs_dir, job, newest[job], now, window) for job in newest}
    for _modified, job, path in sorted(files, reverse=True)[:cap]:
        try:
            record = json.loads(read_text(path) or "null")
        except ValueError:
            continue
        if not isinstance(record, dict):
            continue
        result["trials"] += 1
        prepare = record.get("prepare") if isinstance(record.get("prepare"), dict) else {}
        for item in prepare.get("items") or []:
            if not isinstance(item, dict) or item.get("status") not in PREPARED or item.get("shared"):
                continue
            result[PREPARED[item["status"]]] += 1
            seconds = item.get("seconds") if isinstance(item.get("seconds"), (int, float)) else 0.0
            if item["status"] == "pulled":
                result["pulled"] += 1
                result["pull_seconds"] += seconds
            elif item["status"] == "built":
                result["built"] += 1
                result["build_seconds"] += seconds
        stage = waiting_stage(record, prepare) if active.get(job) else None
        if stage:
            result[stage] += 1
    result["pull_seconds"] = round(result["pull_seconds"], 1)
    result["build_seconds"] = round(result["build_seconds"], 1)
    return result


def disks(paths):
    rows, seen = [], set()
    for path in paths:
        if not path:
            continue
        try:
            device = os.stat(path).st_dev
            usage = shutil.disk_usage(path)
        except OSError:
            continue
        if device in seen:
            next(row for row in rows if row["device"] == device)["paths"].append(path)
            continue
        seen.add(device)
        rows.append({"device": device, "paths": [path], "total": usage.total, "used": usage.used, "free": usage.free})
    return [{key: row[key] for key in ("paths", "total", "used", "free")} for row in rows]


def fetch(url, timeout, limit=None):
    request = urllib.request.Request(url, headers={"User-Agent": "metacodes-bench-monitor"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.status, (response.read(limit) if limit else b"")


def target(url, timeout):
    started = time.monotonic()
    try:
        status, _ = fetch(url, timeout)
        result = {"ok": True, "status": status}
    except urllib.error.HTTPError as exc:
        result = {"ok": True, "status": exc.code}
    except Exception as exc:
        result = {"ok": False, "status": None, "error": type(exc).__name__}
    result["seconds"] = round(time.monotonic() - started, 2)
    return result


def command(argv, timeout):
    try:
        done = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None, "超过 %d 秒没有返回" % timeout
    except OSError as exc:
        return None, str(exc)
    if done.returncode != 0:
        lines = done.stderr.decode("utf-8", "replace").strip().splitlines()
        return None, lines[-1][:300] if lines else "退出码 %d" % done.returncode
    return done.stdout.decode("utf-8", "replace"), None


def docker_section(with_usage):
    if not shutil.which("docker"):
        return {"error": "没有找到 docker 命令"}
    text, error = command(["docker", "info", "--format", "{{json .}}"], 15)
    section = docker_info(text) if text is not None else None
    if section is None:
        return {"error": error or "docker info 没有返回可用的信息"}
    if with_usage:
        text, error = command(["docker", "system", "df", "--format", "{{json .}}"], 22)
        section["usage"] = system_df(text) if text is not None else {}
        section["usage_error"] = error
    return section


def apt_section(options):
    if not options.get("bind"):
        return {"url": None, "answering": False}
    url = "http://%s:%d/acng-report.html" % (options["bind"], options["apt_port"])
    try:
        answering = fetch(url, 3)[0] == 200
    except Exception:
        answering = False
    section = {"url": url, "answering": answering, "mirror": None}
    if not shutil.which("docker"):
        return section
    label = options.get("apt_label")
    if label:
        text, _error = command(["docker", "inspect", "-f", '{{index .Config.Labels "%s"}}' % label,
                                options["apt_container"]], 10)
        section["mirror"] = (text or "").strip() or None
    if not answering:
        return section
    text, error = command(["docker", "exec", options["apt_container"], "tail", "-c", str(APT_LOG_LIMIT),
                           "/var/log/apt-cacher-ng/apt-cacher.log"], 20)
    if text is None:
        section["error"] = error
        return section
    section["log_truncated"] = len(text.encode("utf-8", "replace")) >= APT_LOG_LIMIT
    section.update(apt_log(text))
    return section


def download_section(options):
    if not options.get("bind"):
        return {"url": None, "answering": False}
    url = "http://%s:%d/_stats" % (options["bind"], options["download_port"])
    section = {"url": url, "answering": False}
    try:
        status, body = fetch(url, 3, 4 * 1024 * 1024)
        stats = download_stats(json.loads(body)) if status == 200 else None
    except Exception:
        return section
    if stats is None:
        section["error"] = "缓存返回的统计格式无法识别"
        return section
    section.update(stats, answering=True)
    return section


def guarded(result, key, work):
    try:
        result[key] = work()
    except Exception as exc:
        result[key] = {"error": "%s: %s" % (type(exc).__name__, exc)}


def collect(options):
    proc = options.get("proc") or "/proc"
    started = time.monotonic()
    cpu_before = cpu_times(read_text(os.path.join(proc, "stat")))
    net_before = interfaces(read_text(os.path.join(proc, "net/dev")))
    time.sleep(float(options.get("sample") or 1.0))
    elapsed = time.monotonic() - started
    cpu_after = cpu_times(read_text(os.path.join(proc, "stat")))
    net_after = interfaces(read_text(os.path.join(proc, "net/dev")))
    sections, probes = {}, {}
    work = {"docker": lambda: docker_section(options.get("docker_usage", True)),
            "apt": lambda: apt_section(options), "download": lambda: download_section(options),
            "images": lambda: lifecycle(options.get("jobs_dir") or "", options.get("runs_dir"),
                                        records_dir=options.get("records_dir"))}
    threads = [threading.Thread(target=guarded, args=(sections, key, job), daemon=True) for key, job in work.items()]
    timeout = float(options.get("target_timeout") or 5)
    for key, url in sorted((options.get("targets") or {}).items()):
        threads.append(threading.Thread(target=guarded, args=(probes, key, lambda url=url: target(url, timeout)),
                                        daemon=True))
    for thread in threads:
        thread.start()
    deadline = started + float(options.get("budget") or 26)
    for thread in threads:
        thread.join(max(0.0, deadline - time.monotonic()))
    try:
        loads = load_average(read_text(os.path.join(proc, "loadavg"))) or list(os.getloadavg())
    except (OSError, AttributeError):
        loads = None
    mem = memory(read_text(os.path.join(proc, "meminfo")))
    if mem is None:
        try:
            mem = {"total": os.sysconf("SC_PHYS_PAGES") * os.sysconf("SC_PAGE_SIZE"), "available": None,
                   "swap_total": None, "swap_free": None}
        except (OSError, ValueError, AttributeError):
            mem = None
    docker = sections.get("docker") or {"error": "探测超时"}
    return {
        "schema_version": 1, "collected_at": time.time(), "host": os.uname().nodename if hasattr(os, "uname") else None,
        "os": os.uname().sysname if hasattr(os, "uname") else os.name,
        "load": {"average": loads, "cpus": os.cpu_count(), "cpu_busy_percent": cpu_busy(cpu_before, cpu_after),
                 "memory": mem, "uptime_seconds": uptime(read_text(os.path.join(proc, "uptime")))},
        "disks": disks(["/", docker.get("root"), options.get("state_dir")]),
        "interfaces": interface_rates(net_before, net_after, elapsed, options.get("net_devices") or "/sys/class/net"),
        "targets": {key: probes.get(key) or {"ok": False, "status": None, "error": "timeout", "seconds": None}
                    for key in (options.get("targets") or {})},
        "docker": docker,
        "caches": {"apt": sections.get("apt") or {"error": "探测超时"},
                   "download": sections.get("download") or {"error": "探测超时"},
                   "images": sections.get("images") or {"error": "探测超时"}},
    }


def main(argv):
    options = json.loads(argv[1])
    for key in ("state_dir", "jobs_dir", "runs_dir", "records_dir"):
        if options.get(key):
            options[key] = os.path.abspath(os.path.expanduser(options[key]))
    print(json.dumps(collect(options)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
