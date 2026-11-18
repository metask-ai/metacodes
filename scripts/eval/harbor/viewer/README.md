# Bench viewer

A web workbench over Harbor job directories: launch selected tasks/models,
watch progress, then inspect how each task ended and why.

The supported CLI is [`metacodes bench`](../../../../doc/BENCH_WORKBENCH.md).
The server can still be started directly in read-only mode:

```sh
python3 -m scripts.eval.harbor.viewer.server --jobs-dir ~/harbor-runs --port 18766
# share on the network: --bind 0.0.0.0
```

| View | Answers |
|---|---|
| 总览 `#/` | every job: model, progress, outcome mix, valid pass rate, invalid count, tokens, estimated cost, wall time |
| 作业 `#/job/<job>` | per task: outcome, reward, verifier tests passed, stop reason, turns, tool calls, tokens and cache share, cost, time split (environment / install / agent / verifier); filter, sort, CSV |
| trial `#/job/<job>/<trial>` | verifier tests with messages, tool usage, the whole trajectory (calls and results), verifier output and metacodes stderr |
| 对比 `#/compare/<job>,<job>` | the same tasks across jobs (models), the pass rate on tasks every job scored |

Outcomes follow [doc/BENCHMARKS.md](../../../../doc/BENCHMARKS.md): `invalid`
(verifier timeout, provider or environment failure, no reward) stays out of
the pass rate; `agent 超时` counts as a failure. `空回复结束` marks a trial
metacodes ended on a reply with no text and no tool call.

Pages refresh every 10 s while a job runs. Analysis reads files only; names
in requests are checked against the jobs on disk, and every value reaches
the page as text (no markup from the data, `script-src 'self'`).

The overview, job, trial and CSV views expose total/initial tokens, first-attempt
full-score rate, request-weighted generation TPS, TTFT mean/P50/P95, and cost
coverage. See [metric definitions and storage](../../../../doc/BENCH_WORKBENCH.md#metric-definitions).
Historical timings remain unknown; new workbench runs capture numeric
request metrics through the host streaming relay.

`data.py` is the projection, `runner.py` validates selections, and `worker.py`
owns one durable execution. HTTP launch/cancel routes require the workbench
capability. The benchmark catalog (suites, categories, adapters, WorkBuddy
runner) is `scripts/eval/harbor/suites/`. Contract tests are
`scripts/eval/tests/test_harbor_viewer.py`, `test_bench_workbench.py` and
`test_bench_suites.py`.
