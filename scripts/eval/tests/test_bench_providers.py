"""Providers imported into the Bench workbench by URL and API key.

A local fake provider stands in for the endpoint: it lists models, answers
the echo probe (correctly or not) and records each request's credential. No
real provider is called.
"""
from __future__ import annotations

import io
import json
import os
import stat
import tempfile
import threading
import unittest
from contextlib import redirect_stdout
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

from scripts.eval.harbor import cli
from scripts.eval.harbor.profiling import auth_for, route_problem, upstream_for
from scripts.eval.harbor.viewer import data, providers, server
from scripts.eval.harbor.viewer.providers import Providers, echoed, normalize_base_url, reply_text
from scripts.eval.harbor.viewer.runner import RunManager, atomic_json
from scripts.eval.tests.posix_only import POSIX
from scripts.eval.tests.test_bench_workbench import fixture, wait_run

KEY = 'imported-secret-key-1234'


def fake_provider():
    """An OpenAI/Anthropic-compatible endpoint. Model `echo` repeats the
    string it is asked for, `wrong` answers something else, `broken` fails."""
    calls = []

    class Endpoint(BaseHTTPRequestHandler):
        def reply(self, value, status=200):
            body = json.dumps(value).encode()
            self.send_response(status)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def key(self):
            return self.headers.get('x-api-key') or self.headers.get('Authorization', '').removeprefix('Bearer ')

        def do_GET(self):
            calls.append(('GET', self.path, self.key()))
            if self.key() != KEY:
                self.reply({'error': 'bad key ' + self.key()}, 401)
            elif self.path == '/v1/models':
                self.reply({'data': [{'id': 'echo'}, {'id': 'wrong'}]})
            else:
                self.reply({}, 404)

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            calls.append(('POST', self.path, self.key(), body))
            if self.key() != KEY:
                self.reply({'error': 'invalid key ' + self.key()}, 401)
                return
            if self.path == '/fix-git__fake/v1/messages' or body.get('n') is not None:
                self.reply({'content': [{'type': 'text', 'text': 'ok'}]})
                return
            prompt = (body.get('messages') or [{}])[0].get('content') or body.get('input') or ''
            expected = prompt.rsplit(' ', 1)[-1]
            model = body.get('model')
            if model == 'broken':
                self.reply({'error': {'message': 'model overloaded'}}, 503)
                return
            text = expected if model == 'echo' else 'Sure! ' + expected[::-1]
            if self.path == '/v1/chat/completions':
                self.reply({'choices': [{'message': {'role': 'assistant', 'content': '"' + text + '"\n'}}]})
            elif self.path == '/v1/messages':
                self.reply({'content': [{'type': 'thinking', 'thinking': 'x'}, {'type': 'text', 'text': text}]})
            elif self.path == '/v1/responses':
                self.reply({'output': [{'type': 'message', 'content': [{'type': 'output_text', 'text': text}]}]})
            else:
                self.reply({}, 404)

        def log_message(self, *_args):
            pass

    http = ThreadingHTTPServer(('127.0.0.1', 0), Endpoint)
    threading.Thread(target=http.serve_forever, daemon=True).start()
    return http, calls


