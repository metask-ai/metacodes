"""Real HTTP -> worker -> fake Harbor, including cancel and process failures.

The fake writes Harbor's actual job layout and records argv and credentials
separately. No provider or Docker calls are made by these tests.
"""
from __future__ import annotations

import json
import concurrent.futures
import os
import shutil
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
from scripts.eval.harbor.viewer import builds, data, releases, server
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
if os.environ.get('FAKE_ACCOUNT_REQUEST'):
 import urllib.request
 gateway = next(args[i + 1].removeprefix('account_gateway=') for i, a in enumerate(args) if a == '--ak' and args[i + 1].startswith('account_gateway='))
 req = urllib.request.Request(gateway + '/v1/messages', data=json.dumps({{'model':arg('-m').split('/',1)[1]}}).encode(), headers={{'Authorization':'Bearer ' + os.environ['METASK_API_KEY'], 'Content-Type':'application/json'}})
 with urllib.request.urlopen(req,timeout=5) as response: response.read()
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


def wait_status(manager, name, status, timeout=6):
    """The status the manager shows once it is `status`, or at the deadline."""
    deadline = time.monotonic() + timeout
    while True:
        shown = next((r for r in manager.runs() if r['name'] == name), {}).get('status')
        if shown == status or time.monotonic() >= deadline:
            return shown
        time.sleep(.05)


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


