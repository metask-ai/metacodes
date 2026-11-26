# Bench workbench

`metacodes bench` starts a background web service, opens it in the browser,
and prints its URL. The executable carries the Python and frontend files, so
it works outside a checkout. Python 3.9+ must be on PATH; set
`METACODES_BENCH_PYTHON` to choose an interpreter. Harbor 0.26 and Docker are
needed on the machine that executes trials. OpenSSL is also needed there for
the job-local timing relay's ephemeral TLS certificate. Another machine
with `metacodes` installed can run the trials as a Bench node driven over
SSH (see [Bench nodes](#bench-nodes)).

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
metacodes bench run --task fix-git --features ""      # without the default run gates
metacodes bench prepare --suite gaia2-cli             # generate a harbor-local dataset
metacodes bench pull --suite terminal-bench-2.1 --executor relay-4090   # pre-pull/pre-build task images
metacodes bench sync --run NAME         # retry an SSH run's final summary
metacodes bench monitor [--executor NAME] [--json]   # load, network, mirrors, Docker and caches of an execution machine
metacodes bench node info [--json]      # this machine as a Bench node (see Bench nodes)
metacodes bench node peers [--json]     # nodes it drives and workbenches that drove it
metacodes bench node build              # build one git revision here ({"ref", "repo"} on stdin)
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

The 新建评测 page groups the suites by category; each suite card and each
selected suite's box show the suite's one-line description (what it tests,
how it is scored, how many tasks), and so does the 榜单 page for the chosen
suite. `metacodes bench info` and
`GET /api/workbench` (`suites`, `categories`) list each suite with its task
count and readiness; `GET /api/suite?id=<suite>` returns its task ids and
default sample. The catalog is `scripts/eval/harbor/suites/__init__.py`.

| Category | Suite id | Runner | Harbor 0.26 source | Tasks (cap per launch) |
|---|---|---|---|---|
| 软件工程 | `swe-bench-verified` | harbor-registry | `-d swe-bench/swe-bench-verified@2` | 500 (500) |
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
| 终端工程 | `frontier-harness-eval-1.1` | harbor-registry | `-d frontier-harness-eval/frontier-harness-eval@v1.1.0` | 62 (62) |
| 通用 Agent | `gaia2-cli` | harbor-local | adapter `gaia2_cli` (Harbor `adapters/gaia2 --cli`) | 800 (100) |
| 客服对话 | `tau3-airline`, `tau3-retail`, `tau3-telecom`, `tau3-banking-knowledge` | harbor-registry | `-d sierra-research/tau3-bench@1`, one domain each | 50 / 114 / 114 / 97 (all) |
| 办公 Agent | `workbuddy-code`, `workbuddy-sec` | workbuddy | pinned WorkBuddy-Bench | 80 / 60 (80 / 60) |
| 办公 Agent | `workbuddy-web`, `workbuddy-office` | workbuddy | pinned WorkBuddy-Bench, in-container LLM judge | 70 / 50 (70 / 50) |

Each task runs 1–5 times; concurrency has no upper limit (GAIA2 caps it at
2 and ALFWorld at 10). The page starts at 4 runs
per task; concurrency is the profile's (10 for a new profile, capped by the
chosen suite) and is set only on the profile page. The CLI's `bench run`
defaults to 1 and 1. Task ids must belong to the chosen
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
the trial's `mcpServers`.

`swe-bench-verified` and the `tau3-*` suites pin a Hub revision (`@2`,
`@1`). Their task ids, read from that revision, are in
`scripts/eval/harbor/suites/registry_tasks.json` (500 SWE-bench Verified
instances named `<owner>__<repo>-<number>`; 375 τ³-bench tasks named
`tau3-bench__tau3-<domain>-...`, up to 238 characters, which is why task ids
may be up to 255 characters). taubench.com scores each τ³ domain on its own,
so each domain is one suite over the same dataset.

τ³-bench tasks talk to an LLM-simulated customer through an MCP sidecar
(`tau3-runtime`), and the banking verifier grades natural-language
assertions with an LLM. Both read the execution host's `OPENAI_API_KEY`
(required; readiness names it when missing) and optionally
`OPENAI_BASE_URL`, `TAU2_USER_MODEL` (default `gpt-5.2`, as on
taubench.com), `TAU2_USER_REASONING_EFFORT` and `TAU2_NL_ASSERTIONS_MODEL`,
in every authentication mode; a suite's `required_env` and `host_env` in the
catalog name them and SSH executors receive them like an adapter's
`HOST_ENV`. Scores with another user model are not comparable with the
public board. A launch is refused when the agent's key variable is one of
these names (the worker replaces it with the run's relay placeholder, which
the simulator would then receive); give the provider another `key_env`.

`frontier-harness-eval-1.1` is the pinned task set of the
[FrontierHarness Eval](https://frontierharness.org/) leaderboard (a Hub
dataset whose 62 tasks are named `terminal-bench/<name>`). The workbench runs
it on its own Docker executors with the chosen model, so scores are for
internal comparison: leaderboard results use Runta runtimes, the five Baseten
models at effort `max` and 4 attempts per task
([frontier-harness-eval/eval](https://github.com/frontier-harness-eval/eval/tree/release/v1.1)).

`bench prepare --suite gaia2-cli` needs no manual steps on the workbench
machine: it fetches Harbor v0.26.0 at its pinned commit
(`3cb627394b95d3ae605f31e0d694edf508cf4b7b`, a shallow fetch of exactly
that commit with HEAD verified) into `<state root>/bench/sources/harbor-<commit>`,
reused afterwards, and runs Harbor's `adapters/gaia2/run_adapter.py --cli`
there with the workbench's `uv` (`uv run --frozen --no-dev --extra
huggingface`) against the public Hugging Face dataset
`meta-agents-research-environments/gaia2` at a pinned revision. It needs
`git`, `uv` and access to Hugging Face (`HF_ENDPOINT` selects a mirror);
readiness names whichever is missing. A top-level `pypi_index` in
`workbench.json` makes uv resolve from that mirror (`UV_DEFAULT_INDEX`,
without `--frozen`, since the lock names pypi.org files).
`METACODES_BENCH_HARBOR_SOURCE` still selects an existing Harbor checkout,
and `metacodes bench --dataset gaia2-cli=<dir>` registers a directory
generated elsewhere. The full set is 800 tasks (160 per config:
`execution`, `search`, `adaptability`, `time`, `ambiguity`), named
`gaia2-<config>-<row>-<scenario id>`, about 2.1 GB (2.5–2.7 MB per task,
mostly `environment/scenario.json`); generation takes about 100 seconds
once the dataset is cached. `"prepare": {"gaia2-cli": {"configs": [...],
"limit": N}}` in `workbench.json` narrows it (the adapter's `--configs` and
`--limit`). A prepared dataset carries a marker and is not regenerated while
its options and task trees match. The default sample is the first scenario
of each config.

GAIA2's verifier is an LLM judge (Harbor's `tests/llm_judge.py`, OpenAI
Chat Completions through the `openai` SDK). With Metask authentication it
goes through the run's credential relay, like the agent: Harbor passes the
verifier (`--ve`) `OPENAI_BASE_URL=<relay>/bench-judge/v1`,
`OPENAI_API_KEY=${METACODES_BENCH_JUDGE_TOKEN}` (a run-scoped judge
placeholder in Harbor's environment, distinct from the agent's),
`JUDGE_MODEL=<model>` and `SSL_CERT_FILE=/usr/local/share/metacodes-bench/ca-bundle.pem`,
the system CA bundle plus the relay's ephemeral CA that the metacodes agent
writes when it installs (the verifier runs in the same `main` container; the
SDK's httpx client trusts certifi only, unless `SSL_CERT_FILE` names a
bundle). The relay accepts the judge placeholder only on that route and
only for `POST /v1/chat/completions`, refuses the agent's placeholder there,
forwards to the Metask gateway with the real, refreshing credential, and
does not record judge requests as agent metrics. `OPENAI_API_KEY`,
`OPENAI_BASE_URL` and `JUDGE_MODEL` of the service environment are removed
from Harbor's environment for such a run, so no real key reaches the task.
The model is `"judges": {"gaia2-cli": {"model": "<id>"}}` in
`workbench.json`, default `glm-5.3-flash` (the gateway's bare model id; a
`metask/` prefix is dropped); a launch is refused when the account's model
directory does not list it. The run record and the job view show the judge
(`judge: {"model", "via": "metask"}`). Scores judged this way are not
directly comparable with Harbor's published GAIA2 CLI numbers, which use
`openai/gpt-4o-mini`. With provider authentication the judge keeps the
external route: `OPENAI_API_KEY` (and optionally `OPENAI_BASE_URL`, default
OpenRouter, and `JUDGE_MODEL`, default `openai/gpt-4o-mini`) in the
execution service's environment, forwarded to SSH executors as `HOST_ENV`;
readiness requires `OPENAI_API_KEY` only in that mode.

The harbor-local adapters download pinned sources (verified by hash) into
`<dataset>/.cache/` on `bench prepare --suite <id>` and write Harbor task
directories beside it; see the
[adapter README](../scripts/eval/harbor/adapters/README.md) for sources,
graders and what only a Docker host can check. A suite's `arch` (from the
adapter's `SUITE`) is listed in the catalog and on the page.

### Pre-pulling and pre-building task images

A task whose `task.toml` names a prebuilt image (`[environment]
docker_image`, as every Terminal-Bench task does) runs in it, and Harbor
pulls it only when the executor's Docker does not have it. Every other task
(AIME and the harbor-local suites) is built by Harbor from its
`environment/` directory with `docker compose build` before each trial,
which pulls its base image and runs its `apt-get`/`pip install` steps
unless Docker's build cache already holds them. A registry or package index
that is slow or unreachable during a run then fails trials as
`EnvironmentStartTimeoutError` or a `docker compose` error.
`metacodes bench pull` does both ahead of the run:

```sh
metacodes bench pull --suite terminal-bench-2.1 --executor relay-4090 --dry-run   # what is not ready
metacodes bench pull --suite alfworld --executor relay-4090                       # pull and build
metacodes bench pull --suite terminal-bench-2.1 --task fix-git --task regex-log --json
```

It runs on the workbench machine. Registry suites are read from the same
download a run uses (`<state root>/bench/registry-cache/`), harbor-local
suites from their prepared dataset. It first runs `docker info` on the
executor and stops with its error when Docker cannot be reached. The images
a task names are its own (`[environment] docker_image`), every other
`docker_image` of its `task.toml` (a separate verifier's
`[verifier.environment]`, as in the FrontierHarness tasks), and the
`image:` of the services in `environment/docker-compose.yaml` that have no
`build:` (sidecars). A named
image is checked with `docker image inspect` (over SSH for an SSH executor)
and pulled only when missing; an executor's `ghcr_mirror` is used for
`ghcr.io` images, which are then tagged back, and `docker_mirrors` apply
through its Docker daemon. Tasks to build are grouped by the content of
their `environment/` directory, and each distinct one is built once the way
Harbor builds it: the same build-only compose service (context
`${CONTEXT_DIR}`) plus the task's own `docker-compose.yaml` and its sidecar
services, tagged `metacodes-prebuild-<digest>` so the layers are kept. On an
SSH executor the directory is first copied to
`<state_dir>/prebuild/<digest>/environment/` (beside its copy marker, not
inside the build context). Harbor's later build of the same task
then takes every step from the build cache, without network access. Pulls
and builds are tried up to 3 times with a backoff. `--dry-run` only
inspects (a build counts as ready when its tag exists). Without `--task`
every task of the suite is covered. WorkBuddy suites prepare their own
environments and are refused. The summary also counts the tasks whose
images are all present (`tasks: {total, ready}` in `--json`). The exit
status is 1 when any image could not be pulled or built.

### Preparation ahead of the queue

A run also prepares each task by itself, shortly before its turn, so a run
started without `bench pull` does not pay for every image inside a trial.
The trial queue hook the metacodes agent installs in Harbor
(`scripts/eval/harbor/live_concurrency.py`, with the queue in
`scripts/eval/harbor/trial_lifecycle.py`) gives every trial three stages:

1. **排队**: the trial waits. Slots go to the trials in the order Harbor
   submitted them, oldest first.
2. **准备**: once the trial is among the next wave (as many waiting trials
   as the profile's concurrency), the hook does for its task what
   `bench pull` does, on the machine Harbor runs on: every image the task
   names (its `docker_image`, a separate verifier's image and the images of
   its compose sidecars) is checked with `docker image inspect` and pulled
   only when the local image store lacks it; a task built from `environment/` is built under its
   `metacodes-prebuild-<digest>` tag unless that tag exists. Pulls and builds
   are tried up to 3 times. At most 4 of these run at once, and trials that
   need the same image or build wait for one operation. The task's clock
   starts here.
3. **运行**: the trial takes its slot. When its preparation finished earlier
   it starts at once (就绪等待 is the time in between; after a preparation
   that failed the same wait is 准备失败后等待, and Harbor pulls or builds
   again once the trial starts). When its turn comes
   while it is still preparing, it keeps preparing inside its slot (开始后准备)
   and starts when that ends; the first wave of a run always does.

Preparation never decides a trial's result: when it fails, or the task has
no local directory (a `-d` registry run on the local executor), Harbor
starts the environment itself as before, and the failure is recorded beside
the trial, not as its outcome. A WorkBuddy run drives its own Harbor and has
no such stages.

Each trial's stages are in `<job>/.bench-lifecycle/<trial>.json`, rewritten
at every transition: `queued_at`, `prepare_started_at`,
`prepare_finished_at`, `started_at` (the slot), `finished_at`, and `prepare`
with its `status` (`present` when everything was already there, `prepared`,
`failed`, `skipped`) and one item per image (`kind` `pull` or `build`,
`image`, `status` `present` / `pulled` / `built` / `failed`, `seconds`,
`attempts`, `error`, and `shared` when the trial waited for another trial's
operation). A trial's row in `GET /api/job` and `GET /api/trial` carries
`lifecycle`: `queue_s`, `prepare_s` (预准备, before the slot),
`ready_wait_s` (from a preparation that left everything ready to the slot),
`unprepared_wait_s` (the same wait after a preparation that failed: the
page says so, and that Harbor pulls or builds again once the trial starts),
`prepare_running_s`, `total_s` (from the start of
preparation, or from the slot when there was none, to the end) and
`prepare`; it is `null` for a trial without a record. `elapsed_s` and
`phases` keep their meaning (Harbor's own trial).

### Adding a harbor-local suite

An adapter is `scripts/eval/harbor/adapters/<name>.py`, registered by an entry
in `ADAPTER_SUITES` (its id and category are authoritative) and listed in
`scripts/bench_assets.zig` so the binary carries it. It exposes:

```python
SUITE_ID = "humaneval"                                 # the catalog id
SUITE = {"name": "HumanEval", "description": "…", "default_tasks": [...],
         "max_tasks": 164, "max_concurrency": 4, "arch": "amd64, arm64"}  # all optional
HOST_ENV = ("OPENAI_API_KEY",)        # optional: verifier env, forwarded to SSH executors
JUDGE = {"default_model": "glm-5.3-flash",            # optional: an OpenAI-compatible LLM
         "env": {"api_key": "OPENAI_API_KEY", "base_url": "OPENAI_BASE_URL",   # judge, routed
                 "model": "JUDGE_MODEL", "ca_file": "SSL_CERT_FILE"}}  # through the relay (Metask)

def prepare(dest: Path) -> Path:      # or prepare(dest, ctx): ctx.cfg, ctx.root (bench state)
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
`.venv`, the workbench's Linux bundle (the same one Harbor suites run), the
subset fetched by WorkBuddy's `scripts/dataset/fetch-dataset.sh`, Docker,
`uv`, `bash`, and Metask account authentication. A launch stages the run's bundle with
`stage_artifacts` into a build context of its own, builds the split-mount
image under the run's tag (removed afterwards), writes a transient
`configs/models|jobs/metacodes-<run>.yaml` (removed afterwards), runs
`uv run --frozen bash scripts/run.sh --job metacodes-<run>` in the checkout
with the account key in a dedicated variable and the judge key removed, and
sets the job's `jobs_dir` to `<jobs-dir>/<run>/workbuddy`, whose Harbor
trials the job view reads. These are ordinary WorkBuddy runs, not
launch-gate receipts or quality evidence. The Web and Office subsets also
write a judge model config (`configs/models/metacodes-<run>-judge.yaml`, same
account key as the agent; WorkBuddy calls its judge as OpenAI passthrough, so
the config's URL variable holds the account gateway's `/v1` rather than the
agent's `/v1/messages`) and set the job's `llm_judge_override` to
`{"enabled": true, "mode": "in_container"}` with it. The judge model is
`judges.<suite id>.model` in `workbench.json`, default `kimi-k3.1-pro`.

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
(`{"executor": NAME, "dry_run": bool}`) has the same same-origin rule as
`/api/runs`. Setup refuses to run while a benchmark is
active, because it may restart Docker, and a launch is refused while a setup
that is not a dry run is in progress; the service checks both under one lock.

| Step | What it does |
|---|---|
| SSH access (`ssh` executors) | Runs a probe over `ssh -o BatchMode=yes`; if the key cannot run commands, it stops here and says so |
| Python 3.9+ (`ssh` executors) | Needed by the executor's `metacodes bench` |
| 网络与镜像 (`ssh` executors) | Probes `pypi.org`, `registry-1.docker.io`, `ghcr.io` and `github.com` from the executor (8 s timeout; over 5 s counts as slow) and fills in what is missing from the entry: `pypi_index`, `docker_mirrors`, `ghcr_mirror` and `"egress": "workbench"` (see [Network-restricted executors](#network-restricted-executors)). A value already in the entry is never replaced; a dry run lists the proposed changes |
| uv | macOS: `brew install uv` when Homebrew exists; otherwise (and on Linux) the official installer pinned to uv 0.13.9 into `~/.local/bin` |
| Harbor | `uv tool install --force --python 3.12 harbor==0.26.0` (Harbor 0.26 needs Python 3.12; with an executor's `pypi_index`, prefixed by `env UV_DEFAULT_INDEX=<index>`); the resulting path is saved |
| Docker | macOS: Homebrew `docker docker-compose docker-buildx colima`, the plugin directory in `~/.docker/config.json`, then `colima start` (see [Colima](#colima-on-apple-silicon)); Linux: `get.docker.com` with passwordless sudo, otherwise the command for the user; also starts the daemon, adds the user to the `docker` group and installs the compose and buildx plugins when needed |
| Docker 镜像加速 (`ssh` executors) | With `docker_mirrors`: merges them into `/etc/docker/daemon.json`'s `registry-mirrors` (other keys kept) through `sudo -n`, then `sudo -n systemctl reload docker` (reloadable; Docker is never restarted). Without passwordless sudo the step prints the exact command |
| apt 缓存（任务容器） (`ssh` executors) | With `container_mirrors.apt`: builds `metacodes-apt-cache` and runs it on `<metrics_bind>:3142` with `--restart unless-stopped`, then checks that it answers; a running cache with the same mirror is kept (see [Package mirrors and the apt cache](#package-mirrors-and-the-apt-cache-in-task-containers)) |
| 下载缓存（任务容器） (`ssh` executors) | With `download_cache`: builds `metacodes-download-cache` and runs it on `<metrics_bind>:3143` with `--restart unless-stopped`, one route per cacheable `container_mirrors` key, then checks that `/_stats` answers; a running cache built from the same script and routes is kept (see [The download cache](#the-download-cache)) |
| OpenSSL | Generates a throwaway certificate exactly as the timing relay does |
| Linux bundle | See [the release bundle](#the-linux-release-bundle) |
| metacodes 节点 (`ssh` executors) | Ships the bundle (below) and runs its `metacodes bench node info` by the bundle's own path; only when that node speaks the workbench's protocol is `<state_dir>/bin/metacodes` switched to it (atomically), and `~/.local/bin/metacodes` linked to that entry when the name is free. A failed check leaves the installed node in place (see [Bench nodes](#bench-nodes)) |
| 正在运行的评测（换用新驱动） (`ssh` executors) | Runs `metacodes bench node upgrade <state_dir>/runs` with the node just installed: every run going on there is handed to a driver of that version without stopping it (see [Updating a node under running runs](#updating-a-node-under-running-runs)). A run whose driver predates this, or one the handoff fails for, goes on with its own driver, and the step says so |
| 容器出网（经工作台） (`ssh` executors) | With `egress` other than `direct`: a container on a fresh user-defined Docker network fetches the workbench proxy's probe page through the forwarder and `ssh -R` (workbench mode), or connects to the site proxy. A tunnel port the executor cannot listen on is retried on another one, up to 5 ports, and then the step says the tunnel port could not be bound; any other failure names the gateway and the firewall to check |
| 工作台 Harbor (`ssh` executors) | Harbor on the workbench machine itself, which downloads registry suites for SSH executors; installed with the local `uv` when missing, otherwise the command is reported |
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

### Building any git revision

The overlay above keeps a release's Lean kernels. To evaluate an exact
revision with its own kernels, build its full release unit:

```sh
metacodes bench build --ref main          # a branch, tag or commit
metacodes bench build --ref 54a7a632 --json
metacodes bench build --ref main --executor relay-4090
```

The build runs on the node of the executor (`--executor`, default the
default executor), the machine whose Docker also runs the evaluations;
every node builds the same way. For an `ssh` executor the workbench runs
`metacodes bench node build` there over SSH (the request on stdin, the build
log on stderr, the result as the last stdout line; closing stdin cancels
it), then copies the unit and its build record into its own
`<state root>/bench/bundles/`, accepting only regular files and directories
under the unit's name and only a record verified by the same `source_repo`.
The page does the same from 新建 → 按 commit 编译: it lists a branch's
commits with their commit time, newest first, up to a chosen day
(`GET /api/commits?ref=&until=YYYY-MM-DD&limit=`), and builds the chosen one,
or any pasted commit, branch or tag, in the background (`POST /api/build`
`{ref, executor}`, `GET /api/build` for its status and log tail,
`POST /api/build/cancel`), one build at a time. A built unit is named in the
version list by its commit and commit time.

The node needs Docker; the workbench machine does not. On each node the ref
is resolved in a mirror of `source_repo` (in `workbench.json`; default the
GitHub repository) kept at `<state root>/bench/git/source.git`, and a branch
always means its current head. A branch and a tag of one name on different
commits are refused; write `refs/heads/<name>` or `refs/tags/<name>`. Only a
commit on one of that repository's branches or tags is built, because the
binary later runs with the execution machine's model credential: code that
only a pull-request or other foreign ref names is refused until it is pushed
to a branch.

The build runs as the caller's user in `linux/amd64` containers, in two
steps, the way `release.yml` does. A script owned by the workbench first
installs the Zig version the revision's `build.zig.zon` names, checked against
ziglang.org's SHA-256, and the Lean toolchain its
`control-plane/lean/lean-toolchain` names, through a SHA-256-pinned elan, into
`<state root>/bench/git/toolchains/`; each is staged on that filesystem and
renamed into place only when complete, so an interrupted install is redone.
Downloads and git transfers are retried. The revision's own build then runs
with those toolchains mounted read-only and its checkout and caches in a fresh
temporary directory: `kernels:stage`, the kernel pins, and `release:verify`
for `x86_64-linux-gnu.2.31`. The container never sees the mirror or its
remote URL: the host exports the commit and the tags that point at it as a
`git bundle`, mounted read-only, so a stable version's manifest finds its
release tag and a token in `source_repo` stays on the host.

The unit is published as `<state root>/bench/bundles/metacodes-git-<commit>-x86_64-linux-gnu/`,
where the 评测 page offers it as a profile version like any other bundle, but
only while the configured `source_repo` is the repository that verified it
under the current trust rule: after switching repositories, a unit appears
again once `bench build` has re-verified its commit, and a profile cannot be
created from one that is not listed. The same check covers the bundle a run
actually uses: a single run (`bench run`) refuses a configured default
bundle that is such an unverified unit before recording anything, and a new
profile validates its datasets against the bundle it selected, so a
workbench whose only versions are verified git builds can run profiles
without a default. A single run resolves, checks and freezes the default
bundle from one reading of `workbench.json`, by its resolved path. A profile
keeps the git provenance of the bundle it froze (commit, repository digest, trust rule); each dataset
checks the frozen copy against that record and the current `source_repo`, so
it still runs after the original unit is removed and stops before recording
anything once the repository no longer matches. A
build record beside it names the commit and identifies the repository only by
a digest of its URL; git errors are printed with URL credentials removed. A
full commit id that the configured repository already verified is reused
without contacting it; after switching `source_repo`, or for a record
without that proof, the commit is checked again, and a unit without a record
from this builder is rebuilt. Fetching, installing, building and publishing
hold a lock on `<state root>/bench/git/`, so services sharing a state root
take turns. Ctrl-C stops git or the build container. Progress and build logs go to
stderr, so `--json` prints a single JSON document on stdout. The first build
downloads both toolchains (Lean is about 250 MB); later builds of the same
toolchain versions reuse them.

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
key and checks that it still provides that model; the run then uses it
through the credential relay described below. The CLI's selected key/model
remain unchanged. Only non-secret key ids enter run specs; API keys, access
tokens and OAuth refresh tokens never enter workbench settings, job specs,
run records or the browser.

The 0.12 account OAuth token is refreshed through its own token endpoint
before expiry (or once after a rejected access token). Bench catalog reads
and workers serialize refreshes with a file lock and persist rotated tokens
atomically with private permissions, preserving login preferences. A plain
API-key login without account OAuth can list only that key's models; the page
states this scope and suggests completing account login for all model groups.

### Credential flow and token refresh

Task containers run model-controlled agents, so they never receive a real
credential. Each run gets a random run-scoped placeholder
(`mcb-<run>-<32 random bytes, base64url>`), which Harbor passes as
`METASK_API_KEY` (or the provider's `--key-env` variable) with `--ae
NAME=${NAME}`. Every Harbor run has a credential relay on the Docker host;
the agent's base URL points at it (HTTPS with an ephemeral CA, see
[Metric definitions](#metric-definitions)). The relay accepts only that
placeholder, compared in constant time; a missing or wrong one gets 401 and
is never forwarded. It forwards each request upstream with the current real
credential in the route's header and prefix (`Authorization: Bearer`, an API
key header, or a custom header). Capturing timing metrics is optional on top:
with `metrics_enabled: false` the relay still proxies authentication and
records nothing.

A route the relay cannot forward is refused at launch (and shown as a
readiness reason) rather than handing the container the key: a third-party
provider needs `--provider-config` whose `custom_providers` entry uses
bearer, `api_key_header` or `custom_header` authentication, and whose
channels all use `anthropic_messages`, `openai_chat` or `openai_responses`
with one origin and a base path of `/` or `/v1`. WorkBuddy suites keep their
own design: WorkBuddy's host proxy holds the account key, and its task
containers receive only that proxy's route token.

A current Metask session login (`oauth/metask.json`) has an access token of
about an hour and rotating refresh tokens. The refresh token stays on the
machine that logged in; the relay's credential is refreshed there:

- proactively, once the access token has less than 15 minutes left (about
  45 minutes into a one-hour token), by a background check every 30 seconds
  and before any relay request;
- on demand, when the gateway answers 401: the relay refreshes once and
  repeats that request (nothing has been sent to the container yet).

Refreshes take the state directory's lock, re-read the session file and
persist the rotated pair atomically, so the CLI and catalog reads on the
same state directory follow the rotation and a rotated refresh token is never
reused. Legacy account group keys and provider keys do not expire: they are
never refreshed, with the same placeholder isolation.

The run record carries a secret-free `credential` object: `container:
"placeholder"`, `refreshing`, and for a session `refresh_count`,
`last_refresh_at`, `expires_at` and `error`. When the refresh endpoint rejects
the login (for example after signing out elsewhere), or the token expires
while the endpoint stays unreachable, the run stops at once instead of
spending its remaining tasks on 401s: it ends `failed` with `error` (and
`credential.error`) set to `Metask 登录已失效，请重新登录（metacodes login）后再运行评测`.
A temporary refresh failure keeps the current token and retries after 30
seconds.

Two deployments keep the refresh token on a single machine:

- **Option A — run the workbench on the Docker host.** Install `metacodes`
  on the Linux machine that runs the trials, run `metacodes login` there and
  start `metacodes bench` there (see [Devbox and remote access](#devbox-and-remote-access)
  to reach its page). The local executor's relay refreshes from that
  machine's own login.
- **Option B — an SSH executor.** The workbench machine keeps the login and
  refreshes it; the execution host receives only access tokens on the SSH
  channel's stdin (see [How an SSH run works](#how-an-ssh-run-works)). Its
  files, process arguments and environment never contain a token.

For a workbench whose files live under a separate state directory, select
the install that is already logged in explicitly:

```sh
metacodes bench --auth metask --account-state-dir /path/to/logged-in/state
```

An existing third-party setup remains explicit and independent. Switch it
back with `--auth metask`; the third-party configuration will not be used
for account runs. To use a gateway instead:

```sh
export GW_API_KEY=...                   # or this install's state-root/.env
metacodes bench --bundle /path/to/linux-release --auth provider
```

Without `--provider-config` the workbench reuses MetaCodes' own
configuration (`METACODES_CONFIG_FILE`, else `config.json` in the state
root the workbench was started with): its `custom_providers` models are the
models offered, and only that section is passed to a run. Each provider's
canonical `api_key` entry in `env_aliases` names its key variable.
`--provider-config /path/to/config.json` selects another native metacodes
configuration with `custom_providers`; see
[the Harbor adapter](../scripts/eval/harbor/README.md). `--model` picks the
default model and `--key-env` overrides the key variable; that key is never accepted as a
browser field or stored in a run specification (an imported provider's key
is, once; see below). The relay holds the key;
Harbor's `${VARIABLE}` reference carries only the run's placeholder. The
installed service inherits its startup environment, so restart the service
after changing a credential.

### Imported providers (URL + API key)

Any number of OpenAI- or Anthropic-compatible endpoints can be imported
next to the Metask account (or a `--provider-config` setup) and used for
runs. Their models appear in the model list as `<id>/<model>`. Import them
on the page's 模型 tab or from the CLI on the workbench machine:

```sh
export GW_KEY=...                        # or omit --key-env and type it
metacodes bench provider add --id gw --base-url https://api.example.com/v1 \
  --protocol openai_chat --key-env GW_KEY --probe   # models from /models
metacodes bench provider add --id claude --base-url https://api.example.com \
  --protocol anthropic_messages --provider-model claude-opus-5-5 --key-env GW_KEY
metacodes bench provider list
metacodes bench provider probe --id gw --model gw/glm-5.3   # exit 1 on failure
metacodes bench provider remove --id gw
```

- **Base URL**: `http(s)://host` or `http(s)://host/v1` (a pasted
  `/chat/completions`, `/responses` or `/messages` URL is trimmed). Other
  paths are refused because the run's credential relay forwards to one
  origin. Protocols: `openai_chat`, `openai_responses`,
  `anthropic_messages`; the key goes in `Authorization: Bearer` or
  `x-api-key` (`--auth-header`; Anthropic defaults to `x-api-key`).
- **Models**: `--provider-model` (repeatable) or, when omitted, the
  endpoint's `/models` list.
- **Key**: from `--key-env` or stdin, never argv. Kept only in
  `<state root>/bench/providers.json` (mode 0600). The page accepts it once
  in the import form and never shows it again (only its last four
  characters). A run of an imported model gets a generated provider config
  that names the variable `METACODES_BENCH_PROVIDER_KEY` but holds no key;
  containers hold the run's placeholder and the relay sends the key
  upstream, as with `--provider-config`. The generated config uses the
  internal provider id `bench-<id>` (a config may not take a built-in
  vendor's id, so `--id openai` still works); Harbor job configs show that
  id. `--replace` updates an entry and keeps the saved key when none is
  given, but only while the Base URL keeps its scheme, host and port: a new
  origin needs the key again, so a saved key is never sent elsewhere.
- **Edits and queued runs**: every change of URL, protocol, auth or key
  gives the entry a new revision. A run records the revision its config was
  generated from; if the entry changed before its worker starts, the run
  fails with a message instead of pairing the old upstream with a new key.
  A queued dataset pins its model's route (source and revision) when it is
  queued; if the model resolves elsewhere by its launch, it fails with a message. Two
  concurrent edits of one entry (page and CLI) cannot undo each other: an
  update based on a revision that changed meanwhile is refused.
- **Ids**: `metask` and the provider ids of the workbench's
  `--provider-config` cannot be imported, so one model id never names two
  routes (a clash introduced later by changing `--provider-config` hides
  the imported models and shows a warning).
- **Probe**: sends one real request asking the model to reply with a fresh
  random string (`mc-echo-…`) and passes only when the decoded reply text
  is exactly that string (any extra character fails, whitespace and
  newlines included). The result (reply, HTTP status, latency) is
  stored per model and shown on the 模型 tab; the model list shows only
  pass/fail. Changing the URL, protocol or key clears it. Probing is not
  required to run.
- **Limits**: imported models run Harbor suites on local and SSH
  executors. A Base URL that reaches the workbench itself (`localhost`, a
  loopback or unspecified address, IPv4-mapped included, or a name that
  resolves to one, such as an `/etc/hosts` alias) is refused on SSH
  executors: the workbench probed it on its own machine, but the executor's
  relay would read it as the executor itself. The check runs when a
  dataset is queued, at launch on the exact route written to the run, and on the
  executor against its own resolution before the relay connects. Import an
  address both machines reach for the same gateway instead. WorkBuddy suites refuse them. A suite with an LLM judge (GAIA2)
  refuses them under Metask authentication, where the judge would go
  through the run's relay to the imported upstream; under `--auth provider`
  its judge reads the execution host's variables as for `--provider-config`
  and the run is allowed.
- HTTP: `GET /api/providers`,
  `POST /api/providers` (`id`, `base_url`, `api_key`, optional `name`,
  `protocol`, `auth`, `models`, `replace`, `probe`),
  `POST /api/providers/probe` (`id`, `model`), `POST /api/providers/remove`
  (`id`). The running service sees CLI changes on its next page refresh.

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
(default `python3`), `metrics_bind` (default `172.17.0.1`),
`metrics_enabled`, and the network settings `egress`, `egress_ports`,
`pypi_index`, `docker_mirrors`, `ghcr_mirror`, `container_mirrors` and
`download_cache` (see
[Network-restricted executors](#network-restricted-executors)). Names, hosts, users and paths are validated before any
`ssh` argv is built; unknown fields are refused. `harbor` and `python` may
contain spaces and `@` (a home directory can), since they only travel as one
argv word; `state_dir` may not. Setup saves a Harbor path only when the entry
still validates afterwards, and otherwise says to set it by hand. A malformed
entry is shown as not ready with its reason and leaves the other executors
usable. Readiness probes are cached for 15 seconds.

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

### Bench nodes

For ordinary conversations and Bench runs started independently on a node,
the manager can keep a certificate-verified HTTPS model connection open between runs with
`metacodes bench share --executor NAME --peer-env FILE`.
[Pairing a node](PROVIDERS.md#using-a-managers-login-on-an-ssh-node)
also covers the node's provider setup and stopping the share.

Every machine with `metacodes` installed is a Bench node. A workbench drives
an SSH executor the way an editor drives a remote host: it runs that host's
own `metacodes bench node …` over SSH and talks to it on the channel's stdin
and stdout. Nothing else runs on the executor; the bench runtime is the one
its `metacodes` carries. The node is `<state_dir>/bin/metacodes` (setup's
entry), else a `metacodes` on the executor's PATH; it starts `bench` with the
entry's `python` (as `METACODES_BENCH_PYTHON`). The readiness probe and every
node command resolve it the same way.

- `node info --json` is the node describing itself: its version, the node
  protocol, host name, OS and architecture, and the WorkBuddy suites
  prepared on it (each suite's readiness there and its task ids). The
  readiness probe asks for it on every check (cached 15 seconds), so the page
  labels the executor with the node's version (`relay-4090（SSH …） ·
  metacodes 0.12.1`). A node that is missing, or speaks another protocol, makes
  the executor not ready, naming `metacodes bench setup --executor NAME`.
- `--peer NAME` on `info` names the workbench asking; the node remembers it
  in `<its state root>/bench/peers.json`. `node peers` lists both
  directions: the SSH executors this node's own `workbench.json` drives and
  the workbenches that drove it. Either side can therefore see the other,
  even when only one of them can open an SSH connection.
- `node run <spec>` executes one run. `node results` publishes aggregates
  and answers job, trial and log queries. `node manifest` and `node pack`
  support recovery of older runs. Setup uses `node egress-probe` to check container networking.

A node keeps its own state root (`~/.metacodes` by default) and
`workbench.json`. What is prepared on the node itself is read from there:
a WorkBuddy checkout set with `metacodes bench --workbuddy-checkout <dir>`
on the node (or `METACODES_WORKBUDDY_CHECKOUT`) makes the WorkBuddy Code
and Security suites ready on that executor, with the node's own task list.
The credential always comes from the workbench driving the run.

### How an SSH run works

The local worker stays the durable owner of the run: it resolves the
account (or provider) credential exactly as for a local run, and keeps
refreshing a session login, then

1. resolves the node `<state_dir>/bin/metacodes` points at (the physical
   path inside `<state_dir>/bundles/<digest>`) and runs every node command
   of the run (`run`, `results`) with that binary, so a
   `metacodes bench setup --executor` that switches the node mid-run does
   not change the driver under a running job; a run without a node stops
   here. It then ships the Linux bundle the run evaluates as a tar stream
   over SSH into `<state_dir>/bundles/<digest>`, once per content digest
   (complete directories are marked and reused);
2. uploads the run's secret-free spec (and provider configuration, if any) to
   `<state_dir>/runs/<name>/`;
3. starts `<state_dir>/bin/metacodes bench node run …` over SSH and
   writes the secrets as the first line on the SSH channel's stdin:
   `{"env": {"METASK_API_KEY": "<placeholder>", …}, "credential": "<access token or key>"}`.
   `env` goes to Harbor's environment (`--ae NAME=${NAME}` as locally), so
   Harbor and the containers hold only the placeholder; `credential` stays in
   the driver's memory for its relay. Neither is in argv, in a file, or in
   the SSH command line. `SendEnv` is not used because it needs the server's
   `AcceptEnv`. Each refreshed access token follows as another line,
   `{"credential": "<new access token>"}`; the remote relay swaps it in
   atomically (and answers with a secret-free `{"event": "credential",
   "pushes": N}`). If a push fails, the remote relay keeps the previous
   token until it expires. The refresh token never leaves the workbench
   machine;
4. the driver starts the credential relay next to the remote Docker daemon
   (on the executor's `metrics_bind`; the executor's `metrics_enabled:
   false` turns off only the metrics capture), runs Harbor in its own
   process group and reports heartbeats. Harbor's output stays on the worker;
5. the worker indexes job files into its configured SQLite or PostgreSQL
   database. Every ten seconds the manager requests job and per-task
   aggregates, including outcome counts, scores, usage and timing
   distributions. It persists these with the launch receipt. The dashboard
   and leaderboard can show the last received aggregates while the worker is offline;
6. after Harbor exits the manager requests a final verified summary.
   If delivery fails, the receipt identifies the executor and job directory.
   `metacodes bench sync --run NAME` retries delivery. An older SSH run with
   an existing manager-side mirror verifies and repairs its files in place.
   If the manager has already archived the completed mirror in its active
   database and cleared the directory, sync keeps the archive readable offline.
   An older receipt without a mirror can fetch a summary from an upgraded worker.

Suites on an SSH executor: a `harbor-registry` suite is always downloaded on
the workbench machine (its own Harbor, `harbor download <ref> -o <dir>`), so
the executor never needs to reach GitHub or the Harbor Hub. The download is
cached per reference in `<state root>/bench/registry-cache/<sha256(ref)[:16]>/`
(written atomically, with a marker of its task count; every task id the
catalog lists for the suite must be present, otherwise the run is refused
and nothing is cached), shipped like a local dataset into
`<state_dir>/datasets/<digest>`, and run with `-p`. Harbor names a `-p`
task by its directory name, which the export layout makes the bare task id,
so the `-i` filters drop the Hub's `org/` prefix (`terminal-bench/fix-git`
under `-d` becomes `fix-git`). Readiness of registry suites on SSH executors
includes the workbench machine's Harbor. A `harbor-local` suite's dataset
directory is generated on the workbench's machine (`bench prepare`, or
`--dataset SUITE=DIR`) and shipped like the bundle, into
`<state_dir>/datasets/<digest>`, once per content digest; Harbor's `-p` then
names that copy. Execution-host variables a suite's verifier reads (GAIA2's
`OPENAI_API_KEY`, `OPENAI_BASE_URL`, `JUDGE_MODEL` with provider
authentication, declared by the adapter's `HOST_ENV`) travel with the
credential on the SSH channel's stdin. With Metask authentication GAIA2's
judge uses the executor's relay instead: only its placeholder travels on
stdin (beside the agent's), the remote driver adds the `--ve` arguments once
its relay listens, and the session login's pushed token serves the judge
too (a legacy group key for the judge model, when it differs from the run's,
is sent once on the same line). A WorkBuddy
suite on an SSH executor runs on the node's own checkout: the workbench
validates the tasks against the list the node reports and copies the job
back like a Harbor run. Its readiness there is reaching a compatible node,
Metask authentication and what the node reports for the suite (an executor
without the Harbor CLI still runs WorkBuddy, which brings its own, but it
needs `docker buildx`). The workbench ships the run's bundle to the node
like a Harbor run's; the node stages its `metacodes`, TinyKG, formal kernel
and ripgrep with `stage_artifacts` into a build context of its own, never
the checkout's `docker/artifacts`, and builds the split-mount image under a tag of
the run's own (`wbm:<first 12 hex of sha256(run name)>`, short because Docker names an image mount's directory after the hex of image id, reference and target, which must fit in 255 bytes) and
names it in a transient harness version (the pinned `0.1.0.yaml` plus
`mount.images.local`), which the run's job uses. The shared tag WorkBuddy's
`run.sh` would otherwise reuse, and another workbench on the same Docker
daemon could move, never reaches the trials. The run's tag and version
file are removed (within 60 seconds) under heartbeats before the node
reports the run's end. The build sends heartbeats like a running Harbor,
and a cancel (or a closed channel) kills it and ends the run. WorkBuddy's host proxy is given a run-scoped placeholder and a
loopback relay on the node; the relay forwards with the access token from
the stdin line and swaps in each refreshed one, as for Harbor runs. The node
removes its transient WorkBuddy configs afterwards.

Readiness is per suite and executor: `GET /api/workbench` lists, for every
suite, `executors.<name>.reasons` (service-wide reasons such as sign-in, the
Linux bundle and the executor's own Harbor/Docker/OpenSSL readiness for
Harbor suites, the suite's own prerequisites, and refused combinations),
plus `suite_reasons`; `ready`/`reasons` on the suite and at the top level
are those of the default executor (the top level for the default suite).

Cancel sends `cancel` on the channel: the driver interrupts Harbor (SIGINT,
then SIGKILL after 20 seconds). A login that can no longer be refreshed
cancels the same way and fails the run with the reason above.

A lost connection does not end the run. When the channel closes, or no
heartbeat arrives for 90 seconds, the worker ends that session and starts
`metacodes bench node attach <run spec>` over SSH every 10 seconds. The
driver keeps Harbor and the relay running and accepts the new session on a
Unix socket in `/tmp/metacodes-bench-<uid>/` (a directory only that user can
enter; the socket is named after a hash of the run directory). A session
lost before its first event is attached the same way, and while the driver
is still starting (its pid is in `runs/<name>/driver.pid`) `attach` exits
without an event and the worker tries again. The new session then
carries the events and control lines, the current access token, and the
egress tunnel on a fresh `ssh -R` port, which the driver's forwarder follows.
Harbor runs under a small keeper process that writes its output to
`<state_dir>/runs/<name>/harbor.log` and its exit status to `harbor.exit`
there; the driver copies that output to the attached session, and while no
session is attached its own output goes to `driver.log` there. The run's
terminal event is also kept there, so a session that attaches after Harbor exited still receives it. The
record counts the reattached sessions in `reconnects`. Both sides give up
after 30 minutes (`METACODES_BENCH_RECONNECT_WINDOW` seconds on the
workbench, which passes the value to the driver as the spec's
`detach_grace`): the driver interrupts Harbor, so a lost connection never
leaves trials running unsupervised, and the run fails with what is still on
the executor.

### Updating a node under running runs

`metacodes bench setup --executor NAME` (its 正在运行的评测 step), or
`metacodes bench node upgrade <state_dir>/runs/<name>/spec.json` run on the
executor by the newer node, replaces the driver of a running Harbor run
without interrupting it:

- Harbor stays with its keeper, so its trials go on and the new driver reads
  its exit status from the run directory.
- The relay's TLS key and CA are in `runs/<name>/relay-tls/` (owner only),
  so the CA path Harbor gave the containers stays valid. The old driver
  passes every listening socket of the run to the new one over a Unix
  socket next to the attach socket (SCM_RIGHTS): the relay, the egress
  forwarder, the attach socket and that handoff socket itself. Nothing is
  bound again, no address changes and no connection is refused, and the new
  driver serves them all before it reports the takeover. It also takes over
  the current access token, the placeholders and the request counter.
- The old driver stops accepting and finishes what it had accepted, however
  long it takes: TLS handshakes and requests in progress (a streaming model
  response completes), and forwarded connections until they close or the
  run ends. A keep-alive connection idle between requests is closed; a
  request that still arrives on it is not forwarded, so the client can send
  it again. Its session gets a `handoff` event, and the worker attaches to
  the new driver with a fresh token and egress tunnel port. The old driver,
  and with it the old session and its tunnel, ends only once the newest
  driver has its own tunnel (passed back along several handoffs in a row),
  so container egress has a path throughout.
- A handoff that fails before the old driver let go (another handoff
  version, the new driver dying, a run already ending or being cancelled)
  leaves the run with the old driver. Runs started by a driver from before
  node protocol 8, and WorkBuddy runs, finish with the driver that started
  them.

### Network-restricted executors

An executor that cannot reach PyPI, Docker Hub, ghcr.io or GitHub (or only
slowly) is configured per entry; `metacodes bench setup --executor NAME`
proposes these when its network probe finds those hosts slow or blocked:

```json
{"name": "relay-4090", "kind": "ssh", "host": "10.126.126.1", "user": "bench",
 "egress": "workbench", "egress_ports": [443, 80],
 "pypi_index": "https://pypi.tuna.tsinghua.edu.cn/simple",
 "docker_mirrors": ["https://docker.m.daocloud.io", "https://dockerproxy.net"],
 "ghcr_mirror": "ghcr.nju.edu.cn"}
```

| Field | Effect |
|---|---|
| `egress` | `"direct"` (default): containers use the executor's network. `"workbench"`: containers use the workbench machine's network (below). `{"proxy": "http://host:port"}`: a site proxy the containers can reach, injected the same way, without a tunnel |
| `egress_ports` | Destination ports the workbench proxy serves (default `[443, 80]`) |
| `pypi_index` | `UV_DEFAULT_INDEX` for setup's Harbor install on the executor only; it does not reach runs or the bundle |
| `docker_mirrors` | Added to the daemon's `registry-mirrors` by setup (sudo, reload, never restart). They cover Docker Hub images only |
| `ghcr_mirror` | Before each run, ghcr.io images the selected tasks name (`FROM` lines of their Dockerfiles, `image:` of their compose files, `docker_image` in `task.toml`) that are missing locally are pulled as `<mirror>/<path>` and tagged back to their `ghcr.io/` name; other registries are left alone. A failed pull is logged and Harbor pulls from ghcr.io itself |
| `container_mirrors` | Package mirrors and the apt cache for the runs' task containers (see [below](#package-mirrors-and-the-apt-cache-in-task-containers)) |
| `download_cache` | `true` puts a cache on the executor in front of those mirrors: a download goes to the cache first and to the mirror only when the cache does not have it (see [The download cache](#the-download-cache)). Only with `egress` = `direct` |

`"egress": "workbench"` builds this path for each run, and only for it:

```text
task container --HTTP(S)_PROXY--> forwarder on the executor's Docker gateway (172.17.0.1:<ephemeral>)
  --> 127.0.0.1:<tunnel port> on the executor (ssh -R of the run session)
  --> proxy on the workbench machine (127.0.0.1:<ephemeral>) --> the destination
```

- The worker starts a stdlib-only CONNECT and plain-HTTP proxy on its own
  loopback, on an ephemeral port, before the run session and stops it when
  Harbor has exited. The run's SSH session (only that one) carries
  `-o ExitOnForwardFailure=yes -R 127.0.0.1:<tunnel>:127.0.0.1:<proxy>`,
  with a random tunnel port in 20000–32767, below the ephemeral ranges of
  Linux (from 32768) and macOS (from 49152). When the executor cannot
  listen on it (the port is taken, or its sshd does not allow remote
  forwarding), ssh exits at once with 255 and `remote port forwarding
  failed`; the worker then uploads the run spec with another port and
  starts the session again, up to 5 ports, after which the run fails
  saying the tunnel port could not be bound on the executor.
- SSRF guard: the proxy connects only to globally routable unicast
  addresses. Loopback, private (RFC 1918, unique-local), link-local, CGNAT
  (100.64/10), multicast, reserved and unspecified addresses are refused
  with 403, so containers cannot reach the workbench machine's own services
  or its LAN (EasyTier included). One exception is on by default: the
  benchmarking range `198.18.0.0/15`, which fake-IP resolvers (Clash- or
  Surge-style transparent proxies, as on the devbox-mac network) hand out for
  every public name. `egress_allow` on the executor replaces that list (`[]`
  disables it); loopback, link-local and unspecified addresses are never
  allowed. Setup's 容器出网 step fetches a real outside page
  (`http://deb.debian.org/.../Release.gpg`) through the proxy, so a policy
  or resolver problem shows up there and not mid-run. A name is resolved
  once; any non-public answer refuses it, and the vetted address is the one
  connected to. Single-label names (compose service names such as
  `alfworld-env`) are refused at once with a 502 that says to put them in
  `NO_PROXY`. Only `egress_ports` are served; the proxy needs no credentials
  because only the run's tunnel reaches its loopback port. A workbench
  machine that itself needs a proxy to reach the internet is not supported.
- The remote driver starts a TCP forwarder bound only to the Docker bridge's
  gateway (docker0's address, else `docker network inspect bridge`, else the
  executor's `metrics_bind`), since containers cannot reach the host's
  loopback and sshd's `GatewayPorts` stays untouched. Containers on Harbor's
  own compose networks reach that address too. The forwarder lives exactly
  as long as the driver's Harbor process.
- The containers learn the proxy from a run-scoped Docker CLI configuration
  directory under `<state_dir>/runs/<name>/docker-config-*`, created by the
  driver, passed to Harbor as `DOCKER_CONFIG` and removed when Harbor exits.
  It holds only `proxies.default` (`httpProxy`, `httpsProxy`, `noProxy`) and,
  when it exists, `~/.docker/cli-plugins` as an extra plugin directory; the
  docker CLI then injects the proxy variables into every container and build
  of the run. Nothing is read or copied from the user's own
  `~/.docker/config.json`, so other users of the account are unaffected and
  stale registry credentials there do not apply. `noProxy` holds
  `localhost`, `127.0.0.1`, `::1`, the gateway, the timing relay's host and
  `metrics_bind` (model traffic goes straight to the relay), Harbor's `main`
  and every compose service name of the selected tasks.
- 一键配置's 容器出网（经工作台） step checks the whole path from a
  container on a fresh user-defined network.

### Package mirrors and the apt cache in task containers

`container_mirrors` on an `ssh` executor points every run's task containers
at package mirrors, and `apt` adds a shared apt cache on the executor, so
packages that trials and verifiers install (`apt-get install curl`, `pip`,
`uv`) are fetched from a nearby mirror and, for apt, once per executor
([the download cache](#the-download-cache) does the same for the other
keys):

```json
"container_mirrors": {
  "apt": "http://mirrors.aliyun.com",
  "pypi": "https://mirrors.aliyun.com/pypi/simple/",
  "conda": "https://mirrors.tuna.tsinghua.edu.cn/anaconda",
  "go": "https://goproxy.cn",
  "rustup": "https://rsproxy.cn",
  "npm": "https://registry.npmmirror.com",
  "github": "https://gh-proxy.com/https://github.com",
  "hf": "https://hf-mirror.com"
}
```

| Key | In the task container |
|---|---|
| `apt` | `/etc/apt/apt.conf.d/99metacodes-apt-cache` sets `Acquire::http::Proxy` to the apt cache, `http://<metrics_bind>:3142`. An `http://` mirror root holding `debian/` and `ubuntu/`; the cache fetches `deb.debian.org` and the Ubuntu archive from there, and other `http` apt sources (`security.ubuntu.com`) from their own hosts. `https` sources are not cached. Only with `egress` = `direct`, since the cache fetches from the executor's own network |
| `pypi` | `PIP_INDEX_URL` and `UV_DEFAULT_INDEX` |
| `conda` | `CONDA_CHANNEL_ALIAS=<root>/cloud`, `CONDA_DEFAULT_CHANNELS=<root>/pkgs/main,<root>/pkgs/r` (an Anaconda mirror root) |
| `go` | `GOPROXY=<url>,direct` |
| `rustup` | `RUSTUP_DIST_SERVER=<url>`, `RUSTUP_UPDATE_ROOT=<url>/rustup` (crates still come from crates.io) |
| `npm` | `NPM_CONFIG_REGISTRY` |
| `github` | `UV_INSTALLER_GITHUB_BASE_URL=<url>` and `UV_PYTHON_INSTALL_MIRROR=<url>/astral-sh/python-build-standalone/releases/download`: the uv binary that a verifier's `astral.sh/uv/<version>/install.sh` downloads and the Python that `uvx -p 3.13` downloads, both GitHub release assets. The value stands for `https://github.com`, so a prefix proxy is written with the origin in its path (`https://gh-proxy.com/https://github.com`) |
| `hf` | `HF_ENDPOINT` |

`github` covers release downloads only. It sets no git `insteadOf`: an
agent's own `git clone` still goes to GitHub, because a third-party proxy
that fails where GitHub answers would fail tasks that work today. The
install script itself is fetched from `astral.sh` by a URL written in each
task's `test.sh`, which no variable redirects. A per-project release mirror
does not fit this key: `mirror.nju.edu.cn/github-release` keeps only recent
python-build-standalone releases (its 20251014 assets answered 404 in
November 2026), while a pinned uv asks for the release it was built with.
Docker Hub images have no mirror of this kind; `docker_mirrors` is the
separate daemon setting above.

Each run uploads `<state_dir>/runs/<name>/mirrors.compose.json` and passes
it to Harbor as `--extra-docker-compose`: an overlay of Harbor's `main`
service with those variables and the apt file (an inline compose `config`,
read-only). The overlay comes after a task's own `docker-compose.yaml` in
Harbor's compose order, so before staging the run the worker scans the
suite's compose files, `task.toml` files and Dockerfiles: a variable (or
`Acquire::http::Proxy`) that any of them names is left out of the overlay
for that run and the run log says so. Values baked into a prebuilt image
that the suite's files do not name are still overridden. When `apt` is
set, the worker also checks over SSH that the apt cache answers; when it
does not, the run leaves the apt file out (the task containers use their
own apt sources) and its log names the cache and the setup command that
restarts it. Builds are not
affected: `bench pull` builds task images once and Harbor reuses them.

Setup's apt 缓存 step runs the cache: it builds the image
`metacodes-apt-cache` (apt-cacher-ng on `debian:bookworm-slim`, with the
mirror as its Debian and Ubuntu backend) and starts the container of the same
name with `--restart unless-stopped`, published on
`<metrics_bind>:3142`, with the named volume `metacodes-apt-cache` for the
packages, then checks that `/acng-report.html` answers. A running container
already labeled with the same mirror is kept; another mirror replaces it.
The volume survives that replacement. The cache answers containers on
Harbor's compose networks the same way the egress forwarder does.

### The download cache

Mirrors make a download closer, not rarer: every trial is a fresh container,
so the same wheels, the same uv binary and the same Python are fetched again
for each one (about 107 MB of PyPI packages per SWE-bench trial, about
50 MB from GitHub per Terminal-Bench 2.1 trial). `"download_cache": true`
on an `ssh` executor adds one cache on the executor that every run's task
containers ask first; only what it does not have is fetched from the
mirror, once, and kept:

```json
{"name": "relay-4090", "kind": "ssh", "host": "10.126.126.1",
 "download_cache": true,
 "container_mirrors": {
   "apt": "http://mirrors.aliyun.com",
   "pypi": "https://pypi.tuna.tsinghua.edu.cn/simple",
   "npm": "https://registry.npmmirror.com",
   "github": "https://gh-proxy.com/https://github.com"}}
```

The cache is `scripts/eval/harbor/download_cache.py`, a caching reverse
proxy on Python's standard library. Each cacheable `container_mirrors` key
is a route `http://<metrics_bind>:3143/<key>/…` whose upstream is that
key's mirror, and a run's compose overlay points the same variables at the
route instead of the mirror:

| Key | In the task container when cached | Kept for good | Fetched again after 10 minutes |
|---|---|---|---|
| `pypi` | `PIP_INDEX_URL` and `UV_DEFAULT_INDEX` = `<cache>/pypi/simple/`, `PIP_TRUSTED_HOST=<metrics_bind>` (pip refuses a plain-http index on another host without it; uv needs nothing) | `/packages/…` | `/simple/…` |
| `npm` | `NPM_CONFIG_REGISTRY=<cache>/npm/` | `<package>/-/<file>.tgz` | package metadata |
| `go` | `GOPROXY=<cache>/go,direct` | `@v/<semver>.info`, `.mod`, `.zip` | `@v/list`, `@latest`, `sumdb/…` |
| `conda` | `CONDA_CHANNEL_ALIAS=<cache>/conda/cloud`, `CONDA_DEFAULT_CHANNELS=<cache>/conda/pkgs/main,<cache>/conda/pkgs/r` | `*.conda`, `*.tar.bz2` | `repodata` |
| `rustup` | `RUSTUP_DIST_SERVER=<cache>/rustup`, `RUSTUP_UPDATE_ROOT=<cache>/rustup/rustup` | `dist/<date>/…`, `rustup/archive/…` | channel manifests |
| `github` | `UV_INSTALLER_GITHUB_BASE_URL=<cache>/github`, `UV_PYTHON_INSTALL_MIRROR=<cache>/github/astral-sh/python-build-standalone/releases/download` | `<owner>/<repo>/releases/download/<tag>/<file>` (nothing else is routed) | — |

- **One download per file.** The first request for a file starts one
  download from the mirror; that request and every other request for the
  same file meanwhile are served from it as the bytes arrive, so four
  attempts of a task starting together cost one download and a large wheel
  does not run into pip's read timeout. A client that leaves does not stop
  the download. A file is published in the cache only when it arrived
  complete; redirects (GitHub release assets) are followed by the cache.
- **Mirror down.** A page that is fetched again after 10 minutes (an index
  page, package metadata) is served from the stored copy when the mirror
  fails or answers 5xx, so a run whose files are already cached does not
  need the mirror at all. Answers other than 200 are passed on and not
  stored.
- **Ranges.** A `Range` request is answered from the stored file; while a
  file is not stored yet the whole file is sent, which uv accepts (it then
  reads the wheel it was sent).
- **npm.** Mirror metadata names tarballs by absolute URL, so the cache
  rewrites the mirror's address to its own in metadata; a lockfile written
  during a run therefore names the cache.
- **Pick mirrors that are fast over HTTP/1.1.** The cache, like pip, speaks
  HTTP/1.1. `mirrors.aliyun.com/pypi` served a 23 MB wheel at about
  175 KB/s over HTTP/1.1 and in one second over HTTP/2 (measured from two
  networks in November 2026); the Tsinghua, USTC and Huawei Cloud indexes
  sent it at about 12 MB/s over HTTP/1.1.
- **`pypi` needs a `/simple` index URL** (`…/simple` or `…/simple/`) whose
  file links stay under the same root, as the Tsinghua and Aliyun indexes
  do; another shape keeps going to the mirror directly.
- **Reach.** Only GET and HEAD, only the configured routes, and paths with
  `..` are refused. The container publishes the port on `metrics_bind`
  only, like the apt cache. Before a run the worker reads `/_stats` over
  SSH and points a key's variables at the cache only when the running
  cache has that route with the mirror the entry names now. A cache that
  does not answer, a key added to `container_mirrors` since the last
  setup, or a mirror changed since then leaves those keys on the plain
  mirror variables for that run, and the run log names the setup command.
- **Changing a mirror.** A stored file belongs to the mirror it came from:
  after a route's mirror changes, the cache fetches from the new one and
  never serves (not even as a stale copy) what the old one sent. The old
  files stay on the volume, unused, until it is cleared.

Not behind this cache, each for its own reason:

- **apt** keeps its own cache (apt-cacher-ng, above), which already works
  this way.
- **Docker images.** Their cache is the executor's Docker image store:
  `bench pull` and Harbor pull an image only when `docker image inspect`
  does not find it.
- **Hugging Face.** `hf` stays a plain mirror: the Hub client needs the
  `ETag`, `X-Repo-Commit` and redirect answers of the Hub, which this cache
  does not reproduce.
- **`https://astral.sh/uv/<version>/install.sh`**, the installer script
  itself (a few KB): its URL is written in each task's `test.sh`.
- **An agent's own git traffic**, which no variable redirects.

`GET http://<metrics_bind>:3143/_stats` reports, per route, `requests`,
`hits`, `misses`, `stale`, `errors`, `bytes_cached` (served from the cache)
and `bytes_fetched` (downloaded from the mirror), plus `entries` and
`disk_bytes`; the counters are stored with the cache and survive a restart.
Setup's 下载缓存 step builds the image `metacodes-download-cache`
(`debian:bookworm-slim` with Python and the script) and runs the container
of the same name with `--restart unless-stopped` and the named volume
`metacodes-download-cache`. A running container built from the same script
and routes is kept; anything else replaces it, and the volume survives.
Nothing is evicted in this version: `docker rm -f metacodes-download-cache
&& docker volume rm metacodes-download-cache`, then setup again, starts
from empty.

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
metacodes bench --url http://devbox:18766/
metacodes bench info --url http://devbox:18766/
```

The workbench is meant for a trusted internal network and has no login:
anyone who can open the address can configure it (providers and their API
keys, database, setup) and launch or cancel runs. Bind it only to an
internal address. It serves only its own entries: the `--public-url`
address, `localhost` and IP literals on the listening port. A request whose
`Host` names anything else (for example a foreign name rebound to the
service's address) is refused, and a browser's `Origin` must be exactly the
entry it used (scheme, host and port); clients without an `Origin` (the
CLI) only need a trusted entry. Open it by IP, `localhost` or the
`--public-url` name. A service started without `--config` (a plain results
viewer) is read-only. The service receipt is
`<state root>/bench/service.json` (mode 0600 on POSIX).

The workbench updates while benchmarks run. The version a run evaluates is
its frozen bundle, and each run's worker is a process of its own that runs
the workbench files it started with (extracted per content digest under
`<state root>/bench/runtime/`, never removed), so neither depends on the
service. After upgrading the binary, `metacodes bench` (with the same jobs
directory and state directory) finds the service of the previous build,
stops it and starts this build's on the same bind, port and public URL; the
receipt records the build as `runtime`. Other commands (`run`, `info`, …)
keep using the running service. Active workers continue through the restart,
the new service shows their progress and advances profile queues from where
they stood, and later queue items launch with the new workbench code on the
same frozen bundle. On an SSH executor, `metacodes bench setup --executor`
may install the new node while runs are active: each run keeps the node it
started with (see [How an SSH run works](#how-an-ssh-run-works)). A service from before the login was dropped still requires its
link: `metacodes bench stop` and `metacodes bench` stop it with the
capability from this machine's receipt (the only use of it left), and
`metacodes bench` then starts the login-free service.

When `metacodes bench` replaces a running service (another build, a store
change or the login-free upgrade), the new service keeps the old bind, port and public
URL unless the command gives them. A receipt from before this release does
not record the bind, so when the old service listens on 127.0.0.1 (or
0.0.0.0) the command leaves it running and asks for `--bind`. The CLI acts
on the receipt's service only while that service still serves this state
directory's workbench; if another workbench took the port, the receipt is
treated as stale.

## Using the page

The workbench opens on Profiles. Open one to see its frozen MetaCodes version,
latest results and submitted jobs. Select profiles in the list to compare
their summaries and choose results from the same suite for a task comparison.
System settings (系统配置) contains the database, model providers and Metask login.
Open 监控 in the rail to inspect an execution machine's load, network, mirrors, Docker and caches.

### Profiles

A profile (评测配置) is what an evaluation tests: one frozen metacodes version
with a fixed set of advanced features. Every run belongs to a profile, and a
profile is run on as often as wanted. The 创建作业 form picks the executor and version (the
configured Linux bundle by default, or any valid bundle under
`<state root>/bench/bundles/`, including those `metacodes bench build --ref`
builds), the advanced features, several suites with their tasks, the model
and attempts. Concurrency is not on that page: it belongs to the profile
(10 when the profile is created) and every dataset queued on it runs at it.
The profile's id is derived from
the bundle's content digest and the features, so the same version with the
same features always lands on the same profile, and changing either is
another profile. The first run on a profile validates every dataset, then
copies the bundle, once per content digest, to
`<state root>/bench/bundles/frozen/<digest>/` with its files made read-only.
Every run of the profile uses that copy, so rebuilding the configured bundle
in place or switching `workbench.json` to another version never changes a
profile already created; before each launch the copy is checked against its
digest, and a modified copy fails the dataset instead of running.

The 高级功能 section of the 评测 page switches on metacodes features that are
off in metacodes by default. The Lean-modelled run gates are ticked by
default (`default_features` in `GET /api/workbench`, also what `bench run`
uses) and the preview features are not. Each one adds a single metacodes
flag to every trial of the profile: the run gates
`verification_final_gate` (`--verification-final-gate`), `requirement_ledger`
(`--requirement-ledger`), `test_integrity` (`--test-integrity`),
`delivery_cadence` (`--delivery-cadence`) and `stall_gate` (`--stall-gate`),
and the preview features `execute_code` (`--preview=execute_code`),
`comment_guard` (`--preview=comment_guard`) and `harnessmm` (`--harnessmm`).
`ADVANCED_FEATURES` in `scripts/eval/harbor/command.py` is the list. The
profile and each of its runs record the chosen names (`features`), and the
run passes them to the adapter as `--ak features=<names>`. An unknown name is
refused. A WorkBuddy suite's overlay launches metacodes itself and takes
only the run gates: the workbench writes each one as a harness parameter of
the WorkBuddy job (`FEATURE_PARAMS` in `scripts/eval/harbor/suites/workbuddy.py`,
for example `METACODES_STALL_GATE: true`), and the overlay turns it into the
same flag. Its datasets run without the profile's preview features: the
queued dataset and its run record list only the gates, and the profile page
names the features left out; a direct launch that asks for a preview feature
on a WorkBuddy suite is refused. A WorkBuddy checkout whose installed overlay
differs from this checkout's refuses a run with features until
`install_overlay` reinstalls it. The paid launch gate (`scripts/eval/workbuddy/launch_gate.py`)
refuses a job carrying `METACODES_TEST_INTEGRITY`, `METACODES_DELIVERY_CADENCE`
or `METACODES_STALL_GATE`, which its receipt's `evaluation_treatment` does not record. The frozen bundle has to know the flags: a release older
than a feature fails its trials with a usage error. An SSH executor's node
loads the adapter from its own checkout, so the node protocol is 2 since
features (4 since teamwork, 7 since model prices, 9 since WorkBuddy gates, 10 since worker-owned results): an older node is refused until
`metacodes bench setup --executor <name>` updates it, instead of running the
trials without the chosen flags.

#### Teamwork

`teamwork` is a preview feature of its own kind: not a flag of the headless
run but its entry. A profile with it runs every Harbor task through
`metacodes --preview=teamwork teamwork run`, the same pipeline as the REPL's
`/teamwork` (implementer, reviewer, isolated verifier, merge-back), and the
task's own verifier then scores the merged result. Comparing a profile with
teamwork against one without on the same version, model and tasks measures
what turning it on changes. It runs alone, since `teamwork run` takes none of
the other features' flags, and only on an SSH executor whose entry sets
`"teamwork_privileged": true`:

- **Container**: teamwork seats run their commands under bubblewrap, which
  Docker's defaults refuse. A teamwork run's compose overlay gives Harbor's
  `main` service `cap_add: [SYS_ADMIN, NET_ADMIN]` and unconfined seccomp,
  AppArmor and `systempaths` (`TEAMWORK_CONTAINER`), and the agent installs
  git and bubblewrap when the image lacks them. **This is close to a
  privileged container.** The seats' commands stay inside bubblewrap, but
  the task's verifier runs as root in the same container, outside it, and
  executes code the model wrote (a solution module, a `conftest.py`); with
  these permissions such code can reach the executor host (for example its
  `core_pattern`, or a cgroup v1 `release_agent`). Set
  `teamwork_privileged` only on a disposable executor that holds no
  credentials or other secrets; without it a teamwork launch is refused.
- **Repository**: teamwork works in a git worktree and merges back. A task
  directory without a commit gets one first (`git init` when it is no
  repository, then a snapshot commit of what the image put there); one with
  a commit is used as it is.
- **Permissions**: a headless trial runs with `bypassPermissions`, but
  `teamwork run` takes no `--permission`, and its seats and isolated
  verifier would ask for every risky command with nobody to answer (the
  first real runs ended `audit_unavailable`: the verifier stopped at its
  prompts). The trial writes user-level allow rules for the built-in tools
  (`TEAMWORK_ALLOWED_TOOLS`, WebFetch included) and every MCP server the
  task declares (`mcp__<server>`) to `~/.claude/settings.json` in the
  disposable container, unless the image has that file; seat commands still
  run under bubblewrap. This is narrower than `bypassPermissions`: a
  protected path (for example metacodes' own configuration) still asks, so a
  seat that touches one is refused and the verifier can stop there.
- **Request and approval**: the instruction is the approved request
  (`--approve`); text starting with `[` gets a heading, since a leading
  bracket would be read as an option segment. Every seat uses metacodes and
  the trial's model; the run's reasoning effort reaches the implementer and
  reviewer seats (`--config-json`), while the verifier keeps its own.
- **Budget and time**: `--budget-usd` follows the `difficulty` of the task's
  `task.toml` (easy $20, medium $40, hard $80, otherwise $40), and the trial
  gets `--agent-timeout-multiplier 3`, recorded on the run as
  `agent_timeout_multiplier`. The cap is in metacodes' price estimate,
  not a provider bill; without the run's OpenRouter price (below) a model
  missing from metacodes' table is charged at the Sonnet fallback rates
  (`packages/base/src/util/pricing.zig`), and the cap, and the isolated verifier's own
  $0.20, stop far earlier than real spend would. The first real-model runs
  without it ran out of budget or ended with no audit verdict.

#### Model prices

A Harbor run's model is priced from OpenRouter: at launch the workbench
matches the model to the one OpenRouter model whose id without its `vendor/`
prefix is the run's request model id (case-insensitive, so
`metask/DeepSeek-V4.1-Flash-1017` is `deepseek/deepseek-v4.1-flash-1017`;
a request id with its own namespace, such as `acme/model` behind
`gateway/`, matches only the OpenRouter id `acme/model`),
records it on the run as `model_price` (USD per million tokens and the
`openrouter_id`), and the adapter writes it to the trial's `config.json` as
`model_prices`, which every metacodes cost meter charges first (`doc/API.md`,
"Model prices"). The catalog (`https://openrouter.ai/api/v1/models`) is
cached beside `workbench.json` as `openrouter-prices.json` for a day; when
OpenRouter cannot be reached the cached copy is used. A model with no single
match, or without a cached catalog, keeps metacodes' own estimate and
records no `model_price`. `"model_prices": "off"` in `workbench.json` skips
the lookup.
- **Validity**: `teamwork status --json` lands in the trial's agent logs,
  and the run directory without its worktrees (`teamwork-run/`: ledger,
  seat records and logs) beside it. A run that wrote no status, or in which
  no implementer seat finished (all failed, as on a provider error), fails
  the trial with `TeamworkNotEngaged`, so it counts as invalid. A run that
  spent its budget (`budget_exhausted`), worked but did not merge, or merged
  a wrong change is scored by the verifier like any other. Its stop reason
  is `teamwork_<state>`, and summaries count `budget_exhausted` trials
  apart (预算用完 on the profile page and in 模型对比), since for a model
  without its own price that is often the fallback estimate rather than the
  task. The run directory is copied again when the trial is killed on its
  timeout. The trial's cost is the run's ledger spend; per-request timing
  and tokens come from the relay's request metrics as for a headless run.

`POST /api/profiles/run` queues datasets: on an existing profile with
`profile` (its version and features cannot be changed), or with `bundle` and
`features`, creating the profile on first use (`name` names a new profile).
A profile holds results of any number of models: `models` (up to 8, the
评测 page's model checkboxes) queues every dataset once per model, `model`
queues it with one. The profile page compares the models' latest results
(模型对比, with how many tasks each ran) and filters the task list by model;
when the models ran different tasks it adds the same comparison over only the
tasks all of them ran (`common_tasks` and each model's `common_summary` in
`GET /api/profile`).
Each submission creates one job (作业). All suite/model pairs in the request
carry the same `submission` ID. The profile page can cancel one job or rerun
its original evaluations together (`POST /api/profile/submission` with `id`,
`submission` and `action` of `cancel`, `run` or `delete`). Deleting an ended submission removes
its evaluations and retries from the profile and preserves stored run results.
Item controls use the evaluation’s returned `index` across deletions. Rerunning a whole job
creates a new job on its recorded executor. A single evaluation retry and an
automatic retry stay in the original job. For older records, the workbench
groups evaluations by their original queue timestamp and assigns automatic
retries to their source submission when the recorded history identifies it.

The queued datasets run one after another, each as an ordinary workbench run
(one Harbor job) whose record names the profile. The durable state is
`<jobs-dir>/.bench-profiles/<id>.json`; the service's scheduler only advances
what that file says, so a restarted service resumes a queue where it stopped.
With several profiles queued, the one whose oldest waiting dataset was queued
first runs until its queue is empty. A single launch (`POST /api/runs`,
`metacodes bench run`) runs at once on the profile of the configured bundle
and its `features` (`bench run --features a,b`; the run gates when none are
given, `--features ""` for none), and is refused while
a queue or another run owns the executor. Stopping a profile cancels its running dataset and skips the rest
of its queue. A dataset whose SSH executor does not answer when it is due
(the SSH connection fails or times out; a refused login does not count)
stays pending, with the reason in its `waiting` field, and is retried until the executor
answers. After 30 minutes it fails, and the queue moves on.

A profile's concurrency is set on its page (并发数; `POST /api/profile/concurrency`
with `id` and `concurrency`, any positive integer), running or not; `POST
/api/profiles/run` does not take one. A suite's `max_concurrency`, when set,
caps it. Each queued dataset, including manual and automatic reruns, reads
the saved profile value when it starts. While it waits, its row shows what
it would use now. An older profile without a saved value uses its latest
dataset's concurrency. A CLI `bench run` uses its own concurrency for that
launch only. Saving also updates an active Harbor run. Lowering it lets the trials already running finish;
raising it starts more within about a second. The workbench writes the value
to `<jobs>/.bench-runs/<run>.concurrency`; on an SSH executor the worker sends
it over the run's control channel and the node writes it beside the run's
spec. Harbor reads that file (named by `METACODES_BENCH_CONCURRENCY_FILE`)
through `scripts/eval/harbor/live_concurrency.py`, which the metacodes agent
installs in Harbor's trial queue in place of its fixed `-n` semaphore. A
WorkBuddy run keeps the concurrency it started with. The profile page confirms
that the new value was saved and shows the concurrency WorkBuddy is still using.
If an active run cannot be updated, the page reports the failure and the
saved value still applies to the queue.

A rerun replaces the earlier result: per suite, model and task the profile
counts only the attempts of the latest run that has them, and lists the
replaced runs as the task's history. A run that stopped (cancelled,
interrupted or failed) with only invalid attempts of a task leaves that
task's earlier result in place. 创建作业 and 重跑无效的题 use one model: the
page's model filter, else the last run's. The profile page's 创建作业 opens the launch
page on that profile with its datasets, tasks and last parameters, and
重跑无效的题 keeps only the tasks whose latest attempts include an invalid one
(an infrastructure failure such as a network error, not a failed answer).
With 自动重跑 on (`POST /api/profile/auto-rerun` with `id` and `enabled`,
the 自动重跑无效的题 checkbox on its page), a dataset that finishes with invalid
trials is queued again at the end of the profile's queue with only those
tasks, at most twice per dataset (the item's `auto_rerun` counts the round).
A dataset that was stopped, cancelled or failed is not rerun automatically;
when its results cannot be read, the item records why (`auto_rerun_error`)
and the queue goes on.
A profile can be renamed at any time (`POST /api/profile/rename` with `id`
and `name`, 重命名 on its page; an empty name falls back to the id).
Deleting a profile whose queue has ended (`POST /api/profile/delete`, 删除 Profile
under Profile 设置) removes its record, its runs'
records and logs, their job directories and their rows in the evaluation
database; the frozen bundle copy stays, since other profiles may share it.
A profile still running must be stopped first. Only a profile recorded in
this service's jobs directory is deleted; one ingested from another jobs
directory sharing the database is refused. When a file cannot be removed or
the database delete fails, the request fails and the profile stays for a
retry: the manifest goes last, after the rows are gone.
A single job can be deleted the same way (`POST /api/job/delete` with `name`,
删除 in the overview's job list): its run record and log, its job directory and
its rows go; a profile that ran it drops the link to it (so a later job of the
same name is not the profile's), keeps its other runs and shows the task's
earlier result, if any. A running job, whether the workbench launched it or
Harbor is still writing it, must be stopped first, and a job from another jobs
directory is refused.
Imports of a jobs directory (the service's sync, `bench db import`),
`bench sync --run` and deletions from it take the same lock,
`<jobs-dir>/.bench-store.lock`, so none of them can write a deleted profile
back. A deletion that finds the lock held fails and can be retried; the
service's sync skips the directory until its next round.
Profile records are ingested into the `profiles` table of the evaluation
database (schema v4, which replaces the `batches` table of v3).

Earlier versions grouped runs into batches. When the service starts, every
batch record under `<jobs-dir>/.bench-batches/` is merged into the profile of
its frozen bundle and features (batches with the same version and features
become one profile, the earliest batch's name kept), its runs stay with it,
and the batch record is removed.

The profile page lists every task's latest attempts and the run history; a
task's page shows its attempts side by side, then the selected attempt's
detail:

- **Token distribution**: one column per model request, its input context
  split by part (or by cached / uncached input when no composition was
  recorded), and its output tokens; a per-request table with start offset,
  duration, TTFT and usage.
- **Context composition**: the relay records, per request, the byte size of
  the system prompt, tool definitions, user/task messages, the model's
  earlier output and tool results (sizes only, never content). The page
  apportions the request's measured input tokens by those shares; the
  initial-token metric shows the first request's composition, averaged over
  trials. Runs recorded before this existed show `未采集`.
- **Time**: what the task's time is made of, in order: 预准备, 就绪等待 (or
  准备失败后等待) and 开始后准备 (see [Preparation ahead of the queue](#preparation-ahead-of-the-queue)), then
  Harbor's phases (环境, 安装, agent, 判分), with the images preparation
  pulled, built or found. The total counts from the start of preparation;
  排队 is shown beside it and not counted. The agent phase is split into
  waiting on the model (request durations), running tools (each call's
  measured execution from the metacodes event stream) and the rest; a
  per-tool timing table. The job page's 时间分段 bar has the same parts.
- **Trajectory**: every step, with each tool call's execution time.

The 数据库 page shows the active store and its contents. It tests a SQLite path or a PostgreSQL DSN (no password in the
DSN; `password_env` names the variable), and switches the service to it,
optionally migrating and verifying the current data first (the same copy as
`metacodes bench db migrate`). The new `store` is written to `workbench.json`
and takes effect immediately; switching is refused while a run or a profile's queue
is active.

### Public leaderboards

The 榜单 page (`#/leaderboard/<suite>`, `GET /api/leaderboard?suite=<id>`)
shows, per suite, the results other agents and models published for the
same tasks, and where this workbench's jobs land among them. The boards are
`scripts/eval/harbor/suites/leaderboards.json`: each names the suites whose
tasks it scored, its source (name, URL, the date it was read, what its score
means) and its entries (agent or harness, model, score in percent, and the
standard error, cost per task and date when the source gives them). A board
may list `tasks`, the part of the suite it scored (the AIME 2024 board on
`aime`). SWE-bench Verified has two boards from swebench.com (mini-SWE-agent
bash-only runs with cost, and other agents' submissions); each τ³ domain has
the taubench.com text board for that domain (pass^1). On each board a finished job of the suite scores the mean reward of
its finished trials on the board's tasks, an invalid trial counting 0, with
cost per task as the mean over tasks of each task's mean priced cost; it is
ranked when it covers at least 80% of those tasks, and a job ranked on no
board is listed apart. When a board has
costs, a scatter plots pass rate against cost per task. Published numbers
come from other harnesses, runtimes, attempt counts and judges, so a rank is
a reference, not a like-for-like comparison. To refresh a board, edit its
entries and `retrieved` date.

### Monitoring an execution machine

The 监控 page (`#/monitor[/<executor>]`, `GET /api/monitor?executor=NAME`,
`metacodes bench monitor [--executor NAME] [--json]`) shows one execution
machine: the default executor unless another is chosen. It reads, except for
the 镜像源 block, which edits the executor's mirror settings (below). Each
request runs one stdlib Python script on the machine (`bench/monitor_probe.py`,
sent on stdin of the same SSH command path the readiness probe uses, or run
locally for the local executor), so it needs no node update and works while a
benchmark runs. A snapshot is reused for 10 seconds per executor, the
reachability probes for 60 seconds and Docker's disk usage for 10 minutes
(`docker system df` took 2.6 seconds and 12 CPU-seconds on an executor with
382 images), so an open page neither opens an SSH session per viewer, nor
hammers the mirrors, nor loads the machine it watches. The script reads CPU
and network before it starts anything else, so those readings do not include
its own work. The page refreshes every 10
seconds and keeps the last 120 samples in the browser for the sparklines
(drawn from zero; CPU and memory against 100%, load against the CPU count);
closing the page drops them. A machine that cannot be reached, or whose
script returns nothing within 30 seconds, is shown with that reason; a
section that cannot be read (Docker not running, a cache that does not
answer) says so and leaves the others in place. A service without `--config`
answers 403.

| Panel | Value | Source |
|---|---|---|
| 机器负载 | Load averages, CPU count | `/proc/loadavg` (`os.getloadavg()` where there is no `/proc`), `os.cpu_count()` |
| | CPU 占用 | Share of non-idle time (idle and iowait count as idle) between two readings of the `cpu` line of `/proc/stat` one second apart |
| | 内存已用, swap | `MemTotal`, `MemAvailable`, `SwapTotal`, `SwapFree` of `/proc/meminfo`; used = 1 - available / total |
| | Disks | Size, used and free of `/`, Docker's data directory and the bench state directory (`state_dir`), one row per filesystem |
| 网络 | 下行 / 上行 | Byte counters of `/proc/net/dev` read twice in the same second, as bytes per second. The headline sums the interfaces that have a device (`/sys/class/net/<name>/device`); Docker bridges and container `veth` pairs are listed below it, loopback is left out |
| | 源站 | One GET each, 5 second timeout, to Docker Hub's registry, ghcr.io, github.com, pypi.org, huggingface.co and astral.sh from the machine itself. Any HTTP answer counts as reachable (a registry answers 401); the row shows the time and status |
| 镜像源 | Mirror settings, editable | The executor entry's `pypi_index`, `docker_mirrors` (probed at `/v2/`), `ghcr_mirror`, every `container_mirrors` key (set or not) and `download_cache`, each address probed like a source; `egress`; and the `registry-mirrors` the Docker daemon actually runs with (`docker info`). See [Editing mirrors on the page](#editing-mirrors-on-the-page) |
| Docker | Version, data directory, storage driver, containers | `docker info --format '{{json .}}'` |
| | Images, containers, volumes, build cache: count, in use, size, reclaimable | `docker system df --format '{{json .}}'`, at most every 10 minutes; the panel says when (Docker's decimal sizes, shown in binary units) |
| 缓存 · apt | 命中率 | The apt cache answers on `<metrics_bind>:3142`, and the last 64 MiB of its log are read with `docker exec metacodes-apt-cache tail -c … /var/log/apt-cacher-ng/apt-cacher.log`. Each `O` line is a response served to a container (a request, with its bytes), each `I` line a download from the mirror (a miss, with its bytes), each `E` line an error. Hits = requests - misses, as in apt-cacher-ng's own report; an index file fetched again to check for updates counts as a miss. The log starts when the cache container was created |
| 缓存 · 下载缓存 | Per kind: requests, hit rate, misses, stale answers, errors, bytes served from the cache and bytes downloaded; files and size on disk | `GET http://<metrics_bind>:3143/_stats` of the executor's download cache. 未启用 when nothing answers there |
| 缓存 · 镜像 | 命中率, pulls, builds, failures and their time; trials 排队 / 准备中 / 已就绪等待 / 准备失败等待 | Docker's local image store is the image cache: a task's image is pulled or built only when it is missing. Read from the newest 2000 `<jobs>/<job>/.bench-lifecycle/<trial>.json` records on the machine: an image already present is a hit, one pulled or built a miss, and a pull or build that several trials waited on (`shared` on all but the trial that ran it) counts once. A trial counts only while its job's Harbor is alive (`<state_dir>/runs/<job>/harbor.pid` without `harbor.exit`; for the local executor, a job without a final result written to in the last day): 准备中 while its preparation is running, whether it still waits or already holds its slot (the first wave of a run); otherwise, while it waits for a slot, 已就绪等待 after a preparation that left every image in place, 准备失败等待 after one that did not, and 排队 before any. The local executor leaves out the jobs whose run spec (`<jobs>/.bench-runs/<job>.spec`) names an SSH executor: their records are copied into the workbench's jobs directory, but their images were pulled on that executor |


### Editing mirrors on the page

The 镜像源 block of the 监控 page lists every mirror setting of an SSH
executor, set or not, as a field: `pypi_index`, `docker_mirrors` (several
addresses separated by spaces), `ghcr_mirror`, each `container_mirrors` key
and the `download_cache` switch. An empty field removes the setting. 保存
sends `POST /api/monitor/mirrors` (`{"executor": NAME, "settings": {...}}`
with any of `pypi_index`, `docker_mirrors`, `ghcr_mirror`,
`container_mirrors`, `download_cache`; a key that is left out is not
touched, and `container_mirrors` names only the keys to change, `null` or
`""` removing one). The page sends just the fields that were edited, so a
form opened before someone else saved does not put their values back, and
it locks its fields until the save has answered. The service builds the executor's new entry and validates it with
the parser that reads `workbench.json` (`executors.parse`), so the page
accepts exactly what the file accepts: the same keys, http(s) addresses,
`container_mirrors.apt` only as `http://` and, like `download_cache`, only
with `egress` = `direct`. A refused value is answered with the parser's
message and nothing is written. Otherwise the current file is copied to
`<state root>/bench/backups/workbench-<UTC time>.json` (the newest 20 are
kept) and the new one is written atomically; the response is a fresh
snapshot, in which the new addresses have just been probed (状态). Saving
is refused while a 一键配置 that changes the machine is running, since setup
writes the same file. The local executor has no mirror settings. When the
executor cannot be reached the block is still there, with 状态 shown as not
probed: the settings live on the workbench machine.

When a saved value takes effect is shown on each row (生效):

| Setting | Takes effect |
|---|---|
| `container_mirrors` other than `apt`, `ghcr_mirror` | From the next run that starts. A run in progress keeps the settings it started with |
| `pypi_index` | The next time setup installs Harbor on the executor; it does not reach runs |
| `docker_mirrors` | After setup's Docker 镜像加速 step, which adds the addresses to the daemon's `registry-mirrors` and reloads it. Setup only adds: an address removed here stays in the daemon until `daemon.json` is edited |
| `container_mirrors.apt` | After setup's apt 缓存 step rebuilds the cache for that mirror |
| `download_cache`, and the mirror of a key the cache routes | After setup's 下载缓存 step. Until then a run points only the routes the running cache already serves from the configured mirror at the cache, and the others at their mirror |

The page compares the settings with what the machine runs and marks what
is behind as 需要重新配置: a `docker_mirrors` address the daemon does not
list, an apt cache that does not answer or was built for another mirror (its
container label), a download cache that does not answer or whose routes
(`/_stats`) differ from the configured ones. 重新配置 starts the same
一键配置 as the 评测 page (`POST /api/setup`) and opens its progress there;
it is disabled, with the reason, while a benchmark runs (`busy` in the
snapshot) or a setup is already running (`setup_running`). Setup's 网络与镜像
step does not propose `"egress": "workbench"` for an executor whose
`download_cache` is on or whose `container_mirrors` has `apt`: both caches
fetch from the executor's own network and are only valid with `direct`.

### Metric definitions

| Metric | Calculation |
|---|---|
| Task total tokens | All model-request input tokens (including cache read/write) plus output tokens; repeated context is counted on each request |
| Initial tokens | The first model request's full input usage, including system prompt, tools, task and cached context; historical runs use the first native `usage` event |
| Single-run full-score rate | Independent valid runs with reward >= 1 / all valid runs. Every failed attempt remains in the denominator when a later independent run succeeds |
| First-attempt full-score rate | Tasks with reward >= 1 on their earliest trial / tasks whose earliest trial has a valid outcome. Later attempts never replace the first score. Infrastructure-invalid and running first trials are shown separately |
| Generation TPS | Sum of reported output tokens / sum of generation seconds, from first semantic output until response completion. Tool execution and first-token waiting are excluded |
| TTFT | From relay dispatch to the first non-empty text, reasoning, or tool-call output. Heartbeats and response metadata do not count. The pooled mean uses total duration and request count. Remote P50/P95 use fixed histogram buckets, eight per doubling from 1 ms through about 37 hours, with longer durations in the last bucket |
| Estimated cost | The metacodes binary's catalog estimate, including cache pricing. It is not the provider's settlement. Missing/zero unknown prices are shown as unknown with coverage counts |
| Pass rate 95% interval | Wilson score interval of the single-run full-score rate over valid runs. It treats every run as independent, so repeated attempts of a task and pooled jobs make it narrower than a task-level interval |
| Solved at least once | Tasks with at least one passing run / tasks with at least one valid run |
| Cost per task | Mean estimated cost of each task's priced valid runs, then the mean over those tasks, as in FrontierHarness Eval v1.1 |
| Cost per pass | Over the same priced tasks: the sum of per-task mean costs / the sum of per-task pass fractions, so each task weighs the same in both |
| Non-passing cost share | Estimated cost of valid runs that did not pass / estimated cost of all valid runs; failures and timeouts are also shown separately |
| Cache hit rate | Cache-read input tokens / all input tokens |
| Turns per pass | Mean turns (and tool calls) over passing runs |
| Cost-pass frontier | On the compare page, judged only on the tasks whose first attempt is valid in every compared job: the jobs that no other job beats in both per-task mean cost and mean pass fraction on those tasks. A job without a priced valid run on one of them is left out |

The credential relay runs on the execution host and forwards streaming
payloads unchanged; with metrics enabled it also times them. It stores numeric timing/usage records and per-request context part sizes only, under
`<jobs-dir>/<job>/.bench-metrics/<trial>.jsonl`. Its local Docker hop and HTTP
forwarding are part of the measured harness; these numbers are not provider
SLAs. The relay supports configured Bearer, API-key-header, and
custom-header Messages, Chat Completions, and Responses routes, with origin or
`/v1` base paths; other routes are refused at launch (see
[Credential flow and token refresh](#credential-flow-and-token-refresh)).
Latency aggregates use complete successful requests; failed or interrupted
requests do not become timing samples. The page reports sample coverage.
The host bind defaults to Docker's `172.17.0.1`; server-owned settings can
choose `metrics_bind`, or disable capture with `metrics_enabled: false` (the
relay still proxies authentication).
The container-to-host relay uses HTTPS; its ephemeral CA is added to the
disposable task image's CA bundles, and its private key stays on the host and
is removed when the worker exits. Native certificate verification stays on.

Old logs without request timestamps cannot recover TTFT/TPS and display
`未采集`, not an estimate from task wall time. Interrupted runs with partial
usage retain the observed tokens and are marked `部分记录`. Global costs and
token sums report their coverage so missing data cannot look like zero cost.

### Data storage

The **manager** is the metacodes installation serving the Bench UI and API.
The **worker** is the metacodes installation executing the job, independently
of the bundle being evaluated. A local run puts both roles on one machine.
For an SSH run the worker owns the ordinary Harbor files in
`<executor state_dir>/jobs/<job>/` and indexes them in its own evaluation store.
The manager retains the launch receipt, control log and aggregates.

Opening a job, trial, CSV or execution log queries the worker over SSH. The
manager returns that response to the browser without persisting it. When
the worker's database ID and the job's recorded source match the manager's
active store, the manager reads that database directly. With separate stores
an unreachable worker leaves the dashboard available and detail requests
report which worker is unavailable. The run page and CLI read status from
the manager receipt. Expanding the execution log reads the worker's Harbor
output even if startup failed before the first result. Historical jobs already copied back are
read from their existing store. Deleting a worker-owned job from the manager
removes its manager record and aggregates and preserves the worker's files
and detail records. On the worker, `bench list --jobs-dir <executor state_dir>/jobs`
lists the originals in that directory, including jobs whose manager uses a separate
database. A deleted manager entry stays hidden in that manager's jobs directory.

The layout on the machine that owns the data is:

```text
<jobs-dir>/
  .bench-runs/                     # launch receipts, specs, worker logs
  .bench-profiles/<id>.json        # profiles: frozen version, features, queued runs, state
  .bench-store.lock                # serializes imports, result syncs and profile deletions
  <job>/
    config.json, result.json       # job configuration and aggregate result
    .bench-metrics/<trial>.jsonl   # numeric request-level timing/usage
    .bench-lifecycle/<trial>.json  # queue, preparation and slot times of the trial
    <trial>/
      config.json, result.json     # trial score, timings and usage
      agent/                      # NDJSON, transcript, ATIF trajectory, stderr
      verifier/                   # reward, test output, CTRF report
    workbuddy/<harbor run>/<trial>/  # WorkBuddy launches: trials of its own Harbor runs
```

WorkBuddy trials under `workbuddy/<harbor run>/` are ingested as trials of
the workbench job, with the same projection as top-level trials (request
metrics are read from `.bench-metrics/` beside them).

The page reads the [evaluation database](#evaluation-database) of the machine that owns the requested data. The overview shows the
database and the synced jobs directories. Run files are not synced back to a
developer checkout.

### Evaluation database

Each node indexes the job directories it owns. The manager also indexes launch receipts and their aggregates. Each installation uses SQLite by default (`<state root>/bench/bench.sqlite3`, beside `workbench.json`, with
the same `--state-dir`/`METACODES_HOME` rules) or a remote PostgreSQL. The
service syncs its jobs directory when it starts, every ten seconds, and
before API reads (at most once every two seconds). The worker also syncs its
job every 15 seconds during a run and does a final, content-verified sync
before it writes the finished receipt. Ingestion is idempotent. Only files
whose size or mtime changed are read again, so a job that is still running
can be ingested safely. A partially written file is replaced on the next
pass. Symlinks are never followed. A trial is derived again only when its
own files or request metrics change: Harbor rewriting the job's
`result.json` after each trial updates the job header, not every trial. A
trial that cannot be derived is logged and retried on the next pass without
keeping the job's other trials out.

Text that a database cannot hold is stored the same way in SQLite and
PostgreSQL: in the normalized text columns (file paths, verifier messages,
stop reasons, …) a lone UTF-16 surrogate (a truncated emoji, a non-UTF-8
file name) or NUL becomes U+FFFD; the projections keep the exact value as a
JSON escape, so the page shows what the files show. Names read back from a
database (job names, file paths, trial directories) are validated before
anything is written to disk: a path with `..`, an absolute path, a
backslash, NUL or an empty component is ignored, and migration refuses to
copy one.

A trial is keyed by its directory relative to the job (`task__id`, or
`workbuddy/<run>/task__id`), so a trial name repeated in two WorkBuddy runs
counts twice, as in the live directory; the trial page opens the first by
path. A job whose directory was deleted stays listed from the database: the
database, not the directory, is the record.

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
refused. Files larger than 256 MiB are recorded with size and mtime and
their last 64 KiB: the projections read such a file only through its size
and tail (stderr and verifier output tails, the partial-token mark), so they
match the live files.

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
either direction. It reads the source in one snapshot, used for the copy and
for its verification, and commits the target in batches, so an interrupted
migration resumes when run again. Rows already present and identical are
skipped. A target row that is an older version of the source row (an
earlier ingestion of the same job, trial or launch record, an older mtime of
the same file, and the per-request/usage/test rows of such a trial) is
updated, so a migration rerun after the source moved on resumes instead of
failing. Any other difference under the same key stops the command before
it writes and changes nothing. After the copy, every row of the snapshot is
compared with the target, and every target blob is re-hashed. The command
reports row counts per table (copied, updated, already present, verified).
Migrating while a run is active is safe: the target holds the source as of
the snapshot, and what is ingested later reaches it when the service syncs
after `--switch` (it re-reads the jobs directories) or when `db migrate` is
run again. `--switch` then
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

A target is PostgreSQL when it is a `postgres://`/`postgresql://` URI in any
letter case or a libpq keyword string (`host=db dbname=bench user=bench`);
anything else is a SQLite path, and a path that looks like a connection
string or contains `password` is refused. A DSN containing a password is
refused, and the refusal never repeats it. The password comes from the named
environment variable, or from libpq's `PGPASSWORD`/`~/.pgpass`. It never
enters `workbench.json`, a run spec, or the browser. PostgreSQL needs
psycopg 3 in the Python that runs bench
(`python3 -m pip install 'psycopg[binary]'`). It is imported only when a
PostgreSQL store is configured; SQLite needs only the standard library.
Keep the database (or the jobs directory) when moving or backing up the
workbench. The state root's `bench/` directory also holds service settings
and the private service receipt.

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
`attempts`, `concurrency`, `features` (names from the 高级功能 list) and an optional
`max_tokens` (1024–131072), the output-token cap of each model request; `POST
/api/profiles/run` takes the same `max_tokens` for every suite it queues. Without it
metacodes uses the model's own cap (WorkBuddy runs keep 32768). The original `dataset:
"terminal-bench/terminal-bench-2-1"` field is still accepted and means
`suite: "terminal-bench-2.1"`. It takes task/model selections, not shell
commands, paths, keys, or arbitrary Harbor flags. Full task names are passed as separate argv
elements; there is no shell interpolation and retries are disabled at the
Harbor orchestration layer.

Contract tests use real HTTP and a subprocess standing in for Harbor, proving
that UI/CLI input reaches the child argv, creates a visible job, preserves
exit status, and supports cancellation without making paid requests.

## Code layout

The runtime and its two presentations are separate packages under
`scripts/eval/harbor/`:

| Layer | Files | Owns |
|---|---|---|
| Runtime | `bench/` | job projection (`data.py`), account models and keys (`account.py`), launch validation (`runner.py`), the durable worker (`worker.py`), the execution machine's monitor (`monitor.py` and the script it runs there, `monitor_probe.py`), the `Workbench` facade both presentations read (`workbench.py`) and its HTTP client (`client.py`) |
| Web page | `viewer/server.py`, `viewer/static/` | HTTP routes, authorization, the page |
| CLI | `cli.py` | arguments, service startup, terminal output |

The runtime imports neither presentation, and the two presentations do not
import each other (`LayeringTest` in `scripts/eval/tests/test_bench_workbench.py`).
A change to how runs execute or how results are classified goes in `bench/`;
both the page and `metacodes bench list`/`info` pick it up.
