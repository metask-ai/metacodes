# API overview

Metacodes exposes several host shapes over one kernel. The fixed AgentLoop,
Conversation projection, permission/sandbox chain, budgets, formal verdicts,
artifact store, and TinyKG admission are not replaceable extensions.

Sandbox execution has two boundaries: native filesystem/command tools use
confined executors, while external harness workers run as a whole confined
process tree. Linux combines bubblewrap and seccomp; macOS uses Seatbelt.
Deploy the bundled `bin/metacodes-fs-helper` beside an embedded Host or set
`METACODES_SANDBOX_HELPER` to its absolute path. Enabled native file/worker
sandboxes refuse unavailable backends rather than opening/running on the Host.
The Zig `sandbox_exec` namespace exposes platform discovery; no C ABI fields
or wire layouts change. See [sandbox execution](SANDBOX_DESIGN.md) for the
helper contract and the current network-policy limits.

## Compatibility matrix

| Interface | Entry point | Status | Compatibility rule |
|---|---|---|---|
| CLI | `metacodes-<version>-<target-id>/bin/metacodes` (the release unit, `release/LAYOUT.md`; `zig-out/bin/metacodes` in a development tree) | pre-1.0 | flags may evolve with changelog notice; `manifest.json` records version, commit, target, contract numbers and every file's digest |
| Provider control plane | `src/provider/` kernel API | experimental | schema-versioned documents and revisioned mutations |
| Zig source API | `@import("metacodes-core")` | experimental | pin repository commit and Zig toolchain |
| AgentCore C ABI | `metask_agentcore_get_api(1)` | experimental rev 29 | exact root/child layouts and bundle manifest |
| Python package | `import metacodes` ([sdk/python](../sdk/python/README.md)) | experimental, unpublished | speaks exactly the AgentCore ABI revision it was built for and refuses any other |
| Node package | `require('metacodes')` ([sdk/node](../sdk/node/README.md)) | experimental, unpublished; macOS and Linux | same exact-revision rule; the addon is rebuilt per platform |
| Process plugins | strict manifest + stdio protocol | versioned v1 | reject unknown fields and digest drift |
| Plugin inventory | `--dump-plugins`, Zig, Web state | versioned v1 | additive observation fields only where specified |
| TinyKG executable distribution | `vendor/tinykg/manifest.json` | bundle v1 | exact target, format, source commit, and SHA-256 pinning |
| Web/daemon HTTP surface | `metacodes --web`, `metacodes serve` | pre-1.0 | endpoints, authentication and bind rules as in [Web and daemon HTTP surface](#web-and-daemon-http-surface); changes with changelog notice |

Beyond the endpoints and access rules of
[Web and daemon HTTP surface](#web-and-daemon-http-surface), there is no
general HTTP service API promise yet. The Web and daemon hosts are product
surfaces built over the same core protocols.

## Preview features

Preview features default to disabled, and each has its own switch:

| Feature | Enables |
|---|---|
| `execute_code` | The `ExecuteCode` JavaScript orchestration tool |
| `teamwork` | `metacodes teamwork` run, resume and Manager MCP execution |
| `comment_guard` | The no-comment instruction and the editors' comment check |

`--preview` enables every feature and `--no-preview` disables every feature.
`--preview=<list>` and `--no-preview=<list>` take comma-separated feature names
and change only those, for example `metacodes --preview=execute_code,teamwork`.
An unknown name is a usage error. Flags apply left to right, so the last flag
naming a feature wins. Features no flag names come from the root `"preview"`
of the installation's `config.json` (`<state root>/config.json`): `true`
enables all, `false` disables all, and an object such as
`{"execute_code": true, "comment_guard": false}` enables the features set to
`true`. Child agents inherit the resolved features. A feature's own selection
and permission rules still apply after it is enabled. HarnessMM and RSI are
selected only by their own switches (`--harnessmm`, `--rsi`) and do not depend
on this setting.

Source embedders set `AgentRuntime.RuntimeConfig.preview`, a
`preview.Features` value such as `.all` or `.{ .execute_code = true }`.
AgentCore ABI revision 29 exposes `RuntimeConfigV1.preview` (0 or 1, default
0), where 1 enables every feature; Python uses `Runtime(preview=True)` and
Node.js uses `new Runtime({ preview: true })`. The SDKs include `ExecuteCode`
when enabled. Selecting a preview built-in by name while its feature is
disabled is rejected.

`comment_guard` instructs agents to express intent in code and avoid adding
explanatory comments. Built-in Write, Edit, ApplyPatch and NotebookEdit check
proposed edits before writing. For each recognized language they compare
comment tokens, including repetitions, with the file or code cell being edited.
A new token produces a recoverable tool error with the path and line.
Shebangs and recognized tool directives are allowed. The lexical check covers
text with a known baseline and up to 512 KiB on each side. It uses the bundled
highlighter's string and comment rules, so language-specific constructs can be
misclassified. It skips Bash sources containing `<<`, and YAML and CSS files entirely. Writes by shell commands,
external tools and edits to unsupported formats rely on the prompt guidance.

## JavaScript tool orchestration

`ExecuteCode({code, timeout_ms?})` runs JavaScript in a per-session QuickJS
context. `await tools.Read(args)` and the equivalent interfaces for selected
built-in, Host and process tools enter the kernel's ordinary tool admission
and execution pipeline. Meta Code and its tools remain implemented in Zig.
The result contains the last expression, explicit logs and the inner call count;
intermediate tool results stay outside provider messages. This is a preview
feature: it is absent from the tool menu by default, and a guessed invocation
is rejected before creating a VM. Enabling preview admits it to the catalog;
Session tool selection and ordinary admission still apply. The normative behavior, limits and reset
rules are in [PROGRAMMATIC_TOOL_CALLING.md](PROGRAMMATIC_TOOL_CALLING.md).

## Provider selection surface

The `metacodes bench` CLI starts/opens a Bench workbench, inspects jobs and
launches Harbor trials. Its command, JSON output, HTTP launch contract
(`suite` and `executor` in `POST /api/runs`, `GET /api/suite`,
`/api/setup`, `/api/login` and `/api/providers`), `bench setup`, `bench provider`,
`bench prepare`, `bench pull`, `bench monitor` (and `GET /api/monitor`,
`POST /api/monitor/mirrors`) and
the `bench db` evaluation-database commands are documented in
[Bench workbench](BENCH_WORKBENCH.md). This adds a CLI surface;
AgentCore ABI and SDK layouts are unchanged.

### Metask device OAuth and gateway

`metacodes login --provider metask` performs the Metask JSON device flow:

* `POST $METASK_SITE_URL/api/oauth/device/code` (default site
  `https://www.metask-ai.com`) with `client_id=metacodes` and
  `scope=read model:invoke`;
* polling `POST $METASK_SITE_URL/api/oauth/token` with the device grant and
  `client_id` until approval; and
* atomically storing `access_token`, `refresh_token`, `expires_at`,
  `gateway_url`, `models_url`, and `client_name` in
  `$HOME/.metacodes/oauth/metask.json` (or `METACODES_OAUTH_DIR`).

In an SSH session (`SSH_CONNECTION` or `SSH_TTY` set), where a loopback
redirect lands on this machine and the browser that would follow it is on
another one, `metacodes login` takes this flow by itself and says so in one
line, and `/login` asks which way with this flow selected. Taken there, this
flow opens no browser on this machine; the browser way, picked in `/login`,
opens it as it does without SSH. `--no-browser` keeps the browser sign-in
(#722). A loopback sign-in (Metask's, `login --provider <id>`'s OAuth, and
`metacodes mcp login`'s, #740) also takes the address the browser ended on,
pasted at the prompt or into the `/login` pane: its path and query are
judged as the callback would be (path, `state`, `code`, `error`), so an
address from another sign-in is refused and the wait goes on. The browser sign-in of `metacodes login` waits for the
callback at most `METACODES_LOGIN_CALLBACK_TIMEOUT_MS` (default 600000;
`0` waits without a limit), then exits 1 having stored nothing and names
this flow; `metacodes mcp login` waits as long, then exits 1 having stored
nothing. In an SSH session every loopback sign-in (Metask's, `login
--provider <id>`'s OAuth, `metacodes mcp login`'s, OpenRouter's browser way)
prints the forward its callback needs, with the port it bound:
`ssh -L <port>:127.0.0.1:<port> <you>@<this machine>`. A callback that
carries the sign-in's `state` and an `error`, as a denial on the
authorization page does, ends Metask's browser sign-in and `metacodes mcp
login` as it ends `login --provider <id>`'s OAuth: each says what the
server said and stores nothing (#749).

Every Metask sign-in that replaces a stored session (this one, `metacodes
login`, `/login`, `/login metask`) revokes the replaced one at
`$METASK_SITE_URL/api/oauth/revoke`, as `metacodes logout` revokes the current
one (#560): only once the new session is stored (and, in the TUI, bound), so a
sign-in that fails, cannot bind or is cancelled revokes nothing; bounded (3 s
in the TUI, 5 s on the command line), and a refusal or no answer is reported
in one line without failing the sign-in. The same session stored again is not
revoked, and a replaced session whose `gateway_url` is not the origin of
`$METASK_SITE_URL` is not sent there: it stays valid until it expires, and the
sign-in says so.

The refresh grant sends only `grant_type=refresh_token` and the stored refresh
token. Metask rotates refresh tokens; persistence happens before the new access
token is used, and an `invalid_grant` is actionable as “log in again”. The
gateway origin comes from `gateway_url` or `METASK_GATEWAY_URL` (an origin, not
`/v1/messages`) and exposes both `/v1/messages` (Anthropic SSE) and
`/v1/chat/completions` (OpenAI SSE). On a pre-stream `401` whose JSON error code
is `token_expired`, the identical serialized request is replayed once. Invalid
tokens, invalid API keys, balance errors, and model-not-found responses are not
refresh-retried.

Every gateway response captures the case-insensitive `X-Metask-Request-Id`.
Completed and failed requests are appended as one NDJSON record to
`$HOME/.metacodes/ledger/metask.ndjson` (or `METACODES_LEDGER_DIR`), with
server-reported usage only, local/server request ids, HTTP status, retry
attempt, outcome, and elapsed time. `metacodes ledger metask` prints the file.
The schema-1 keys are `ts` (unix milliseconds), `session_id`, `provider_id`,
`protocol`, `model`, `local_request_id`, `server_request_id`, `http_status`,
`outcome`, `retry_attempt`, `input_tokens`, `output_tokens`,
`cache_read_tokens`, `cache_creation_tokens`, and `wall_elapsed_ms`; missing
usage on an error or interrupted stream is recorded as zero.

The historical `METASK_API_KEY`/`--api-key` path remains available only as an
explicit compatibility choice. It is never inferred in place of a stored
device-flow gateway; an explicit `--base-url` or `METASK_GATEWAY_URL` can be
used for deliberate legacy/local testing.

Route selection is provider-owned data, not a model-name convention. See
[Provider offers and control plane](PROVIDER_OFFER_ARCHITECTURE.md) for the
normative model; the entry points are:

| Surface | Contract |
|---|---|
| `--provider <id\|alias>` / `METACODES_PROVIDER` | resolve the route through the provider registry instead of inferring a transport from the model name |
| `METACODES_MODEL` | the model, as `--model` gives it (the flag wins) |
| `--preset <name>` / `METACODES_PRESET` | a named setup from `config.json` `presets` (#489; [LOCAL_CONFIG.md](LOCAL_CONFIG.md#presets)), applied as the flags naming its route would: `--model`, `--channel` and `--reasoning-effort` replace one field for that run, `--provider`/`--offer` set it aside, nothing is written back. Below a preset named at start comes the one `directory_presets` remembers for the working directory (its git worktree root, else the directory), then the `/model` default. A name `config.json` does not define stops `-p`, `serve` and `--web` with exit 2, listing the presets; the TUI starts without it and says so under its banner. With `"global_default": false` in `config.json` nothing below the directory's preset applies (the `/model` default, a Metask sign-in, `.env`'s choice; `--api-key` still does): in a directory that remembers none the TUI opens without a model, and `-p`, `serve` and `--web` stop with exit 2 before any request |
| `<state root>/.env` | the install's local configuration ([LOCAL_CONFIG.md](LOCAL_CONFIG.md)), read once at start and never `setenv`: a layer below the process environment for the names it may set — every registered profile's `env_aliases`, the variables `config.json` names (`providers.<id>.credentials[].env`, `provider_catalogs.<id>.credential_env`), `METACODES_PROVIDER`, `METACODES_MODEL`, `METACODES_PRESET`; a provider's aliases are read from it only when the environment sets none of them. Request addresses (`METACODES_BASE_URL`, `METASK_GATEWAY_URL`, `METASK_SITE_URL`, `METACODES_KEY_CHECK_URL`, `METACODES_KG_URL`, any `*_URL`) are refused; other names are ignored with one warning listing them. Its `METACODES_PRESET`, else its `METACODES_PROVIDER` (else the one provider whose key it holds), applies only when no flag or environment variable names a provider or a preset, the working directory remembers no preset, no `global_selection` is stored and no Metask sign-in exists (`--api-key`, `METASK_API_KEY`, a key or older sign-in in `auth.json`, the Metask session `oauth/metask.json`); keys of several providers and no name choose none, and the run lists them. A `.env` anywhere else, the working directory included, is never read. `metacodes install` writes `<state root>/.env.example` on every install and upgrade and never touches `.env` |
| no credential at all | the interactive TUI opens without a model (#484): its banner reads `not set — /login, or configure .env`; a prompt, `/retry`, `/edit <n>`, `/init`, `/commit`, `/review`, `/btw`, `/recap` and a Skill are refused with a note before any request is assembled; nothing is probed; no session directory is made until a route binds (`/model`, `/login`). A Metask sign-in in `auth.json` older than #527 with no key and model chosen opens it the same way, and so does a provider named by `--provider`, `--offer`, `METACODES_PROVIDER`, a preset or `.env` that has no credential: the note names that provider's variables, and no other provider is used in its place (#485). `-p`, `-`, `serve`, `--web` and a REPL whose input is a pipe exit non-zero with the sign-in hint (or the named provider's help) instead. The banner names where a bound route's credential came from (`· Metask`, `· from .env`, `· from shell`, `· saved key`, `· signed in`, `· --api-key`) |
| stored default without a credential | a `global_selection` whose provider has no credential (a Metask one: no Metask session, no Metask key and no key in `auth.json`; a stored Metask route the session authenticates runs at the session's gateway, never at the compiled endpoint with the session's token, #527) is passed over for the levels below it, with one notice: `The default model, <provider> · <model>, has no key or sign-in; this session uses <model> · <origin>.` (under the TUI's banner, else on stderr) (#485) |
| `metacodes logout` | revokes the Metask session at `$METASK_SITE_URL/api/oauth/revoke` (bounded; a failure is reported and the local sign-out goes on), removes both Metask sign-ins (`auth.json`, `oauth/metask.json` with its refresh token) and a key stored with `login --provider metask`, forgets a stored default that resolves to Metask, and says which it removed; `METASK_API_KEY` left in the shell or `.env` is named, never removed. `logout --provider metask` is the same (#499) |
| `--channel <id>` | narrow to one endpoint/region/plan/account binding |
| `--offer <offer-id>` | pin one exact reproducible route |
| `--base-url <url>` | validated against the selected profile and route policy before any request URL is built |
| `--check-providers` | validate the configuration and print every route it produces, then exit; no credential is resolved and no request URL is built |
| `METACODES_LOGIN_CALLBACK_TIMEOUT_MS` | how long `metacodes login`'s browser sign-in and `metacodes mcp login` wait for the browser to come back (default 600000, ten minutes; `0` waits without a limit); then they exit 1 and store nothing, and `metacodes login` names the device-code sign-in (#722, #740) |
| `METACODES_STREAM_IDLE_TIMEOUT_MS` | stream liveness, **head phase**: a request whose connection stays open but delivers no byte before the response head for this long (default 120000; 0 disables liveness monitoring entirely) is shut down by the client's monitor and retried as a transient network error. Nothing in a blocked socket read notices an abort flag; this is what turns a silent gateway or proxy into a bounded failure instead of a frozen session. Progress is measured per SSE line, not per parsed event: a tool call's `input_json_delta` frames and unknown events keep the request alive, but keepalive lines (`event: ping`, `data: {"type":"ping"}`, `:` comments) do not — they prove the gateway connection is up, not that the model is producing (2026-09-23: a gateway pinged every 15 s for 55 minutes over an upstream that produced nothing) |
| `METACODES_STREAM_BODY_IDLE_TIMEOUT_MS` | stream liveness, **body phase** (response head accepted): unset = automatic, `clamp(max_tokens × 100 ms, 600000, 1800000)` — a gateway may generate an entire tool call before writing a byte of it, so the tolerated silence scales with the response the request allows; an explicit value is a flat limit in ms; 0 disables body-phase monitoring. Past the limit the client shuts the connection down, the turn ends with `StreamStalled` and the TUI reports `正文空闲超时: <idle> ms 内无任何字节(上限 <limit> ms)` when the connection itself went silent, or `<idle> ms 内无模型输出,但网关 keepalive 仍在到达(最近字节 <n> ms 前)…` when a gateway kept the connection alive over a dead upstream — instead of the generic failure text. A user cancel (Ctrl+C/Esc) that wakes the blocked read is reported as an abort, never as an API error, and the streamed prefix is kept as partial text. A body-phase stall after visible output (text, thinking or a tool call) is not retried automatically in the TUI (the streamed prefix cannot be pretended away); a stall, a stream that ended without a stop report, or a dropped connection before any visible output is re-sent once (an in-stream server error, reported as `API 错误帧: …` on every wire, is not). Independently of this limit, once an endpoint has been seen to send keepalives mid-stream (three pings or SSE comments, each ending a silence of at least 2 s), a streamed body with no byte at all, keepalives included, for max(4 × the longest such interval, 2 minutes) is judged a dead connection and reported as `连接已断: <n> ms 内无任何字节,连 keepalive 也没有…`; 0 here disables that rule as well |
| `metacodes login --provider <id> --oauth-token-json <file>` | import an OAuth token into that provider's own store; refresh, single flight, and rotated-refresh persistence then run themselves |
| `metacodes login --provider <id> [--key-page <page>] [--api-key-stdin] [--no-check]` | for a provider that declares key pages and no sign-in it can run — every built-in vendor but Metask: `openai`, `gemini`, `qwen`, `minimax`, `kimi`, `deepseek`, `zai-coding-plan`, `kimi-code`, `bedrock` (OpenAI's OAuth sign-in runs instead once an OAuth client is configured for it, or with `--client-id`), and every provider defined in `custom_providers` that accepts an API key (no page is opened for one: the key is pasted, checked at its default channel's model listing, and stored with no page recorded): open the key page (the one for the default channel's region; `--key-page` picks another), read the pasted key with echo off (or from stdin, or `--api-key <key>`), check it with a GET the provider does not bill, the key placed where the provider's requests carry it (Gemini's `x-goog-api-key`), and store it in `<state root>/keys/<id>.json` (0600). A 401/403, or what the provider words as a wrong key (Gemini's 400 `API_KEY_INVALID`), refuses it; nothing is stored then. Only that provider's resolution reads the file, after its environment aliases: when one of them is set in the shell or in `.env`, the login says so by the variable's name (`warning: DASHSCOPE_API_KEY is set in your shell and is used before the stored key: …`; `/login` prints the same line); `metacodes logout --provider <id>` removes it. `METACODES_KEY_CHECK_URL` (https, or http to a loopback host) replaces the check URL for a local mock |
| `metacodes login --provider openrouter [--device-code] [--no-browser]` | OpenRouter's own sign-in (`ProviderProfile.key_grant`, its PKCE flow): the browser goes to `https://openrouter.ai/auth` with an S256 challenge and a loopback callback on any free port (1456, else 1457, else one the system picks), taken only with its own `state`; a refusal ends it at once. `--device-code` (taken unasked in an SSH session unless `--no-browser`) prints a page without a callback, whose code is pasted back at a hidden prompt. `POST /api/v1/auth/keys` trades the code and the verifier for an API key of the user's own account, which is stored in `<state root>/keys/openrouter.json` like a pasted one, with what `GET /api/v1/key` said about it (label, spending limit, expiry, free tier); then the account's listing (`GET /api/v1/models/user`) is fetched and kept for `/model`. `--api-key-stdin` stores a key created on OpenRouter instead, checked and described by `GET /api/v1/key`. `logout --provider openrouter` removes the key from this machine and names `https://openrouter.ai/keys/<sha256 hex of the key>`, where its owner deletes it (only a management key could delete it from here). `METACODES_OPENROUTER_URL` (https, or http to a loopback host; process environment only) moves every OpenRouter address, requests included, for a local mock |
| `metacodes providers add <id> --base-url <url> --protocol <wire> [--protocol <wire>[=<url>]]… [--model <id>]… [--probe] [--display-name <name>] [--dialect <vendor>] [--key-env <VAR>] [--auth bearer\|header:<name>[:<prefix>]] [--subscription-plan] [--replace]` | write `custom_providers.<id>` ([PROVIDERS.md](PROVIDERS.md#a-model-api-of-your-own)): one channel per wire; the document is checked as `--check-providers` checks it, in the lock that writes it, and a definition that would not load is not written; an endpoint the policy refuses, a built-in id, a taken id (without `--replace`) and a `--key-env` another provider reads are refused first. With no arguments at a terminal it asks for each part; without one a missing part exits 2. `--probe` asks the endpoint's model listing (at a terminal: the key, then a pick); `--subscription-plan` writes `"subscription_plan": true`, so a `-p`, `serve` or CI start on it warns as on `kimi-code`. Applies from the next start |
| `metacodes providers probe <id>` / `probe --base-url <url> --protocol <wire> [--auth …] [--key-env <VAR> \| --api-key-stdin]` | list the models the endpoint serves (the `data` array, an enriched `models` map, or Gemini's `models` array); a key, when there is one, is sent as the provider's requests send it, and no redirect is followed; nothing is stored; exit 1 when no listing answered |
| `metacodes providers list` | the defined providers: channels, models, where each one's key comes from (names and paths, never a value), disabled ones marked |
| `metacodes providers remove <id>` | remove a defined provider whole: `custom_providers.<id>`, `providers.<id>` and a `global_selection` that resolved to it in one write, then `keys/<id>.json` and `oauth/<id>.json` (not revoked); a built-in id exits 2. `/providers remove <id>` does the same for a defined provider |
| `~/.metacodes/config.json` | `schema_version`, `config_revision`, `providers` (with per-provider `credentials` by environment-variable reference), `custom_providers`, `provider_catalogs`, `aliases`, `global_selection`, `presets`, `directory_presets` and `global_default` (#489), `recent_operation_ids`; written atomically, other keys preserved. The same file declares MCP servers under `"mcpServers"` (Claude Code's schema; the legacy `"mcp_servers":[{"name":"<id>","command":[...]}]` array still works), and Claude Code's `~/.claude.json` / `.mcp.json` and Codex's `config.toml` servers are read too — see [Skills and MCP servers](SKILLS_AND_MCP.md). Each connected server's tools register as deferred `mcp__<id>__<tool>` (listed under the prompt's `# Deferred tools`, activated with `ToolSearch select:mcp__<id>__<tool>`), `/mcp` shows every configured server and why any failed, and `ListMcpResourcesTool` fails with `capability_unsupported` when nothing is |
| `<session_dir>/runtime-selection.json` | `session_selection`; a session-scoped choice never reaches `config.json` |
| `src/provider/control_plane.zig` | `model.list`, `model.describe`, `selection.validate`, `selection.resolve`, `selection.commit`, `quote.estimate`, replayable event journal |

Interactive surfaces: `Ctrl+O` and `/model` open the route picker, one screen
of models under a heading per provider (where its key comes from, who bills
it), the cursor on the model in use; a model served on several routes lists
them under it while the cursor is on it, the reasoning level is a line under
the list changed with ←/→, the three scopes are named in the header (`Tab`
cycles them), typing filters across every provider, a line under the header
says that OpenRouter's model list is still downloading (how much has come)
or why it did not come (`Ctrl+R` downloads it again) and the list fills in
when it comes, and closing without a
choice prints `kept <model>` (transcript
viewing moved to `Ctrl+X Ctrl+O`, also `/transcript`); `/providers` lists routes
and takes `refresh`, `enable <id>`, `disable <id>`, `remove <id>`; `/alias`
names a route (`pin`, `float`, `use`, `remove`); `/models` still selects the
account key of a key route; `/login` alone runs the Metask browser sign-in
`metacodes login` runs (authorization code + PKCE at
`https://www.metask-ai.com` as the client `metacodes`, scope
`read model:invoke`, on a loopback `/auth/metask/callback`; `--no-browser`
prints the URL without opening it) on a worker thread, then asks for the
model and reasoning level in the pane, from the `/v1/models` of the gateway
the token response names (models that gateway does not serve on
`/v1/messages` are left out); `Esc` at any step stores and changes nothing.
Once both are chosen it stores the token response as the Metask session
(`oauth/metask.json`) and the choice in `auth.json`, as `metacodes login`
does, moves the session onto that gateway with the session's token at once,
and forgets a stored `global_selection`, so the next start is on the sign-in
too (#485, #527); a Metask session it replaced is then revoked at Metask
(#560, see [Metask device OAuth and gateway](#metask-device-oauth-and-gateway)).
`/logout` revokes the Metask session at Metask, removes
both Metask sign-ins (`auth.json` and the session `oauth/metask.json`) and a
Metask key
stored with `login --provider metask`, forgets a stored default that resolves
to Metask, drops every Metask credential the process holds (nothing is sent
with one again), and moves a session on Metask to what `.env` chooses at
level 6 of the startup order, its `METACODES_PRESET` before its provider
(`Switched to <provider> (from .env)`), or leaves it unbound;
`/logout <id>` removes `keys/<id>.json`, and a session that ran on that key
holds no credential afterwards. Neither runs in the middle of a turn: a
command typed then waits in the queue until the turn ends.
`/login metask` is Metask's device grant in the pane `/login` uses: the code
is confirmed on any device, then the model and reasoning level are chosen,
and the sign-in is stored and used as `/login`'s (#527). In an SSH session
`/login` alone asks which way, the device grant selected, and says why;
`/login --no-browser` keeps the browser sign-in there (#722).
`/login <id> [--device-code] [--no-browser] [--client-id <client>]` starts
another provider's sign-in directly; it
runs the kernel OAuth flow on a worker thread (`Esc` cancels it) and stores
the login where `metacodes login --provider <id>` does (issue #33); `--client-id` is needed
only when neither the profile nor `providers.<id>.oauth_client_id` in
`~/.metacodes/config.json` names the installation's registered client (#87). A
provider that takes a pasted key instead (`zai-coding-plan`, `kimi-code`) is
listed in `/login` as "API key": ↑/↓ picks the plan, its page opens, the key is
typed masked, and Enter checks and stores it. A provider whose site creates
the key (`openrouter`) is listed as "browser sign-in" and asks which way: the
browser on this computer, another device (its page shows a code, typed here
masked; offered first in an SSH session, and where `--device-code` starts), or
a key the user already has.

The picker lists only routes a commit can apply as they are (#488): a route is
listed when a credential resolves for it now, by the same resolution a commit
binds with, without a request: the environment, `<state root>/.env`, a key
`/login <id>` stored, a provider's stored OAuth login, a credential-pool
member, `--api-key` for the provider it was given for, and for Metask the
session's own key or, in a session started on another provider, the key
`metacodes login` stored in `auth.json`. Only a missing credential takes a
route off the list: a route refused for another reason (two names of its key
that disagree, say) stays listed, and a commit reports why. A
provider none of whose routes has one is listed dimmed under "Not
configured", below the others; choosing it shows the variable its key is read
from, this install's `<state root>/.env` and `doc/LOCAL_CONFIG.md` (for
Metask, `/login` first), and nothing else: the picker starts no sign-in, takes
no key and sends no request. A commit that still finds no credential shows the
same. `/login <id>` is where a key is pasted or a provider signed in to; the
in-picker sign-in and key stage of #67 are gone. When a commit moves the
session to another provider, its confirmation says who bills it from then on.

A committed route is broadcast on the UI event stream as `config_changed` →
`route`, carrying provider, channel, protocol, wire model id, offer id,
credential *reference*, and scope. The model name alone cannot identify a route,
so a name-only broadcast would announce a change an out-of-process client cannot
tell apart from another; the credential reference travels and the secret does
not.

A newer `config.json` `schema_version` is rejected rather than merged. Sessions
that name no provider keep the historical Metask credential and model-inference
path unchanged.

## Session command surface (UI-neutral)

All three interactive hosts (terminal REPL, `--web`, `serve`/`serve --sessions N`)
share one input pipeline (`apps/cli/src/session_intent.zig` + `apps/cli/src/session_service.zig`):

    raw input → session_intent.parse → InputIntent
      → SessionService.dispatch (validate → mutate → optional RunPlan)
      → host submits the run via session_service.buildRunOptions

- **Intent classes.** `!cmd` is the shell lane; `/verb …` resolves against the
  built-in verb table (`session_intent.BUILTIN_VERBS`, built-ins win over
  same-named skills); an unknown `/head` is a skill candidate; anything else is
  a prompt. The verb table is the single registry — hosts do not parse slash
  commands themselves.
- **Service verbs** (equivalent across hosts): `/model use <id>`, `/mode
  [name]`, `/effort <level>`, `/compact`, `/add-dir <path>`, `/theme <v>`,
  `/vim`, `/retry`, `/edit <n> <text>`, `/commit`, `/review`, `/init`, plus
  prompt and `!cmd` submission. Web/daemon reach them via `POST /command`
  (queued to the driver thread; result arrives as a `command_result` journal
  event, run-producing commands then execute a normal agent run). Display-only verbs (`/help`,
  `/tools`, …) are terminal-rendered; web/daemon report them as unsupported.
- **Run assembly.** `session_service.buildRunOptions` is the only place App
  state is projected into `agent_loop.Options`; hosts add only host-specific
  fields (UI requester, run-control observers, budgets).
- Equivalence is locked by `apps/cli/tests/component/session_api_parity_test.zig`.

### Edit and rerun

`/edit <n> <text>` edits message `n` of the conversation, one the user wrote,
and reruns from it (#432). Messages are numbered from 1 over the whole
history, compacted ones included. The conversation becomes messages
`1..n-1` followed by `text`, and a run answers it. The original message `n`
and everything after it are dropped: later prompts, replies, tool calls and
tool results. They are discarded, not kept as a branch. In the terminal,
`/edit` alone lists the messages that can be edited with their numbers.

- **Persistence.** Dropping messages rewrites the transcript from the live
  conversation at its next flush (the rewrite `/retry` uses), so a resumed
  session has the edited history, never the dropped one.
- **Refusals** change nothing and run nothing. Each names its reason
  (`conversation.RewindError`): `PositionOutOfRange` (no message `n`),
  `NotUserMessage` (a reply, a tool result, or text the runtime wrote),
  and `PositionCompacted` (the message is behind the compact boundary, so the
  context before it exists only as a summary and cannot be rerun). A message
  at or after the boundary can be edited; the summary stays its preceding
  context, as in every request since the compaction. The command line also
  refuses a number that is not a positive integer (`InvalidPosition`) and a
  missing text.
- **Context only.** Files written, commands run and other effects of the
  dropped turns stay. The must-read-first record is cleared (as by `/clear`),
  since the rerun's context no longer shows what was read.
- **Hosts.** `POST /command` takes the same line; the Run's `user_message`
  line carries the text and `"replaces":n`
  ([Wire lines](#wire-lines-for-out-of-process-hosts)). A Zig Host calls
  `AgentSession.rewindToUserMessage(position)` while idle and then runs the
  edited text; `SessionHost` does both for a submission with `.replaces`
  (see [SessionHost](#sessionhost-a-multi-session-service-for-network-hosts)).
  An AgentCore Host calls `session_control->rewind_to_user_message(session,
  position, out_error)` (revision 27, #441) while idle and then runs the
  edited input: the three refusals are the public statuses
  `MESSAGE_POSITION_OUT_OF_RANGE` (31), `NOT_USER_MESSAGE` (32) and
  `MESSAGE_POSITION_COMPACTED` (33), and a checkpoint exported afterwards
  holds the edited Conversation, so a restored Session continues from it
  (see [Edit and rerun](AGENTCORE_BINARY_ABI.md#edit-and-rerun)).

This is an internal-consistency contract, not yet a wire-protocol stability
promise: the HTTP endpoint shapes remain pre-1.0.

## CLI surface

`metacodes [--state-dir <dir>] --preview teamwork run --request-file <file> --approve
--budget-usd <cap>` runs the approved SWE loop synchronously: implementer,
reviewer, isolated completion verifier, then merge-back into the user's
workspace without committing. `--approve` authorizes the request bytes,
configured harnesses and pinned check, spend up to the positive dollar cap,
and merge-back. No App/provider, seat or worktree starts before approval.
The state root must be outside the repository. All workers, pinned checks
and verifier tools require Sandbox Foundations; an unavailable backend fails
closed. Native and Claude Code implementer/reviewer seats are supported.
Windows has no seat sandbox backend and no workspace tree id, so `teamwork
run`/`resume`/`mcp`, REPL `/teamwork`, `Run.start` and `Run.reopen` fail with
`UnsupportedPlatform` before any run state is written.

Teamwork is the `teamwork` **preview feature**, disabled by default. It uses
the same root `"preview"` in `<state root>/config.json` and the same
`--preview`, `--no-preview`, `--preview=teamwork` and `--no-preview=teamwork`
flags as the other preview features. Flags may precede `teamwork` or follow
the action; the last flag naming the feature wins and overrides the saved value. CLI dispatch
before App initialization and App initialization share `core/file_config.zig`'s
`resolvePreview` (`FileConfig` loading plus `Setting.resolve`). `--preview`
selects the feature; it does not approve a task or authorize spend.

With the feature disabled, start/resume and Manager execution fail with
`PreviewDisabled` before App/provider startup, run creation or recovery,
worker probes, budget admission, auditing or merge-back. A saved approval,
checkpoint or MCP field cannot grant current preview authorization. Read-only
CLI status remains available without loading global configuration. Existing
runtime/MCP handles retain status, cancellation and destruction/cleanup after
host opt-out; only the host's abort signal is safe to change concurrently.

Zig hosts explicitly supply `teamwork_runtime.Deps.preview` (default `.none`),
independently of the approved task configuration. `Run.start`, `reopen`,
`dispatch` and `requestCompletion` require its `teamwork` feature. Production
hosts project the resolved `app.config.preview.features()` and propagate it into native
seat and verifier subagents and worker launch admission. Third-party Claude
Code is gated before probing/launch; it is not passed metacodes-only flags.
This increment adds no AgentCore ABI field: the shared revision-29 preview
setting and SDK bindings come from the preview framework dependency.

Configuration precedence is `<state root>/config.json`'s `teamwork` object,
repository-root `.metacodes/teamwork.json` (a bare teamwork object), then
`--config-json <object>` / `--budget-usd` / `--max-rounds` /
`--check-command`. CLI overrides are applied left to right. `--id <id>`
selects a path-safe run id; otherwise one is generated and printed to stderr.
Provider options are `--provider`, `--model`, `--base-url`, `--api-key`, and
`--verbose`. This CLI uses an already-written request that `--approve`
approves as is, so it runs no interviewer. The Manager is the built-in
deterministic loop unless `seats.manager` names an external harness (see the
launched Manager below); model/effort on the built-in manager is rejected. The verifier
must be native; explicit verifier effort and tier aliases are rejected until
wired.

The request may start with option segments, each in square brackets:
`[skip-interview]` and `[seats=<role>:<harness>[:<model>],...]` (for example
`[seats=reviewer:claude_code,implementer:metacodes:fast]`). Segments are
removed from the request; the rest is the approved text. `seats` is a
configuration layer for this run only, above `.metacodes/teamwork.json` and
below the CLI options; a `claude_code` seat still takes its `command` from a
lower layer. An unknown, duplicated, unterminated or malformed segment fails
with `UnknownTeamworkSegment`, `DuplicateTeamworkSegment`,
`UnterminatedTeamworkSegment` or `InvalidTeamworkSeats` before any state is
created; a request without leading `[` is used byte for byte. A request file
whose own text starts with `[` (such as `[WIP] ...`), which earlier versions
accepted as is, is now refused; start it with any other character. `run.json` and
`teamwork status` record `request_source`: `request_file` (a CLI request
file), `skip_interview`, `interview` (the interviewer's draft approved
unchanged) or `user_edited` (text the user edited, then approved). Runs
saved before this field report `request_file`.

In the REPL, `/teamwork <request>` accepts the same segments and the same
configuration layers. With the `teamwork` preview feature off it prints an error and sends nothing
to the model. Otherwise the interviewer seat (either harness) reads a
disposable snapshot of the workspace and drafts a task statement, charged to
the run's budget ledger. The user answers `y` (approve), `e` (type a
replacement statement, shown again for approval) or `n` (reject). Each prompt
also states what approval authorizes: the dollar cap and seats per role,
every seat's harness and model, the pinned check, and merge-back into the
repository as uncommitted changes. With parallel candidates it also names
each candidate's seat, the judge, the per-candidate estimate and the raised
implementer/reviewer cap; a wallclock-only external seat is marked as having
no dollar cap. Ctrl+C while the interviewer drafts
cancels that seat (as `aborted`, even when the unreported spend of a killed
seat fills the cap) and leaves the next message unaffected. No
implementer, reviewer, worktree or `ORIGINAL_REQUEST.md` exists before
approval; the approved bytes are written to `ORIGINAL_REQUEST.md` unchanged,
then the run continues on a background thread with its own provider client,
and the REPL stays available. While a run is live, the TUI panel above the
input box shows its goal, `N/M done · $spent / $cap · <phase>` and one line
per seat with its harness and status (`queued`, `working`, `needs_you`,
`waiting`, `done`, `failed`); the interviewer is `needs_you` while the
approval prompt waits. `/teamwork status` prints that progress summary for
the session's run; `/teamwork status <id>` prints the same JSON as
`teamwork status`. One run per REPL session at a time; leaving the REPL
cancels an unfinished run, which `teamwork resume <id> --approve` continues
under the same permission mode and sandbox settings. `[skip-interview]` skips
the interviewer: the same prompt shows the request text itself for approval.
After a rejected, failed or cancelled interview nothing has started; the run
directory then holds only the interviewer seat and its `budget.jsonl`, which
`teamwork status` does not read (it has no `run.json`).

`metacodes [--state-dir <dir>] teamwork status <id> [--json]` prints JSON
containing saved state/detail, repository, dispatch counts, audit results,
merge-conflict count, request source, seats and budget totals. It reads only run files: no
global provider configuration, credentials, startup, state rewrite or ledger
repair. A missing budget ledger means no charges yet. A torn budget tail is
reported and excluded from totals; `budget.pending` shows an outstanding
pre-call reservation without consuming, settling or deleting it. Reads during
execution are observations of individually atomic files, not one transaction.
`teamwork resume <id> --preview --approve` resumes from the approval stored with `run.json`.
The approved budget, check, seat models, effective permissions and sandbox
restrictions must match the run's saved fingerprints. Older CLI runs without
a host-policy fingerprint still support status, and need a new approval to run.
A run that reached its cap pauses in `budget_exhausted` with its worktree and
ledger kept; `detail` names the phase it continues from. Parallel candidates
that already have a verdict keep it, and unfinished ones continue in their
worktrees, within the approved rounds per role; a cap that does not cover
their estimate plus a launched Manager's allowance is refused and the run stays paused. A `wallclock_only` seat that ran out of time also ends in
`budget_exhausted`, with `detail: null`: a higher dollar cap would not help,
so it cannot continue. While a launched Manager still holds its allowance,
the run stays locked until that allowance is settled. `teamwork resume <id>
--approve --budget-usd <dollars>` approves a higher cap for such a run and
continues it there. The new cap must exceed the approved cap and the spend so
far, which stays charged against it (`CapNotRaised` otherwise);
`NotResumable` refuses any other run. Without `--budget-usd`, the cap never
changes. Review, audit and merge-back rules are unchanged.
Inherited native seat models are pinned before the first dispatch. Provider
credentials/endpoint can be supplied again. Resume also accepts the originally
saved repository when invoked elsewhere. An OS lifetime lock permits one
driver per run. Ctrl-C forwards cancellation to the run. Exit codes are 0 for
done/status/help, 1 for runtime failure and 2 for invalid input/refusal.

`teamwork run` and `teamwork resume` take `--events`: stdout then carries one
`teamwork.snapshot` wire line once the run is open, a `teamwork.event` line
for every seat status change and phase change, and finally the status JSON
(which has no `v`). The lines are specified in
[WIRE_PROTOCOL.md](WIRE_PROTOCOL.md#16-teamwork-progress-lines) and pinned by
`tests/fixtures/wire/v1/teamwork.jsonl`. A Zig host gets the same events
in-process by setting `teamwork_runtime.Deps.observer` to a
`teamwork_progress.Observer`; each `Event` carries the change and the
`Snapshot` after it, and `teamwork_progress.Board` keeps the latest snapshot
for a host that renders from another thread (`publish`, `read`,
`currentRevision`). `interview.draft` reports the interviewer seat the same
way and `interview.finishApproval` moves it from `needs_you` to `done`. The
AgentCore C ABI has no teamwork entry point, so it carries no teamwork events.

A launched Manager (#545) is configured with `seats.manager` as a
`claude_code` seat (absolute `command`, optional `model`/`effort`) and a
top-level `manager_budget_usd`: its dollar allowance out of `budget_usd`,
greater than zero and below the cap. `teamwork run`, `teamwork resume` and
the REPL's `/teamwork` then start the Manager CLI themselves instead of the
deterministic loop; worker harnesses stay configured per seat, independently
of the Manager's. Before the Manager starts, `budget.jsonl.hold` durably holds
its allowance, which workers and the audit cannot spend; the Manager's
reported cost settles it, and a Manager stopped without a cost report (cancel,
budget, crash, timeout) is charged the whole allowance as `reserved`. Reopening
a run whose Manager was live consumes the hold once and never grants it again;
the next Manager is a new seat (`manager-<n>`) with a new hold. The Manager
runs in Sandbox Foundations with its seat directory as working directory and
only writable root, default permissions with prompts refused, and its tools
limited to the teamwork MCP tools served by the controller in the host
process. The approval prompt names the Manager and its allowance.
Validation errors: `ManagerBudgetMissing`, `ManagerBudgetWithoutExternalManager`,
`InvalidManagerBudget` and `ExternalManagerWallclockOnly`; a Manager CLI that
fails its compatibility probe ends the run `failed` with
`manager_unavailable`. `teamwork mcp` with an external `seats.manager` fails
with `UnsupportedManager`: there the MCP client is the Manager. Windows has no
launched Manager (`UnsupportedPlatform`). `teamwork status` shows an
outstanding hold as `budget.manager_hold` and excludes it from
`remaining_usd`.

`teamwork mcp --request-file <file> --approve --budget-usd <cap>` starts
the same approved lifecycle and serves the [Manager MCP protocol](TEAMWORK_MCP.md)
on stdin/stdout. The built CLI binds `Server.init(gpa, run).serve()`. The CLI host exposes
`teamwork_command.Host.create(arena, app, cfg)` / `Host.deps()` and
`executeWithMcp(arena, app, prepared, ?McpHost)`. The `McpHost.serveFn(gpa,
run)` callback owns stdin/stdout until return; it receives a live approved
`runtime.Run` instead of running the deterministic loop. Without a bound
callback the command refuses before App startup. See
[TEAMWORK_DESIGN.md](TEAMWORK_DESIGN.md) for the runtime contracts.

Budget admission writes `budget.jsonl.pending` before a paid worker/audit
call. A durable charge settles it; restart consumes an unresolved allowance
as `reserved` instead of treating unknown spend as zero. `reserved` is cap
consumption, not a measured bill. With `teamwork mcp` the cap does not
include the MCP client's own Manager model calls; snapshots say so with
`budget.manager: "outside_ledger"`.

The completion auditor's PASS includes the reviewed tree ID. Pinned checks
and verifier probes run in a disposable checkout of that tree. Merge-back
checks full file preimages against a private Git index. Changes to submodule
commit pointers are refused and the candidate and patch are retained.

Teamwork CLI hosts set `Config.mcp_connect = .disabled`: configured outbound
MCP servers (including imported Claude Code config) are not launched. The
built-in tool surface is still published before seat dependencies are built.
This prevents recursive launches of the teamwork endpoint and empty native
seat tool lists. Ordinary CLI/REPL MCP connection modes retain their behavior.

`metacodes --help` enumerates the current flag set and is the authoritative
pre-1.0 surface; `metacodes --version` prints `metacodes <semver>` as its first
line, then the build identity (commit and dirty state, Zig, target and
optimize mode, AgentCore ABI revision, config schema, the ripgrep and TinyKG
versions with the digests the vendored manifests pin for the target, layout).
`metacodes --version --json` prints that identity as one JSON document:
`{name, version, commit, dirty, zig, target, optimize, release_layout,
contract: {binary_abi_version, binary_abi_revision, config_schema_version},
expected_runtime_assets: [{name, version, sha256}]}`, where `sha256` is null
when the vendored bundle has no artifact for the target. `metacodes doctor
[--json | --plain] [--strict]` reports where ripgrep, TinyKG (CLI and daemon) and the two
Lean governance kernels resolve from (`source`: `env`, `config`, `adjacent`,
`path`, `fallback`), the SHA-256 of each resolved file, the digest the file is
held to (the build's pin, or the environment pair's digest for a kernel named by
`METACODES_<FORMAL|PROJECT>_KERNEL_PATH`/`_SHA256`), `match`, and
`provenance`: for the kernels, whether the sidecar beside the kernel is a valid
manifest for *that* kernel (`formal_kernel`: the v4 manifest plus build
receipt; `project_kernel`: the v6 manifest); for `tinykg`/`tinykgd`, whether
the staging receipt beside the binary (`<name>.provenance.json`,
`metacodes.tinykg-binary-receipt/v2`) describes that file (recorded digest,
role, version line, storage contract, and for a bundled binary its bundle key
and source commit), null when there is no receipt; null for ripgrep. A
`provenance` of false fails `--strict`. At a terminal the report is a readable
summary (one line per component, digests shown only on a mismatch, a closing
verdict; colour unless `NO_COLOR`); `--plain`, and any output that is not a
terminal, keep one `key=value` line per check, which scripts parse; `--json` emits
`{checks: [{name, resolved_path, sha256, expected_sha256, match, source,
provenance}]}` with `name` in `ripgrep`, `tinykg`, `formal_kernel`,
`project_kernel`, `tinykgd`, plus a `kg` object when the TinyKG diagnosis could
be built and a `local_config` object for `<state root>/.env`
(`{path, state, accepted, ignored, malformed_lines, permissions}`: the names a
session reads from it and the names it ignores, never a value; `state` one of
`absent`, `read`, `unreadable`, `not_a_file`, `too_large`, `no_state_root`;
`permissions` the POSIX mode as `"0600"`, null on Windows); the plain form adds
a `local_config` line, and neither affects `--strict`. `--strict` exits 1 when a binary is unresolved or mismatched, when a
resolved kernel's `provenance` is not `true`, or when an environment override
was present but resolved nothing (`source: "env"` with a null `resolved_path`);
an unpinned kernel or daemon may be absent. `metacodes terminal-setup
[--dry-run | --restore] [--terminal <name>] [--keybindings <file>]` (also
`/terminal-setup` in the TUI) binds Shift+Enter to a newline in Apple Terminal
or a VS Code build's `keybindings.json` after a backup, and `--restore` undoes
it; it exits 0 when the terminal is set up or needs nothing, 1 when it left the
terminal alone or the change failed ([TERMINAL_SETUP.md](TERMINAL_SETUP.md)).
On macOS and Linux the interactive TUI reports the mouse (`ESC[?1002h`,
`ESC[?1006h`) while it reads keys, so dragging with the left button copies
the text under the drag when the button is released: the TUI sends it as OSC
52 and, in a local session on macOS, also to `pbcopy`, and the prompt shows
`Copied to clipboard`. The TUI keeps a copy of the text it printed and asks
the terminal for the cursor position (`ESC[6n`) to place it on the screen.
Text that other programs printed may not match what the drag covered. While
the mouse is reported, the wheel no longer scrolls the terminal's scrollback
and the terminal's own selection needs its modifier key (Shift in most
terminals, Option in iTerm2). Linux needs a terminal that accepts OSC 52.
Windows keeps the terminal's own selection.
`metacodes mcp add <name> <url> [--type http|sse] [--header <name>=<value>]... [--force] [--no-check]`,
`metacodes mcp add <name> [--env <name>=<value>]... [--force] [--no-check] -- <command> [<arg>...]`
and `metacodes mcp add-json <name> '<json>'` write a server into `mcpServers`
of `<state root>/config.json` (only that member changes; atomic, mode 0600),
taking Claude Code's and Codex's spellings of the same options too, and
`metacodes mcp remove <name>` takes it out. `add` refuses an entry no session
could use, then connects the server once and prints the outcome (a 401 names
`mcp login`; `--no-check` skips it). They exit 0 once the file is written,
whatever the check found; 1 when the name is already configured without
`--force`, is not in `mcpServers` (for `remove`), or the file cannot be read,
parsed or written; and 2 for a usage error or an entry no session could use
([SKILLS_AND_MCP.md](SKILLS_AND_MCP.md#adding-and-removing-servers)).
`metacodes mcp login <server> [--no-browser]` runs the MCP OAuth flow for a
configured HTTP or SSE server and stores the token that later sessions send and
refresh; `metacodes mcp logout <server>` forgets it and `metacodes mcp list`
prints each configured server's transport, how it authenticates and, unless
`--no-check`, whether it connects; they exit
0 on success, 1 when the server is unknown, is not a URL server, already sends
a configured `Authorization`, or the login fails (including a server that
answers the new token with 401 or 403, and a browser that does not come back
within `METACODES_LOGIN_CALLBACK_TIMEOUT_MS`; nothing is stored then), and 2
for a usage error
([SKILLS_AND_MCP.md](SKILLS_AND_MCP.md#authorization-oauth)).
The flag surface is fail-closed: an unknown flag or positional argument exits with code
2 and names the offender — nothing is silently ignored, because evaluation
harnesses pass treatment configuration through this surface. Headless
automation uses `-p/--print` (or `-` for stdin) with `--json`/`--stream-json`
NDJSON output; introspection uses `--dump-prompt` and `--dump-plugins`.
Two independent preview features default to off and are selected only by
their own switches; the shared preview setting neither selects nor blocks them.
`--harnessmm` / `--no-harnessmm`
enables bounded runtime EDGs, guarded reuse of decisions through the native
tool dispatcher, and durable callback-substitution certificates; the
[HarnessMM protocol](HARNESSMM_PROTOCOL.md) defines supported guards and
conservative fallback. `--rsi` / `--no-rsi`, with `--rsi-policy <file>`,
enables the evolved procedural instruction and its own local ridge router
together. With RSI off, its policy is not opened or required; with HarnessMM
off, plans are not admitted and certificates are not read or written. Neither runtime switch
starts optimization. The [RSI protocol](SKILL_RSI_PROTOCOL.md) defines offline
training, budgets, exact features, hash binding and host-origin injection.
Zig consumers use `harnessmm`, `skill_rsi`, and `agent_loop.Options.harnessmm`,
`rsi` / `rsi_policy`. Explicit child
selections use the matching `subagent.SpawnOptions` fields; fresh children
default to no selection, while background root continuation retains it.
The policy is borrowed for the run or job lifetime. Restoring a conversation
does not restore feature permission or execute historical graphs; inactive
host guidance is omitted only from provider projection. C ABI layouts are
unchanged by these selections and AgentCore Sessions do not implicitly inherit CLI features.
`metacodes update [--check] [--version X.Y.Z] [--release-base <url>] [--pull]
[--allow-downgrade] [--no-sdk] [--ignore-running] [--json]` brings the install
the executable belongs to up to date from the source its install record names
(doc/UPDATE_DESIGN.md).
- **Exit codes:** 0 when it is done or there is nothing to do, 1 when it is
  refused or fails, 2 for a usage error, and 3 with `--check` when an update
  or repair is available.
- **`--json` result:** one document on stdout,
  `{action, source, from, to, prefix, origin, sdk, checked_only,
  stopped_services, running_sessions, sessions, services, notes}`.
  - `stopped_services` and `running_sessions` are what a real run did: the
    TinyKG service pids it stopped and the session pids it left running
    (`--ignore-running`). They are always empty under `--check`.
  - `sessions` and `services` are what `--check` found when an update or
    repair is available: the session pids that would refuse the update and
    the TinyKG service pids a real run would stop. The exit code stays 3
    either way. They are always empty without `--check`.
  - `action` is `up_to_date`, `newer_installed`, `upgrade`, `downgrade`,
    `repair` or `rebuild`.
  - `source` is `release` or `checkout`.
  - A failure prints `{action: "refused", error}` instead.
- **Update notice:** an interactive TUI start of a release install offers a
  newer release that a background check, at most once a day, wrote to
  `<state root>/update-check.json`: `1` runs `update` and exits, `3` skips
  that version. `METACODES_NO_UPDATE_CHECK` or `METACODES_NO_PROBE` turns both
  off (doc/UPDATE_DESIGN.md §13).
`metacodes --resume <id>` starts the interactive REPL as a stored session of
the working directory (an id or id prefix, the rule `/resume <id>` uses) with
its conversation, goal and model route restored, and appends to the same
transcript. Under the banner, the REPL writes the conversation back as its
turns were shown live (`apps/cli/src/repl/replay.zig`: prompts, replies and tool cards
through the live rendering paths; at most the last 200 messages, opening at a
typed prompt, after a dim count of the rest; Ctrl+O shows all of it). What the
live view never showed stays out: messages the runtime wrote itself
(`Message.origin = host`, recorded as `"origin":"host"` in `transcript.jsonl`;
a record without the key is the user's or the model's) and text blocks that
ride along with tool results. `/resume <id>` clears the screen and does the
same, then shows the command and what it restored. An id that names no session exits 1 before the REPL starts;
`--resume` beside `-p`/`-`, `--web`, `serve`, `--resume-response`, `--session`,
`--teammate` or `--dump-*` is a usage error. When an interactive session whose
transcript is on disk exits (`/exit`, Ctrl+C or Ctrl+D twice, EOF), the REPL
prints, dim, `Resume this session with:` and `metacodes --resume <id>` (with
`--state-dir <dir>` when that flag chose the state root); a session that never
persisted a turn, and a run whose stdin is not a terminal, print nothing. Every
NDJSON line is valid UTF-8: string fields go through the repository's JSON
encoder, which replaces bytes that are not valid UTF-8 (binary tool output,
such as a PDF read with `Read`) with U+FFFD while `content_bytes` and
`input_bytes` keep counting the raw payload; a `text`/`thinking` delta cut
inside a multi-byte character is held back and rejoined with the next delta of
the same kind, and a character the block ends without completing is emitted
as one U+FFFD line rather than dropped. The terminal `type:"result"` line
includes `usage_status:"known"|"unknown"`: `unknown` means the successful
provider response supplied no readable usage object (including a usage tail
lost after a reported stop), so its numeric usage and cost fields are
placeholders rather than a claim of free work. Explicit numeric zero usage is
`known`. When a configured MCP server did not connect, the result line carries
`mcp_unavailable: [{"name", "detail"}]` (the reason `/mcp` shows, with the
`metacodes mcp login` command for a server that answered 401), and the run
writes one `warning: MCP server '<name>' did not connect: <detail>` line per
server to stderr before it starts; with every server connected, neither
appears. Flag removals or semantic changes require a changelog entry.

### System-One memory advisor (optional)

A self-hosted Jev System-One judge can advise four memory decisions (scoped
recall injection, `KgRecall` evidence, `KgRemember` relations, enumeration
intent). It is off until a service is named: by the `jev` object of the
install's `<state root>/config.json`, each field overridable by its
`METACODES_JEV_*` variable. The CLI names none, so `metacodes doctor` of a fresh
install reports `jev_advisor off … source=none` and nothing of a session
reaches a Jev server (#474; until then the CLI fell back to the built-in
service, plain HTTP to a public address). A host that sets
`Config.jev_builtin_default` (no host in this repository does) falls back to
that built-in service — `metask-jev-4b` at `http://58.211.6.133:10420` in
`advisory` mode, advising `scoped_recall` only — when neither names a `url`.
To use that service from the CLI, write its settings down once
(doc/JEV_SYSTEM_ONE.md §7 has the object). The default applies as a whole: a
layer that names its own `url` starts from the plain defaults (`shadow`, no
model pin, every surface), while one that only sets `mode`, `timeout_ms` or
`decisions` tunes the default service, or tunes nothing when the host takes no
default. An `off` or empty `url` from any layer
(`"jev": false`, `"jev": {"url": "off"}`, `METACODES_JEV_URL=off`) turns it
off; the build exports `METACODES_JEV_URL=off` to every step it runs. It is
evidence only: it never gates a tool, a permission, a budget, or a TinyKG
write. Design, failure semantics and evaluation: [JEV_SYSTEM_ONE.md](JEV_SYSTEM_ONE.md).

| `jev` field | Override | Contract |
|---|---|---|
| `url` | `METACODES_JEV_URL` | judge origin (`http(s)://host[:port]`); absent everywhere means no advisor (the built-in default only for a host that sets `Config.jev_builtin_default`; the CLI does not); `off` or blank disables the advisor |
| `mode` | `METACODES_JEV_MODE` | `shadow` (when unset: consult and journal, provider-visible bytes unchanged) or `advisory` (the built-in default; judgments change injections and annotate `KgRemember` results) |
| `timeout_ms` (integer) | `METACODES_JEV_TIMEOUT_MS` | per-consultation deadline, default 2500, 100–30000; a miss falls back to the unadvised path with no retry |
| `model` | `METACODES_JEV_MODEL` | expected model id; a response from any other model, or one that reports a priced tariff, is refused |
| `decisions` (array of names, or a comma-separated string) | `METACODES_JEV_DECISIONS` (comma-separated) | subset of `scoped_recall`, `memory_relation`, `enumeration_intent` (default: all, except `scoped_recall` alone for the built-in default); a surface left out behaves exactly as with no advisor, and an unknown or empty list disables the advisor; the retired `recall_evidence` is skipped with a warning, so a list naming only it is empty |

An unknown key in the `jev` object, a value of the wrong type, or an invalid
value disables the advisor with a warning rather than falling back to a
default. `metacodes doctor` reports the effective state, URL and source
(`jev_advisor <off|shadow|advisory|invalid> url=… source=<none|default|file|env|file_and_env> error=…`;
`"jev"` in `--json`); it never affects `--strict`.

Every consultation emits a `system_one_decision` event
(`schema_version: metacodes-system-one-decision-v1`): decision, question set,
mode, outcome, `actuated`, request SHA-256, model, latency, and
judged/positive/changed counts. The scoped-recall decision goes to the
evaluation event stream; the tool-surface decisions (KgRecall, KgRemember,
enumeration) go to the session's tool-observation journal. A user interrupt
during a consultation surfaces as `Aborted`, never as a fallback.

### Model tiers

Subagent/skill model pins and `/model` accept tier names — `low`, `mid`,
`high` (legacy aliases `haiku`/`sonnet`/`opus` map to the same tiers) — which
resolve against the current provider's tier table in
`~/.metacodes/config.json`:

```json
"model_tiers": {
  "openai": {
    "low":  {"model": "gpt-5.6-mini", "effort": "medium"},
    "high": {"model": "gpt-5.6-sol",  "effort": "xhigh"}
  }
}
```

The table is keyed by provider kind (`anthropic`/`openai`/`gemini`/`bedrock`;
`bedrock` serves every route on the Bedrock Converse wire, whose tier models
are Bedrock model or inference-profile ids such as
`us.anthropic.claude-haiku-4-5-20251001-v1:0`) so one
user-level file serves any `--provider` session without cross-provider model
injection. An unconfigured tier inherits the session model and effort — there
are no built-in per-provider model IDs. A tier's optional `effort` is the
canonical `none|minimal|low|medium|high|xhigh` scale; each model family's
dialect translates it to its own wire format and level count (OpenAI
`reasoning.effort` full scale; GLM `reasoning_effort` pass-through; Kimi
K2.6/K3 three levels; DeepSeek two levels; MiniMax M3 three states
`disabled|adaptive|enabled` with M2.x always-on; Anthropic adaptive thinking
plus `output_config.effort`, whose vocabulary is `low|medium|high|max` — the
canonical top level `xhigh` is sent as `max` on every Anthropic-compatible
route, including GLM behind the Metask gateway). The picker and the `/model`
status line label that top level with the route's own word: a catalog whose
`capabilities.effort` declares `max` shows `max`, one that declares `xhigh`
(or nothing) shows `xhigh`; `--reasoning-effort max` is accepted as an alias.
Explicit `effort:` in an agent definition wins over the tier's effort. The
built-in `Explore` agent pins the `low` tier.

### Model prices

Cost estimates (the session's cost line, `/cost`, evaluation budgets, the
isolated verifier and the Teamwork ledger) use metacodes' built-in price
table, which charges a model it does not know at the Sonnet fallback rates.
`~/.metacodes/config.json` can price models itself, in USD per million
tokens:

```json
"model_prices": {
  "DeepSeek-V4.1-Flash-1017": {"input": 0.15, "output": 0.6, "cached_input": 0.003}
}
```

A key matches the session's model case-insensitively: the full model id
first, then the id without its first `provider/` segment
(`gateway/acme/model` matches `acme/model`, never `model`; with keys for
both `model` and `acme/model`, the session model `acme/model` takes the
latter). `input` and `output` are required; `cached_input` and
`cache_write` default to `input`. A malformed table (an unknown field, a
negative or non-numeric price) is ignored with a warning, and costs keep the
built-in table. A configured price is a declaration, not a bill: its
evaluation provenance is `user_config_model_prices`.

### Multimodal image input

User messages can carry first-class image content alongside text. Core
represents a conversation block as `Block.image {media_type, data}` (base64
payload, MIME at least `image/png` and `image/jpeg`), ordered freely between
text blocks; the projection to the provider request preserves that order.
Headless runs attach images with `--image <path>` (repeatable, order kept,
png/jpg/jpeg/gif/webp by extension, 3.75 MB raw per image); the prompt text
plus the images become one multimodal user message.

Each provider dialect translates the neutral image block to its native wire
form (`Dialect.serializeImagePart`): Anthropic emits a base64 `image` source
block, OpenAI-compatible endpoints emit an `image_url` data URL content part
(the Responses protocol emits `input_image`), and Gemini emits an
`inline_data` part. Capability is per-model data
(`ModelProfile.supports_image_input` with `ModelProfile.image_input_source`,
queryable as `Capability.image_input` or, with its source, as
`Provider.imageInput`): a model without vision fails a request carrying an
image in user input with `error.ImageInputUnsupported` before any network
I/O — an image in user input is never silently dropped, OCR'd, or replaced
with placeholder text (an image *tool result* that cannot be sent becomes an
explicit placeholder; see below). The truth has three layers, resolved in each
client's `dialectFor` (Anthropic, OpenAI and Gemini alike) through
`Dialect.declareImageInput`: a Host declaration
(`SessionConfig.model_capabilities`, or `SessionHostConfigV1.model_capabilities`
over the AgentCore ABI) outranks the provider's `/v1/models` catalog
(`capabilities.image_input.supported`, parsed into `api/catalog.zig`
`Entry.image_input`), which outranks the model *family* table
(`model_adapter.familyImageInput`, regardless of wire protocol: a `gpt-5.x`,
`gemini-*`, `qwen*-vl`, `glm-4.Nv` or `MiniMax-M3` name is vision on an
Anthropic-compatible route too, issue #112). The family table answers "no"
only for families it knows to be text-only; a name nothing covers is
`image_input_source == .unknown` and fails closed (issue #273: an unknown
route can drop an image without an error, so it is not sent on a guess).
`Provider.supportsForModel` and `Provider.imageInput` answer the same question
for a subagent's `model_override`. Image blocks round-trip through the JSONL
transcript and the AgentCore checkpoint (block tag 5), so restored sessions
resend the original bytes.

Embedders reach the same capability three ways: source-level hosts build
ordered `message.UserContentPart` slices and call `AgentSession.runUserParts`
(or `AdmittedRun.runUserParts`); AgentCore binary consumers submit
`RUN_INPUT_MULTIMODAL` with a `RunInputPartV1` array through
`session_run_input` (capability preflight status 28 — see
[doc/AGENTCORE_BINARY_ABI.md](AGENTCORE_BINARY_ABI.md)); the headless CLI
keeps `--image`.

Tool results can also carry an image: the `Read` tool returns
`{"type":"image","media_type":...,"data":...}` for image files, and every
protocol family now serializes that form natively instead of passing the raw
base64 JSON through as tool-result text. Only the canonical shape counts as
an image (`dialect.extractImageResult`): one JSON object with exactly those
three keys in any order, `type` equal to `image`, a media type from
`types.SUPPORTED_IMAGE_MEDIA_TYPES` (`image/png`, `image/jpeg`, `image/gif`,
`image/webp`), standard base64 of at most `types.MAX_IMAGE_BYTES` of payload,
and only whitespace after the closing brace. Standard JSON whitespace between
tokens does not matter; extra, duplicate or missing keys, JSON escapes (so a
serializer that writes `image\/png` does not produce an image), or more than
`types.MAX_IMAGE_RESULT_BYTES` of raw content do.
Anything else is ordinary text and is bounded by the tool-result projection
like any other result. A canonical image result is exempt from that
projection, from microcompact clearing while it has not yet been delivered
to the provider (delivery is an explicit per-tool_result watermark, persisted in the
transcript, set by the agent loop once the provider has accepted a request
for streaming, i.e. a
stream handle was returned; a request the provider rejects with an HTTP
error does not deliver, a locally appended assistant message is not
delivery, a resumed transcript restores the persisted flags (records written
before this field restore as undelivered until the next accepted request), and a request through a model without image input, which only
carries the placeholder, does not deliver messages holding an image result —
that decision is the serializer's own, carried back on the accepted stream
handle as the tool_use ids whose picture went out as a placeholder
(`StreamHandle.image_placeholder_ids`; `null` = unknown, treated as all
placeholders) rather than re-derived, so it always matches the bytes sent
and a parallel turn's natively-sent siblings are not pinned by one
placeholder (the flag lives on each tool_result block); messages behind the compact boundary and
orphan image results the normalizer strips are delivered regardless, since no
later request can carry them), from `truncateLargeToolResults`, and from the AgentCore
artifact promotion above the operation's cap (`tool_result_cap_bytes` for
built-in and host tools, `mcp_result_cap_bytes` for external tools), so the
picture itself reaches the provider. Two different units apply: context estimation charges one image at
`types.IMAGE_TOKEN_ESTIMATE` (1,600 tokens); the projection turn budget and
the AgentCore payload cap charge it at `IMAGE_RESULT_BUDGET_BYTES` (6,400
budget bytes, four bytes per token). The AgentCore durable budget is charged
the real bytes. Because images bypass the byte budgets, the bytes they put
on the wire are capped separately at `types.MAX_IMAGE_RESULT_BYTES_PER_REQUEST`
(16 MiB, under every wired provider's inline-image request limit): the
projection spills the largest images of the current turn beyond the cap into
artifact envelopes, and before each request the agent loop stubs the oldest
already-delivered image results until the active history fits
(`agent_loop.Options.image_request_bytes_cap`, also applied as the
projection's per-turn image cap). The total counts first-class user images
too (they are never cleared but consume the allowance) and a fresh tool turn
is projected against what the cap leaves after such non-trimmable images.
Only results whose persisted watermark says the picture was received
natively are ever trimmed; when the non-trimmable remainder still exceeds
the cap the agent loop logs it explicitly and lets the provider decide. On Gemini 3, `image/gif`
results travel as a sibling `inline_data` part rather than inside the
multimodal function response, whose `inlineData` accepts only PNG, JPEG and
WebP. A profile whose cap for that operation kind is below 6,400
rejects images of that kind with `checkpoint_payload_resource_limit`. Anthropic keeps the base64 `image`
source block inside the `tool_result` content array (byte-identical to
before). OpenAI chat/completions sends a short pointer as the tool message
(tool message content officially accepts only text) and attaches the image in
an immediately following user message (`image_url` data URL, one text label
per image naming its `tool_call_id`). The OpenAI Responses protocol sends
`function_call_output.output` as an `input_image` content-part array (official
since 2025-09), pairing by `call_id`. Gemini 3 series uses the official
multimodal function response (`functionResponse.parts[].inlineData`,
`ModelProfile.supports_multimodal_function_response`); older Gemini models
receive the image as a sibling `inline_data` part in the same user turn after
all `functionResponse` parts.

The `Read` tool is gated at execution time: the agent loop passes the run's
effective model and `supportsForModel(.image_input, model_override)` into
`ToolContext` (`active_model`, `image_input_supported`), and reading an image
for a model that cannot receive one returns a structured tool error (code
`capability_unsupported`, recoverable) whose detail names the model, the
models on the route whose catalog entry declares image input
(`Provider.visionModels`), and the non-visual alternatives — nothing is read,
encoded, or written to the transcript. When a host does not populate the gate
(`image_input_supported == null`) the image still enters history as before,
and a serializer that finds an image result it cannot send (a model switch
after the read, a fail-closed dialect) emits the short explicit placeholder
`[image (<MIME>) was read successfully but omitted: this model does not
support image input]` — never the multi-megabyte base64 payload and never a
silently wedged session.

Prompt-cache note: a text-only conversation serializes byte-identically to
builds without this feature (OpenAI `content` stays a plain string unless the
message actually contains an image), so existing cache prefixes are
unaffected. Non-image tool results are also byte-identical to before on all
three protocol families.

An image tool result is exempt from the byte-length spilling that
`core/result_projection.zig` applies to oversized results. The per-result cap
is `clamp(window/8, 8 KB, 64 KB)` while the `Read` tool accepts images up to
3.75 MB, so without the carve-out essentially every real screenshot would be
replaced by an artifact envelope before any dialect could serialize it.
Detection reuses `dialect.extractImageResult` (the same single truth the wire
serializers use). Images stay bounded by `Read`'s `MAX_IMAGE_BYTES`, and the
per-turn budget charges one image at `IMAGE_TOKEN_ESTIMATE` rather than its
base64 length, so a screenshot no longer evicts unrelated tool results.

Both caps now come from one place, `core/result_budget.zig`, derived once per
turn from the provider window and handed to `ToolContext.result_budget` as
well as to `result_projection`. A tool that bounds its own output (Bash, whose
two channels share one allowance by max-min fairness) sizes its preview from
that value rather than from a private constant, and spends it in **encoded**
bytes so JSON escaping cannot double the rendered result. When a result is
spilled, its preview is sized from the same budget instead of a fixed 1536
bytes; when the envelope would be larger than the content it replaces, the
result is left inline. The per-turn budget lowers a single water line across
every oversized result rather than evicting the largest one. A result whose
preview was fixed by the streaming capture path is re-rendered against the
budget before commit, and re-inlined outright when the original fits. Text
results therefore no longer project byte-identically to builds before this
change; committed results are still never re-projected for a later request, so
prompt-cache prefixes are unaffected.

"Encoded" is the unit everywhere, including on the two paths that are exempt
from the spill pass and therefore have no second chance: a committed envelope
re-rendered against the budget, and `ReadArtifact`. Both cut their payload by
what it will cost once escaped, and the encoding chosen while budgeting is
carried to whatever renders it rather than being decided a second time.

The Conversation-level pressure valves bound results that entered under a
different budget - a `/resume`d transcript, or a switch to a smaller window.
Their generic head/tail truncation is a text edit, so an artifact envelope is
first offered to `result_projection.shrinkRecoverableEnvelope`, which
re-renders it in place with a smaller preview and every identity field intact.
Anything else structured — a Bash envelope, a non-recoverable fallback, any
tool's large JSON — keeps its shape by trimming only its string values, at any
depth, with every counter that describes a trimmed string corrected as it is
written (`<channel>_truncated`, `preview_head_bytes`, `preview_tail_bytes`, and
`omitted_bytes`, which has to keep satisfying head + tail + omitted ==
original). The short fields are what make a result actionable and are never
what made it oversized.

A structured result that cannot be shrunk — one whose bulk is not in its
strings — is left oversized rather than mangled, and the generic text
truncation is reserved for content that was never structured. Being one request
too large is recoverable; an unparseable result is not. `clearToolResultAt`
already refuses to erase a result's only recovery capability for the same
reason.

Recovery has two primitives rather than one. `ReadArtifact` returns byte
ranges, which costs one round trip per `MAX_READ_BYTES` and cannot answer a
question about the content; `Grep` therefore accepts `artifact_id` in place of
`path` and searches the stored blob directly. The store path is never exposed:
filename output is suppressed, `files_with_matches` — whose entire output would
be that path — is rejected for artifact searches, and the child's stderr is
scrubbed of it before it can reach a tool error.

`ReadArtifact` remains exempt from result projection, but its recovery cost is
bounded per turn. Before the batch executes, the agent loop walks the turn's
tool calls in slot order and charges each `ReadArtifact` call its upper bound,
`result_budget.recoveryReadCost` (`min(MAX_READ_BYTES, per_result_bytes)`).
Every call past `recoveryAllowanceBytes` (`per_turn_bytes / 2`) is deferred: it
does not run, and its result is the bounded body
`{"error":"recovery_allowance_exhausted","artifact_id":<id or null>,"offset":<n>,
"allowance_bytes":<allowance>,"charged_bytes":<charged before this call>,
"hint":<resume from this offset next turn>}` with `is_error` set, plus a
`policy_decision` event whose source is `recovery_allowance`. On a 200K window
four full chunks are served and the fifth is deferred, where nine used to
exceed the turn budget with nothing projection could trim. The decision is made
in slot order at the upper bound before any thread runs, so which call is
deferred never depends on scheduling and provider-visible bytes stay a pure
function of the request.

No staging path is model-visible from Bash at all - not on a completed
channel, not in the auto-backgrounded snapshot, and not on the explicit
`run_in_background` response. All three handed one back for `Read` until they
were replaced by the `job_id` that `BashOutput` already takes. A capture too
large to publish is therefore genuinely unrecoverable, and
`<channel>_storage_error` says which of the reasons it was rather than implying
a handle exists.

Known gap, recorded rather than implied away: `job_id` is itself generated from
random bytes, so it is a random id by the contract's own definition and a
backgrounded command still does not serialize identically across runs. It
cannot simply become a counter, because the same value names the spool file
under a directory shared between processes, where a counter would collide.
Closing it means separating the file identity from the model-visible handle -
tracked with the JobRegistry ownership work, not here. Removing the paths
narrows the exposure to one short opaque token per backgrounded command and
stops leaking the host temp directory; it does not finish the job.

Every budget derived from the context window resolves the model the request
will actually name, not the Provider's own. A subagent shares its parent's
Provider and differs from it only by `model_override`, so sizing a child's
results — or its auto-compact thresholds — against the parent's window is how a
200K parent hands a 32K child a history that endpoint rejects.

### Provider reasoning continuity (DeepSeek, Kimi, MiniMax, Mistral)

Some models want their earlier reasoning back on later requests. DeepSeek's
thinking mode answers HTTP 400 to a tool turn whose assistant history lacks
`reasoning_content`; Kimi asks for the assistant message back unchanged,
reasoning included; MiniMax M3 and later ask for the full response back to keep
the reasoning chain; Mistral asks for the full assistant message back,
ThinkChunks included. Core projects every `Block.thinking` into the request IR
and lets the dialect decide (issues #421, #437):

- A dialect whose profile sets `ModelProfile.echoes_reasoning_content` gets it
  back: DeepSeek, Kimi and MiniMax M3 and later on the OpenAI chat wire,
  OpenRouter routes, and a route declaring DeepSeek on the Anthropic Messages
  wire. OpenAI chat sends the message's thinking text as `reasoning_content` on
  the assistant message (after `content`, before `tool_calls`); Anthropic
  Messages sends the non-empty `thinking` blocks in their original position.
- The Mistral dialect's reasoning models (Small 2603, Medium 3.5, Large 4,
  Magistral; `ModelProfile.content_chunks = .read_and_echo`) get it back as
  ThinkChunks on the OpenAI chat wire: an assistant message with non-empty
  thinking is sent with a list-typed `content` holding
  `{"type":"thinking","thinking":[{"type":"text","text":…}]}` and
  `{"type":"text","text":…}` chunks in their original order, before
  `tool_calls`. The same dialect reads a streamed list-typed `delta.content` the
  same way. A route that declares another dialect for a Mistral-named model
  does neither.
- Every other model is sent exactly the bytes it was sent before: OpenAI
  native and every other compatible dialect (GLM, Qwen, MiniMax M2, and Mistral
  models without documented reasoning), OpenAI Responses, Gemini, and Claude. Claude in particular never receives a
  thinking block: one sent back must carry the signature it was issued with,
  and the IR keeps none.
- The dialect follows the route's declaration
  ([PROVIDER_OFFER_ARCHITECTURE.md](PROVIDER_OFFER_ARCHITECTURE.md)). On the
  Anthropic wire a model name is never inferred as DeepSeek, so a DeepSeek
  Anthropic endpoint configured as a custom provider gets its thinking back only
  when it declares `"dialect": "deepseek"`; the built-in `deepseek` provider
  declares it.

An assistant message holding nothing but thinking (a reply cut off by
`max_tokens` inside its reasoning) is still left out of the request.

### Provider reasoning continuity (OpenAI Responses)

The Responses protocol is used with `store:false`: the server keeps no copy of
the response, so reasoning context survives only if the client sends the
server's own `reasoning` items back on the next request. Core models one as
`Block.reasoning_item {model, json}` — `json` is the item exactly as the
server emitted it (`id`, `summary`, `encrypted_content`), replayed byte for
byte, and `model` is the model that produced it.

This is not `Block.thinking`. A thinking block is readable assistant
reasoning that the UI displays and that only a model asking for its reasoning
back receives (see the previous section); a reasoning item is opaque provider
state that is never displayed, never enters a compaction summary, and never
becomes assistant text. Every dialect other than OpenAI Responses skips it.

Capture is event-independent: the same item may arrive in
`response.output_item.done`, in the terminal `response.completed`'s
`response.output` array, or in both. Both paths extract it and a per-stream
key (the item `id`) keeps it replayed exactly once. On the next request the
items are emitted first among that message's `input` items, matching the
server's own `output` order (reasoning → message/function_call).

Replay is model-scoped: encrypted reasoning state belongs to the model that
produced it, so after a mid-session model switch the stale items are dropped
rather than sent to a model that would reject them. Reasoning items round-trip
through the JSONL transcript and the AgentCore checkpoint (block tag 6), so a
resumed session keeps the continuity. A conversation with no reasoning items
serializes byte-identically to before.

## Web and daemon HTTP surface

`metacodes --web [port]` (one session with the bundled browser UI),
`metacodes serve [port]` (one session) and `metacodes serve --sessions N
[--max-sessions M] [--uds <path>] [port]` (the multi-session daemon: N
sessions at startup, N ≥ 0, then created and destroyed over HTTP, at most M
live) serve one HTTP/1.1 surface (`apps/cli/src/web/server.zig`). Port 0 lets the
kernel pick; the startup line prints the address actually bound,
`<label>: http://<address>:<port>  (Ctrl+C to quit)`.

**Endpoints.** With one session the routes below sit at the root; with
`--sessions N` (any N, 1 included) or `--uds` every session route is under
`/s/<id>/`, and an unknown id, or one being destroyed, is 404. Bodies are JSON
unless noted.

| Method and path | Purpose |
|---|---|
| `GET /health` | Liveness probe: `200 {"status":"ok","version":"<v>","sessions":N}`. `<v>` is the version `metacodes --version` prints on its first line (the semver, plus `+<commit12>` on a development build); `N` is 1, or the number of live sessions the daemon hosts. Never under `/s/<id>/`, never authenticated, and it reads no session, journal or lock. |
| `GET /` | The bundled single-session browser UI; in the `/s/<id>/` daemon, a page listing the live session ids and these endpoints. |
| `GET /events` | SSE stream of the session's wire lines ([Wire lines](#wire-lines-for-out-of-process-hosts): ids `<epoch>-<seq>`, `Last-Event-ID` or `?since=<seq>&epoch=<epoch>`, `event: resync`). |
| `POST /message` | `{"text":"..."}`: queue a prompt; echoed as `user_message`. `429` when the session's queue is full ([below](#web-and-daemon-messages-post-message-and-get-state)). |
| `POST /respond` | `{"id":N,...}`: answer the pending `ui_request` N; 409 when N is not pending. Ids are never reused, also across restarts and a session destroyed and restored, so an answer to an earlier process's request is 409 and never answers a newer one ([WIRE_PROTOCOL.md](WIRE_PROTOCOL.md#15-ui-requests-approvers-expiry-suspended-runs)). |
| `POST /capabilities` | The frontend's [capability frame](WIRE_PROTOCOL.md#2-capability-exchange): `200` with the `capabilities_accepted` line (also journaled), `400` with `capabilities_refused` (nothing changes). From then on a UI request the frame leaves out is journaled as `ui_request_unavailable` and never announced. |
| `POST /command` | `{"cmd":"/verb ..."}`: queue a [service verb](#session-command-surface-ui-neutral); the result arrives as `command_result`. `429` when the session's queue is full. |
| `POST /interrupt` | Interrupt the running generation; 409 when idle. |
| `GET /state` | Session snapshot (model, mode, usage, journal epoch and seq, queue depth, ...). |
| `GET /spans` | The session's recorded spans as one OTLP/JSON `ExportTraceServiceRequest` ([Observability](OBSERVABILITY.md#the-web-trace-view)): every Run of the conversation, in the order its spans ended. `404` when the host records no spans. |
| `GET /trace` | The trace view: the conversation's spans as a waterfall, read from `GET /spans`. |

**Session lifecycle (multi-session daemon only, #254).** These routes sit at
the top level, never under `/s/<id>/`, and go through the same admission
(token, `Host`, `Origin`) as every other route. On `--web` and the
single-session `serve` they are 404. A session id is 24 lowercase hex
characters.

| Method and path | Result |
|---|---|
| `GET /sessions` | `200 {"sessions":[{"session_id","generating","model","permission_mode","pending_request_id"}]}`, live sessions in id order (ids sort by creation time). The fields are read the way `/state` reads them; `pending_request_id` is the pending `ui_request` id, 0 when none. |
| `POST /sessions/create` | Body empty or `{"session_id"?:"<id>","resume"?:bool}`. `201 {"session_id":"<id>","messages":N}`: a new session (the given id, or a generated one), the same as a startup session; `N` is the number of messages restored, 0 for a fresh one. `"resume":true` rebuilds the conversation persisted under that id (its transcript under the state root, the session's goal and its own model route). `400` for a malformed body or id, or `resume` without `session_id`; `409` when the id is live, when it names a destroyed session that is not freed yet (`{"error":"session is still closing"}`; see destroy), or when a fresh create names an id whose transcript is persisted (restore it with `"resume":true`; a fresh create never overwrites a conversation); `404` when `"resume":true` names an id with no transcript; `429 {"error":"session limit reached","max_sessions":M}` at the cap; `503` while the daemon shuts down. A refused create builds nothing and writes nothing. The request holds its connection for the whole session construction, which starts the session's MCP and language servers and can take seconds; a client that gives up waiting may still have created the session, so after a timed-out create it should look in `GET /sessions` (or create again with its own `session_id`, which answers 409 if the first one landed) and destroy what it does not want. |
| `POST /sessions/<id>/resume` | `200 {"session_id":"<id>","live":true}` when the session is live, `404` otherwise; it loads nothing (a caller restores with `create {"resume":true}`). |
| `POST /sessions/<id>/destroy` | `200 {"ok":true,"session_id":"<id>"}` once the session's work has stopped and been joined: its driver (an in-flight run is aborted and its provider request cancelled) and its background work (background agent jobs, swarm teammates, background shell commands); `404` when it is not live. From then on the id resolves nowhere (`/s/<id>/...` is 404); every `GET /s/<id>/events` stream and UDS `attach` receives the aborted run's last events, then `session_lifecycle.closed`, then its transport's close, and ends. The destroy never waits for such readers: the session's memory is freed once the last request using it has finished, normally milliseconds later. Until then the session still owns its directory, and a create with its id answers `409 {"error":"session is still closing"}`; retry. The persisted transcript stays. |

`--max-sessions M` (default 32, M ≥ 1 and ≥ N) caps live sessions; a session
being destroyed no longer counts. With `--sessions 0` the daemon starts with no
session. The UDS `list` op lists the same live sessions.

**Admission.** Each request is judged on its head, before any body byte is
read, in this order:

1. `GET /health` is answered at once.
2. Token: when one is configured (`--web-token <t>`, else
   `METACODES_WEB_TOKEN`; the flag wins), every other request must carry
   `Authorization: Bearer <t>` (scheme case-insensitive). A `GET` may carry
   `?token=<t>` instead, percent-encoded (EventSource cannot set headers, and
   a browser opens the UI as `/?token=<t>`); a `POST` is never authenticated by
   query. Missing or wrong: `401 {"error":"unauthorized"}` with
   `WWW-Authenticate: Bearer`. The comparison takes the same time however many
   leading bytes match. A token is 1 to 4096 visible ASCII bytes. The token is
   never printed or logged; a `--web-token` value is visible to other local
   users in `ps`, so the environment variable is preferred.
3. Host (DNS rebinding): without a token, a `Host` header must name the server
   by `localhost`, `127.0.0.1` (any 127/8 literal) or `[::1]`, with the
   listening port or none; on a non-loopback bind allowed by
   `--web-allow-unauth` an IP literal is accepted as well, since no DNS answer
   can rebind one. Anything else is `403 {"error":"host not allowed"}`. With a
   token, `Host` is not restricted. A request without `Host` is not from a
   browser and passes.
4. Origin (CSRF): a `POST` whose `Origin` is present must be `http://<Host>`,
   or `https://<Host>` behind a TLS-terminating proxy, where `<Host>` is the
   request's own `Host` value (without `Host`: the loopback origins of the
   listening port). Otherwise `403 {"error":"cross-origin POST rejected"}`. A
   valid token does not lift this rule.

**Bind.** `--web-bind <addr>`, else `METACODES_WEB_BIND` (the flag wins),
names the IPv4 or IPv6 literal to bind (`127.0.0.1` by default; `0.0.0.0`,
`::`, `::1`, `[::1]` and specific addresses are accepted; host names, zone
ids and `::ffff:` IPv4-mapped forms are not). An IPv6 socket sets
`IPV6_V6ONLY` explicitly: `::` is dual-stack (IPv4 clients reach it too), any
other IPv6 address is IPv6-only. A bind address that is not loopback (127/8 or
`::1`) needs a token or `--web-allow-unauth`; otherwise the process exits with
code 2 before anything starts and names `METACODES_WEB_TOKEN`. Invalid values
(a malformed address, an empty or non-ASCII token) also exit 2, and
`--web-bind`, `--web-token` and `--web-allow-unauth` without `--web` or
`serve` are argument errors. The environment variables are ignored when no
web surface is requested. Likewise `--sessions`, `--max-sessions` and `--uds`
without `serve`, `--max-sessions` without `--sessions` or `--uds`, a
`--sessions` value that is not a count, `--max-sessions 0`, and N above M exit
with code 2.

The `--uds` transport of `serve` is not HTTP and takes no token: its access
control is the socket file's mode 0600 (owner only).

## Zig source embedding

`src/lib.zig` exports the UI-neutral core. In a consumer, these types are reached
through the module namespaces `mc.agent_session.AgentRuntime`,
`mc.agent_session.RuntimeHost`, and `mc.agent_session.AgentSession` (where
`mc = @import("metacodes-core")`). A host supplies a fixed
provider/workspace/policy configuration, creates sessions, consumes typed events/UI
requests, and destroys sessions before their owning runtime generation.

`RuntimeHost.replace` publishes a fully validated immutable generation for new
sessions. Existing sessions remain pinned to their old generation. Failed staging
does not consume a generation or mutate the active runtime.

Runtime creation validates tool availability, not only tool names: built-ins
that execute through an external binary (`Glob`/`Grep` → ripgrep) fail
creation with `error.ToolDependencyUnavailable` when that executable cannot be
resolved, instead of entering the catalog and failing on their first
invocation. A host can probe the dependency up front with
`mc.util_toolchain.ripgrepPath()` and select a tool set without `Glob`/`Grep`
when it is absent.

The recommended high-level lifecycle is:

```zig
const mc = @import("metacodes-core");

const host = try mc.agent_session.RuntimeHost.create(allocator, .{});
defer host.destroy() catch unreachable; // after all Session defers below
const session = try host.createSession(.{
    .provider_kind = .anthropic,
    .api_key = api_key,
    .model = model,
    .workspace = .{ .root = workspace_root },
    .allowed_tools = &.{ "Read", "Write" },
});
defer session.destroy() catch unreachable;
const result = try session.runText(1, "Summarize the workspace", 4, sink);
_ = result.stop_reason;
```

`EventSink` is a synchronous callback value (`.{ .ctx = ..., .emit = ... }`). Keep
its context, the provider credentials, and `workspace_root` alive until the Session
is destroyed. Use `RuntimeHost.replace` for a staged generation change; do not
mutate a live Session's tool catalog directly.

### Session configuration classes

Each setting belongs to the Session that was configured with it, and changes
in one of five ways:

| Class | Settings | How it changes |
|---|---|---|
| Idle-mutable | model, route (provider kind, OpenAI protocol, endpoint, auth scheme, dialect, credential and model together), permission mode, imported permission rules, prompt profile, reasoning effort, additional directories | `setModel`, `setRoute`, `setPermissionMode`, `updatePermissionRules`, `setPromptProfile`, `setReasoningEffort`, `setAdditionalDirectories`. Only while idle (`error.SessionBusy` otherwise). Input is validated before the Session changes; on error the previous value stays in force. The next Run uses the new value; a Session that inherits this one's permissions (`inheritPermissions`, #445) decides its next tool call with the new rules and directories, and refuses its own `updatePermissionRules`/`setAdditionalDirectories` (`error.PermissionsInherited`). |
| Live-replaceable | API key (the provider credential) | `updateCredential`, idle or during a Run, from any thread or from the Session's own callbacks; never `error.SessionBusy`, and refused only for a poisoned Session or an invalid candidate. Create and restore apply the same rule to `SessionConfig.api_key` (1 to 16 KiB of printable ASCII; `error.InvalidCredentialByte`, `error.EmptyCredential`, `error.CredentialTooLong`). The candidate is validated and copied before anything changes; a refusal keeps the previous credential. A request reads the credential when it is sent (once it holds its connection slot), so every request sent after the call returns uses the new credential, retries, tool providers built earlier and requests still waiting for a connection included; one already sent keeps the old one. See [Credential updates](AGENTCORE_BINARY_ABI.md#credential-updates). |
| Runtime generation | built-in tool set, static and process plugins, provider dialects | `RuntimeHost.replace`. Sessions created afterwards use the new generation; existing Sessions stay on theirs. To move a Session, persist it and restore it with `createRestoredSession` on the new generation. |
| Fixed at create | workspace root/home/state root/shell, artifact store, run journal | Create a new Session, restoring the conversation from a checkpoint or transcript. |
| Identity | Session ID | Never; a restore reuses it. |

Inherited permission decisions hold the lender lock and read a published rule
header stored with that lock. Replacing the lead's own optional rule header
does not change an in-progress decision; publication completes before the
previous rule allocations are freed.

`SessionConfig.reasoning_effort` is carried by every provider request and kept
across `setModel`; a provider without an effort control (Gemini) refuses a
non-null value with `error.AgentEffortUnsupportedProvider`.
`WorkspaceConfig.additional_dirs` widens exactly what the workspace root grants:
`accept_edits` auto-approval of Write/Edit/NotebookEdit and sandboxed shell
writes. It is not named in the system prompt. These two are source-level only;
AgentCore revision 29 does not carry them.

### Permission modes the settings disable

`disableBypassPermissionsMode` and `disableAutoMode`, in any settings layer,
are hard constraints on the mode work runs under, not only on what `/mode`
accepts:

- **Mode switches are refused.** A session that starts in such a mode is
  downgraded to `default` when the settings load. `/mode` on every surface
  and the `--web`/`serve` message's `permission_mode` refuse it (see below).
  `AgentSession.setPermissionMode` returns `error.PermissionModeDisabled` and
  AgentCore `update_permission_mode` returns `INVALID_ARGUMENT` (diagnostic
  `PermissionModeDisabled`); the mode, policy generation and grants stay as
  they were.
- **Spawns do not apply it.** An AgentDef's `permissionMode` (a Task
  subagent, a background job, an in-process teammate) and a forked Skill
  bound to that agent with `agent:` run as `default` instead, and log one
  warning. The Task result carries `"permission_mode_notice": "permissionMode
  bypassPermissions is disabled by settings; the subagent runs as default"`,
  the forked Skill's result opens with the same sentence in brackets, and
  `/agents` marks the mode `(disabled by settings; runs as default)`.
- **Decisions never run under it.** Whatever puts such a mode on a permission
  context, each decision is the one `default` makes
  (`permission/decision.zig` `effectiveMode`), including the ApplyPatch path
  gate and the AgentCore fallback for external Tools.

An `AgentSession`'s settings are only the Host-imported rule layer
(`permission_rules`, `updatePermissionRules`: allow/ask/deny), which has no
way to disable a mode, so the refusal above cannot trigger for a Session today:
the Host owns which modes it offers its users and must not pass one it
forbids. The check is in place for a Session that does carry such settings.

### Wire lines for out-of-process Hosts

A Host that carries a Session over SSE, a WebSocket or a queue serializes
events and UI requests with `mc.protocol.wire` rather than `std.json` over the
kernel structs, so a field renamed inside the kernel shows up as a contract
change instead of silently reaching every client. Each line is one JSON object
with the schema version `v` (currently 1) and a `type`:

```text
{"v":1,"type":"<CoreEvent tag>","data":<payload or null>}
{"v":1,"type":"<CoreEvent tag>","run_id":N,"trace_id":"...","data":...}
{"v":1,"type":"<HostEvent tag>","data":{...}}
{"v":1,"type":"ui_request","id":N,"kind":"permission|ask_question|custom","request":{...}}
{"v":1,"type":"ui_request_closed","id":N,"outcome":"answered|cancelled|malformed"}
{"v":1,"type":"ui_request_unavailable","kind":"...","custom_kind":"...","reason":"..."}
{"v":1,"type":"capabilities_accepted",...}
```

Host events (`user_message`, `run_done`, `command_result`,
`message_rejected`, `session_poisoned`) are what a Host adds around the
kernel's events ([WIRE_PROTOCOL.md](WIRE_PROTOCOL.md#11-host-events)). Runs
are numbered 1, 2, … per Session. A Run's lines run from its `user_message`
to its `run_done`, and every kernel event in between carries its `run_id`
([Runs](WIRE_PROTOCOL.md#12-runs)). The bundled `--web` and `serve` host
journals nothing but these lines.

The normative contract, including which changes keep v1 and which bump
`SCHEMA_VERSION`, is [WIRE_PROTOCOL.md](WIRE_PROTOCOL.md).

A frontend may open its channel with a **capability frame** naming the UI
requests it renders (`wire.parseCapabilities`, `wire.acceptCapabilities`):

```json
{"v":1,"type":"capabilities","ui_requests":["permission","ask_question"],"custom":["video_timeline@1"],"events":["text_chunk"]}
```

Custom kinds carry their version (`<name>@<major>`) and match exactly. Once a
frame is installed, a request it leaves out is not announced: the Host
journals `ui_request_unavailable` (reason `kind_not_declared`,
`custom_kind_not_declared` or `custom_kind_unversioned`) and the tool gets
`RequestOutcome.unrenderable` at once: it fails as without a UI
(`AskUserQuestion` fails with `FrontendCannotRender`, `requestUiCustom`
returns `CustomUiUnsupported`, a permission prompt is denied with no terminal
fallback), and the tool result tells the model the frontend cannot render the
request rather than that the user refused it. A Zig Host that switches over
`RequestOutcome` handles the fourth value. A frame of another version, or a malformed one,
is answered `{"v":1,"type":"capabilities_refused","reason":"<RefusalError>"}`
and changes nothing. A frontend that never declares receives every request,
as before; in-process backends (TUI, headless, the C ABI) never declare.
`frontend_capabilities.route` is the routing rule and `Slot` the per-Session
holder a Host keeps.

`wire.parseResponse` turns the client's answer (`{"choice":...}`,
`{"answers":[...]}` or `{"result":...}`) back into a `UiResponse`; anything
malformed or of another version fails as a cancellation, never as a
grant, and closes as `malformed` (`wire.closedOnParseError`). An answer that
races an interrupt or close loses: it is refused or discarded and the request
closes as `cancelled`. A request nobody answered fails through
`wire.cancelResponse(request, why)`: a permission prompt with the
`ui_request.Unanswered` error naming the timeout, cancellation or unreadable
answer, so the model reads that nobody answered instead of that the user
declined; a question or a custom UI with `InputAborted`
([WIRE_PROTOCOL.md](WIRE_PROTOCOL.md#14-requests-nobody-answered)). `tests/fixtures/wire/v1` pins one line for every event tag and request
kind, plus capability frames with core's reply to each, and doubles as
conformance vectors for Hosts in other languages. The bundled `--web` UI
consumes exactly these lines and declares `permission` and `ask_question`
when it loads.

The `--web` server streams these lines over SSE with ids `<epoch>-<seq>`; the
UDS `attach` op streams the same lines, one per line. Each transport also has
frames of its own that are not journal lines and carry no `v`
([Transport frames](WIRE_PROTOCOL.md#13-transport-frames)). The
epoch names the event journal; a restarted host or a rebuilt session has a new
one. A client resumes with `Last-Event-ID` or `?since=<seq>&epoch=<epoch>`
(`/state` reports both). When the cursor belongs to another epoch, names a
position without an epoch, or lies past the journal's end, the server sends
`event: resync` with
`{"reason":"epoch_changed"|"epoch_unknown"|"cursor_ahead","epoch":...,"from":N}`
and replays from the oldest event it kept; when old events were evicted under
the cursor, the reason is `evicted`. Deduplicate on `(session, epoch, seq)`.

The UDS transport of `serve` takes the frontend's two lines, the answer and
the capability frame, as NDJSON ops, so a UDS-only frontend needs no HTTP side
channel for either. `{"op":"respond","session":"<id>","id":N,...}` answers the
pending `ui_request` N with the same answer fields `POST /respond` takes
beside the routing fields (`{"ok":true}`; a stale or unknown id replies
`{"ok":false,"error":"no pending request with this id"}`, the 409 of the HTTP
surface, and a line without `id` replies `{"ok":false,"error":"missing id"}`).
`{"op":"capabilities","session":"<id>","v":1,"type":"capabilities",...}` is
the capability frame itself
([WIRE_PROTOCOL.md](WIRE_PROTOCOL.md#23-transports)) beside the routing
fields, answered with the `capabilities_accepted` acknowledgement line (also
journaled, like the HTTP route) or `capabilities_refused`.

### Web and daemon messages: `POST /message` and `GET /state`

`--web` and `serve` take a message at `POST /message`, `serve --sessions N`
at `POST /s/<id>/message`:

```json
{"text": "...", "model": "claude-opus-4-6", "permission_mode": "acceptEdits"}
```

The UDS transport's `{"op":"message","session":"<id>",...}` reads the same
three fields with the same checks (replies `{"ok":true}` or
`{"ok":false,"error":"..."}`).

- `text` is required and must not be empty after trimming. A body that is not
  a JSON object is the text itself.
- `model` and `permission_mode` are optional and hold for this message's turn
  and the turns after it. Absent or `null` keeps what is in force; nothing is
  ever reset.
- `permission_mode` takes the names `/mode` takes: `default`, `acceptEdits`,
  `auto`, `dontAsk`, `bypassPermissions`, their underscore and hyphen
  spellings (`accept_edits`, `accept-edits`) and the historical
  `prompt`/`bypass`. Any other value, an empty string or a non-string is
  answered `400 {"error":"invalid permission_mode (...)"}`, a `model` that is
  not a non-empty string `400 {"error":"invalid model: ..."}`, and nothing is
  queued. `200 {"ok":true}` means queued.
- Other fields are ignored, except `idempotency_key`: these hosts do not
  de-duplicate yet, so a message carrying one (not `null`) is refused with
  `400 {"error":"idempotency_key not supported: this host does not de-duplicate messages"}`
  rather than run once per delivery while the client relies on the key
  (#447; [`SessionHost`](#sessionhost-a-multi-session-service-for-network-hosts)
  takes it).

A session queues at most 64 messages and `POST /command` lines together, the
bound `SessionHost` keeps (`max_queued`, #447); the turn in progress is not
one of them. Beyond it a message or a command is refused and nothing is
queued: `429 {"error":"queue full","max_queued":64}` over HTTP,
`{"ok":false,"error":"queue full","max_queued":64}` from the UDS `message`
op. Once the driver takes the next one off the queue, one more fits.
`/state` reports `queued` and `max_queued`.

The session's driver takes messages one at a time, after the turn in progress
and after queued `POST /command`s. For each message it checks the permission
mode (a mode the session's settings disable — `disableBypassPermissionsMode`,
`disableAutoMode` — is refused, as `/mode` refuses it) and the model (tier
names resolve as `/model` resolves them; the model must be usable with the
session's provider), switches to the model for this session only — unlike
`/model`, the login's saved model selection is not written — sets the
permission mode, journals `user_message` and runs the turn. Each field the
message gives is
announced, even when its value was already in force, so the journal for one
message reads, with nothing from the driver in between:

```text
{"v":1,"type":"config_changed","data":{"model":"claude-opus-4-6"}}   if model was given
{"v":1,"type":"config_changed","data":{"mode":"accept_edits"}}      if permission_mode was given
{"v":1,"type":"user_message","data":{"run_id":N,"trace_id":null,"text":"...","replaces":null}}
... the Run's events, each with "run_id":N ...
{"v":1,"type":"run_done","data":{"run_id":N,"trace_id":null,"stop_reason":"end_turn","error_name":null,"model_error":null}}
```

A turn that stops on the model (`api_error`, `max_tokens_exhausted`) says why
on the same line: `model_error` is the structured detail, and its `message` is
the text to show. Every other stop has `"model_error":null`. A Run that fails
without returning (the run control refuses it, or the loop fails) has
`"stop_reason":null` and names the error in `error_name`.

```text
{"v":1,"type":"run_done","data":{"run_id":N,"trace_id":null,"stop_reason":"api_error","error_name":null,"model_error":{"category":"payment_required","code":"insufficient_balance","type":null,"message":"Balance too low","http_status":402,"request_id":"req_1","retry":"not_retryable","retry_after_ms":null,"attempts":1,"truncated":false}}}
```

The fields, what is redacted and how `retry` is decided are specified in
[AGENTCORE_BINARY_ABI.md](AGENTCORE_BINARY_ABI.md#model-failure-detail).
`code` passes through whatever the provider sent: metacodes attaches no billing
or quota meaning to it. `SessionHost` writes the same `run_done` line.

If either field is refused, neither is applied, the text stays out of the
conversation, no turn runs, and this line takes the place of `user_message`:

```text
{"v":1,"type":"message_rejected","data":{"message":"model not available for current provider","text":"...","model":"...","permission_mode":"bypass_permissions"}}
{"v":1,"type":"message_rejected","data":{"message":"bypassPermissions is disabled by settings","text":"...","model":"...","permission_mode":"bypass_permissions"}}
```

`model` and `permission_mode` repeat what the message asked for (`null` when
not given; the mode in the spelling `/state` uses). Every accepted message
therefore ends in exactly one `user_message` or `message_rejected`.
`user_message` is journaled when the turn starts, not when the message is
queued: a message sent during a turn appears after that turn's `run_done`.

Every line is a wire v1 line ([Wire lines](#wire-lines-for-out-of-process-hosts)).
A `config_changed` line has one of `model`, `mode`, `dirs`, `reasoning` or
`route` in `data`, whatever caused the change: a message, `/command` or a
tool. `session_lifecycle` is a kernel event. `user_message`, `run_done`,
`command_result` and `message_rejected` are host events
([WIRE_PROTOCOL.md](WIRE_PROTOCOL.md#11-host-events)). A `/command` is
answered by `command_result`: `command` is the line's verb, `message` what it
reports, and `error_name` is set when `ok` is false. A `/command` that plans a
Run (a prompt, `/edit`, `/retry`, `/commit`, …) journals its `command_result`
first, then the Run's `user_message` (none for a macro or `/retry`). A
`user_message` from `/edit <n> <text>` has `"replaces":n`: the conversation
before the turn is messages `1..n-1` ([Edit and rerun](#edit-and-rerun)).

`GET /state` (`/s/<id>/state`) is the snapshot a client reconciles with after
connecting or reconnecting:

| Field | Meaning |
|---|---|
| `seq`, `epoch` | Journal position of the next line and the journal it belongs to. `seq` never decreases within an epoch; `/events?since=<seq>&epoch=<epoch>` continues exactly after the snapshot. |
| `model`, `permission_mode` | In force now; the mode as `default`, `accept_edits`, `auto`, `dont_ask` or `bypass_permissions`. |
| `generating` | A turn or a command is running. |
| `pending_request_id` | The UI request waiting for `POST /respond`, `0` when none. |
| `queued`, `max_queued` | Messages and `/command` lines waiting for the driver, and the bound beyond which they are refused with `429`. |
| `frontend_capabilities` | The declaration in force (the last `capabilities_accepted` object), `null` while no frontend declared: every request is then announced. |

It also carries `session_id`, `additional_dirs`, token usage and cost, the
agent roster, tasks and `plugin_inventory`.
`apps/cli/tests/component/web_message_config_test.zig` holds both drivers (`--web` and
`serve`, over HTTP and UDS) to this section.

### SessionHost: a multi-session service for network Hosts

`mc.session_host.SessionHost` is what a Host puts behind its own transport
when Sessions are opened and closed by id at runtime (one container serving
many users, a GUI with many tabs). It composes the pieces above instead of
leaving every Host to rebuild them:

- `open(.{ .config, .id, .mode = .fresh | .resume })` creates a Session, or
  restores one from its transcript (`transcript.sessionDir` under the
  Session's state root). A fresh open under an id that has a transcript
  replaces that transcript at once. `open` and `acquire` return a counted
  reference; `release` gives it back.
- `HostedSession.submit(.{ .text, .trace_id, .replaces, .model, .permission_mode })` queues a Run.
  With `.replaces` (a `conversation.MessagePosition`, from
  `MessagePosition.fromOrdinal(n)`), the text replaces user message `n`: just
  before the Run the driver drops that message and everything after it
  (`AgentSession.rewindToUserMessage`), so the Run sees messages `1..n-1`
  plus the text, and the transcript and a later `open(.resume)` hold that
  history ([Edit and rerun](#edit-and-rerun)). The `user_message` line
  carries `"replaces":n`; a refused position ends the Run with `run_done`
  naming it (`PositionOutOfRange`, `NotUserMessage`, `PositionCompacted`)
  and changes nothing.
- A submission may be typed (#447): `source` (where it came from, such as
  `im:lark`), `kind` (`[a-z0-9][a-z0-9_.-]*`, such as `telemetry`),
  `attributes` (name/value strings) and `idempotency_key`. A field outside
  its bounds (`core/typed_submission.zig`) is refused before anything is
  queued: `error.InvalidSource`, `InvalidKind`, `InvalidAttributes`,
  `InvalidIdempotencyKey`. The four are echoed on the Run's `user_message`
  ([WIRE_PROTOCOL.md](WIRE_PROTOCOL.md#11-host-events)) and reach the
  provider only through the Session's template, `open(.{ ...,
  .submission_template })`: `{{text}}`, `{{source}}`, `{{kind}}` and
  `{{attributes}}` (one JSON object) are substituted, and any other `{{` is
  `error.InvalidSubmissionTemplate`. Without a template the Run's input is
  the text, byte for byte, so the provider-visible bytes, a cache contract,
  are those of an untyped submission.
- One idempotency key is one Run. A delivery whose key is queued, running,
  or whose Run started less than `idempotency_retention_ms` ago (24 h) is
  refused with `error.DuplicateSubmission`: nothing is queued, and the first
  delivery's Run answers for it, so a transport reports it as accepted (an
  HTTP Host: `200` and `"duplicate":true`). The same key on a different
  submission (text, source, kind, attributes or `replaces`) is
  `error.IdempotencyKeyReused`. With `transcripts`, started keys are kept in
  the session directory (`idempotency.jsonl`), so a Host that opens the
  Session again under its id after a restart, resumed or fresh, refuses them
  too. A key is spent when its Run starts, whatever the Run then does, and
  not before: a delivery still queued when the Host stopped may be delivered
  again. A key that cannot be recorded fails its Run
  (`IdempotencyKeyNotRecorded`) and stays unspent. At most
  `idempotency_max_keys` (10 000) started keys are kept; the oldest goes
  first.
- A submission may carry its own `model` and `permission_mode` (#445), as a
  `--web`/`serve` message does: the driver applies them just before the
  Run, as `set_model` then `set_permission_mode` queued right ahead of it
  would, and journals each as `config_changed` (`{"model":...}` as
  resolved, `{"mode":...}`) before the Run's `user_message`, also when
  the value was already in force, as `--web`/`serve` does. They stay the
  Session's settings afterwards. The mode is checked first
  (`AgentSession.setPermissionMode`'s check), so when either is refused
  (a mode the settings disable, or a model `Options.models` or the
  Session refuses) nothing is applied, the text stays out of the
  conversation, no Run starts, and `message_rejected` takes the place of
  `user_message`, its `message` saying why in words (the daemon's, such
  as `bypassPermissions is disabled by settings` or `model not available
  for current provider`, where the two refuse alike). Its idempotency key
  is not spent; `model` and `permission_mode` are not part of what a key
  compares.
- With `Options.models` (a `ModelPolicy`), a model name in a submission
  or a `set_model` command resolves as the bundled daemon resolves one
  (`api/model_availability.zig`, shared with `/model` and `--web`/`serve`
  messages): it is trimmed, a tier name (`low`/`mid`/`high`, or
  `haiku`/`sonnet`/`opus`) becomes the model `tiers` (a borrowed
  `model_tiers.TierTable`) sets for the Session's provider kind, and the
  result must be one that provider takes: listed for it in `catalog`
  (`CatalogModel{ provider, id }`, borrowed), or with an id that names it
  (`claude-`, `gpt`/`o1`/`o3`, `gemini`). Anything else, an unset tier
  included, is `error.ModelUnavailable` (`set_model`'s `error_name`) and
  changes nothing. A tier's reasoning effort is not applied, as on the
  daemon. Without `Options.models` the name goes to the Session as it is.
- `SessionHost.setModelCatalog(catalog)` replaces `Options.models`'
  `catalog` while the Host runs (#445), as the daemon adopts a refreshed
  `/v1/models` answer (cached at startup, replaced when the background
  refresh lands). The Host copies `catalog`; from the call on, every
  Session's next `Submission.model` or `set_model` is checked against it
  and no longer against the catalog before (replaced, not merged). The
  model a Session is on stays in force, also when the new catalog no
  longer lists it. Without `Options.models` it is
  `error.ModelPolicyUnset` and nothing is kept.
- The queue holds `max_queued` (64) submissions and commands. Beyond it
  `submit` and `command` refuse with `error.QueueFull` and hold nothing (an
  HTTP Host: `429`); a duplicate is answered as one before the bound is
  checked. `snapshot()` reports `queued` and `max_queued`. Runs the
  driver starts by itself, a cron job's prompt or a team lead's inbox,
  count against the same bound and never take `queued` past it (#493).
- `HostedSession.submit` and `command` (`set_model`, `set_permission_mode`,
  `set_reasoning_effort`, `set_additional_directories`, `set_prompt_profile`,
  `update_permission_rules`, `compact`, `cancel_cron_job`,
  `cancel_all_cron_jobs`, `set_route`) share one FIFO run by the Session's
  driver thread, so configuration changes apply between Runs in the order
  they were queued. Each command is answered by `command_result`. As the
  `--web`/`serve` config sink journals `/model`, `/mode`, `/effort` and
  `/add-dir` (#445), an accepted `set_model`, `set_permission_mode` or
  `set_reasoning_effort` is first journaled as `config_changed`
  (`{"model":...}` as resolved, `{"mode":...}`, `{"reasoning":...}`, `null`
  when the effort was cleared), also when the value was already in force,
  and `set_additional_directories` journals `{"dirs":...}` for each
  directory in force afterwards that was not before, as its resolved path
  (a directory taken away has no line). A refused command journals none.
  The permission mode is journaled by a config sink on the Session's
  permission context, so a mode set any other way is journaled too.
- `command(.{ .set_route = route })` (issue #16, #445) moves the Session
  onto a route the Host's provider control plane bound, as the CLI's
  `/model` commit does (`App.bindCommittedSelection`). `Route.binding` is
  what the Session sends with (`AgentSession.Route`: provider kind, OpenAI
  protocol, auth scheme, dialect, credential, model, base URL); the rest
  says who the route is (`provider_id`, `channel_id`, `protocol`,
  `offer_id`, `credential_ref`, `scope`). `AgentSession.setRoute` swaps
  them together while idle, so no request goes out on a mix of the two
  routes, and keeps the conversation and the reasoning effort; an effort
  the new provider cannot take is `error.AgentEffortUnsupportedProvider`,
  never dropped. An accepted route is journaled as `config_changed`
  `{"model":...}` (the route's model) and then `{"route":{...}}`, as the
  CLI does, before its `command_result`; the credential is in neither. A
  refused route (an invalid model or credential, a busy or poisoned
  Session) changes nothing and journals no `config_changed`. Later
  `set_model` names resolve for the new provider kind, and a teammate the
  Session spawns afterwards runs on its route (`TeammateSpawn.lead_route`,
  which `InheritLead` applies).
- Every kernel event, host event (`user_message`, `run_done`,
  `command_result`, `message_rejected`, `session_poisoned`, `run_resumed`)
  and UI request lands in the Session's `journal` as a wire line;
  CoreEvents carry `run_id` and the submission's `trace_id`. `respond(id, json)` answers a UI request, and
  may name who answered (`"by"`); anything but an open request is
  `error.NoSuchRequest`, a second answer to one that has not yet applied its
  first is `error.AlreadyAnswered`, and neither changes anything (see UI
  requests below).
- `declareCapabilities(allocator, frame)` installs the client's capability
  frame ([WIRE_PROTOCOL.md](WIRE_PROTOCOL.md#2-capability-exchange)) and
  returns, and journals, its `capabilities_accepted` line; a refused frame
  is a `wire.DeclareError` and changes nothing. A UI request the declaration
  leaves out is journaled as `ui_request_unavailable` and answered
  `unavailable` without waiting.
- `interrupt` aborts the Run (or the one being admitted) and answers a
  pending UI request as cancelled; a suspended Run's request is cancelled
  too, and the Run resumes only to record that. A Session the kernel poisoned reports
  `session_poisoned`, drops its queue and refuses further work; close and
  reopen it.
- `close` stops the driver, closes the journal (waking readers), waits only
  for an in-flight `interrupt` to leave the kernel and destroys the Session,
  so the id can be opened again as soon as it returns. It never waits for
  references: a holder keeps a closed `HostedSession` readable (journal,
  `snapshot`) until its own `release`, which frees it last.
- A team lead (`SessionConfig.team` with `.role = .lead`, once its team
  exists) is fed its inbox: while its queue is empty the driver reads it at
  most every `session_host.lead_inbox_poll_ms` (500 ms) with
  `swarm_tools.pollLeadInbox`, and a member's reply becomes the lead's next
  Run, queued behind any work already there and journaled like a submission
  without a `trace_id`. The bundled daemon does the same for its `App` lead.
- A Session that selected the cron tools (`CronCreate`, `CronDelete`,
  `CronList`; admitted only with `RuntimeConfig.enable_cron`) has its
  scheduled prompts fired by its driver, as the CLI fires them once it is
  back at the prompt: while its queue is empty and it has cron jobs, the
  driver calls `AgentSession.takeDueCronPrompts` at most every
  `session_host.cron_poll_ms` (1000 ms), and each prompt due becomes a Run
  typed `source = session_host.cron_source` (`session_host`) and
  `kind = session_host.cron_kind` (`cron_fired`), in the order the jobs were
  created. The Run's user message is the prompt byte for byte; the typing
  reaches the provider only through a submission template. A job never fires
  during a Run or ahead of queued work, and its jobs close with the Session
  (they are not persisted, as in the CLI).
- A Host sees and stops a Session's cron jobs without a Run (#493).
  `snapshot().cron_jobs` lists them oldest first, each a
  `session_host.CronJob`: `id` (a `CronJobId`, the 12 hex digits
  `CronCreate` gave the model), `next_fire_unix` (unix seconds) and
  `schedule`, `.once` or `.recurring` with its cron expression; the prompt
  stays with the model. The list is as of the last time the Session was
  between Runs: a job a Run creates or deletes shows from its `run_done` on,
  and a one-shot job is gone once it fired. `command(.{ .cancel_cron_job =
  id })` removes one job and `command(.cancel_all_cron_jobs)` all of them, in
  queue order like any command; neither job fires again, and a prompt
  already fired and queued still runs. Each is answered by `command_result`
  (`cancel_cron_job`, `cancel_all_cron_jobs`), by which time `snapshot()`
  shows the change; an id the Session does not have is `ok: false`,
  `error_name: "CronJobNotFound"`. `CronJobId.parse(text)` takes a Host's
  text and refuses anything but 12 lowercase hex digits
  (`error.InvalidCronJobId`).
- Fired prompts count against `max_queued` (#493): the driver takes only
  as many due prompts as the queue has room for, oldest job first, and a
  job left out stays due, untouched, and fires once the queue has room. So
  `queued` never passes `max_queued` and no prompt is lost; a recurring job
  is rescheduled, and a one-shot job removed, only when its prompt is
  taken. `AgentSession.takeDueCronPrompts(allocator, limit)` takes that
  limit; `cronJobs`, `cancelCronJob` and `cancelAllCronJobs` are the idle-only
  reads and changes the SessionHost makes. A team lead's inbox is read only
  while the queue has room.
- A Session whose `SessionConfig.run_control` asks for it opens, for every
  Run, the per-Run control the bundled daemon opens
  (`project_rule_activation.RunControl`, #445). It needs a durable
  `run_journal`: anything but the default on an ephemeral Session is refused
  by `open` (`error.RunControlRequiresRunJournal`). With
  `project_rules = .enforced`, an active bundle in
  `<dirname(run journal root)>/project-rules` (the daemon's layout when the
  journal root is the Session's directory) for the workspace root is
  re-attested before the provider request and decides each tool call through
  the project kernel: a call it blocks reaches the model as a
  `project_rule_blocked` tool error. A missing or invalid kernel
  configuration, a bundle that fails attestation, or a Bash job of the
  Session still running or a team it leads (`ProjectRulesRequireDetachedWorkersIdle`)
  fails the Run before any provider request: `run_done` names the error and
  the Run is closed in the journal. Unlike other failed Runs, such a refusal
  does not poison the Session, as the daemon reports the Run failed and
  takes the next message: the submission's text never enters the
  Conversation and the Session is idle again. A refused resumption of a
  suspended Run (`ui_request_wait = .suspend`) keeps the suspension: after
  `ui_request_closed` and `run_resumed`, `run_done` names the error, the
  request's `ui_request` line is journaled again under the same id, the
  Session is `suspended` with that `pending_request_id`, and the request is
  recorded open, so the answer the refused Run took is dropped and a later
  `respond` (also after a restart) resumes the turn. A journal that cannot
  open still poisons. After a Run the bundle is re-attested and the Run's
  operational observation is published beside the journal.
  `abandoned_run = .record_abandoned` closes a Run whose process died as
  abandoned and runs the next one, as the daemon does; the default,
  `fail_closed`, keeps the Session closed (`UnfinishedRun`).
- With `Options.teammates` (a `TeammateFactory`), the SessionHost also
  fulfils the lead's `SpawnTeammate` requests, as the daemon's `App` starts
  its teammates: after each Run the lead's driver takes the pending requests
  oldest first, calls `configure(ctx, arena, spawn)` for the member's
  `SessionConfig` (provider, workspace, tools and permissions are the
  Host's; `spawn` names the lead, team, member, prompt, `agent_type` and
  `effort`), opens it on the same SessionHost as a member of the lead's team
  under the lead's session id and a fresh lease, and submits the prompt as
  its first Run. The factory returns `team = null` (the SessionHost owns the
  identity; anything else is refused). `spawn` also carries the lead's
  current `lead_model`, `lead_permission_mode` and `lead_reasoning_effort`.
  A refused or failed spawn becomes the lead's next Run, so its model learns
  of it: `<teammate-status from="<name>" state="failed">teammate was not
  started: <error></teammate-status>`, journaled as a typed `user_message`
  (`source` `session_host`, `kind` `teammate_spawn_failed`;
  `session_host.spawn_failure_source`/`spawn_failure_kind`). When the name
  was already open and its member refused the prompt, the text says
  `teammate did not take the prompt: <error>` instead. A failure while
  fulfilling such a report Run's own spawns is only logged, so a model that
  keeps asking for a name that cannot start gets one report, not a Run per
  retry (under the `App` the failure is a tool result, bounded by the turn
  limit). A name the lead
  already opened, still open, takes the prompt as its next Run; one whose
  member the Host closed is opened again under a fresh lease, after its old
  roster entry is dropped. Closing the lead closes the members it opened.
  Without a factory the requests stay pending for the Host to fulfil itself
  (open a `.role = .member` Session).
- `session_host.InheritLead{ .base = config }.factory()` is the factory that
  configures each member like its lead, as the bundled daemon's `App`
  teammates are: `base` (the configuration the Host opens its leads with;
  borrowed, outlives the SessionHost) with the lead's current model and
  permission mode, and the spawn's `effort` or else the lead's reasoning
  effort. `InheritLead.derive(base, spawn)` is the same mapping as a pure
  function. `agent_type` is not interpreted. Its factory declares
  `TeammatePermissions.lead`, below.
- `TeammateFactory.permissions` (`TeammatePermissions`, default `.own`) says
  whose permission state a member decides its tool calls with. `.own`: what
  `configure` returned, fixed when the member opened. `.lead`: its lead's
  imported rules, additional directories and Session memory, read at each
  tool call (`AgentSession.inheritPermissions`), as the bundled daemon's
  in-process teammates borrow their lead's permission context: a rule the
  lead gains through `update_permission_rules` or an "allow always"/"deny"
  answer, and a directory it gains through `set_additional_directories`,
  decide the member's next tool call, also inside a Run already going. Both
  Sessions remember answers in the lead's memory. The member's own
  `update_permission_rules` and `set_additional_directories` are refused
  (`command_result{ok:false, error_name:"PermissionsInherited"}`); its
  permission mode, tools, workspace root and the sandbox its shell runs in
  stay what `configure` returned. Locking: each member decision holds the
  lead's `lent_permissions` lock for the whole decision (never across a
  prompt); the lead replaces its rules or directories under that lock and
  frees the old ones after it. The lead's AgentSession outlives its
  members': the lead closes them before destroying its own, and its
  `destroy` waits for any member still being destroyed (permission/lent.zig).

Options: `max_queued`, `max_turns`, `teammates`, `transcripts`,
`ui_request_timeout_ms`, `ui_request_expiry`, `ui_request_wait`,
`idempotency_retention_ms`, `idempotency_max_keys`, `models`.
Authentication, tenancy and the transport stay with the Host.
To stream a Session's journal over SSE, parse the client's position with
`event_journal.Cursor.fromLastEventId` / `fromSince`, start from
`EventJournal.planResume(cursor)` (send `resync` when it reports a restart),
and label lines with `EventJournal.eventId` — the rule the bundled `--web`
server uses.

UI requests on a long-lived Session (#446; the wire side is
[WIRE_PROTOCOL.md §1.5](WIRE_PROTOCOL.md#15-ui-requests-approvers-expiry-suspended-runs)):

- **Approver.** An answer may carry `"by":"<approver>"`, 1 to 256 bytes; the
  request's `ui_request_closed` records it. `respond` refuses any other `by`
  with `error.InvalidApprover` and leaves the request open. `by` is
  self-reported, not authenticated: a Host that needs a verified approver
  sets it from its own authentication (or records the verified identity
  apart), never from the client's answer body.
- **Expiry.** `ui_request_timeout_ms` (null: no limit) and
  `ui_request_expiry`: `.cancel` (default, as before) closes the request
  `cancelled` and the Run goes on without the answer; `.interrupt` does
  that and stops the Run; `.re_announce` journals the same `ui_request` line
  again every period until someone answers. Under `.cancel` and
  `.interrupt` alike, an expired permission prompt is denied and the model
  reads that nobody answered in time, and an expired question or custom UI
  fails with `InputAborted`
  ([WIRE_PROTOCOL.md §1.4](WIRE_PROTOCOL.md#14-requests-nobody-answered)).
  `.re_announce` needs a period: with a zero `ui_request_timeout_ms`, `open`
  is `error.InvalidUiRequestTimeout`.
- **Waiting work.** A Session runs one thing at a time: a submission or
  command queued while a request is open waits behind it, never refused for
  it. `snapshot()` says why in `queue_waiting` (`.none`, `.run`,
  `.ui_request` with `pending_request_id`). A Host that wants the work to run
  at once opens another Session.
- **Suspend mode.** `ui_request_wait = .suspend` (default `.block`; needs
  `transcripts`, else `open` is `error.SuspendRequiresTranscripts`): a
  question or custom UI request ends its Run `suspended` (`Phase.suspended`)
  instead of holding the driver. The Session's directory keeps it
  (`ui_requests.json`, written whole and fsynced, with a result for every
  other call of the suspended turn; the kernel's `suspend.json` is not
  used); `close` leaves it
  there; `open(.resume)` under the id, after a restart too, announces it
  again under the same id; `respond` then resumes the Run once through
  `AdmittedRun.resumeWithResults`, journaled as `ui_request_closed` and
  `run_resumed`. Exactly once, with the transcript as the witness: the
  settlement is recorded before it enters the conversation and dropped once
  the resumed Run's transcript holds the call's result; a crash in between
  applies it on the next open, and an open that finds the result already
  there only drops the record. A call of the suspended turn that the kernel
  did not run (it denied or deferred it) is answered on resume with a result
  saying it did not run. Nothing else runs while a Run is suspended: queued work
  waits, and a team lead does not read its inbox, so a teammate's reply
  waits there, unread, and becomes the lead's next Run after the resumed Run
  and the queue. The resumed Run keeps the suspended Run's `trace_id`, turn
  limit and `stream_retry_budget`. A question's answers reach the model as
  AskUserQuestion's result; a custom UI's `result` is the tool's result as
  is (the kernel's suspension convention); a cancelled or expired request is
  the call failing with `InputAborted`. Request ids are kept too, so none is
  reused across restarts. Each open request has its own id, and `respond`
  gives an answer only to the request it names: a permission request that
  blocks beside a suspended question is answered under its own id
  (`pending_request_id` shows it while it blocks). A `ui_requests.json` this
  version cannot read (corrupt, or written by a later version; a field it
  does not know is ignored) is left as it is and never written over:
  requests then block as under `.block`, under ids past the file's
  `next_id` and past the clock in milliseconds. A Run submitted under an
  idempotency key keeps the key spent while it is suspended, however long
  the request waits; once the resumed Run ends, the key's
  `idempotency_retention_ms` counts from the Run's start as before, so a
  Host whose requests may wait long sets the retention above the longest
  wait plus its redelivery window. One crash window is left: a crash after
  the suspended turn reaches the transcript and before `ui_requests.json`
  records its request loses the request; the next Run finds the call without
  a result and closes it as any unanswered call is closed (message_repair),
  so the conversation stays valid but the question is not asked again. A
  fresh `open` under the id drops a suspended Run with the conversation it
  belonged to. **A permission request is never
  suspended:** the kernel's permission gate reads a `pending` answer as no
  answer and denies the tool unasked, so under `.suspend` a permission
  request blocks as under `.block` (the Session reports `.running` with the
  request pending) and is cancelled by `close`. Making permission requests
  survive a restart needs the kernel to suspend at its permission gate and
  run the approved call on resume; that is follow-up work.

Static trusted plugins can contribute typed tools, streaming tools, services,
advisory policies, and deterministic provider dialects. Process plugins can only
contribute isolated tools through the versioned wire protocol. Neither receives a
mutable AgentLoop, permission, formal, or TinyKG handle.

See [LIB_API.md](LIB_API.md) for the dependency/build wiring and
`example/main.zig` for a complete consumer fixture.

## AgentCore binary embedding

The source-free bundle is one coordinate root: `sdk/metask/agentcore.h`
(C11/C++17), the `sdk/zig` and `sdk/rust` bindings, one target-specific static
library, the manifest-pinned ripgrep runtime asset, and a manifest whose file
allow-list and SHA-256 values are mandatory. Consumers call only
`metask_agentcore_get_api(METASK_AGENTCORE_ABI_V1)` and must validate ABI revision 29,
the exact 80-byte root, all seven mandatory typed tables, reserved zeros, function
slots, and the schema-1 bundle manifest. The ABI is experimental, with no
compatibility shim between revisions: pin a bundle, not only a semantic version.
What the seven tables cover, provider protocol selection, the `on_event`
observation stream and its visible-output tags, input submitted to an active
Run (`session->submit_input`, the `input_adopted` event and the `RunResultV1`
input counts), automatic compaction inside a Run (the model window, a
provider's context-window refusal and checkpoint capacity each compact the
Conversation at a safe boundary and the same Run continues; the summary
request is budgeted and the replacement commits only if the checkpoint fits —
the `auto_compact` event and its `cause`), the structured reason a Run stopped
with `STOP_API_ERROR` (the `model_error` event), each request's own re-issue
after a stream that broke off without an answer and before any tool call
started (#461), and the Host-granted stream retry budget beyond it
(`RunOptionsV1.stream_retry_budget`: a Run re-issues such a request further
times, after output and a started tool call too); for every re-issue of an
attempt that showed output the Host takes back what it showed through the
`discarded` segment, `thinking_discarded` and `retry_notice`, which precedes a
short cancellable backoff, the in-place credential update (`session->update_credential`),
edit-and-rerun (`session_control->rewind_to_user_message` and its three refusal statuses), the Session goal (the `goal` table, goal-continuation Runs, the
`goal_updated` event), the host-scheduled team (`enable_teams`, the `team`
config, and the `team` table's `describe` and `poll`), the Workspace Skill
catalog and its source priorities (`SkillSourceV1.priority` and the query's
`default_user_source_priority` / `default_workspace_source_priority`, which
pick one winner among same-scope sources defining one Skill name), process plugins, Host streaming tools, journal profiles,
and the Completion boundary are specified once in
[AGENTCORE_BINARY_ABI.md](AGENTCORE_BINARY_ABI.md) and not repeated here.

## Tool result contract

All tool origins converge on the same typed result:

```zig
const ToolResultBody = union(enum) {
    @"inline": InlineResult,
    artifact: ArtifactReceipt,
    structured_error: StructuredToolError,
};
```

Unknown or large producers should begin a kernel-owned capture before byte zero.
The capture computes SHA-256, bounded previews, quotas, and CAS publication while
streaming. Conversation receives deterministic inline bytes or an artifact
envelope; `ReadArtifact` restores bounded slices. UI and post-tool observation can
consume the original result without changing model-visible projection.

Results above `per_result_bytes` are sealed during execution and published at the
batch commit boundary. The sealed receipt renders a byte-identical artifact envelope;
publication failure uses `retainInlineAfterFailedPublish`, falling back to inline bytes
when allowed or a bounded `ArtifactPublishFailed` tool error otherwise. Other producers
that still publish during execution are tracked in #65.

Text returned by a tool is UTF-8 encoded at the text boundary and every bounded
text page ends on a code-point boundary. Raw process or document bytes remain
artifacts (or explicit base64 envelopes) and are never written as JSON text.
`TaskOutput` keeps source byte cursors: `output_next_offset` is the cursor for
the next request, `output_size_bytes` is the current source size, and the legacy
`output_total_bytes` field has the cursor value for compatibility. A cursor is
not a JSON or base64 length.

## Prompt-cache contract

For equivalent effective configuration, one provider request must be a byte prefix
of the next request until deliberate compaction. These are never model-visible:

- plugin generation/id/path and activation bookkeeping;
- operation journals, telemetry, TinyKG receipts, timestamps, and random ids;
- staging paths for artifacts or external binaries.

A real tool schema, system instruction, dialect output, conversation append, or
compaction may change the cache key. Tests compare serialized provider requests,
not internal object identity.

Selecting, staging, or explicitly overriding a TinyKG executable does not change
provider-visible bytes. TinyKG receipts and bundle identities remain execution
metadata; only governed memory content deliberately appended at a checkpoint can
change the subsequent request.

An AgentSession prompt profile is frozen into the Session: the same profile
renders the same system prompt on every Run, and replacing it while idle is one
deliberate cache boundary, announced by the next Run's `prompt_manifest`.
Volatile Host facts (the date, page state) belong in per-Run context blocks,
which join the conversation as user-role content after the existing history, so
they extend the cached prefix instead of moving the system prompt. The date is
supplied by default (issue #276): AgentCore leads each Run's context with a
`currentDate` block in the process's time zone, or in a UTC offset the Host
gives per Run (`RunOptionsV1.time_context_code` / `utc_offset_minutes`); a Host
`currentDate` block replaces it, and `TIME_CONTEXT_OFF` drops it. An explicit
Skill invocation Run (`RUN_INPUT_SKILL`) takes context blocks and the date
like any other Run (#534): they lead its invocation record, ahead of the Skill
body. The CLI's
user-context message always states the session's start date and zone, and the
first Run on a later local date gets one "the date has changed" notice in that
turn (`agent_loop.Options.time_announcer`). Source-level Hosts build the same
text with `core.time_context` (`systemZone`, `Zone.fromHostOffset`, `today`).

A Session goal (issue #277) is one objective with an optional token budget.
`core.goal` owns its rules: the transition table (`State.apply`, `update`), and
the `Meter` the agent loop charges per provider response (non-cached input plus
output, automatic compaction included) for every Run that began on an active
goal, however the Run ends. A budget used up mid-Run makes the goal
`budget_limited` and asks the model, once, at the next turn boundary to wrap
up; the Run is not cut off. `AgentSession` owns a goal (`setGoal`,
`updateGoal`, `clearGoal`, `currentGoal`), charges it on every Run, and emits
`CoreEvent.goal_updated`; AgentCore exposes it as the `goal` table and the
`RUN_INPUT_GOAL_CONTINUATION` input kind. A host-scheduled team (issue #277)
is the same core `swarm` seam: with `RuntimeConfigV1.enable_teams` the lead and
member Sessions carry a `SessionHostConfigV1.team`, delegation records a spawn
request the Host fulfils, and the `team` table's `describe` and `poll` read the
roster and take a teammate's reply. The CLI's `/goal` and `/loop` use the
same rules, and every CLI entry point - REPL, web, daemon, forked Skills,
headless - charges the App's goal through `session_service.buildRunOptions` and
writes goal.json when it changes.

## Errors and ownership

Public boundaries use tagged states or explicit error sets. Callback buffers are
borrowed only for the documented call duration. Returned buffers always have a
documented paired release API: AgentCore-owned byte buffers are released with
`api->buffer_release`, while callback-owned buffers are released by the host's
registered release function. Hosts must not retain sink pointers, call mutating
session APIs reentrantly, or destroy a runtime with active sessions. The normative
ownership rules live beside each public header/type and its consumer fixture.

## Teamwork Manager MCP (#522)

The normative Manager protocol is [TEAMWORK_MCP.md](TEAMWORK_MCP.md).
`teamwork/mcp_server.zig` exposes `Server.init(gpa, run: *runtime.Run) Server`,
`handle(self, gpa, line) error{OutOfMemory}!?[]u8`, `serve(self) !void` on
stdin/stdout, and `serveFds(self, input: platform.fs.Fd, output: platform.fs.Fd)
!void`. The host starts an already-user-approved run and retains ownership.
`handle` responses are owned by its allocator; the caller frees them. Serving
uses bounded NDJSON with protocol-only stdout and cancels live runs on EOF.

The tools are `teamwork_status`, synchronous `teamwork_dispatch` (only
implementer/reviewer and optional instructions), `teamwork_run_candidates`
(parallel candidates and the judge, #525), `teamwork_request_completion`
and `teamwork_cancel`. No tool starts or approves a run, replaces the approved
request, changes configuration/budget/check command, or chooses a workspace.
The runtime alone verifies review approval, independently audits and merges;
an unavailable audit cannot complete. Results contain real runtime snapshots
in text and structured content. See the normative document for lifecycle,
error codes, ownership, limits and cancellation semantics, and the
[Claude Code consumer fixture](../examples/teamwork/claude-code-mcp.json) for
host CLI integration.
