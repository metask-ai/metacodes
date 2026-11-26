from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

if __package__:
    from . import test_ids as ids
else:
    import test_ids as ids


SOURCES = 'tests/test_ids/linux-sources.tsv'
LEGS = ('units', 'product', 'checks')
META = 'test-ids-meta.json'
TSV = 'test-ids.tsv'
PRE_INVENTORY_WIRING = {
    ('a4fc3a7282105248eac18302615348722ed06d17', '8c080596871248665c6f05e3d97b80695aa7af8e'),
    ('f9d1cce3e251a0946354603c26e0b95fae8c74ac', 'd33b70ff8a2a1a8858c8d6520261176991ecbc6d'),
}


def git(*args):
    return subprocess.check_output(['git', *args], text=True).strip()


def require(value, message):
    if not value:
        raise ValueError(message)


def expected_sources(rev, event):
    result = subprocess.run(['git', 'show', f'{rev}:{SOURCES}'], capture_output=True, text=True)
    if result.returncode:
        wiring = (git('rev-parse', f'{rev}:build.zig'), git('rev-parse', f'{rev}:.github/workflows/ci.yml'))
        require(wiring in PRE_INVENTORY_WIRING, 'base predates the Linux ID inventory and has unknown test wiring')
        bootstrap = (ids.ROOT / SOURCES).with_name('linux-sources-pre-inventory.tsv')
        require(sha256(bootstrap) == 'ddfebf5ab1eb5dcb8a1c5ed159d3a31b2b991138d75a226e58e0e76fcd3f2edd',
                'cannot verify a pre-inventory baseline with a changed source plan')
        plan = bootstrap.read_text()
    else:
        plan = result.stdout
    expected = Counter()
    for line in plan.splitlines():
        leg, source, root, count = line.split('\t')
        if leg == 'pr-checks':
            if event not in ('pull_request', 'merge_group'):
                continue
            leg = 'checks'
        require(leg in LEGS and int(count) > 0, f'invalid Linux source: {line}')
        expected[leg, source, root] += int(count)
    require(set(leg for leg, _, _ in expected) == set(LEGS), 'incomplete Linux inventory')
    return expected


def check_raw(raw, expected, prefix='test-ids-raw-'):
    found = Counter()
    leg_dirs = {prefix + leg: leg for leg in LEGS}
    seen_python_tests = {leg: set() for leg in LEGS}
    for record in raw.rglob('*.tsv'):
        parts = record.relative_to(raw).parts
        require(len(parts) == 2 and parts[0] in leg_dirs, f'unexpected raw test source: {record}')
        leg = leg_dirs[parts[0]]
        source, separator, _ = record.stem.partition('--')
        require(separator, f'unrecognized source: {record.name}')
        with record.open(encoding='utf-8') as handle:
            header = handle.readline().rstrip('\r\n')
            require(header.startswith('root\t'), f'missing test root: {record.name}')
            if source.startswith('py-'):
                tests = {line.rstrip('\r\n').partition('\t')[2] for line in handle}
                require(tests and '' not in tests, f'empty Python record: {record.name}')
                require(not tests.intersection(seen_python_tests[leg]), f'overlapping Python records: {record.name}')
                seen_python_tests[leg].update(tests)
            else:
                require(handle.readline(), f'empty Zig record: {record.name}')
        found[leg, source, header[5:] or '.'] += 1
    require(found == expected, f'Linux source inventory mismatch: missing {expected-found}, extra {found-expected}')


def pins():
    merge = git('rev-parse', 'HEAD')
    require(merge == os.environ['GITHUB_SHA'], 'checkout differs from the tested merge')
    event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
    base = git('rev-parse', 'HEAD^1')
    pr = event['pull_request']
    require(base == pr['base']['sha'] and git('rev-parse', 'HEAD^2') == pr['head']['sha'],
            'tested merge parents differ from the event')
    return dict(base=base, tree=git('rev-parse', 'HEAD^1^{tree}'), merge=merge, head_tree=git('rev-parse', 'HEAD^{tree}'))


def download(run, name, directory, pattern=False):
    args = ['gh', 'run', 'download', str(run['id']), '--repo', os.environ['GITHUB_REPOSITORY'],
            '--pattern' if pattern else '--name', name, '--dir', str(directory)]
    return subprocess.run(args, check=False).returncode == 0


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def cached(run, pin, tmp):
    repo = os.environ['GITHUB_REPOSITORY']
    if (run['conclusion'] != 'success' or run['path'] != '.github/workflows/ci.yml'
            or run['repository']['full_name'] != repo or run['event'] not in ('pull_request', 'schedule', 'workflow_dispatch')):
        return None
    artifact = tmp / 'artifact'
    if not download(run, 'test-ids', artifact):
        return None
    meta = json.loads((artifact / META).read_text())
    if meta['tree'] != pin['tree'] or not re.fullmatch('[0-9a-f]{40}', meta['commit']):
        return None
    revision = ids.github_json(f"repos/{repo}/git/commits/{meta['commit']}")
    if revision['tree']['sha'] != pin['tree']:
        return None
    if run['event'] == 'pull_request':
        if [p['sha'] for p in revision['parents'][1:]] != [run['head_sha']]:
            return None
    elif run['head_branch'] != 'main' or run['head_sha'] != meta['commit']:
        return None
    expected = expected_sources(pin['base'], 'pull_request')
    if run['event'] != 'pull_request' and expected_sources(pin['base'], run['event']) != expected:
        return None
    if (meta.get('scope') == 'full' and meta.get('verified_full_run') == run['id'] and meta.get('repository') == repo
            and meta.get('sha256') == sha256(artifact / TSV)):
        return (artifact / TSV).read_bytes()
    if not download(run, 'change-scope', tmp / 'scope'):
        return None
    scope = json.loads((tmp / 'scope/change-scope.json').read_text())
    if scope.get('scope') != 'full' or scope.get('fast_path') is not False:
        return None
    raw = tmp / 'raw'
    if not download(run, 'test-ids-raw-*', raw, pattern=True):
        return None
    check_raw(raw, expected)
    output = tmp / 'rebuilt.tsv'
    collect_base(pin, raw, output)
    require(output.read_bytes() == (artifact / TSV).read_bytes(), 'cached aggregate differs from raw records')
    return output.read_bytes()


