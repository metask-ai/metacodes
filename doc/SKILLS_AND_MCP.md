# Skills and MCP servers

metacodes keeps its own Skills and MCP configuration under its state root
(`~/.metacodes` unless `--state-dir`, `METACODES_HOME` or the install manifest
chooses another), and also reads what Claude Code, Codex and Metacode users
already have,
with each tool's own semantics. This page is the contract for the CLI hosts
(terminal REPL, `--web`, `serve`). AgentCore keeps the narrower,
`.agents/skills`-only policy described in
[AGENTCORE_BINARY_ABI.md](AGENTCORE_BINARY_ABI.md).

## Skills

Short procedural instructions can also be evolved offline and gated by a local
ridge router. Together they form the preview RSI feature (`--preview --rsi`), independent of
[HarnessMM runtime reuse](HARNESSMM_PROTOCOL.md) and distinct from the
`SKILL.md` catalog and its activation/tool policy. See
[Procedural skill RSI](SKILL_RSI_PROTOCOL.md) for switches, training and the
frozen policy format.

### Where Skills are found

Every root below is a *compat* source (`catalog.Profile.compat` in
`src/skills/runtime/catalog.zig`). A name defined in several places takes the
highest tier, as in Claude Code — enterprise, then personal, then project — so a
checked-out repository cannot shadow a Skill the user installed.

| Tier | Roots, highest first |
|---|---|
| Enterprise | `/etc/metacodes/skills`, Claude Code's managed `<dir>/.claude/skills` (`/Library/Application Support/ClaudeCode`, `/etc/claude-code`, `C:\Program Files\ClaudeCode`), `/etc/codex/skills` |
| Personal | `<state root>/sealed-skills` (pinned sealed Skills, see below), `<state root>/skills`, `~/.agents/skills`, `~/.claude/skills`, `$CODEX_HOME/skills` (default `~/.codex/skills`) |
| Project | each directory from the repository root down to the working directory — a level closer to the working directory wins — and within a directory `.metacodes/skills`, `.agents/skills`, `.claude/skills`, `.codex/skills` |
| `--add-dir` | `.metacodes/skills`, `.agents/skills`, `.claude/skills` under each added directory |

Discovery follows what both tools do:

- A Skill is a directory holding `SKILL.md`, found up to 6 directory levels
  below a root (Codex); a Skill's own subtree is not searched again.
- Hidden directories and Claude Code's reserved `synced` folder are skipped.
- A symlinked root or Skill directory is followed. A Skill reached through
  several links (the `npx skills` layout links `~/.claude/skills/x` to
  `~/.agents/skills/x`) is loaded once, through its highest-priority path.
- A root that exists but cannot be read is skipped and reported by `/skills`;
  it never hides the other roots.
- Names may contain non-ASCII letters (`/地址库`); spaces, controls and
  zero-width characters are refused with a typed issue.

### `SKILL.md`

The frontmatter is YAML (`src/skills/runtime/frontmatter.zig`): quoted
strings, folded `>` and literal `|` blocks, block and flow lists, nested maps,
comments, CRLF and a BOM all parse. As in Codex, a one-line value that only
looks like a flow collection (`argument-hint: [pr] [priority]`) stays text, and
`key: value: more` keeps everything after the first colon. Unknown keys are
ignored.

| Field | Meaning |
|---|---|
| `name` | display name (the invocation name is the directory name); when absent, the directory name |
| `description` | listed to the model; when absent, the first body line (Claude Code), and `/skills` reports the Skill |
| `when_to_use` | appended to the description in listings |
| `argument-hint` | shown beside the command in the `/` menu |
| `arguments` | positional names for `$name` substitution |
| `allowed-tools`, `disallowed-tools` | the Skill's tool policy frame |
| `disable-model-invocation` | not listed to the model and not activatable by it; the user can still run `/name` (`skillOverrides` cannot list it) |
| `user-invocable: false` | hidden from the `/` menu, still model-invocable |
| `model`, `context: fork`, `agent` | a forked Skill runs under the named subagent's prompt, tool set, permission mode and model |
| `model-activation`, `shell` | metacodes extensions |

