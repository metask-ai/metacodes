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
import time
import unittest
from contextlib import redirect_stdout
from functools import partial
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

from scripts.eval.harbor import cli
from scripts.eval.harbor.profiling import auth_for, route_problem, upstream_for
from scripts.eval.harbor.bench import data, providers
from scripts.eval.harbor.viewer import server
from scripts.eval.harbor.bench.providers import Providers, echoed, normalize_base_url, reply_text
from scripts.eval.harbor.bench.runner import RunManager, atomic_json
from scripts.eval.harbor.bench.workbench import Workbench
from scripts.eval.tests.posix_only import POSIX
from scripts.eval.tests.test_bench_workbench import fixture, offline_hugging_face, wait_run

KEY = 'imported-secret-key-1234'


def fake_provider():
    """An OpenAI/Anthropic-compatible endpoint. Model `echo` repeats the
    string it is asked for, `period` repeats it with a final period,
    `wrong` answers something else, `broken` fails."""
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
            text = {'echo': expected, 'period': expected + '.', 'spaced': expected + ' '}.get(model, 'Sure! ' + expected[::-1])
            if self.path == '/v1/chat/completions':
                self.reply({'choices': [{'message': {'role': 'assistant', 'content': text}}]})
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
        for extra in ('"mc-echo-ab12"', 'mc-echo-ab12.', '`mc-echo-ab12`', 'mc-echo-ab12。', "'mc-echo-ab12'",
                      '\tmc-echo-ab12', 'mc-echo-ab12 ', 'mc-echo-ab12\n', ' mc-echo-ab12'):
            with self.subTest(extra=extra):
                self.assertFalse(echoed(extra, 'mc-echo-ab12'))
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
        self.assertEqual(self.store.secret('gw', self.store.find('gw')['revision']), KEY)
        if POSIX:
            self.assertEqual(stat.S_IMODE(self.store.path.stat().st_mode), 0o600)
        # The run's config names the key's variable, never the key.
        route = self.store.run_route('gw/echo')
        self.assertNotIn(KEY, json.dumps(route))
        self.assertEqual(route['model'], 'bench-gw/echo')
        native = route['config']
        self.assertEqual(native['custom_providers']['bench-gw']['env_aliases'][0]['name'], providers.KEY_ENV)

    def test_probe_passes_only_when_the_model_echoes_the_random_string(self):
        self.store.add({'id': 'gw', 'base_url': self.url, 'api_key': KEY, 'models': ['echo', 'period', 'wrong', 'broken']})
        ok = self.store.probe('gw', 'echo')
        self.assertTrue(ok['ok'], ok)
        self.assertTrue(ok['expected'].startswith('mc-echo-'))
        self.assertEqual(ok['reply'], ok['expected'])
        sent = self.calls[-1][3]['messages'][0]['content']
        self.assertTrue(sent.endswith(ok['expected']))
        period = self.store.probe('gw', 'period')
        self.assertFalse(period['ok'], period)
        self.assertEqual(period['reply'], period['expected'] + '.')
        wrong = self.store.probe('gw', 'wrong')
        self.assertFalse(wrong['ok'])
        self.assertIn('不一致', wrong['error'])
        broken = self.store.probe('gw', 'broken')
        self.assertFalse(broken['ok'])
        self.assertIn('HTTP 503', broken['error'])
        # A fresh string each time.
        self.assertNotEqual(self.store.probe('gw', 'echo')['expected'], ok['expected'])
        probes = {m['name']: m['probe'] for m in self.store.listing()['providers'][0]['models']}
        self.assertEqual({k: v['ok'] for k, v in probes.items()}, {'echo': True, 'period': False, 'wrong': False, 'broken': False})
        # The catalog (readable without the capability) carries pass/fail only.
        catalog = {m['id']: m for m in self.store.models()}
        self.assertEqual(set(catalog['gw/broken']['probe']), {'ok', 'at'})
        self.assertNotIn('overloaded', json.dumps(catalog))
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
        revision = self.store.find('gw')['revision']
        self.assertEqual(self.store.secret('gw', revision), KEY)
        rekeyed = self.store.add({'id': 'gw', 'base_url': self.url, 'api_key': 'another-key-5678',
                                  'models': ['echo'], 'replace': True})
        self.assertIsNone(rekeyed['models'][0]['probe'])
        # A run configured from the old revision does not get the new key.
        with self.assertRaisesRegex(ValueError, '排队期间被修改'):
            self.store.secret('gw', revision)
        self.store.remove('gw')
        self.assertEqual(self.store.listing()['providers'], [])

    def test_a_saved_key_is_never_sent_to_a_new_origin(self):
        self.store.add({'id': 'gw', 'base_url': self.url, 'api_key': KEY, 'models': ['echo']})
        other, other_calls = fake_provider()
        self.addCleanup(other.server_close)
        self.addCleanup(other.shutdown)
        moved = f'http://127.0.0.1:{other.server_port}/v1'
        for models in ([], ['echo']):  # with discovery and without
            with self.subTest(models=models), self.assertRaisesRegex(ValueError, '重新填写 API Key'):
                self.store.add({'id': 'gw', 'base_url': moved, 'models': models, 'replace': True})
        self.assertEqual(other_calls, [])
        self.assertEqual(self.store.find('gw')['base_url'], self.url + '/v1')
        # Same origin, another protocol: the key stays and the revision moves.
        before = self.store.find('gw')['revision']
        self.store.add({'id': 'gw', 'base_url': self.url, 'protocol': 'openai_responses', 'models': ['echo'], 'replace': True})
        self.assertEqual(self.store.secret('gw', self.store.find('gw')['revision']), KEY)
        self.assertNotEqual(self.store.find('gw')['revision'], before)
        moved_entry = self.store.add({'id': 'gw', 'base_url': moved, 'api_key': 'new-key-for-new-host', 'models': ['echo'],
                                      'replace': True})
        self.assertEqual(moved_entry['base_url'], moved)

    def test_builtin_vendor_ids_import_under_an_internal_native_id_and_configured_ids_are_reserved(self):
        self.store.add({'id': 'openai', 'base_url': self.url, 'api_key': KEY, 'models': ['echo']})
        route = self.store.run_route('openai/echo')
        self.assertEqual(list(route['config']['custom_providers']), ['bench-openai'])
        with self.assertRaisesRegex(ValueError, '--provider-config'):
            self.store.add({'id': 'tokenjoy', 'base_url': self.url, 'api_key': KEY, 'models': ['echo']},
                           reserved={'tokenjoy'})

    def test_a_reply_off_by_whitespace_fails_and_shows_the_whitespace(self):
        self.store.add({'id': 'gw', 'base_url': self.url, 'api_key': KEY, 'models': ['spaced']})
        result = self.store.probe('gw', 'spaced')
        self.assertFalse(result['ok'])
        self.assertEqual(result['reply'], result['expected'] + ' ')
        out = cli.probe_line(result)
        self.assertIn(repr(result['expected'] + ' '), out)

    def test_a_probe_finished_during_a_same_route_update_is_kept(self):
        self.store.add({'id': 'gw', 'base_url': self.url, 'api_key': KEY, 'models': ['echo']})
        other = Providers(self.root)
        real_discover = Providers.discover

        def probing_discover(store, entry):
            other.probe('gw', 'echo')  # meanwhile, on the page
            return real_discover(store, entry)
        with patch.object(Providers, 'discover', probing_discover):
            updated = self.store.add({'id': 'gw', 'name': 'Renamed', 'base_url': self.url, 'replace': True})
        self.assertEqual(updated['name'], 'Renamed')
        self.assertTrue(self.store.find('gw')['probes']['echo']['ok'])

    def test_names_resolving_here_and_mapped_addresses_count_as_this_machine(self):
        from scripts.eval.harbor.bench import egress

        def resolve(host, *_args):
            table = {'devbox-alias': '127.0.1.1', 'v6-alias': '::ffff:127.0.0.1', 'gw.example': '203.0.113.7'}
            if host not in table:
                raise OSError('unknown host')
            return [(None, None, None, '', (table[host], 0))]
        for host in ('devbox-alias', 'v6-alias', '::ffff:127.0.0.1', '::ffff:0.0.0.0', '::', 'LOCALHOST.'):
            with self.subTest(host=host):
                self.assertTrue(egress.names_this_machine(host, resolve=resolve))
        for host in ('gw.example', 'unknown.example', '::ffff:203.0.113.7'):
            with self.subTest(host=host):
                self.assertFalse(egress.names_this_machine(host, resolve=resolve))
        with patch.object(egress, 'names_this_machine', partial(egress.names_this_machine, resolve=resolve)):
            self.assertTrue(providers.loopback('http://devbox-alias:8000/v1'))
            self.assertTrue(providers.loopback('http://[::ffff:127.0.0.1]:8000'))
            self.assertFalse(providers.loopback('https://gw.example/v1'))

    def test_each_upstream_connection_dials_only_an_address_it_just_checked(self):
        from scripts.eval.harbor.bench import egress
        answers = [['203.0.113.7'], ['127.0.0.1'], ['203.0.113.8', '::ffff:127.0.0.1'], OSError('no answer')]
        dialed = []

        def resolve(host, port, *_args):
            answer = answers.pop(0)
            if isinstance(answer, Exception):
                raise answer
            return [(egress.socket.AF_INET, egress.socket.SOCK_STREAM, 6, '', (ip, port)) for ip in answer]

        class Socket:
            def __init__(self, *_args):
                pass

            def settimeout(self, _timeout):
                pass

            def connect(self, sockaddr):
                dialed.append(sockaddr)

        with patch.object(egress.socket, 'socket', Socket):
            egress.connect_not_local(('gw.example', 80), 5, resolve=resolve)
            for _ in range(3):
                with self.assertRaises(egress.LocalUpstream):
                    egress.connect_not_local(('gw.example', 80), 5, resolve=resolve)
        self.assertEqual(dialed, [('203.0.113.7', 80)])

    def test_a_candidate_whose_socket_cannot_be_created_falls_through_to_the_next_checked_one(self):
        from scripts.eval.harbor.bench import egress
        AF_INET, AF_INET6 = egress.socket.AF_INET, egress.socket.AF_INET6
        dialed = []

        def resolve(host, port, *_args):
            return [(AF_INET6, egress.socket.SOCK_STREAM, 6, '', ('2001:db8::7', port, 0, 0)),
                    (AF_INET, egress.socket.SOCK_STREAM, 6, '', ('203.0.113.7', port))]

        class Socket:
            def __init__(self, family, *_args):
                if family == AF_INET6:
                    raise OSError(97, 'Address family not supported by protocol')

            def settimeout(self, _timeout):
                pass

            def connect(self, sockaddr):
                dialed.append(sockaddr)

        with patch.object(egress.socket, 'socket', Socket):
            egress.connect_not_local(('gw.example', 80), 5, resolve=resolve)
        self.assertEqual(dialed, [('203.0.113.7', 80)])

    def test_the_executor_refuses_an_imported_upstream_that_resolves_to_itself(self):
        from scripts.eval.harbor.bench import remote
        runtime = str(Path(__file__).resolve().parents[3])
        spec = {'argv': ['harbor', 'run'], 'key_env': providers.KEY_ENV, 'runtime': runtime,
                'relay': {'upstream': 'http://127.0.0.1:9', 'bind': '127.0.0.1', 'auth_header': 'Authorization',
                          'auth_prefix': 'Bearer ', 'metrics_dir': str(self.root / 'metrics'), 'record': False,
                          'refuse_local_upstream': True}}
        spec_path = self.root / 'spec.json'
        spec_path.parent.mkdir(parents=True, exist_ok=True)
        spec_path.write_text(json.dumps(spec))
        line = json.dumps({'env': {providers.KEY_ENV: 'mcb-placeholder'}, 'credential': KEY}) + '\n'
        out = io.StringIO()
        stdin = io.TextIOWrapper(io.BytesIO(line.encode()))
        with patch.object(remote.os, 'chdir'), patch('sys.stdin', stdin), redirect_stdout(out), \
                patch('scripts.eval.harbor.profiling.TimingRelay') as relay:
            self.assertEqual(remote.run(str(spec_path)), 2)
        relay.assert_not_called()
        events = [json.loads(x) for x in out.getvalue().splitlines()]
        self.assertTrue(any(e['event'] == 'error' and '本机' in e['message'] for e in events), events)

    def test_loopback_addresses_are_recognized(self):
        for url in ('http://127.0.0.1:8000/v1', 'http://localhost:11434', 'http://[::1]:8000', 'http://0.0.0.0:1',
                    'http://127.1.2.3', 'http://api.localhost'):
            with self.subTest(url=url):
                self.assertTrue(providers.loopback(url))
        for url in ('https://api.example.com/v1', 'http://10.0.0.2:8000', 'http://192.168.1.5'):
            with self.subTest(url=url):
                self.assertFalse(providers.loopback(url))

    def test_a_concurrent_update_cannot_restore_a_rotated_key(self):
        self.store.add({'id': 'gw', 'base_url': self.url, 'api_key': KEY, 'models': ['echo']})
        other = Providers(self.root)  # the CLI, in another process
        real_discover = Providers.discover

        def slow_discover(store, entry):
            # While the page's update discovers models, the CLI rotates the key.
            other.add({'id': 'gw', 'base_url': self.url, 'api_key': 'rotated-key-9999', 'models': ['echo'],
                       'replace': True})
            return real_discover(store, entry)
        with patch.object(Providers, 'discover', slow_discover):
            with self.assertRaisesRegex(ValueError, '其他请求修改'):
                self.store.add({'id': 'gw', 'name': 'Renamed', 'base_url': self.url, 'replace': True})
        current = self.store.find('gw')
        self.assertEqual(current['api_key'], 'rotated-key-9999')
        self.assertEqual(self.store.secret('gw', current['revision']), 'rotated-key-9999')

    def test_entries_saved_before_revisions_get_one_once(self):
        self.store.save([{'id': 'old', 'name': 'old', 'base_url': self.url + '/v1', 'protocol': 'openai_chat',
                          'auth': 'bearer', 'api_key': KEY, 'models': ['echo']}])
        route = self.store.run_route('old/echo')
        self.assertTrue(route['revision'])
        self.assertEqual(self.store.run_route('old/echo')['revision'], route['revision'])
        self.assertEqual(self.store.secret('old', route['revision']), KEY)

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
        route = self.store.run_route('claude/m')
        path = providers.write_config(self.root / 'run.provider', route['config'])
        spec = {'auth_mode': 'provider', 'provider_config': path, 'model': route['model']}
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
        offline_hugging_face(self)
        self.env = patch.dict(os.environ, {'PATH': str(binary_dir) + os.pathsep + os.environ.get('PATH', ''),
                                          'TOKENJOY_API_KEY': 'private-test-value'})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.upstream, self.calls = fake_provider()
        self.addCleanup(self.upstream.server_close)
        self.addCleanup(self.upstream.shutdown)
        self.manager = RunManager(self.root / 'jobs', config)
        self.http = server.make_server(Workbench(data.Library([self.manager.jobs_dir]), self.manager),
                                       '127.0.0.1', 0)
        threading.Thread(target=self.http.serve_forever, daemon=True).start()
        self.addCleanup(self.http.server_close)
        self.addCleanup(self.http.shutdown)
        self.client = cli.Client(f'http://127.0.0.1:{self.http.server_address[1]}/')

    def test_imported_model_runs_with_only_a_placeholder_and_the_relay_sends_the_key(self):
        added = self.client.request('api/providers', {
            'id': 'local', 'name': 'Local', 'base_url': f'http://127.0.0.1:{self.upstream.server_port}',
            'api_key': KEY, 'protocol': 'anthropic_messages', 'auth': 'bearer', 'models': ['echo'], 'probe': True})
        self.assertTrue(added['probe']['ok'], added)
        self.assertNotIn(KEY, json.dumps(added))
        listing = self.client.request('api/providers')
        self.assertEqual(listing['providers'][0]['id'], 'local')
        self.assertNotIn(KEY, json.dumps(listing))
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
        # Harbor runs the internal native id; the run record keeps the catalog id.
        self.assertEqual(argv[argv.index('-m') + 1], 'bench-local/echo')
        self.assertEqual(final['model'], 'local/echo')
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

    def test_an_edit_after_launch_is_never_paired_with_the_old_route(self):
        from scripts.eval.harbor.bench import credentials
        base = f'http://127.0.0.1:{self.upstream.server_port}'
        self.client.request('api/providers', {'id': 'local', 'base_url': base, 'api_key': KEY, 'models': ['echo']})
        route = self.manager.providers.run_route('local/echo')
        spec = {'auth_mode': 'provider', 'imported_provider': 'local', 'imported_revision': route['revision'],
                'providers_root': str(self.manager.providers.root), 'key_env': providers.KEY_ENV}
        self.assertEqual(credentials.for_run(spec, {})[0].current(), KEY)
        # Same id moved to another gateway with another key while queued.
        self.client.request('api/providers', {'id': 'local', 'base_url': 'http://127.0.0.2:9', 'api_key': 'other-key-0000',
                                              'models': ['echo'], 'replace': True})
        with self.assertRaisesRegex(ValueError, '排队期间被修改'):
            credentials.for_run(spec, {})

    def test_provider_config_ids_cannot_be_imported_and_a_later_clash_is_hidden(self):
        base = f'http://127.0.0.1:{self.upstream.server_port}'
        with self.assertRaisesRegex(ValueError, '--provider-config'):
            self.client.request('api/providers', {'id': 'tokenjoy', 'base_url': base, 'api_key': KEY,
                                                  'models': ['test-model', 'echo']})
        # A clash that appears afterwards (the store written before the
        # --provider-config changed) never routes the id to the import.
        self.manager.providers.add({'id': 'tokenjoy', 'base_url': base, 'api_key': KEY, 'models': ['test-model', 'echo']})
        catalog = self.client.request('api/workbench')
        ids = [m['id'] for m in catalog['models']]
        self.assertEqual(ids.count('tokenjoy/test-model'), 1)
        self.assertNotIn('tokenjoy/echo', ids)
        self.assertTrue(any('冲突' in w for w in catalog['warnings']), catalog['warnings'])
        run = self.client.request('api/runs', {'model': 'tokenjoy/test-model', 'tasks': ['fix-git']})
        spec = json.loads((self.manager.records / (run['name'] + '.spec')).read_text())
        self.assertNotIn('imported_provider', spec)
        self.assertEqual(spec['provider_config'], json.loads(self.manager.config_path.read_text())['provider_config'])
        wait_run(self.manager, run['name'])

    def test_a_batch_never_switches_an_items_route_after_creation(self):
        base = f'http://127.0.0.1:{self.upstream.server_port}'
        self.client.request('api/providers', {'id': 'local', 'base_url': base, 'api_key': KEY, 'models': ['echo']})
        created = self.client.request('api/batches', {
            'model': 'local/echo', 'attempts': 1, 'concurrency': 1,
            'items': [{'suite': 'terminal-bench-2.1', 'tasks': ['fix-git']},
                      {'suite': 'terminal-bench-2.0', 'tasks': ['fix-git']}]})
        self.assertNotIn('route', json.dumps(created['items']))  # internal, like the launch request
        stored = self.manager.batches.get(created['id'])
        self.assertEqual(stored['items'][0]['route']['source'], 'imported')
        with patch.dict(os.environ, {'FAKE_BENCH_DELAY': '2'}):
            self.manager.batches.advance()  # first item starts on the original route
            first = self.manager.batches.get(created['id'])['items'][0]
            self.assertEqual(first['status'], 'running')
            # Its worker has taken the key (Harbor is running) before the edit.
            from scripts.eval.tests.test_bench_workbench import wait_status
            self.assertEqual(wait_status(self.manager, first['run'], 'running'), 'running')
            # The same id moves to another key before the second item.
            self.client.request('api/providers', {'id': 'local', 'base_url': base, 'api_key': 'rotated-key-0000',
                                                  'models': ['echo'], 'replace': True})
            deadline = time.monotonic() + 30
            while self.manager.batches.get(created['id'])['status'] not in ('finished', 'cancelled') \
                    and time.monotonic() < deadline:
                self.manager.batches.advance()
                time.sleep(.1)
        record = self.manager.batches.get(created['id'])
        self.assertEqual(record['items'][0]['status'], 'finished')
        self.assertEqual(record['items'][1]['status'], 'failed')
        self.assertIn('批次创建后', record['items'][1]['error'])
        self.assertEqual(len(self.manager.runs()), 1)

    def test_a_loopback_import_is_refused_on_an_ssh_executor(self):
        from scripts.eval.harbor.bench import executors
        base = f'http://127.0.0.1:{self.upstream.server_port}'
        self.client.request('api/providers', {'id': 'local', 'base_url': base, 'api_key': KEY, 'models': ['echo']})
        cfg = json.loads(self.manager.config_path.read_text())
        cfg['executors'] = [{'name': 'local', 'kind': 'local'}, {'name': 'gpu', 'kind': 'ssh', 'host': 'gpu.example'}]
        atomic_json(self.manager.config_path, cfg)
        with patch.object(executors, 'probe', return_value={}), patch.object(executors, 'reasons', return_value=[]), \
                patch.object(executors, 'workbench_harbor', return_value='/usr/bin/harbor'):
            request = {'model': 'local/echo', 'tasks': ['fix-git']}
            self.assertEqual(self.manager.launch({**request, 'executor': 'local'}, dry_run=True)['executor'], 'local')
            with self.assertRaisesRegex(ValueError, '回环地址'):
                self.manager.launch({**request, 'executor': 'gpu'}, dry_run=True)
            with self.assertRaisesRegex(ValueError, '回环地址'):
                self.client.request('api/batches', {'model': 'local/echo', 'executor': 'gpu', 'attempts': 1,
                                                    'concurrency': 1,
                                                    'items': [{'suite': 'terminal-bench-2.1', 'tasks': ['fix-git']}]})
        self.assertEqual(self.manager.runs(), [])

    def test_the_final_route_snapshot_is_checked_against_the_ssh_executor(self):
        from scripts.eval.harbor.bench import egress, executors
        self.client.request('api/providers', {'id': 'gw', 'base_url': 'http://gw.example:9', 'api_key': KEY,
                                              'models': ['echo']})
        cfg = json.loads(self.manager.config_path.read_text())
        cfg['executors'] = [{'name': 'gpu', 'kind': 'ssh', 'host': 'gpu.example'}]
        atomic_json(self.manager.config_path, cfg)
        real_route = Providers.run_route
        calls = []

        def moved_to_loopback_after_validation(store, model_id):
            calls.append(model_id)
            if len(calls) == 3:  # validation passed; a direct launch has no pin
                store.add({'id': 'gw', 'base_url': 'http://devbox-alias:9', 'api_key': 'other-key-2222',
                           'models': ['echo'], 'replace': True})
            return real_route(store, model_id)

        def resolve(host, *_args):
            if host == 'devbox-alias':
                return [(None, None, None, '', ('127.0.0.1', 0))]
            raise OSError('unknown host')
        with patch.object(executors, 'probe', return_value={}), patch.object(executors, 'reasons', return_value=[]), \
                patch.object(executors, 'workbench_harbor', return_value='/usr/bin/harbor'), \
                patch.object(egress, 'names_this_machine', partial(egress.names_this_machine, resolve=resolve)), \
                patch.object(Providers, 'run_route', moved_to_loopback_after_validation):
            with self.assertRaisesRegex(ValueError, '工作台本机'):
                self.manager.launch({'model': 'gw/echo', 'tasks': ['fix-git']})
        self.assertEqual(len(calls), 3)
        self.assertEqual(self.manager.runs(), [])
        self.assertEqual(list(self.manager.records.glob('*')) if self.manager.records.exists() else [], [])

    def test_a_refused_launch_leaves_no_queued_receipt(self):
        base = f'http://127.0.0.1:{self.upstream.server_port}'
        self.client.request('api/providers', {'id': 'local', 'base_url': base, 'api_key': KEY, 'models': ['echo']})
        request = {'model': 'local/echo', 'tasks': ['fix-git']}
        pinned = self.manager.launch(request, dry_run=True)['route']
        real_route = Providers.run_route
        calls = []

        def edited_between_checks(store, model_id):
            calls.append(model_id)
            if len(calls) == 3:  # after validation, before the receipt
                store.add({'id': 'local', 'base_url': base, 'api_key': 'rotated-key-1111', 'models': ['echo'],
                           'replace': True})
            return real_route(store, model_id)
        with patch.object(Providers, 'run_route', edited_between_checks):
            with self.assertRaisesRegex(ValueError, '批次创建后'):
                self.manager.launch(request, pinned=pinned)
        self.assertEqual(self.manager.runs(), [])
        self.assertEqual(list(self.manager.records.glob('*')) if self.manager.records.exists() else [], [])

    def test_a_pinned_launch_refuses_another_source(self):
        base = f'http://127.0.0.1:{self.upstream.server_port}'
        self.client.request('api/providers', {'id': 'local', 'base_url': base, 'api_key': KEY, 'models': ['test-model']})
        request = {'model': 'local/test-model', 'tasks': ['fix-git']}
        pinned = self.manager.launch(request, dry_run=True)['route']
        self.client.request('api/providers/remove', {'id': 'local'})
        with self.assertRaises(ValueError):
            self.manager.launch(request, pinned=pinned)
        # A configured model pinned as such stays launchable; pinned to an
        # import, it is refused.
        configured = self.manager.launch({'model': 'tokenjoy/test-model', 'tasks': ['fix-git']}, dry_run=True)['route']
        self.assertEqual(configured, {'source': 'provider'})
        with self.assertRaisesRegex(ValueError, '批次创建后'):
            self.manager.launch({'model': 'tokenjoy/test-model', 'tasks': ['fix-git']}, pinned=pinned)
        self.assertEqual(self.manager.runs(), [])

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