class HelpersTest(unittest.TestCase):
    def test_base_url_is_normalized_per_protocol_and_unproxiable_paths_are_refused(self):
        self.assertEqual(normalize_base_url('https://api.x.com', 'openai_chat'), 'https://api.x.com/v1')
        self.assertEqual(normalize_base_url('https://api.x.com/v1/', 'openai_responses'), 'https://api.x.com/v1')
        self.assertEqual(normalize_base_url('https://api.x.com/v1/chat/completions', 'openai_chat'), 'https://api.x.com/v1')
        self.assertEqual(normalize_base_url('http://10.0.0.2:8000/v1', 'anthropic_messages'), 'http://10.0.0.2:8000')
        self.assertEqual(normalize_base_url('https://api.x.com/v1/messages', 'anthropic_messages'), 'https://api.x.com')
        for bad in ('', 'ftp://x', 'https://x.com/api/paas/v4', 'https://u:p@x.com', 'https://x.com/v1?key=1'):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                normalize_base_url(bad, 'openai_chat')

    def test_echo_must_be_the_exact_string(self):
        self.assertTrue(echoed('mc-echo-ab12', 'mc-echo-ab12'))
        self.assertTrue(echoed(' "mc-echo-ab12".\n', 'mc-echo-ab12'))
        self.assertTrue(echoed('`mc-echo-ab12`', 'mc-echo-ab12'))
        self.assertFalse(echoed('Sure: mc-echo-ab12', 'mc-echo-ab12'))
        self.assertFalse(echoed('mc-echo-ab13', 'mc-echo-ab12'))
        self.assertFalse(echoed(None, 'mc-echo-ab12'))

    def test_reply_text_reads_each_protocol(self):
        self.assertEqual(reply_text('openai_chat', {'choices': [{'message': {'content': 'a'}}]}), 'a')
        self.assertEqual(reply_text('openai_chat', {'choices': [{'message': {'content': [{'type': 'text', 'text': 'b'}]}}]}), 'b')
        self.assertEqual(reply_text('anthropic_messages', {'content': [{'type': 'text', 'text': 'c'}]}), 'c')
        self.assertEqual(reply_text('openai_responses', {'output_text': 'd'}), 'd')
        self.assertIsNone(reply_text('openai_chat', {'choices': []}))


class ProviderStoreTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / 'bench'
        self.http, self.calls = fake_provider()
        self.addCleanup(self.http.server_close)
        self.addCleanup(self.http.shutdown)
        self.url = f'http://127.0.0.1:{self.http.server_port}'
        self.store = Providers(self.root)

    def test_models_are_discovered_and_the_key_stays_in_a_private_file(self):
        added = self.store.add({'id': 'gw', 'name': 'Gateway', 'base_url': self.url + '/v1', 'api_key': KEY})
        self.assertEqual([m['id'] for m in added['models']], ['gw/echo', 'gw/wrong'])
        self.assertEqual(added['key_hint'], '…1234')
        self.assertNotIn(KEY, json.dumps(added))
        self.assertNotIn(KEY, json.dumps(self.store.listing()))
        self.assertNotIn(KEY, json.dumps(self.store.models()))
        self.assertEqual(self.store.secret('gw'), KEY)
        if POSIX:
            self.assertEqual(stat.S_IMODE(self.store.path.stat().st_mode), 0o600)
        # The run's config names the key's variable, never the key.
        native = self.store.native_config('gw')
        self.assertNotIn(KEY, json.dumps(native))
        self.assertEqual(native['custom_providers']['gw']['env_aliases'][0]['name'], providers.KEY_ENV)

    def test_probe_passes_only_when_the_model_echoes_the_random_string(self):
        self.store.add({'id': 'gw', 'base_url': self.url, 'api_key': KEY, 'models': ['echo', 'wrong', 'broken']})
        ok = self.store.probe('gw', 'echo')
        self.assertTrue(ok['ok'], ok)
        self.assertTrue(ok['expected'].startswith('mc-echo-'))
        self.assertEqual(ok['reply'], '"' + ok['expected'] + '"')
        sent = self.calls[-1][3]['messages'][0]['content']
        self.assertTrue(sent.endswith(ok['expected']))
        wrong = self.store.probe('gw', 'wrong')
        self.assertFalse(wrong['ok'])
        self.assertIn('不一致', wrong['error'])
        broken = self.store.probe('gw', 'broken')
        self.assertFalse(broken['ok'])
        self.assertIn('HTTP 503', broken['error'])
        # A fresh string each time.
        self.assertNotEqual(self.store.probe('gw', 'echo')['expected'], ok['expected'])
        probes = {m['name']: m['probe'] for m in self.store.listing()['providers'][0]['models']}
        self.assertEqual({k: v['ok'] for k, v in probes.items()}, {'echo': True, 'wrong': False, 'broken': False})
        labels = {m['id']: m['label'] for m in self.store.models()}
        self.assertIn('探测通过', labels['gw/echo'])
        self.assertIn('探测失败', labels['gw/wrong'])

    def test_each_protocol_and_auth_header_reach_the_endpoint(self):
        self.store.add({'id': 'claude', 'base_url': self.url + '/v1', 'api_key': KEY,
                        'protocol': 'anthropic_messages', 'models': ['echo']})
        self.assertTrue(self.store.probe('claude', 'echo')['ok'])
        self.assertEqual(self.calls[-1][1], '/v1/messages')
        self.store.add({'id': 'resp', 'base_url': self.url, 'api_key': KEY,
                        'protocol': 'openai_responses', 'models': ['echo']})
        self.assertTrue(self.store.probe('resp', 'echo')['ok'])
        self.assertEqual(self.calls[-1][1], '/v1/responses')

    def test_rejected_key_is_reported_without_echoing_it(self):
        self.store.add({'id': 'gw', 'base_url': self.url, 'api_key': 'wrong-key-abcdefgh', 'models': ['echo']})
        result = self.store.probe('gw', 'echo')
        self.assertFalse(result['ok'])
        self.assertIn('HTTP 401', result['error'])
        self.assertNotIn('wrong-key-abcdefgh', json.dumps(result))
        with self.assertRaisesRegex(ValueError, 'HTTP 401') as caught:
            self.store.add({'id': 'gw2', 'base_url': self.url, 'api_key': 'wrong-key-abcdefgh'})
        self.assertNotIn('wrong-key-abcdefgh', str(caught.exception))

    def test_replace_keeps_the_key_and_a_changed_key_voids_old_probes(self):
        self.store.add({'id': 'gw', 'base_url': self.url, 'api_key': KEY, 'models': ['echo']})
        self.store.probe('gw', 'echo')
        with self.assertRaisesRegex(ValueError, '已存在'):
            self.store.add({'id': 'gw', 'base_url': self.url, 'api_key': KEY, 'models': ['echo']})
        renamed = self.store.add({'id': 'gw', 'name': 'Renamed', 'base_url': self.url, 'models': ['echo'], 'replace': True})
        self.assertEqual(renamed['name'], 'Renamed')
        self.assertTrue(renamed['models'][0]['probe']['ok'])
        self.assertEqual(self.store.secret('gw'), KEY)
        rekeyed = self.store.add({'id': 'gw', 'base_url': self.url, 'api_key': 'another-key-5678',
                                  'models': ['echo'], 'replace': True})
        self.assertIsNone(rekeyed['models'][0]['probe'])
        self.store.remove('gw')
        self.assertEqual(self.store.listing()['providers'], [])

    def test_invalid_requests_are_refused(self):
        for request in ({'id': 'Bad Id', 'base_url': self.url, 'api_key': KEY, 'models': ['m']},
                        {'id': 'metask', 'base_url': self.url, 'api_key': KEY, 'models': ['m']},
                        {'id': 'gw', 'base_url': self.url, 'models': ['m']},
                        {'id': 'gw', 'base_url': self.url, 'api_key': KEY, 'models': ['bad model']},
                        {'id': 'gw', 'base_url': self.url, 'api_key': KEY, 'models': ['m'], 'protocol': 'grpc'},
                        {'id': 'gw', 'base_url': self.url, 'api_key': 'a\nb', 'models': ['m']},
                        {'id': 'gw', 'base_url': self.url, 'api_key': KEY, 'models': ['m'], 'extra': 1}):
            with self.subTest(request=request), self.assertRaises(ValueError):
                self.store.add(request)
        self.assertEqual(self.store.entries(), [])

    def test_generated_config_routes_through_the_credential_relay(self):
        self.store.add({'id': 'claude', 'base_url': 'https://api.example.com/v1', 'api_key': KEY,
                        'protocol': 'anthropic_messages', 'models': ['m']})
        path = providers.write_config(self.root / 'run.provider', self.store.native_config('claude'))
        spec = {'auth_mode': 'provider', 'provider_config': path, 'model': 'claude/m'}
        self.assertIsNone(route_problem(spec))
        self.assertEqual(upstream_for(spec), 'https://api.example.com')
        self.assertEqual(auth_for(spec), ('x-api-key', ''))


class ProviderCliTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.state = Path(self.tmp.name)
        self.http, self.calls = fake_provider()
        self.addCleanup(self.http.server_close)
        self.addCleanup(self.http.shutdown)
        self.url = f'http://127.0.0.1:{self.http.server_port}/v1'

    def run_cli(self, *argv, stdin=''):
        out = io.StringIO()
        with redirect_stdout(out), patch('sys.stdin', io.StringIO(stdin)):
            code = cli.main(['--state-root', str(self.state), *argv])
        return code, out.getvalue()

    def test_add_reads_the_key_from_an_environment_variable_and_probe_reports(self):
        with patch.dict(os.environ, {'GW_KEY': KEY}):
            code, out = self.run_cli('provider', 'add', '--id', 'gw', '--base-url', self.url, '--key-env', 'GW_KEY',
                                     '--provider-model', 'echo', '--probe')
        self.assertEqual(code, 0, out)
        self.assertIn('gw/echo', out)
        self.assertIn('探测通过', out)
        self.assertNotIn(KEY, out)
        # `--key-env` here never becomes the workbench's provider-mode key.
        self.assertNotIn('key_env', data.read_json(self.state / 'bench' / 'workbench.json') or {})
        code, out = self.run_cli('provider', 'probe', '--id', 'gw', '--model', 'gw/echo', '--json')
        self.assertEqual(code, 0)
        self.assertTrue(json.loads(out)['ok'])
        code, out = self.run_cli('provider', 'list')
        self.assertIn('探测通过', out)

    def test_key_from_stdin_and_failed_probe_exit_status(self):
        code, _ = self.run_cli('provider', 'add', '--id', 'gw', '--base-url', self.url, '--provider-model', 'wrong',
                               stdin=KEY + '\n')
        self.assertEqual(code, 0)
        code, out = self.run_cli('provider', 'probe', '--id', 'gw')
        self.assertEqual(code, 1)
        self.assertIn('探测失败', out)
        code, out = self.run_cli('provider', 'remove', '--id', 'gw')
        self.assertEqual(code, 0)
        self.assertEqual(Providers(self.state / 'bench').entries(), [])


