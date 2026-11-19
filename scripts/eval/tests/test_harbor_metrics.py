"""Metric math and an actual streaming HTTP relay; no paid providers."""
from __future__ import annotations

import json
import socket
import ssl
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from scripts.eval.harbor.profiling import StreamMetrics, TimingRelay, routed_config, usage_values
from scripts.eval.harbor.viewer import data, server
from scripts.eval.tests.test_harbor_viewer import _job, _trial, _write


def sse(value):
    return b'data: ' + json.dumps(value).encode() + b'\n\n'


class StreamTest(unittest.TestCase):
    def test_invalid_usage_never_fabricates_token_counts(self):
        for value in (True, -1, float('nan'), float('inf'), 1.5, 1 << 10000):
            self.assertEqual(usage_values({'input_tokens': value, 'output_tokens': value}), {})
        self.assertEqual(usage_values({'input_tokens': 14.0})['input_tokens'], 14)

    def test_anthropic_cache_and_tool_first_token_ignore_pings_and_metadata(self):
        at = [0.0]
        metrics = StreamMetrics(lambda: at[0])
        at[0] = .1
        metrics.feed(sse({'type': 'ping'}))
        at[0] = .2
        metrics.feed(sse({'type': 'message_start', 'message': {'usage': {
            'input_tokens': 10, 'cache_read_input_tokens': 20, 'cache_creation_input_tokens': 5}}}))
        self.assertIsNone(metrics.first)
        at[0] = .5
        metrics.feed(sse({'type': 'content_block_start', 'content_block': {'type': 'tool_use', 'name': 'Bash'}}))
        at[0] = 1.5
        metrics.feed(sse({'type': 'message_delta', 'usage': {'output_tokens': 100}}))
        metrics.feed(sse({'type': 'message_stop'}))
        at[0] = 2.0
        result = metrics.finish(200, True)
        self.assertEqual((result['input_tokens'], result['output_tokens']), (35, 100))
        self.assertEqual((result['ttft_ms'], result['generation_ms']), (500, 1500))
        self.assertTrue(result['complete'])

    def test_openai_and_responses_usage_do_not_double_count_cache(self):
        self.assertEqual(usage_values({'prompt_tokens': 100, 'completion_tokens': 20,
                                      'prompt_tokens_details': {'cached_tokens': 90}})['input_tokens'], 100)
        self.assertEqual(usage_values({'input_tokens': 100, 'output_tokens': 20,
                                      'input_tokens_details': {'cached_tokens': 90}})['input_tokens'], 100)
        for first, final in [
            ({'choices': [{'delta': {'reasoning_content': 'thinking'}}]},
             {'choices': [{'finish_reason': 'stop'}], 'usage': {'prompt_tokens': 100, 'completion_tokens': 20}}),
            ({'type': 'response.function_call_arguments.delta', 'delta': '{'},
             {'type': 'response.completed', 'response': {'usage': {'input_tokens': 100, 'output_tokens': 20}}}),
        ]:
            now = [0.0]
            metrics = StreamMetrics(lambda: now[0])
            now[0] = .25
            metrics.feed(sse(first)[:7])
            metrics.feed(sse(first)[7:])
            now[0] = 1
            metrics.feed(sse(final))
            result = metrics.finish(200, True)
            self.assertEqual(result['ttft_ms'], 250)
            self.assertEqual(result['output_tokens'], 20)
            self.assertTrue(result['complete'])

    def test_truncated_and_error_streams_do_not_become_successful_samples(self):
        metrics = StreamMetrics()
        metrics.feed(sse({'choices': [{'delta': {'content': 'partial'}}]}))
        self.assertFalse(metrics.finish(200, True)['complete'])
        metrics.feed(sse({'type': 'error', 'error': {'message': 'failed'}}))
        metrics.feed(b'data: [DONE]\n\n')
        self.assertFalse(metrics.finish(200, True)['complete'])


