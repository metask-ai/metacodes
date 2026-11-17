"""Real HTTP -> worker -> fake Harbor, including cancel and process failures.

The fake writes Harbor's actual job layout and records argv and credentials
separately. No provider or Docker calls are made by these tests.
"""
from __future__ import annotations

import json
import concurrent.futures
import os
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

from scripts.eval.harbor import cli
from scripts.eval.harbor.command import BUNDLE_EXECUTABLES
from scripts.eval.harbor.viewer import data, server
from scripts.eval.harbor.viewer.account import Account
from scripts.eval.harbor.viewer.runner import RunManager, atomic_json
from scripts.eval.tests.posix_only import POSIX

FAKE_HARBOR = '''#!{python}
import json, os, pathlib, sys, time
args = sys.argv[1:]
def arg(flag): return args[args.index(flag) + 1]
root = pathlib.Path(arg('-o')) / arg('--job-name')
root.mkdir(parents=True, exist_ok=True)
(root / 'argv.json').write_text(json.dumps(args))
(root / 'credential-check.json').write_text(json.dumps({{'account_key_matches': bool(os.environ.get('FAKE_EXPECT_ACCOUNT_KEY')) and os.environ.get('METASK_API_KEY') == os.environ.get('FAKE_EXPECT_ACCOUNT_KEY')}}))
(root / 'config.json').write_text(json.dumps({{'agents':[{{'model_name':arg('-m')}}], 'n_attempts':int(arg('-k'))}}))
(root / 'result.json').write_text(json.dumps({{'started_at':'2026-11-16T00:00:00Z','finished_at':None, 'n_total_trials':1}}))
if os.environ.get('FAKE_PROFILE_REQUEST'):
 import ssl, urllib.request
 relay = next(args[i + 1].removeprefix('metrics_proxy=') for i, a in enumerate(args) if a == '--ak' and args[i + 1].startswith('metrics_proxy='))
 ca = next(args[i + 1].removeprefix('metrics_ca=') for i, a in enumerate(args) if a == '--ak' and args[i + 1].startswith('metrics_ca='))
 req = urllib.request.Request(relay + '/fix-git__fake/v1/messages', data=json.dumps({{'model':arg('-m').split('/',1)[1]}}).encode(), headers={{'Authorization':'Bearer ' + os.environ['METASK_API_KEY'], 'Content-Type':'application/json'}})
 with urllib.request.urlopen(req,timeout=5,context=ssl.create_default_context(cafile=ca)) as response: response.read()
time.sleep(float(os.environ.get('FAKE_BENCH_DELAY', '.2')))
if os.environ.get('FAKE_BENCH_FAIL'): sys.exit(7)
t = root / 'fix-git__fake'; t.mkdir()
(t / 'config.json').write_text('{{}}')
(t / 'result.json').write_text(json.dumps({{'task_name':'terminal-bench/fix-git', 'started_at':'2026-11-16T00:00:00Z', 'finished_at':'2026-11-16T00:01:00Z', 'verifier_result':{{'rewards':{{'reward':1.0}}}}}}))
(root / 'result.json').write_text(json.dumps({{'started_at':'2026-11-16T00:00:00Z','finished_at':'2026-11-16T00:01:00Z','n_total_trials':1}}))
'''


def fixture(root):
    bundle = root / 'bundle'
    for file in BUNDLE_EXECUTABLES:
        path = bundle / file
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b'fake')
    atomic_json(bundle / 'manifest.json', {'target': {'os': 'linux'}})
    native = root / 'provider.json'
    atomic_json(native, {'custom_providers': {'tokenjoy': {
        'display_name': 'TokenJoy', 'env_aliases': [{'name': 'TOKENJOY_API_KEY'}],
        'models': [{'request_model_id': 'test-model'}]}}})
    binary_dir = root / 'bin'
    binary_dir.mkdir()
    harbor = binary_dir / 'harbor'
    harbor.write_text(FAKE_HARBOR.format(python=sys.executable))
    harbor.chmod(0o755)
    docker = binary_dir / 'docker'
    docker.write_text('#!/bin/sh\nexit 0\n')
    docker.chmod(0o755)
    config = root / 'workbench.json'
    atomic_json(config, {'bundle': str(bundle), 'provider_config': str(native),
                         'harbor': str(harbor), 'model': 'tokenjoy/test-model',
                         'key_env': 'TOKENJOY_API_KEY', 'metrics_enabled': False})
    return config, binary_dir


def wait_run(manager, name):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        run = next((r for r in manager.runs() if r['name'] == name), {})
        if run.get('status') in ('finished', 'failed', 'cancelled', 'interrupted'):
            return run
        time.sleep(.05)
    raise AssertionError('worker did not finish')


