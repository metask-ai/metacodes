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
metacodes bench info                    # dependencies, models, suites and readiness
metacodes bench list --json             # previous jobs and results
metacodes bench stop                    # stop HTTP service; workers continue
metacodes bench run --task fix-git --task cancel-async-tasks --wait
metacodes bench run --suite aime-2025 --wait          # the suite's default sample
metacodes bench run --suite terminal-bench-2.0 --task fix-git
metacodes bench prepare --suite gaia2-cli             # generate a harbor-local dataset
```

Without `--suite`, `run` uses Terminal-Bench 2.1 as before. Without `--task`,
it runs the suite's default sample (an error when the suite has none).

`run --wait` waits for the worker, returns its exit status (0 on successful
execution, 1 on failure/interruption), and prints the stable result link.
Without `--wait`, it returns as soon as the job starts. A scored failure is
a valid benchmark outcome and does not itself make the execution fail.
`--json` produces JSON on stdout; misuse exits 2. Read-only `info` and `list`
do not start a service or call a model.

## Benchmarks

The 新建评测 page groups the suites by category. `metacodes bench info` and
`GET /api/workbench` (`suites`, `categories`) list each suite with its task
count and readiness; `GET /api/suite?id=<suite>` returns its task ids and
default sample. The catalog is `scripts/eval/harbor/suites/__init__.py`.

| Category | Suite id | Runner | Harbor 0.26 source | Tasks (cap per launch) |
|---|---|---|---|---|
| 代码生成 | `humaneval` | harbor-local | adapter `humaneval` (not yet available) | per adapter (164) |
| 基础编程 | `mbpp` | harbor-local | adapter `mbpp` (not yet available) | per adapter (200) |
| 交互规划 | `alfworld` | harbor-local | adapter `alfworld` (not yet available) | per adapter (134) |
| 问答 | `searchqa` | harbor-local | adapter `searchqa` (not yet available) | per adapter (200) |
| 数学推理 | `livemath` | harbor-local | adapter `livemath` (not yet available) | per adapter (200) |
| 竞赛数学 | `aime` | harbor-registry | `-d aime@1.0` | 60 (60) |
| 竞赛数学 | `aime-2025` | harbor-registry | `-d aime@1.0`, 2025 I/II only | 30 (30) |
| 终端工程 | `terminal-bench-2.1` | harbor-registry | `-d terminal-bench/terminal-bench-2-1` | 89 (89) |
| 终端工程 | `terminal-bench-2.0` | harbor-registry | `-d terminal-bench@2.0` | 89 (89) |
| 通用 Agent | `gaia2-cli` | harbor-local | adapter `gaia2_cli` (Harbor `adapters/gaia2 --cli`) | 800 (100) |
| 办公 Agent | `workbuddy-code`, `workbuddy-sec` | workbuddy | pinned WorkBuddy-Bench | 80 / 60 (20) |
| 办公 Agent | `workbuddy-web`, `workbuddy-office` | workbuddy | listed, not launched (LLM judge budget) | 70 / 50 |

Each task runs 1–5 times; concurrency is 1–3 (AIME and the small-task
adapters allow up to 8, WorkBuddy 2). Task ids must belong to the chosen
suite, and the worker passes each as an exact Harbor `-i` pattern.

Harbor 0.26 resolves `-d name@version` through its legacy registry (tasks
matched by bare name, e.g. `fix-git`, `aime_i-1`) and `-d org/name[@ref]`
through the Harbor Hub (tasks matched as `org/name`, e.g.
`terminal-bench/fix-git`; `latest` of `terminal-bench-2-1` is revision 6).
AIME ids are `aime_60`…`aime_89` (2024), `aime_i-1`…`aime_i-15` (2025-I) and
`aime_ii-1`…`aime_ii-15` (2025-II); `aime-2025` selects the last 30. GAIA2
is in neither registry, so `gaia2-cli` runs a locally generated dataset with
`-p`. Its tasks reach the agent's tools through an MCP sidecar
(`[[environment.mcp_servers]]`), which the metacodes Harbor agent writes into
the trial's `mcpServers`; its verifier is an LLM judge that needs
`OPENAI_API_KEY` (and optionally `OPENAI_BASE_URL`, default OpenRouter, and
`JUDGE_MODEL`) in the execution service's environment. `bench prepare
--suite gaia2-cli` runs Harbor's adapter from a Harbor source checkout named
by `METACODES_BENCH_HARBOR_SOURCE` (`uv` and the Hugging Face `datasets`
package; the dataset is public), or register an existing directory with
`metacodes bench --dataset gaia2-cli=<dir>`.

### Adding a harbor-local suite

An adapter is `scripts/eval/harbor/adapters/<name>.py`, registered by an entry
in `ADAPTER_SUITES` (its id and category are authoritative) and listed in
`scripts/bench_assets.zig` so the binary carries it. It exposes:

```python
SUITE = {"name": "HumanEval", "description": "…", "default_tasks": [...],
         "max_tasks": 164, "max_concurrency": 8}       # all optional