@unittest.skipUnless(POSIX, 'fake executable and worker signal test are POSIX')
class ImportedProviderRunTest(unittest.TestCase):
    """HTTP import -> catalog -> real worker -> relay with the imported key."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        config, binary_dir = fixture(self.root)
        self.env = patch.dict(os.environ, {'PATH': str(binary_dir) + os.pathsep + os.environ.get('PATH', ''),
                                          'TOKENJOY_API_KEY': 'private-test-value'})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.upstream, self.calls = fake_provider()
        self.addCleanup(self.upstream.server_close)
        self.addCleanup(self.upstream.shutdown)
        self.manager = RunManager(self.root / 'jobs', config)
        self.http = server.make_server(data.Library([self.manager.jobs_dir]), '127.0.0.1', 0,
                                       self.manager, 'test-capability')
        threading.Thread(target=self.http.serve_forever, daemon=True).start()
        self.addCleanup(self.http.server_close)
        self.addCleanup(self.http.shutdown)
        self.client = cli.Client(f'http://127.0.0.1:{self.http.server_address[1]}/', 'test-capability')

    def test_imported_model_runs_with_only_a_placeholder_and_the_relay_sends_the_key(self):
        added = self.client.request('api/providers', {
            'id': 'local', 'name': 'Local', 'base_url': f'http://127.0.0.1:{self.upstream.server_port}',
            'api_key': KEY, 'protocol': 'anthropic_messages', 'auth': 'bearer', 'models': ['echo'], 'probe': True})
        self.assertTrue(added['probe']['ok'], added)
        self.assertNotIn(KEY, json.dumps(added))
        listing = self.client.request('api/providers')
        self.assertEqual(listing['providers'][0]['id'], 'local')
        self.assertNotIn(KEY, json.dumps(listing))
        with self.assertRaisesRegex(ValueError, '授权'):
            cli.Client(self.client.url).request('api/providers')
        catalog = self.client.request('api/workbench')
        self.assertIn('local/echo', [m['id'] for m in catalog['models']])
        self.assertIn('tokenjoy/test-model', [m['id'] for m in catalog['models']])
        self.assertTrue(catalog['ready'], catalog['reasons'])
        self.assertNotIn(KEY, json.dumps(catalog))

        cfg = json.loads(self.manager.config_path.read_text())
        cfg.update(metrics_enabled=True, metrics_bind='127.0.0.1')
        atomic_json(self.manager.config_path, cfg)
        with patch.dict(os.environ, {'FAKE_RELAY_REQUESTS': '1', 'FAKE_RELAY_INTERVAL': '0'}):
            run = self.client.request('api/runs', {'model': 'local/echo', 'tasks': ['fix-git'],
                                                   'attempts': 1, 'concurrency': 1})
            final = wait_run(self.manager, run['name'])
        self.assertEqual(final['status'], 'finished', final)
        job = self.manager.jobs_dir / run['name']
        self.assertEqual(json.loads((job / 'relay-statuses.json').read_text()), [200])
        argv = json.loads((job / 'argv.json').read_text())
        self.assertIn(providers.KEY_ENV + '=${' + providers.KEY_ENV + '}', argv)
        container = json.loads((job / 'container-env.json').read_text())
        self.assertTrue(container[providers.KEY_ENV].startswith('mcb-'), container)
        config = next(a.removeprefix('config=') for a in argv if a.startswith('config='))
        self.assertNotIn(KEY, Path(config).read_text())
        for path in [*job.rglob('*'), *self.manager.records.glob('*')]:
            if path.is_file():
                self.assertNotIn(KEY, path.read_text(errors='replace'), path)
        # The relay replaced the placeholder with the imported key upstream.
        relayed = [c for c in self.calls if c[0] == 'POST' and c[1] == '/v1/messages' and c[3].get('model') == 'echo'
                   and c[3].get('messages') is None]
        self.assertTrue(relayed, self.calls)
        self.assertEqual(relayed[-1][2], KEY)

    def test_imported_models_do_not_need_the_provider_mode_key(self):
        os.environ.pop('TOKENJOY_API_KEY')
        self.assertFalse(self.client.request('api/workbench')['ready'])
        self.client.request('api/providers', {'id': 'local', 'base_url': f'http://127.0.0.1:{self.upstream.server_port}',
                                              'api_key': KEY, 'models': ['echo']})
        catalog = self.client.request('api/workbench')
        self.assertTrue(catalog['ready'], catalog['reasons'])
        self.assertEqual([m['id'] for m in catalog['models']], ['local/echo'])
        self.assertTrue(any('TOKENJOY_API_KEY' in w for w in catalog['warnings']), catalog['warnings'])

    def test_judged_and_workbuddy_suites_refuse_imported_models(self):
        self.client.request('api/providers', {'id': 'local', 'base_url': f'http://127.0.0.1:{self.upstream.server_port}',
                                              'api_key': KEY, 'models': ['echo']})
        cfg = json.loads(self.manager.config_path.read_text())
        cfg['auth_mode'] = 'metask'  # a judge goes through the Metask account
        atomic_json(self.manager.config_path, cfg)
        with patch('scripts.eval.harbor.suites.judge', return_value={'model': 'glm-5.3-flash', 'env': {}}):
            with self.assertRaisesRegex(ValueError, '评委'):
                self.manager.launch({'model': 'local/echo', 'tasks': ['fix-git']}, dry_run=True)
        self.assertEqual(self.manager.runs(), [])


if __name__ == '__main__':
    unittest.main()
