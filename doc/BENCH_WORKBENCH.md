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
metacodes bench setup [--executor NAME] [--dry-run] [--json]   # install what is missing
metacodes bench db status               # evaluation database: SQLite or PostgreSQL
metacodes bench run --task fix-git --task cancel-async-tasks --wait
metacodes bench run --suite aime-2025 --wait          # the suite's default sample
metacodes bench run --suite terminal-bench-2.0 --task fix-git
metacodes bench run --suite aime --executor relay-4090 --wait   # on an SSH executor
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
| 代码生成 | `humaneval` | harbor-local | adapter `humaneval` (openai/human-eval, pinned) | 164 (164) |
| 基础编程 | `mbpp` | harbor-local | adapter `mbpp` (full test split, pinned) | 500 (200) |
| 基础编程 | `mbpp-sanitized` | harbor-local | adapter `mbpp_sanitized` (sanitized test split, pinned) | 257 (200) |
| 交互规划 | `alfworld` | harbor-local | adapter `alfworld` (valid_unseen; sidecar linux/amd64 only) | 134 (134) |
| 问答 | `searchqa` | harbor-local | adapter `searchqa` (pinned 200-question test subset) | 200 (200) |
| 数学推理 | `livemath` | harbor-local | adapter `livemath` (LiveMathBench v202412 EN; gated, needs `HF_TOKEN` to prepare) | per prepared set (200) |
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

The harbor-local adapters download pinned sources (verified by hash) into
`<dataset>/.cache/` on `bench prepare --suite <id>` and write Harbor task
directories beside it; see the
[adapter README](../scripts/eval/harbor/adapters/README.md) for sources,
graders and what only a Docker host can check. A suite's `arch` (from the
adapter's `SUITE`) is listed in the catalog and on the page.

### Adding a harbor-local suite

An adapter is `scripts/eval/harbor/adapters/<name>.py`, registered by an entry
in `ADAPTER_SUITES` (its id and category are authoritative) and listed in
`scripts/bench_assets.zig` so the binary carries it. It exposes:

```python
SUITE_ID = "humaneval"                                 # the catalog id
SUITE = {"name": "HumanEval", "description": "…", "default_tasks": [...],
         "max_tasks": 164, "max_concurrency": 8, "arch": "amd64, arm64"}  # all optional
HOST_ENV = ("OPENAI_API_KEY",)        # optional: verifier env, forwarded to SSH executors

def prepare(dest: Path) -> Path:
    """Write Harbor task dirs (<dest>/<task-id>/task.toml, …); return the dataset dir."""

def check(ctx) -> list[str]:          # optional extra readiness reasons
def tasks(dataset: Path) -> list[str]: # optional; default: dirs with task.toml
```

Task ids must match `[A-Za-z0-9][A-Za-z0-9._-]*` (no glob characters).
`metacodes bench prepare --suite <id>` calls `prepare` on the execution
machine with `dest = <state root>/bench/datasets/<suite id>`; a returned
directory elsewhere is recorded in `workbench.json` `datasets`. The suite id
may differ from the module name (`mbpp-sanitized` is `mbpp_sanitized.py`);
`ADAPTER_SUITES` names the module. Until the module exists the page lists the
suite as not yet available. On an SSH executor only the task directories are
shipped (dot entries such as `.cache/` stay on the workbench machine).

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

`metacodes bench setup` prepares an execution machine in one go; the page's
新建评测 callout has the same 一键配置 button (and 预演, a dry run) whenever
something is missing:

```sh
metacodes bench setup --dry-run         # checks only; lists every command it would run
metacodes bench setup                   # this machine
metacodes bench setup --executor relay-4090 --json
```

