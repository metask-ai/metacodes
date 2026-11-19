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
            with_config = [str(native), '--state-dir', str(root / 'remote'), 'bench', 'info', '--json', '--url', started['url']]
            remote = subprocess.run(with_config, env=env, cwd=root, capture_output=True, text=True, timeout=15)
            assert remote.returncode == 0, remote.stderr
            assert json.loads(remote.stdout)['can_run']
            assert json.loads(invoke(['stop', '--json']))['stopped']
            print('bench CLI smoke: extraction, info/list, service reuse, remote client, run/wait and result link passed (paid=0)')
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