def collect_base(pin, raw, output):
    with tempfile.TemporaryDirectory() as tmp:
        checkout = Path(tmp) / 'base'
        subprocess.run(['git', 'worktree', 'add', '--quiet', '--detach', str(checkout), pin['base']], check=True)
        try:
            subprocess.run(['python3', 'scripts/test_ids.py', 'collect', '--raw', str(raw.resolve()), '--tty',
                            'tests/tty/cases', '--output', str(output.resolve())], cwd=checkout, check=True)
        finally:
            subprocess.run(['git', 'worktree', 'remove', '--force', str(checkout)], check=True)


def plan(args):
    pin = pins()
    require(args.scope == 'full' and args.complete == 'true' and args.fast == 'false', 'migration needs the full test scope')
    repo = os.environ['GITHUB_REPOSITORY']
    mode = 'replay'
    try:
        runs = list(ids.candidate_runs(repo, pin['base'], ids.github_json))
    except subprocess.CalledProcessError as error:
        print(f'Could not list baseline artifacts: {error}')
        runs = []
    for run in runs:
        with tempfile.TemporaryDirectory() as tmp:
            try:
                data = cached(run, pin, Path(tmp))
            except (KeyError, ValueError, OSError, subprocess.CalledProcessError, ids.TestIdError) as error:
                print(f"Unusable test IDs from run {run['id']}: {error}")
                continue
            if data:
                args.directory.mkdir(parents=True, exist_ok=True)
                (args.directory / TSV).write_bytes(data)
                (args.directory / META).write_text(json.dumps(pin))
                mode = 'cache'
                print(f"Using full Linux IDs from run {run['id']}")
                break
    with Path(os.environ['GITHUB_OUTPUT']).open('a') as handle:
        for key, value in dict(pin, mode=mode).items():
            print(f'{key}={value}', file=handle)
    print(f"Migration baseline {pin['base']} ({pin['tree']}), head {pin['head_tree']}: {mode}")


def compare(args):
    pin = pins()
    require(pin == {key: os.environ['PIN_' + key.upper()] for key in pin}, 'baseline plan differs from tested merge')
    require(args.scope == 'full' and args.complete == 'true', 'partial migration head')
    head_meta = json.loads((args.head.parent / META).read_text())
    require(head_meta['commit'] == pin['merge'] and head_meta['tree'] == pin['head_tree']
            and head_meta.get('verified_full_run') == int(os.environ['GITHUB_RUN_ID'])
            and head_meta.get('sha256') == sha256(args.head), 'unverified migration head')
    if args.mode == 'cache':
        require(json.loads((args.directory / META).read_text()) == pin, 'cache belongs to another merge')
    else:
        require(args.mode == 'replay' and os.environ['REPLAY_RESULT'] == 'success', 'baseline collection failed')
        for leg in LEGS:
            stamp = args.raw / f'migration-raw-{leg}' / 'revision.json'
            require(json.loads(stamp.read_text()) == [pin['base'], pin['tree'], leg], f'wrong {leg} baseline')
        check_raw(args.raw, expected_sources(pin['base'], 'pull_request'), prefix='migration-raw-')
        args.directory.mkdir(parents=True, exist_ok=True)
        collect_base(pin, args.raw, args.directory / TSV)
    base = ids.Base(ids.parse_ids((args.directory / TSV).read_text()), f"Base: {pin['base']} ({args.mode}).", True)
    head = ids.parse_ids(args.head.read_text())
    renamed, removed = ids.read_explanations(Path.cwd(), pin['base'])
    report, failed = ids.ci_report(head, base, renamed, removed, True)
    ids.write_report(report, os.environ.get('GITHUB_STEP_SUMMARY'))
    return int(failed)


def attest(args):
    check_raw(args.raw, expected_sources('HEAD', os.environ['GITHUB_EVENT_NAME']))
    path = args.directory / META
    meta = json.loads(path.read_text())
    require(meta['tree'] == git('rev-parse', 'HEAD^{tree}') and meta['commit'] == git('rev-parse', 'HEAD'), 'wrong head artifact')
    meta.update(scope='full', repository=os.environ['GITHUB_REPOSITORY'], verified_full_run=int(os.environ['GITHUB_RUN_ID']),
                sha256=sha256(args.directory / TSV))
    path.write_text(json.dumps(meta) + '\n')


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest='command', required=True)
    for name in ('plan', 'compare', 'attest'):
        cmd = commands.add_parser(name)
        cmd.add_argument('--directory', required=True, type=Path)
        if name != 'attest':
            cmd.add_argument('--scope', required=True)
            cmd.add_argument('--complete', required=True)
        if name != 'plan':
            cmd.add_argument('--raw', required=True, type=Path)
        if name == 'plan':
            cmd.add_argument('--fast', required=True)
        if name == 'compare':
            cmd.add_argument('--mode', required=True)
            cmd.add_argument('--head', required=True, type=Path)
    args = parser.parse_args()
    return {'plan': plan, 'compare': compare, 'attest': attest}[args.command](args)


if __name__ == '__main__':
    raise SystemExit(main())