def session_fixture(root, *, expired=True):
    """Current native CLI login: preferences + oauth/metask.json."""
    state = root / 'session-account'
    state.mkdir()
    atomic_json(state / 'auth.json', {'selected_model': 'session-model', 'reasoning_effort': 'max'})
    calls = []

    class Endpoint(BaseHTTPRequestHandler):
        def reply(self, value, code=200):
            body = json.dumps(value).encode()
            self.send_response(code)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            if self.path == '/api/oauth/token':
                calls.append(('refresh', self.headers.get_content_type(), body))
                if body != {'grant_type': 'refresh_token', 'client_id': 'metacodes', 'refresh_token': 'session-refresh'}:
                    self.reply({}, 400)
                    return
                self.reply({'access_token': 'session-access', 'refresh_token': 'session-rotated', 'expires_in': 3600})
            elif self.path == '/v1/messages':
                calls.append(('model-request', self.headers.get('Authorization'), body))
                if self.headers.get('Authorization') != 'Bearer session-access':
                    self.reply({}, 401)
                    return
                events = [{'type': 'message_start', 'message': {'usage': {'input_tokens': 50}}},
                          {'type': 'content_block_delta', 'delta': {'text': 'output'}},
                          {'type': 'message_delta', 'usage': {'output_tokens': 20}}, {'type': 'message_stop'}]
                payload = b''.join(b'data: ' + json.dumps(e).encode() + b'\n\n' for e in events)
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.send_header('Content-Length', str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
            else:
                self.reply({}, 404)

        def do_GET(self):
            calls.append((self.path, self.headers.get('Authorization')))
            if self.path != '/v1/models':
                self.reply({}, 404)
            elif self.headers.get('Authorization') not in ('Bearer session-access', 'Bearer replacement-access'):
                self.reply({}, 401)
            else:
                self.reply({'data': [{'id': 'session-model'}, {'id': 'video-model', 'capabilities': {
                    'endpoints': {'messages': {'supported': False}}}}]})

        def log_message(self, *_args):
            pass

    http = ThreadingHTTPServer(('127.0.0.1', 0), Endpoint)
    atomic_json(state / 'oauth/metask.json', {'schema_version': 1, 'access_token': 'old-session',
                'refresh_token': 'session-refresh', 'token_type': 'Bearer',
                'expires_at': 0 if expired else int(time.time()) + 3600,
                'gateway_url': f'http://127.0.0.1:{http.server_port}',
                'models_url': f'http://127.0.0.1:{http.server_port}/v1/models'})
    threading.Thread(target=http.serve_forever, daemon=True).start()
    return state, http, calls


def stalled_account_fixture(root):
    """A key login whose model directory, once armed, holds each lookup
    until released: a slow Metask credential lookup, with no provider."""
    state = root / 'stalled-account'
    state.mkdir()
    atomic_json(state / 'auth.json', {'api_key': 'stalled-account-key', 'selected_model': 'glm-test'})
    armed, entered, release = threading.Event(), threading.Event(), threading.Event()

    class Catalog(BaseHTTPRequestHandler):
        def do_GET(self):
            if armed.is_set():
                entered.set()
                release.wait(9)
            body = json.dumps({'data': [{'id': 'glm-test'}]}).encode()
            self.send_response(200)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_args):
            pass

    http = ThreadingHTTPServer(('127.0.0.1', 0), Catalog)
    threading.Thread(target=http.serve_forever, daemon=True).start()
    return state, http, (armed, entered, release)


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
        caught.exception.close()
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

    def test_current_cli_session_reaches_catalog_and_actual_worker_request(self):
        state, upstream, calls = session_fixture(self.root)
        self.addCleanup(upstream.server_close)
        self.addCleanup(upstream.shutdown)
        cfg = json.loads(self.manager.config_path.read_text())
        cfg.update(auth_mode='metask', account_state_dir=str(state), metrics_enabled=True, metrics_bind='127.0.0.1')
        atomic_json(self.manager.config_path, cfg)
        with patch.dict(os.environ, {'METASK_SITE_URL': f'http://127.0.0.1:{upstream.server_port}',
                                     'FAKE_EXPECT_ACCOUNT_KEY': 'session-access', 'FAKE_PROFILE_REQUEST': '1'}):
            catalog = self.client.request('api/workbench')
            self.assertEqual([m['id'] for m in catalog['models']], ['metask/session-model'])
            self.assertEqual(catalog['reasoning_effort'], 'max')
            self.assertEqual(catalog['warnings'], [])
            run = self.client.request('api/runs', {**self.request(), 'model': 'metask/session-model'})
            final = wait_run(self.manager, run['name'])
            self.assertEqual(final['status'], 'finished', final)
            row = self.client.request('api/job?name=' + run['name'])['rows'][0]
            self.assertEqual((row['total_tokens'], row['requests']), (70, 1))
            self.assertIn(('model-request', 'Bearer session-access', {'model': 'session-model'}), calls)
            saved = json.loads((state / 'oauth/metask.json').read_text())
            self.assertEqual(saved['refresh_token'], 'session-rotated')
            self.assertEqual(json.loads((state / 'auth.json').read_text()),
                             {'selected_model': 'session-model', 'reasoning_effort': 'max'})
            saved['access_token'] = 'replacement-access'
            atomic_json(state / 'oauth/metask.json', saved)
            self.client.request('api/workbench')
            self.assertEqual(calls[-1], ('/v1/models', 'Bearer replacement-access'))
        public = json.dumps(catalog) + ''.join(p.read_text() for p in self.manager.records.iterdir())
        for secret in ('session-access', 'session-refresh', 'session-rotated', 'replacement-access'):
            self.assertNotIn(secret, public)

    def test_session_gateway_reaches_child_when_profiling_is_disabled(self):
        state, upstream, calls = session_fixture(self.root)
        self.addCleanup(upstream.server_close)
        self.addCleanup(upstream.shutdown)
        cfg = json.loads(self.manager.config_path.read_text())
        cfg.update(auth_mode='metask', account_state_dir=str(state), metrics_enabled=False)
        atomic_json(self.manager.config_path, cfg)
        with patch.dict(os.environ, {'METASK_SITE_URL': f'http://127.0.0.1:{upstream.server_port}',
                                     'FAKE_ACCOUNT_REQUEST': '1'}):
            run = self.client.request('api/runs', {**self.request(), 'model': 'metask/session-model'})
            final = wait_run(self.manager, run['name'])
        self.assertEqual(final['status'], 'finished', final)
        self.assertIn(('model-request', 'Bearer session-access', {'model': 'session-model'}), calls)

    def start_stalled_preparation(self):
        """Launch a run whose worker is still resolving its account key."""
        state, upstream, (armed, entered, release) = stalled_account_fixture(self.root)
        self.addCleanup(upstream.server_close)
        self.addCleanup(upstream.shutdown)
        self.addCleanup(release.set)
        cfg = json.loads(self.manager.config_path.read_text())
        cfg.update(auth_mode='metask', account_state_dir=str(state),
                   account_gateway=f'http://127.0.0.1:{upstream.server_port}')
        atomic_json(self.manager.config_path, cfg)
        # The catalog read answers at once; only the worker's own lookup stalls.
        catalog = self.client.request('api/workbench')
        self.assertTrue(catalog['ready'], catalog['reasons'])
        armed.set()
        run = self.client.request('api/runs', {**self.request(), 'model': 'metask/glm-test'})
        self.assertTrue(entered.wait(10), 'the worker never looked up its account key')
        return run, release

    def test_slow_preparation_stays_running_and_refuses_a_second_launch(self):
        run, release = self.start_stalled_preparation()
        # As if the key lookup had already outlasted the 30 second window.
        stale = time.time() - 31
        os.utime(self.manager.records / (run['name'] + '.json'), (stale, stale))
        shown = wait_status(self.manager, run['name'], 'starting')
        try:
            second = self.client.request('api/runs', {**self.request(), 'model': 'metask/glm-test'})['status']
        except ValueError as exc:
            second = str(exc)
        self.assertEqual((shown, second), ('starting', '已有评测正在运行，请等待完成或先停止'))
        release.set()
        self.assertEqual(wait_run(self.manager, run['name'])['status'], 'finished')

    def test_cancel_during_slow_preparation_never_starts_harbor(self):
        run, release = self.start_stalled_preparation()
        self.client.request('api/cancel', {'name': run['name']})
        shown = wait_status(self.manager, run['name'], 'cancelling')
        release.set()
        final = wait_run(self.manager, run['name'])
        started = (self.manager.jobs_dir / run['name'] / 'argv.json').exists()
        self.assertEqual((shown, final['status'], final['exit_code'], started), ('cancelling', 'cancelled', None, False))


