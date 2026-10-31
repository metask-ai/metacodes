# API overview

Metacodes exposes several host shapes over one kernel. The fixed AgentLoop,
Conversation projection, permission/sandbox chain, budgets, formal verdicts,
artifact store, and TinyKG admission are not replaceable extensions.

## Compatibility matrix

| Interface | Entry point | Status | Compatibility rule |
|---|---|---|---|
| CLI | `metacodes-<version>-<target-id>/bin/metacodes` (the release unit, `release/LAYOUT.md`; `zig-out/bin/metacodes` in a development tree) | pre-1.0 | flags may evolve with changelog notice; `manifest.json` records version, commit, target, contract numbers and every file's digest |
| Provider control plane | `src/provider/` kernel API | experimental | schema-versioned documents and revisioned mutations |
| Zig source API | `@import("metacodes-core")` | experimental | pin repository commit and Zig toolchain |
| AgentCore C ABI | `metask_agentcore_get_api(1)` | experimental rev 26 | exact root/child layouts and bundle manifest |
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

## Provider selection surface

### Metask device OAuth and gateway

`metacodes login --provider metask` performs the Metask JSON device flow:

* `POST $METASK_SITE_URL/api/oauth/device/code` (default site
  `https://metask-ai.com`) with `client_id=metacodes` and the local hostname;
* polling `POST $METASK_SITE_URL/api/oauth/token` with the device grant until
  approval; and
