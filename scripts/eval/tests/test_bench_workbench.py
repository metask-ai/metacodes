"""Real HTTP -> worker -> fake Harbor, including cancel and process failures.

The fake writes Harbor's actual job layout and records argv and credentials
separately. No provider or Docker calls are made by these tests.
"""
from __future__ import annotations

import argparse
import ast
import json
import concurrent.futures
import io
import os
import socket
import sys
import tempfile
import threading
import time
import types
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from contextlib import redirect_stderr
from unittest.mock import patch

from scripts.eval.harbor import cli
from scripts.eval.harbor.adapters import gaia2_cli
from scripts.eval.harbor.command import BUNDLE_EXECUTABLES
from scripts.eval.harbor.bench import data
from scripts.eval.harbor.bench.workbench import Workbench
from scripts.eval.harbor.viewer import server
from scripts.eval.harbor.bench.account import Account, refresh_lock
from scripts.eval.harbor.bench.runner import ACTIVE, RunManager, atomic_json
from scripts.eval.tests.posix_only import POSIX

FAKE_HARBOR = '''#!{python}
import json, os, pathlib, sys, time
args = sys.argv[1:]
def arg(flag): return args[args.index(flag) + 1]
if args[:1] == ['download']:
    # `harbor download REF -o DIR`: the export layout, DIR/<dataset>/<task>/,
    # with every task the catalog lists for REF.
    ref, out = args[1], pathlib.Path(arg('-o'))
    if os.environ.get('FAKE_HARBOR_DOWNLOAD_LOG'):
        with open(os.environ['FAKE_HARBOR_DOWNLOAD_LOG'], 'a') as log: log.write(ref + '\\n')
    from scripts.eval.harbor import suites
    names = sorted({{t for s in suites.ALL if s.dataset == ref for t in (s.tasks or ())}})
    names = names[int(os.environ.get('FAKE_HARBOR_DOWNLOAD_DROP', '0')):]
    base = out / ref.split('@')[0].split('/')[-1]
    for n in names:
        (base / n / 'environment').mkdir(parents=True)
        (base / n / 'task.toml').write_text('[task]\\n')
        (base / n / 'environment' / 'Dockerfile').write_text(os.environ.get('FAKE_TASK_FROM', 'FROM ubuntu:24.04') + '\\n')
    print('Successfully downloaded %d task(s)' % len(names))
    sys.exit(0)
root = pathlib.Path(arg('-o')) / arg('--job-name')
root.mkdir(parents=True, exist_ok=True)
(root / 'argv.json').write_text(json.dumps(args))
key_env = next((args[i + 1].split('=', 1)[0] for i, a in enumerate(args) if a == '--ae'), 'METASK_API_KEY')
(root / 'credential-check.json').write_text(json.dumps({{'account_key_matches': bool(os.environ.get('FAKE_EXPECT_ACCOUNT_KEY')) and os.environ.get(key_env) == os.environ.get('FAKE_EXPECT_ACCOUNT_KEY'),
    'placeholder': os.environ.get(key_env, '').startswith('mcb-')}}))
# What Harbor would hand the task container (--ae values), and its own env.
(root / 'container-env.json').write_text(json.dumps({{args[i + 1].split('=', 1)[0]: os.environ.get(args[i + 1].split('=', 1)[0]) for i, a in enumerate(args) if a == '--ae'}}))
(root / 'harbor-env.json').write_text(json.dumps({{k: v for k, v in os.environ.items() if not k.startswith('FAKE_')}}))
if os.environ.get('DOCKER_CONFIG'):
    # What the docker CLI would read for this run's containers.
    docker_config = json.loads((pathlib.Path(os.environ['DOCKER_CONFIG']) / 'config.json').read_text())
    (root / 'docker-config.json').write_text(json.dumps(docker_config))
    if os.environ.get('FAKE_EGRESS_FETCH'):
        import urllib.request
        proxy = docker_config['proxies']['default']['httpProxy']
        with urllib.request.urlopen(proxy + '/metacodes-bench-egress-probe', timeout=10) as response:
            (root / 'egress-probe.txt').write_bytes(response.read())
(root / 'config.json').write_text(json.dumps({{'agents':[{{'model_name':arg('-m')}}], 'n_attempts':int(arg('-k'))}}))
(root / 'result.json').write_text(json.dumps({{'started_at':'2026-11-16T00:00:00Z','finished_at':None, 'n_total_trials':1}}))
if os.environ.get('FAKE_PROFILE_REQUEST'):
 import ssl, urllib.request
 relay = next(args[i + 1].removeprefix('metrics_proxy=') for i, a in enumerate(args) if a == '--ak' and args[i + 1].startswith('metrics_proxy='))
 ca = next(args[i + 1].removeprefix('metrics_ca=') for i, a in enumerate(args) if a == '--ak' and args[i + 1].startswith('metrics_ca='))
 req = urllib.request.Request(relay + '/fix-git__fake/v1/messages', data=json.dumps({{'model':arg('-m').split('/',1)[1]}}).encode(), headers={{'Authorization':'Bearer ' + os.environ['METASK_API_KEY'], 'Content-Type':'application/json'}})
 with urllib.request.urlopen(req,timeout=5,context=ssl.create_default_context(cafile=ca)) as response: response.read()
if os.environ.get('FAKE_JUDGE_REQUEST'):
 # Harbor's verifier: `--ve` values (templates resolved from Harbor's own
 # environment, as harbor.utils.env.resolve_env_vars does) become the test
 # script's environment; the judge then calls Chat Completions like the
 # openai SDK (base_url + /chat/completions). The CA is the host's copy of
 # the bundle the container reads from SSL_CERT_FILE.
 import ssl, urllib.error, urllib.request
 ca = next(args[i + 1].removeprefix('metrics_ca=') for i, a in enumerate(args) if a == '--ak' and args[i + 1].startswith('metrics_ca='))
 ve = {{}}
 for i, a in enumerate(args):
  if a == '--ve':
   k, v = args[i + 1].split('=', 1)
   ve[k] = os.environ[v[2:-1]] if v.startswith('${{') and v.endswith('}}') else v
 (root / 'verifier-env.json').write_text(json.dumps(ve))
 body = json.dumps({{'model': ve['JUDGE_MODEL'], 'messages': [{{'role': 'user', 'content': 'grade'}}]}}).encode()
 statuses = {{}}
 for label, token in (('judge', ve['OPENAI_API_KEY']), ('agent-token', os.environ[key_env])):
  req = urllib.request.Request(ve['OPENAI_BASE_URL'] + '/chat/completions', data=body, headers={{'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'}})
  try:
   with urllib.request.urlopen(req, timeout=10, context=ssl.create_default_context(cafile=ca)) as response:
    statuses[label] = [response.status, json.loads(response.read())['choices'][0]['message']['content']]
  except urllib.error.HTTPError as exc:
   statuses[label] = [exc.code, None]; exc.close()
 (root / 'judge-statuses.json').write_text(json.dumps(statuses))
if os.environ.get('FAKE_RELAY_REQUESTS'):
 import ssl, urllib.error, urllib.request
 relay = next(args[i + 1].removeprefix('metrics_proxy=') for i, a in enumerate(args) if a == '--ak' and args[i + 1].startswith('metrics_proxy='))
 ca = next(args[i + 1].removeprefix('metrics_ca=') for i, a in enumerate(args) if a == '--ak' and args[i + 1].startswith('metrics_ca='))
 statuses = []
 for n in range(int(os.environ['FAKE_RELAY_REQUESTS'])):
  req = urllib.request.Request(relay + '/fix-git__fake/v1/messages', data=json.dumps({{'model':arg('-m').split('/',1)[1], 'n': n}}).encode(), headers={{'Authorization':'Bearer ' + os.environ[key_env], 'Content-Type':'application/json'}})
  try:
   with urllib.request.urlopen(req,timeout=10,context=ssl.create_default_context(cafile=ca)) as response: response.read(); statuses.append(response.status)
  except urllib.error.HTTPError as exc:
   statuses.append(exc.code); exc.close()
  (root / 'relay-statuses.json').write_text(json.dumps(statuses))
  time.sleep(float(os.environ.get('FAKE_RELAY_INTERVAL', '.3')))
if os.environ.get('FAKE_ACCOUNT_REQUEST'):
 import urllib.request
 gateway = next(args[i + 1].removeprefix('account_gateway=') for i, a in enumerate(args) if a == '--ak' and args[i + 1].startswith('account_gateway='))
 req = urllib.request.Request(gateway + '/v1/messages', data=json.dumps({{'model':arg('-m').split('/',1)[1]}}).encode(), headers={{'Authorization':'Bearer ' + os.environ['METASK_API_KEY'], 'Content-Type':'application/json'}})
 with urllib.request.urlopen(req,timeout=5) as response: response.read()
release_file = os.environ.get('FAKE_BENCH_RELEASE_FILE')
if release_file:
 deadline = time.monotonic() + 30
 while not pathlib.Path(release_file).exists():
  if time.monotonic() >= deadline: sys.exit(8)
  time.sleep(.05)
if os.environ.get('FAKE_LATE_TRAFFIC'):
 # After the release file: a model request through the relay and a fetch
 # through the container egress proxy, with the CA and proxy given at start.
 import ssl, urllib.request
 relay = next(args[i + 1].removeprefix('metrics_proxy=') for i, a in enumerate(args) if a == '--ak' and args[i + 1].startswith('metrics_proxy='))
 ca = next(args[i + 1].removeprefix('metrics_ca=') for i, a in enumerate(args) if a == '--ak' and args[i + 1].startswith('metrics_ca='))
 req = urllib.request.Request(relay + '/fix-git__fake/v1/messages', data=b'{{}}', headers={{'Authorization':'Bearer ' + os.environ[key_env], 'Content-Type':'application/json'}})
 with urllib.request.urlopen(req, timeout=10, context=ssl.create_default_context(cafile=ca)) as response: late = {{'relay': response.status, 'body': len(response.read())}}
 proxy = json.loads((pathlib.Path(os.environ['DOCKER_CONFIG']) / 'config.json').read_text())['proxies']['default']['httpProxy']
 with urllib.request.urlopen(proxy + '/metacodes-bench-egress-probe', timeout=10) as response: late['egress'] = response.read().decode()
 (root / 'late-traffic.json').write_text(json.dumps(late))
time.sleep(float(os.environ.get('FAKE_BENCH_DELAY', '.2')))
if os.environ.get('FAKE_BENCH_FAIL'): sys.exit(7)
t = root / 'fix-git__fake'; t.mkdir()
(t / 'config.json').write_text('{{}}')
(t / 'result.json').write_text(json.dumps({{'task_name':'terminal-bench/fix-git', 'started_at':'2026-11-16T00:00:00Z', 'finished_at':'2026-11-16T00:01:00Z', 'verifier_result':{{'rewards':{{'reward':1.0}}}}}}))
(root / 'result.json').write_text(json.dumps({{'started_at':'2026-11-16T00:00:00Z','finished_at':'2026-11-16T00:01:00Z','n_total_trials':1}}))
'''