class AccountTest(unittest.TestCase):
    def test_oauth_refresh_tokens_are_never_used_as_account_keys(self):
        with tempfile.TemporaryDirectory() as root:
            atomic_json(Path(root) / 'auth.json', {'oauth': {'refresh_token': 'refresh-test'}})
            with self.assertRaisesRegex(ValueError, '查看全部模型组需要 Metask 账号登录'):
                Account(root).credential()

    def test_current_session_refreshes_rejected_access_once_with_json_grant(self):
        with tempfile.TemporaryDirectory() as root:
            state, upstream, calls = session_fixture(Path(root), expired=False)
            self.addCleanup(upstream.server_close)
            self.addCleanup(upstream.shutdown)
            with patch.dict(os.environ, {'METASK_SITE_URL': f'http://127.0.0.1:{upstream.server_port}'}):
                account = Account(state)
                self.assertEqual(account.credential('metask/session-model', key_id='session'), 'session-access')
            refreshes = [c for c in calls if c[0] == 'refresh']
            self.assertEqual(refreshes, [('refresh', 'application/json', {
                'grant_type': 'refresh_token', 'client_id': 'metacodes', 'refresh_token': 'session-refresh'})])
            self.assertEqual(json.loads((state / 'oauth/metask.json').read_text())['schema_version'], 1)
            if os.name != 'nt':
                self.assertEqual((state / 'oauth/metask.json').stat().st_mode & 0o777, 0o600)

    def test_current_session_concurrent_refresh_and_invalid_store(self):
        with tempfile.TemporaryDirectory() as root:
            state, upstream, calls = session_fixture(Path(root))
            self.addCleanup(upstream.server_close)
            self.addCleanup(upstream.shutdown)
            with patch.dict(os.environ, {'METASK_SITE_URL': f'http://127.0.0.1:{upstream.server_port}'}):
                with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                    self.assertEqual(list(pool.map(lambda _: Account(state).oauth_bearer(), [1, 2])),
                                     ['session-access', 'session-access'])
                self.assertEqual(len([c for c in calls if c[0] == 'refresh']), 1)
                atomic_json(state / 'oauth/metask.json', {'access_token': 'broken'})
                with self.assertRaisesRegex(ValueError, '会话格式无效'):
                    Account(state).credential()


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