def prepare(dest: Path) -> Path:
    """Write Harbor task dirs (<dest>/<task-id>/task.toml, …); return the dataset dir."""

def check(ctx) -> list[str]:          # optional extra readiness reasons
def tasks(dataset: Path) -> list[str]: # optional; default: dirs with task.toml
```

Task ids must match `[A-Za-z0-9][A-Za-z0-9._-]*` (no glob characters).
`metacodes bench prepare --suite <id>` calls `prepare` on the execution
machine with `dest = <state root>/bench/datasets/<suite id>`; a returned
directory elsewhere is recorded in `workbench.json` `datasets`. Until the
module exists the page lists the suite as not yet available.

### WorkBuddy

The `workbuddy` runner drives the pinned integration in
[scripts/eval/workbuddy](../scripts/eval/workbuddy/README.md) under the same
durable worker. Readiness requires a checkout from `provision_checkout.sh`
(`metacodes bench --workbuddy-checkout <dir>` or
`METACODES_WORKBUDDY_CHECKOUT`) at the pinned commit with the overlay and
`.venv`, production linux/amd64 artifacts staged by `stage_artifacts`, the
subset fetched by WorkBuddy's `scripts/dataset/fetch-dataset.sh`, Docker,
`uv`, `bash`, and Metask account authentication. A launch writes a transient
`configs/models|jobs/metacodes-<run>.yaml` (removed afterwards), runs
`uv run --frozen bash scripts/run.sh --job metacodes-<run>` in the checkout
with the account key in a dedicated variable and the judge key removed, and
sets the job's `jobs_dir` to `<jobs-dir>/<run>/workbuddy`, whose Harbor
trials the job view reads. These are ordinary WorkBuddy runs, not
launch-gate receipts or quality evidence; the judged Web/Office subsets
remain with `launch_gate`.

## Configure execution

Choose a Linux release bundle and a model once on the execution machine:

```sh
uv tool install harbor==0.26.0
metacodes login                       # sign in and select a model
metacodes bench --bundle /path/to/linux-release
```

The workbench reads the current CLI session from `oauth/metask.json` and the
model/reasoning preferences from `auth.json`. It uses the session's gateway
and authenticated `/v1/models` directory, leaving out models that explicitly
do not support `/v1/messages`. Session refresh follows the CLI's JSON grant
at `METASK_SITE_URL` (default `https://www.metask-ai.com`), with client
`metacodes`, and persists rotated tokens in the same private session file.
`METACODES_OAUTH_DIR` and `METACODES_AUTH_FILE` overrides match the CLI.

Older `auth.json` account logins remain supported. Their account OAuth token
lists all active keys/model groups, then each group's
key queries its authenticated `/v1/models` directory. The page shows the
union of these model lists, with duplicates removed. If several groups
provide a model, the CLI's selected key takes priority. Groups whose model
directory cannot be read are reported rather than silently hidden.
The page also lists the account's available groups and whether a key already
exists for each. Groups without a key are shown separately from runnable
models; no keys are created and no model ids are guessed from group names.

Model metadata is cached for one minute and invalidated when either login file
changes. The default model and reasoning effort follow the saved login.
Launching a model resolves the current session token or its legacy group's
key, checks that it still provides that model, and passes it as `METASK_API_KEY` through Harbor's
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
    workbuddy/<harbor run>/<trial>/  # WorkBuddy launches: trials of its own Harbor runs
```

The overview displays the configured absolute jobs path. The workbench does
not require a database and does not sync these run files back to a developer
checkout. Keep this jobs directory when moving or backing up the workbench;
the state root's `bench/` directory separately holds service settings and its
private authorization receipt.

- **新建评测:** choose a suite by category, then its tasks (search, default
  sample, all, or a random N) and a configured model; caps are per suite.
- **总览:** each job shows its suite and category and can be filtered by
  category; launches from before suites existed are recognised by dataset.
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

The run endpoint (`POST /api/runs`) accepts `suite`, `tasks`, `model`,
`attempts` and `concurrency`; the original `dataset:
"terminal-bench/terminal-bench-2-1"` field is still accepted and means
`suite: "terminal-bench-2.1"`. It takes task/model selections, not shell
commands, paths, keys, or arbitrary Harbor flags. Full task names are passed as separate argv
elements; there is no shell interpolation and retries are disabled at the
Harbor orchestration layer.

Contract tests use real HTTP and a subprocess standing in for Harbor, proving
that UI/CLI input reaches the child argv, creates a visible job, preserves
exit status, and supports cancellation without making paid requests.