def account_fixture(root, *, expired=True, paginated=False, broken_group=False):
    state = root / 'signed-in-account'
    state.mkdir()
    atomic_json(state / 'auth.json', {'api_key': 'group-glm-secret', 'selected_model': 'glm-test',
                'reasoning_effort': 'high', 'oauth': {'access_token': 'old-access',
                'refresh_token': 'old-refresh', 'expires_at': 0 if expired else int(time.time()) + 3600}})
    calls = []

    class Endpoint(BaseHTTPRequestHandler):
        def reply(self, value, code=200):
            body = json.dumps(value).encode()
            self.send_response(code)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self):
            if self.path == '/v1/messages':
                self.rfile.read(int(self.headers['Content-Length']))
                if self.headers.get('Authorization') != 'Bearer group-claude-secret':
                    self.reply({}, 401)
                    return
                events = [{'type': 'message_start', 'message': {'usage': {'input_tokens': 50}}},
                          {'type': 'content_block_delta', 'delta': {'text': 'output'}},
                          {'type': 'message_delta', 'usage': {'output_tokens': 20}}, {'type': 'message_stop'}]
                body = b''.join(b'data: ' + json.dumps(e).encode() + b'\n\n' for e in events)
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            import urllib.parse
            form = urllib.parse.parse_qs(self.rfile.read(int(self.headers['Content-Length'])).decode())
            calls.append(('refresh', form))
            if self.path != '/oauth/token' or form != {'grant_type': ['refresh_token'],
                    'client_id': ['metacode-cli'], 'refresh_token': ['old-refresh']}:
                self.reply({}, 400)
                return
            time.sleep(.05)
            self.reply({'access_token': 'new-access', 'refresh_token': 'rotated-refresh', 'expires_in': 3600})

        def do_GET(self):
            bearer = self.headers.get('Authorization')
            calls.append((self.path, bearer))
            if self.path.startswith('/api/v1/keys?'):
                if bearer != 'Bearer new-access':
                    self.reply({}, 401)
                    return
                rows = [{'id': 'glm-key', 'key': 'group-glm-secret', 'status': 'active', 'group': {'name': 'GLM'}},
                        {'id': 'claude-key', 'key': 'group-claude-secret', 'status': 'active', 'group': {'name': 'Claude'}},
                        {'id': 'disabled', 'key': 'disabled-secret', 'status': 'disabled'}]
                if broken_group:
                    rows.append({'id': 'broken', 'key': 'broken-secret', 'status': 'active'})
                if paginated and 'page=1&' in self.path:
                    rows = [{'id': n, 'key': 'disabled-secret', 'status': 'disabled'} for n in range(100)]
                self.reply({'data': {'items': rows}})
            elif self.path == '/api/v1/groups/available':
                self.reply({'data': [{'id': 1, 'name': 'GLM', 'status': 'active'},
                                     {'id': 2, 'name': 'Claude', 'status': 'active'},
                                     {'id': 3, 'name': 'Other group', 'status': 'active'}]})
            elif self.path == '/v1/models':
                if bearer == 'Bearer group-glm-secret':
                    self.reply({'data': [{'id': 'glm-test'}, {'id': 'shared'}]})
                elif bearer == 'Bearer group-claude-secret':
                    self.reply({'data': [{'id': 'claude-test'}, {'id': 'shared'}]})
                else:
                    self.reply({}, 503)
            else:
                self.reply({}, 404)

        def log_message(self, *_args):
            pass

    http = ThreadingHTTPServer(('127.0.0.1', 0), Endpoint)
    threading.Thread(target=http.serve_forever, daemon=True).start()
    return state, http, calls


