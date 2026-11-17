# Bench workbench

`metacodes bench` starts a background web service, opens it in the browser,
and prints its URL. The executable carries the Python and frontend files, so
it works outside a checkout. Python 3.9+ must be on PATH; set
`METACODES_BENCH_PYTHON` to choose an interpreter. Harbor 0.26 and Docker are
needed on the machine that executes trials. OpenSSL is also needed there for
the job-local timing relay's ephemeral TLS certificate.

```sh
metacodes bench                         # start/reuse service and open browser
metacodes bench --no-open               # print the workbench link
metacodes bench info                    # dependencies, models and readiness
metacodes bench list --json             # previous jobs and results
metacodes bench stop                    # stop HTTP service; workers continue
metacodes bench run --task fix-git --task cancel-async-tasks --wait
```

`run --wait` waits for the worker, returns its exit status (0 on successful
execution, 1 on failure/interruption), and prints the stable result link.
Without `--wait`, it returns as soon as the job starts. A scored failure is
a valid benchmark outcome and does not itself make the execution fail.
`--json` produces JSON on stdout; misuse exits 2. Read-only `info` and `list`
do not start a service or call a model.

## Configure execution

Choose a Linux release bundle and a model once on the execution machine:

```sh
uv tool install harbor==0.26.0
metacodes login                       # select your Metask account key/model
metacodes bench --bundle /path/to/linux-release
```

By default the workbench reads the current install's `auth.json` login.
The account OAuth token lists all active keys/model groups, then each group's
key queries its authenticated `/v1/models` directory. The page shows the
union of these model lists, with duplicates removed. If several groups
provide a model, the CLI's selected key takes priority. Groups whose model
directory cannot be read are reported rather than silently hidden.
The page also lists the account's available groups and whether a key already
exists for each. Groups without a key are shown separately from runnable
models; no keys are created and no model ids are guessed from group names.

Model metadata is cached for one minute and invalidated when the login file
changes. The default model and reasoning effort follow the saved login.
Launching a model resolves its group's current key, checks that the key
still provides that model, and passes it as `METASK_API_KEY` through Harbor's
environment reference. The CLI's selected key/model remain unchanged. Only
non-secret key ids enter run specs; API keys and OAuth refresh tokens never
enter workbench settings, job specs, or the browser.

The 0.12 account OAuth token is refreshed through its own token endpoint
before expiry (or once after a rejected access token). Bench catalog reads
and workers serialize refreshes with a file lock and persist rotated tokens
atomically with private permissions, preserving login preferences. A plain
API-key login without account OAuth can list only that key's models; the page
states this scope and suggests completing account login for all model groups.

For a workbench whose files live under a separate state directory, select
the install that is already logged in explicitly:

```sh
metacodes bench --auth metask --account-state-dir /path/to/logged-in/state
```

An existing third-party setup remains explicit and independent. Switch it
back with `--auth metask`; the third-party configuration will not be used
for account runs. To use a gateway instead:

```sh
export TOKENJOY_API_KEY=...             # or this install's state-root/.env
metacodes bench --bundle /path/to/linux-release \
  --provider-config /path/to/config.json \
  --model tokenjoy/GLM5.3-Flash --key-env TOKENJOY_API_KEY
```

`--provider-config` is a native metacodes configuration with
`custom_providers`; see [the Harbor adapter](../scripts/eval/harbor/README.md).
`--key-env` names the credential variable; the key is never accepted as a
browser field or stored in a run specification. Execution uses Harbor's
`${VARIABLE}` reference. The installed service inherits its startup
environment, so restart the service after changing a credential.

Defaults and server configuration live in `<state root>/bench/workbench.json`.
Jobs go to `<state root>/bench/jobs` unless `--jobs-dir` names an existing
Harbor jobs directory. Both paths respect a leading `--state-dir` or
`METACODES_HOME`. Python/frontend files are extracted to a content-addressed
runtime directory under the same state root. No release-layout file or
SDK/AgentCore ABI changes are required.

## Devbox and remote access

```sh
# On devbox, with the provider environment set:
metacodes bench --jobs-dir /path/to/harbor-runs --bind 0.0.0.0 \
  --port 18766 --public-url http://devbox:18766/ --no-open

# On Mac, connect to that existing service:
metacodes bench --url 'http://devbox:18766/?token=<workbench capability>'
metacodes bench info --url http://devbox:18766/
```

The link printed when a service starts contains a workbench capability.
Opening it creates an HttpOnly SameSite cookie and redirects to a clean URL.
Reads remain available without the capability. Run/cancel requests require
the cookie or a bearer capability and reject foreign browser origins. A CLI
client can also supply `METACODES_BENCH_TOKEN`. The workbench keeps its service
receipt (including capability) at `<state root>/bench/service.json` with mode
0600 on POSIX.

