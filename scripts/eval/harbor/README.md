# Harbor adapter

[Harbor](https://harborframework.com) runs agents on containerized benchmark
tasks: Terminal-Bench 2.x and later, DeepSWE, and the datasets on Harbor Hub.
`metacodes_agent.py` makes metacodes one of its installed agents, loaded by
import path. It targets Harbor 0.26 and the upstream task format; the
WorkBuddy-Bench overlay in `../workbuddy/` is a separate adapter for that
benchmark's pinned Harbor fork and its local proxy.

| File | What it is |
|---|---|
| `metacodes_agent.py` | `MetacodesAgent`, the Harbor `BaseInstalledAgent` |
| `command.py` | Harbor-free core: bundle check, model split, the trial script, trace → ATIF |
| `smoke.py`, `smoke_provider.py`, `fixtures/smoke-task/` | zero-cost end-to-end smoke through the real `harbor run` |

Contract tests: `scripts/eval/tests/test_harbor_adapter.py` (part of
`zig build test:product`).

## What a trial does

1. **Install.** The adapter uploads a Linux release-layout bundle
   ([release/LAYOUT.md](../../../release/LAYOUT.md): `bin/metacodes`, ripgrep,
   TinyKG, both Lean kernels) to `/opt/metacodes` in the task container,
   checks the executable's SHA-256 against the host copy, and runs
   `metacodes --version --json`. A task image whose C library the bundle cannot
   load fails here, not as a zero-reward trial. An image without a CA bundle
   (some Terminal-Bench images ship no `ca-certificates`) gets the package
   from its own package manager; without it every provider request fails
   with `TlsInitializationFailed`.
2. **Run.** metacodes runs headless with its own `--state-dir` under `/tmp`
   (config and sessions, so trials share nothing),
   `--permission bypassPermissions`, and the instruction on stdin from an
   uploaded file. `HOME` is left alone: the task's own commands use it.
   TinyKG runs in the exclusive CLI mode on a fresh store in that state dir
   ([doc/TINYKG_INTEGRATION.md](../../../doc/TINYKG_INTEGRATION.md#runtime-modes)),
   so no `kgd` service is started or left running into the verifier.
3. **Collect.** The NDJSON output and stderr go straight to files in
   `/logs/agent` (no pipes: a process that outlives metacodes cannot hold the
   trial open), the session transcript is copied there, and Harbor copies the
   directory back. The adapter converts them to an
   ATIF `trajectory.json` (one step per model turn, tool results attached to
   their call) and fills Harbor's token and cost counters. A trial Harbor
   killed on timeout becomes a one-step trajectory with stop reason
   `killed_no_result`.

## The bundle

Use a published Linux release: it is what the version string names, and its
glibc floor is low (0.12.0: `metacodes` needs glibc 2.28, the kernels 2.14).
Images built on musl (Alpine) cannot run it.

```sh
gh release download 0.12.0 -R metask-ai/metacodes -p 'metacodes-0.12.0-x86_64-linux-gnu.tar.gz'
tar xzf metacodes-0.12.0-x86_64-linux-gnu.tar.gz
```

## Running a benchmark

From the repository root on a Linux host with Docker and Harbor
(`uv tool install harbor`):

```sh
PYTHONPATH=. harbor run \
  -d terminal-bench/terminal-bench-2-1 \
  -a scripts.eval.harbor.metacodes_agent:MetacodesAgent \
  -m deepseek/deepseek-v4-flash \
  --ak bundle=/path/to/metacodes-0.12.0-x86_64-linux-gnu \
  --ae 'DEEPSEEK_API_KEY=${DEEPSEEK_API_KEY}' \
  -k 5 -n 4
```

This spends provider money. Run it only with the user's explicit
authorization ([AGENTS.md](../../../AGENTS.md#definition-of-done)).

- `-m <provider>/<model>`: the part before the first `/` is passed as
  `--provider` (a built-in id or alias, or a provider defined in the native
  config), the rest as `--model`. A name without `/` passes only `--model`.
- Credentials: Harbor forwards `--ae NAME=value` to the agent's commands.
  Written as the template `'NAME=${NAME}'` (single quotes), Harbor reads the
  value from its own environment, so the key is in neither the command line
  nor the saved job config. Pass the variable the provider reads
  ([doc/LOCAL_CONFIG.md](../../../doc/LOCAL_CONFIG.md#names-it-accepts)).

Agent options (`--ak name=value`):

| Option | Default | Effect |
|---|---|---|
| `bundle` | `$METACODES_HARBOR_BUNDLE` | the Linux release prefix to install (required) |
| `config` | none | a metacodes `config.json` (path or inline JSON), installed in the trial's state dir; this is how a `custom_providers` endpoint reaches the trial |
| `reasoning_effort` | the model's default | `--reasoning-effort`: `none` … `max` |
| `max_tokens` | the model's default | `--max-tokens` |
| `disallowed_tools` | `Agent,Task,TaskBatch,TeamCreate,TeamDelete,SendMessage,EnterPlanMode,ExitPlanMode` | `--disallowed-tools`; an empty value enables every tool |

## Smoke

```sh
python3 -m scripts.eval.harbor.smoke --bundle /path/to/metacodes-<version>-x86_64-linux-gnu
```

It starts a scripted Anthropic-Messages endpoint on the Docker bridge
(`172.17.0.1`; `--bind` to change), runs the real `harbor run` on
`fixtures/smoke-task` (an `ubuntu:22.04` image) with a `custom_providers`
config pointing at it, and passes only if the endpoint saw its two scripted
requests, the verifier gave reward 1, and the trajectory holds the Bash call
and its result. No credential, no provider request.

## Leaderboards

Terminal-Bench takes submissions as public Harbor Hub jobs (`--upload
--public`, at least five attempts per task) followed by a PR to its
leaderboard repository; check the leaderboard's current rules first, since
community submissions have been closed at times. Uploading trajectories is a
public, irreversible act: do it only when the user asks.
