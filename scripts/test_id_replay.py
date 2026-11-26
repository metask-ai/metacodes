from __future__ import annotations

import argparse
import json
from pathlib import Path

import yaml


def replay_steps(workflow, leg):
    job = workflow['jobs']['gates-linux']
    matrix = next(row for row in job['strategy']['matrix']['include'] if row['leg'] == leg)
    steps = job['steps']
    first = next(i for i, step in enumerate(steps) if step.get('uses', '').startswith('actions/checkout@')) + 1
    last = next(i for i, step in enumerate(steps) if step.get('name') == 'Upload the executed test IDs')
    replay = []
    for step in steps[first:last]:
        condition = step.get('if', '')
        if (condition.startswith(('matrix.release &&', "env.POOL_JOB == 'true'", "env.WARM_CACHE == 'true'"))
                or step.get('name') in {'Version state gate and release rehearsal', 'Changelog entries are unreleased'}):
            continue
        serialized = json.dumps(step).replace('${{ matrix.leg }}', leg)
        for flag in ('units', 'product', 'checks', 'release'):
            serialized = serialized.replace('matrix.' + flag, 'true' if matrix.get(flag) else 'false')
        step = json.loads(serialized)
        if 'run' in step:
            step.setdefault('shell', 'bash')
        replay.append(step)
    return replay


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('leg', choices=['units', 'product', 'checks'])
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    workflow = yaml.safe_load(Path('.github/workflows/ci.yml').read_text())
    action = dict(name='Pinned Linux test-ID collection', description='Run the base revision Linux leg',
                  runs=dict(using='composite', steps=replay_steps(workflow, args.leg)))
    args.destination.mkdir(parents=True, exist_ok=True)
    (args.destination / 'action.yml').write_text(yaml.safe_dump(action, sort_keys=False))