class RelayTest(unittest.TestCase):
    def test_idle_tls_connection_does_not_block_other_trials_or_shutdown(self):
        with tempfile.TemporaryDirectory() as temp:
            relay = TimingRelay('http://127.0.0.1:1', 'test-key', temp, bind='127.0.0.1', tls=True)
            with relay:
                with socket.create_connection(relay.server.server_address, timeout=3) as idle:
                    context = ssl.create_default_context(cafile=str(relay.ca_path))
                    with self.assertRaises(urllib.error.HTTPError) as caught:
                        urllib.request.urlopen(relay.url + '/missing', context=context, timeout=3)
                    self.assertEqual(caught.exception.code, 404)
                    caught.exception.close()
                    # Leave the idle peer connected while shutting down.
                    relay.server.shutdown()
                    idle.shutdown(socket.SHUT_RDWR)

    def test_real_stream_is_preserved_and_numeric_sidecar_has_no_secrets(self):
        chunks = [sse({'type': 'ping'}), sse({'type': 'message_start', 'message': {'usage': {'input_tokens': 50}}}),
                  sse({'type': 'content_block_delta', 'delta': {'text': 'private-output'}}),
                  sse({'type': 'message_delta', 'usage': {'output_tokens': 20}}), sse({'type': 'message_stop'})]
        seen = []

        class Provider(BaseHTTPRequestHandler):
            def do_POST(self):
                seen.append((self.path, self.headers['Authorization'], self.rfile.read(int(self.headers['Content-Length']))))
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.send_header('Content-Length', str(sum(map(len, chunks))))
                self.end_headers()
                for chunk in chunks:
                    time.sleep(.02)
                    self.wfile.write(chunk)
                    self.wfile.flush()

            def log_message(self, *_args):
                pass

        upstream = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
        threading.Thread(target=upstream.serve_forever, daemon=True).start()
        self.addCleanup(upstream.server_close)
        self.addCleanup(upstream.shutdown)
        with tempfile.TemporaryDirectory() as temp, TimingRelay(
                f'http://127.0.0.1:{upstream.server_port}', 'private-key', temp, bind='127.0.0.1') as relay:
            # The container presents only the relay's placeholder.
            self.assertTrue(relay.token.startswith('mcb-'))
            request = urllib.request.Request(relay.url + '/task__one/v1/messages', data=b'{"private":"input"}',
                                             headers={'Authorization': 'Bearer ' + relay.token, 'Content-Type': 'application/json'})
            with urllib.request.urlopen(request, timeout=5) as response:
                self.assertEqual(response.read(), b''.join(chunks))
            deadline = time.monotonic() + 2
            path = Path(temp) / 'task__one.jsonl'
            while True:
                try:
                    metric = json.loads(path.read_text())
                    break
                except (OSError, ValueError):
                    if time.monotonic() >= deadline:
                        raise
                    time.sleep(.01)
            self.assertTrue(metric['complete'])
            self.assertGreater(metric['ttft_ms'], 30)
            self.assertLess(metric['ttft_ms'], metric['duration_ms'])
            self.assertEqual((metric['input_tokens'], metric['output_tokens']), (50, 20))
            self.assertEqual(seen, [('/v1/messages', 'Bearer private-key', b'{"private":"input"}')])
            text = path.read_text()
            for secret in ('private-key', 'private-output', '"private"', relay.token):
                self.assertNotIn(secret, text)
            # No header, the real key itself, or a wrong placeholder: refused
            # by the relay, never forwarded.
            for headers in ({}, {'Authorization': 'Bearer private-key'},
                            {'Authorization': 'Bearer mcb-other-' + 'x' * 43}):
                with self.assertRaises(urllib.error.HTTPError) as caught:
                    urllib.request.urlopen(urllib.request.Request(relay.url + '/task__one/v1/messages', data=b'{}',
                                                                  headers=headers))
                self.assertEqual(caught.exception.code, 401)
                caught.exception.close()
            self.assertEqual(len(seen), 1)

    def test_custom_header_route_replaces_the_placeholder_and_metrics_off_still_proxies(self):
        seen = []

        class Provider(BaseHTTPRequestHandler):
            def do_POST(self):
                self.rfile.read(int(self.headers['Content-Length']))
                seen.append((self.headers.get('x-api-key'), self.headers.get('Authorization')))
                body = sse({'type': 'message_stop'})
                self.send_response(200)
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *_args):
                pass

        upstream = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
        threading.Thread(target=upstream.serve_forever, daemon=True).start()
        self.addCleanup(upstream.server_close)
        self.addCleanup(upstream.shutdown)
        with tempfile.TemporaryDirectory() as temp, TimingRelay(
                f'http://127.0.0.1:{upstream.server_port}', 'real-provider-key', Path(temp) / 'metrics',
                bind='127.0.0.1', auth_header='x-api-key', auth_prefix='', token='mcb-run-placeholder',
                record=False) as relay:
            request = urllib.request.Request(relay.url + '/task__one/v1/messages', data=b'{}',
                                             headers={'x-api-key': 'mcb-run-placeholder'})
            with urllib.request.urlopen(request, timeout=5) as response:
                response.read()
            self.assertEqual(seen, [('real-provider-key', None)])
            self.assertFalse((Path(temp) / 'metrics').exists())

    def test_judge_placeholder_reaches_only_chat_completions_on_its_route(self):
        seen = []

        class Gateway(BaseHTTPRequestHandler):
            def do_POST(self):
                seen.append((self.path, self.headers['Authorization'],
                             json.loads(self.rfile.read(int(self.headers['Content-Length'])))))
                body = json.dumps({'choices': [{'message': {'content': 'yes'}}]}).encode()
                self.send_response(200)
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *_args):
                pass

        upstream = ThreadingHTTPServer(('127.0.0.1', 0), Gateway)
        threading.Thread(target=upstream.serve_forever, daemon=True).start()
        self.addCleanup(upstream.server_close)
        self.addCleanup(upstream.shutdown)
        with self.assertRaises(ValueError):
            TimingRelay('http://127.0.0.1:1', 'k', '/nonexistent', bind='127.0.0.1', token='mcb-same',
                        judge_token='mcb-same')
        with tempfile.TemporaryDirectory() as temp, TimingRelay(
                f'http://127.0.0.1:{upstream.server_port}', 'agent-key', temp, bind='127.0.0.1',
                token='mcb-agent', judge_token='mcb-judge', judge_credential='judge-group-key') as relay:
            def post(path, token):
                request = urllib.request.Request(relay.url + path, data=b'{"model":"glm-5.3-flash"}',
                                                 headers={'Authorization': 'Bearer ' + token})
                try:
                    with urllib.request.urlopen(request, timeout=5) as response:
                        response.read()
                        return response.status
                except urllib.error.HTTPError as exc:
                    exc.close()
                    return exc.code
            self.assertEqual(post('/bench-judge/v1/chat/completions', 'mcb-judge'), 200)
            # The judge's token is for its route and endpoint only; the
            # agent's token never reaches the judge route.
            self.assertEqual(post('/bench-judge/v1/messages', 'mcb-judge'), 403)
            self.assertEqual(post('/task__one/v1/chat/completions', 'mcb-judge'), 403)
            self.assertEqual(post('/bench-judge/v1/chat/completions', 'mcb-agent'), 403)
            self.assertEqual(post('/bench-judge/v1/chat/completions', 'judge-group-key'), 401)
            self.assertEqual(post('/task__one/v1/chat/completions', 'mcb-agent'), 200)
            self.assertEqual(seen, [('/v1/chat/completions', 'Bearer judge-group-key', {'model': 'glm-5.3-flash'}),
                                    ('/v1/chat/completions', 'Bearer agent-key', {'model': 'glm-5.3-flash'})])
            # Only the agent's request is a metric sample.
            time.sleep(.1)
            self.assertEqual(sorted(p.name for p in Path(temp).iterdir()), ['task__one.jsonl'])