## Using the page

### Metric definitions

| Metric | Calculation |
|---|---|
| Task total tokens | All model-request input tokens (including cache read/write) plus output tokens; repeated context is counted on each request |
| Initial tokens | The first model request's full input usage, including system prompt, tools, task and cached context; historical runs use the first native `usage` event |
| Single-run full-score rate | Independent valid runs with reward >= 1 / all valid runs. Every failed attempt remains in the denominator when a later independent run succeeds |
| First-attempt full-score rate | Tasks with reward >= 1 on their earliest trial / tasks whose earliest trial has a valid outcome. Later attempts never replace the first score. Infrastructure-invalid and running first trials are shown separately |
| Generation TPS | Sum of reported output tokens / sum of generation seconds, from first semantic output until response completion. Tool execution and first-token waiting are excluded |
| TTFT | From relay dispatch to the first non-empty text, reasoning, or tool-call output. Heartbeats and response metadata do not count. The global mean and P50/P95 pool request samples across jobs |
| Estimated cost | The metacodes binary's catalog estimate, including cache pricing. It is not the provider's settlement. Missing/zero unknown prices are shown as unknown with coverage counts |

The timing relay runs on the execution host and forwards streaming payloads
unchanged. It stores numeric timing/usage records only, under
`<jobs-dir>/<job>/.bench-metrics/<trial>.jsonl`. Its local Docker hop and HTTP
forwarding are part of the measured harness; these numbers are not provider
SLAs. The current relay supports configured Bearer, API-key-header, and
custom-header Messages, Chat Completions, and Responses routes, with origin or `/v1` base paths.
Other routes retain native execution and show missing timing coverage.
Latency aggregates use complete successful requests; failed or interrupted
requests do not become timing samples. The page reports sample coverage.
The host bind defaults to Docker's `172.17.0.1`; server-owned settings can
choose `metrics_bind`, or disable capture with `metrics_enabled: false`.
The container-to-host relay uses HTTPS; its ephemeral CA is added to the
disposable task image's CA bundles, and its private key stays on the host and
is removed when the worker exits. Native certificate verification stays on.

Old logs without request timestamps cannot recover TTFT/TPS and display
`未采集`, not an estimate from task wall time. Interrupted runs with partial
usage retain the observed tokens and are marked `部分记录`. Global costs and
token sums report their coverage so missing data cannot look like zero cost.

### Data storage

All results are ordinary files on the execution machine:

```text
<jobs-dir>/
  .bench-runs/                     # launch receipts, specs, worker logs
  <job>/
    config.json, result.json       # job configuration and aggregate result
    .bench-metrics/<trial>.jsonl   # numeric request-level timing/usage
    <trial>/
      config.json, result.json     # trial score, timings and usage
      agent/                      # NDJSON, transcript, ATIF trajectory, stderr
      verifier/                   # reward, test output, CTRF report
```

The overview displays the configured absolute jobs path. The workbench does
not require a database and does not sync these run files back to a developer
checkout. Keep this jobs directory when moving or backing up the workbench;
the state root's `bench/` directory separately holds service settings and its
private authorization receipt.

- **新建评测:** choose a configured model and 1–20 Terminal-Bench 2.1 tasks;
  each task runs 1–5 times, with concurrency 1–3. The suggested task names are
  a starter list, and additional names can be entered directly.
- **运行状态:** queued/running/completed status, execution log, stop button,
  and a stable result URL. The worker survives HTTP service restarts; a
  durable cancellation marker asks that worker to stop its own process group.
- **总览 / 作业 / 单题 / 对比:** progress, rewards, valid pass rate, invalid
  reasons, token/cache usage, estimated cost, phase durations, verifier test
  failures, complete trajectories, and CSV export.

Only one workbench launch runs at a time. Failed launches have their own
durable receipt even when Harbor could not create a job. A stale worker is
shown as interrupted. Closing the browser or CLI does not stop the worker.
Jobs refresh every ten seconds while active; per-trial trajectories become
available when Harbor copies the agent logs back from the container.

The run endpoint accepts task/model selections, not shell commands, paths,
keys, or arbitrary Harbor flags. Full task names are passed as separate argv
elements; there is no shell interpolation and retries are disabled at the
Harbor orchestration layer.

Contract tests use real HTTP and a subprocess standing in for Harbor, proving
that UI/CLI input reaches the child argv, creates a visible job, preserves
exit status, and supports cancellation without making paid requests.
