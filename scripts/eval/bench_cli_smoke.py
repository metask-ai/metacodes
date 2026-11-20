#!/usr/bin/env python3
"""Exercise the shipped Bench command from outside a repository checkout."""
from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib.parse import urlsplit
from urllib.request import Request, urlopen

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))
from scripts.eval.harbor.viewer.runner import RunManager, atomic_json  # noqa: E402
from scripts.eval.tests.test_bench_workbench import fixture, wait_run, wait_status  # noqa: E402

# A service from before the login was dropped, in a separate process: the
# base revision's headers, a capability every POST must carry, and a
# receipt holding that capability (what such a service wrote).
LEGACY_TOKEN = 'legacy-capability'
LEGACY_SERVER = """
import sys
from scripts.eval.harbor.viewer import server
TOKEN = 'legacy-capability'
base_handler, base_json = server.make_handler, server.atomic_json


def legacy_handler(*args, **kwargs):
    base = base_handler(*args, **kwargs)

    class Legacy(base):
        def authorized(self):
            return self.headers.get('Authorization', '') == 'Bearer ' + TOKEN

        def do_POST(self):
            if not self.authorized():
                self.send_json({'error': 'login link required'}, 403)
                return
            super().do_POST()
    return Legacy


def receipt(path, value):
    base_json(path, {**value, 'token': TOKEN} if 'pid' in value else value)


server.make_handler, server.atomic_json = legacy_handler, receipt
server.SECURITY_HEADERS = (
    ("Cache-Control", "no-store"),
    ("X-Content-Type-Options", "nosniff"),
    (
        "Content-Security-Policy",
        "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; "
        "object-src 'none'; base-uri 'none'; frame-ancestors 'none'",
    ),
    ("Referrer-Policy", "no-referrer"),
)
sys.exit(server.main())
"""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    args = parser.parse_args()
    if os.name == 'nt':
        print('bench CLI worker smoke: POSIX executable fixture only')
        return 0
    with tempfile.TemporaryDirectory(prefix='bench-cli-') as temp:
        root = Path(temp).resolve()
        native = root / 'metacodes'
        shutil.copy2(args.binary.resolve(), native)
        cfg, binary_dir = fixture(root)
        config = json.loads(cfg.read_text())
        state = root / 'state'
        env = {**os.environ, 'PATH': str(binary_dir) + os.pathsep + os.environ.get('PATH', ''),
               'TOKENJOY_API_KEY': 'private-cli-fixture', 'HOME': str(root),
               'METACODES_BENCH_URL': ''}
        command = [str(native), '--state-dir', str(state), 'bench']
        def invoke(extra, expected=0):
            p = subprocess.run(command + extra, env=env, cwd=root, capture_output=True, text=True, timeout=40)
            assert p.returncode == expected, (p.returncode, p.stdout, p.stderr)
            return p.stdout
        ready = state / 'bench/service.json'
        release = root / 'release-harbor'
        legacy = None
        try:
            assert '暂无' in invoke(['list'])
            initial = json.loads(invoke(['info', '--json']))
            assert initial['service'] == 'metacodes-bench'
            invoke(['--not-an-option'], expected=2)
            jobs_dir = ready.parent / 'jobs'
            config_path = ready.with_name('workbench.json')
            atomic_json(config_path, {**config, 'jobs_dir': str(jobs_dir)})
            manager = RunManager(jobs_dir, config_path)
            def start_legacy(port='0'):
                ready.unlink(missing_ok=True)
                process = subprocess.Popen(
                    [sys.executable, '-c', LEGACY_SERVER, '--config', str(config_path),
                     '--jobs-dir', str(jobs_dir), '--port', port, '--ready-file', str(ready)],
                    env={**env, 'FAKE_BENCH_RELEASE_FILE': str(release)}, cwd=REPO,
                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                )
                deadline = time.monotonic() + 10
                while not ready.exists():
                    assert process.poll() is None, 'legacy workbench exited before ready'
                    assert time.monotonic() < deadline, 'legacy workbench did not become ready'
                    time.sleep(.05)
                return process

            legacy = start_legacy()
            old_url = json.loads(ready.read_text())['url']
            port = str(urlsplit(old_url).port)
            with urlopen(old_url, timeout=5) as response:
                assert 'Content-Security-Policy' in response.headers
            # The old service really requires its capability: a run is
            # started on it with the capability, as its page did.
            launch = Request(old_url + 'api/runs', data=json.dumps(
                {'model': config['model'], 'tasks': ['fix-git'], 'attempts': 1, 'concurrency': 1}).encode(),
                headers={'Content-Type': 'application/json', 'Authorization': 'Bearer ' + LEGACY_TOKEN})
            with urlopen(launch, timeout=10) as response:
                active = json.load(response)
            assert wait_status(manager, active['name'], 'running') == 'running', active
            # `bench stop` stops it with the capability from the local receipt.
            assert json.loads(invoke(['stop', '--json']))['stopped']
            assert legacy.wait(timeout=10) == 0
            # Opening the workbench while an old service runs replaces it.
            legacy = start_legacy(port)
            assert json.loads(ready.read_text())['token'] == LEGACY_TOKEN
            started = json.loads(invoke(['--no-open', '--json', '--port', port,
                                        '--bundle', config['bundle'], '--provider-config', config['provider_config'],
                                        '--model', config['model'], '--harbor', config['harbor']]))
            assert started['url'] == old_url, started
            assert legacy.wait(timeout=10) == 0, 'the old service must be replaced'
            assert 'token' not in json.loads(ready.read_text()), 'the new receipt carries no capability'
            for path in ('', 'index.html'):
                with urlopen(old_url + path, timeout=5) as response:
                    assert 'Content-Security-Policy' not in response.headers, path
                    assert response.headers['X-Frame-Options'] == 'DENY', path
                    assert response.headers['X-Content-Type-Options'] == 'nosniff', path
            with urlopen(old_url + 'api/run?name=' + active['name'], timeout=5) as response:
                assert json.load(response)['status'] == 'running', active
            release.touch()
            upgraded_run = wait_run(manager, active['name'])
            assert upgraded_run['status'] == 'finished', upgraded_run

            second = json.loads(invoke(['--no-open', '--json']))
            assert started['url'] == second['url'], 'must reuse ready service'
            completed = json.loads(invoke(['run', '--task', 'fix-git', '--wait', '--json']))
            assert completed['status'] == 'finished', completed
            assert '#/run/' in completed['url']
            jobs = json.loads(invoke(['list', '--json']))['jobs']
            assert len(jobs) == 2 and all(job['summary']['counts']['pass'] == 1 for job in jobs), jobs
            assert 'private-cli-fixture' not in json.dumps(jobs)
            info = json.loads(invoke(['info', '--json']))
            assert [e['name'] for e in info['executors']] == ['local'] and info['default_executor'] == 'local', info
            suites = {s['id']: s for s in info['suites']}
            assert suites['aime-2025']['executors']['local']['ready'], suites['aime-2025']
            assert suites['aime-2025']['ready'] and suites['aime-2025']['task_count'] == 30, suites['aime-2025']
            aime = json.loads(invoke(['run', '--suite', 'aime-2025', '--task', 'aime_ii-3', '--wait', '--json']))
            assert aime['status'] == 'finished' and aime['suite'] == 'aime-2025', aime
            argv = json.loads((state / 'bench/jobs' / aime['name'] / 'argv.json').read_text())
            assert argv[argv.index('-d') + 1] == 'aime@1.0' and argv[argv.index('-i') + 1] == 'aime_ii-3', argv
            with_config = [str(native), '--state-dir', str(root / 'remote'), 'bench', 'info', '--json', '--url', started['url']]
            remote = subprocess.run(with_config, env=env, cwd=root, capture_output=True, text=True, timeout=15)
            assert remote.returncode == 0, remote.stderr
            assert json.loads(remote.stdout)['can_run']
            assert json.loads(invoke(['stop', '--json']))['stopped']
            status = json.loads(invoke(['db', 'status', '--json']))
            assert status['format'] == 'SQLite' and status['counts']['trials'] == 3, status  # fix-git, aime and the upgrade run
            assert status['location'] == str((state / 'bench/bench.sqlite3').resolve()), status
            copy = root / 'copy.sqlite3'
            moved = json.loads(invoke(['db', 'migrate', '--to', str(copy), '--switch', '--json']))
            assert moved['switched'] and moved['tables']['trials']['verified'] == 3, moved
            assert json.loads(invoke(['db', 'status', '--json']))['location'] == str(copy.resolve())
            invoke(['db', 'status', '--store-postgres', 'postgresql://u:secret@db/bench'], expected=1)
            print('bench CLI smoke: extraction, info/list, suites, executors, service reuse, upgrade with active worker, remote client, run/wait, result link '
                  'and evaluation database status/migrate passed (paid=0)')
        finally:
            release.touch()
            if legacy is not None and legacy.poll() is None:
                legacy.kill()
                legacy.wait(timeout=5)
            if ready.exists():
                record = json.loads(ready.read_text())
                if legacy is None or record['pid'] != legacy.pid:
                    try:
                        os.kill(record['pid'], signal.SIGTERM)
                    except ProcessLookupError:
                        pass
    return 0


if __name__ == '__main__':
    sys.exit(main())
