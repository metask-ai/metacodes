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
| `viewer/` | read-only web page over Harbor job directories ([viewer/README.md](viewer/README.md)) |

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
| `metrics_proxy` | none | workbench-owned relay URL for request-level TTFT/TPS; payloads are forwarded unchanged |
| `metrics_ca` | none | public relay CA file; trusted only inside the disposable task container |
| `account_gateway` | none | account session's gateway origin; used by the Metask route when no timing relay is active |

### A third-party gateway

A provider metacodes has no profile for (an OpenAI-compatible relay, a
self-hosted server) is a `custom_providers` entry
([doc/PROVIDER_OFFER_ARCHITECTURE.md](../../../doc/PROVIDER_OFFER_ARCHITECTURE.md#user-defined-providers)).
The config names the variable the key is read from, never the key:

```json
{
  "schema_version": 1,
  "custom_providers": {
    "gateway": {
      "display_name": "My gateway",
      "auth": {"kind": "bearer"},
      "env_aliases": [{"name": "GATEWAY_API_KEY", "kind": "api_key", "canonical": true}],
      "channels": [{"id": "chat", "base_url": "https://gateway.example.com/v1", "protocol": "openai_chat"}],
      "models": [{
        "request_model_id": "GLM5.3-Flash",
        "dialect": "glm",
        "limits": {"context_window": 200000, "max_output_tokens": 32768}
      }]
    }
  }
}
```

```sh
PYTHONPATH=. harbor run ... -m gateway/GLM5.3-Flash \
  --ak config=/path/to/gateway-config.json \
  --ae 'GATEWAY_API_KEY=${GATEWAY_API_KEY}'
```

Declare `limits`: a model with an unknown context window is refused before
the first request. `dialect` names the vendor whose request parameters the
model takes (`glm`, `deepseek`, `kimi`, `qwen`, ...). Check the definition
offline with `metacodes --state-dir <dir with config.json> --check-providers`.

In third-party provider mode, the workbench model menu enumerates the
`models` in this configuration; it does not automatically import all models
from a gateway. [examples/tokenjoy-coding.json](examples/tokenjoy-coding.json)
declares six coding-model choices across Chat Completions, Responses, and
Anthropic Messages. They use the same credential environment variable.
The 200K context / 32K output values are conservative benchmark ceilings,
not claims about provider maxima. A model being listed or passing offline
route validation does not establish a benchmark result or live compatibility.

The workbench defaults to the Metask account selected by `metacodes login`.
Its model list uses the current CLI session's gateway and bearer. Legacy
account logins combine all active keys/model groups; each launch uses the
chosen model's matching credential. Existing
gateway configurations stay in provider mode until `metacodes bench --auth
metask` is selected; see [account configuration](../../../doc/BENCH_WORKBENCH.md#configure-execution).
## Smoke

```sh
python3 -m scripts.eval.harbor.smoke --bundle /path/to/metacodes-<version>-x86_64-linux-gnu
# Verify the HTTPS timing relay, still using the local scripted provider:
python3 -m scripts.eval.harbor.smoke --bundle /path/to/bundle --profile
python3 -m scripts.eval.harbor.smoke --bundle /path/to/bundle --metask-route
```

It starts a scripted Anthropic-Messages endpoint on the Docker bridge
(`172.17.0.1`; `--bind` to change), runs the real `harbor run` on
`fixtures/smoke-task` (an `ubuntu:22.04` image) with a `custom_providers`
config pointing at it, and passes only if the endpoint saw its two scripted
requests, the verifier gave reward 1, and the trajectory holds the Bash call
and its result. No credential, no provider request.
`--profile` also checks two complete TTFT/usage records; `--metask-route`
exercises the built-in Metask route with a fake credential. Both use a
job-local TLS CA and keep native certificate verification enabled.

## Leaderboards

Terminal-Bench takes submissions as public Harbor Hub jobs (`--upload
--public`, at least five attempts per task) followed by a PR to its
leaderboard repository; check the leaderboard's current rules first, since
community submissions have been closed at times. Uploading trajectories is a
public, irreversible act: do it only when the user asks.
