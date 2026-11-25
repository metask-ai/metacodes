"""`metacodes bench build --ref`: real git, a fake `docker` standing in for the builder."""
from __future__ import annotations

import hashlib
import io
import json
import os
import shlex
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

from scripts.eval.harbor import cli
from scripts.eval.harbor.bench import data
from scripts.eval.harbor.bench.runner import RunManager
from scripts.eval.harbor.bench.workbench import Workbench
from scripts.eval.harbor.viewer import server
from scripts.eval.harbor.bench import builds, executors
from scripts.eval.harbor.bench.profiles import bundle_choices
from scripts.eval.harbor.command import BUNDLE_EXECUTABLES
from scripts.eval.tests.posix_only import POSIX

FAKE_DOCKER = """\
import json, os, pathlib, sys, time
args = sys.argv[1:]
with pathlib.Path(os.environ['FAKE_DOCKER_LOG']).open('a') as log:
    log.write(json.dumps(args) + chr(10))
toolchains = next((pathlib.Path(a.split(':')[0]) for a in args if a.endswith(':/toolchains')), None)
if args[0] == 'run' and toolchains is not None:
    busy = toolchains / '.fake-busy'
    if busy.exists():
        (toolchains.parent / 'overlap').write_text('yes')
    busy.write_text('1')
    time.sleep(float(os.environ.get('FAKE_TOOLCHAIN_DELAY', '0')))
    busy.unlink()
if args[0] != 'run' or not any(a.endswith(':/out') for a in args):
    sys.exit(0)
out = next(pathlib.Path(a.split(':')[0]) for a in args if a.endswith(':/out'))
commit = next(a.split('=', 1)[1] for a in args if a.startswith('COMMIT='))
time.sleep(float(os.environ.get('FAKE_BUILD_DELAY', '0')))
if os.environ.get('FAKE_BUILD_FAIL'):
    sys.exit(3)
for rel in {executables!r}:
    (out / rel).parent.mkdir(parents=True, exist_ok=True)
    (out / rel).write_text(commit)
(out / 'manifest.json').write_text(json.dumps({{'target': {{'os': 'linux'}}, 'release': {{'version': '0.0.0-dev+' + commit[:12]}},
                                              'source': {{'commit': commit, 'dirty': False}}}}))
"""


# `ssh <options> <host> <command>`: the command runs on this machine, in the
# fake executor's home directory.
FAKE_SSH = """\
import os, sys
args = sys.argv[1:]
i = 0
while args[i].startswith('-'):
    i += 2 if args[i] in ('-o', '-p', '-i', '-R') else 1
os.chdir(os.environ['FAKE_REMOTE_HOME'])
os.execvp('sh', ['sh', '-c', ' '.join(args[i + 1:])])
"""

FAKE_MACOS_TAR = """\
import io, os, sys, tarfile
args = sys.argv[1:]
if args[:2] != ['-cf', '-'] or os.environ.get('COPYFILE_DISABLE') == '1':
    real = next(p for p in ('/usr/bin/tar', '/bin/tar') if os.path.exists(p))
    os.execv(real, [real] + args)
root, names, i = '.', [], 2
while i < len(args):
    if args[i] == '-C':
        root, i = args[i + 1], i + 2
    else:
        names.append(args[i])
        i += 1
with tarfile.open(fileobj=sys.stdout.buffer, mode='w|') as archive:
    def add(name):
        parent, base = os.path.split(name)
        metadata = tarfile.TarInfo(os.path.join(parent, '._' + base))
        metadata.size = 4
        archive.addfile(metadata, io.BytesIO(b'\\x00\\x05\\x16\\x07'))
        archive.add(os.path.join(root, name), name, recursive=False)
        if os.path.isdir(os.path.join(root, name)):
            for child in sorted(os.listdir(os.path.join(root, name))):
                add(os.path.join(name, child))
    for name in names:
        add(name)
"""

# The executor's node: `metacodes bench node ...` with its own state root.
FAKE_NODE = """\
import sys
sys.path.insert(0, {root!r})
from scripts.eval.harbor import cli
from scripts.eval.harbor.bench import data
from scripts.eval.harbor.bench.runner import RunManager
from scripts.eval.harbor.bench.workbench import Workbench
from scripts.eval.harbor.viewer import server
sys.exit(cli.main(['--state-root', {state!r}] + sys.argv[2:]))
"""


