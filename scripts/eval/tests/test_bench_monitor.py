from __future__ import annotations

import contextlib
import io
import json
import os
import shlex
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

from scripts.eval.harbor import cli
from scripts.eval.harbor.bench import data, executors, monitor, monitor_probe
from scripts.eval.harbor.bench.runner import RunManager
from scripts.eval.harbor.bench.workbench import Workbench
from scripts.eval.harbor.viewer import server
from scripts.eval.tests.test_bench_setup import SetupFixture

PROC_STAT = ("cpu  28661035 53032 6910150 633554989 405074 0 206397 1915 0 0\n"
             "cpu0 1699127 1931 443880 39679861 26309 0 21618 147 0 0\n")
PROC_STAT_LATER = "cpu  28661835 53032 6910350 633555889 405174 0 206397 1915 0 0\n"
PROC_MEMINFO = ("MemTotal:       32842768 kB\nMemFree:        10947192 kB\nMemAvailable:   30081860 kB\n"
                "Buffers:         1191604 kB\nSwapTotal:       2097148 kB\nSwapFree:        2028608 kB\n")
PROC_NET_DEV = (
    "Inter-|   Receive                                                |  Transmit\n"
    " face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed\n"
    "    lo: 39875255797 9226286    0    0    0     0          0         0 39875255797 9226286    0    0    0     0       0          0\n"
    "enp6s18: 348785268629 131485414    0    0    0     0          0         0 22571411249 82887442    0    0    0     0       0          0\n"
    "docker0: 24362933845 1868015    0    0    0     0          0         0 4938445649 1928477    0    0    0     0       0          0\n"
    "vethce3ac40: 24236230928 1646712    0    0    0     0          0         0 2029142655 1658506    0    0    0     0       0          0\n")
DOCKER_DF = (
    '{"Active":"6","Reclaimable":"27.51GB (17%)","Size":"157.7GB","TotalCount":"382","Type":"Images"}\n'
    '{"Active":"9","Reclaimable":"148.8MB (13%)","Size":"1.076GB","TotalCount":"10","Type":"Containers"}\n'
    '{"Active":"1","Reclaimable":"528B (0%)","Size":"1.916GB","TotalCount":"8","Type":"Local Volumes"}\n'
    '{"Active":"0","Reclaimable":"58.67GB","Size":"64.27GB","TotalCount":"1528","Type":"Build Cache"}\n')
DOCKER_INFO = json.dumps({
    "ServerVersion": "29.1.3", "DockerRootDir": "/var/lib/docker", "Driver": "overlayfs", "Containers": 10,
    "ContainersRunning": 9, "Images": 382,
    "RegistryConfig": {"IndexConfigs": {"docker.io": {"Mirrors": []}}, "Mirrors": ["https://docker.m.daocloud.io/"]}})
APT_LOG = (
    "1795407514|I|152419|172.17.0.1|debrep/dists/bookworm/InRelease\n"
    "1795407514|O|151343|172.17.0.1|debrep/dists/bookworm/InRelease\n"
    "1795407516|I|8791922|172.17.0.1|debrep/dists/bookworm/main/binary-amd64/by-hash/SHA256/9e0b\n"
    "1795407516|O|8791000|172.17.0.1|debrep/dists/bookworm/main/binary-amd64/by-hash/SHA256/9e0b\n"
    "1795407600|E|0|172.17.0.1|secdeb/dists/bookworm-security/InRelease\n"
    "1795578655|O|196970|172.17.0.1|uburep/pool/main/m/mtools/mtools_4.0.43-1build1_amd64.deb\n"
    "1795578655|O|374620|172.17.0.1|uburep/pool/main/s/socat/socat_1.8.0.0-4ubuntu0.1_amd64.deb\n"
    "1795578656|O|374620|172.17.0.1|uburep/pool/main/s/socat/socat_1.8.0.0-4ubuntu0.1_amd64.deb\n")
