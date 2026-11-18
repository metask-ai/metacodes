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
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from scripts.eval.tests.test_bench_workbench import fixture  # noqa: E402


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    args = parser.parse_args()
    if os.name == 'nt':
        print('bench CLI worker smoke: POSIX executable fixture only')
        return 0
    with tempfile.TemporaryDirectory(prefix='bench-cli-') as temp:
        root = Path(temp)
        native = root / 'metacodes'
        shutil.copy2(args.binary.resolve(), native)
        cfg, binary_dir = fixture(root)
        config = json.loads(cfg.read_text())
        state = root / 'state'
        env = {**os.environ, 'PATH': str(binary_dir) + os.pathsep + os.environ.get('PATH', ''),
               'TOKENJOY_API_KEY': 'private-cli-fixture', 'HOME': str(root),
               'METACODES_BENCH_URL': '', 'METACODES_BENCH_TOKEN': ''}
        command = [str(native), '--state-dir', str(state), 'bench']
        def invoke(extra, expected=0):
            p = subprocess.run(command + extra, env=env, cwd=root, capture_output=True, text=True, timeout=40)
            assert p.returncode == expected, (p.returncode, p.stdout, p.stderr)
            return p.stdout
        ready = state / 'bench/service.json'
        try:
            assert '暂无' in invoke(['list'])
            initial = json.loads(invoke(['info', '--json']))
            assert initial['service'] == 'metacodes-bench'
            invoke(['--not-an-option'], expected=2)
            started = json.loads(invoke(['--no-open', '--json', '--bundle', config['bundle'],
                                '--provider-config', config['provider_config'], '--model', config['model'],
                                '--harbor', config['harbor']]))
            assert '?token=' in started['url']
            second = json.loads(invoke(['--no-open', '--json']))
            assert started['url'] == second['url'], 'must reuse ready service'
            completed = json.loads(invoke(['run', '--task', 'fix-git', '--wait', '--json']))
            assert completed['status'] == 'finished', completed
            assert '#/run/' in completed['url']
            jobs = json.loads(invoke(['list', '--json']))['jobs']
            assert len(jobs) == 1 and jobs[0]['summary']['counts']['pass'] == 1, jobs
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
            assert status['format'] == 'SQLite' and status['counts']['trials'] == 2, status  # fix-git and aime
            assert status['location'] == str((state / 'bench/bench.sqlite3').resolve()), status
            copy = root / 'copy.sqlite3'
            moved = json.loads(invoke(['db', 'migrate', '--to', str(copy), '--switch', '--json']))
            assert moved['switched'] and moved['tables']['trials']['verified'] == 2, moved
            assert json.loads(invoke(['db', 'status', '--json']))['location'] == str(copy.resolve())
            invoke(['db', 'status', '--store-postgres', 'postgresql://u:secret@db/bench'], expected=1)
            print('bench CLI smoke: extraction, info/list, suites, executors, service reuse, remote client, run/wait, result link '
                  'and evaluation database status/migrate passed (paid=0)')
        finally:
            if ready.exists():
                record = json.loads(ready.read_text())
                try:
                    os.kill(record['pid'], signal.SIGTERM)
                except ProcessLookupError:
                    pass
    return 0


if __name__ == '__main__':
    sys.exit(main())