@unittest.skipUnless(POSIX, 'fake executable and worker signal test are POSIX')
class WorkbenchTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        config, binary_dir = fixture(self.root)
        self.env = patch.dict(os.environ, {'PATH': str(binary_dir) + os.pathsep + os.environ.get('PATH', ''),
                                          'TOKENJOY_API_KEY': 'private-test-value'})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.manager = RunManager(self.root / 'jobs', config)
        self.http = server.make_server(data.Library([self.manager.jobs_dir]), '127.0.0.1', 0,
                                       self.manager, 'test-capability')
        self.thread = threading.Thread(target=self.http.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.http.server_close)
        self.addCleanup(self.http.shutdown)
        self.client = cli.Client(f'http://127.0.0.1:{self.http.server_address[1]}/', 'test-capability')

    def request(self):
        return {'model': 'tokenjoy/test-model', 'tasks': ['fix-git'], 'attempts': 2, 'concurrency': 1}

    def test_http_launch_creates_real_job_and_keeps_credentials_out_of_argv(self):
        catalog = self.client.request('api/workbench')
        self.assertTrue(catalog['ready'], catalog['reasons'])
        self.assertTrue(catalog['can_run'])
        self.assertNotIn('private-test-value', json.dumps(catalog))
        run = self.client.request('api/runs', self.request())
        final = wait_run(self.manager, run['name'])
        self.assertEqual(final['status'], 'finished', final)
        argv = json.loads((self.manager.jobs_dir / run['name'] / 'argv.json').read_text())
        self.assertIn('terminal-bench/fix-git', argv)
        self.assertEqual(argv[argv.index('-k') + 1], '2')
        self.assertIn('TOKENJOY_API_KEY=${TOKENJOY_API_KEY}', argv)
        self.assertNotIn('private-test-value', json.dumps(argv))
        job = self.client.request('api/job?name=' + run['name'])
        self.assertEqual(job['summary']['counts']['pass'], 1)
        self.assertIn(run['name'], final['url'])
        # A new manager still sees the durable worker receipt after restart.
        self.assertEqual(RunManager(self.manager.jobs_dir, self.manager.config_path).runs()[0]['status'], 'finished')

    def test_missing_authorization_and_cross_origin_are_refused(self):
        import urllib.request
        anonymous = cli.Client(self.client.url)
        with self.assertRaisesRegex(ValueError, '授权'):
            anonymous.request('api/runs', self.request())
        request = urllib.request.Request(self.client.url + 'api/runs', data=b'{}', headers={
            'Content-Type': 'application/json', 'Authorization': 'Bearer test-capability', 'Origin': 'https://other.example'})
        with self.assertRaises(urllib.error.HTTPError) as caught:
            urllib.request.urlopen(request)
        self.assertEqual(caught.exception.code, 403)
        self.assertEqual(self.manager.runs(), [])

    def test_unknown_models_shell_fragments_and_bad_ranges_are_refused_before_spawn(self):
        for override in ({'tasks': ['--path /etc']}, {'tasks': ['fix-git;touch /tmp/x']},
                         {'concurrency': True}, {'attempts': 0}, {'model': 'unknown'},
                         {'bundle': '/tmp/untrusted'}, {'dataset': '/tmp/untrusted'}):
            with self.subTest(override=override), self.assertRaises(ValueError):
                self.client.request('api/runs', {**self.request(), **override})
        self.assertEqual(self.manager.runs(), [])

    def test_worker_can_cancel_and_failure_is_durable(self):
        with patch.dict(os.environ, {'FAKE_BENCH_DELAY': '10'}):
            run = self.client.request('api/runs', self.request())
            with self.assertRaisesRegex(ValueError, '已有评测'):
                self.client.request('api/runs', self.request())
            self.client.request('api/cancel', {'name': run['name']})
            self.assertEqual(wait_run(self.manager, run['name'])['status'], 'cancelled')
        with patch.dict(os.environ, {'FAKE_BENCH_FAIL': '1'}):
            failed = self.client.request('api/runs', self.request())
            final = wait_run(self.manager, failed['name'])
            self.assertEqual((final['status'], final['exit_code']), ('failed', 7))

    def test_key_env_loaded_without_overriding_existing_secret(self):
        path = self.root / '.env'
        path.write_text('TOKENJOY_API_KEY="wrong"\nBENCH_TEST_OTHER="hello world"\n')
        with patch.dict(os.environ):
            cli.read_env(path)
            self.assertEqual(os.environ['TOKENJOY_API_KEY'], 'private-test-value')
            self.assertEqual(os.environ['BENCH_TEST_OTHER'], 'hello world')

    def test_account_login_drives_catalog_and_real_worker_without_provider_config(self):
        state = self.root / 'account'
        state.mkdir()
        login = {'api_key': 'account-test-key', 'selected_model': 'glm-test', 'reasoning_effort': 'high'}
        atomic_json(state / 'auth.json', login)
        seen = []

        class Catalog(BaseHTTPRequestHandler):
            def do_GET(self):
                seen.append((self.path, self.headers.get('Authorization')))
                body = json.dumps({'data': [{'id': 'glm-test', 'display_name': 'GLM Test'}, {'id': 'other-model'}]}).encode()
                self.send_response(200)
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *_args):
                pass

        upstream = ThreadingHTTPServer(('127.0.0.1', 0), Catalog)
        threading.Thread(target=upstream.serve_forever, daemon=True).start()
        self.addCleanup(upstream.server_close)
        self.addCleanup(upstream.shutdown)
        cfg = json.loads(self.manager.config_path.read_text())
        cfg.update(auth_mode='metask', account_state_dir=str(state),
                   account_gateway=f'http://127.0.0.1:{upstream.server_port}')
        atomic_json(self.manager.config_path, cfg)
        with patch('scripts.eval.harbor.viewer.account.GATEWAY', f'http://127.0.0.1:{upstream.server_port}'):
            catalog = self.client.request('api/workbench')
            self.assertTrue(catalog['ready'], catalog['reasons'])
            self.assertEqual(catalog['authentication']['kind'], 'metask')
            self.assertEqual(catalog['default_model'], 'metask/glm-test')
            self.assertEqual([m['label'] for m in catalog['models']], ['GLM Test', 'other-model'])
            self.assertNotIn('account-test-key', json.dumps(catalog))
            # The browser's next read reuses metadata, not a network roundtrip.
            self.client.request('api/workbench')
            self.assertEqual(seen, [('/v1/models', 'Bearer account-test-key')])
            # A login change invalidates metadata; workers must also read the
            # current credential, overriding any stale ambient account key.
            login['api_key'] = 'rotated-account-key'
            atomic_json(state / 'auth.json', login)
            with patch.dict(os.environ, {'FAKE_EXPECT_ACCOUNT_KEY': 'rotated-account-key', 'METASK_API_KEY': 'wrong-ambient-key'}):
                run = self.client.request('api/runs', {**self.request(), 'model': 'metask/glm-test'})
                final = wait_run(self.manager, run['name'])
            self.assertEqual(final['status'], 'finished', final)
            job = self.manager.jobs_dir / run['name']
            argv = json.loads((job / 'argv.json').read_text())
            self.assertEqual(argv[argv.index('-m') + 1], 'metask/glm-test')
            self.assertIn('METASK_API_KEY=${METASK_API_KEY}', argv)
            self.assertIn('reasoning_effort=high', argv)
            self.assertFalse(any(arg.startswith('config=') for arg in argv))
            self.assertTrue(json.loads((job / 'credential-check.json').read_text())['account_key_matches'])
            for path in self.manager.records.iterdir():
                text = path.read_text()
                for secret in ('account-test-key', 'rotated-account-key', 'never-forward-refresh'):
                    self.assertNotIn(secret, text)
            self.assertEqual(seen[-1][1], 'Bearer rotated-account-key')

    def test_missing_account_login_blocks_launch_despite_tokenjoy_key(self):
        cfg = json.loads(self.manager.config_path.read_text())
        cfg.update(auth_mode='metask', account_state_dir=str(self.root / 'not-logged-in'))
        atomic_json(self.manager.config_path, cfg)
        catalog = self.client.request('api/workbench')
        self.assertFalse(catalog['ready'])
        self.assertEqual(catalog['models'], [])
        self.assertTrue(any('尚未登录 Metask' in r for r in catalog['reasons']))
        with self.assertRaisesRegex(ValueError, '尚未登录 Metask'):
            self.client.request('api/runs', self.request())
        self.assertEqual(self.manager.runs(), [])

    def test_model_from_another_group_launches_with_that_groups_key(self):
        state, upstream, calls = account_fixture(self.root)
        self.addCleanup(upstream.server_close)
        self.addCleanup(upstream.shutdown)
        cfg = json.loads(self.manager.config_path.read_text())
        cfg.update(auth_mode='metask', account_state_dir=str(state),
                   account_gateway=f'http://127.0.0.1:{upstream.server_port}')
        atomic_json(self.manager.config_path, cfg)
        catalog = self.client.request('api/workbench')
        self.assertEqual({m['id'] for m in catalog['models']}, {'metask/glm-test', 'metask/shared', 'metask/claude-test'})
        self.assertEqual(catalog['account_summary']['groups'], 2)
        with patch.dict(os.environ, {'FAKE_EXPECT_ACCOUNT_KEY': 'group-claude-secret'}):
            run = self.client.request('api/runs', {**self.request(), 'model': 'metask/claude-test'})
            final = wait_run(self.manager, run['name'])
        self.assertEqual(final['status'], 'finished', final)
        job = self.manager.jobs_dir / run['name']
        self.assertTrue(json.loads((job / 'credential-check.json').read_text())['account_key_matches'])
        spec = json.loads((self.manager.records / (run['name'] + '.spec')).read_text())
        self.assertEqual(spec['account_key_id'], 'claude-key')
        self.assertEqual(json.loads((state / 'auth.json').read_text())['api_key'], 'group-glm-secret')
        public = json.dumps(catalog) + ''.join(p.read_text() for p in self.manager.records.iterdir())
        for secret in ('group-glm-secret', 'group-claude-secret', 'old-refresh', 'rotated-refresh', 'new-access'):
            self.assertNotIn(secret, public)

    def test_worker_profiles_the_actual_child_request_and_exposes_metrics(self):
        state, upstream, _ = account_fixture(self.root)
        self.addCleanup(upstream.server_close)
        self.addCleanup(upstream.shutdown)
        cfg = json.loads(self.manager.config_path.read_text())
        cfg.update(auth_mode='metask', account_state_dir=str(state), metrics_enabled=True,
                   metrics_bind='127.0.0.1', account_gateway=f'http://127.0.0.1:{upstream.server_port}')
        atomic_json(self.manager.config_path, cfg)
        with patch.dict(os.environ, {'FAKE_PROFILE_REQUEST': '1'}):
            run = self.client.request('api/runs', {**self.request(), 'model': 'metask/claude-test'})
            final = wait_run(self.manager, run['name'])
        self.assertEqual(final['status'], 'finished', final)
        view = self.client.request('api/job?name=' + run['name'])
        row = view['rows'][0]
        self.assertEqual(row['initial_input_tokens'], 50)
        self.assertEqual(row['total_tokens'], 70)
        self.assertEqual(row['requests'], 1)
        self.assertGreater(row['tps'], 0)
        self.assertGreaterEqual(row['ttft_ms'], 0)