def release_server(root, version, *, corrupt=False):
    """A local stand-in for GitHub Releases serving one Linux unit."""
    import hashlib, io, tarfile
    target = releases.linux_target()
    name = f'metacodes-{version}-{target}.tar.gz'
    unit = f'metacodes-{version}-{target}/'
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode='w:gz') as tar:
        files = {rel: b'fake' for rel in BUNDLE_EXECUTABLES}
        files['manifest.json'] = json.dumps({'target': {'os': 'linux'}, 'release': {'version': version}}).encode()
        for rel, body in files.items():
            info = tarfile.TarInfo(unit + rel)
            info.size, info.mode = len(body), 0o755
            tar.addfile(info, io.BytesIO(body))
    archive = buffer.getvalue()
    digest = hashlib.sha256(b'other' if corrupt else archive).hexdigest()
    assets = {f'/download/{version}/{name}': archive,
              f'/download/{version}/metacodes-{version}-SHA256SUMS': f'{digest}  {name}\n'.encode()}
    hits = []

    class Releases(BaseHTTPRequestHandler):
        def do_GET(self):
            hits.append(self.path)
            body = assets.get(self.path)
            self.send_response(200 if body is not None else 404)
            self.send_header('Content-Length', str(len(body or b'')))
            self.end_headers()
            self.wfile.write(body or b'')

        def log_message(self, *_args):
            pass

    http = ThreadingHTTPServer(('127.0.0.1', 0), Releases)
    threading.Thread(target=http.serve_forever, daemon=True).start()
    return f'http://127.0.0.1:{http.server_address[1]}', http, hits


@unittest.skipUnless(POSIX, 'fake executable and worker signal test are POSIX')
class ReleaseVersionTest(unittest.TestCase):
    # The same live service as WorkbenchTest, without rerunning its tests.
    setUp = WorkbenchTest.setUp
    request = WorkbenchTest.request

    def use_release(self, version, **kwargs):
        base, http, hits = release_server(self.root, version, **kwargs)
        self.addCleanup(http.server_close)
        self.addCleanup(http.shutdown)
        cfg = json.loads(self.manager.config_path.read_text())
        atomic_json(self.manager.config_path, {**cfg, 'release_base': base})
        return hits

    def test_named_version_is_downloaded_verified_cached_and_reaches_harbor(self):
        hits = self.use_release('9.8.7')
        for _ in range(2):
            run = self.client.request('api/runs', {**self.request(), 'version': '9.8.7'})
            self.assertEqual(run['metacodes_version'], '9.8.7')
            final = wait_run(self.manager, run['name'])
            self.assertEqual(final['status'], 'finished', final)
            argv = json.loads((self.manager.jobs_dir / run['name'] / 'argv.json').read_text())
            bundle = Path(argv[argv.index('--ak') + 1].removeprefix('bundle='))
            self.assertEqual(bundle, self.manager.release_cache / f'metacodes-9.8.7-{releases.linux_target()}')
            self.assertTrue(os.access(bundle / 'bin' / 'metacodes', os.X_OK))
        self.assertEqual(len([h for h in hits if h.endswith('.tar.gz')]), 1)
        catalog = self.client.request('api/workbench')
        self.assertEqual(catalog['metacodes']['cached_versions'], ['9.8.7'])
        self.assertTrue(catalog['metacodes']['bundle'])

    def test_checksum_mismatch_fails_the_run_with_a_reason_and_caches_nothing(self):
        self.use_release('9.8.7', corrupt=True)
        run = self.client.request('api/runs', {**self.request(), 'version': '9.8.7'})
        final = wait_run(self.manager, run['name'])
        self.assertEqual(final['status'], 'failed')
        self.assertIn('SHA-256', final['error'])
        self.assertFalse((self.manager.jobs_dir / run['name']).exists())
        self.assertEqual(releases.cached(self.manager.release_cache), [])

    def test_missing_version_fails_the_run_with_a_reason(self):
        self.use_release('9.8.7')
        run = self.client.request('api/runs', {**self.request(), 'version': '1.2.3'})
        final = wait_run(self.manager, run['name'])
        self.assertEqual(final['status'], 'failed')
        self.assertIn('1.2.3', final['error'])

    def test_malformed_versions_are_refused_before_spawn(self):
        for version in ('../0.12.0', '0.12', '0.12.0;rm -rf /', '0.12.0/x', 12):
            with self.subTest(version=version), self.assertRaisesRegex(ValueError, '版本'):
                self.client.request('api/runs', {**self.request(), 'version': version})
        self.assertEqual(self.manager.runs(), [])

    def test_without_a_bundle_a_launch_must_name_a_version(self):
        cfg = json.loads(self.manager.config_path.read_text())
        atomic_json(self.manager.config_path, {**cfg, 'bundle': None})
        catalog = self.client.request('api/workbench')
        self.assertTrue(catalog['ready'], catalog['reasons'])
        self.assertFalse(catalog['metacodes']['bundle'])
        with self.assertRaisesRegex(ValueError, '版本'):
            self.client.request('api/runs', self.request())
        self.assertEqual(self.manager.runs(), [])

    def test_archive_links_and_escaping_paths_are_refused(self):
        import io, tarfile
        for name, kind in (('../escape', tarfile.REGTYPE), ('/abs', tarfile.REGTYPE), ('unit/link', tarfile.SYMTYPE)):
            with self.subTest(name=name):
                archive = self.root / 'bad.tar.gz'
                with tarfile.open(archive, 'w:gz') as tar:
                    info = tarfile.TarInfo(name)
                    info.type, info.linkname = kind, '/etc/passwd'
                    tar.addfile(info, io.BytesIO(b''))
                with self.assertRaisesRegex(ValueError, '不安全'):
                    releases._extract(archive, self.root / 'out')
                self.assertFalse((self.root / 'escape').exists())


