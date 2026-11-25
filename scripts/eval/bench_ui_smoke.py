#!/usr/bin/env python3
"""Optional browser smoke (Playwright): submit one fake trial in the real UI.

    python3 scripts/eval/bench_ui_smoke.py --screenshot /tmp/bench-workbench.png

Uses an isolated temporary jobs directory and the same fake Harbor as the
HTTP contract tests. No real model requests, Docker tasks or user browser.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
import threading
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from scripts.eval.harbor.bench import data  # noqa: E402
from scripts.eval.harbor.bench.workbench import Workbench  # noqa: E402
from scripts.eval.harbor.viewer import server  # noqa: E402
from scripts.eval.harbor.bench.runner import RunManager  # noqa: E402
from scripts.eval.harbor.adapters import gaia2_cli  # noqa: E402
from scripts.eval.tests.test_bench_workbench import fixture, wait_run  # noqa: E402
from scripts.eval.tests.test_harbor_viewer import _job  # noqa: E402


def main():
    from playwright.sync_api import sync_playwright
    parser = argparse.ArgumentParser()
    parser.add_argument('--screenshot', type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='bench-ui-') as temp:
        root = Path(temp)
        config, binary_dir = fixture(root)
        manager = RunManager(root / 'jobs', config)
        with patch.dict(os.environ, {'PATH': str(binary_dir) + os.pathsep + os.environ.get('PATH', ''),
                                     'TOKENJOY_API_KEY': 'private-ui-fixture'}), patch.object(gaia2_cli, 'cached_hf_problem', return_value=None):
            http = server.make_server(Workbench(data.Library([manager.jobs_dir]), manager), '127.0.0.1', 0)
            threading.Thread(target=http.serve_forever, daemon=True).start()
            try:
                with sync_playwright() as playwright:
                    browser = playwright.chromium.launch(headless=True)
                    page = browser.new_page(viewport={'width': 1440, 'height': 1100})
                    errors = []
                    page.on('pageerror', lambda error: errors.append(str(error)))
                    page.goto(f'http://127.0.0.1:{http.server_address[1]}/#/new')
                    page.get_by_role('button', name='清空', exact=True).click()
                    page.get_by_role('checkbox', name='fix-git', exact=True).check()
                    page.locator('[name=attempts]').fill('1')
                    page.locator('.form-submit button').click()
                    page.wait_for_url('**/#/profile/*')
                    profile = page.url.split('/profile/')[1]
                    page.wait_for_function("fetch('/api/profile?id=' + location.hash.split('/')[2]).then(r => r.json()).then(p => p.items[0].run)")
                    name = manager.profiles.get(profile)['items'][0]['run']
                    assert wait_run(manager, name)['status'] == 'finished'
                    job = manager.jobs_dir / name
                    trial = job / 'fix-git__fake'
                    result = json.loads((trial / 'result.json').read_text())
                    result['agent_result'] = {'n_input_tokens': 1920, 'n_output_tokens': 100, 'cost_usd': .01}
                    (trial / 'result.json').write_text(json.dumps(result))
                    (trial / 'agent').mkdir()
                    (trial / 'agent/metacodes-output.jsonl').write_text(json.dumps(
                        {'type': 'result', 'stop_reason': 'end_turn', 'text': 'done'}))
                    (job / '.bench-metrics').mkdir()
                    (job / '.bench-metrics/fix-git__fake.jsonl').write_text('\n'.join(json.dumps(r) for r in [
                        {'request': 1, 'complete': True, 'input_tokens': 920, 'output_tokens': 10, 'ttft_ms': 100, 'generation_ms': 1000},
                        {'request': 2, 'complete': True, 'input_tokens': 1000, 'output_tokens': 90, 'ttft_ms': 300, 'generation_ms': 3000}]))
                    http.workbench.library.sync()
                    page.goto(f'http://127.0.0.1:{http.server_address[1]}/#/run/{name}')
                    page.get_by_role('heading', name='运行完成', exact=True).wait_for()
                    page.get_by_text('1 通过 / 1 有效', exact=False).first.wait_for()
                    for label in ('一次性完成率', '首轮满分率', '任务总 Token', '初始 Token（均值）', 'TPS（生成）', 'TTFT（均值）', '估算成本'):
                        page.locator('.metric > span', has_text=label).first.wait_for()
                    page.get_by_text('25.0 tok/s', exact=True).first.wait_for()
                    page.get_by_text('0.20s', exact=True).first.wait_for()
                    assert '#/run/' in page.locator('.run-state a').get_attribute('href')
                    if args.screenshot:
                        page.goto(f'http://127.0.0.1:{http.server_address[1]}/#/profile/{profile}')
                        page.locator('.submission').wait_for()
                        page.screenshot(path=str(args.screenshot), full_page=True)
                    page.goto(f'http://127.0.0.1:{http.server_address[1]}/#/settings')
                    page.get_by_text(str(manager.jobs_dir), exact=True).wait_for()
                    page.goto(f'http://127.0.0.1:{http.server_address[1]}/#/job/{name}/fix-git__fake')
                    page.get_by_text('920', exact=True).first.wait_for()
                    page.get_by_text('2,020', exact=True).first.wait_for()
                    manager.profiles.advance()
                    with patch.dict(os.environ, {'FAKE_BENCH_RELEASE_FILE': str(root / 'hold-standalone')}):
                        loose = manager.launch({'model': 'tokenjoy/test-model', 'tasks': ['fix-git']})['name']
                    imported = _job(manager.jobs_dir, 'imported', 'test-model', 1)
                    try:
                        page.wait_for_function("name => fetch('/api/job?name=' + name).then(r => r.ok)", arg=loose)
                        http.workbench.library.sync()
                        page.goto(f'http://127.0.0.1:{http.server_address[1]}/#/')
                        assert page.get_by_role('link', name=imported.name, exact=True).get_attribute('href') == '#/job/imported'
                        page.get_by_role('link', name=loose, exact=True).click()
                        page.get_by_text('执行日志', exact=True).wait_for()
                        page.get_by_role('button', name='停止评测', exact=True).click()
                        assert wait_run(manager, loose)['status'] == 'cancelled'
                    finally:
                        manager.cancel(loose)
                        wait_run(manager, loose)
                    page.set_viewport_size({'width': 390, 'height': 844})
                    page.goto(f'http://127.0.0.1:{http.server_address[1]}/#/new')
                    page.locator('.form-submit button').wait_for()
                    assert page.evaluate('document.documentElement.scrollWidth <= window.innerWidth'), 'mobile overflow'
                    assert not errors, errors
                    browser.close()
                    print('bench UI smoke: submit -> worker -> graded result + metrics/storage, desktop/mobile, no JS errors (paid=0)')
            finally:
                http.shutdown()
                http.server_close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