class RouteTest(unittest.TestCase):
    def test_only_routes_the_relay_can_forward_are_launchable(self):
        from scripts.eval.harbor.profiling import route_problem, upstream_for
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'provider.json'

            def problem(provider):
                path.write_text(json.dumps({'custom_providers': {'p': provider}}))
                return route_problem({'auth_mode': 'provider', 'model': 'p/m', 'provider_config': str(path)})

            good = {'channels': [{'id': 'a', 'protocol': 'openai_chat', 'base_url': 'https://h.example/v1'}]}
            self.assertIsNone(problem(good))
            self.assertEqual(upstream_for({'auth_mode': 'provider', 'model': 'p/m', 'provider_config': str(path)}),
                             'https://h.example/v1')
            self.assertIn('channels', problem({}))
            self.assertIn('base_url', problem({'channels': [{'protocol': 'openai_chat', 'base_url': 'https://h.example/api/v4'}]}))
            self.assertIn('协议', problem({'channels': [{'protocol': 'gemini', 'base_url': 'https://h.example'}]}))
            self.assertIn('认证', problem({**good, 'auth': {'kind': 'oauth'}}))
            self.assertIn('不同的主机', problem({'channels': good['channels'] + [
                {'protocol': 'openai_chat', 'base_url': 'https://other.example'}]}))
            self.assertIn('provider-config', route_problem({'auth_mode': 'provider', 'model': 'p/m'}))
            self.assertIsNone(route_problem({'auth_mode': 'metask', 'model': 'metask/x'}))

    def test_route_rewrite_preserves_model_protocol_and_original_configuration(self):
        original = {'custom_providers': {'p': {'channels': [{'protocol': 'openai_responses', 'base_url': 'https://provider.example/v1'}]}}}
        changed = routed_config(original, 'p', 'http://172.17.0.1:1234', 'task__one')
        channel = changed['custom_providers']['p']['channels'][0]
        self.assertEqual(channel['base_url'], 'http://172.17.0.1:1234/task__one/v1')
        self.assertEqual(channel['protocol'], 'openai_responses')
        self.assertEqual(original['custom_providers']['p']['channels'][0]['base_url'], 'https://provider.example/v1')


class MetricProjectionTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.job = _job(self.root, 'metrics-job', 'metask/model', 2)

    def test_first_attempt_does_not_count_later_full_score(self):
        first = _trial(self.job, 'same__first', reward=0)
        second = _trial(self.job, 'same__second', reward=1)
        doc = data.read_json(second / 'result.json')
        doc['started_at'] = '2026-11-16T09:00:00Z'
        _write(second / 'result.json', doc)
        _trial(self.job, 'other__one', reward=1)
        _trial(self.job, 'infra__one', exception='VerifierTimeoutError')
        view = data.job_view(self.job)
        s = view['summary']
        self.assertEqual((s['first_passed'], s['first_valid'], s['first_invalid']), (1, 2, 1))
        self.assertEqual(s['first_pass_rate'], .5)
        self.assertAlmostEqual(s['pass_rate'], 2 / 3)
        self.assertAlmostEqual(s['one_shot_pass_rate'], 2 / 3)
        rows = {r['trial']: r for r in view['rows']}
        self.assertTrue(rows[first.name]['first_attempt'])
        self.assertFalse(rows[second.name]['first_attempt'])

    def test_usage_initial_input_weighted_tps_and_ttft_reach_http_and_csv(self):
        trial = _trial(self.job, 'one__aaa', reward=1)
        document = data.read_json(trial / 'result.json')
        document['agent_result'].update(n_input_tokens=1920, n_output_tokens=100)
        _write(trial / 'result.json', document)
        _write(trial / 'agent/metacodes-output.jsonl', '\n'.join(json.dumps(v) for v in [
            {'type': 'usage', 'input_tokens': 100, 'cache_read_input_tokens': 800, 'cache_creation_input_tokens': 20, 'output_tokens': 10},
            {'type': 'result', 'stop_reason': 'end_turn', 'text': 'done'}]))
        _write(self.job / '.bench-metrics/one__aaa.jsonl', '\n'.join(json.dumps(v) for v in [
            {'request': 1, 'complete': True, 'input_tokens': 920, 'output_tokens': 10, 'ttft_ms': 100, 'generation_ms': 1000},
            {'request': 2, 'complete': True, 'input_tokens': 1000, 'output_tokens': 90, 'ttft_ms': 300, 'generation_ms': 3000}]))
        view = data.job_view(self.job)
        row, summary = view['rows'][0], view['summary']
        self.assertEqual(row['total_tokens'], 2020)
        self.assertEqual(row['initial_input_tokens'], 920)
        self.assertEqual(row['tps'], 25)  # 100 / 4, not mean(10/1, 90/3)
        self.assertEqual(row['ttft_ms'], 200)
        self.assertEqual(row['ttft_p95_ms'], 290)
        self.assertEqual(summary['initial_input_tokens_mean'], 920)
        self.assertIn('initial_input_tokens', data.job_csv(view).splitlines()[0])
        http = server.make_server(data.Library([self.root]), '127.0.0.1', 0)
        threading.Thread(target=http.serve_forever, daemon=True).start()
        self.addCleanup(http.server_close)
        self.addCleanup(http.shutdown)
        with urllib.request.urlopen(f'http://127.0.0.1:{http.server_port}/api/jobs') as response:
            result = json.load(response)
        self.assertEqual(result['summary']['tps'], 25)
        self.assertEqual(result['storage']['jobs_dirs'], [str(self.root.resolve())])

    def test_historical_usage_is_recovered_but_missing_timing_stays_unknown(self):
        trial = _trial(self.job, 'old__aaa', reward=1)
        path = trial / 'agent/metacodes-output.jsonl'
        text = path.read_text()
        path.write_text(json.dumps({'type': 'usage', 'input_tokens': 100, 'cache_read_input_tokens': 800,
                                    'cache_creation_input_tokens': 20, 'output_tokens': 10}) + '\n' + text)
        row = data.trial_row(trial)
        self.assertEqual(row['initial_input_tokens'], 920)
        self.assertIsNone(row['ttft_ms'])
        self.assertIsNone(row['tps'])
        self.assertEqual(row['requests'], 0)

    def test_global_metrics_pool_requests_without_deduplicating_tasks_between_jobs(self):
        _trial(self.job, 'same__first', reward=1)
        _write(self.job / '.bench-metrics/same__first.jsonl', json.dumps(
            {'request': 1, 'complete': True, 'output_tokens': 10, 'ttft_ms': 100, 'generation_ms': 1000}))
        other = _job(self.root, 'other-model', 'other/model', 1)
        _trial(other, 'same__second', reward=1)
        _write(other / '.bench-metrics/same__second.jsonl', '\n'.join(json.dumps(v) for v in [
            {'request': 1, 'complete': True, 'output_tokens': 30, 'ttft_ms': 300, 'generation_ms': 3000},
            {'request': 2, 'complete': True, 'output_tokens': 60, 'ttft_ms': 500, 'generation_ms': 1000}]))
        summary = data.merge_summaries([data.job_view(self.job)['summary'], data.job_view(other)['summary']])
        self.assertEqual(summary['first_valid'], 2)
        self.assertEqual(summary['tps'], 20)  # 100 tokens / 5 seconds
        self.assertEqual(summary['ttft_ms'], 300)

    def test_first_attempt_order_compares_timestamp_offsets_as_instants(self):
        _trial(self.job, 'same__a', reward=1)
        b = _trial(self.job, 'same__b', reward=0)
        document = data.read_json(b / 'result.json')
        document['started_at'] = '2026-11-16T09:00:00+02:00'  # 07:00 UTC, before a
        _write(b / 'result.json', document)
        self.assertEqual(data.job_view(self.job)['summary']['first_pass_rate'], 0)

    def test_killed_trial_preserves_partial_usage_instead_of_fabricated_zero(self):
        trial = _trial(self.job, 'killed__aaa', reward=0)
        _write(trial / 'agent/metacodes-output.jsonl', json.dumps({'type': 'usage', 'input_tokens': 100,
                'cache_read_input_tokens': 800, 'output_tokens': 20}))
        row = data.trial_row(trial)
        self.assertTrue(row['tokens_partial'])
        self.assertEqual(row['total_tokens'], 920)


if __name__ == '__main__':
    unittest.main()