Codex's `agents/openai.yaml` is read too: `policy.allow_implicit_invocation:
false` hides the Skill from the model like `disable-model-invocation`.

A malformed policy value (`context`, `shell`, a boolean, `model-activation`) or
malformed YAML makes the Skill a typed `invalid_definition` issue rather than
silently changing its meaning.

The [Agent Skills specification](https://github.com/agentskills/agentskills/blob/main/docs/specification.mdx#frontmatter)
requires `name` and `description` to be non-empty. A `name` or `description`
that is empty or only whitespace (`name: ""`, `description: "  "`,
`description:` with no value) counts as absent, as in Claude Code
(`description`) and Codex (both), so the fallbacks above stand in. The Skill
still loads: a blank field is a typed warning in its definition
(`definition.Warning`), not an `invalid_definition` issue, and `/skills` names
the field. When the body has no line to stand in either, the Skill is listed
with no description (`- **name**`), exactly as when `description` is absent.
AgentCore's canonical catalog has no body fallback: a blank `description` is
empty there, as an absent one is.

### What the model sees

The system prompt and the `Skill` tool list each model-invocable Skill as
`name — description when_to_use`, whitespace collapsed and capped at 1536
bytes per Skill; past a 16 KiB total, descriptions are shortened and then
dropped (names stay). Activating a Skill returns its rendered body preceded by
`Base directory for this skill: <dir>`: relative references such as
`scripts/x.py` resolve there, and `${CLAUDE_SKILL_DIR}` expands to the same
directory.

For compat sources that directory is the live Skill directory, as in Claude
Code and Codex: only `SKILL.md` and `agents/openai.yaml` are read when the
Skills are loaded, so Skills that carry a virtualenv, `node_modules` or large
assets work. (AgentCore's canonical sources still snapshot and materialize the
whole tree.)

### Changes during a session

A session watches every compat Skill root (present or not), each entry in it,
and that entry's `SKILL.md`, `sealed.json` and `agents/openai.yaml`. Before
each request of a top-level Run (at most once a second, one stat each) it
reads the Skills again when one of them changed. From then on a new Skill can
be activated, an edited one runs its new `SKILL.md`, and a removed one is
refused, with no restart.

The listings in the system prompt and the `Skill` tool stay byte for byte as
they were, so the prompt cache holds. The model is told in a system reminder
which Skills are new (with their description), which are gone and which
changed; like the MCP reminder it is read back from the system prompt and the
reminders still in the conversation, so compaction and `/clear` tell it again.
A session that started without a model-invocable Skill gains the `Skill` tool
when the first one appears, and that request misses the prompt cache once.

Plugin Skills are not watched: their package is a fixed generation. An
activation already running keeps the Skill it started with, and a background
agent or teammate keeps the Skill list it started with; nothing they hold is
freed before the session ends. Completion of `/` commands, `/skills` and
`/doctor` show the Skills as they are now.

### `skillOverrides`

Claude Code's per-Skill setting, read from the same files
(`src/skills/overrides.zig`): `~/.claude/settings.json` <
`<project>/.claude/settings.json` < `<project>/.claude/settings.local.json`,
where the project is the repository root or, outside one, the working
directory.

```json
{ "skillOverrides": { "release-notes": "name-only", "deploy": "off" } }
```

| Value | Model listing | Skill tool | `/name` and `/` menu |
|---|---|---|---|
| `on` (absent) | name and description | admitted | yes |
| `name-only` | name only (`- name`) | admitted | yes |
| `user-invocable-only` | not listed | refused | yes |
| `off` | not listed | refused | refused, not in the menu |

The Skill tool refuses with Claude Code's words (`Skill <name> is disabled
for model invocation in skillOverrides settings`); `/name` of an `off` Skill
prints `Skill "<name>" is disabled via skillOverrides. Re-enable it in /skills
or remove the override from your settings to run it.` in place of its echo.
The Skill Runtime enforces the state at activation, so background jobs and
teammates obey a change at once. An unknown value is ignored (and kept in the
file); a settings file that does not parse contributes nothing.

The `Skill` tool is registered whenever a Skill may be model-invoked by its
definition, so an override changes the tool's description, never the tool
set. The listings change only when an override does: `/skills` closed with
no change leaves the request bytes as they were.

### Commands

- Typing `/` opens the command menu: built-in commands in alphabetical
  order, then every user-invocable Skill (its description followed by its
  tier, e.g. `(user)`, and its `argument-hint`). Prefix matches come first, then substring matches; the
  window scrolls with the selection; Esc closes the menu and keeps the draft.
  Enter on a Skill that takes arguments fills `/name ` instead of submitting.
- `/name args` runs the Skill as a turn of the conversation: the reply
  streams with the spinner and tool cards and Esc interrupts it, as for any
  prompt; the rendered Skill body goes to the model, not to the scrollback.
- In the TUI, `/skills` opens Claude Code's pane: each Skill with its
  `skillOverrides` state, tier and listing cost (`✔ on  name · user · < 20
  tok`), and how many Skills did not load. Enter or Space cycles the selected
  Skill through on → name-only → user-only → off (a
  `disable-model-invocation` Skill is `🔒 locked by author`); typing or `/`
  searches, Esc clears the search, then leaves it, then closes the pane.
  Closing writes the changes to `.claude/settings.local.json` (an entry equal
  to what the project and user settings give is removed) and prints
  `Updated N skill overrides` or `No changes`; the next request carries the
  new listing. Without a terminal (and as the data behind it) `/skills`
  prints the full report: tier, any override state, and directory, the
  Skills without a `description` (listed with their first body line or with
  nothing), those with a blank `name`, the Skills that did not load and why,
  and skipped roots. The startup banner and `/doctor` count these (a Skill
  once, however many of its fields are blank), together with hook and agent
  configuration problems (`/hooks`, `/agents`), so a broken file is noticed
  without knowing where to look.

### Sealed Skills

A sealed Skill is one whose body never reaches this machine: it runs on a
gateway speaking the Sealed Skill Protocol (`metask.sealed-skill/v1`,
[SEALED_SKILL_PROTOCOL.md](SEALED_SKILL_PROTOCOL.md)), and every tool call it
needs is sent back here, executed under the ordinary permission system, and
its result returned. `metacodes sealed install <gateway-url> <skill_id>`
shows the manifest the user consents to (tool allowlist, data egress classes,
credentials, price) and pins it under `<state root>/sealed-skills/<name>/`;
the pin's projected `SKILL.md` carries `sealed-gateway`, `sealed-skill-id`
and `sealed-manifest-digest`, `context: fork`, and the allowlist as
`allowed-tools`. `/skills` lists it like any Skill; `/name args` and the
`Skill` tool run it as a fork whose model is the gateway. The model is this
session's own: the gateway runs the Skill's loop as a shadow of the fork and
calls the model over the session's provider route and credential, so the
request the model sees is the one a local fork would have sent, on the
user's own account and bill. The gateway reports each Step's tokens and its
estimate of their cost; the client stops the run at
`METACODES_SEALED_MAX_COST_MICROS` and records every Step in
`<state root>/ledger/sealed.ndjson` (`metacodes sealed ledger`). The gateway
account owes only the Skill's own fee, when a gateway charges one. A call
the gateway marks `confirm: true` is approved
interactively even in a mode that would auto-allow it; a question the
Skill has for the user is asked through the session's own AskUserQuestion
dialog and answered in place. A credential reference the manifest declares
is bound with `metacodes sealed bind <name> <ref>` (secret from stdin or
`--from-env`), kept in `<state root>/sealed-credentials.json`, substituted
into the call on this machine and redacted from the result before it
leaves. The Skill's public files (scripts, data) are installed under the
pin directory; its `sealed/` reference files are read on the gateway.
`metacodes sealed serve` runs the reference gateway; it has no provider
credentials of its own.

## MCP servers

### Sources and precedence

`src/mcp/config.zig` reads, highest precedence first; a server name takes the
whole entry from the highest source (fields never merge):

| Source | Format | Child environment | `${VAR}` expansion |
|---|---|---|---|
| `<state root>/config.json` `mcpServers` | Claude Code JSON, plus Codex keys | Codex allowlist (`inheritEnv: true` to inherit) | yes |
| `<state root>/config.json` `mcp_servers` | legacy `[{"name", "command": [argv]}]` | Codex allowlist | yes |
| `~/.claude.json` `projects[<cwd>].mcpServers` | Claude Code local scope | inherited | yes |
| `<project>/.mcp.json` | Claude Code project scope, approval required | inherited | yes |
| `~/.claude.json` `mcpServers` | Claude Code user scope | inherited | yes |
| `<dir>/.codex/config.toml` `[mcp_servers.*]` | Codex project layer, trusted projects only | Codex allowlist | no |
| `$CODEX_HOME/config.toml` `[mcp_servers.*]` | Codex user layer | Codex allowlist | no |
| `~/.metacode/config.toml` `[mcp_servers.*]` | Metacode user layer (Codex format) | Codex allowlist | no |

`"mcpImport": {"claude": false, "codex": false, "metacode": false}` turns the
foreign sources off;
an entry `{"enabled": false}` without a command or URL disables that name in
every lower source.

A `.mcp.json` server runs a command from a checked-out repository, so it starts
only when approved: `enableAllProjectMcpServers` or `enabledMcpjsonServers` in
metacodes' config, in Claude Code's user or local settings, or in Claude Code's
per-project state in `~/.claude.json`. `disabledMcpjsonServers` anywhere wins,
and the shared `.claude/settings.json` can reject but not approve. A Codex
project layer is read only when `$CODEX_HOME/config.toml` marks the project
`trust_level = "trusted"`.

### Adding and removing servers

`metacodes mcp add` writes one entry into `mcpServers` of
`<state root>/config.json`, the first source above, and `metacodes mcp remove`
takes it out again (`src/app/mcp_config_edit.zig`):

```sh
metacodes mcp add docs https://example.com/mcp --header X-Team=core
metacodes mcp add linear --type sse https://mcp.linear.app/sse
metacodes mcp add github --env 'GITHUB_PERSONAL_ACCESS_TOKEN=${GITHUB_TOKEN}' -- npx -y @modelcontextprotocol/server-github
metacodes mcp add-json tracker '{"type":"http","url":"https://t.example/mcp","oauth":{"clientId":"cli"}}'
metacodes mcp remove docs
```

A URL (positional or `--url`) makes an HTTP server (Streamable HTTP, or
`--type sse`) and takes `--header <name>=<value>`; a command makes a stdio
server and takes `--env <name>=<value>`. Claude Code's and Codex's spellings
of the same command work as well (`-t/--transport`, `-e`, `-H "Name: value"`,
`-s user|local`, `--bearer-token-env-var`, `--client-id`, `--callback-port`),
so a command copied from a server's install page for either of them installs
the server here. `-s project` is refused with a pointer to `.mcp.json`, and
`--client-secret` is refused because metacodes logs in as a public client.
`add-json` takes the whole entry as one JSON object, in the shape of
[Entry fields](#entry-fields). Values may name `${VAR}`, expanded when a
session starts, so a token need not be written into the file.

Before writing, `add` reads the entry the way a session will and refuses one
no session could use (exit 2), naming the loader's problem. The edit is a
read-modify-write under the file's lock: only that one member changes, every
other key (`jev`, a legacy `mcp_servers` array, provider settings) keeps its
value and place, and the file is replaced atomically with mode 0600. A name
already configured — in that file, its legacy array, or another source the
entry would shadow — is refused unless `--force`. `remove` edits only
`mcpServers`: a legacy entry or another program's file is explained, not
changed. It also forgets the server's stored login, unless a server of the
same name and URL is still configured.

After writing, `add` connects the server once, as a session would (its stored
login included, its log left alone), and prints what happened: the number of
tools, or for a 401 the `mcp login` command to run (`--no-check` skips the
check). A running session picks the change up before its next request (see
"Changes during a session"); a new session connects the server when it
starts. `metacodes mcp list` shows each configured server, the
file it comes from, its transport, how a URL server authenticates
(`auth: configured`, `auth: OAuth (<issuer>)`, an expired login, or
`auth: not logged in`, which says no credential is stored, not that the server
needs none) and, unless `--no-check`, whether it connects now. Every hint
these commands print names the command that ran them (`metacodes-dev mcp login`
for a side-by-side install), as the other next-step hints do (#482).

The interactive and headless CLI tell the model the same in the environment
section of the system prompt: that its command is the one that started it
(not `metacode`, a different product, nor any other similarly named program),
that `<command> mcp add`, `mcp login` and `mcp list` manage MCP servers, and
that a server added, changed or logged in to during a session is connected
before the next request, with a system reminder listing its tools, unless it
is defined inside the working directories, where it waits for the user's
`/mcp reconnect <name>`. The lines name the command only;
they carry no path or server, so they stay the same for every session of an
install. A host that builds an App without the CLI's command name (the daemon,
an embedder) gets no such lines.

### Entry fields

```json
{
  "mcpServers": {
    "github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": {"GITHUB_PERSONAL_ACCESS_TOKEN": "${GITHUB_TOKEN}"},
      "envVars": ["HTTPS_PROXY"],
      "cwd": "/path",
      "startupTimeoutSec": 30,
      "toolTimeoutSec": 300,
      "enabledTools": ["create_issue"],
      "disabledTools": []
    },
    "docs": {
      "type": "http",
      "url": "https://example.com/mcp",
      "headers": {"X-Team": "core"},
      "bearerTokenEnvVar": "DOCS_TOKEN"
    },
    "linear": {
      "type": "sse",
      "url": "https://mcp.linear.app/sse"
    },
    "tracker": {
      "type": "http",
      "url": "https://tracker.example.com/mcp",
      "oauth": {"clientId": "metacodes-cli", "callbackPort": 8765},
      "scopes": ["issues:read"]
    }
  }
}
```

Codex's snake_case spellings (`env_vars`, `startup_timeout_sec`,
`tool_timeout_sec`, `enabled_tools`, `disabled_tools`, `bearer_token_env_var`,
`http_headers`, `env_http_headers`) are accepted in JSON as well, and Claude
Code's per-call `timeout` (milliseconds). `type` may be `stdio` (or absent with
`command`), `http` / `streamable-http`, or `sse` (the 2024-11-05 HTTP+SSE
transport, below). `oauth` is Claude Code's object — `clientId`,
`callbackPort`, `authServerMetadataUrl` — and `scopes` (an array, Codex's key,
also accepted inside `oauth`) names the scopes to request; all of them are
optional (see [Authorization](#authorization-oauth)). `oauth.clientSecret` is
refused with a configuration problem: a secret does not belong in a file a
repository may carry, and the flow is PKCE for a public client.

- **Environment.** The allowlist is Codex's `DEFAULT_ENV_VARS` (`HOME`,
  `LOGNAME`, `PATH`, `SHELL`, `USER`, `LANG`, `LC_ALL`, `TERM`, `TMPDIR`, `TZ`,
  and the Windows equivalents) plus the CA-bundle variables, then `env_vars`,
  then `env`. A bare command is looked up on the child's own `PATH`; a relative
  path resolves against `cwd` (default: the session's working directory).
- **Timeouts.** The handshake has 30 s by default, connecting (DNS, TCP,
  TLS) included; a server that does not answer is reported and the others start anyway (all servers start in
  parallel). Tool calls are unbounded unless a tool timeout is configured
  (Codex entries default to 300 s); an expired call is cancelled with
  `notifications/cancelled`.
- **Startup.** The interactive REPL shows its prompt while the servers
  connect; the footer reads `connecting to MCP servers (n/total)`. The first
  thing that sends a request (a message, a `/skill`, `/init` and the other
  prompt commands, `/btw`, `/recap`, cron and `/loop` turns) waits until every
  server has reported (the spinner reads `Connecting to MCP servers`; Esc or
  Ctrl+C stops waiting and the turn does not start), and only then are the
  tools registered and the tool list and system prompt built — once, so what
  the model sees never depends on how fast a server answered. Leaving the
  REPL while a server connects interrupts its handshake. Every other mode
  (`-p`, `--web`, `serve`, `--teammate`, `--dump-*`) waits for the servers
  before it starts, as before; their connects overlap the rest of startup.
  After startup, failures are announced once in the footer, Claude Code's way
  (`1 MCP server failed · /mcp`, `1 MCP server needs auth · /mcp` for a 401 or
  403), until `/mcp` or the next turn.
- **Logs.** Each stdio server's stderr goes to `<state root>/logs/mcp/<name>.log`.

### Tools

Tools register as deferred `mcp__<server>__<tool>`, Claude Code's form, so its
permission rules (`mcp__server`, `mcp__server__*`, `mcp__server__get_*`,
`mcp__server__tool`), Skill `allowed-tools` and subagent `tools:` lists apply
unchanged. Characters outside `[A-Za-z0-9_-]` become `_`; a name over 64
bytes, or one that collides after that, keeps a readable prefix and ends in a
stable hash. The earlier metacodes name `<server>__<tool>` still selects the
same tool in those lists and rules. Resources are read through
`ListMcpResourcesTool` and `ReadMcpResourceTool`.

A call to a server's tool is permissioned as executing, like `Bash`, and as
AgentCore permissions it: the server may change things outside this machine.
`default`, `acceptEdits` and `auto` ask before it runs (`-p` has nobody to ask
and denies it), `dontAsk` denies it, and `bypassPermissions` runs it. A
server's annotations (`readOnlyHint` and the rest) are its own claim and do
not relax this. To let a trusted server's tools run without a prompt, allow
the server: `{"permissions": {"allow": ["mcp__server"]}}` in a settings file,
or `--allowedTools mcp__server`. Approving a project server in `.mcp.json`
starts it; it does not allow its tools. `ListMcpResourcesTool` and
`ReadMcpResourceTool` read, and run without a prompt.

### Protocol

The client (`src/mcp/client.zig`, the one implementation every entry point
runs; see [MCP_ARCHITECTURE.md](MCP_ARCHITECTURE.md)) speaks MCP 2026-07-28 and
the handshake revisions 2025-11-25, 2025-06-18, 2025-03-26 and 2024-11-05:

- It first sends `server/discover`. A 2026-07-28 answer selects the stateless
  protocol: every request carries `_meta` (protocol version, client
  capabilities, client info), results carry `resultType` (absent means
  `complete`), and an `input_required` result is fulfilled (elicitation through
  the host's handler, declined when there is none) and retried with
  `inputResponses` and the echoed `requestState` under a new request id.
- Any other answer falls back to `initialize` (never keyed to one error code).
  Over stdio, a server that exits or stays silent on the probe is restarted for
  the handshake. Over HTTP, a timeout, a network failure or 401/403 is an error,
  not a reason to fall back.
- The handshake answers server `ping`s and form-mode elicitation requests,
  echoing the request's id whether it is a number or a string; undeclared
  requests get `method_not_found`. Elicitation is declared only when the
  connection was given a handler: the CLI has no elicitation UI yet, so it
  declares none and declines an elicitation a server sends anyway.
  `tools/list` follows `nextCursor` (an empty string is a cursor too).
- Streamable HTTP POSTs every message with `Accept: application/json,
  text/event-stream`, reads JSON or SSE responses (a mid-stream server request
  is answered on its own POST), keeps the handshake's `MCP-Session-Id` and
  `MCP-Protocol-Version` (DELETE on close, given at most 1 s; a 404 to a request carrying the
  session id means the server ended the session, so the client sends a new
  `initialize` without it, adopts the revision the server selects, and repeats
  the request once in the new session), and sends `Mcp-Method`, `Mcp-Name`
  and `Mcp-Param-*` (from `x-mcp-header`; a tool with an invalid annotation is
  dropped) on 2026-07-28. An SSE response that ends before its answer is
  resumed when the server numbered its events: after the stream's `retry`
  delay (1 s by default, 10 s at most), a GET with `Last-Event-ID` (the id of
  the last event received whole) and the session headers reopens it and the server replays the rest (2025-03-26
  through 2025-11-25; at most 3 consecutive attempts that bring no new event
  id, so a polling server whose every stream opens with a fresh priming event
  keeps the call open until it answers or the request times out). On
  2026-07-28 the answer is lost instead, and the client reports the call as
  indeterminate rather than sending it again.
- A `tools/call` is sent once. A failure after the request left (a timeout, a
  dropped connection, a server exit) tells the model that the call may have
  executed and to check its effect before repeating it. A POST whose body was
  never fully written, that a 401 refused, or that a 404 refused for an
  expired session, is known not to have run and is retried. A `tools/call` does not reuse an HTTP connection idle for more than
  a second, since the race with a server closing it could not be retried.
- **HTTP+SSE** (`type: "sse"`, revision 2024-11-05, which many hosted
  servers still offer at an `/sse` URL): a long-lived `GET <url>`
  (`Accept: text/event-stream`, the configured headers) whose first event,
  `endpoint`, names the URI each message is POSTed to (202 Accepted); every
  answer, server request and notification arrives as a `message` event on
  the stream. A relative endpoint resolves against the stream URL; one on
  another origin is refused, because every POST carries the configured
  headers, and a later `endpoint` event is ignored. When the server ends the
  stream, the session's calls fail with "closed its SSE event stream"; a new
  session reconnects. A reader thread owns the stream, so a call that is interrupted or
  times out leaves the session intact: the client sends
  `notifications/cancelled`, as over stdio, and the late answer is discarded
  by id. The handshake is `initialize` (the transport predates
  `server/discover`); the stream must open and name its endpoint within the
  startup timeout. A URL that answers with anything but an event stream is
  reported as such (`type: "http"` is probably meant).
- A server's requests share one kept-alive connection while they come in quick
  succession (the handshake, a burst of tool calls), so startup costs one TLS
  handshake rather than one per message, and `Connection: close` is never
  sent (Vercel-hosted servers such as developers.openai.com drop such
  requests). A connection is reused only after its response was read to the
  end — an answered SSE stream is finished before the next request, waiting
  at most 250 ms of silence — and only within 4 s of its last use; a request
  that finds a reused connection already closed by the server, before any
  response byte, is sent again on a new connection.

### Authorization (OAuth)

An HTTP or SSE server that answers 401 is `needs authentication` in `/mcp`
and the footer. `metacodes mcp login <server>` logs in once; every session
after that sends the token and keeps it fresh. The flow is the MCP
authorization specification's (2025-06-18 / 2025-11-25, with the 2025-03-26
fallback), in `src/mcp/oauth.zig`:

1. **Discovery.** An unauthenticated request in the server's own transport
   (a POST of `initialize`, or the SSE stream's GET) earns a 401 whose
   `WWW-Authenticate: Bearer resource_metadata="…", scope="…"` names the
   protected resource metadata (RFC 9728); without one, the well-known
   locations are tried (`/.well-known/oauth-protected-resource<path>`, then
   the root). Its `resource` must cover the server URL, and its first
   `authorization_servers` entry is the issuer whose RFC 8414 / OpenID
   Connect metadata gives the endpoints (path-inserted locations first).
   `oauth.authServerMetadataUrl` overrides that lookup. A server that
   publishes no resource metadata is a 2025-03-26 server: its origin is the
   authorization server, with `/authorize`, `/token` and `/register` as
   defaults when it has no metadata either. Metadata that does not list
   `S256` in `code_challenge_methods_supported` is refused, and every
   endpoint must be HTTPS (plain HTTP on loopback only).
2. **Client.** `oauth.clientId` when configured; otherwise RFC 7591 dynamic
   registration of a public client (`token_endpoint_auth_method: none`) for
   this login's redirect. A server with neither fails with a message naming
   `oauth.clientId`.
3. **Authorization.** The browser opens the authorization endpoint
   (`--no-browser` only prints the URL) with PKCE S256, a random `state`,
   the scopes — `scopes` from the configuration, else the challenge's
   `scope`, else every `scopes_supported` of the resource — and the RFC 8707
   `resource` (the canonical server URL). The redirect is
   `http://localhost:<port>/callback`, Claude Code's path, on a
   kernel-chosen port, or `oauth.callbackPort` for a client whose redirect is
   registered in advance. In an SSH session (`SSH_CONNECTION` or `SSH_TTY`
   set), where that redirect lands on this machine and the browser is on
   another one, the CLI prints the forward the callback needs, with the port
   it bound: `ssh -L <port>:127.0.0.1:<port> <you>@<this machine>`. A
   browser on another computer ends on a page that does not load: paste that
   page's address at the prompt and the login finishes here. The address is
   judged as the callback would be (path, `state`, `code`, `error`), so one
   from another login is refused and the wait goes on. The CLI waits at most
   `METACODES_LOGIN_CALLBACK_TIMEOUT_MS` (ten minutes by default, `0` for no
   limit), then exits 1 having stored nothing (#740).
4. **Token.** The code is exchanged with its verifier and the same
   `resource`. Before it is stored, the new token is tried with one
   authenticated request in the server's own transport (an `initialize`, or
   the SSE stream's GET; a session it opens is ended with `DELETE`). A 401
   or 403 fails the login and stores nothing: the CLI prints the server's
   answer (`error`, `error_description`, the scope it asks for, a body
   excerpt) and the scope requested and granted. Any other status, or no
   answer, stores the token and says it is unverified. A token response
   whose `scope` is `""` is recorded as no scope granted. A refused
   registration or token request prints the authorization server's `error`
   and `error_description`. The answer is stored in
   `<state root>/mcp-oauth/<server>-<hash>.json` (mode 0600, written
   atomically), keyed to the server name and URL so a token never reaches
   another URL.

A session's HTTP and SSE transports attach `Authorization: Bearer` from the
stored login, refresh it (`refresh_token` grant, with `resource`) a minute
before it expires, and after a 401 refresh once and retry the request; a
rotated refresh token is saved before it is used. Concurrent requests that
see one 401 perform one refresh, and the store is re-read first: a session
whose token another session already refreshed adopts the stored one instead
of spending a refresh token that rotation has revoked. A refresh that fails
for want of a network is not retried for 30 s; it runs within the request's
own interrupt and deadline. A refused refresh token, or a 401 that survives
the retry, is `needs authentication` again. Configuration wins: a
server whose `headers` or `bearerTokenEnvVar` set `Authorization` never uses
a stored login (`mcp login` refuses it). `metacodes mcp logout <server>`
forgets the login; `metacodes mcp list` shows each server's transport and how
it authenticates. Not implemented yet: client ID metadata documents
(2025-11-25), step-up authorization on `403 insufficient_scope` (reported as
needing authentication), and logging in from inside the TUI.

### `/mcp`

`/mcp` lists every configured server with its source, state (connected and
the negotiated revision, needs authentication — with the `metacodes mcp login`
command that fixes it — or why it failed), tool count and log, followed by project servers awaiting approval, disabled names and
configuration problems. While servers are still connecting it shows each one's
state so far (`connecting… 3s`), without waiting for them.
The model is told as well: when ToolSearch finds nothing, or the model calls
an `mcp__…` tool that does not exist, the result names the configured servers
that give no tools with the reason `/mcp` shows (for a 401, the
`metacodes mcp login` command; for one still connecting, that it is), and asks
the model to tell the user instead of reaching the server another way. The
same result reads the configuration again at that moment and names a server
added since the session last read it; that one is connected before the next
request. Nothing about them enters the system prompt. A `-p` run prints one
`warning: MCP server '<name>' did not connect: <reason>` line per such server
to stderr before it starts, and `--json` adds them to the result line as
`mcp_unavailable`.

### Changes during a session

A session watches every file its MCP configuration is read from (each source
above, present or not) and `<state root>/mcp-oauth`. Before each request of a
top-level Run (the first request of a Run and every one after a batch of tool
calls) it looks at them, at most once a second and with one stat each. Only
when one changed does it read the configuration again and compare it server
by server with what the session is using:

- A server added, or one whose entry changed (any field that affects how it
  connects), connects on a worker thread. The request waits up to 5 s for it;
  one that takes longer is published before a later request.
- A server that needed a login connects again once its stored login changes
  (`metacodes mcp login`), not on every later change to the configuration.
- A server removed from the configuration, or disabled, is disconnected. A
  call that a background agent has in flight on it finishes first.
- A server that announces `notifications/tools/list_changed` has its tool list
  read again.

A configuration file that cannot be parsed as it stands (half written, say)
holds every change back until it can be; the servers it listed stay as they
are.

The system prompt and the tool schemas already sent stay byte for byte as they
were, so the prompt cache holds. The model learns of the change from a system
reminder appended to the conversation: the new MCP tools with a one-line
summary each (loaded with ToolSearch, like every deferred tool), the ones that
are gone, and one line per server whose state changed (connected, failed and
why, needs a login, not connected automatically). What the model has been told
is read back from the system prompt and the reminders still in the
conversation, so after compaction, `/clear` or a resume it is told again, and
it is never told twice. A tool the model had already loaded keeps its schema
in the requests after its server goes; calling it fails and says why.

A server added or changed in a file inside the session's working directories
(the current directory, `--add-dir` directories and the sandbox's
`allowWrite`) is not connected automatically, because a command the session
ran could have written that file. The reminder and `/mcp` name
`/mcp reconnect <name>`, which connects it. Project `.mcp.json` servers still
need approval first. Removals and logins always apply.

`/mcp reconnect` goes the same way: `/mcp reconnect` connects every configured
server that is not connected, and `/mcp reconnect <name>` closes that server's
connection, if it has one, and connects it again. The spinner reads
`Reconnecting MCP servers`; Esc or Ctrl+C cancels the connects that have not
finished, and the outcome is published either way. Neither rebuilds the system
prompt, and both run while a background agent or an in-process teammate runs:
nothing those hold is freed before the session ends, and a background agent
keeps the tool list it started with.

## Tests and evaluations

A test that isolates metacodes with a temporary `HOME` must also drop
`CODEX_HOME`: it is an absolute path that the temporary `HOME` does not move,
and the product would load the caller's Codex Skills and start the MCP servers
in its `config.toml`. `build.zig` removes it from every step it runs (as it
sets `METACODES_JEV_URL=off`); the harnesses that run outside the build —
`tests/e2e/lib.sh`, the TTY driver, the session-memory and runtime-arm smokes,
the memory-agent runtime's scripted arms and the plugin gate and pair runner —
remove it from the child environment themselves.