DOWNLOAD_STATS = {"schema_version": 1, "started_at": "2026-11-25T01:00:00+00:00", "entries": 412, "disk_bytes": 734003200,
                  "routes": {
                      "pypi": {"upstream": "https://mirrors.aliyun.com/pypi", "requests": 1000, "hits": 900, "misses": 90,
                               "stale": 4, "errors": 6, "bytes_cached": 96000000000, "bytes_fetched": 107000000},
                      "github": {"upstream": "https://gh-proxy.com/https://github.com", "requests": 0, "hits": 0,
                                 "misses": 0, "stale": 0, "errors": 0, "bytes_cached": 0, "bytes_fetched": 0}}}
FAKE_DOCKER = r'''#!/bin/sh
exec {python} - "$@" <<'METACODES_FAKE_DOCKER'
import json, os, sys
args = sys.argv[1:]
with open(os.environ["FAKE_LOG"], "a") as log:
    log.write(json.dumps(["docker", args, "remote"]) + "\n")
if args[:1] == ["info"]:
    print({info!r})
elif args[:2] == ["system", "df"]:
    sys.stdout.write({df!r})
elif args[:1] == ["exec"]:
    sys.stdout.write({apt!r})
else:
    sys.exit(1)
METACODES_FAKE_DOCKER
'''


def lifecycle_record(trial, **fields):
    record = {"schema_version": 1, "trial": trial, "task": trial.split("__")[0], "queued_at": "2026-11-25T03:00:00Z",
              "prepare_started_at": None, "prepare_finished_at": None, "started_at": None, "finished_at": None,
              "prepare": None}
    record.update(fields)
    return record


def write_lifecycle(jobs, runs):
    prepared = {"prepare_started_at": "2026-11-25T03:00:05Z", "prepare_finished_at": "2026-11-25T03:01:05Z"}
    live = {
        "fix-git__a": lifecycle_record("fix-git__a", **prepared, started_at="2026-11-25T03:01:06Z", prepare={
            "status": "present", "items": [{"kind": "pull", "image": "tb/fix-git", "status": "present", "seconds": 0.2}]}),
        "regex-log__b": lifecycle_record("regex-log__b", **prepared, prepare={"status": "prepared", "items": [
            {"kind": "pull", "image": "tb/regex-log", "status": "pulled", "seconds": 61.5},
            {"kind": "pull", "image": "tb/regex-log-verifier", "status": "present", "seconds": 0.1}]}),
        "alfworld__c": lifecycle_record("alfworld__c", prepare_started_at="2026-11-25T03:02:00Z"),
        "aime__d": lifecycle_record("aime__d"),
        "aime__e": lifecycle_record("aime__e", **prepared, started_at="2026-11-25T03:03:00Z",
                                    finished_at="2026-11-25T03:09:00Z", prepare={"status": "prepared", "items": [
                                        {"kind": "build", "image": "metacodes-prebuild-1", "status": "built", "seconds": 30.4},
                                        {"kind": "pull", "image": "tb/regex-log", "status": "pulled", "seconds": 61.5,
                                         "shared": True}]}),
        "cold__h": lifecycle_record("cold__h", started_at="2026-11-25T03:00:01Z",
                                    prepare_started_at="2026-11-25T03:00:01Z"),
        "broken__i": lifecycle_record("broken__i", **prepared, prepare={"status": "failed", "items": [
            {"kind": "pull", "image": "tb/broken", "status": "failed", "seconds": 45.0, "attempts": 3,
             "error": "manifest unknown"}]}),
    }
    ended = {
        "swe__f": lifecycle_record("swe__f", **prepared, started_at="2026-11-25T02:00:00Z",
                                   finished_at="2026-11-25T02:05:00Z", prepare={"status": "failed", "items": [
            {"kind": "pull", "image": "swebench/x", "status": "failed", "seconds": 90.0, "error": "timeout"}]}),
        "swe__g": lifecycle_record("swe__g"),
    }
    for job, records, marker in (("bench-live", live, "harbor.pid"), ("bench-ended", ended, "harbor.exit")):
        directory = jobs / job / ".bench-lifecycle"
        directory.mkdir(parents=True)
        for name, record in records.items():
            (directory / (name + ".json")).write_text(json.dumps(record))
        (directory / "notes.txt").write_text("ignored")
        (runs / job).mkdir(parents=True)
        (runs / job / "harbor.pid").write_text("1")
        (runs / job / marker).write_text("0")


