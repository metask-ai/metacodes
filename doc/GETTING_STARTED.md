# Getting started

Install, configure a model, build from source. The [README](../README.md) is
the overview; this page holds the details it links to.

- [Install a release](#install-a-release)
- [Choose a model provider](#choose-a-model-provider)
- [Metask OAuth](#metask-oauth)
- [Run it](#run-it)
- [Build from source](#build-from-source)
- [Auditing a different TinyKG binary](#auditing-a-different-tinykg-binary)

## Install a release

macOS and Linux (aarch64 or x86_64), the latest release:

```sh
curl -fsSL https://raw.githubusercontent.com/metask-ai/metacodes/main/scripts/install.sh | sh
```

A release runs on macOS 13 or newer and on Linux with glibc 2.31 or newer
(Ubuntu 20.04, Debian 11, RHEL 9 and later), on any x86-64 CPU, Apple Silicon,
or 64-bit Arm Linux machine (no SVE needed). Releases up to 0.8.0 have no
aarch64 Linux or Intel macOS unit, and releases 0.4.0 to 0.8.0 need more: glibc 2.36 and a CPU with AVX2 on
Linux, AVX2 on Windows, and AVX-512 in the 0.4.0, 0.6.0 and 0.8.0 Windows
builds, which many desktop and laptop CPUs lack.

This installs into `~/.local/opt/metacodes` with a `metacodes` launcher in
`~/.local/bin`, the AgentCore SDK included; rerunning it upgrades in place and
keeps the state. `| sh -s -- --version X.Y.Z` picks a release, `--help` lists
the rest. Nothing needs starting by hand: the first session of an install sets
up and starts its TinyKG service in the background.

A downloaded archive installs the same way:

```sh
sh scripts/install.sh metacodes-<version>-<target>.tar.gz
```

```powershell
powershell -ExecutionPolicy Bypass -File scripts\install.ps1 metacodes-<version>-x86_64-windows-gnu.zip
```

From a checkout, `scripts/install.sh --dev` builds the release unit from source
and installs it beside the released one: the main checkout as `metacodes-dev`
(`~/.local/opt/metacodes-dev`), a linked worktree as
`metacodes-dev-<worktree directory>`, each with a state root of its own. An
install is a copy, so rebuilding or removing the checkout leaves it running;
`--dev --uninstall` removes it again.

### Update an install

```sh
metacodes update
```

This brings the install up to date from where it came from. A release install
moves to the latest published release, downloaded from the same place it came
from: a mirror named with `install.sh --release-base` (or
`update --release-base`) is recorded and used again. A development install is
rebuilt from the checkout that built it; `--pull` fast-forwards that checkout
first.

- **What it keeps.** The prefix, the state root, the launcher and the SDK all
  stay as they are.
- **Never backwards.** It never moves an install to an older version without
  `--allow-downgrade`.
- **Repairs.** It repairs an install whose files no longer match its
  manifest.
- **Running sessions.** Exit the sessions of the install first, or pass
  `--ignore-running` (not on Windows). Restart them afterwards: their next
  formal-kernel check fails closed.

`--check` only reports (exit 3 when there is something to do), `--version
X.Y.Z` picks a release, and `--json` prints the result. Downloads go through
curl, as `install.sh`'s do, so a proxy set for one works for the other.
Installs older than the first release with `update` take one more
`install.sh` run.

The release unit is complete on every supported platform: the TUI, TinyKG (CLI
and daemon) and both Lean governance kernels under `libexec/metacodes/`, each
pinned into the executable ([release/LAYOUT.md](../release/LAYOUT.md)). Runtime
resolution checks the environment-variable pair first, then the adjacent file
with its compiled-in digest, and `metacodes doctor` reports every runtime asset
and the state root.

### Isolated installs

Each install is self-contained and isolated: it keeps its state (config,
credentials, TinyKG store, sessions, plans, Lean rules) in its own state root,
`<prefix>/state` unless `--state-dir` says otherwise, recorded in
`<prefix>/etc/metacodes/install.json`. Several installs coexist on one machine;
give each its own `--prefix` and launcher name (`--link-name`). `--sdk` adds the
AgentCore SDK under `<prefix>/sdk/agentcore/` (`include/metask/agentcore.h`,
`lib/`, Zig and Rust bindings).

The scripts only unpack (and refuse a downgrade for a release up to 0.5.0,
whose own install does not); the install is `bin/metacodes install` (`--help`
lists its options), which ends with the installed `doctor --strict`;
`--upgrade` replaces another version of the same product (the scripts always
pass it) but not a newer one with an older one unless `--allow-downgrade`,
`--force` also foreign files and another launcher. A launcher name held by
another install is refused with that install's prefix and version. A process
picks its state root from `--state-dir`, then `METACODES_HOME`, then the
install record, then `~/.metacodes` ([INSTALL_DESIGN.md](INSTALL_DESIGN.md)).

## Choose a model provider

metacodes is model-agnostic. `--provider` selects a provider profile
(`metask`, `openai`, `gemini`, `zai-coding-plan`, `deepseek`, `kimi`, `qwen`,
`minimax`, `bedrock`, or one you define), `--channel` a route within it, and `--offer` pins one exact model route. `metacodes
--check-providers` validates the configuration and lists every route without
touching the network. `--base-url`, `--api-key` and `--model` override the
endpoint, key and model for a single run; `--openai-protocol responses`
switches the OpenAI wire from Chat Completions to Responses. Profiles,
channels, offers and typed credentials are specified in
[PROVIDER_OFFER_ARCHITECTURE.md](PROVIDER_OFFER_ARCHITECTURE.md).

Each built-in vendor reads its key from its own variable — `DEEPSEEK_API_KEY`,
`MOONSHOT_API_KEY`, `DASHSCOPE_API_KEY`, `MINIMAX_API_KEY`,
`AWS_BEARER_TOKEN_BEDROCK` (a Bedrock API key) — and its integration notes
(endpoints, thinking parameters, known differences, sources) are the header of
`src/api/dialects/<vendor>.zig`.

## GLM Coding Plan

```sh
metacodes login --provider zai-coding-plan
metacodes --provider zai-coding-plan --model glm-5.3
```

Z.AI has no third-party sign-in, so the login asks which plan the key is for
(China or Global, personal or team), opens that plan's key page, and reads
the pasted key without showing it. The key is checked against the plan's
model list and stored in `$HOME/.metacodes/keys/zai-coding-plan.json` (0600);
a refused key is not stored. Create it on the Coding Plan page, not the
standard API-key page: a standard key bills the account balance. `/login`
and `/model` in the TUI offer the same steps. `ZAI_API_KEY` still works and
wins over the stored key; `metacodes logout --provider zai-coding-plan`
forgets it.

## Metask OAuth

`metacodes login --provider metask` uses Metask's JSON device authorization
flow. It prints `METASK_VERIFICATION_URI=...` and `METASK_USER_CODE=...` to
stderr (use `--no-browser` on a headless machine), then stores the access and
rotating refresh tokens plus gateway/model URLs in
`$HOME/.metacodes/oauth/metask.json`. Set `METASK_SITE_URL` for a local control
plane (`http://localhost:3000`); `METASK_GATEWAY_URL` overrides the gateway
origin for local development. `METACODES_OAUTH_DIR` changes the OAuth store.

Gateway requests use both Anthropic Messages and OpenAI Chat routes. A request
that receives `401` with `code=token_expired` is refreshed once and replayed;
`invalid_token`, `invalid_api_key`, and balance errors are never refresh-looped.
Each request is recorded after completion in
`$HOME/.metacodes/ledger/metask.ndjson` (override the directory with
`METACODES_LEDGER_DIR`), and `metacodes ledger metask` prints those JSON lines.
The ledger uses server-reported token usage only and includes both local and
`X-Metask-Request-Id` request identifiers.
Records are schema version 1 NDJSON with unix-millisecond `ts`; failed or
interrupted responses use zero token counts rather than estimates.

For compatibility, `--api-key` or an explicitly set `METASK_API_KEY` can still
select the historical `napi.metask-ai.com` API-key route. A stored device-flow
session supplies its authenticated gateway by default; use `--base-url` or
`METASK_GATEWAY_URL` when deliberately testing a different gateway.

## Run it

```sh
metacodes                                   # interactive TUI
metacodes --resume <id>                     # the TUI, back in a session of this directory
metacodes -p "explain src/main.zig" --json  # headless: one prompt, one NDJSON result
metacodes -p - --stream-json < task.txt     # headless, streaming every event as NDJSON
metacodes --web                             # browser UI on 127.0.0.1:7777
metacodes serve --sessions 4                # HTTP daemon with create/destroy session routes
metacodes doctor                            # where every runtime asset resolves from
```

The interactive TUI opens with a short animation of the "Metask Lab" wordmark,
played while metacodes starts up (MCP servers, catalogs); any key skips it.
Set `METACODES_NO_STARTUP_ANIMATION` (to any value, even
`0`), or put
`"startupAnimation": false` in `<state root>/config.json` (`metacodes doctor`
shows where the state root is), to start straight at the prompt. The TUI keeps
the model route's `/v1/models` answer in `<state root>/cache/models/` for a
day, so a start does not wait for it; it is refreshed in the background, and
the directory can be deleted at any time.

Leaving a session that has run a turn prints the command that reopens it,
`metacodes --resume <id>`; inside the TUI, `/resume` lists this directory's
sessions.

In the prompt, Enter submits and Shift+Enter starts a new line where the
terminal can tell the two apart. When the footer says `\ + ⏎ for newline`, end
the line with `\` and press Enter instead, or run `/terminal-setup` once: in
Apple Terminal and in VS Code (and its forks) it binds Shift+Enter in the
terminal's own settings, after a backup, and `/terminal-setup restore` undoes
it ([Terminal setup](TERMINAL_SETUP.md)).

`metacodes --help` lists every flag. Embedding the runtime in your own process
(Zig module or the AgentCore C ABI) starts at [API.md](API.md).

## Build from source

The checked-in toolchain contract currently requires Zig 0.16.0 or newer within
the 0.16 development line used by CI.

```sh
git clone https://github.com/metask-ai/metacodes.git
cd metacodes
zig build
./zig-out/bin/metacodes --help
```

The default build does not download or compile TinyKG. It selects one
manifest-pinned CLI from the checked-in cross-platform binary bundle and stages
it beside Metacodes. `highlight-zig` remains the only checked-in source
dependency. See [TinyKG integration](TINYKG_INTEGRATION.md) for the supported
matrix, provenance contract, explicit override, and manual update procedure.

Common gates:

```sh
zig build test
zig build test:lib -Doptimize=ReleaseSafe
```

With a Lean toolchain (elan) on the machine, `zig build test` also builds both
governance kernels from this checkout (`kernels:stage`, cached on the Lean
sources) and runs every kernel-gated test against them; `-Dlean-kernels=on`
turns a missing toolchain into a failure, `off` skips the kernels. On Windows
the kernel scripts run under Git for Windows' bash, never WSL's. A release
unit from source is `zig build kernels:stage --prefix <u>` followed by
`zig build release:verify -Drelease-layout=true --prefix <u> $(python3
scripts/kernel_pins.py <u>)`; `<u>/bin/metacodes install --prefix <dir>` then
installs it. `scripts/install.sh --dev` does all three, plus the AgentCore SDK.

The AgentCore bundle and its native consumption gates (`agentcore:test`,
`agentcore:bundle`, `agentcore:gate`) are documented once, in
[sdk/README.md](../sdk/README.md).

On Windows the same suite runs natively; keep the job count bounded because
the default is one LLVM codegen per core and the test binaries are large:

```sh
zig build test -j6
```

The Python suites need Python >= 3.9 (the macOS system `python3` suffices) and
PyYAML: `python3 -m pip install -r requirements-dev.txt`. `zig build test` runs
`python3` (`python` on Windows) from PATH, and `scripts/tests/test_python_floor.py`
keeps every script parseable at that floor.

Line endings are pinned to LF by `.gitattributes` (embedded prompt templates
take part in SHA-256 contracts), and a few gates are POSIX-only by design and
skip with a stated reason: the paid budget journal, dir_fd-anchored artifact
publication, and the anonymous-descriptor memory runtime smoke (see
`scripts/eval/tests/posix_only.py`). CI runs this suite in the `units`,
`integration` and `product` legs of the `windows-gates` job.
To exercise the POSIX-only paths from a Windows box, clone the commit into a
WSL ext4 home (not `/mnt/...`, where every file reports as executable) and run
the Python suite there.

## Auditing a different TinyKG binary

Maintainers can audit a candidate binary instead of the bundled one:

```sh
tinykg_bin=/absolute/path/to/tinykg
tinykg_sha=$(shasum -a 256 "$tinykg_bin" | awk '{print $1}')
zig build test \
  -Dtinykg-bin="$tinykg_bin" \
  -Dtinykg-sha256="$tinykg_sha"
```

Normal tests use the native bundled artifact automatically. No build, test, or
release gate searches `PATH`, downloads TinyKG, inspects a sibling checkout, or
uses an old `zig-out` artifact.