def write_python_tool(path: Path, source: str) -> None:
    path.with_name(path.name + '.py').write_text(source)
    path.write_text(f'#!/bin/sh\nexec {shlex.quote(sys.executable)} "$0.py" "$@"\n')
    path.chmod(0o755)


@unittest.skipUnless(POSIX, 'fake tools use POSIX launchers')
class PythonToolTest(unittest.TestCase):
    def test_child_uses_the_selected_interpreter_and_preserves_arguments(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            python = root / "test user's python"
            python.symlink_to(sys.executable)
            tool = root / 'fake tool'
            with patch.object(sys, 'executable', str(python)):
                write_python_tool(tool, 'import json, sys\nprint(json.dumps([sys.executable, *sys.argv[1:]]))')
            output = subprocess.check_output([str(tool), 'two words', ''], text=True)
            self.assertEqual(json.loads(output), [str(python), 'two words', ''])


@unittest.skipUnless(POSIX, 'process groups are POSIX')
class SignalGroupTest(unittest.TestCase):
    def test_a_group_whose_leader_already_exited_is_not_an_error(self):
        process = subprocess.Popen([sys.executable, '-c', 'pass'], start_new_session=True)
        self.addCleanup(process.wait)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and 'Z' not in subprocess.run(
                ['ps', '-o', 'stat=', '-p', str(process.pid)], capture_output=True, text=True).stdout:
            time.sleep(0.05)
        executors.signal_group(process, signal.SIGKILL)
        self.assertEqual(process.wait(), 0)

    def test_a_running_group_is_signalled(self):
        process = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'], start_new_session=True)
        self.addCleanup(process.wait)
        executors.signal_group(process, signal.SIGKILL)
        self.assertEqual(process.wait(timeout=10), -signal.SIGKILL)


@unittest.skipUnless(POSIX, 'fake docker and process groups are POSIX')
class GitRefBuildTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.bench = self.root / 'state' / 'bench'
        self.bench.mkdir(parents=True)
        tools = self.root / 'bin'
        tools.mkdir()
        write_python_tool(tools / 'docker', FAKE_DOCKER.format(executables=list(BUNDLE_EXECUTABLES)))
        env = patch.dict(os.environ, {'PATH': str(tools) + os.pathsep + os.environ['PATH'],
                                      'FAKE_DOCKER_LOG': str(self.root / 'docker.log'),
                                      'GIT_AUTHOR_NAME': 't', 'GIT_AUTHOR_EMAIL': 't@example.com',
                                      'GIT_COMMITTER_NAME': 't', 'GIT_COMMITTER_EMAIL': 't@example.com'})
        env.start()
        self.addCleanup(env.stop)
        self.repo = self.root / 'source'
        self.repo.mkdir()
        self.git('init', '-q', '-b', 'main')
        (self.repo / 'build.zig.zon').write_text('.{ .minimum_zig_version = "0.16.0" }')
        (self.repo / 'control-plane' / 'lean').mkdir(parents=True)
        (self.repo / 'control-plane' / 'lean' / 'lean-toolchain').write_text('leanprover/lean4:v4.14.0\n')
        self.git('add', '.')
        self.git('commit', '-q', '-m', 'one')

    def git(self, *args, repo=None):
        return subprocess.run(['git', '-C', str(repo or self.repo), *args], check=True,
                              capture_output=True, text=True).stdout.strip()

    def build(self, ref, repo=None, **kwargs):
        return builds.bundle(ref, self.bench, str(repo or self.repo), **kwargs)

    def calls(self):
        path = self.root / 'docker.log'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def builds_run(self):
        return [c for c in self.calls() if c[0] == 'run' and any(a.endswith(':/out') for a in c)]

    def toolchain_runs(self):
        return [c for c in self.calls() if c[0] == 'run' and any(a.endswith(':/toolchains') for a in c)]

    def record(self, commit):
        path = builds.unit_path(self.bench, commit)
        return path.parent / (path.name + '.json')

    def checkout(self, mirror, commit, probe):
        source = builds.source_bundle(mirror, commit, self.root / (commit + '.bundle'))
        return subprocess.run(['bash', '-c', builds.CHECKOUT_SCRIPT + probe], capture_output=True, text=True,
                              env={**os.environ, 'SOURCE': str(source), 'COMMIT': commit, 'TMPDIR': str(self.root)})

    def test_ref_builds_once_per_commit_into_a_profile_choice(self):
        first = self.git('rev-parse', 'HEAD')
        unit, info = self.build('main')
        self.assertEqual(unit, self.bench / 'bundles' / f'metacodes-git-{first[:12]}-x86_64-linux-gnu')
        self.assertEqual((unit / 'bin' / 'metacodes').read_text(), first)
        self.assertEqual((info['ref'], info['commit']), ('main', first))
        build = self.builds_run()[0]
        self.assertIn('COMMIT=' + first, build)
        self.assertIn(builds.image(), build)
        self.assertEqual(build[build.index('--platform') + 1], 'linux/amd64')
        mounts = [build[i + 1] for i, a in enumerate(build) if a == '-v']
        self.assertEqual([m for m in mounts if not m.endswith(':ro')], [m for m in mounts if m.endswith(':/out')])
        self.assertTrue(any(m.endswith('/source.bundle:/source.bundle:ro') for m in mounts))
        self.assertFalse(any('source.git' in m for c in self.calls() for m in c))
        self.assertTrue(any(m.endswith('/zig/0.16.0:/opt/zig:ro') for m in mounts))
        self.assertTrue(any(m.endswith('/lean/leanprover-lean4-v4.14.0:/opt/lean:ro') for m in mounts))
        toolchain = self.toolchain_runs()[0]
        self.assertIn('ZIG_VERSION=0.16.0', toolchain)
        self.assertFalse(any(a.endswith(':/mirror:ro') or a.endswith(':/out') for a in toolchain))
        self.assertEqual(bundle_choices({}, self.bench / 'workbench.json'), [])
        choices = bundle_choices({'source_repo': str(self.repo)}, self.bench / 'workbench.json')
        self.assertEqual([(c['id'], c['commit']) for c in choices], [(unit.name, first)])
        self.assertNotIn('source', json.dumps([{k: v for k, v in c.items() if k != 'source'} for c in choices]))
        self.assertEqual(self.build(first[:8])[0], unit)
        self.assertEqual(len(self.builds_run()), 1)
        self.git('commit', '-q', '--allow-empty', '-m', 'two')
        second = self.git('rev-parse', 'HEAD')
        self.assertEqual((self.build('main')[0] / 'bin' / 'metacodes').read_text(), second)
        self.assertEqual(len(self.builds_run()), 2)

    def remote_executor(self):
        home = self.root / 'remote-home'
        node = home / '.metacodes-bench' / 'bin' / 'metacodes'
        node.parent.mkdir(parents=True)
        write_python_tool(node, FAKE_NODE.format(root=str(Path(__file__).resolve().parents[3]),
                                                 state=str(self.root / 'remote-state')))
        write_python_tool(self.root / 'bin' / 'ssh', FAKE_SSH)
        env = patch.dict(os.environ, {'FAKE_REMOTE_HOME': str(home)})
        env.start()
        self.addCleanup(env.stop)
        return executors.SshExecutor(name='gpu', host='gpu.example')

    def test_commits_are_listed_newest_first_and_up_to_a_day(self):
        first = self.git('rev-parse', 'HEAD')
        for day in ('2026-11-01', '2026-11-03'):
            with patch.dict(os.environ, {'GIT_COMMITTER_DATE': day + 'T12:00:00+00:00'}):
                self.git('commit', '-q', '--allow-empty', '-m', 'on ' + day)
        cache = self.bench / 'git'
        listed = builds.commits(cache, str(self.repo))
        self.assertEqual([c['subject'] for c in listed], ['on 2026-11-03', 'on 2026-11-01', 'one'])
        self.assertEqual(listed[0]['committed_at'][:10], '2026-11-03')
        self.assertEqual(listed[-1]['commit'], first)
        self.assertEqual([c['subject'] for c in builds.commits(cache, str(self.repo), until='2026-11-02')][:1],
                         ['on 2026-11-01'])
        self.assertEqual(len(builds.commits(cache, str(self.repo), limit=1)), 1)
        for bad in ({'until': '11/02'}, {'limit': 0}, {'limit': 10_000}, {'ref': 'a..b'}):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                builds.commits(cache, str(self.repo), **bad)

    def test_ssh_executor_builds_on_its_node_and_the_unit_comes_back(self):
        executor = self.remote_executor()
        commit = self.git('rev-parse', 'HEAD')
        unit, info = builds.build_on(executor, 'main', self.bench, str(self.repo))
        remote_unit = builds.unit_path(self.root / 'remote-state' / 'bench', commit)
        self.assertTrue((remote_unit / 'bin' / 'metacodes').is_file())
        self.assertEqual(unit, builds.unit_path(self.bench, commit))
        self.assertEqual((unit / 'bin' / 'metacodes').read_text(), commit)
        self.assertEqual(executors.tree_digest(unit, executors.tree_files(unit)),
                         executors.tree_digest(remote_unit, executors.tree_files(remote_unit)))
        self.assertEqual(info['commit'], commit)
        self.assertTrue(info['committed_at'])
        self.assertFalse((self.bench / 'git').joinpath('source.git').exists())
        choices = bundle_choices({'source_repo': str(self.repo)}, self.bench / 'workbench.json')
        self.assertEqual([c['id'] for c in choices], [unit.name])
        self.assertTrue(choices[0]['label'].startswith('git ' + commit[:8] + ' · '))
        self.assertEqual(builds.build_on(executor, commit, self.bench, str(self.repo))[0], unit)
        self.assertEqual(len(self.builds_run()), 1)

    def test_a_unit_comes_back_from_a_node_whose_tar_adds_macos_metadata(self):
        executor = self.remote_executor()
        write_python_tool(self.root / 'bin' / 'tar', FAKE_MACOS_TAR)
        commit = self.git('rev-parse', 'HEAD')
        unit, info = builds.build_on(executor, 'main', self.bench, str(self.repo))
        self.assertEqual((unit / 'bin' / 'metacodes').read_text(), commit)
        self.assertEqual(info['commit'], commit)
        self.assertEqual([p for p in unit.rglob('*') if p.name.startswith('._')], [])

    def test_a_failed_node_build_publishes_nothing_here(self):
        executor = self.remote_executor()
        with patch.dict(os.environ, {'FAKE_BUILD_FAIL': '1'}), patch('sys.stderr', io.StringIO()):
            with self.assertRaisesRegex(ValueError, 'gpu 上的编译失败'):
                builds.build_on(executor, 'main', self.bench, str(self.repo))
        self.assertFalse((self.bench / 'bundles').exists() and any((self.bench / 'bundles').iterdir()))

    def test_cancelling_a_node_build_stops_the_builder_there(self):
        executor = self.remote_executor()
        stop = threading.Event()
        threading.Timer(3.0, stop.set).start()
        with patch.dict(os.environ, {'FAKE_BUILD_DELAY': '20'}):
            started = time.monotonic()
            with self.assertRaisesRegex(ValueError, '取消'):
                builds.build_on(executor, 'main', self.bench, str(self.repo), cancelled=stop.is_set)
        self.assertLess(time.monotonic() - started, 15)
        self.assertTrue(any(c[0] == 'kill' for c in self.calls()))

    def test_a_unit_verified_by_another_repository_is_refused(self):
        executor = self.remote_executor()
        commit = self.git('rev-parse', 'HEAD')
        builds.build_on(executor, 'main', self.bench, str(self.repo))
        record = builds.unit_path(self.root / 'remote-state' / 'bench', commit)
        record = record.parent / (record.name + '.json')
        local = builds.unit_path(self.bench, commit)
        shutil.rmtree(local)
        (local.parent / (local.name + '.json')).unlink()
        value = json.loads(record.read_text())
        record.write_text(json.dumps({**value, 'source_id': builds.source_id('https://example.com/other.git')}))
        with patch('sys.stderr', io.StringIO()), self.assertRaisesRegex(ValueError, '源码仓库验证'):
            builds._fetch_unit(executor, str(record.with_suffix('').with_name(local.name)), local, commit,
                               str(self.repo), lambda: False, subprocess.Popen)
        self.assertFalse(local.exists())
        self.assertEqual(list(local.parent.glob('.fetch-*')), [])

    def test_a_remote_unit_with_a_disallowed_entry_is_refused_with_its_reason(self):
        executor = self.remote_executor()
        commit = self.git('rev-parse', 'HEAD')
        builds.build_on(executor, 'main', self.bench, str(self.repo))
        remote = builds.unit_path(self.root / 'remote-state' / 'bench', commit)
        (remote / 'bin' / 'escape').symlink_to('/etc/passwd')
        local = builds.unit_path(self.bench, commit)
        shutil.rmtree(local)
        (local.parent / (local.name + '.json')).unlink()
        with self.assertRaisesRegex(builds.BuildError, '不允许的条目'):
            builds._fetch_unit(executor, str(remote), local, commit, str(self.repo), lambda: False, subprocess.Popen)
        self.assertFalse(local.exists())
        self.assertEqual(list(local.parent.glob('.fetch-*')), [])

    def test_fetched_archive_may_hold_only_the_unit_and_its_record(self):
        for name, kind in (('../escape', tarfile.REGTYPE), ('unit/link', tarfile.SYMTYPE), ('other', tarfile.REGTYPE)):
            with self.subTest(name=name):
                data = io.BytesIO()
                with tarfile.open(fileobj=data, mode='w') as archive:
                    info = tarfile.TarInfo(name)
                    info.type = kind
                    archive.addfile(info, io.BytesIO(b'') if kind == tarfile.REGTYPE else None)
                data.seek(0)
                staged = self.root / ('staged-' + str(abs(hash(name))))
                staged.mkdir()
                with self.assertRaisesRegex(ValueError, '不允许'):
                    builds._extract(data, staged, 'unit', 'unit.json', lambda: False)
                self.assertFalse((self.root / 'escape').exists())

    def test_page_lists_commits_and_builds_one_in_the_background(self):
        config = self.bench / 'workbench.json'
        config.write_text(json.dumps({'source_repo': str(self.repo)}))
        manager = RunManager(self.bench / 'jobs', config)
        http = server.make_server(Workbench(data.Library([manager.jobs_dir]), manager), '127.0.0.1', 0)
        threading.Thread(target=http.serve_forever, daemon=True).start()
        self.addCleanup(http.server_close)
        self.addCleanup(http.shutdown)
        client = cli.Client(f'http://127.0.0.1:{http.server_address[1]}/')
        commit = self.git('rev-parse', 'HEAD')
        listed = client.request('api/commits?ref=main')['commits']
        self.assertEqual([(c['commit'], c['bundle']) for c in listed], [(commit, None)])
        self.assertIsNone(client.request('api/build')['build'])
        started = client.request('api/build', {'ref': commit[:10]})
        self.assertEqual(started['status'], 'running')
        with self.assertRaisesRegex(Exception, '已有一个编译'):
            client.request('api/build', {'ref': 'main'})
        deadline = time.monotonic() + 60
        while (build := client.request('api/build')['build'])['status'] == 'running' and time.monotonic() < deadline:
            time.sleep(0.2)
        self.assertEqual(build['status'], 'done', build.get('log'))
        unit = builds.unit_path(self.bench, commit)
        self.assertEqual(build['bundle'], unit.name)
        self.assertEqual(client.request('api/commits')['commits'][0]['bundle'], unit.name)
        self.assertIn(unit.name, [b['id'] for b in client.request('api/workbench')['bundles']])
        with self.assertRaisesRegex(Exception, 'YYYY-MM-DD'):
            client.request('api/commits?until=yesterday')

    def test_cli_build_prints_the_bundle_and_refuses_an_empty_ref(self):
        state = self.bench.parent
        (self.bench / 'workbench.json').write_text(json.dumps({'source_repo': str(self.repo)}))
        for _ in range(2):
            output = io.StringIO()
            with patch('sys.stdout', output):
                self.assertEqual(cli.main(['build', '--state-root', str(state), '--ref', 'main', '--json']), 0)
            value = json.loads(output.getvalue())
            self.assertEqual(value['bundle'], builds.unit_path(self.bench, value['commit']).name)
        with patch('sys.stderr', io.StringIO()):
            self.assertEqual(cli.main(['build', '--state-root', str(state), '--ref', '']), 1)
            with self.assertRaises(SystemExit):
                cli.main(['build', '--state-root', str(state)])

    def test_failed_build_publishes_nothing(self):
        with patch.dict(os.environ, {'FAKE_BUILD_FAIL': '1'}):
            with self.assertRaisesRegex(ValueError, '编译失败'):
                self.build('main')
        self.assertEqual(list((self.bench / 'bundles').glob('*')) if (self.bench / 'bundles').exists() else [], [])
        self.assertEqual(list((self.bench / 'git').glob('work-*')), [])

    def test_unknown_and_malformed_refs_are_refused(self):
        with self.assertRaisesRegex(ValueError, 'no-such-branch'):
            self.build('no-such-branch')
        for ref in ('--upload-pack=touch /tmp/x', 'a..b', 'main@{1}', 'x y', '', 7):
            with self.subTest(ref=ref), self.assertRaisesRegex(ValueError, 'git 版本'):
                self.build(ref)
        self.assertEqual(self.calls(), [])

    def test_cancel_during_build_stops_the_builder(self):
        stop = threading.Event()
        threading.Timer(1.0, stop.set).start()
        with patch.dict(os.environ, {'FAKE_BUILD_DELAY': '10'}):
            with self.assertRaisesRegex(ValueError, '取消'):
                self.build('main', cancelled=stop.is_set)
        self.assertTrue(any(c[0] == 'kill' for c in self.calls()))
        self.assertEqual(bundle_choices({}, self.bench / 'workbench.json'), [])

    def test_branch_and_tag_of_one_name_on_different_commits_is_ambiguous(self):
        old = self.git('rev-parse', 'HEAD')
        self.git('tag', 'main')
        self.git('commit', '-q', '--allow-empty', '-m', 'two')
        new = self.git('rev-parse', 'HEAD')
        with self.assertRaisesRegex(ValueError, 'refs/heads/main'):
            self.build('main')
        self.assertEqual(self.build('refs/heads/main')[1]['commit'], new)
        self.assertEqual(self.build('refs/tags/main')[1]['commit'], old)

    def test_commit_only_a_foreign_ref_names_is_never_built(self):
        self.git('commit', '-q', '--allow-empty', '-m', 'candidate')
        candidate = self.git('rev-parse', 'HEAD')
        self.git('update-ref', 'refs/pull/7/head', candidate)
        self.git('reset', '-q', '--hard', 'HEAD~1')
        for ref in (candidate, 'refs/pull/7/head'):
            with self.subTest(ref=ref), self.assertRaisesRegex(ValueError, '不在源码仓库的任何分支或 tag 上'):
                self.build(ref)
        self.assertEqual(self.builds_run(), [])
        self.git('branch', 'published', candidate)
        mirror, commit = builds.resolve(candidate, self.root / 'cache', str(self.repo))
        self.git('branch', '-D', 'published')
        result = self.checkout(mirror, commit, 'git rev-parse HEAD')
        self.assertEqual((result.returncode, result.stdout.strip()), (0, candidate), result.stderr)

    def test_release_tag_reaches_the_checkout_and_tag_or_sha_share_one_build(self):
        commit = self.git('rev-parse', 'HEAD')
        self.git('tag', '-a', '-m', 'release', '0.0.1')
        mirror, _ = builds.resolve('0.0.1', self.root / 'cache', str(self.repo))
        self.assertEqual(builds.tags_at(mirror, commit), ['0.0.1'])
        result = self.checkout(mirror, commit, 'git describe --tags --exact-match HEAD')
        self.assertEqual((result.returncode, result.stdout.strip()), (0, '0.0.1'), result.stderr)
        unit = self.build('0.0.1')[0]
        self.assertEqual(self.build(commit)[0], unit)
        self.assertEqual(len(self.builds_run()), 1)

    def test_offline_reuse_is_bound_to_the_repository_that_verified_it(self):
        commit = self.git('rev-parse', 'HEAD')
        fork = self.root / 'fork'
        subprocess.run(['git', 'clone', '-q', str(self.repo), str(fork)], check=True)
        self.git('commit', '-q', '--allow-empty', '-m', 'fork only', repo=fork)
        forked = self.git('rev-parse', 'HEAD', repo=fork)
        self.build(forked, repo=fork)
        self.build(commit, repo=fork)
        official = {'source_repo': str(self.repo)}

        def listed(cfg):
            return {c['commit'] for c in bundle_choices(cfg, self.bench / 'workbench.json')}

        self.assertEqual(listed({'source_repo': str(fork)}), {forked, commit})
        self.assertEqual(listed(official), set())
        with self.assertRaisesRegex(ValueError, '不在源码仓库的任何分支或 tag 上'):
            self.build(forked)
        self.assertEqual(self.build(commit)[1]['source_id'], builds.source_id(str(self.repo)))
        self.assertEqual(listed(official), {commit})
        self.assertEqual(len(self.builds_run()), 2)
        moved = self.root / 'away'
        self.repo.rename(moved)
        self.assertEqual(self.build(commit)[1]['commit'], commit)
        moved.rename(self.repo)

    def test_records_without_current_proof_are_checked_or_rebuilt(self):
        commit = self.git('rev-parse', 'HEAD')
        self.build('main')
        record = self.record(commit)
        info = json.loads(record.read_text())
        moved = self.root / 'away'
        record.write_text(json.dumps({**info, 'trust_policy': builds.TRUST_POLICY - 1}))
        self.repo.rename(moved)
        with self.assertRaisesRegex(ValueError, '源码仓库'):
            self.build(commit)
        moved.rename(self.repo)
        self.assertEqual(self.build(commit)[1]['trust_policy'], builds.TRUST_POLICY)
        self.assertEqual(len(self.builds_run()), 1)
        unit = builds.unit_path(self.bench, commit)
        for legacy in ({k: info[k] for k in ('ref', 'commit', 'version', 'built_at')},
                       {**{k: info[k] for k in ('ref', 'commit', 'version', 'built_at')},
                        'source_repo': str(self.repo), 'trust_policy': 1}):
            with self.subTest(legacy=sorted(legacy)):
                record.write_text(json.dumps(legacy))
                (unit / 'bin' / 'metacodes').write_text('planted')
                self.build(commit)
                self.assertEqual((unit / 'bin' / 'metacodes').read_text(), commit)
        self.assertEqual(len(self.builds_run()), 3)

    def test_failed_origin_switch_never_verifies_against_the_old_one(self):
        commit = self.git('rev-parse', 'HEAD')
        builds.resolve('main', self.bench / 'git', str(self.repo))
        stub = self.root / 'git-stub'
        stub.mkdir()
        (stub / 'git').write_text('#!/bin/sh\n[ "$1 $2" = "remote set-url" ] && exit 5\nexec %s "$@"\n' % shutil.which('git'))
        (stub / 'git').chmod(0o755)
        with patch.dict(os.environ, {'PATH': str(stub) + os.pathsep + os.environ['PATH']}):
            with self.assertRaisesRegex(ValueError, '切换'):
                self.build(commit, repo=self.root / 'other')
        self.assertEqual(self.builds_run(), [])

    def test_repository_url_and_credentials_stay_out_of_records_and_errors(self):
        commit = self.git('rev-parse', 'HEAD')
        self.build('main')
        self.assertNotIn(str(self.repo), self.record(commit).read_text())
        shutil.rmtree(self.bench / 'git' / 'source.git')
        with self.assertRaises(ValueError) as caught:
            self.build('main', repo='http://bench:s3cret-token@127.0.0.1:9/private.git')
        self.assertNotIn('s3cret-token', str(caught.exception))

    def test_cancel_while_fetching_source(self):
        hit = threading.Event()

        class Hang(BaseHTTPRequestHandler):
            def do_GET(self):
                hit.set()
                time.sleep(30)

            def log_message(self, *_args):
                pass

        http = ThreadingHTTPServer(('127.0.0.1', 0), Hang)
        http.daemon_threads = True
        threading.Thread(target=http.serve_forever, daemon=True).start()
        self.addCleanup(http.server_close)
        self.addCleanup(http.shutdown)
        started = time.monotonic()
        with self.assertRaisesRegex(ValueError, '取消'):
            self.build('main', repo=f'http://127.0.0.1:{http.server_address[1]}/repo.git',
                       cancelled=lambda: hit.is_set())
        self.assertLess(time.monotonic() - started, 10)

    def test_overlapping_builds_are_serialized_and_waiting_is_cancellable(self):
        self.git('commit', '-q', '--allow-empty', '-m', 'two')
        self.git('branch', 'other', 'HEAD~1')
        results = {}

        def build(ref):
            results[ref] = self.build(ref)

        with patch.dict(os.environ, {'FAKE_TOOLCHAIN_DELAY': '.5', 'FAKE_BUILD_DELAY': '.3'}):
            threads = [threading.Thread(target=build, args=(ref,)) for ref in ('main', 'other', 'main')]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join(20)
        self.assertEqual(set(results), {'main', 'other'})
        self.assertFalse((self.bench / 'git' / 'overlap').exists())
        self.assertEqual(len(self.builds_run()), 2)
        with builds._locked(self.bench / 'git', lambda: False):
            with self.assertRaisesRegex(ValueError, '取消'):
                self.build('main', cancelled=lambda: True)

    def test_interrupted_toolchain_install_is_redone_not_reused(self):
        stub = self.root / 'stub'
        stub.mkdir()
        archive = io.BytesIO()
        with tarfile.open(fileobj=archive, mode='w:xz') as tar:
            for name, body in (('zig-x/zig', b'#!/bin/sh\n'), ('zig-x/lib/std.zig', b'complete')):
                info = tarfile.TarInfo(name)
                info.size, info.mode = len(body), 0o755
                tar.addfile(info, io.BytesIO(body))
        (stub / 'zig.tar.xz').write_bytes(archive.getvalue())
        index = {'0.16.0': {'x86_64-linux': {'tarball': 'https://example.invalid/zig.tar.xz',
                                             'shasum': hashlib.sha256(archive.getvalue()).hexdigest()}}}
        (stub / 'index.json').write_text(json.dumps(index))
        (stub / 'curl').write_text('#!/bin/sh\nout=\nwhile [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift;; *) url=$1;; esac; shift; done\n'
                                   'case "$url" in *index.json) cat "%s/index.json";; *) cp "%s/zig.tar.xz" "$out";; esac\n' % (stub, stub))
        (stub / 'curl').chmod(0o755)
        toolchains = self.root / 'toolchains'
        (toolchains / 'zig' / '0.16.0').mkdir(parents=True)
        (toolchains / 'zig' / '0.16.0' / 'zig').write_text('half')
        (toolchains / '.staging-old').mkdir()
        lean = toolchains / 'lean' / 'leanprover-lean4-v4.14.0'
        lean.mkdir(parents=True)
        (lean / '.bench-complete').touch()
        result = subprocess.run(['bash', '-c', builds.TOOLCHAIN_SCRIPT], capture_output=True, text=True,
                                env={**os.environ, 'PATH': str(stub) + os.pathsep + os.environ['PATH'],
                                     'TOOLCHAINS': str(toolchains), 'ZIG_VERSION': '0.16.0',
                                     'LEAN_TOOLCHAIN': 'leanprover/lean4:v4.14.0', 'LEAN_DIR': lean.name})
        self.assertEqual(result.returncode, 0, result.stderr)
        zig = toolchains / 'zig' / '0.16.0'
        self.assertTrue((zig / '.bench-complete').is_file())
        self.assertEqual((zig / 'lib' / 'std.zig').read_text(), 'complete')
        self.assertEqual(list(toolchains.glob('.staging-*')), [])


if __name__ == '__main__':
    unittest.main()