class ProbeParserTest(unittest.TestCase):
    def test_cpu_busy_is_the_share_of_non_idle_time_between_two_samples(self):
        before, after = monitor_probe.cpu_times(PROC_STAT), monitor_probe.cpu_times(PROC_STAT_LATER)
        self.assertEqual(before, (28661035 + 53032 + 6910150 + 206397 + 1915, 669792592))
        self.assertEqual(monitor_probe.cpu_busy(before, after), 50.0)
        self.assertIsNone(monitor_probe.cpu_busy(before, before))
        self.assertIsNone(monitor_probe.cpu_times(""))
        self.assertIsNone(monitor_probe.cpu_times(None))

    def test_memory_load_and_uptime_come_from_proc(self):
        self.assertEqual(monitor_probe.memory(PROC_MEMINFO), {
            "total": 32842768 * 1024, "available": 30081860 * 1024, "swap_total": 2097148 * 1024,
            "swap_free": 2028608 * 1024})
        self.assertIsNone(monitor_probe.memory("garbage"))
        self.assertEqual(monitor_probe.load_average("1.33 1.77 3.00 4/803 3207612\n"), [1.33, 1.77, 3.0])
        self.assertIsNone(monitor_probe.load_average(None))
        self.assertEqual(monitor_probe.uptime("418911.33 6335549.93\n"), 418911.33)
        self.assertIsNone(monitor_probe.uptime(""))

    def test_interface_rates_leave_out_loopback_and_mark_physical_cards(self):
        before = monitor_probe.interfaces(PROC_NET_DEV)
        self.assertEqual(sorted(before), ["docker0", "enp6s18", "vethce3ac40"])
        after = dict(before, enp6s18=(before["enp6s18"][0] + 4096, before["enp6s18"][1] + 1024), fresh0=(10, 20))
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "enp6s18" / "device").mkdir(parents=True)
            rows = {row["name"]: row for row in monitor_probe.interface_rates(before, after, 2.0, tmp)}
        self.assertEqual((rows["enp6s18"]["rx_rate"], rows["enp6s18"]["tx_rate"], rows["enp6s18"]["physical"]),
                         (2048.0, 512.0, True))
        self.assertEqual((rows["docker0"]["rx_rate"], rows["docker0"]["physical"]), (0.0, False))
        self.assertEqual((rows["fresh0"]["rx_rate"], rows["fresh0"]["rx_bytes"]), (None, 10))

    def test_docker_usage_is_read_from_system_df_json_lines(self):
        self.assertEqual(monitor_probe.size_bytes("27.51GB (17%)"), 27510000000)
        self.assertEqual(monitor_probe.size_bytes("528B (0%)"), 528)
        self.assertEqual(monitor_probe.size_bytes("1.5GiB"), 1610612736)
        self.assertIsNone(monitor_probe.size_bytes("n/a"))
        usage = monitor_probe.system_df(DOCKER_DF + "not json\n")
        self.assertEqual(usage["images"], {"count": 382, "active": 6, "bytes": 157700000000,
                                           "reclaimable_bytes": 27510000000})
        self.assertEqual(usage["build_cache"]["reclaimable_bytes"], 58670000000)
        self.assertEqual(sorted(usage), ["build_cache", "containers", "images", "volumes"])
        info = monitor_probe.docker_info(DOCKER_INFO)
        self.assertEqual((info["version"], info["root"], info["driver"], info["containers_running"]),
                         ("29.1.3", "/var/lib/docker", "overlayfs", 9))
        self.assertEqual(info["registry_mirrors"], ["https://docker.m.daocloud.io/"])
        self.assertIsNone(monitor_probe.docker_info('{"ServerErrors": ["down"]}'))
        self.assertIsNone(monitor_probe.docker_info(""))

    def test_apt_hits_are_served_responses_without_an_upstream_fetch(self):
        self.assertEqual(monitor_probe.apt_log(APT_LOG + "broken line\n"), {
            "requests": 5, "misses": 2, "hits": 3, "errors": 1,
            "bytes_served": 151343 + 8791000 + 196970 + 374620 * 2, "bytes_fetched": 152419 + 8791922})
        self.assertEqual(monitor_probe.apt_log("")["hits"], 0)

    def test_download_cache_stats_are_totalled_and_malformed_ones_refused(self):
        stats = monitor_probe.download_stats(DOWNLOAD_STATS)
        self.assertEqual(stats["totals"], {"requests": 1000, "hits": 900, "misses": 90, "stale": 4, "errors": 6,
                                           "bytes_cached": 96000000000, "bytes_fetched": 107000000})
        self.assertEqual((stats["entries"], stats["disk_bytes"], stats["routes"]["github"]["requests"]),
                         (412, 734003200, 0))
        self.assertIsNone(monitor_probe.download_stats({"routes": []}))
        self.assertIsNone(monitor_probe.download_stats("<html>"))

    def test_lifecycle_counts_image_hits_and_only_live_jobs_as_waiting(self):
        with tempfile.TemporaryDirectory() as tmp:
            jobs, runs = Path(tmp) / "jobs", Path(tmp) / "runs"
            write_lifecycle(jobs, runs)
            counted = monitor_probe.lifecycle(str(jobs), str(runs))
            self.assertEqual(counted, {"trials": 9, "hits": 2, "misses": 2, "failed": 2, "pulled": 1, "built": 1,
                                       "pull_seconds": 61.5, "build_seconds": 30.4, "queued": 1, "preparing": 2,
                                       "ready": 1, "unprepared": 1})
            self.assertEqual(monitor_probe.lifecycle(str(jobs), str(runs), cap=1)["trials"], 1)
            local = monitor_probe.lifecycle(str(jobs), None)
            self.assertEqual((local["queued"], local["preparing"], local["ready"], local["unprepared"]), (2, 2, 1, 1))
            (jobs / "bench-ended" / "result.json").write_text('{"finished_at": "2026-11-25T03:30:00"}')
            self.assertEqual(monitor_probe.lifecycle(str(jobs), None)["queued"], 1)
            stale = monitor_probe.lifecycle(str(jobs), None, now=time.time() + 90000)
            self.assertEqual((stale["queued"], stale["preparing"], stale["ready"], stale["hits"]), (0, 0, 0, 2))
        self.assertEqual(monitor_probe.lifecycle(str(Path(tmp) / "gone"))["trials"], 0)

    def test_a_trial_preparing_in_its_slot_counts_as_preparing_and_a_failed_preparation_is_not_ready(self):
        stages = {
            "cold start, holds its slot": ({"started_at": "t", "prepare_started_at": "t"}, {}, "preparing"),
            "ahead of its turn": ({"prepare_started_at": "t"}, {}, "preparing"),
            "ready": ({"prepare_started_at": "t", "prepare_finished_at": "t"}, {"status": "prepared"}, "ready"),
            "found everything": ({"prepare_started_at": "t", "prepare_finished_at": "t"}, {"status": "present"}, "ready"),
            "pull retries used up": ({"prepare_started_at": "t", "prepare_finished_at": "t"}, {"status": "failed"},
                                     "unprepared"),
            "nothing found to prepare": ({"prepare_started_at": "t", "prepare_finished_at": "t"},
                                         {"status": "skipped"}, "unprepared"),
            "not reached": ({}, {}, "queued"),
            "running": ({"started_at": "t", "prepare_started_at": "t", "prepare_finished_at": "t"},
                        {"status": "prepared"}, None),
            "done": ({"started_at": "t", "prepare_started_at": "t", "finished_at": "t"}, {}, None),
        }
        for name, (record, prepare, expected) in stages.items():
            with self.subTest(name=name):
                self.assertEqual(monitor_probe.waiting_stage(record, prepare), expected)

    def test_the_local_machine_leaves_out_jobs_that_ran_on_an_ssh_executor(self):
        with tempfile.TemporaryDirectory() as tmp:
            jobs = Path(tmp) / "jobs"
            pulled = {"status": "prepared", "items": [{"kind": "pull", "image": "tb/x", "status": "pulled", "seconds": 5}]}
            for job in ("ran-on-4090", "ran-here", "started-by-hand"):
                directory = jobs / job / ".bench-lifecycle"
                directory.mkdir(parents=True)
                (directory / "a__1.json").write_text(json.dumps(lifecycle_record("a__1", prepare=pulled)))
            records = jobs / ".bench-runs"
            records.mkdir()
            (records / "ran-on-4090.spec").write_text(json.dumps({"executor": {"name": "relay-4090", "kind": "ssh"}}))
            (records / "ran-here.spec").write_text(json.dumps({"executor": {"name": "devbox-mac", "kind": "local"}}))
            (records / "broken.spec").write_text("{not json")
            self.assertEqual(monitor_probe.jobs_run_elsewhere(str(records)), {"ran-on-4090"})
            everything = monitor_probe.lifecycle(str(jobs), None)
            here = monitor_probe.lifecycle(str(jobs), None, records_dir=str(records))
            self.assertEqual((everything["trials"], everything["pulled"], everything["queued"]), (3, 3, 3))
            self.assertEqual((here["trials"], here["pulled"], here["queued"]), (2, 2, 2))
            self.assertEqual(monitor_probe.jobs_run_elsewhere(str(Path(tmp) / "gone")), set())


