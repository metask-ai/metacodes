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
| Profiles `#/` | profile versions and status, profile comparison, and historical standalone evaluations |
| Profile `#/profile/<id>` | frozen metacodes version and advanced features, jobs grouped by submission with job and evaluation controls, comparisons between jobs, every task's latest attempts (a rerun replaces the earlier result); set its concurrency (并发数, for every dataset it runs), rename it, run it again or rerun its tasks with invalid attempts (automatically too, when 自动重跑 is on), stop its queue, delete it once ended |
| 任务 `#/profile/<id>/task/<job>/<task>[/<trial>]` | attempts side by side, then the selected attempt as on the trial view, with previous/next task and the replaced runs |
| 创建作业 `#/new` | executor, metacodes version and advanced features (the profile), models, several suites and their tasks, attempts (concurrency is set on the profile page); the start button stays at the bottom of the window |
| 系统配置 `#/settings` | database selection and migration, model providers and Metask account login |
| 评测结果 `#/job/<job>` | per task: outcome, reward, verifier tests passed, stop reason, turns, tool calls, tokens and cache share, cost, time split (environment / install / agent / verifier); filter, sort, CSV |
| trial `#/job/<job>/<trial>` | per-request token distribution and context composition, time split (model / tools / other) and per-tool timing, verifier tests, the whole trajectory with each call's execution time, verifier output and metacodes stderr |
| 对比 `#/compare/<job>,<job>` | the same tasks across jobs (models), the pass rate on tasks every job scored |
| 榜单 `#/leaderboard/<suite>` | published results of other agents and models on the suite, with this workbench's jobs ranked among them |

Outcomes follow [doc/BENCHMARKS.md](../../../../doc/BENCHMARKS.md): `invalid`
(verifier timeout, provider or environment failure, no reward) stays out of
the pass rate; `agent 超时` counts as a failure. `空回复结束` marks a trial
metacodes ended on a reply with no text and no tool call.

Pages refresh every 10 s while a job runs. The server syncs the jobs
directories into the [evaluation database](../../../../doc/BENCH_WORKBENCH.md#evaluation-database)
(`../store/`) and serves every view from it; names in requests are looked up
in the database, never used as paths, and every value reaches the page as
plain text (no markup from the data).

The profile, job, trial and CSV views expose total/initial tokens, first-attempt
full-score rate, request-weighted generation TPS, TTFT mean/P50/P95, and cost
coverage, plus the pass-rate 95% interval, tasks solved at least once, cost per
task and per pass, the cost share of non-passing runs, cache hit rate and turns
per pass. The compare page marks the cost-pass frontier. See [metric definitions and storage](../../../../doc/BENCH_WORKBENCH.md#metric-definitions).
Historical timings remain unknown; new workbench runs capture numeric
request metrics through the host streaming relay.

This directory is only the web presentation: `server.py` maps routes onto the
runtime's `Workbench` and `static/` is the page. The runtime lives in
[`../bench/`](../bench/): `data.py` is the projection (applied to the stored
bytes by `../store/ingest.py`), `runner.py` validates selections, `profiles.py`
freezes a bundle and runs the datasets queued on a profile in order, `worker.py` owns one
durable execution and ingests its job, and `workbench.py` is the facade the
page and the CLI both read. `executors.py` (this machine or SSH hosts),
`remote.py` (the driver on an SSH host), `setup.py` (`bench setup`) and
`providers.py` (imported model providers) let a launch run on any configured
executor through the same worker. The benchmark catalog (suites, categories,
adapters, WorkBuddy runner) is `scripts/eval/harbor/suites/`. The workbench
has no login (internal network); POSTs with a foreign browser `Origin` are
refused, and a service without `--config` is read-only. Contract tests are
`scripts/eval/tests/test_harbor_viewer.py`, `test_bench_workbench.py`,
`test_bench_store.py`, `test_bench_suites.py`, `test_bench_setup.py`,
`test_bench_profiles.py` and `test_bench_providers.py`.