Each step checks first, installs only what is missing and verifies the
result. Every command is logged (in the terminal, or in the page's step list),
`--dry-run` executes only read-only checks, and no secret is stored or
printed. Steps that need root run only when `sudo -n` works; otherwise the
step reports the exact command to run. The page's `POST /api/setup`
(`{"executor": NAME, "dry_run": bool}`) has the same capability and
same-origin rules as `/api/runs`, and its progress (`GET /api/setup`) is only
shown to the capability holder. Setup refuses to run while a benchmark is
active, because it may restart Docker.

| Step | What it does |
|---|---|
| SSH access (`ssh` executors) | Runs a probe over `ssh -o BatchMode=yes`; if the key cannot run commands, it stops here and says so |
| Python 3.9+ (`ssh` executors) | Needed by the remote driver |
| uv | macOS: `brew install uv` when Homebrew exists; otherwise (and on Linux) the official installer pinned to uv 0.13.9 into `~/.local/bin` |
| Harbor | `uv tool install --force --python 3.12 harbor==0.26.0` (Harbor 0.26 needs Python 3.12); the resulting path is saved |
| Docker | macOS: Homebrew `docker docker-compose docker-buildx colima`, the plugin directory in `~/.docker/config.json`, then `colima start` (see [Colima](#colima-on-apple-silicon)); Linux: `get.docker.com` with passwordless sudo, otherwise the command for the user; also starts the daemon, adds the user to the `docker` group and installs the compose plugin when needed |
| OpenSSL | Generates a throwaway certificate exactly as the timing relay does |
| Linux bundle | See [the release bundle](#the-linux-release-bundle) |
| Copy runtime (`ssh` executors) | Ships the bench runtime and the bundle (below) |
| psycopg | Only when `workbench.json` has `"store": {"backend": "postgres"}`: `pip install --user psycopg[binary]` pinned for the workbench's Python |
| Metask login | Never automated. The step names the command; the page's 登录 button runs `metacodes login --provider metask --no-browser` and shows its device-flow URL and code |

Results the readiness checks read are written to
`<state root>/bench/workbench.json`: `harbor` (or the executor's `harbor`),
`bundle` and `bundle_source`, and on macOS `metrics_bind`/`metrics_host`.

### The Linux release bundle

The release workflow publishes `metacodes-<version>-x86_64-linux-gnu.tar.gz`
and `metacodes-<version>-SHA256SUMS` on the GitHub release
(`release/LAYOUT.md`). When the running executable is a release (`X.Y.Z`),
setup downloads that version's Linux x86_64 unit, checks its SHA-256 against
the release's `SHA256SUMS`, extracts only regular files and directories into
`<state root>/bench/bundles/` and validates the release layout. A development
build (`X.Y.Z-dev`) has no published unit: when the executable lives in a
checkout (or `--source <checkout>` names one), setup downloads the newest
release the same way and cross-compiles this checkout's executable over it:

```sh
zig build install -Drelease-layout=true -Doptimize=ReleaseSafe \
  -Dtarget=x86_64-linux-gnu.2.31 -Dlean-kernels=off \
  -Dformal-kernel-sha256=<release kernel> -Dproject-kernel-sha256=<release kernel> \
  --prefix <copy of the release unit>
```

The Lean kernels are only built natively in CI, so the overlay keeps the
release's kernels and pins their digests; its `manifest.json` is the base
release's. `--bundle-version X.Y.Z` picks a published unit instead, and
`metacodes bench --bundle <dir>` still sets one by hand. `METACODES_RELEASE_BASE`
points the download at a mirror of the releases page.

### Manual configuration

The equivalent manual steps on an execution machine are:

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

## Execution machines

Without an `executors` list, trials run on the workbench's own machine. A
list in `workbench.json` names several machines; the page shows readiness
per machine and lets each run pick one (`metacodes bench run --executor NAME`
does the same):

```json
{
  "executors": [
    {"name": "devbox-mac", "kind": "local"},
    {"name": "relay-4090", "kind": "ssh", "host": "10.126.126.1", "user": "bench",
     "port": 22, "identity_file": "~/.ssh/bench_relay", "state_dir": ".metacodes-bench"}
  ],
  "default_executor": "devbox-mac"
}
```

An `ssh` entry also accepts `harbor` (written by setup), `python`
(default `python3`), `metrics_bind` (default `172.17.0.1`) and
`metrics_enabled`. Names, hosts, users and paths are validated before any
`ssh` argv is built; unknown fields are refused. Readiness probes are cached
for 15 seconds.

### SSH prerequisites

- An SSH key that may run commands on the host. A key restricted to port
  forwarding (or a forced command) is reported as such: readiness says that
  SSH connected but cannot run commands, and setup stops at its first step.
- The host key is accepted on first use (`StrictHostKeyChecking=accept-new`);
  connections use `BatchMode=yes`, so a passphrase prompt fails instead of
  hanging. Load the key into an agent or use one without a passphrase.
- Linux with `sh`, `tar` and Python 3.9+; Harbor, Docker and OpenSSL can be
  installed by `metacodes bench setup --executor <name>`. Docker installation
  and group changes need passwordless sudo, or the user runs the reported
  command.

### How an SSH run works

The local worker stays the durable owner of the run: it resolves the
account (or provider) key exactly as for a local run, then

1. ships the bench runtime and the Linux bundle as tar streams over SSH into
   `<state_dir>/runtime/<digest>` and `<state_dir>/bundles/<digest>`, once per
   content digest (complete directories are marked and reused);
2. uploads the run's secret-free spec (and provider configuration, if any) to
   `<state_dir>/runs/<name>/`;
3. starts `python3 -m scripts.eval.harbor.viewer.remote run …` over SSH and
   writes the credential as the first line on the SSH channel's stdin. The
   remote driver keeps it only in its own environment and Harbor's (`--ae
   NAME=${NAME}` as locally): it is never in argv, in a file, or in the SSH
   command line. `SendEnv` is not used because it needs the server's
   `AcceptEnv`;
4. the driver starts the timing relay next to the remote Docker daemon (on
   the executor's `metrics_bind`), runs Harbor in its own process group and
   prints heartbeats; Harbor's output reaches the local run log;
5. the worker copies the remote job directory into the local jobs directory
   every 10 seconds and once more at the end, transferring only files whose
   size or modification time changed. The viewer and other readers of local
   job directories see ordinary Harbor files.

Suites on an SSH executor: `harbor-registry` suites run there unchanged
(the remote Harbor resolves `-d` itself). A `harbor-local` suite's dataset
directory is generated on the workbench's machine (`bench prepare`, or
`--dataset SUITE=DIR`) and shipped like the bundle, into
`<state_dir>/datasets/<digest>`, once per content digest; Harbor's `-p` then
names that copy. Execution-host variables a suite's verifier reads (GAIA2's
`OPENAI_API_KEY`, `OPENAI_BASE_URL`, `JUDGE_MODEL`, declared by the adapter's
`HOST_ENV`) travel with the credential on the SSH channel's stdin. WorkBuddy
suites drive the workbench machine's own checkout and Docker, so they run on
the `local` executor only; readiness on an SSH executor says so and the
launch is refused.

Readiness is per suite and executor: `GET /api/workbench` lists, for every
suite, `executors.<name>.reasons` (service-wide reasons such as sign-in, the
Linux bundle and the executor's own Harbor/Docker/OpenSSL readiness for
Harbor suites, the suite's own prerequisites, and refused combinations),
plus `suite_reasons`; `ready`/`reasons` on the suite and at the top level
are those of the default executor (the top level for the default suite).

Cancel sends `cancel` on the channel: the driver interrupts Harbor (SIGINT,
then SIGKILL after 20 seconds). If the channel closes, or no heartbeat
arrives for 90 seconds, the driver stops Harbor as well, so a lost connection
never leaves trials running unsupervised.

### Colima on Apple Silicon

Docker Desktop is not used (licensing). Setup installs Colima and the docker
CLI from Homebrew and starts:

```sh
colima start --runtime docker --cpu 4 --memory 8 --disk 100 \
  --vm-type vz --vz-rosetta --arch aarch64 --mount-type virtiofs --mount "$HOME:w"
```

Terminal-Bench images are linux/amd64. With `vz` + Rosetta the VM is native
arm64 and amd64 containers run through Rosetta's Linux binfmt handler: close
to native speed, but Rosetta does not translate every x86 extension, so a
task that needs one fails. `"colima": {"emulation": "qemu"}` in
`workbench.json` instead runs a whole x86_64 VM under QEMU (exact amd64,
several times slower; Homebrew `qemu` and `lima-additional-guestagents`).
`cpu`, `memory` and `disk` can be set there too. Rosetta for Linux VMs must
be installed (`softwareupdate --install-rosetta --agree-to-license`).
Verification runs `docker run --platform linux/amd64 alpine:3.20 uname -m`.

Inside Colima, `172.17.0.1` is the VM's bridge, not the Mac. Setup therefore
sets `metrics_bind: 127.0.0.1` and `metrics_host: 192.168.5.2` (Lima's
`host.lima.internal`, which forwards to the Mac's loopback) and checks that a
container reaches it. Colima does not start at login; when Docker becomes
unreachable after a reboot, readiness says so and 一键配置 starts it again.

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

All results are ordinary files on the workbench's machine (an SSH
executor's job directory is copied back into the same layout, and from
there into the evaluation database):

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

WorkBuddy trials under `workbuddy/<harbor run>/` are ingested as trials of
the workbench job, with the same projection as top-level trials (request
metrics are read from `.bench-metrics/` beside them).

The page reads the [evaluation database](#evaluation-database), which holds
all of these files and the values computed from them. The overview shows the
database and the synced jobs directories. Run files are not synced back to a
developer checkout.

### Evaluation database

Every job directory and launch record is copied into one database: SQLite by
default (`<state root>/bench/bench.sqlite3`, beside `workbench.json`, with
the same `--state-dir`/`METACODES_HOME` rules) or a remote PostgreSQL. The
service syncs its jobs directory when it starts, every ten seconds, and
before API reads (at most once every two seconds). The worker also syncs its
job every 15 seconds during a run and does a final, content-verified sync
before it writes the finished receipt. Ingestion is idempotent. Only files
whose size or mtime changed are read again, so a job that is still running
can be ingested safely. A partially written file is replaced on the next
pass. Symlinks are never followed.

| Layer | Tables | Content |
|---|---|---|
| raw | `blobs`, `files`, `runs` | Every file of every job (trajectories, NDJSON, stderr, verifier output, CTRF, request metrics, results), stored as zlib-compressed blobs keyed by SHA-256 of the content, with path, size and mtime; launch receipts with their spec and worker log |
| normalized | `jobs`, `trials`, `requests`, `usage_events`, `verifier_tests` | Model, dataset, status (enum), reward, tokens, cost and its source, TTFT/TPS, phase seconds, per-request timing/usage, per-event usage and full verifier messages, all queryable with SQL |
| projection | `jobs.header_json`, `trials.row_json`, `trials.detail_json` | Exactly what the page shows, computed by the viewer's file projection from the stored bytes |

Projections are recomputed from the stored bytes when either the bytes or
the projection code changes. Metric definitions therefore stay identical to
a live jobs directory: the contract test compares every view, CSV and
summary from files with the same view from the database, also after the files
are deleted. CHECK and foreign-key constraints reject unknown statuses,
scored trials without a reward, costs whose source contradicts them, and
dangling rows. Each schema change is a numbered migration recorded in
`schema_migrations`. A database whose schema is newer than the binary is
refused. Files larger than 256 MiB are recorded with size and mtime, but
their content is not stored.

```sh
metacodes bench db status                       # backend, schema, row counts
metacodes bench db import --jobs-dir ~/harbor-runs   # add historical jobs
metacodes bench db migrate --to postgresql://bench@db:5432/bench \
  --password-env BENCH_PG_PASSWORD --switch
metacodes bench db migrate --to ~/bench-copy.sqlite3   # PostgreSQL -> SQLite
```

`db import` does not change the workbench's configured jobs directory. A
job name that is already stored from another existing directory is skipped.
`--verify` re-reads every file by content.

`db migrate` copies everything from the active database to the target, in
either direction. It reads the source in one snapshot and commits the target
in batches, so an interrupted migration resumes when run again. Rows already
present and identical are skipped. If the target holds a different row under
the same key, the command stops before writing and changes nothing. After
the copy, every source row is compared with the target, and every target blob
is re-hashed. The command reports row counts per table. `--switch` then
writes the target into `workbench.json`; restart the service with
`metacodes bench stop && metacodes bench`. A new `metacodes bench` replaces
a running service that uses a different database.

Choose the database directly with `--store-sqlite PATH` or
`--store-postgres DSN [--store-password-env NAME]`, on any `metacodes bench`
command. Each is saved in `workbench.json` as follows:

```json
{"store": {"backend": "sqlite", "path": "/abs/bench.sqlite3"}}
{"store": {"backend": "postgres", "dsn": "postgresql://bench@db:5432/bench",
           "password_env": "BENCH_PG_PASSWORD"}}
```

A DSN containing a password is refused. The password comes from the named
environment variable, or from libpq's `PGPASSWORD`/`~/.pgpass`. It never
enters `workbench.json`, a run spec, or the browser. PostgreSQL needs
psycopg 3 in the Python that runs bench
(`python3 -m pip install 'psycopg[binary]'`). It is imported only when a
PostgreSQL store is configured; SQLite needs only the standard library.
Keep the database (or the jobs directory) when moving or backing up the
workbench. The state root's `bench/` directory also holds service settings
and the private authorization receipt.

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