class ProbeCollectTest(unittest.TestCase):
    def options(self, **extra):
        return {"bind": None, "apt_port": 3142, "apt_container": "metacodes-apt-cache", "download_port": 3143,
                "state_dir": None, "jobs_dir": None, "runs_dir": None, "targets": {}, "sample": 0.01, **extra}

    def test_a_host_without_proc_or_docker_reports_nulls_not_errors(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, {"PATH": tmp}):
            value = monitor_probe.collect(self.options(proc=str(Path(tmp) / "proc"), net_devices=tmp))
        self.assertEqual(value["schema_version"], 1)
        self.assertIsNone(value["load"]["cpu_busy_percent"])
        self.assertIsNone(value["load"]["uptime_seconds"])
        self.assertEqual(value["interfaces"], [])
        self.assertIn("docker", value["docker"]["error"])
        self.assertEqual(value["caches"]["apt"], {"url": None, "answering": False})
        self.assertEqual(value["caches"]["download"], {"url": None, "answering": False})
        self.assertEqual(value["caches"]["images"]["trials"], 0)
        self.assertEqual(json.loads(json.dumps(value)), value)

    def test_proc_files_fill_the_load_section_and_dead_targets_are_reported(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, {"PATH": tmp}):
            proc = Path(tmp) / "proc"
            (proc / "net").mkdir(parents=True)
            (proc / "stat").write_text(PROC_STAT)
            (proc / "meminfo").write_text(PROC_MEMINFO)
            (proc / "net/dev").write_text(PROC_NET_DEV)
            (proc / "loadavg").write_text("1.33 1.77 3.00 4/803 3207612\n")
            (proc / "uptime").write_text("418911.33 6335549.93\n")
            value = monitor_probe.collect(self.options(proc=str(proc), net_devices=tmp, state_dir=tmp, target_timeout=2,
                                                       targets={"dead": "http://127.0.0.1:9/"}))
        self.assertEqual(value["load"]["average"], [1.33, 1.77, 3.0])
        self.assertEqual(value["load"]["memory"]["available"], 30081860 * 1024)
        self.assertEqual(value["load"]["uptime_seconds"], 418911.33)
        self.assertEqual([row["name"] for row in value["interfaces"]], ["docker0", "enp6s18", "vethce3ac40"])
        self.assertEqual((value["targets"]["dead"]["ok"], value["targets"]["dead"]["status"]), (False, None))
        self.assertTrue(any(tmp in disk["paths"] for disk in value["disks"]), value["disks"])