* atomically storing `access_token`, `refresh_token`, `expires_at`,
  `gateway_url`, `models_url`, and `client_name` in
  `$HOME/.metacodes/oauth/metask.json` (or `METACODES_OAUTH_DIR`).

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
| `--channel <id>` | narrow to one endpoint/region/plan/account binding |
| `--offer <offer-id>` | pin one exact reproducible route |
| `--base-url <url>` | validated against the selected profile and route policy before any request URL is built |
| `--check-providers` | validate the configuration and print every route it produces, then exit; no credential is resolved and no request URL is built |
| `METACODES_STREAM_IDLE_TIMEOUT_MS` | stream liveness, **head phase**: a request whose connection stays open but delivers no byte before the response head for this long (default 120000; 0 disables liveness monitoring entirely) is shut down by the client's monitor and retried as a transient network error. Nothing in a blocked socket read notices an abort flag; this is what turns a silent gateway or proxy into a bounded failure instead of a frozen session. Progress is measured per SSE line, not per parsed event: a tool call's `input_json_delta` frames and unknown events keep the request alive, but keepalive lines (`event: ping`, `data: {"type":"ping"}`, `:` comments) do not — they prove the gateway connection is up, not that the model is producing (2026-09-23: a gateway pinged every 15 s for 55 minutes over an upstream that produced nothing) |
| `METACODES_STREAM_BODY_IDLE_TIMEOUT_MS` | stream liveness, **body phase** (response head accepted): unset = automatic, `clamp(max_tokens × 100 ms, 600000, 1800000)` — a gateway may generate an entire tool call before writing a byte of it, so the tolerated silence scales with the response the request allows; an explicit value is a flat limit in ms; 0 disables body-phase monitoring. Past the limit the client shuts the connection down, the turn ends with `StreamStalled` and the TUI reports `正文空闲超时: <idle> ms 内无任何字节(上限 <limit> ms)` when the connection itself went silent, or `<idle> ms 内无模型输出,但网关 keepalive 仍在到达(最近字节 <n> ms 前)…` when a gateway kept the connection alive over a dead upstream — instead of the generic failure text. A user cancel (Ctrl+C/Esc) that wakes the blocked read is reported as an abort, never as an API error, and the streamed prefix is kept as partial text. A body-phase stall after visible output (text, thinking or a tool call) is not retried automatically in the TUI (the streamed prefix cannot be pretended away); a stall, a stream that ended without a stop report, or a dropped connection before any visible output is re-sent once (an in-stream server error, reported as `API 错误帧: …` on every wire, is not). Independently of this limit, once an endpoint has been seen to send keepalives mid-stream (three pings or SSE comments, each ending a silence of at least 2 s), a streamed body with no byte at all, keepalives included, for max(4 × the longest such interval, 2 minutes) is judged a dead connection and reported as `连接已断: <n> ms 内无任何字节,连 keepalive 也没有…`; 0 here disables that rule as well |
| `metacodes login --provider <id> --oauth-token-json <file>` | import an OAuth token into that provider's own store; refresh, single flight, and rotated-refresh persistence then run themselves |
| `metacodes login --provider <id> [--key-page <page>] [--api-key-stdin] [--no-check]` | for a provider that declares key pages instead of a sign-in (`zai-coding-plan`): open the plan page, read the pasted key with echo off (or from stdin), check it with a GET the provider does not bill, and store it in `<state root>/keys/<id>.json` (0600). Only that provider's resolution reads the file, after its environment aliases; `metacodes logout --provider <id>` removes it. `METACODES_KEY_CHECK_URL` (https, or http to a loopback host) replaces the check URL for a local mock |
| `~/.metacodes/config.json` | `schema_version`, `config_revision`, `providers` (with per-provider `credentials` by environment-variable reference), `custom_providers`, `provider_catalogs`, `aliases`, `global_selection`, `recent_operation_ids`; written atomically, other keys preserved. The same file declares MCP servers under `"mcpServers"` (Claude Code's schema; the legacy `"mcp_servers":[{"name":"<id>","command":[...]}]` array still works), and Claude Code's `~/.claude.json` / `.mcp.json` and Codex's `config.toml` servers are read too — see [Skills and MCP servers](SKILLS_AND_MCP.md). Each connected server's tools register as deferred `mcp__<id>__<tool>` (listed under the prompt's `# Deferred tools`, activated with `ToolSearch select:mcp__<id>__<tool>`), `/mcp` shows every configured server and why any failed, and `ListMcpResourcesTool` fails with `capability_unsupported` when nothing is |
| `<session_dir>/runtime-selection.json` | `session_selection`; a session-scoped choice never reaches `config.json` |
| `src/provider/control_plane.zig` | `model.list`, `model.describe`, `selection.validate`, `selection.resolve`, `selection.commit`, `quote.estimate`, replayable event journal |

Interactive surfaces: `Ctrl+O` and `/model` open the route picker (transcript
viewing moved to `Ctrl+X Ctrl+O`, also `/transcript`); `/providers` lists routes
and takes `refresh`, `enable <id>`, `disable <id>`, `remove <id>`; `/alias`
names a route (`pin`, `float`, `use`, `remove`); `/models` still selects the
account key; `/login` opens a Login pane listing the providers this
installation can sign in to (Metask's own device grant included), and
`/login <id> [--device-code] [--no-browser] [--client-id <client>]` starts that
provider's sign-in directly; either runs the kernel OAuth flow on a worker
thread (`Esc` cancels it) and stores the login where
`metacodes login --provider <id>` does (issue #33); `--client-id` is needed
only when neither the profile nor `providers.<id>.oauth_client_id` in
`~/.metacodes/config.json` names the installation's registered client (#87). Choosing a route whose
OAuth-capable provider has no credential signs in inside the picker: the
authorization URL or device code is drawn in the overlay, `Esc` cancels the
flow, and the chosen route is committed once the login lands (issue #67). A
provider that takes a pasted key instead (`zai-coding-plan`) is listed in
`/login` as "API key", and choosing one of its routes without a key shows its
key pages in the picker: ↑/↓ picks the plan, Tab opens the page, the key is
typed masked, and Enter checks and stores it before the route is committed.

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
share one input pipeline (`src/session_intent.zig` + `src/session_service.zig`):

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
  `/vim`, `/retry`, `/commit`, `/review`, `/init`, plus prompt and `!cmd`
  submission. Web/daemon reach them via `POST /command` (queued to the driver
  thread; result arrives as a `command_result` journal event, run-producing
  commands then execute a normal agent run). Display-only verbs (`/help`,
  `/tools`, …) are terminal-rendered; web/daemon report them as unsupported.
- **Run assembly.** `session_service.buildRunOptions` is the only place App
  state is projected into `agent_loop.Options`; hosts add only host-specific
  fields (UI requester, run-control observers, budgets).
- Equivalence is locked by `tests/component/session_api_parity_test.zig`.

This is an internal-consistency contract, not yet a wire-protocol stability
promise: the HTTP endpoint shapes remain pre-1.0.

## CLI surface

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
be built. `--strict` exits 1 when a binary is unresolved or mismatched, when a
resolved kernel's `provenance` is not `true`, or when an environment override
was present but resolved nothing (`source: "env"` with a null `resolved_path`);
an unpinned kernel or daemon may be absent. `metacodes terminal-setup
[--dry-run | --restore] [--terminal <name>] [--keybindings <file>]` (also
`/terminal-setup` in the TUI) binds Shift+Enter to a newline in Apple Terminal
or a VS Code build's `keybindings.json` after a backup, and `--restore` undoes
it; it exits 0 when the terminal is set up or needs nothing, 1 when it left the
terminal alone or the change failed ([TERMINAL_SETUP.md](TERMINAL_SETUP.md)).
`metacodes mcp login <server> [--no-browser]` runs the MCP OAuth flow for a
configured HTTP or SSE server and stores the token that later sessions send and
refresh; `metacodes mcp logout <server>` forgets it and `metacodes mcp list`
prints each configured server's transport and how it authenticates; they exit
0 on success, 1 when the server is unknown, is not a URL server, already sends
a configured `Authorization`, or the login fails, and 2 for a usage error
([SKILLS_AND_MCP.md](SKILLS_AND_MCP.md#authorization-oauth)).
The flag surface is fail-closed: an unknown flag or positional argument exits with code
2 and names the offender — nothing is silently ignored, because evaluation
harnesses pass treatment configuration through this surface. Headless
automation uses `-p/--print` (or `-` for stdin) with `--json`/`--stream-json`
NDJSON output; introspection uses `--dump-prompt` and `--dump-plugins`.
`metacodes update [--check] [--version X.Y.Z] [--release-base <url>] [--pull]
[--allow-downgrade] [--no-sdk] [--ignore-running] [--json]` brings the install
the executable belongs to up to date from the source its install record names
(doc/UPDATE_DESIGN.md).
- **Exit codes:** 0 when it is done or there is nothing to do, 1 when it is
  refused or fails, 2 for a usage error, and 3 with `--check` when an update
  or repair is available.
- **`--json` result:** one document on stdout,
  `{action, source, from, to, prefix, origin, sdk, checked_only,
  stopped_services, running_sessions, notes}`.
  - `action` is `up_to_date`, `newer_installed`, `upgrade`, `downgrade`,
    `repair` or `rebuild`.
  - `source` is `release` or `checkout`.
  - A failure prints `{action: "refused", error}` instead.
`metacodes --resume <id>` starts the interactive REPL as a stored session of
the working directory (an id or id prefix, the rule `/resume <id>` uses) with
its conversation, goal and model route restored, and appends to the same
transcript. Under the banner, the REPL writes the conversation back as its
turns were shown live (`src/repl/replay.zig`: prompts, replies and tool cards
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
`known`. Flag removals or semantic changes require a changelog entry.

### System-One memory advisor (optional)

A self-hosted Jev System-One judge can advise four memory decisions (scoped
recall injection, `KgRecall` evidence, `KgRemember` relations, enumeration
intent). It is configured by the `jev` object of the install's
`<state root>/config.json`, each field overridable by its `METACODES_JEV_*`
variable. A host that sets `Config.jev_builtin_default` (the CLI does) falls
back to the built-in service — `metask-jev-4b` at `http://58.211.6.133:10420`
in `advisory` mode, advising `scoped_recall` only, plain HTTP over the public
network — when neither names a `url`; an embedder that leaves it off has no
advisor unless one of them does. The default applies as a whole: a layer that
names its own `url` starts from the plain defaults (`shadow`, no model pin,
every surface), while one that only sets `mode`, `timeout_ms` or `decisions`
tunes the default service. An `off` or empty `url` from any layer
(`"jev": false`, `"jev": {"url": "off"}`, `METACODES_JEV_URL=off`) turns it
off; the build exports `METACODES_JEV_URL=off` to every step it runs. It is
evidence only: it never gates a tool, a permission, a budget, or a TinyKG
write. Design, failure semantics and evaluation: [JEV_SYSTEM_ONE.md](JEV_SYSTEM_ONE.md).

| `jev` field | Override | Contract |
|---|---|---|
| `url` | `METACODES_JEV_URL` | judge origin (`http(s)://host[:port]`); absent everywhere means the built-in default (CLI) or no advisor (embedders); `off` or blank disables the advisor |
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

The table is keyed by provider kind (`anthropic`/`openai`/`gemini`) so one
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

### Provider reasoning continuity (OpenAI Responses)

The Responses protocol is used with `store:false`: the server keeps no copy of
the response, so reasoning context survives only if the client sends the
server's own `reasoning` items back on the next request. Core models one as
`Block.reasoning_item {model, json}` — `json` is the item exactly as the
server emitted it (`id`, `summary`, `encrypted_content`), replayed byte for
byte, and `model` is the model that produced it.

This is not `Block.thinking`. A thinking block is readable assistant
reasoning that the UI displays and the Anthropic dialect replays as a
`thinking` block; a reasoning item is opaque provider state that is never
displayed, never enters a compaction summary, and never becomes assistant
text. Every dialect other than OpenAI Responses skips it.

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
live) serve one HTTP/1.1 surface (`src/web/server.zig`). Port 0 lets the
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
| `POST /message` | `{"text":"..."}`: queue a prompt; echoed as `user_message`. |
| `POST /respond` | `{"id":N,...}`: answer the pending `ui_request` N; 409 when N is not pending. |
| `POST /capabilities` | The frontend's [capability frame](WIRE_PROTOCOL.md#2-capability-exchange): `200` with the `capabilities_accepted` line (also journaled), `400` with `capabilities_refused` (nothing changes). From then on a UI request the frame leaves out is journaled as `ui_request_unavailable` and never announced. |
| `POST /command` | `{"cmd":"/verb ..."}`: queue a [service verb](#session-command-surface-ui-neutral); the result arrives as `command_result`. |
| `POST /interrupt` | Interrupt the running generation; 409 when idle. |
| `GET /state` | Session snapshot (model, mode, usage, journal epoch and seq, ...). |

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
| Idle-mutable | model, permission mode, imported permission rules, prompt profile, reasoning effort, additional directories | `setModel`, `setPermissionMode`, `updatePermissionRules`, `setPromptProfile`, `setReasoningEffort`, `setAdditionalDirectories`. Only while idle (`error.SessionBusy` otherwise). Input is validated before the Session changes; on error the previous value stays in force. The next Run uses the new value. |
| Live-replaceable | API key (the provider credential) | `updateCredential`, idle or during a Run, from any thread or from the Session's own callbacks; never `error.SessionBusy`, and refused only for a poisoned Session or an invalid candidate. Create and restore apply the same rule to `SessionConfig.api_key` (1 to 16 KiB of printable ASCII; `error.InvalidCredentialByte`, `error.EmptyCredential`, `error.CredentialTooLong`). The candidate is validated and copied before anything changes; a refusal keeps the previous credential. A request reads the credential when it is sent (once it holds its connection slot), so every request sent after the call returns uses the new credential, retries, tool providers built earlier and requests still waiting for a connection included; one already sent keeps the old one. See [Credential updates](AGENTCORE_BINARY_ABI.md#credential-updates). |
| Runtime generation | built-in tool set, static and process plugins, provider dialects | `RuntimeHost.replace`. Sessions created afterwards use the new generation; existing Sessions stay on theirs. To move a Session, persist it and restore it with `createRestoredSession` on the new generation. |
| Fixed at create | provider kind, OpenAI protocol, auth scheme, base URL, workspace root/home/state root/shell, artifact store, run journal | Create a new Session, restoring the conversation from a checkpoint or transcript. |
| Identity | Session ID | Never; a restore reuses it. |

`SessionConfig.reasoning_effort` is carried by every provider request and kept
across `setModel`; a provider without an effort control (Gemini) refuses a
non-null value with `error.AgentEffortUnsupportedProvider`.
`WorkspaceConfig.additional_dirs` widens exactly what the workspace root grants:
`accept_edits` auto-approval of Write/Edit/NotebookEdit and sandboxed shell
writes. It is not named in the system prompt. These two are source-level only;
AgentCore revision 26 does not carry them.

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
{"v":1,"type":"ui_request","id":N,"kind":"permission|ask_question|custom","request":{...}}
{"v":1,"type":"ui_request_closed","id":N,"outcome":"answered|cancelled|malformed"}
{"v":1,"type":"ui_request_unavailable","kind":"...","custom_kind":"...","reason":"..."}
{"v":1,"type":"capabilities_accepted",...}
```

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
malformed or of another version is answered as a cancellation, never as a
grant, and closes as `malformed`. An answer that races an interrupt or close
loses: it is refused or discarded and the request closes as `cancelled`. `tests/fixtures/wire/v1` pins one line for every event tag and request
kind, plus capability frames with core's reply to each, and doubles as
conformance vectors for Hosts in other languages. The bundled `--web` UI
consumes exactly these lines and declares `permission` and `ask_question`
when it loads.

The `--web` server streams these lines over SSE with ids `<epoch>-<seq>`. The
epoch names the event journal; a restarted host or a rebuilt session has a new
one. A client resumes with `Last-Event-ID` or `?since=<seq>&epoch=<epoch>`
(`/state` reports both). When the cursor belongs to another epoch, names a
position without an epoch, or lies past the journal's end, the server sends
`event: resync` with
`{"reason":"epoch_changed"|"epoch_unknown"|"cursor_ahead","epoch":...,"from":N}`
and replays from the oldest event it kept; when old events were evicted under
the cursor, the reason is `evicted`. Deduplicate on `(session, epoch, seq)`.

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
{"user_message":"..."}
... the turn's events ...
{"run_done":{"stop_reason":"end_turn","err":null}}
```

If either field is refused, neither is applied, the text stays out of the
conversation, no turn runs, and this line takes the place of `user_message`:

```text
{"message_rejected":{"message":"model not available for current provider","text":"...","model":"...","permission_mode":"bypass_permissions"}}
{"message_rejected":{"message":"bypassPermissions is disabled by settings","text":"...","model":"...","permission_mode":"bypass_permissions"}}
```

`model` and `permission_mode` repeat what the message asked for (`null` when
not given; the mode in the spelling `/state` uses). Every accepted message
therefore ends in exactly one `user_message` or `message_rejected`.
`user_message` is journaled when the turn starts, not when the message is
queued: a message sent during a turn appears after that turn's `run_done`.

`config_changed` lines, whatever caused the change (a message, `/command`, a
tool), are wire v1 lines whose `data` holds one of `model`, `mode`, `dirs`,
`reasoning` or `route`. The other host lines (`user_message`, `run_done`,
`command_result`, `message_rejected`, `session_lifecycle`) keep their
`{"<name>":...}` shape.

`GET /state` (`/s/<id>/state`) is the snapshot a client reconciles with after
connecting or reconnecting:

| Field | Meaning |
|---|---|
| `seq`, `epoch` | Journal position of the next line and the journal it belongs to. `seq` never decreases within an epoch; `/events?since=<seq>&epoch=<epoch>` continues exactly after the snapshot. |
| `model`, `permission_mode` | In force now; the mode as `default`, `accept_edits`, `auto`, `dont_ask` or `bypass_permissions`. |
| `generating` | A turn or a command is running. |
| `pending_request_id` | The UI request waiting for `POST /respond`, `0` when none. |
| `frontend_capabilities` | The declaration in force (the last `capabilities_accepted` object), `null` while no frontend declared: every request is then announced. |

It also carries `session_id`, `additional_dirs`, token usage and cost, the
agent roster, tasks and `plugin_inventory`.
`tests/component/web_message_config_test.zig` holds both drivers (`--web` and
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
- `HostedSession.submit` and `command` (`set_model`, `set_permission_mode`,
  `set_reasoning_effort`, `set_additional_directories`, `set_prompt_profile`,
  `update_permission_rules`, `compact`) share one FIFO run by the Session's
  driver thread, so configuration changes apply between Runs in the order
  they were queued.
- Every kernel event, host event (`user_message`, `run_done`,
  `command_result`, `session_poisoned`) and UI request lands in the
  Session's `journal` as a wire line; CoreEvents carry `run_id` and the
  submission's `trace_id`. `respond(id, json)` answers a UI request;
  anything but the pending id is `error.NoSuchRequest`.
- `declareCapabilities(allocator, frame)` installs the client's capability
  frame ([WIRE_PROTOCOL.md](WIRE_PROTOCOL.md#2-capability-exchange)) and
  returns, and journals, its `capabilities_accepted` line; a refused frame
  is a `wire.DeclareError` and changes nothing. A UI request the declaration
  leaves out is journaled as `ui_request_unavailable` and answered
  `unavailable` without waiting.
- `interrupt` aborts the Run (or the one being admitted) and answers a
  pending UI request as cancelled. A Session the kernel poisoned reports
  `session_poisoned`, drops its queue and refuses further work; close and
  reopen it.
- `close` stops the driver, closes the journal (waking readers), waits only
  for an in-flight `interrupt` to leave the kernel and destroys the Session,
  so the id can be opened again as soon as it returns. It never waits for
  references: a holder keeps a closed `HostedSession` readable (journal,
  `snapshot`) until its own `release`, which frees it last.

Options: `max_queued`, `max_turns`, `transcripts`, `ui_request_timeout_ms`.
Authentication, tenancy, idempotency and the transport stay with the Host.
To stream a Session's journal over SSE, parse the client's position with
`event_journal.Cursor.fromLastEventId` / `fromSince`, start from
`EventJournal.planResume(cursor)` (send `resync` when it reports a restart),
and label lines with `EventJournal.eventId` — the rule the bundled `--web`
server uses.

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
`metask_agentcore_get_api(METASK_AGENTCORE_ABI_V1)` and must validate ABI revision 26,
the exact 80-byte root, all seven mandatory typed tables, reserved zeros, function
slots, and the schema-1 bundle manifest. The ABI is experimental, with no
compatibility shim between revisions: pin a bundle, not only a semantic version.
What the seven tables cover, provider protocol selection, the `on_event`
observation stream and its visible-output tags, input submitted to an active
Run (`session->submit_input`, the `input_adopted` event and the `RunResultV1`
input counts), the in-place credential update (`session->update_credential`), the Session goal (the `goal` table, goal-continuation Runs, the
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
`currentDate` block replaces it, and `TIME_CONTEXT_OFF` drops it. The CLI's
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