class AccountTest(unittest.TestCase):
    def test_oauth_refresh_tokens_are_never_used_as_account_keys(self):
        with tempfile.TemporaryDirectory() as root:
            atomic_json(Path(root) / 'auth.json', {'oauth': {'refresh_token': 'refresh-test'}})
            with self.assertRaisesRegex(ValueError, '查看全部模型组需要 Metask 账号登录'):
                Account(root).credential()


class AccountInventoryTest(unittest.TestCase):
    def setup_account(self, **kwargs):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        state, http, calls = account_fixture(Path(tmp.name), **kwargs)
        self.addCleanup(http.server_close)
        self.addCleanup(http.shutdown)
        return Account(state, f'http://127.0.0.1:{http.server_port}'), calls

    def test_all_groups_are_unioned_and_shared_models_prefer_current_key(self):
        account, calls = self.setup_account()
        catalog = account.catalog()
        self.assertEqual(catalog['routes'], {'metask/glm-test': 'glm-key', 'metask/shared': 'glm-key', 'metask/claude-test': 'claude-key'})
        self.assertEqual(catalog['default_model'], 'metask/glm-test')
        self.assertEqual([g['configured'] for g in catalog['account_groups']], [True, True, False])
        self.assertEqual(account.credential('metask/claude-test', key_id='claude-key'), 'group-claude-secret')
        with self.assertRaisesRegex(ValueError, '已不可用'):
            account.credential('metask/claude-test', key_id='glm-key')
        self.assertEqual(len([c for c in calls if c[0] == 'refresh']), 1)

    def test_concurrent_refresh_rotates_privately_and_preserves_cli_selection(self):
        account, calls = self.setup_account()
        barrier = threading.Barrier(2)

        def access(_):
            barrier.wait()
            return Account(account.state_dir, account.gateway).oauth_bearer()

        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            self.assertEqual(list(pool.map(access, [1, 2])), ['new-access', 'new-access'])
        self.assertEqual(len([c for c in calls if c[0] == 'refresh']), 1)
        saved = json.loads((account.state_dir / 'auth.json').read_text())
        self.assertEqual(saved['oauth']['refresh_token'], 'rotated-refresh')
        self.assertEqual((saved['api_key'], saved['selected_model'], saved['reasoning_effort']), ('group-glm-secret', 'glm-test', 'high'))
        if os.name != 'nt':
            self.assertEqual((account.state_dir / 'auth.json').stat().st_mode & 0o777, 0o600)

    def test_all_key_pages_are_read_and_rejected_access_token_refreshes_once(self):
        account, calls = self.setup_account(expired=False, paginated=True)
        catalog = account.catalog()
        self.assertEqual(len(catalog['models']), 3)
        self.assertTrue(any(c[0].startswith('/api/v1/keys?page=2&') for c in calls))
        self.assertEqual(len([c for c in calls if c[0] == 'refresh']), 1)

    def test_unavailable_group_is_visible_without_losing_other_models(self):
        account, _ = self.setup_account(broken_group=True)
        catalog = account.catalog()
        self.assertEqual(catalog['account_summary'], {'groups': 3, 'available_groups': 2, 'models': 3})
        self.assertEqual(len(catalog['warnings']), 1)


if __name__ == '__main__':
    unittest.main()
