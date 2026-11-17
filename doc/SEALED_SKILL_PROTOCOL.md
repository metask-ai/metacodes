# Sealed Skill Protocol (SSP/1)

Status: **draft for implementation**, protocol identifier
`metask.sealed-skill/v1`, revision 2026-10-15. Owner: Metask Lab. This
document is normative for the wire protocol between a *client* (an agent
harness that owns tools, permissions and a user's budget) and a *gateway*
(a service that executes a Skill it never discloses). metacodes is the
reference client; §9 records how it maps the protocol onto its own kernel.

The words MUST, MUST NOT, SHOULD and MAY are used as in RFC 2119.

## 1. Problem and shape

A Skill today is a plaintext `SKILL.md` plus assets, discovered and read by
the agent on the user's machine. Whatever it contains is readable by the
user, by every process on the machine, and by every model provider the
agent talks to. That makes Skills impossible to sell: a Skill marketplace
needs creators who can publish without handing the work to every subscriber.

SSP turns a Skill into a *service* without moving the user's environment to
the service. The split is:

- **the brain runs on the gateway**: the Skill body, its workflow, its
  private knowledge and its model calls stay on the gateway;
- **the hands stay on the client**: every tool call the Skill needs is sent
  to the client as a request, executed there under the client's own
  permission system, sandbox and credentials, and only the result goes back;
- **the client's own model does the thinking**: the gateway runs the Skill's
  loop as a *shadow* of the client's fork, calling the model over the
  client's own provider route and credential, so the model, the account and
  the bill are the client's; the gateway meters the run for the client's cap
  and ledger and charges only the Skill's own fee.

It is the hosted-agent / client-executed-tools pattern (computer use agents,
managed agents with client tools) applied in reverse to the Skill: the
remote side holds the instructions, the local side holds the environment.

### 1.1 What the protocol protects, stated honestly

| Layer of a Skill | Where it lives under SSP | Visible to the client? |
|---|---|---|
| Reasoning: system prompt, judgement, domain knowledge, exception handling | gateway | **no** |
| Actions: which tools are called, with which inputs, in which order | both | **yes** — the client executes and the user approves each one |
| Code assets the Skill ships | gateway (`server` class) or client (`client-sealed`, §7) | server: no; client-sealed: deterrent only |

A run reveals one path through the Skill, never the Skill. A Skill whose
value is a fixed procedure is reconstructible from enough runs; a Skill
whose value is judgement and the long tail of exception handling is not.
The model the gateway's brain runs on — the client's own, §8.1 — is itself
a disclosure channel (a tool result can carry an injection that asks the
model to write its instructions into a file), so SSP specifies detection
and accountability for that channel (§8.5), not impossibility. Nothing in this document is encryption of the
Skill against the party that runs it; the Skill is confidential because it
never leaves the gateway, and the gateway is operated by the party the
creator chose to trust.

### 1.2 Roles

| Role | Holds | Trusts |
|---|---|---|
| **Creator** | the Skill: `SKILL.md`, workflow, assets, manifest | the gateway operator (contractually; §8.6 for the attested variant) |
| **Gateway** | Skill content, the brain (the client's loop run as a shadow, or a workflow engine), the sealing key | nobody: every client message is untrusted input; it holds no model credentials of its own |
| **Client** | the user's tools, permissions, sandbox, credentials, budget, audit log | nobody: every gateway message is untrusted model output |
| **Subscriber** | an account on the gateway, and their own model-provider account | the gateway for the Skill fee only (the model bill is their own provider's, §8.1), the client for everything that touches their machine |

In the reference deployment one service implements the gateway's four
internal identities — *skill host* (content and brain), *inference gateway*
(the party that relays the brain's model calls over the client's own route
and credential, meters them and signs Steps; it owns no inference account),
*sealing issuer* (§7) and *billing* (the Skill fee, §8.2; never the model).
They are named separately so that a later revision can let a third party
host Skills behind a Metask inference gateway; a v1 implementation MAY
merge them and MUST still populate the identity fields (§4.2) distinctly.

## 2. Transport

- **JSON-RPC 2.0** messages, each POSTed to one gateway URL with
  `Content-Type: application/json`. The gateway answers with
  `application/json` (one response) or `text/event-stream` (a stream of
  JSON-RPC messages, last one the response), the same framing as MCP
  Streamable HTTP; a client MUST accept both.
- Every request carries the header `Sealed-Skill-Version: 1`. A gateway
  that does not implement that major version MUST answer HTTP 400 with
  error `unsupported_version`.
- Authentication is a bearer token for the subscriber's gateway account in
  `Authorization`. How the token is obtained (OAuth, API key) is outside this
  protocol.
- The client's **provider credential** for the request travels in the
  `Sealed-Provider-Credential` header of `runs.start` and `runs.continue`
  (§8.1): the gateway makes the Step's model calls with it and forgets it
  with the request. It is a header, never a parameter: it is not digested,
  not echoed and not logged.
- The gateway SHOULD be **stateless per run**: run state travels in the
  opaque `run_state` blob (§4.4) that the client returns unchanged with every
  message. A gateway MAY keep state server-side instead; the client cannot
  tell and MUST behave identically.
- A gateway SHOULD answer `runs.start` and `runs.continue` as
  `text/event-stream` and send a comment line (`: ping`) at intervals while
  the Step is computed, so that no intermediary and no client liveness
  monitor sees a silent connection during a long model call; the response
  is the stream's final event. A client MUST ignore comment lines and any
  event it does not understand.
- **Admission.** A gateway at capacity refuses a request before processing
  it: HTTP 503 with a `Retry-After` header (seconds) when no worker can take
  the connection, or the JSON-RPC error `rate_limited` with
  `data.retry_after_ms` when every model slot is busy. Either answer means
  the request was **not processed** and changed no run state; the client
  SHOULD wait the named interval and resend the identical request. This is
  compatible with §8.4: a refused `seq` was never answered.
- TLS is required outside loopback test deployments.

## 3. Methods

| Method | Direction | Purpose |
|---|---|---|
| `sealed/discover` | client → gateway | protocol versions, capabilities, operator identity |
| `sealed/skills.list` | client → gateway | the Skills this subscriber may run, with manifests |
| `sealed/skills.get` | client → gateway | one Skill's current manifest (for pin refresh) |
| `sealed/runs.start` | client → gateway | begin a run; returns the first Step |
| `sealed/runs.continue` | client → gateway | deliver tool results; returns the next Step |
| `sealed/runs.cancel` | client → gateway | end a run early |

There are no gateway-initiated requests. Everything the gateway needs from
the client is expressed as a Step (§4.3); this keeps the client's transport a
plain request/response client and keeps the gateway free of per-client
connections.

### 3.1 `sealed/discover`

Params: `{}`. Result:

```json
{
  "protocol": "metask.sealed-skill/v1",
  "revisions": ["2026-10-15"],
  "operator": {"id": "metask", "display_name": "Metask Lab"},
  "identities": {"skill_host": "metask", "inference_gateway": "metask",
                 "sealing_issuer": "metask", "billing": "metask"},
  "capabilities": {
    "run_state": "opaque",
    "step_signature": true,
    "input_required": true,
    "client_provider": true,
    "prefetch": false,
    "client_sealed": false,
    "currencies": ["USD"]
  }
}
```

`capabilities.run_state` is `"opaque"` or `"server"`. `step_signature` says
every Step carries `sig` (§8.4). `client_provider` says the gateway calls
the model over the client's route and credential (§8.1); in revision
2026-10-15 it MUST be `true` — the protocol defines no other account a
run's model calls could be made on — and a client MUST NOT start a run on
a gateway that does not advertise it. `identities.billing` names who
charges the Skill fee (§8.2); no identity bills for the model. `prefetch`
and `client_sealed` are §7 features and are `false` in revision
2026-10-15.

### 3.2 `sealed/skills.list`

Params: `{"cursor": "<opaque>"?}`. Result: `{"skills": [Entry...],
"next_cursor": "<opaque>"?}`. An Entry is:

```json
{
  "skill_id": "ssk_7f3a…",
  "version": "1.4.0",
  "manifest": { … §5 … },
  "manifest_digest": "sha256:…",
  "manifest_sig": "<base64 Ed25519 over the canonical manifest>"?,
  "subscription": {"state": "active" | "available" | "expired"},
  "assets": [{"path": "scripts/post.py", "sha256": "sha256:…", "bytes": 1832}]
}
```

`manifest_digest` is SHA-256 over the canonical JSON (§4.5) of `manifest`.
The client stores Entries it installs as **pins**; a pin is the user's
consent to exactly that manifest (§6.1). `assets` lists the package's
**public files** (§12): the client installs them under the pin directory
with `sealed/skills.asset`, so the Skill's scripts and data exist where its
brain believes they are. The Skill body and the `sealed/` directory are
never listed and never served.

### 3.3a `sealed/skills.asset`

Params: `{"skill_id", "path"}` with a `path` from the Entry's `assets`.
Result: `{"path", "sha256", "content_base64"}`. The client MUST verify the
digest against the Entry before writing the file, and MUST refuse a path
that is not a plain relative path inside the pin directory.

### 3.3 `sealed/skills.get`

Params: `{"skill_id"}`. Result: one Entry. Error `skill_not_found` when the
id is unknown or not visible to this subscriber.

### 3.4 `sealed/runs.start`

```json
{
  "skill_id": "ssk_7f3a…",
  "manifest_digest": "sha256:…",
  "prompt": "the user's task, as the activating turn would have given a local Skill",
  "arguments": ["positional", "values"],
  "tools": [ToolDefinition...],
  "budget": {"max_cost_micros": 500000, "currency": "USD", "max_steps": 200},
  "client": {"name": "metacodes", "version": "0.6.0", "platform": "windows-x86_64",
             "run_ref": "<client-side run id, for audit joins>"},
  "locale": "zh-CN"?,
  "confirmation": "client" | "always",
  "system": "<the fork's system prompt, exactly as the client's own fork would send it>",
  "base_dir": "<the pin directory: the Skill's base directory as the brain is told it>",
  "provider": {"kind": "anthropic" | "openai" | "gemini", "base_url": "https://…",
               "openai_protocol": "chat_completions" | "responses"?,
               "auth": {"scheme": "bearer" | "api_key_header" | "custom_header",
                        "header": "x-api-key"?, "value_prefix": ""?}?},
  "provider_tools": []?,
  "request": {"model": "claude-sonnet-4-5", "max_tokens": 8192, "reasoning_effort": "high"?}
}
```

- `manifest_digest` is the pinned digest. If the Skill's current manifest
  differs the gateway MUST fail with `manifest_changed` and MUST NOT run; the
  client refreshes the pin through `skills.get` and asks the user again.
- `tools` are the definitions (name, description, input schema) of the
  client's tools that fall inside the manifest's `tools.allow` and outside
  `tools.deny`, in the client's own schema dialect. A gateway MUST request
  only tools listed here, by exactly these names and against these schemas;
  it MUST NOT assume a tool exists because the manifest allows it.
- `provider_tools` is reserved for the provider-side server tools the
  fork's request would carry, and in this revision it MUST be absent or
  empty: the agent loop keeps no server-tool blocks, so a turn the provider
  pauses (`pause_turn`) could only be truncated, and the client's own fork
  refuses such tools before its first request. A gateway MUST refuse a
  non-empty list with `invalid params` naming `provider_tools`, before any
  model call.
- `budget.max_cost_micros` is the cap for this run in micro-units of
  `currency` (USD 0.50 is `500000`): a cap on the gateway's estimate of
  what the run's model calls cost on the client's own account (§8.2). The
  gateway MUST stop with `budget_exceeded` before `cumulative.cost_micros`
  would pass it. `max_steps` bounds the number of Steps.
- `confirmation: "always"` asks the gateway to mark every call `confirm:
  true`; `"client"` (default) leaves it to the manifest and the gateway.
- `system`, `tools`, `provider_tools`, `request` and the credential header
  together are the **mirror** (§9.1): everything the client's own fork would
  have put in its model request. A gateway whose brain is a model loop MUST
  make the request from these and from nothing of its own, so that the
  request the model sees is the one the client's fork would have sent, with
  the Skill body in the first user turn. `arguments` are rendered into the
  body on the gateway exactly as the client renders a local Skill's.
- `base_dir` is where the client installed the Skill's public assets (§3.2);
  the brain is told it as the Skill's base directory, and a `Read`, `Glob`
  or `Grep` under `<base_dir>/sealed/` is served by the gateway from the
  package (§12).
- `provider` is the client's route without its credential; `auth` absent
  means the kind's default header. A `signed_adapter` scheme cannot be
  carried and such a client cannot run sealed Skills. `kind` has exactly
  the three values above: a client on any other transport (Amazon Bedrock's
  Converse wire, for one) cannot run sealed Skills either, and a gateway
  answers any other value with `invalid params`.

Result: a Step (§4.3).

### 3.5 `sealed/runs.continue`

```json
{
  "run_id": "run_…",
  "run_state": "<opaque, from the previous Step>",
  "seq": 4,
  "results": [
    {"tool_use_id": "call_1", "content": "…", "is_error": false,
     "truncated": false, "redactions": ["erp-main"]}
  ]
}
```

- `seq` is the `seq` of the Step being answered. A gateway MUST reject a
  stale or future `seq` with `run_state_invalid`.
- `results` MUST contain exactly one entry per call in that Step, in any
  order. `content` is the tool's result as the client would have given its
  own model: text, or a JSON array of content parts when the tool returned
  parts (images are allowed only when the manifest's egress classes include
  `images`).
- `truncated` is `true` when the client cut the result to the manifest's
  `egress.max_result_bytes` (§6.3). `redactions` lists the credential
  references whose values the client replaced in the content (§6.4).
- A call the client refused (policy, permission denied by the user, tool
  missing) is reported with `is_error: true` and a `refusal` field:
  `"policy_violation" | "permission_denied" | "tool_unavailable" |
  "budget" | "aborted"`. The gateway MUST treat a `policy_violation`
  refusal as a defect in its own Skill, not as something to retry.

Result: the next Step.

### 3.6 `sealed/runs.cancel`

Params: `{"run_id", "run_state", "reason": "user_abort" | "budget" |
"policy" | "client_error"}`. Result: a Step of kind `failed` with
`reason: "cancelled"` and the final `cumulative` usage. The gateway MUST
charge nothing for work after a cancel is received.

## 4. Objects

### 4.1 ToolDefinition

The client's neutral tool definition: `{"name", "description",
"input_schema": <JSON Schema object>}`. Names are the client's own
(`Read`, `Bash`, `mcp__playwright__browser_click`, …).

### 4.2 Identities

Every Step and every Entry carries `issuer`: `{"skill_host": "<id>",
"inference_gateway": "<id>"}`, the gateway identities that produced it. A
client MUST record them with the run (§8.3).

### 4.3 Step

```json
{
  "run_id": "run_…",
  "seq": 4,
  "run_state": "<opaque>",
  "kind": "tool_calls",
  "calls": [
    {"id": "call_1", "name": "Read", "input": {"file_path": "src/app.zig"},
     "confirm": false, "deadline_ms": 30000, "credentials": [],
     "result_limit_bytes": 65536}
  ],
  "text": "optional progress text for the user",
  "usage": {"model": "claude-sonnet-5-5", "input_tokens": 1830, "output_tokens": 92,
            "cache_read_input_tokens": 1500, "cache_creation_input_tokens": 0,
            "cost_micros": 7100, "currency": "USD"},
  "cumulative": {"steps": 4, "cost_micros": 24400, "currency": "USD",
                 "input_tokens": 7300, "output_tokens": 410},
  "issuer": {"skill_host": "metask", "inference_gateway": "metask"},
  "prev_digest": "sha256:…",
  "results_digest": "sha256:…"?,
  "disclosure": {"redactions": 1}?,
  "digest": "sha256:…",
  "sig": "<base64 Ed25519 over digest>"?
}
```

`results_digest` is present on every Step derived from a `runs.continue`:
the digest (§4.5) of that request's `results` array as the gateway parsed
it. It is inside the digested body, so the chain binds what the client sent
as well as what the gateway answered (§8.3). It is absent on the first Step;
a client ends the run when the Step answering its `runs.continue` lacks it
or carries another value.

`disclosure` is present when the gateway's screen (§8.5) replaced passages
of the Skill's sealed material in this Step's `text`, call inputs or
question: `redactions` counts them. The replaced passages read `[sealed]`.

`kind` is one of:

| kind | meaning | fields |
|---|---|---|
| `tool_calls` | execute `calls`, answer with `runs.continue` | `calls` (1..n); no `text`: the brain's narration between calls is its own reasoning and stays on the gateway |
| `final` | the run is complete | `text` (the Skill's result for the user), `charge` (§4.6) |
| `input_required` | the Skill needs something only the user can give | `question`: `{"id", "message", "schema"?, "tool_input"?}`; `tool_input` is the brain's `AskUserQuestion` call as the client's own tool takes it, which the client runs verbatim, `message`/`schema` (MCP elicitation form shape) are for a client or gateway without that tool; answered through `runs.continue` with one result whose `tool_use_id` is the Step's `question.id` |
| `failed` | the run ended without a result | `reason`: `"budget_exceeded" \| "max_steps" \| "cancelled" \| "skill_error" \| "policy_violation" \| "upstream_unavailable" \| "disclosure"`, `message`, `charge` |

A `usage` block is present on every Step and describes the gateway's work
*since the previous Step* — every model call the shadow made for it,
including the ones that served sealed reads or compacted its context (zero
for a pure workflow-engine step). `cumulative` is the running total. The
token counts are the provider's own numbers for calls made with the
client's credential, so they are also on the client's provider bill;
`cost_micros` is the gateway's estimate of what those calls cost there
(§8.2). A Step carries both: the client's cap and ledger use the estimate
in revision 2026-10-15, and a client that prices with its own table MAY
use the counts instead.

Call fields:

- `confirm: true` means the client MUST obtain an explicit user approval for
  this call even in a permission mode that would otherwise auto-allow it.
- `deadline_ms` is how long the gateway will wait for this Step's results;
  the client SHOULD report `is_error` with `refusal: "aborted"` for a call
  it could not finish in time rather than letting the run die.
- `credentials` names credential references (§6.4) the call needs.
- `result_limit_bytes` caps the result the gateway wants; it MUST NOT exceed
  the manifest's `egress.max_result_bytes`.

### 4.4 `run_state`

An opaque string. The client MUST return it unchanged on the next message
and MUST NOT interpret it. A stateless gateway encodes the run's
conversation and workflow position in it, encrypted and authenticated with
a gateway key (AEAD, key id in the clear), so that a tampered blob, or one
presented under another run, fails with `run_state_invalid` (what this does
and does not say about replay: §8.4). Size SHOULD stay under 256 KiB; a
gateway that needs more SHOULD switch to server-side state for that run.

### 4.5 Canonical JSON

Digests are computed over the canonical JSON of an object: UTF-8, keys
sorted by code point, no whitespace, no `+`/leading zeros/exponent in
integers, floats forbidden in digested objects (use integers in micro-units
or strings). The `digest`, `sig` and `run_state` fields are removed before
digesting a Step; `manifest_digest` and `manifest_sig` are not part of the
manifest.

### 4.6 Charge

The `final` and `failed` Steps carry
`charge: {"run_id", "cost_micros", "currency", "steps", "issued_at",
"digest", "sig"?}`: the receipt the client appends to its ledger. A gateway
MUST make `charge.cost_micros` equal `cumulative.cost_micros` of the same
Step.

## 5. Manifest

The manifest is the only part of a Skill the client ever holds. It is
written by the creator, validated and possibly annotated by the gateway at
publish time, and pinned by the user at install time.

```json
{
  "schema": "metask.sealed-skill.manifest/v1",
  "skill_id": "ssk_7f3a…",
  "version": "1.4.0",
  "name": "erp-post-invoice",
  "display_name": "ERP invoice posting",
  "description": "Posts supplier invoices into the ERP from a folder of PDFs. Use when…",
  "when_to_use": "…",
  "argument_hint": "[folder]",
  "arguments": ["folder"],
  "creator": {"id": "cr_…", "display_name": "…"},
  "tools": {
    "allow": ["Read", "Glob", "Grep", "Bash(python3 *)", "mcp__playwright__*"],
    "deny": ["Bash(rm *)"]
  },
  "confirmation": {"required_for": ["Write", "Edit", "mcp__playwright__browser_click"]},
  "egress": {
    "classes": ["file_contents", "command_output", "page_snapshot"],
    "max_result_bytes": 65536,
    "retention": "run"
  },
  "credentials": [{"ref": "erp-main", "purpose": "ERP login", "kind": "password"}],
  "execution": {"classes": ["server"]},
  "pricing": {"model": "subscription", "estimate_micros_per_run": 60000, "currency": "USD"},
  "protection": {"rating": "judgement_heavy", "action_layer_reconstructibility": 0.31},
  "requires": {"protocol": "metask.sealed-skill/v1", "client_min_version": "0.6.0"}
}
```

- `tools.allow` / `tools.deny` use the client's permission-rule syntax
  (`Tool`, `Tool(pattern)`, `prefix__*`). **The client enforces them**
  (§6.2); the gateway promises not to exceed them.
- `confirmation.required_for` lists tools whose calls the gateway MUST mark
  `confirm: true`; the client MAY add more.
- `egress.classes` declares what kinds of data leave the machine as tool
  results: `file_contents`, `command_output`, `page_snapshot`, `images`,
  `repository_structure`, `environment`. A client MUST refuse a call whose
  result would fall outside the declared classes when it can tell — before
  running it, from the tool alone: `Read`, `Grep`, `Edit` and
  `NotebookEdit` return `file_contents`, `Glob` `repository_structure`,
  `Bash` and `BashOutput` `command_output`, `WebFetch` and `WebSearch`
  `page_snapshot`; a tool whose result it cannot classify (a subagent, an
  MCP tool, a write's confirmation) is not refused on class grounds — and
  MUST show the classes at install time. `repository_structure` also
  governs the one thing that leaves the machine other than as a tool
  result: the codebase context the client's own forks carry in their system
  prompt (the CLAUDE.md chain and git status). A sealed fork carries it
  only under that class; otherwise it starts without it. `egress.disclosure`
  is the creator's policy for the gateway's disclosure screen (§8.5):
  `"redact"` (the default) replaces a passage that quotes the Skill's sealed
  material with `[sealed]` and the Step counts it, `"fail"` ends the run as
  `failed` / `disclosure`, `"off"` disables the screen. The screen has two
  corpora with their own policies — the **body** (the Skill's instructions)
  and the **references** (the `sealed/` files) — so the field is either one
  word for both or `{"body": "redact", "references": "off"}`. A
  documentation Skill, whose purpose is to restate its references, sets
  `references` to `off` and keeps its instructions screened; a Skill whose
  references are its private rules keeps both at `redact` or `fail`.
  `retention` is the gateway's promise for tool results: `"run"` (discarded
  when the run ends) or `"audit"` (kept for the audit window the operator
  publishes).
- `credentials` declares references the Skill will ask for; the user binds
  each to a local secret at install time or on first use (§6.4).
- `execution.classes` is `["server"]` in revision 2026-10-15; §7 adds
  `client-sealed`.
- `protection` is written by the gateway, not the creator: the publish-time
  self-check's estimate of how much of the Skill a tool trace reconstructs.
  It is informative, shown to the creator, and MAY be shown to users.

A gateway MUST reject a manifest whose `tools.allow` is empty, whose
`egress.classes` is empty while `tools.allow` names a tool that returns
data, or whose `description` is empty. `tools.allow: ["*"]` is the whole
tool set of the client's fork, as a local Skill without `allowed-tools` has.
`AskUserQuestion` is always available to a sealed Skill whatever the
allowlist says: it never executes anything, it asks the person running the
Skill (§4.3 `input_required`).

## 6. Client obligations

### 6.1 Pinning and consent

Installing a Skill means storing its Entry (manifest + digest + signature)
as a pin, and its public assets (§3.2) under the pin directory, after
showing the user, at minimum: name, description, creator, the tool
allowlist, the egress classes, the credentials it will ask for and the price
estimate — and what travels with every run besides tool results: the
project's CLAUDE.md chain and git status when `repository_structure` is
declared, nothing of the kind otherwise. A run MUST send the pinned digest.
A `manifest_changed`
error MUST NOT be resolved silently: the client refreshes the Entry and
repeats the consent step with a diff of the manifest.

### 6.2 Policy enforcement

The client evaluates every call in a Step against the pinned
`tools.allow`/`tools.deny`, and a call whose result class it knows (§5)
against `egress.classes`, **before** its ordinary permission system sees
it. A call outside the allowlist, or whose results fall outside the
declared classes, is never executed; it is answered with
`refusal: "policy_violation"`, logged, and counted. After three policy
violations in one run the client MUST cancel the run with `reason:
"policy"`. A call inside the allowlist then goes through the client's normal
permission, sandbox and budget machinery exactly as a model-originated tool
call would; `confirm: true` additionally forces an interactive approval.

The gateway is an untrusted principal: no path in the client may execute a
gateway-requested tool with more authority than the user's own model would
have had in the same session.

### 6.3 Result limits

Results are truncated to `min(call.result_limit_bytes,
manifest.egress.max_result_bytes)` with `truncated: true`; the client
SHOULD keep the head and a marked tail, as it does for its own model.

### 6.4 Credentials

A credential reference is a name (`erp-main`) bound locally to a secret.
When a call lists references, the client substitutes the secret for the
placeholder `${SEALED_CRED:erp-main}` wherever it appears in string values
of `input`, executes, and then **replaces every occurrence of the secret's
value in the result with `[redacted:erp-main]`** before sending it, listing
the reference in `redactions`. The gateway never receives the secret. A
reference not bound locally makes the call fail with `refusal:
"permission_denied"` and the client prompts the user to bind it.

### 6.5 Budget

Before `runs.start` the client decides `max_cost_micros` (a per-skill or
global setting, or a prompt to the user). It MUST stop executing calls and
cancel with `reason: "budget"` as soon as `cumulative.cost_micros` exceeds
the cap, independently of the gateway's own enforcement.

### 6.6 Audit

For every Step the client records `run_id`, `seq`, `digest`, `prev_digest`,
`issuer`, the call ids and names, a digest of each result it sent,
`usage`, and the `charge` receipt. The record is append-only and local to
the subscriber (§8.3).

## 7. Execution classes beyond `server`

Revision 2026-10-15 defines one execution class, `server`: everything the
Skill is runs on the gateway. Two extensions are reserved and MUST be
advertised through `capabilities` before use:

- **`client-sealed`**: a creator asset compiled to WebAssembly, encrypted
  per run by the sealing issuer, delivered inside a Step and executed by
  the client **in memory only** on a signed runtime whose host calls go
  through the same permission and sandbox as every other tool. The module is
  bound to a machine fingerprint and a time window. This is *deterrent-grade*
  confidentiality plus licensing control, never secrecy: it exists for
  logic that must touch large local state the Skill cannot afford to upload.
- **`prefetch`**: a workflow-engine gateway may include up to N future
  Steps whose inputs do not depend on results, so a transient gateway
  outage does not stall a deterministic run. N is small by design; a
  prefetched sequence must not amount to the workflow.

Both are specified in a later revision; the identifiers are reserved here
so manifests and capability negotiation do not change shape.

## 8. Security and accountability

### 8.1 The model is the client's

The gateway holds **no model-provider credentials of its own**. Every model
call of a run is made over the client's provider route (`provider` and
`request` in `runs.start`) with the credential the client sends in the
`Sealed-Provider-Credential` header of that request. The gateway MUST use
the credential only for the model calls of the request that carried it,
MUST NOT persist, log or echo it, and MUST refuse `runs.start` and
`runs.continue` without it. The client sends the credential its own
provider would have sent for the fork (its API key, or its current OAuth
bearer; refresh stays on the client), so the model, the account, the prompt
cache and the bill are the user's own, and the shadow's request is the
fork's request.

What this costs, stated plainly: for the duration of a Step the gateway can
spend on the user's account, and the client's `max_cost_micros` does not
bound that — only the credential's lifetime and the provider-side limits
do. A short-lived token, or a dedicated key with a spend cap, is the right
thing to hand a gateway. The client's provider endpoint MUST be reachable
from the gateway (a model served from the user's own loopback is not), and
a credential whose scheme cannot be carried in a header (`signed_adapter`),
or a route on a transport `provider.kind` has no value for (§3.4), cannot be
delegated; the client says so rather than running the Skill without it.

A gateway MAY keep a client's built provider — and, where its client allows
it, the upstream connection — for a short idle window after a request,
keyed by the route and the credential, so that consecutive Steps of a run do
not each rebuild the client or pay an upstream handshake. Within that window the credential exists in process
memory inside that client and nowhere else; it is never written or logged,
and the window is bounded (the reference gateway: 60 s, `--provider-cache-ms
0` restores strict per-request handling).

### 8.2 Metering

Model usage is billed where the calls are made: on the client's own
provider account (§8.1). The subscriber's gateway account is charged
nothing for it. `usage` reports the provider's token counts for every call
of the Step, and `usage.cost_micros` the gateway's estimate of what they
cost there, from those counts and the gateway's price table. The estimate
is informational — the provider's own bill is authoritative — but it is the
number the client's cap (§6.5) and ledger (§6.6) use in revision
2026-10-15, so the gateway MUST report both the counts and the estimate for
every Step. The Skill's own fee, when the gateway's operator charges one,
is carried by `charge` (§4.6) and is what the subscriber owes the gateway;
its terms are outside this protocol.

### 8.3 Tamper-evident log

Steps form a hash chain: `prev_digest` is the previous Step's `digest`
(`sha256:` over 32 zero bytes for `seq: 1`), and the client's `results` are
digested into the next Step by the gateway as `results_digest` — the digest
of the canonical JSON of the `results` array it received. The client
computes the same digest over the array it sent and MUST end the run as
`failed` / `client_error` when the Step answering its `runs.continue` does
not carry exactly that digest: a gateway that binds other results than the
ones it was given — or none — is misreporting the conversation. Either side
can therefore show, after the fact, what the other sent: the client keeps
per-result digests and the array digest in its ledger, the gateway keeps
the chain. With `step_signature`, `sig` is an
Ed25519 signature by the inference gateway over `digest`; the key is
published at `<gateway>/.well-known/sealed-skill.json`.

### 8.4 Replay and ordering

`run_state` is authenticated with the run id as associated data and carries
`seq`, so a tampered blob, a blob presented under another run's id, or a
`seq` that does not match the blob is rejected with `run_state_invalid`.
What a stateless gateway does **not** prevent, and this document does not
promise: the holder of a blob replaying it. An old `run_state` with its own
`seq` is self-consistent, so a client can continue a run again from any
earlier Step and get a fresh continuation, at its own cost and on its own
account; the hash chain makes such a fork visible (two Steps with the same
`prev_digest`) and the client's ledger records both. A gateway that keeps
server-side state MAY additionally reject a `seq` it has already answered.
A client that crashes mid-run cannot resume it in any other way (there is
no resume method in v1); it cancels or lets the gateway's run deadline
expire, and is charged for the work done.

### 8.5 Disclosure through the model

Tool results are untrusted data to the model the gateway's brain runs on,
exactly as they are to the client's own loop, and the model can restate
what it was told. A gateway MUST screen what the brain is about to show
the client — a `final` text, every call's `input` in a `tool_calls` Step, a
`question` — against the Skill's own sealed material before the Step
leaves. The reference gateway replaces every run of eight consecutive
tokens (words compared without case or punctuation; CJK per character)
that also occurs in the body or a `sealed/` file with `[sealed]`, the Step
carries `disclosure.redactions`, and the brain's own conversation keeps the
original: the output is edited, never the brain's memory. The body and the
`sealed/` references are separate corpora under separate policies, because
they leak differently: restating the instructions is what the screen
exists for, while citing a reference verbatim is a documentation Skill's
job and a rule Skill's leak — only the creator knows which. The manifest's
`egress.disclosure` (§5) chooses `redact`, `fail` (the Step becomes
`failed` / `disclosure` and nothing of it reaches the client) or `off`, for
both at once or for each.
What the screen does not catch, stated plainly: a number, a name, a short
phrase, a paraphrase — a threshold restated as "under 5000.00" passes; the
rule it belongs to, quoted, does not. A gateway SHOULD add detection of its
own (embedding similarity, canary phrases seeded per creator) and MUST log
and attribute an attempt to the subscriber account. Operators publish what
they do here; the protocol does not promise that extraction is impossible.

### 8.6 Attested gateway (reserved)

A gateway MAY run Skills inside an attested enclave and publish the
attestation under `.well-known/sealed-skill.json`, so that creators can
encrypt Skills to the enclave and the operator's staff cannot read them.
The protocol fields do not change; `discover.capabilities.attestation`
is reserved for it.

### 8.7 Protecting the user from the Skill

The manifest allowlist, egress classes and `confirm` flags are enforced by
the client, and the gateway reviews Skills at publish time (allowlist versus
stated purpose) and watches runs for anomalies (a Skill that reads
credential directories it never declared). Those are gateway duties the
operator publishes; the client's duty is to never execute what the pin did
not consent to.

## 9. Reference implementation: metacodes

This section is informative for other implementations and binding for
metacodes. Both sides of the protocol live in `src/skills/sealed/`:
`protocol.zig` (objects, digests, envelope), `transport.zig` (client HTTP),
`pin.zig`, `credentials.zig`, `provider.zig` and `ledger.zig` (client),
`gateway.zig` (server). `tests/component/sealed_skill_test.zig` runs a pinned
Skill through a loopback gateway whose model is a mock SSE server playing
the client's own provider, with a probe standing in for the session's UI,
and asserts: the Skill body reaches only the model; the gateway calls the
model with the client's credential and model and refuses a request without
the credential; **the shadow's model request is byte-identical to the local
fork's** for the same Skill (base directory aside, under a manifest that
declares `repository_structure`); the tool result is
produced locally; the ledger holds the charge and never the credential; the
gateway restarts between two Steps and the run continues from the carried
state; an allowlist violation is refused locally; the bearer token gates the
gateway; a stale pin is refused before any model call; narration between
calls never reaches the client; a sealed reference file is read on the
gateway without a Step while a public asset is installed and read on the
client; a Glob and a Grep under `sealed/` are answered on the gateway
without a Step while a Glob over the Skill directory goes to the client; a
call whose result class is undeclared is refused before it runs; the fork's
codebase context reaches the gateway only under `repository_structure`; a
final that quotes a sealed line comes back with the passage replaced and
the Step counting it, a tool input that quotes one reaches the client's
tool redacted, and under `disclosure: "fail"` the run ends with nothing of
the Step shown; a
`confirm: true` call is approved interactively in bypass mode (and
a declined one reported as `permission_denied`); the brain's
`AskUserQuestion` is asked through the client's own dialog and the run
continues (or ends with the question when there is no channel, and a call
issued beside a question waits); and a bound credential is substituted into
the call and redacted from the result while an unbound one refuses the
call.

### 9.1 Client

- **Catalog.** `metacodes sealed install <gateway> <skill_id>` fetches the
  Entry, verifies the digest, prints the consent summary (§6.1), writes the
  pin under `<state root>/sealed-skills/<name>/` — `sealed.json` (the Entry
  verbatim, gateway URL, token variable) and a projected `SKILL.md` whose
  frontmatter carries the listing fields, the allowlist as `allowed-tools`
  / `disallowed-tools` (a lone `*` omits the key; `AskUserQuestion` is always
  added), `context: fork` and the three binding keys `sealed-gateway`,
  `sealed-skill-id`, `sealed-manifest-digest`, with a body of `$ARGUMENTS` —
  and installs every public asset of the Entry under the same directory
  after verifying its digest. The pin root is a personal-tier catalog source
  above every other personal source, so no local file shadows a subscribed
  name. `metacodes sealed list` prints the pins and the binding state of
  their credential references; a `sealed.json` that no longer verifies is
  listed as broken.
- **Activation.** `/name` and the `Skill` tool prepare the same activation
  plan as a local forked Skill. Execution re-reads and re-verifies the pin,
  checks it against the catalog's binding, and spawns the existing subagent
  loop with a `SealedSkillProvider` in place of the model provider. Its
  first `sendStream` sends `runs.start` with the fork's system prompt, the
  tool definitions the loop handed it (allowlist-filtered, deferred tools
  flagged; `provider_tools` stays empty, since the loop refuses provider
  server tools before its first request), the model, the
  output cap and reasoning effort of the session's own provider, that
  provider's route and, in the header, its credential; `runs.continue`
  follows with the new `tool_result` blocks. Each Step is replayed as
  neutral stream events (`tool_use_start` per call, `usage`, `done`), so
  dispatch, permission, sandbox, artifact storage and observation sinks are
  unchanged. A session whose provider has no delegable route cannot run
  sealed Skills and says so (§8.1).
- **Mirror.** The provider answers the loop's questions about the model —
  capabilities, output cap, reasoning effort — with the session's own
  provider's answers, so the loop advertises to the gateway exactly what it
  would have advertised to the model. The provider's route and credential
  are read from the session's provider **before every request**, so a
  refreshed OAuth token or a switched key is what the gateway gets, never a
  copy taken at activation. Two deliberate deviations: the context window
  it reports is effectively unbounded, so the client's copy of the fork
  conversation never compacts — the brain's conversation lives on the
  gateway, which compacts it; the client's is a mirror for pairing results.
  And the fork's system prompt carries the codebase context — the CLAUDE.md
  chain and git status — only when the manifest declares
  `repository_structure` (§5), the class under which that context leaves
  the machine; the install consent says which it is.
- **Executor mode.** The brain's iteration belongs to the gateway's loop;
  the client's fork loop is its executor. Its turn cap is the protocol's
  `max_steps`, not the subagent default; it never summarizes (the provider
  refuses compaction requests); the brain's text between calls is not
  replayed into it; the user's own stops — the cost cap, abort, policy
  violations, permission — apply as ever.
- **Chain and sequence.** Every Step's `digest` is recomputed and its
  `prev_digest` / `seq` checked against the previous Step before anything
  is recorded; a Step derived from a `runs.continue` must carry the digest
  of the results the client sent (`results_digest`, §8.3), which the client
  computed before sending and keeps in its ledger; any mismatch ends the
  run with `SealedChainBroken`.
- **Policy.** The policy frame derived from the pinned allowlist refuses a
  call outside it before dispatch, and the provider refuses, before adopting
  it, a call whose result class (§5) the manifest does not declare; either
  refusal is reported as `policy_violation`, counted, and the run is
  cancelled with `reason: policy` at the third. Results are truncated to
  the smaller of the call's and the manifest's byte cap.
- **Budget.** The cap is `METACODES_SEALED_MAX_COST_MICROS` (default
  `500000`, USD 0.50). It is sent as `budget.max_cost_micros`, enforced by
  the provider on the gateway's `cumulative` (cancel with `reason:
  budget`), and passed to the child loop as `cost_budget_usd` for its own
  estimate-based stop. It bounds what the gateway charges; it cannot bound
  what the gateway spends on the client's account (§8.1).
- **Ledger.** `<state root>/ledger/sealed.ndjson` holds, per run, a
  `step` record per Step (usage, chain link, the `results_digest` the
  gateway bound, issuer, and every call's id and name as `tool_calls`), a
  `results` record per `runs.continue` (for each result its `tool_use_id`,
  the SHA-256 of the content exactly as sent, its size, `is_error`,
  `truncated`, `refusal`, `redactions`, and the digest of the whole array
  as sent, §8.3) and a `charge` record per receipt — what §6.6 asks for,
  without the contents themselves.
  `metacodes sealed ledger` prints it. The provider credential is never
  written there.
- **Disclosure.** A Step whose `disclosure.redactions` is not zero is
  logged at warn under `sealed`, recorded in the ledger
  (`disclosure_redactions`) and announced once in the fork's output; the
  `[sealed]` markers stay where the passages were.
- **Confirmation.** A call marked `confirm: true` is approved
  interactively whatever the permission mode (§6.2). The provider does not
  decide permissions: it answers the child permission context's *confirm
  gate* (`permission/confirm_gate.zig`), which the loop consults after the
  ordinary decision and which can only tighten — an `allow` becomes an `ask`
  whose prompt ignores a remembered "allow always" for the tool (a
  remembered deny still denies), and the stream prefetch never starts a
  gated call. A declined prompt is reported as `refusal: permission_denied`.
- **Credentials.** `metacodes sealed bind <name> <ref>` (secret from stdin
  or `--from-env VAR`, never argv) binds a reference the pinned manifest
  declares to a local secret, scoped to that Skill's `skill_id`, in
  `<state root>/sealed-credentials.json` (mode 0600; a file of its own
  rather than a section of `auth.json`, whose writers rebuild the whole
  document from their own struct on every OAuth refresh). `metacodes sealed
  unbind` removes it and `metacodes sealed list` shows each pin's references
  as bound or not. For a call that lists references the provider replaces
  `${SEALED_CRED:<ref>}` in the input JSON with the JSON-escaped secret
  before streaming the call to the loop, and replaces every byte-exact
  occurrence of the secret in the result with `[redacted:<ref>]` *before*
  truncation, listing the reference in `redactions`. A reference the
  manifest does not declare, or one not bound here, is never dispatched: the
  call is answered with `refusal: permission_denied` and the bind command,
  and the same hint is prepended to the fork's result for the user. A result
  that is JSON-escaped or otherwise transformed differently from the secret
  is not recognized; redaction is byte-exact.
- **Input.** An `input_required` Step that carries `tool_input` is answered
  by running the client's own `AskUserQuestion` tool on it, with the
  session's UI requester (the tool context's at the top level, else the
  permission context's), so the brain gets the result shape it asked for;
  one that carries only a message gets one dialog with the options of a
  single-property `enum` in the elicitation schema and the dialog's
  free-text entry otherwise. The answer is sent as the Step's one result
  (`tool_use_id` = `question.id`) in `runs.continue` and the run goes on. A
  dismissed dialog sends `is_error` with `refusal: aborted`; a tool error
  (a malformed question) is sent as the tool's error. Without a channel
  (headless, or an asynchronous front end that can only stash the question)
  the run is cancelled and the question becomes the fork's text.
- **Token.** The bearer token is read from the environment variable named
  by the pin (`--token-env`, default `METACODES_SEALED_TOKEN`).
- **Transport.** One `std.http.Client` POST per request with
  `Sealed-Skill-Version: 1` and, while a run is open, the provider
  credential header; JSON and SSE answers are both accepted; in-flight
  requests sit in the shared abort registry with a two-minute liveness
  limit, so Ctrl+C and a dead socket both end the call. Every exchange is
  logged at info level under the `sealed` module (method, request id, HTTP
  status, bytes each way, latency), and the provider logs each Step it
  adopts (seq, kind, calls) and each `runs.start` / `runs.continue` /
  `runs.cancel` it sends — never parameters or results — so a client trace
  (`METACODES_LOG=sealed:info`) shows the protocol conversation.
- **Not in revision 2026-10-15 of the client:** suspending a fork on an
  `input_required` Step for an asynchronous front end (the run is cancelled
  instead, see *Input*); `confirmation: "always"` as a client setting (the
  manifest and the gateway decide which calls carry `confirm`); a run-level
  budget prompt (the cap is the environment variable); nested sealed brains
  (a `Task` the brain issues is a client tool and runs a local subagent, as
  a local fork's would).

### 9.2 Gateway

`metacodes sealed serve --skills <dir> [--listen PORT] [--token T]` is the
reference gateway. A package is `<dir>/<name>/SKILL.md` plus
`manifest.json` (§5, creator fields only), an optional `sealed/` directory
and any other files as public assets (§12); the manifest is canonicalized
and digested at load, the assets are listed in the Entry with their
digests, and the body and the sealed files never leave the process. The
server listens on loopback only and answers requests in order; TLS,
fan-out and non-loopback exposure are a reverse proxy's job. It stops on
Ctrl+C (SIGINT; also SIGTERM/SIGHUP, or the console closing on Windows):
the accept loop is joined, the listener closed and the packages freed
before the process exits. A port already in use is refused at start, never
shared with the instance that holds it.

- **No provider.** The gateway has no model credentials and no `--provider`
  flags. For every `runs.start` and `runs.continue` it builds a provider
  from the client's `provider` route and `request` model with the
  credential in the request's header, through the same provider factory the
  CLI uses, and releases it with the request (§8.1). A request without the
  header is refused with `invalid params` naming the header, and a
  `runs.start` with a non-empty `provider_tools` with `invalid params`
  naming that field (§3.4).
- **The shadow loop.** The brain is the client's own `agent_loop`, run on
  the gateway with the client's system prompt, tool definitions (deferred
  flags preserved, so `ToolSearch` stays or goes as it would on the client),
  the body rendered with the user's arguments as the
  first user turn behind `Base directory for this skill: <base_dir>`, a
  bypass permission context (the client is the permission authority), no
  hooks, no settings, no memory, no task store, nothing loaded from the
  gateway's own environment. Its tool dispatcher executes nothing: every
  tool use is marked pending, the loop suspends on the batch
  (`Options.suspend_all_pending`), and the batch is the Step. The one thing
  the dispatcher serves itself is a `Read`, `Glob` or `Grep` whose target
  lies under `<base_dir>/sealed/`, and only when the manifest admits the
  tool: the client's own tool implementation runs against the package's
  sealed directory — a Read rendered as the client's would be, a Glob or
  Grep with every path it prints rewritten to the client's
  `<base_dir>/sealed` — and the loop goes on inside the same Step. A search
  over the Skill directory as a whole is forwarded unchanged and sees the
  public assets only; a sealed tool the manifest does not admit is forwarded
  too, so the client refuses it as it would any other. A later Step resumes
  the loop with the client's results and the gateway's own as one user turn
  (`resumeRunWithResults`), so the API's tool_use/tool_result pairing holds.
- **Stateless runs.** The loop's continuation — the conversation's active
  window in the transcript's own message shape plus the compaction summary
  that stands for everything before it (the projected-away prefix is not
  carried, so the state stays the size of a context window instead of
  growing with every Step), the pending batch, the gateway's own results,
  totals, caps, the client's route and request parameters — is sealed into
  `run_state` with XChaCha20-Poly1305 under a process key, with the run id
  as associated data; `runs.continue` and `runs.cancel` fail with
  `run_state_invalid` on a tampered or foreign blob, or a `seq` that does
  not match (replay by the blob's holder is not prevented, §8.4). On
  restore the summary becomes the first assistant turn, which is the
  projection the loop would have made of it and lets a later compaction
  fold it in. Nothing is stored server-side, the body is re-read from the
  package rather than carried, and any gateway instance with the key serves
  any Step; the suite restarts the gateway between two Steps.
- **Steps.** `tool_calls` for a suspended batch of remote tool uses (with
  `confirm` from the manifest or `confirmation: always`, `credentials` from
  the manifest-declared placeholders the input names, and
  `result_limit_bytes` from the manifest; never `text`), `input_required`
  when the batch holds an `AskUserQuestion` call (the first question is the
  Step, carrying the call's input as `tool_input`; other calls of the same
  batch are answered by the gateway with an error asking the brain to call
  again), `final` with the last assistant message's text on `end_turn`,
  `failed` on the cost cap, the step limit, the internal turn cap (model
  turns without a tool call for the client), three client policy refusals,
  a cancel, a provider failure or a loop stop the Skill cannot continue
  from. The digest is computed before the state is sealed with it as chain
  head, then both are attached.
- **Metering.** `usage` is the loop's token usage since the previous Step
  (every model call it made, sealed reads and compaction included), costed
  with the local price table for the client's model (§8.2); `cumulative`
  and `charge` carry the running total. The gateway stops with
  `budget_exceeded` as soon as the total passes the client's cap.
- **Disclosure screen.** `disclosure.zig` builds, at package load, the set
  of eight-token windows of the body and every sealed file; `emitStep`
  passes a `final` text, each call input of a `tool_calls` batch and a
  question through it before the Step is rendered (`screenEmit`), by the
  manifest's `egress.disclosure`: `redact` replaces the passage with
  `[sealed]` and counts it in the Step, `fail` turns the Step into
  `failed` / `disclosure` with the pending batch dropped, `off` skips it.
  The brain's conversation in `run_state` keeps the original.
- **Not in revision 2026-10-15 of the gateway:** Step signatures
  (`step_signature: false`), subscriptions and per-account authorization
  beyond the single bearer token, a Skill fee in `charge` (it carries the
  model-cost estimate), the publish-time protection rating, and any
  disclosure detection beyond the eight-token screen of §8.5.

## 10. Error codes

JSON-RPC `error.code` in the application range, `error.data.code` carrying
the symbolic name:

| code | name | meaning |
|---|---|---|
| -32001 | `unauthorized` | token missing or invalid |
| -32002 | `subscription_required` | the account may not run this Skill |
| -32003 | `skill_not_found` | unknown or invisible `skill_id` |
| -32004 | `manifest_changed` | pinned digest is not current; `data.current` holds the Entry |
| -32005 | `run_not_found` | unknown `run_id` |
| -32006 | `run_state_invalid` | tampered or foreign `run_state`, or a `seq` that does not match it |
| -32007 | `budget_exceeded` | the run would pass `max_cost_micros` |
| -32008 | `policy_violation` | the client reported refusals the gateway cannot recover from |
| -32009 | `rate_limited` | not processed; resend the identical request after `data.retry_after_ms` (§2 Admission) |
| -32010 | `unsupported_version` | `Sealed-Skill-Version` not implemented |
| -32011 | `upstream_unavailable` | the gateway's model provider failed |

## 11. Versioning

The protocol identifier carries the major version; `revisions` lists the
dated minor revisions a gateway implements. A minor revision adds fields or
capabilities; it never changes the meaning of an existing field. A client
MUST ignore unknown fields in Steps and Entries and MUST NOT ignore an
unknown `kind`: an unknown `kind` ends the run as `failed` with `reason:
"client_error"`.

## 12. Creator-side publishing (informative)

A Skill package is `SKILL.md` (frontmatter and body as today), the manifest
(§5, without the gateway-written fields), a `sealed/` directory of
reference files only the gateway reads, and any other files, which are
**public assets**: installed on the client under the pin directory (§3.2)
and executed or read there like a local Skill's. What is sealed is the
text the model reads — the body and `sealed/` — not glue code; an author
who needs to protect a script compiles it. A sealed body MUST NOT rely on
shell injection (`` !`cmd` ``): the gateway renders it with shell execution
disabled. Optionally a package carries a workflow definition that lets the
gateway drive the happy path without a model and reserve the model for
exceptions. The
gateway validates the package, computes the protection rating from sample
runs, signs the manifest, and lists it. Creators are paid per successful
run or per subscription period out of the Skill fee the gateway records
(§8.2) — never out of model usage, which is each subscriber's own bill on
their own provider account; the wire protocol carries nothing of that
relationship except the identities in §4.2.