FAKE_DOCKER = """#!{python}
import json, os, pathlib, sys, time
args = sys.argv[1:]
log = pathlib.Path(os.environ['FAKE_DOCKER_LOG'])
with log.open('a') as f: f.write(json.dumps(args) + chr(10))
if args[0] != 'run' or not any(a.endswith(':/out') for a in args): sys.exit(0)
out = next(pathlib.Path(a.split(':')[0]) for a in args if a.endswith(':/out'))
commit = next(a.split('=', 1)[1] for a in args if a.startswith('COMMIT='))
time.sleep(float(os.environ.get('FAKE_BUILD_DELAY', '0')))
if os.environ.get('FAKE_BUILD_FAIL'): sys.exit(3)
for rel in {executables!r}:
    (out / rel).parent.mkdir(parents=True, exist_ok=True)
    (out / rel).write_text(commit)
(out / 'manifest.json').write_text(json.dumps({{'target': {{'os': 'linux'}}, 'release': {{'version': '0.0.0-dev+' + commit[:12]}}}}))
"""


@unittest.skipUnless(POSIX, 'fake executable and worker signal test are POSIX')
class GitRefBuildTest(unittest.TestCase):
    setUp_service = WorkbenchTest.setUp
    request = WorkbenchTest.request

    def setUp(self):
        self.setUp_service()
        import subprocess
        self.git_env = patch.dict(os.environ, {'GIT_AUTHOR_NAME': 't', 'GIT_AUTHOR_EMAIL': 't@example.com',
                                               'GIT_COMMITTER_NAME': 't', 'GIT_COMMITTER_EMAIL': 't@example.com',
                                               'FAKE_DOCKER_LOG': str(self.root / 'docker.log')})
        self.git_env.start()
        self.addCleanup(self.git_env.stop)
        self.repo = self.root / 'source'
        self.repo.mkdir()
        self.git = lambda *a: subprocess.run(['git', '-C', str(self.repo), *a], check=True,
                                             capture_output=True, text=True).stdout.strip()
        self.git('init', '-q', '-b', 'main')
        (self.repo / 'build.zig.zon').write_text('.{ .minimum_zig_version = "0.16.0" }')
        (self.repo / 'control-plane' / 'lean').mkdir(parents=True)
        (self.repo / 'control-plane' / 'lean' / 'lean-toolchain').write_text('leanprover/lean4:v4.14.0\n')
        self.git('add', '.')
        self.git('commit', '-q', '-m', 'one')
        docker = Path(os.environ['PATH'].split(os.pathsep)[0]) / 'docker'
        docker.write_text(FAKE_DOCKER.format(python=sys.executable, executables=list(BUNDLE_EXECUTABLES)))
        cfg = json.loads(self.manager.config_path.read_text())
        atomic_json(self.manager.config_path, {**cfg, 'source_repo': str(self.repo)})

    def docker_runs(self):
        path = self.root / 'docker.log'
        calls = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
        return [c for c in calls if c[0] == 'run' and any(a.endswith(':/out') for a in c)]

    def toolchain_runs(self):
        path = self.root / 'docker.log'
        calls = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
        return [c for c in calls if c[0] == 'run' and any(a.endswith(':/toolchains') for a in c)]

    def launch(self, **request):
        run = self.client.request('api/runs', {**self.request(), **request})
        return run, wait_run(self.manager, run['name'])

    def bundle_of(self, run):
        argv = json.loads((self.manager.jobs_dir / run['name'] / 'argv.json').read_text())
        return Path(argv[argv.index('--ak') + 1].removeprefix('bundle='))

    def test_ref_is_built_once_per_commit_and_reaches_harbor(self):
        first = self.git('rev-parse', 'HEAD')
        run, final = self.launch(ref='main')
        self.assertEqual(run['metacodes_version'], 'git main')
        self.assertEqual(final['status'], 'finished', final)
        self.assertIn(first[:12], final['metacodes_version'])
        bundle = self.bundle_of(run)
        self.assertEqual(bundle.parent, self.manager.build_cache / 'builds')
        self.assertEqual((bundle / 'bin' / 'metacodes').read_text(), first)
        call = self.docker_runs()[0]
        self.assertIn('COMMIT=' + first, call)
        self.assertIn(builds.image(), call)
        self.assertTrue(any(a.endswith(':/mirror:ro') for a in call))
        # The revision's build sees the toolchains read-only and nothing shared writable.
        self.assertTrue(any(a.endswith('/zig/0.16.0:/opt/zig:ro') for a in call), call)
        self.assertTrue(any(a.endswith('/lean/leanprover-lean4-v4.14.0:/opt/lean:ro') for a in call), call)
        mounts = [call[i + 1] for i, a in enumerate(call) if a == '-v']
        self.assertEqual([m for m in mounts if not m.endswith(':ro')], [m for m in mounts if m.endswith(':/out')])
        toolchain = self.toolchain_runs()[0]
        self.assertIn('ZIG_VERSION=0.16.0', toolchain)
        self.assertIn('LEAN_TOOLCHAIN=leanprover/lean4:v4.14.0', toolchain)
        self.assertFalse(any(a.endswith(':/mirror:ro') or a.endswith(':/out') for a in toolchain))
        # The same commit by another name reuses the cached unit.
        run, final = self.launch(ref=first[:8])
        self.assertEqual((final['status'], self.bundle_of(run)), ('finished', bundle))
        self.assertEqual(len(self.docker_runs()), 1)
        catalog = self.client.request('api/workbench')
        self.assertEqual([b['commit'] for b in catalog['metacodes']['builds']], [first])
        # A new commit on the branch is fetched and built.
        self.git('commit', '-q', '--allow-empty', '-m', 'two')
        second = self.git('rev-parse', 'HEAD')
        run, final = self.launch(ref='main')
        self.assertEqual((self.bundle_of(run) / 'bin' / 'metacodes').read_text(), second)
        self.assertEqual(len(self.docker_runs()), 2)

    def test_failed_build_fails_the_run_with_a_reason_and_caches_nothing(self):
        with patch.dict(os.environ, {'FAKE_BUILD_FAIL': '1'}):
            run, final = self.launch(ref='main')
        self.assertEqual(final['status'], 'failed')
        self.assertIn('编译失败', final['error'])
        self.assertFalse((self.manager.jobs_dir / run['name']).exists())
        self.assertEqual(builds.cached(self.manager.build_cache), [])
        self.assertEqual(list((self.manager.build_cache / 'builds').iterdir()), [])

    def test_unknown_ref_fails_the_run_with_a_reason(self):
        _, final = self.launch(ref='no-such-branch')
        self.assertEqual(final['status'], 'failed')
        self.assertIn('no-such-branch', final['error'])
        self.assertEqual(self.docker_runs(), [])

    def test_cancel_during_build_stops_the_builder(self):
        with patch.dict(os.environ, {'FAKE_BUILD_DELAY': '10'}):
            run = self.client.request('api/runs', {**self.request(), 'ref': 'main'})
            deadline = time.monotonic() + 10
            while not self.docker_runs() and time.monotonic() < deadline:
                time.sleep(.05)
            self.client.request('api/cancel', {'name': run['name']})
            final = wait_run(self.manager, run['name'])
        self.assertEqual(final['status'], 'cancelled')
        log = [json.loads(line) for line in (self.root / 'docker.log').read_text().splitlines()]
        self.assertTrue(any(c[0] == 'kill' for c in log))
        self.assertFalse((self.manager.jobs_dir / run['name']).exists())

    def test_empty_cli_selection_is_refused_not_run_on_the_default_bundle(self):
        with patch.dict(os.environ, {'METACODES_BENCH_TOKEN': 'test-capability'}):
            for flag in ('--ref', '--version'):
                with self.subTest(flag=flag):
                    code = cli.main(['run', '--state-root', str(self.root / 'cli-state'), '--url', self.client.url,
                                     '--model', 'tokenjoy/test-model', flag, '', '--task', 'fix-git'])
                    self.assertEqual(code, 1)
        self.assertEqual(self.manager.runs(), [])

    def test_branch_and_tag_of_one_name_on_different_commits_is_ambiguous(self):
        old = self.git('rev-parse', 'HEAD')
        self.git('tag', 'main')
        self.git('commit', '-q', '--allow-empty', '-m', 'two')
        new = self.git('rev-parse', 'HEAD')
        _, final = self.launch(ref='main')
        self.assertEqual(final['status'], 'failed')
        self.assertIn('refs/heads/main', final['error'])
        self.assertEqual(self.docker_runs(), [])
        for ref, commit in (('refs/heads/main', new), ('refs/tags/main', old)):
            run, final = self.launch(ref=ref)
            self.assertEqual((self.bundle_of(run) / 'bin' / 'metacodes').read_text(), commit)

    def test_cached_full_commit_needs_no_source_repository(self):
        commit = self.git('rev-parse', 'HEAD')
        self.launch(ref='main')
        shutil.rmtree(self.repo)
        run, final = self.launch(ref=commit)
        self.assertEqual(final['status'], 'finished', final)
        self.assertEqual((self.bundle_of(run) / 'bin' / 'metacodes').read_text(), commit)
        # A branch still has to be refreshed, and says why it cannot be.
        _, final = self.launch(ref='main')
        self.assertEqual(final['status'], 'failed')
        self.assertIn('源码仓库', final['error'])

    def checkout(self, mirror, commit, tags, probe):
        """The builder's checkout step, run as this (non-root) user."""
        import subprocess
        return subprocess.run(['bash', '-c', builds.BUILD_SCRIPT + probe], capture_output=True, text=True,
                              env={**os.environ, 'MIRROR': str(mirror), 'COMMIT': commit,
                                   'TAGS': ' '.join(tags), 'TMPDIR': str(self.root)})

    def test_commit_only_a_foreign_ref_names_is_never_built_or_run(self):
        self.git('commit', '-q', '--allow-empty', '-m', 'candidate')
        candidate = self.git('rev-parse', 'HEAD')
        self.git('update-ref', 'refs/pull/7/head', candidate)
        self.git('reset', '-q', '--hard', 'HEAD~1')
        for ref in (candidate, 'refs/pull/7/head'):
            with self.subTest(ref=ref):
                run, final = self.launch(ref=ref)
                self.assertEqual(final['status'], 'failed')
                self.assertIn('不在源码仓库的任何分支或 tag 上', final['error'])
                self.assertFalse((self.manager.jobs_dir / run['name']).exists())
        self.assertEqual(self.docker_runs(), [])
        # Once the repository publishes it on a branch, it builds; the checkout
        # fetches it by id even though no fetched branch head is that commit.
        self.git('branch', 'published', candidate)
        mirror, commit = builds.resolve(candidate, self.root / 'cache', str(self.repo))
        self.git('branch', '-D', 'published')
        result = self.checkout(mirror, commit, [], 'git rev-parse HEAD')
        self.assertEqual((result.returncode, result.stdout.strip()), (0, candidate), result.stderr)

    def test_release_tag_reaches_the_checkout_and_tag_or_sha_share_one_build(self):
        commit = self.git('rev-parse', 'HEAD')
        self.git('tag', '-a', '-m', 'release', '0.0.1')
        self.git('tag', 'other-name')
        mirror, _ = builds.resolve('0.0.1', self.root / 'cache', str(self.repo))
        tags = builds.tags_at(mirror, commit)
        self.assertEqual(sorted(tags), ['0.0.1', 'other-name'])
        result = self.checkout(mirror, commit, tags, 'git describe --tags --exact-match --match 0.0.1 HEAD')
        self.assertEqual((result.returncode, result.stdout.strip()), (0, '0.0.1'), result.stderr)
        run, final = self.launch(ref='0.0.1')
        self.assertEqual(final['status'], 'finished', final)
        self.assertIn('TAGS=0.0.1 other-name', self.docker_runs()[0])
        again, final = self.launch(ref=commit)
        self.assertEqual((final['status'], self.bundle_of(again)), ('finished', self.bundle_of(run)))
        self.assertEqual(len(self.docker_runs()), 1)

    def test_interrupted_toolchain_install_is_redone_not_reused(self):
        import io, subprocess, tarfile
        stub = self.root / 'stub'
        stub.mkdir()
        archive = io.BytesIO()
        with tarfile.open(fileobj=archive, mode='w:xz') as tar:
            for name, body in (('zig-x/zig', b'#!/bin/sh\n'), ('zig-x/lib/std.zig', b'complete')):
                info = tarfile.TarInfo(name)
                info.size, info.mode = len(body), 0o755
                tar.addfile(info, io.BytesIO(body))
        (stub / 'zig.tar.xz').write_bytes(archive.getvalue())
        import hashlib
        index = {'0.16.0': {os.uname().machine + '-linux': {'tarball': 'https://example.invalid/zig.tar.xz',
                                                              'shasum': hashlib.sha256(archive.getvalue()).hexdigest()}}}
        (stub / 'index.json').write_text(json.dumps(index))
        curl = stub / 'curl'
        curl.write_text('#!/bin/sh\nout=\nwhile [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift;; *) url=$1;; esac; shift; done\n'
                        'case "$url" in *index.json) cat "%s/index.json";; *) cp "%s/zig.tar.xz" "$out";; esac\n' % (stub, stub))
        curl.chmod(0o755)
        toolchains = self.root / 'toolchains'
        # A copy cancelled after the executable landed, and a stale staging area.
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

    def test_cancel_while_fetching_source_ends_the_run_and_frees_the_workbench(self):
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
        cfg = json.loads(self.manager.config_path.read_text())
        atomic_json(self.manager.config_path, {**cfg, 'source_repo': f'http://127.0.0.1:{http.server_address[1]}/repo.git'})
        run = self.client.request('api/runs', {**self.request(), 'ref': 'main'})
        self.assertTrue(hit.wait(10))
        started = time.monotonic()
        self.client.request('api/cancel', {'name': run['name']})
        self.assertEqual(wait_run(self.manager, run['name'])['status'], 'cancelled')
        self.assertLess(time.monotonic() - started, 10)
        atomic_json(self.manager.config_path, {**cfg, 'source_repo': str(self.repo)})
        _, final = self.launch(ref='main')
        self.assertEqual(final['status'], 'finished', final)

    def test_malformed_refs_and_two_sources_are_refused_before_spawn(self):
        for request in ({'ref': '--upload-pack=touch /tmp/x'}, {'ref': 'a..b'}, {'ref': 'main@{1}'},
                        {'ref': 'x y'}, {'ref': 7}, {'ref': 'main', 'version': '0.12.0'},
                        {'ref': ''}, {'version': ''}, {'ref': None}, {'version': None}):
            with self.subTest(request=request), self.assertRaises(ValueError):
                self.client.request('api/runs', {**self.request(), **request})
        self.assertEqual(self.manager.runs(), [])

if __name__ == '__main__':
    unittest.main()