REPO = Path(__file__).resolve().parents[3]


def node_script() -> bytes:
    """A bundle's `metacodes` as an SSH node runs it: `bench` from this checkout
    (what bench_cli.zig does with the binary's embedded copy)."""
    bootstrap = 'import sys; sys.path.insert(0, sys.argv.pop(1)); from scripts.eval.harbor.cli import main; sys.exit(main())'
    # Like bench_cli.zig: METACODES_BENCH_PYTHON, else python3 on PATH.
    return (f'#!/bin/sh\n[ "$1" = bench ] || exit 2\nshift\nexec "${{METACODES_BENCH_PYTHON:-python3}}" -c "{bootstrap}" '
            f'{REPO} --state-root "$HOME/.metacodes" --metacodes-version 9.9.9 "$@"\n').encode()


def offline_hugging_face(case):
    probe = patch.object(gaia2_cli, 'cached_hf_problem', lambda: None)
    probe.start()
    case.addCleanup(probe.stop)


def fixture(root):
    bundle = root / 'bundle'
    for file in BUNDLE_EXECUTABLES:
        path = bundle / file
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(node_script() if file == 'bin/metacodes' else b'fake')
        path.chmod(0o755)
    atomic_json(bundle / 'manifest.json', {'target': {'os': 'linux'}})
    native = root / 'provider.json'
    atomic_json(native, {'custom_providers': {'tokenjoy': {
        'display_name': 'TokenJoy', 'env_aliases': [{'name': 'TOKENJOY_API_KEY'}],
        'channels': [{'id': 'default', 'protocol': 'openai_chat', 'base_url': 'https://tokenjoy.invalid/v1'}],
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
                         'key_env': 'TOKENJOY_API_KEY', 'metrics_enabled': False, 'metrics_bind': '127.0.0.1',
                         'model_prices': 'off'})
    return config, binary_dir


def gaia2_dataset(root):
    """A prepared gaia2-cli dataset directory (one task)."""
    dataset = root / 'gaia2-dataset'
    (dataset / 'gaia2-search-0000-abc').mkdir(parents=True)
    (dataset / 'gaia2-search-0000-abc' / 'task.toml').write_text('[task]\n')
    return dataset


def wait_run(manager, name, timeout=15):
    deadline = time.monotonic() + timeout
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


def stop_profiles_and_workers(manager, timeout=60):
    profiles = getattr(manager, 'profiles', None)
    if profiles is not None:
        profiles.stop()
        if profiles._thread is not None:
            profiles._thread.join(timeout)
            if profiles._thread.is_alive():
                raise AssertionError('the profile scheduler did not stop')

    def active():
        receipts = {path.stem: data.read_json(path) for path in manager.records.glob('*.json')}
        return [name for name, receipt in receipts.items()
                if isinstance(receipt, dict) and receipt.get('status') in ACTIVE]

    for name in active():
        manager.cancel(name)
    deadline = time.monotonic() + timeout
    while running := active():
        if time.monotonic() >= deadline:
            raise AssertionError('workers did not end: ' + ', '.join(running))
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
                calls.append(('model-request', self.headers.get('Authorization')))
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
            elif self.path == '/v1/chat/completions':
                # An LLM judge (OpenAI Chat Completions) on the same bearer.
                calls.append(('judge-request', self.headers.get('Authorization'), body))
                if self.headers.get('Authorization') != 'Bearer session-access':
                    self.reply({}, 401)
                    return
                self.reply({'choices': [{'message': {'role': 'assistant', 'content': 'GRADE: yes'}}]})
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
                # glm-5.3-flash: a Chat Completions judge, not offered for
                # Messages, so it is no agent model in the catalog.
                self.reply({'data': [{'id': 'session-model'}, {'id': 'video-model', 'capabilities': {
                    'endpoints': {'messages': {'supported': False}}}}, {'id': 'glm-5.3-flash', 'capabilities': {
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


class RotatingGateway:
    """A Metask gateway and OAuth endpoint with short-lived tokens.

    Access tokens live `lifetime` seconds; a model request with an expired,
    revoked or unknown token gets 401. Each refresh rotates the refresh
    token, and a reused (already rotated) refresh token is rejected with 400
    `invalid_grant`, as the real endpoint does."""

    def __init__(self, root, lifetime=4.0):
        self.lifetime = lifetime
        self.lock = threading.Lock()
        self.serial = 0
        self.expiry = {}
        self.issued = []
        self.revoked = set()
        self.deny_refresh = False
        self.refreshes = []   # (time, seconds the replaced access token still had)
        self.first_request_at = None
        self.rejected = []    # refresh tokens refused
        self.requests = []    # (access token, accepted, seconds left)
        self.current_access = self.issue()
        self.refresh_token = 'live-refresh-0'
        self.issued.append(self.refresh_token)
        gateway = self

        class Endpoint(BaseHTTPRequestHandler):
            def reply(self, value, code=200):
                body = json.dumps(value).encode()
                self.send_response(code)
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def bearer(self):
                return (self.headers.get('Authorization') or '').removeprefix('Bearer ')

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers['Content-Length'])) or b'{}')
                if self.path == '/api/oauth/token':
                    self.reply(*gateway.refresh(body))
                elif self.path == '/v1/messages':
                    if not gateway.accept(self.bearer()):
                        self.reply({'error': {'code': 'token_expired', 'message': 'expired'}}, 401)
                        return
                    events = (
                        {'type': 'message_start', 'message': {'id': 'msg-1', 'role': 'assistant', 'type': 'message',
                                                              'content': [], 'usage': {'input_tokens': 5}}},
                        {'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'text', 'text': ''}},
                        {'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'text_delta', 'text': 'ok'}},
                        {'type': 'content_block_stop', 'index': 0},
                        {'type': 'message_delta', 'delta': {'stop_reason': 'end_turn'}, 'usage': {'output_tokens': 2}},
                        {'type': 'message_stop'})
                    payload = ''.join(f"event: {e['type']}\ndata: {json.dumps(e)}\n\n" for e in events).encode()
                    self.send_response(200)
                    self.send_header('Content-Type', 'text/event-stream')
                    self.send_header('Content-Length', str(len(payload)))
                    self.end_headers()
                    self.wfile.write(payload)
                else:
                    self.reply({}, 404)

            def do_GET(self):
                if self.path.partition('?')[0] != '/v1/models':
                    self.reply({}, 404)
                elif not gateway.valid(self.bearer()):
                    self.reply({}, 401)
                else:
                    self.reply({'data': [{'id': 'session-model'}]})

            def log_message(self, *_args):
                pass

        self.http = ThreadingHTTPServer(('127.0.0.1', 0), Endpoint)
        self.url = f'http://127.0.0.1:{self.http.server_port}'
        self.state = root / 'rotating-account'
        self.state.mkdir()
        atomic_json(self.state / 'auth.json', {'selected_model': 'session-model'})
        atomic_json(self.state / 'oauth/metask.json', {
            'schema_version': 1, 'access_token': self.current_access, 'refresh_token': self.refresh_token,
            'token_type': 'Bearer', 'expires_at': int(self.expiry[self.current_access]),
            'gateway_url': self.url, 'models_url': self.url + '/v1/models'})
        threading.Thread(target=self.http.serve_forever, daemon=True).start()

    def close(self):
        self.http.shutdown()
        self.http.server_close()

    def issue(self):
        token = f'live-access-{self.serial}'
        self.expiry[token] = time.time() + self.lifetime
        self.issued.append(token)
        return token

    def valid(self, token):
        with self.lock:
            return token in self.expiry and token not in self.revoked and time.time() < self.expiry[token]

    def accept(self, token):
        with self.lock:
            left = self.expiry.get(token, 0) - time.time()
            ok = token in self.expiry and token not in self.revoked and left > 0
            if self.first_request_at is None:
                self.first_request_at = time.time()
            self.requests.append((token, ok, left))
            return ok

    def refreshes_while_serving(self):
        with self.lock:
            return [left for at, left in self.refreshes
                    if self.first_request_at is not None and at > self.first_request_at]

    def revoke(self, token):
        with self.lock:
            self.revoked.add(token)

    def refresh(self, body):
        with self.lock:
            if (self.deny_refresh or body.get('client_id') != 'metacodes'
                    or body.get('refresh_token') != self.refresh_token):
                self.rejected.append(body.get('refresh_token'))
                return {'error': 'invalid_grant'}, 400
            self.refreshes.append((time.time(), self.expiry[self.current_access] - time.time()))
            self.serial += 1
            self.current_access = self.issue()
            self.refresh_token = f'live-refresh-{self.serial}'
            self.issued.append(self.refresh_token)
            return {'access_token': self.current_access, 'refresh_token': self.refresh_token,
                    'expires_in': int(self.lifetime), 'token_type': 'Bearer'}, 200


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
        offline_hugging_face(self)
        self.env = patch.dict(os.environ, {'PATH': str(binary_dir) + os.pathsep + os.environ.get('PATH', ''),
                                          'TOKENJOY_API_KEY': 'private-test-value'})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.manager = RunManager(self.root / 'jobs', config)
        self.http = server.make_server(Workbench(data.Library([self.manager.jobs_dir]), self.manager),
                                       '127.0.0.1', 0)
        self.thread = threading.Thread(target=self.http.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.http.server_close)
        self.addCleanup(self.http.shutdown)
        self.addCleanup(stop_profiles_and_workers, self.manager)
        self.client = cli.Client(f'http://127.0.0.1:{self.http.server_address[1]}/')

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
        # Harbor (and so the task container) holds only the run's placeholder.
        container = json.loads((self.manager.jobs_dir / run['name'] / 'container-env.json').read_text())
        self.assertTrue(container['TOKENJOY_API_KEY'].startswith('mcb-'), container)
        self.assertNotIn('private-test-value', (self.manager.jobs_dir / run['name'] / 'harbor-env.json').read_text())
        self.assertTrue(any(a.startswith('metrics_proxy=https://127.0.0.1:') for a in argv))
        self.assertEqual(final['credential'], {'container': 'placeholder', 'refreshing': False})
        job = self.client.request('api/job?name=' + run['name'])
        self.assertEqual(job['summary']['counts']['pass'], 1)
        self.assertIn(run['name'], final['url'])
        # A new manager still sees the durable worker receipt after restart.
        self.assertEqual(RunManager(self.manager.jobs_dir, self.manager.config_path).runs()[0]['status'], 'finished')

    def test_a_run_can_cap_the_output_tokens_of_each_model_request(self):
        for bad in (100, 131073, '32000', True):
            with self.assertRaisesRegex(ValueError, 'max_tokens'):
                self.manager.launch({**self.request(), 'max_tokens': bad})
        run = self.client.request('api/runs', {**self.request(), 'max_tokens': 32000})
        final = wait_run(self.manager, run['name'])
        self.assertEqual(final['status'], 'finished', final)
        self.assertEqual(final['max_tokens'], 32000)
        argv = json.loads((self.manager.jobs_dir / run['name'] / 'argv.json').read_text())
        self.assertIn('max_tokens=32000', argv)

    def test_provider_mode_reads_the_config_of_the_workbench_state_root(self):
        native = json.loads((self.root / 'provider.json').read_text())['custom_providers']['tokenjoy']
        state_root = self.root / 'state'
        atomic_json(state_root / 'config.json', {'custom_providers': {'gw': native}})
        cfg = json.loads(self.manager.config_path.read_text())
        for name in ('provider_config', 'model'):
            cfg.pop(name)
        atomic_json(self.manager.config_path, {**cfg, 'auth_mode': 'provider', 'account_state_dir': str(state_root)})
        environ = {k: v for k, v in os.environ.items() if k not in ('METACODES_CONFIG_FILE', 'METACODES_HOME')}
        with patch.dict(os.environ, environ, clear=True):
            catalog = self.client.request('api/workbench')
        self.assertTrue(catalog['ready'], catalog['reasons'])
        self.assertEqual([m['id'] for m in catalog['models']], ['gw/test-model'])

    def test_provider_mode_reuses_the_metacodes_config_and_its_key_variable(self):
        native = json.loads((self.root / 'provider.json').read_text())['custom_providers']['tokenjoy']
        metacodes_config = self.root / 'metacodes-config.json'
        atomic_json(metacodes_config, {'mcp_servers': [{'name': 'kg', 'command': 'tinykg'}], 'custom_providers': {
            'gw': {**native, 'env_aliases': [{'name': 'GW_KEY', 'kind': 'api_key', 'canonical': True}]}}})
        cfg = json.loads(self.manager.config_path.read_text())
        for name in ('provider_config', 'model', 'key_env'):
            cfg.pop(name)
        atomic_json(self.manager.config_path, {**cfg, 'auth_mode': 'provider'})
        with patch.dict(os.environ, {'METACODES_CONFIG_FILE': str(metacodes_config)}):
            catalog = self.client.request('api/workbench')
            self.assertEqual(catalog['reasons'], ['执行服务缺少环境变量 GW_KEY，设置后重启服务'])
            os.environ['GW_KEY'] = 'private-test-value'
            catalog = self.client.request('api/workbench')
            self.assertTrue(catalog['ready'], catalog['reasons'])
            self.assertEqual([m['id'] for m in catalog['models']], ['gw/test-model'])
            run = self.client.request('api/runs', {**self.request(), 'model': 'gw/test-model'})
            final = wait_run(self.manager, run['name'])
        self.assertEqual(final['status'], 'finished', final)
        argv = json.loads((self.manager.jobs_dir / run['name'] / 'argv.json').read_text())
        self.assertIn('GW_KEY=${GW_KEY}', argv)
        shipped = next(a.removeprefix('config=') for a in argv if a.startswith('config='))
        self.assertEqual(list(json.loads(Path(shipped).read_text())), ['custom_providers'])

    def test_a_task_host_variable_named_like_the_agent_key_is_refused(self):
        cfg = json.loads(self.manager.config_path.read_text())
        request = {'model': 'tokenjoy/test-model', 'suite': 'tau3-airline', 'tasks': ['tau3-bench__tau3-airline-0']}
        with patch.dict(os.environ, {'OPENAI_API_KEY': 'user-simulator-key'}):
            self.assertEqual(self.manager.launch(request, dry_run=True)['suite'], 'tau3-airline')
            atomic_json(self.manager.config_path, {**cfg, 'key_env': 'OPENAI_API_KEY'})
            with self.assertRaisesRegex(ValueError, 'OPENAI_API_KEY.*relay 占位令牌'):
                self.client.request('api/runs', request)
        self.assertEqual(self.manager.runs(), [])

    def test_no_credential_is_needed_but_cross_origin_is_refused(self):
        import urllib.request
        # An internal-network workbench: the page needs no link capability.
        catalog = self.client.request('api/workbench')
        self.assertTrue(catalog['can_run'])
        request = urllib.request.Request(self.client.url + 'api/runs', data=json.dumps(self.request()).encode(), headers={
            'Content-Type': 'application/json', 'Origin': 'https://other.example'})
        with self.assertRaises(urllib.error.HTTPError) as caught:
            urllib.request.urlopen(request)
        self.assertEqual(caught.exception.code, 403)
        caught.exception.close()
        self.assertEqual(self.manager.runs(), [])

    def raw(self, method, path, host=None, origin=None, body=None):
        """(status, error) of one request with chosen Host and Origin headers."""
        import http.client
        port = self.http.server_address[1]
        connection = http.client.HTTPConnection('127.0.0.1', port, timeout=10)
        headers = {'Host': host or f'127.0.0.1:{port}'}
        if origin is not None:
            headers['Origin'] = origin
        if body is not None:
            headers['Content-Type'] = 'application/json'
        try:
            connection.request(method, path, body=json.dumps(body).encode() if body is not None else None,
                               headers=headers)
            response = connection.getresponse()
            return response.status, (json.loads(response.read() or b'{}') or {}).get('error')
        finally:
            connection.close()

    def test_only_the_workbench_entries_are_served_and_origins_must_match_exactly(self):
        port = self.http.server_address[1]
        cancel = {'name': 'bench-20260101-000000-abcdef'}  # passes the checks, then "运行不存在"
        # A DNS-rebound foreign name reaches the service with that name in Host.
        for method, body in (('GET', None), ('POST', cancel)):
            path = '/api/workbench' if method == 'GET' else '/api/cancel'
            with self.subTest(method=method):
                self.assertEqual(self.raw(method, path, host=f'evil.example:{port}',
                                          origin=f'http://evil.example:{port}' if body else None, body=body)[0], 403)
        # Trusted entries: IP literals and localhost on the listening port.
        for host in (f'127.0.0.1:{port}', f'localhost:{port}'):
            with self.subTest(host=host):
                self.assertEqual(self.raw('GET', '/api/workbench', host=host)[0], 200)
                self.assertEqual(self.raw('POST', '/api/cancel', host=host, origin='http://' + host, body=cancel)[0], 400)
        # The CLI sends no Origin.
        self.assertEqual(self.raw('POST', '/api/cancel', body=cancel)[0], 400)
        # The browser Origin must be that entry exactly: scheme, host, port.
        for origin in (f'https://127.0.0.1:{port}', f'http://127.0.0.1:{port + 1}', 'http://127.0.0.1',
                       f'http://localhost:{port}', 'null', f'http://evil.example:{port}'):
            with self.subTest(origin=origin):
                self.assertEqual(self.raw('POST', '/api/cancel', origin=origin, body=cancel)[0], 403)
        self.assertEqual(self.raw('GET', '/api/workbench', host=f'127.0.0.1:{port + 1}')[0], 403)

    def test_a_configured_public_url_is_a_trusted_entry(self):
        self.assertEqual(server.trusted_origin('devbox:18766', 18766, 'http://devbox:18766/'), ('http', 'devbox', 18766))
        self.assertEqual(server.trusted_origin('bench.example', 18766, 'https://bench.example/'),
                         ('https', 'bench.example', 443))
        self.assertIsNone(server.trusted_origin('other:18766', 18766, 'http://devbox:18766/'))
        self.assertIsNone(server.trusted_origin('evil.example:18766', 18766, None))
        self.assertEqual(server.trusted_origin('[::1]:18766', 18766), ('http', '::1', 18766))
        trusted = server.trusted_origin('bench.example', 18766, 'https://bench.example/')
        self.assertTrue(server.same_origin('https://bench.example', trusted))
        self.assertTrue(server.same_origin('https://bench.example:443', trusted))
        self.assertFalse(server.same_origin('http://bench.example', trusted))

    def test_a_receipt_names_its_service_only_while_it_serves_this_workbench(self):
        url = f'http://127.0.0.1:{self.http.server_address[1]}/'
        saved = {'url': url, 'listen_url': url}
        self.assertIsNotNone(cli.receipt_client(saved, self.manager.config_path))
        # The port now belongs to a workbench of another state directory.
        self.assertIsNone(cli.receipt_client(saved, self.root / 'other' / 'workbench.json'))
        self.assertIsNone(cli.receipt_client({}, self.manager.config_path))
        # Ownership does not depend on the database statistics.
        with patch.object(Workbench, 'store_status', side_effect=RuntimeError('database busy')):
            self.assertIsNotNone(cli.receipt_client(saved, self.manager.config_path))

    def test_a_service_that_cannot_tell_whose_it_is_keeps_its_receipt(self):
        root = self.root / 'state' / 'bench'
        root.mkdir(parents=True)
        url = f'http://127.0.0.1:{self.http.server_address[1]}/'
        receipt = {'url': url, 'listen_url': url, 'jobs_dir': str(self.manager.jobs_dir)}
        atomic_json(root / 'service.json', receipt)
        with patch.object(cli.Client, 'request', side_effect=ValueError('internal error')):
            with self.assertRaisesRegex(ValueError, '无法确认'):
                cli.receipt_client(receipt, self.manager.config_path)
            self.assertEqual(cli.main(['stop', '--state-root', str(root.parent)]), 1)
        self.assertEqual(json.loads((root / 'service.json').read_text()), receipt)
        closed = socket.socket()
        closed.bind(('127.0.0.1', 0))
        gone = f'http://127.0.0.1:{closed.getsockname()[1]}/'
        closed.close()
        self.assertIsNone(cli.receipt_client({'url': gone}, self.manager.config_path))

    def test_an_unexpected_failure_answers_instead_of_dropping_the_connection(self):
        with patch.object(Workbench, 'queue_profile', side_effect=FileNotFoundError('/tmp/gone/bench-provider-x')):
            with self.assertRaisesRegex(ValueError, '内部错误'), redirect_stderr(io.StringIO()):
                self.client.request('api/profiles/run', {})

    def test_a_login_era_service_is_known_by_its_receipt_capability(self):
        legacy = {'url': 'http://127.0.0.1:1/', 'token': 'capability'}
        for can_run, mine in ((True, True), (False, False)):
            catalog = {'service': 'metacodes-bench', 'can_run': can_run}
            with self.subTest(can_run=can_run), patch.object(cli.Client, 'request', return_value=catalog) as request:
                client = cli.receipt_client(legacy, self.manager.config_path)
                self.assertEqual(client is not None, mine)
                request.assert_called_once_with('api/workbench')

    def test_replacing_a_running_service_keeps_its_entry(self):
        def args(**given):
            return argparse.Namespace(**{'bind': None, 'port': None, 'public_url': None, **given})
        self.assertEqual(cli.service_entry(args(), {}), ('127.0.0.1', 0, None))
        shared = {'url': 'http://10.0.0.2:18766/', 'listen_url': 'http://127.0.0.1:18766/'}
        self.assertEqual(cli.service_entry(args(), {**shared, 'bind': '0.0.0.0'}),
                         ('0.0.0.0', 18766, 'http://10.0.0.2:18766/'))
        # An older receipt has no bind, and 127.0.0.1 may have been 0.0.0.0.
        with self.assertRaisesRegex(ValueError, '--bind'):
            cli.service_entry(args(), shared)
        self.assertEqual(cli.service_entry(args(bind='0.0.0.0'), shared), ('0.0.0.0', 18766, 'http://10.0.0.2:18766/'))
        direct = {'url': 'http://10.0.0.2:18766/', 'listen_url': 'http://10.0.0.2:18766/'}
        self.assertEqual(cli.service_entry(args(), direct), ('10.0.0.2', 18766, None))
        self.assertEqual(cli.service_entry(args(port=9000), direct), ('10.0.0.2', 9000, None))
        # An older service bound to a host name gave that name as its page.
        named = {'url': 'http://devbox:18766/', 'listen_url': 'http://devbox:18766/'}
        self.assertEqual(cli.service_entry(args(), named), ('devbox', 18766, 'http://devbox:18766/'))

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
            def do_POST(self):
                self.rfile.read(int(self.headers['Content-Length']))
                seen.append(('model-request', self.headers.get('Authorization')))
                body = b'data: {"type": "message_stop"}\n\n'
                self.send_response(200)
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)

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
        with patch('scripts.eval.harbor.bench.account.GATEWAY', f'http://127.0.0.1:{upstream.server_port}'):
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
            with patch.dict(os.environ, {'FAKE_EXPECT_ACCOUNT_KEY': 'rotated-account-key', 'METASK_API_KEY': 'wrong-ambient-key',
                                         'FAKE_PROFILE_REQUEST': '1'}):
                run = self.client.request('api/runs', {**self.request(), 'model': 'metask/glm-test'})
                final = wait_run(self.manager, run['name'])
            self.assertEqual(final['status'], 'finished', final)
            job = self.manager.jobs_dir / run['name']
            argv = json.loads((job / 'argv.json').read_text())
            self.assertEqual(argv[argv.index('-m') + 1], 'metask/glm-test')
            self.assertIn('METASK_API_KEY=${METASK_API_KEY}', argv)
            self.assertIn('reasoning_effort=high', argv)
            self.assertFalse(any(arg.startswith('config=') for arg in argv))
            # Harbor holds the placeholder; the relay sent the current key.
            check = json.loads((job / 'credential-check.json').read_text())
            self.assertEqual((check['account_key_matches'], check['placeholder']), (False, True))
            self.assertEqual(seen[-1], ('model-request', 'Bearer rotated-account-key'))
            self.assertEqual(seen[-2][1], 'Bearer rotated-account-key')
            for path in list(self.manager.records.iterdir()) + [p for p in job.rglob('*') if p.is_file()]:
                text = path.read_text()
                for secret in ('account-test-key', 'rotated-account-key', 'never-forward-refresh'):
                    self.assertNotIn(secret, text)

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
        with patch.dict(os.environ, {'FAKE_EXPECT_ACCOUNT_KEY': 'group-claude-secret', 'FAKE_PROFILE_REQUEST': '1'}):
            run = self.client.request('api/runs', {**self.request(), 'model': 'metask/claude-test'})
            final = wait_run(self.manager, run['name'])
        self.assertEqual(final['status'], 'finished', final)
        job = self.manager.jobs_dir / run['name']
        self.assertTrue(json.loads((job / 'credential-check.json').read_text())['placeholder'])
        self.assertEqual(calls[-1], ('model-request', 'Bearer group-claude-secret'))
        spec = json.loads((self.manager.records / (run['name'] + '.spec')).read_text())
        self.assertEqual(spec['account_key_id'], 'claude-key')
        self.assertEqual(json.loads((state / 'auth.json').read_text())['api_key'], 'group-glm-secret')
        public = json.dumps(catalog) + ''.join(p.read_text() for p in self.manager.records.iterdir())
        public += ''.join(p.read_text() for p in job.rglob('*') if p.is_file())
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

    def test_gaia2_judge_goes_through_the_relay_with_its_own_placeholder(self):
        """GAIA2's verifier gets the relay route, a judge-only placeholder, the
        configured model and the CA path; the relay forwards to the gateway's
        /v1/chat/completions with the real session token."""
        state, upstream, calls = session_fixture(self.root)
        self.addCleanup(upstream.server_close)
        self.addCleanup(upstream.shutdown)
        dataset = gaia2_dataset(self.root)
        cfg = json.loads(self.manager.config_path.read_text())
        cfg.update(auth_mode='metask', account_state_dir=str(state), metrics_enabled=True, metrics_bind='127.0.0.1',
                   datasets={'gaia2-cli': str(dataset)})
        atomic_json(self.manager.config_path, cfg)
        # A judge key in the service environment must not reach Harbor.
        with patch.dict(os.environ, {'METASK_SITE_URL': f'http://127.0.0.1:{upstream.server_port}',
                                     'FAKE_JUDGE_REQUEST': '1', 'OPENAI_API_KEY': 'real-openai-key',
                                     'OPENAI_BASE_URL': 'https://openrouter.invalid/api/v1'}):
            catalog = self.client.request('api/workbench')
            entry = next(s for s in catalog['suites'] if s['id'] == 'gaia2-cli')
            # Metask authentication: no OPENAI_API_KEY requirement.
            self.assertTrue(entry['ready'], entry['reasons'])
            self.assertEqual(entry['judge'], {'model': 'glm-5.3-flash', 'via': 'metask'})
            run = self.client.request('api/runs', {'suite': 'gaia2-cli', 'model': 'metask/session-model',
                                                   'tasks': ['gaia2-search-0000-abc'], 'attempts': 1, 'concurrency': 1})
            final = wait_run(self.manager, run['name'])
        self.assertEqual(final['status'], 'finished', final)
        self.assertEqual(final['judge'], {'model': 'glm-5.3-flash', 'via': 'metask'})
        job = self.manager.jobs_dir / run['name']
        argv = json.loads((job / 'argv.json').read_text())
        relay = next(a.removeprefix('metrics_proxy=') for a in argv if a.startswith('metrics_proxy='))
        self.assertIn('OPENAI_API_KEY=${METACODES_BENCH_JUDGE_TOKEN}', argv)
        verifier = json.loads((job / 'verifier-env.json').read_text())
        agent = json.loads((job / 'container-env.json').read_text())['METASK_API_KEY']
        self.assertEqual(verifier['OPENAI_BASE_URL'], relay + '/bench-judge/v1')
        self.assertEqual(verifier['JUDGE_MODEL'], 'glm-5.3-flash')
        self.assertEqual(verifier['SSL_CERT_FILE'], '/usr/local/share/metacodes-bench/ca-bundle.pem')
        self.assertTrue(verifier['OPENAI_API_KEY'].startswith('mcb-'), verifier)
        self.assertNotEqual(verifier['OPENAI_API_KEY'], agent)
        # The judge got its answer; the agent's placeholder is refused there.
        statuses = json.loads((job / 'judge-statuses.json').read_text())
        self.assertEqual(statuses, {'judge': [200, 'GRADE: yes'], 'agent-token': [403, None]})
        judged = [c for c in calls if c[0] == 'judge-request']
        self.assertEqual(judged, [('judge-request', 'Bearer session-access',
                                   {'model': 'glm-5.3-flash', 'messages': [{'role': 'user', 'content': 'grade'}]})])
        self.assertFalse(any(isinstance(c[1], str) and 'mcb-' in c[1] for c in calls), calls)
        harbor_env = json.loads((job / 'harbor-env.json').read_text())
        self.assertNotIn('OPENAI_API_KEY', harbor_env)
        self.assertNotIn('OPENAI_BASE_URL', harbor_env)
        self.assertEqual(harbor_env['TZ'], 'UTC')
        self.assertEqual(harbor_env['METACODES_BENCH_JUDGE_TOKEN'], verifier['OPENAI_API_KEY'])
        # Judge requests are not agent metrics.
        self.assertFalse((job / '.bench-metrics' / 'bench-judge.jsonl').exists())
        files = [p for p in job.rglob('*') if p.is_file()] + list(self.manager.records.iterdir())
        public = b''.join(p.read_bytes() for p in files) + json.dumps(argv).encode()
        for secret in (b'session-access', b'session-refresh', b'session-rotated', b'real-openai-key'):
            self.assertNotIn(secret, public)
        view = self.client.request('api/job?name=' + run['name'])
        self.assertEqual(view['judge'], {'model': 'glm-5.3-flash', 'via': 'metask'})

    def test_gaia2_judge_model_is_configurable_and_must_be_in_the_account(self):
        state, upstream, calls = session_fixture(self.root)
        self.addCleanup(upstream.server_close)
        self.addCleanup(upstream.shutdown)
        cfg = json.loads(self.manager.config_path.read_text())
        cfg.update(auth_mode='metask', account_state_dir=str(state), metrics_bind='127.0.0.1',
                   datasets={'gaia2-cli': str(gaia2_dataset(self.root))},
                   judges={'gaia2-cli': {'model': 'metask/video-model'}})
        atomic_json(self.manager.config_path, cfg)
        request = {'suite': 'gaia2-cli', 'model': 'metask/session-model', 'tasks': ['gaia2-search-0000-abc']}
        with patch.dict(os.environ, {'METASK_SITE_URL': f'http://127.0.0.1:{upstream.server_port}',
                                     'FAKE_JUDGE_REQUEST': '1'}):
            run = self.client.request('api/runs', request)
            final = wait_run(self.manager, run['name'])
            self.assertEqual(final['status'], 'finished', final)
            verifier = json.loads((self.manager.jobs_dir / run['name'] / 'verifier-env.json').read_text())
            self.assertEqual(verifier['JUDGE_MODEL'], 'video-model')  # the gateway's bare id
            cfg['judges'] = {'gaia2-cli': {'model': 'no-such-judge'}}
            atomic_json(self.manager.config_path, cfg)
            run = self.client.request('api/runs', request)
            final = wait_run(self.manager, run['name'])
            self.assertEqual(final['status'], 'failed')
            self.assertIn('评委模型 no-such-judge 不在当前 Metask 账号的模型目录中', final['error'])
            self.assertFalse((self.manager.jobs_dir / run['name']).exists())  # Harbor never started
            cfg['judges'] = {'gaia2-cli': {'model': 'bad model'}}
            atomic_json(self.manager.config_path, cfg)
            entry = next(s for s in self.client.request('api/workbench')['suites'] if s['id'] == 'gaia2-cli')
            self.assertIn('judges.gaia2-cli.model 无效', ' '.join(entry['reasons']))

    def test_disabled_metrics_still_proxy_auth_and_record_nothing(self):
        state, upstream, calls = session_fixture(self.root)
        self.addCleanup(upstream.server_close)
        self.addCleanup(upstream.shutdown)
        cfg = json.loads(self.manager.config_path.read_text())
        cfg.update(auth_mode='metask', account_state_dir=str(state), metrics_enabled=False)
        atomic_json(self.manager.config_path, cfg)
        with patch.dict(os.environ, {'METASK_SITE_URL': f'http://127.0.0.1:{upstream.server_port}',
                                     'FAKE_PROFILE_REQUEST': '1'}):
            run = self.client.request('api/runs', {**self.request(), 'model': 'metask/session-model'})
            final = wait_run(self.manager, run['name'])
        self.assertEqual(final['status'], 'finished', final)
        # The container's placeholder became the session token at the relay.
        self.assertIn(('model-request', 'Bearer session-access', {'model': 'session-model'}), calls)
        job = self.manager.jobs_dir / run['name']
        self.assertTrue(json.loads((job / 'credential-check.json').read_text())['placeholder'])
        self.assertFalse((job / '.bench-metrics').exists())

    def test_unproxiable_provider_route_is_refused_instead_of_leaking_the_key(self):
        native = json.loads(Path(json.loads(self.manager.config_path.read_text())['provider_config']).read_text())
        native['custom_providers']['tokenjoy']['channels'][0]['base_url'] = 'https://tokenjoy.invalid/api/paas/v4'
        atomic_json(Path(json.loads(self.manager.config_path.read_text())['provider_config']), native)
        catalog = self.client.request('api/workbench')
        self.assertFalse(catalog['ready'])
        self.assertTrue(any('凭据代理' in r for r in catalog['reasons']), catalog['reasons'])
        with self.assertRaisesRegex(ValueError, '凭据代理'):
            self.client.request('api/runs', self.request())
        self.assertEqual(self.manager.runs(), [])

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


@unittest.skipUnless(POSIX, 'fake executable and worker signal test are POSIX')
class TokenRefreshRunTest(unittest.TestCase):
    """A run longer than several access-token lifetimes (seconds here)."""
    setUp = WorkbenchTest.setUp
    request = WorkbenchTest.request

    def gateway(self):
        gateway = RotatingGateway(self.root, lifetime=4)
        self.addCleanup(gateway.close)
        cfg = json.loads(self.manager.config_path.read_text())
        cfg.update(auth_mode='metask', account_state_dir=str(gateway.state), metrics_enabled=True)
        atomic_json(self.manager.config_path, cfg)
        env = patch.dict(os.environ, {'METASK_SITE_URL': gateway.url, 'METACODES_BENCH_REFRESH_MARGIN': '2',
                                      'METACODES_BENCH_REFRESH_INTERVAL': '0.2'})
        env.start()
        self.addCleanup(env.stop)
        return gateway

    def test_long_run_refreshes_before_expiry_and_containers_hold_only_a_placeholder(self):
        gateway = self.gateway()
        with patch.dict(os.environ, {'FAKE_RELAY_REQUESTS': '30', 'FAKE_RELAY_INTERVAL': '0.3'}):
            run = self.client.request('api/runs', {**self.request(), 'model': 'metask/session-model'})
            final = wait_run(self.manager, run['name'], timeout=60)
        self.assertEqual(final['status'], 'finished', final)
        job = self.manager.jobs_dir / run['name']
        # Every model request of the ~10 s run (2.5 lifetimes) was authorized
        # upstream: no 401 reached the container and none was needed.
        self.assertEqual(json.loads((job / 'relay-statuses.json').read_text()), [200] * 30)
        model_requests = [r for r in gateway.requests]
        self.assertEqual(len(model_requests), 30)
        self.assertTrue(all(ok for _, ok, _ in model_requests), model_requests)
        self.assertGreaterEqual(len({token for token, _, _ in model_requests}), 3)
        # Each refresh while the run served requests replaced a token that
        # was still valid: proactive.
        during_run = gateway.refreshes_while_serving()
        self.assertTrue(during_run and all(left > 0 for left in during_run), gateway.refreshes)
        self.assertEqual(gateway.rejected, [])
        credential = final['credential']
        self.assertEqual((credential['container'], credential['refreshing'], credential['error']),
                         ('placeholder', True, None))
        self.assertGreaterEqual(credential['refresh_count'], 2)
        self.assertTrue(credential['last_refresh_at'])
        # The rotated refresh token is persisted for the CLI and later runs.
        saved = json.loads((gateway.state / 'oauth/metask.json').read_text())
        self.assertEqual((saved['access_token'], saved['refresh_token']), (gateway.current_access, gateway.refresh_token))
        # Harbor's --ae value (the container env) is the placeholder; no real
        # token is in Harbor's env/argv, the trial dir, the run record or log.
        container = json.loads((job / 'container-env.json').read_text())
        self.assertTrue(container['METASK_API_KEY'].startswith('mcb-'), container)
        files = [p for p in job.rglob('*') if p.is_file()] + list(self.manager.records.iterdir())
        public = ''.join(p.read_text(errors='replace') for p in files)
        for secret in gateway.issued:
            self.assertNotIn(secret, public)
        self.assertTrue(list((job / '.bench-metrics').glob('*.jsonl')))

    def test_lost_login_fails_the_run_fast_with_a_clear_reason(self):
        gateway = self.gateway()
        with patch.dict(os.environ, {'FAKE_BENCH_DELAY': '30'}):
            run = self.client.request('api/runs', {**self.request(), 'model': 'metask/session-model'})
            deadline = time.monotonic() + 15
            while not (self.manager.jobs_dir / run['name'] / 'argv.json').exists():
                self.assertLess(time.monotonic(), deadline)
                time.sleep(.05)
            gateway.deny_refresh = True  # e.g. signed out elsewhere
            started = time.monotonic()
            final = wait_run(self.manager, run['name'], timeout=30)
        self.assertLess(time.monotonic() - started, 15)  # not the 30 s task
        self.assertEqual(final['status'], 'failed', final)
        self.assertIn('Metask 登录已失效，请重新登录', final['error'])
        self.assertEqual(final['credential']['error'], final['error'])


class CredentialRefreshTest(unittest.TestCase):
    """The relay with a refreshing session source, without a worker."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.gateway = RotatingGateway(self.root, lifetime=60)
        self.addCleanup(self.gateway.close)
        env = patch.dict(os.environ, {'METASK_SITE_URL': self.gateway.url})
        env.start()
        self.addCleanup(env.stop)

    def post(self, relay, token):
        import urllib.error
        import urllib.request
        request = urllib.request.Request(relay.url + '/t__1/v1/messages', data=b'{}',
                                         headers={'Authorization': 'Bearer ' + token})
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                response.read()
                return response.status
        except urllib.error.HTTPError as exc:
            exc.close()
            return exc.code

    def test_margin_constant_is_fifteen_minutes(self):
        from scripts.eval.harbor.bench import credentials
        self.assertEqual(credentials.REFRESH_MARGIN, 15 * 60)
        with patch.dict(os.environ, {'METACODES_BENCH_REFRESH_MARGIN': ''}):
            self.assertEqual(credentials.refresh_margin(), 900)
        # A one-hour token is refreshed 45 minutes in, not before.
        clock = [1000.0]
        account = type('A', (), {'session_access': lambda self, stale=None, margin=0: ('t', 1000 + 3600)})()
        source = credentials.SessionCredential(account, margin=900, clock=lambda: clock[0])
        calls = []
        account.session_access = lambda stale=None, margin=0: calls.append(margin) or ('t2', clock[0] + 3600)
        clock[0] = 1000 + 44 * 60
        self.assertEqual((source.current(), calls), ('t', []))
        clock[0] = 1000 + 46 * 60
        self.assertEqual((source.current(), calls), ('t2', [900]))
        self.assertEqual(source.refresh_count, 1)

    def test_rejected_token_is_refreshed_once_and_the_request_retried(self):
        from scripts.eval.harbor.profiling import TimingRelay
        from scripts.eval.harbor.bench.credentials import SessionCredential
        source = SessionCredential(Account(self.gateway.state), margin=2)
        first = source.current()
        with TimingRelay(self.gateway.url, source, self.root / 'metrics', bind='127.0.0.1',
                         token='mcb-test-placeholder', record=False) as relay:
            self.gateway.revoke(first)  # the gateway rejects a still-unexpired token
            self.assertEqual(self.post(relay, 'mcb-test-placeholder'), 200)
            tokens = [(token, ok) for token, ok, _ in self.gateway.requests]
            self.assertEqual(tokens, [(first, False), (source.token, True)])
            self.assertEqual(source.refresh_count, 1)
            saved = json.loads((self.gateway.state / 'oauth/metask.json').read_text())
            self.assertEqual(saved['refresh_token'], self.gateway.refresh_token)
            # A wrong placeholder never reaches the gateway.
            self.assertEqual(self.post(relay, 'mcb-test-wrong'), 401)
            self.assertEqual(len(self.gateway.requests), 2)
            # The CLI rotates the pair meanwhile; the relay's next refresh
            # re-reads it under the lock instead of reusing the old refresh
            # token (which the endpoint would reject).
            Account(self.gateway.state).oauth_bearer(stale=source.token)
            self.gateway.revoke(source.token)
            self.assertEqual(self.post(relay, 'mcb-test-placeholder'), 200)
            self.assertEqual(self.gateway.rejected, [])
            self.assertEqual(source.token, self.gateway.current_access)
            # The login is gone: the upstream 401 passes through once, then
            # the relay refuses without calling upstream; the reason is set.
            self.gateway.deny_refresh = True
            self.gateway.revoke(source.token)
            self.assertEqual(self.post(relay, 'mcb-test-placeholder'), 401)
            count = len(self.gateway.requests)
            self.assertEqual(self.post(relay, 'mcb-test-placeholder'), 401)
            self.assertEqual(len(self.gateway.requests), count)
            self.assertTrue(source.failed)
            self.assertIn('请重新登录', source.status()['error'])
        self.assertFalse((self.root / 'metrics').exists())


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


def hold_byte_lock(fd):
    if os.name == 'nt':
        import msvcrt
        os.lseek(fd, 0, os.SEEK_SET)
        msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
    else:
        import fcntl
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)


def release_byte_lock(fd):
    if os.name == 'nt':
        import msvcrt
        os.lseek(fd, 0, os.SEEK_SET)
        msvcrt.locking(fd, msvcrt.LK_UNLCK, 1)
    else:
        import fcntl
        fcntl.flock(fd, fcntl.LOCK_UN)


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

    def test_a_refresh_waits_for_the_holder_of_an_empty_lock_file_and_writes_nothing_into_it(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        state = Path(tmp.name)
        path = state / 'bench-oauth.lock'
        held = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
        self.addCleanup(os.close, held)
        hold_byte_lock(held)
        entered, errors = threading.Event(), []

        def refresh():
            try:
                with refresh_lock(state):
                    entered.set()
            except OSError as exc:
                errors.append(exc)

        worker = threading.Thread(target=refresh, daemon=True)
        worker.start()
        time.sleep(0.3)
        self.assertFalse(entered.is_set())
        release_byte_lock(held)
        worker.join(15)
        self.assertEqual(errors, [])
        self.assertTrue(entered.is_set())
        self.assertEqual(path.stat().st_size, 0)

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


class ServiceReuseTest(unittest.TestCase):
    STORE = {'backend': 'sqlite', 'path': '/state/bench/bench.sqlite'}
    CONFIG = Path('/state/bench/workbench.json')

    def store(self):
        return types.SimpleNamespace(describe=lambda: self.STORE)

    def test_directory_check_and_client_come_from_one_service_record(self):
        # A second read would see another startup's service for directory B.
        records = iter([{'url': 'http://127.0.0.1:1/', 'jobs_dir': '/jobs/a', 'store': self.STORE},
                        {'url': 'http://127.0.0.1:2/', 'jobs_dir': '/jobs/b', 'store': self.STORE}])
        with patch.object(cli, 'settings', side_effect=lambda _path: next(records)), \
                patch.object(cli.Client, 'request', return_value={'service': 'metacodes-bench', 'config_path': str(self.CONFIG.resolve())}):
            client = cli.running_service(Path('/state/bench'), self.CONFIG, '/jobs/a', self.store())
        self.assertEqual(client.url, 'http://127.0.0.1:1/')

    def test_service_runs_on_its_own_temporary_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            jobs = str(root / 'jobs')
            started = {'url': 'http://127.0.0.1:1/', 'listen_url': 'http://127.0.0.1:1/', 'bind': '127.0.0.1',
                       'jobs_dir': jobs, 'store': self.STORE}
            earlier = dict(started)
            atomic_json(root / 'service.json', earlier)
            catalog = {'service': 'metacodes-bench', 'config_path': str(self.CONFIG.resolve())}
            with patch.object(cli.Client, 'request', return_value=catalog), \
                    patch.object(cli, 'stop_service') as stop, \
                    patch.object(cli, 'settings', side_effect=[earlier, started]), \
                    patch.object(cli.subprocess, 'Popen') as popen:
                cli.ensure_service(argparse.Namespace(action='open', bind=None, port=None, public_url=None),
                                   root, self.CONFIG, jobs, self.store())
            stop.assert_called_once()
            self.assertEqual(popen.call_args.kwargs['env']['TMPDIR'], str(root / 'tmp'))
            self.assertTrue((root / 'tmp').is_dir())
            receipt = json.loads((root / 'service.json').read_text())
            self.assertEqual(receipt, {**started, 'tmpdir': str(root / 'tmp'), 'runtime': str(cli.RUNTIME_ROOT)})

    def test_opening_with_another_build_replaces_the_service_and_other_commands_reuse_it(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            jobs = str(root / 'jobs')
            catalog = {'service': 'metacodes-bench', 'config_path': str(self.CONFIG.resolve())}
            receipt = {'url': 'http://127.0.0.1:1/', 'listen_url': 'http://127.0.0.1:1/', 'bind': '127.0.0.1',
                       'jobs_dir': jobs, 'store': self.STORE, 'tmpdir': str(root / 'tmp')}
            cases = (('open', str(cli.RUNTIME_ROOT), False), ('open', '/state/bench/runtime/older', True),
                     ('open', None, True), ('run', '/state/bench/runtime/older', False))
            for action, runtime, replaced in cases:
                saved = {**receipt, 'runtime': runtime} if runtime else receipt
                with self.subTest(action=action, runtime=runtime), \
                        patch.object(cli.Client, 'request', return_value=catalog), \
                        patch.object(cli, 'stop_service') as stop, \
                        patch.object(cli, 'settings', return_value=saved), \
                        patch.object(cli.subprocess, 'Popen') as popen:
                    try:
                        cli.ensure_service(argparse.Namespace(action=action, bind=None, port=None, public_url=None),
                                           root, self.CONFIG, jobs, self.store())
                    except ValueError:
                        pass
                    self.assertEqual(stop.called, replaced)
                    self.assertEqual(popen.called, replaced)

    def test_service_for_another_directory_is_not_reused(self):
        record = {'url': 'http://127.0.0.1:2/', 'jobs_dir': '/jobs/b', 'store': self.STORE}
        with patch.object(cli, 'settings', return_value=record), \
                patch.object(cli.Client, 'request', return_value={'service': 'metacodes-bench', 'config_path': str(self.CONFIG.resolve())}):
            self.assertIsNone(cli.running_service(Path('/state/bench'), self.CONFIG, '/jobs/a', self.store()))


class LayeringTest(unittest.TestCase):
    """The runtime (bench/) stands alone; the page and the CLI only present it."""

    HARBOR = Path(__file__).resolve().parents[1] / 'harbor'

    def imports(self, path):
        """Every module or name a file imports, relative imports resolved."""
        package = '.'.join(path.resolve().relative_to(self.HARBOR.parents[2]).parent.parts)
        names = set()
        for node in ast.walk(ast.parse(path.read_text(encoding='utf-8'))):
            if isinstance(node, ast.Import):
                names.update(alias.name for alias in node.names)
            elif isinstance(node, ast.ImportFrom):
                base = package.split('.')
                base = base[:len(base) - node.level + 1] if node.level else []
                module = '.'.join(base + ([node.module] if node.module else []))
                names.add(module)
                names.update(module + '.' + alias.name for alias in node.names)
        return names

    def test_imports_resolve_from_and_relative_forms(self):
        with tempfile.TemporaryDirectory(dir=self.HARBOR / 'bench') as temp:
            probe = Path(temp) / 'probe.py'
            probe.write_text('from scripts.eval.harbor import cli\nfrom ... import viewer\n', encoding='utf-8')
            names = self.imports(probe)
        self.assertIn('scripts.eval.harbor.cli', names)
        self.assertIn('scripts.eval.harbor.viewer', names)

    def test_runtime_imports_no_presentation(self):
        for path in sorted((self.HARBOR / 'bench').glob('*.py')):
            for name in self.imports(path):
                with self.subTest(module=path.name, imports=name):
                    self.assertFalse(name.startswith(('scripts.eval.harbor.viewer', 'scripts.eval.harbor.cli')))
                    self.assertNotIn(name, ('http.server', 'webbrowser', 'argparse'))

    def test_presentations_do_not_import_each_other(self):
        self.assertFalse(any(n.startswith('scripts.eval.harbor.cli') for n in self.imports(self.HARBOR / 'viewer/server.py')))
        self.assertFalse(any(n.startswith('scripts.eval.harbor.viewer') for n in self.imports(self.HARBOR / 'cli.py')))

    def test_binary_carries_every_runtime_and_viewer_module(self):
        assets = (self.HARBOR.parents[1] / 'bench_assets.zig').read_text(encoding='utf-8')
        for package in ('bench', 'viewer'):
            for path in sorted((self.HARBOR / package).glob('*.py')):
                with self.subTest(module=f'{package}/{path.name}'):
                    self.assertIn(f'@embedFile("eval/harbor/{package}/{path.name}")', assets)


if __name__ == '__main__':
    unittest.main()