class Answers(BaseHTTPRequestHandler):
    pages: dict = {}

    def do_GET(self):
        body = self.pages.get(self.path)
        self.send_response(200 if body is not None else 404)
        self.send_header("Content-Length", str(len(body or b"")))
        self.end_headers()
        self.wfile.write(body or b"")

    def log_message(self, *_args):
        pass


class MonitorHttpTest(SetupFixture):
    def serve(self, pages):
        handler = type("Pages", (Answers,), {"pages": pages})
        http = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=http.serve_forever, daemon=True).start()
        self.addCleanup(http.server_close)
        self.addCleanup(http.shutdown)
        return http.server_port

    def setUp(self):
        super().setUp()
        apt_port = self.serve({"/acng-report.html": b"ok"})
        download_port = self.serve({"/_stats": json.dumps(DOWNLOAD_STATS).encode()})
        self.dead = "http://127.0.0.1:9/"
        for patcher in (patch.object(executors, "APT_CACHE_PORT", apt_port),
                        patch.object(monitor, "DOWNLOAD_CACHE_PORT", download_port),
                        patch.object(monitor, "TARGET_TIMEOUT", 2),
                        patch.object(monitor, "SOURCES", (("pypi", "PyPI", self.reachable), ("github", "GitHub", self.dead)))):
            patcher.start()
            self.addCleanup(patcher.stop)
        self.add_ssh_executor(metrics_bind="127.0.0.1", pypi_index=self.reachable + "simple",
                              docker_mirrors=[self.reachable.rstrip("/")], ghcr_mirror="ghcr.example.invalid",
                              container_mirrors={"apt": "http://mirrors.example.invalid", "go": self.reachable})
        docker = self.remote_bin / "docker"
        docker.write_text(FAKE_DOCKER.format(python=sys.executable, info=DOCKER_INFO, df=DOCKER_DF, apt=APT_LOG))
        docker.chmod(0o755)
        write_lifecycle(self.remote_home / ".metacodes-bench/jobs", self.remote_home / ".metacodes-bench/runs")
        self.manager = RunManager(self.state / "bench/jobs", self.config)
        http = server.make_server(Workbench(data.Library([self.manager.jobs_dir]), self.manager), "127.0.0.1", 0)
        threading.Thread(target=http.serve_forever, daemon=True).start()
        self.addCleanup(http.server_close)
        self.addCleanup(http.shutdown)
        self.url = f"http://127.0.0.1:{http.server_address[1]}/"
        self.client = cli.Client(self.url)

    def probes(self):
        return [call for call in self.calls("ssh") if " - " in call[1][-1] and "apt_container" in call[1][-1]]

    def options_sent(self, call):
        return json.loads(shlex.split(shlex.split(call[1][-1])[2])[-1])

    def test_the_page_api_returns_what_the_probe_measured_on_the_executor(self):
        value = self.client.request("api/monitor?executor=relay-4090")
        self.assertIsNone(value["error"])
        self.assertEqual((value["executor"]["name"], value["default_executor"]), ("relay-4090", "devbox-mac"))
        self.assertEqual([e["name"] for e in value["executors"]], ["devbox-mac", "relay-4090"])
        self.assertEqual(len(self.probes()), 1)
        self.assertIn("python3 - ", self.probes()[0][1][-1])
        docker = value["docker"]
        self.assertEqual((docker["version"], docker["containers_running"], docker["registry_mirrors"]),
                         ("29.1.3", 9, ["https://docker.m.daocloud.io/"]))
        self.assertEqual(docker["usage"]["images"], {"count": 382, "active": 6, "bytes": 157700000000,
                                                     "reclaimable_bytes": 27510000000})
        remote_calls = [call[1][:2] for call in self.calls("docker", "remote")]
        self.assertIn(["info", "--format"], remote_calls)
        self.assertIn(["exec", "metacodes-apt-cache"], remote_calls)
        apt = value["caches"]["apt"]
        self.assertEqual((apt["answering"], apt["configured"], apt["upstream"]), (True, True, "http://mirrors.example.invalid"))
        self.assertEqual((apt["requests"], apt["hits"], apt["misses"], apt["errors"], apt["hit_rate"]), (5, 3, 2, 1, 0.6))
        download = value["caches"]["download"]
        self.assertEqual((download["answering"], download["entries"], download["totals"]["hits"]), (True, 412, 900))
        self.assertEqual((download["routes"]["pypi"]["hit_rate"], download["routes"]["github"]["hit_rate"],
                          download["totals"]["hit_rate"]), (0.9, None, 0.9))
        images = value["caches"]["images"]
        self.assertEqual((images["hits"], images["misses"], images["failed"], images["hit_rate"]), (2, 2, 2, 0.5))
        self.assertEqual((images["queued"], images["preparing"], images["ready"], images["unprepared"]), (1, 2, 1, 1))
        self.assertIsNone(self.options_sent(self.probes()[0])["records_dir"])
        targets = {row["key"]: row for row in value["network"]["targets"]}
        self.assertEqual(sorted(targets), ["mirror.container.apt", "mirror.container.go", "mirror.docker.0", "mirror.ghcr",
                                           "mirror.pypi_index", "source.github", "source.pypi"])
        self.assertEqual((targets["source.pypi"]["probe"]["ok"], targets["source.pypi"]["probe"]["status"]), (True, 200))
        self.assertEqual((targets["source.github"]["probe"]["ok"], targets["source.github"]["url"]), (False, self.dead))
        self.assertEqual((targets["mirror.docker.0"]["url"], targets["mirror.docker.0"]["probe"]["status"]),
                         (self.reachable + "v2/", 404))
        self.assertEqual(targets["mirror.ghcr"]["url"], "https://ghcr.example.invalid/v2/")
        self.assertFalse(targets["mirror.ghcr"]["probe"]["ok"])
        mirrors = value["mirrors"]
        self.assertEqual(mirrors["egress"], "direct")
        self.assertEqual([(row["setting"], row["scope"]) for row in mirrors["items"]], [
            ("pypi_index", "执行机器"), ("docker_mirrors", "执行机器"), ("ghcr_mirror", "执行机器"),
            ("container_mirrors.apt", "任务容器"), ("container_mirrors.go", "任务容器")])
        self.assertTrue(any(path.endswith("/.metacodes-bench") for disk in value["disks"] for path in disk["paths"]))
        self.assertIsNotNone(value["load"]["cpus"])
        self.assertIsNotNone(data.parse_time(value["collected_at"]))

    def test_snapshots_are_reused_briefly_and_targets_for_longer(self):
        first = self.client.request("api/monitor?executor=relay-4090")
        again = self.client.request("api/monitor?executor=relay-4090")
        self.assertEqual((len(self.probes()), again["collected_at"]), (1, first["collected_at"]))
        with patch.object(monitor, "SNAPSHOT_SECONDS", 0):
            fresh = self.client.request("api/monitor?executor=relay-4090")
        self.assertEqual(len(self.probes()), 2)
        self.assertNotEqual(fresh["collected_at"], first["collected_at"])
        self.assertEqual(fresh["network"]["targets_checked_at"], first["network"]["targets_checked_at"])
        self.assertEqual((fresh["docker"]["usage"], fresh["docker"]["usage_checked_at"]),
                         (first["docker"]["usage"], first["docker"]["usage_checked_at"]))
        self.assertEqual(first["docker"]["usage_checked_at"], first["collected_at"])
        self.assertEqual([self.options_sent(call)["docker_usage"] for call in self.probes()], [True, False])
        self.assertEqual(len([c for c in self.calls("docker", "remote") if c[1][:2] == ["system", "df"]]), 1)
        self.assertEqual(len([c for c in self.calls("docker", "remote") if c[1][:1] == ["info"]]), 2)
        self.assertEqual(self.options_sent(self.probes()[1])["targets"], {})
        self.assertEqual({row["key"]: row["probe"] for row in fresh["network"]["targets"]},
                         {row["key"]: row["probe"] for row in first["network"]["targets"]})
        with patch.object(monitor, "SNAPSHOT_SECONDS", 0), patch.object(monitor, "TARGET_SECONDS", 0), \
                patch.object(monitor, "USAGE_SECONDS", 0):
            self.client.request("api/monitor?executor=relay-4090")
        self.assertTrue(self.options_sent(self.probes()[2])["targets"])
        self.assertTrue(self.options_sent(self.probes()[2])["docker_usage"])
        self.assertEqual(len([c for c in self.calls("docker", "remote") if c[1][:2] == ["system", "df"]]), 2)

    def test_an_unreachable_executor_is_an_error_for_the_page_not_a_failure(self):
        with patch.dict(os.environ, {"FAKE_SSH_MODE": "deny"}):
            value = self.client.request("api/monitor?executor=relay-4090")
        self.assertIn("连接执行机器失败", value["error"])
        self.assertIn("Permission denied", value["error"])
        self.assertEqual(value["executor"]["name"], "relay-4090")
        self.assertEqual([e["name"] for e in value["executors"]], ["devbox-mac", "relay-4090"])
        with self.assertRaisesRegex(ValueError, "未配置执行机器 nowhere"):
            self.client.request("api/monitor?executor=nowhere")

    def test_missing_caches_are_reported_as_not_answering(self):
        with patch.object(executors, "APT_CACHE_PORT", 9), patch.object(monitor, "DOWNLOAD_CACHE_PORT", 9):
            value = self.client.request("api/monitor?executor=relay-4090")
        self.assertEqual((value["caches"]["apt"]["answering"], value["caches"]["apt"]["configured"]), (False, True))
        self.assertNotIn("requests", value["caches"]["apt"])
        self.assertEqual((value["caches"]["download"]["answering"], value["caches"]["download"]["configured"]),
                         (False, False))
        self.assertFalse([call for call in self.calls("docker", "remote") if call[1][:1] == ["exec"]])

    def test_the_default_executor_is_this_machine_and_a_viewer_without_config_refuses(self):
        value = self.client.request("api/monitor")
        self.assertIsNone(value["error"])
        self.assertEqual(value["executor"]["name"], "devbox-mac")
        self.assertEqual(self.probes(), [])
        self.assertIn("docker", value["docker"]["error"])
        self.assertEqual(value["caches"]["apt"]["answering"], False)
        self.assertEqual(value["mirrors"]["items"], [])
        self.assertEqual(value["caches"]["images"]["trials"], 0)
        synced = self.manager.jobs_dir / "synced-from-4090" / ".bench-lifecycle"
        synced.mkdir(parents=True)
        (synced / "a__1.json").write_text(json.dumps(lifecycle_record("a__1", prepare={"status": "prepared", "items": [
            {"kind": "pull", "image": "tb/x", "status": "pulled", "seconds": 5}]})))
        local = self.manager.jobs_dir / "ran-here" / ".bench-lifecycle"
        local.mkdir(parents=True)
        (local / "b__1.json").write_text(json.dumps(lifecycle_record("b__1", prepare={"status": "present", "items": [
            {"kind": "pull", "image": "tb/y", "status": "present", "seconds": 0.1}]})))
        self.manager.records.mkdir(parents=True, exist_ok=True)
        (self.manager.records / "synced-from-4090.spec").write_text(json.dumps(
            {"executor": {"name": "relay-4090", "kind": "ssh"}}))
        with patch.object(monitor, "SNAPSHOT_SECONDS", 0):
            images = self.client.request("api/monitor")["caches"]["images"]
        self.assertEqual((images["trials"], images["hits"], images["misses"], images["pulled"]), (1, 1, 0, 0))
        viewer = server.make_server(Workbench(data.Library([self.manager.jobs_dir])), "127.0.0.1", 0)
        threading.Thread(target=viewer.serve_forever, daemon=True).start()
        self.addCleanup(viewer.server_close)
        self.addCleanup(viewer.shutdown)
        with self.assertRaises(urllib.error.HTTPError) as caught:
            urllib.request.urlopen(f"http://127.0.0.1:{viewer.server_address[1]}/api/monitor")
        self.assertEqual(caught.exception.code, 403)
        caught.exception.close()

    def test_the_cli_prints_the_same_snapshot(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = cli.main(["monitor", "--state-root", str(self.state), "--executor", "relay-4090", "--json"])
        value = json.loads(out.getvalue())
        self.assertEqual((code, value["caches"]["apt"]["hits"], value["docker"]["version"]), (0, 3, "29.1.3"))
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = cli.main(["monitor", "--state-root", str(self.state), "--url", self.url, "--executor", "relay-4090"])
        self.assertEqual(code, 0)
        self.assertIn("apt 缓存：命中 3 / 5（60%）", out.getvalue())
        self.assertIn("下载缓存：命中 900 / 1000（90%）", out.getvalue())
        self.assertIn("镜像（本地镜像库）：命中 2 · 拉取或构建 2 · 失败 2 · 排队 1 · 准备中 2 · 就绪等待 1 · 准备失败等待 1", out.getvalue())


if __name__ == "__main__":
    unittest.main()
