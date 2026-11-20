# Provider profiles, model offers, and the runtime control plane

Status: **all delivery slices shipped** — P0 identity and kernel boundary, the
P1 providers (Z.AI GLM Coding Plan, OpenAI/Codex OAuth lifecycle), offer and
routing metadata with the OpenRouter adapters, controls and the cross-UI picker,
user-defined providers, and the P2 follow-ups (aliases, credential pools,
learned failover, the TinyKG audit plane). The P2 signed-adapter slice and the
four items below are open by their own terms. Issue: `metask-ai/metacodes#16`.

This document is the normative description of the provider identity model, the
credential contract, and the control-plane API. It also records, explicitly,
what is *not* implemented yet — the requirement's delivery slices are
incremental by design, and a silent gap is worse than a listed one.

## Why this exists

The previous provider layer normalized request and streaming behaviour but not
identity:

| Concern | Before | Now |
|---|---|---|
| Provider identity | `types.ProviderKind = enum{anthropic,openai,gemini}` | `ProviderProfile` registry, one file + one line per vendor |
| Transport choice | `main.zig inferProviderKind()` guessed from the model-name prefix | the offer's protocol selects the transport |
| Route identity | one `base_url` + one `model` string | `ProviderProfile → ChannelDescriptor → ModelOffer` |
| Credentials | one opaque bearer token, `METASK_API_KEY` consulted for any provider | typed `CredentialRef`, provider-scoped resolution, per-profile env aliases |
| Auth on the wire | hard-coded `authorization: Bearer` | provider-declared `AuthScheme` materialized by the transport |
| Persistence | five flat optional fields, non-atomic write that deleted other writers' keys | schema-versioned document, monotonic revision, atomic write, order-preserving merge |

A model name never identifies a route. Relays, regions, plans, multiple
accounts, and BYOK keys all produce different routes for the same visible model,
and all of them stay distinct.

## Domain model

```text
ProviderProfile           vendor identity, auth kinds, channels, hooks
└── ChannelDescriptor     endpoint / region / plan / account binding
    └── ModelOffer        the selectable route (protocol + request model id)
        └── RuntimeSelection   offer or policy + controls + scope
```

| Identity | Type | Meaning |
|---|---|---|
| `ProviderId` | `Slug` (value, ≤64 bytes) | stable metacodes id; aliases are configuration only |
| `ChannelId` | `Slug` | provider-owned route identity |
| `OfferId` | 128-bit digest, rendered `offer-<32 hex>` | derived from the normalized stable binding; never random, never a model name |
| `CanonicalModelId` | free-form string | logical upstream identity, for grouping and analytics |
| `RequestModelId` | free-form string | the exact bytes sent on the wire |
| `UpstreamModelId` | free-form string, optional | backend name; may be opaque or unknown |
| `CredentialRef` | `Slug` + typed metadata | stable across token refresh, contains no secret |

`OfferId` is a domain-separated SHA-256 over length-prefixed
`(provider_id, channel_id, protocol, endpoint_url, request_model_id,
credential_binding)`. Length prefixes matter: plain concatenation would make
`(provider "a-b", channel "c")` collide with `(provider "a", channel "b-c")`.
Metadata refreshes move `offer_revision`/`catalog_revision` and leave the id
alone, so a pinned selection stays reproducible.

Ids are fixed-size values rather than slices. A selection outlives the catalog
it came from, and a slice into a list that later grows is a dangling pointer.

## Adding a provider

1. Write `src/provider/profiles/<vendor>.zig` declaring a `ProviderProfile`.
2. Add one line to `BUILTIN_PROFILES` in `src/provider/registry.zig`.
3. If the vendor speaks its own dialect, write `src/api/dialects/<vendor>.zig`
   (see *Vendor integrations* below), add the vendor to `Vendor` in
   `src/provider/vendor.zig`, and declare it on the profile's routes.

A runtime source — the `custom_providers` section, a fetched catalog — registers
through the same call, and may **replace its own** registrations: re-reading a
configuration or refreshing a catalog is an ordinary thing to do twice, and a
registry that only ever appended made the second one fail. It may never take
over a built-in vendor's id, because letting a config file redefine `openai`
would change where an existing session's credentials go.

Replacement is validated and capacity-reserved before anything mutates, so a set
of profiles installs atomically: the registry never ends up holding profiles
that borrow an arena the same call is about to release.

Nothing in `AgentLoop`, the client factory, the TUI, or the Web UI changes. A
provider discovered at runtime (user-defined instance, plugin-supplied profile)
goes through the same `ProviderRegistry.register` call, including validation.

`transportKindFor(protocol)` is the single place a protocol becomes a concrete
client. It is keyed by protocol, not by vendor, which is what removes the
model-name guessing: a GLM model reached over `anthropic_messages` uses the
Anthropic transport, which is the opposite of what a name prefix would say.

## Vendor integrations: the code is the document

Each vendor's integration notes live in exactly one place: the header of its
dialect file, `src/api/dialects/<vendor>.zig`. There is no separate
integration document to drift from the code. Every header has the same
sections, in order — 接入点 (endpoints and the profile that declares them),
协议 (wires and auth), 思考与推理 (thinking parameters and the effort mapping),
回传与缓存 (reasoning passback and prompt caching), 已知差异 (quirks and known
gaps), 来源 (the vendor pages the facts were checked against, with dates) —
and `dialects/registry.zig` fails a test when one is missing.

| Vendor | Integration file | Built-in profile |
|---|---|---|
| OpenAI | `src/api/dialects/openai.zig` | `openai` |
| Anthropic Claude | `src/api/dialects/claude.zig` | `metask` (Claude models) |
| Google Gemini | `src/api/dialects/gemini.zig` | `gemini` |
| Zhipu GLM | `src/api/dialects/glm.zig` | `zai-coding-plan` |
| Moonshot Kimi | `src/api/dialects/kimi.zig` | `kimi` (open platform), `kimi-code` (Kimi Code subscription) |
| DeepSeek | `src/api/dialects/deepseek.zig` | `deepseek` |
| Alibaba Qwen | `src/api/dialects/qwen.zig` | `qwen` |
| MiniMax | `src/api/dialects/minimax.zig` | `minimax` |
| Mistral | `src/api/dialects/mistral.zig` | — |
| OpenRouter | `src/api/dialects/openrouter.zig` | `openrouter`, and catalogs |
| Amazon Bedrock (Converse wire) | `src/api/dialects/bedrock.zig` | `bedrock`, and catalogs |

The OpenAI chat building blocks every compatible vendor shares are
`src/api/dialects/openai_compat.zig`.

**Which dialect a request uses is a property of the route**, the way an
OpenRouter endpoint names its upstream. `ProtocolRoute.dialect` declares it for
a channel's route, `ModelEntry.dialect` overrides it for one model on a
multi-vendor gateway, and the offer carries both (`ModelOffer.dialect`, a
`vendor.Declaration`, not part of the offer id). It travels with the auth scheme
through the startup route, a `/model` switch, child agents, swarm teammates and
`AgentSession`, to the client's `declared_dialect`. The entry's declaration
covers its own model only: a child agent's `model_override`, a teammate or a
Session's model switch on another model of the same route inherits the route's
declaration alone, and with none infers from its own name, so a GLM child of a
Claude lead on the Metask gateway is still written in GLM's dialect. A route
that declares none infers the vendor
from the model name — the behaviour before routes could say — so a custom
provider written for that keeps working. A runtime plugin's dialect for a model
still wins over the route's declaration.

Reasoning passback is the dialect's decision too. `buildApiMessages` projects
the conversation's thinking blocks; a dialect that declares
`ModelProfile.echoes_reasoning_content` sends them back (DeepSeek, which
returns 400 without them once tools are present; Kimi, whose documentation
requires them with tool calls; MiniMax M3 and later, which ask for the full
response back; and OpenRouter), and every
other dialect leaves the request bytes exactly as before. Claude never receives
an unsigned thinking block. On Bedrock the stream hands each *signed* reasoning
block to the conversation as a provider-private `reasoning_item` (its Converse
JSON, verbatim, gated by model name), which the transcript and the AgentCore
checkpoint keep; the next request for the same model writes the same bytes
back at the head of their assistant message, so the signature survives a
resume and the cached prefix stays byte-identical.

## Amazon Bedrock

`bedrock_converse` is a wire of its own: Converse JSON requests, answered with
the AWS event-stream binary framing (`src/api/aws_event_stream.zig`, both CRCs
checked) instead of SSE. Like Gemini, the channel declares an origin and the
transport appends `/model/{modelId}/converse-stream`. The built-in `bedrock`
profile has one channel per region and authenticates with a Bedrock API key
(`AWS_BEARER_TOKEN_BEDROCK`, sent as a bearer); SigV4 is not implemented.
Each channel names the inference profiles its Region can call (Tokyo:
`jp.` for Sonnet 4.6, `global.` for Opus 4.6, which has no Japan profile).

The authoritative model list of an account is its catalog, ingested the way
OpenRouter's is: ListFoundationModels and ListInferenceProfiles documents
become one channel whose every usable model and cross-region inference profile
is an offer, each declaring its dialect from the catalog's `providerName`:

```json
"provider_catalogs": {
  "bedrock-us": {"kind": "bedrock", "region": "us-east-1",
                 "foundation_models_file": "…/foundation-models.json",
                 "inference_profiles_file": "…/inference-profiles.json"}
}
```

The documents are what
`GET https://bedrock.<region>.amazonaws.com/foundation-models` and
`GET https://bedrock.<region>.amazonaws.com/inference-profiles?type=SYSTEM_DEFINED&maxResults=1000`
return with the same API key as a bearer.

## Conservative metadata

Every optional field means *unknown*, and unknown never resolves in the
permissive direction:

- **Limits.** `context_window`, `max_input_tokens`, `max_output_tokens`, and
  `max_completion_tokens` stay distinct. `intersect` takes the tightest known
  bound per field and fails closed on incomparable token units.
- **Admission.** An unknown required limit is either an explicit conservative
  cap (flagged as such in the result) or a rejection — never "unlimited".
  Every built-in model now declares its documented limits; the fail-closed
  path is exercised by test profiles and by any model a user names that the
  profile does not declare.
- **Capabilities.** Tri-state. A channel may remove a canonical capability and
  may confirm one; `unknown` is only promoted by a provider declaration, and
  only `supported` permits emitting the wire feature.
- **Pricing.** `Quote` is a tagged union. A missing price is `unknown`, and any
  unknown component makes the whole cost unknown. There is no zero. Cached
  reads and cache writes are separately priced, because folding either into the
  fresh-input rate misreports the cost in one direction or the other.

  The `metask` profile's quote is derived from `util/pricing.zig` — the same
  table `UsageTotals.costUsd` already reports with — and a test asserts the two
  agree, so the picker cannot show a number `/cost` contradicts. It carries
  `estimated = true`: these are published rates, not a provider bill.

  `zai-coding-plan` stays `unknown` on purpose. The Coding Plan is a
  subscription, so a per-token list price is not what the user is billed;
  publishing one would be a fabricated price wearing the same type as a real
  one. A plan-aware quote needs the account's plan and remaining quota.
- **Provenance.** Every metadata group carries freshness (`known`/`inherited`/
  `stale`/`unknown`) and source (`builtin_profile`/`provider_catalog`/
  `user_config`/`observed`).

## GLM Coding Plan

```text
cn-anthropic      https://open.bigmodel.cn/api/anthropic        anthropic_messages   (default)
cn-openai         https://open.bigmodel.cn/api/coding/paas/v4   openai_chat
global-anthropic  https://api.z.ai/api/anthropic                anthropic_messages
global-openai     https://api.z.ai/api/coding/paas/v4           openai_chat
```

China is the default launch path; "global" is a channel, not a core switch. The
Anthropic wire is the default channel because it is this repository's
best-exercised transport.

The endpoint policy is the load-bearing part. A profile-level forbidden fragment
(`/api/paas/v4`) makes it impossible for a `--base-url` override to fall back to
the general Z.AI surface, and each route requires its own path marker so an
override cannot cross protocols either. Both checks run while the catalog is
built — before any request URL exists.

Coding Plan credentials are their own kind (`zai_coding_plan_api_key`), separate
from a general Z.AI key. `ZAI_API_KEY` is canonical; `GLM_API_KEY` and
`Z_AI_API_KEY` are accepted aliases. Two aliases holding *different* values is
an ambiguity error, not a silent first-wins pick. Zhipu offers no third-party
sign-in, so the profile declares the pages a plan key is created on instead,
and `metacodes login --provider zai-coding-plan`, `/login` and the picker walk
the user there and store the pasted key (*Stored API keys* below).

Error classification is provider-owned: `429` with quota wording is
`quota_exceeded` (not retryable) while plain throttling is `rate_limited`
(retryable); invalid key, wrong endpoint, and permission failures never retry as
transport errors.

## Kimi Code

```text
cn-responses      https://api.kimi.com/coding/v1   openai_responses   (default)
cn-chat           https://api.kimi.com/coding/v1   openai_chat
global-responses  https://api.kimi.ai/coding/v1    openai_responses
global-chat       https://api.kimi.ai/coding/v1    openai_chat
```

`kimi-code` is the coding quota of a Kimi membership, a different account
from the Moonshot open platform (`kimi`): Kimi says their keys and base URLs
are not interchangeable. Kimi documents one OpenAI-protocol base URL per host
for both wires; each wire is its own channel, because two routes on the
default channel would make `--model k3.1-pro` an ambiguity. Responses is the
default, the wire Kimi asks Responses-capable tools to use. Every route
requires `/coding/v1`, which no open-platform URL carries, so an override
cannot fall back to the pay-as-you-go platform.

Kimi Code keys are their own kind (`kimi_code_api_key`). `KIMI_CODE_API_KEY` is
canonical; `KIMI_API_KEY`, the name Kimi's guides give the subscription key, is
an alias, and the `kimi` profile reads `MOONSHOT_API_KEY` only. The
Anthropic-compatible surface (`https://api.kimi.com/coding/`) is not a channel
yet: Kimi does not document how a Messages request turns thinking on, and K3.1
Pro refuses a request with thinking off. K3.1 Pro and K3 declare 262,144
tokens, the window every plan that offers them gets; quotes stay `unknown`, as
for the GLM plan.

## Subscription plans

`ProviderProfile.subscription_plan` marks a coding plan billed by the month
rather than by the token: `kimi-code`, `zai-coding-plan` and `chatgpt-codex`
today, and a test in `provider/registry.zig` keeps a new one a deliberate
entry. The vendors
license these plans for a person working in a coding tool — Kimi Code's
community guidelines name personal, interactive use, and the GLM Coding
Plan's subscription agreement the tools Zhipu lists — so a start with nobody
at the keyboard (`-p`, `serve`, a resumed suspension, the REPL reading a pipe)
prints one `warning:` line on stderr saying so. It never refuses and never
changes the exit code: the terms are the vendor's to enforce. `--web` is a
person in a browser and a teammate answers to its lead's session; neither
prints it. A provider the user defines can say it is one too
(`"subscription_plan": true` in `custom_providers`, written by
`metacodes providers add --subscription-plan`): the coding plans of Alibaba
Cloud Model Studio and Volcano Engine Ark are reached that way, and their
terms limit the plan keys to interactive use in coding tools as well.

## User-Agent

Every request says what it is: `src/api/http_connection.zig`, which all of
`src/` sends through, sets `User-Agent: metacodes/<version>` unless the
caller names itself (the OTLP exporter keeps `metacodes-otlp`). Vendors
tell coding tools apart by this header, some refuse a client they do not
recognise, and their terms forbid a forged one; an honest name is the only
one a vendor can be asked to admit.

## ChatGPT (Codex)

```text
default   https://chatgpt.com/backend-api/codex   openai_responses   request profile chatgpt_codex
```

`chatgpt-codex` reaches a ChatGPT plan's Codex quota the way the Codex CLI
does. OpenAI documents no third-party use of it: the sign-in reuses the Codex
CLI's public client (`app_EMoamEEZ73f0CkXaXp7hrann`) and the requests go to
the backend the Codex CLI talks to, as OpenCode, pi and KWWK do. Its OAuth
sign-in is therefore declared `unofficial` (`ProviderProfile.oauth_support`),
which the sign-in says before it starts, and the provider is one route that
can stop working without touching any other.

The sign-in is the authorization code with PKCE at `auth.openai.com`, scope
`openid profile email offline_access`, with three parameters the profile
declares after the standard ones (`oauth_authorize_params`):
`id_token_add_organizations=true`, `codex_cli_simplified_flow=true` and
`originator=metacodes`. The client registered its redirect at
`http://localhost:1455` and `:1457` only (`oauth_redirect_host`,
`oauth_callback_ports`); Metask's own sign-in listens on the same two, so two
sign-ins cannot wait at once, and with both ports taken the sign-in stops and
names them. Nothing is sent to whatever holds them: unlike the Codex CLI, which
asks the holder to `/cancel`, a program here cannot know the holder is its
own. The ChatGPT workspace the grant is for is read from the ID token's
`https://api.openai.com/auth` claim, else from the access token
(`provider/chatgpt_claims.zig`), and stored with the sign-in as `account_id`;
the ID token is not kept. Signing out revokes the refresh token at
`auth.openai.com/oauth/revoke` (JSON, `oauth_revocation`) before the sign-in
is deleted.

What the backend wants beyond the Responses wire is the route's **request
profile** (`ProtocolRoute.request_profile`, `provider/request_profile.zig`):
`originator: metacodes`, `chatgpt-account-id`, `accept: text/event-stream`,
`include: ["reasoning.encrypted_content"]` (with `store:false`, the only
value the backend takes, the server keeps no reasoning between turns and
returns it encrypted only when asked) and `instructions` even when empty. A
request profile is a reviewed, named value rather than configuration, since it
decides which headers reach the network. It travels in the offer's dialect
declaration (`vendor.Declaration.request_profile`), so every client built on
the route carries it, subagents and teammates included, and it survives a
model override on the route. The workspace header is read from the access
token each request carries, so a refreshed token and its workspace always
travel together. The `openai` provider's routes declare no request profile and
send none of it.

A used-up plan answers 429 `usage_limit_reached` with `resets_at`, and a plan
without Codex 429 `usage_not_included` (`api/codex_usage.zig`). Neither is
retried; the failure line says when the plan resets, in the local zone and as
a wait, and the Run's failure detail carries the wait as `retry_after_ms`.

It is a subscription plan (`subscription_plan`, above): a `-p` or `serve`
start on it says so once on stderr.

The ten models are a static list, GPT-6.2 Sol first: a start that names no
model uses it. The backend lists what it serves at
`/models?client_version=<version>`, filtered by each model's minimum client
version; this client sends its own version, never the Codex CLI's, and on
2026-11-18 that list was empty for 0.12.1. A model the list lacks still goes
out under `--model <id>` or `/model use <id>`. Context windows are
OpenCode's figures for ChatGPT-plan requests (272k; 500k from GPT-6.1 on);
GPT-6.2's are the defaults OpenAI's model page gives for Codex (Sol 500k,
Astra 272k). Quotes are `unknown`: the plan is a monthly fee.

## Credential pools

A provider can have several credentials — separate accounts, separate plans —
declared by reference in `config.json`:

```json
"providers": {
  "openai": {"credentials": [
    {"id": "work", "env": "OPENAI_API_KEY_WORK", "kind": "api_key", "priority": 0},
    {"id": "personal", "env": "OPENAI_API_KEY_PERSONAL", "kind": "api_key", "priority": 1}
  ]}
}
```

**No secret is in the document.** The value lives in the named environment
variable; the document holds an id, a variable name, a kind, and a priority. A
literal `secret` key is rejected at parse time — `config.json` is read by
several tools and is not mode 0600.

A bound credential participates in the offer id, so *each account is its own
offer*. Two accounts on one route are two rows in the picker, each showing its
`account=`, and "switch to my work account" is a selectable route rather than an
invisible side effect of resolution. This is also why the picker needs no
separate credential stage: the accounts already are offers.

Because the offer names the credential, binding uses **that** member — not the
pool's highest-priority one. Resolving to a different account would make the
offer id identify a route the request does not take. A member whose variable
is unset leaves its route without a credential (`MissingCredentials`): not the
next member, not the provider's own variable, not a stored key.

A pool is one provider's. Each member carries the provider whose
`providers.<id>.credentials[]` declared it, and neither binding nor pool
selection offers it to another provider's route, whatever kind that
provider's profile accepts.

Selection among unbound members is deterministic: priority first, then id, so
configuration order cannot make a failover irreproducible. A member is skipped
when it is invalid, cooling down, expired, or empty. `noteFailure` maps a
provider-classified failure to the right state — a rate limit earns a cooldown,
an authentication failure marks the credential invalid, since retrying a key the
provider rejected only burns the account's error budget — and a transient
network failure changes nothing.

The pool is consulted *after* explicit, runtime-descriptor, environment-alias,
and single stored credentials, so an existing single-credential setup resolves
exactly as it did before the pool existed.

Failure state is **learned and durable**. `config_store.noteCredentialFailure`
records a cooldown or an invalidation through the same lock, revision, and
atomic-rename path as every other mutation, so the next process skips the
credential instead of rediscovering the same rate limit by hitting it. The class
is the provider's own classification — profiles already own `classify_error` —
because the difference between "slow down" and "this key is dead" is exactly the
difference between a cooldown and an invalidation. A transient network failure
records nothing; marking one would retire a working account.

## Aliases

A local alias is a name for a route — `fast`, `cheap`, `review` — and an
**explicit record**, never a string heuristic. Two policies, and the difference
between them is the whole point:

| Policy | Stores | Across a catalog refresh |
|---|---|---|
| `pinned` | offer id + revision | means the same route; reports an error when that offer is gone |
| `floating` | selector + last resolved offer + catalog revision | re-resolves, and records what it landed on |

A pinned alias that cannot resolve says so rather than resolving to a
neighbour — a pin that quietly moves is not a pin. A floating selector matching
several routes is an error listing the candidates, not a guess: choosing one
would silently pick a protocol, region, price, and credential the user never
named.

Either policy produces a *pinned* `RuntimeSelection`. The alias already decided
which route; leaving it auto would let a floating alias re-resolve inside the
kernel, mid-turn, against a catalog the user never saw.

`/alias` lists, `/alias pin <name>` names the route the session is on,
`/alias float <name> <model>` declares a re-resolving one, `/alias use <name>`
switches to it, and `/alias remove <name>` deletes it. A floating alias that
matches several routes reports which ones, so the answer is "pin one of these"
rather than "it did not work".

## Selection persistence

Scope decides *where* a committed selection is written, and the two files never
share a key:

| Scope | Written to | Restored by |
|---|---|---|
| `global` | `~/.metacodes/config.json` → `global_selection` | `applyPersistedGlobalSelection` at startup, before model-name inference |
| `session` | `<session_dir>/runtime-selection.json` → `session_selection` | `App.restoreSessionSelection` on `/resume` |
| `once` | nowhere | expires with the turn |

Named selections are kept beside them (#489): `presets` maps a name to a
selection in the `global_selection` shape, and `directory_presets` maps an
absolute directory to a preset name, never to a route. A start applies at most
one, chosen by `src/app/startup_order.zig` (`--preset`/`METACODES_PRESET`, then
the working directory's), by lowering it into the fields the flags naming the
same route would set (`src/app/presets.zig`); nothing is persisted by using
one. A preset written by hand is written back as it was by every other commit
(`config_doc.Preset.raw`).

Session scope is narrower, so on resume it wins: a resumed session continues on
the route it was using, not on whatever became global in the meantime. A stored
selection that no longer resolves is reported — as a startup error for global,
as a warning that leaves the current route alone for session — and never
silently replaced with a different vendor.

## Credentials

```text
CredentialRef { id, provider_id, kind, status, source, account_or_plan?, expires_at?, priority, cooldown_until, last_error }
```

Resolution is provider-scoped and deterministic: explicit reference → injected
runtime descriptor → profile-declared environment aliases → persisted store
(expiry aware) → interactive setup. `api_key_first`/`oauth_first` only reorders
the last two steps *within one provider*; it never widens scope.

A host may keep a layer below the process environment
(`ResolveInput.env_fallback`): the CLI's `<state root>/.env`
([LOCAL_CONFIG.md](LOCAL_CONFIG.md)). It is read for a provider's aliases only
when the process environment sets none of them, so an alias in the
environment and another in the file is never an ambiguity; two aliases with
different values inside the file still are. The pool's credential variables
and a catalog's `credential_env` are read from it when the environment leaves
them unset. AgentCore and every other embedder keep no such layer.

Because aliases are profile data, a Metask key is not reachable from an OpenAI
or Z.AI resolution at all. `--api-key` is the one key that arrives without a
kind or a provider, and every API-key profile would accept it — ahead of its
own environment key. It is therefore labelled with the provider the session
started on (Metask when none is named, otherwise the startup route's provider,
the scope startup resolved it in), and a `/model` commit offers it to that
provider only (`ScopedSecret` in `provider/runtime_binding.zig`). Picking
another provider's model uses that provider's own credential or is refused for
want of one; the previous route stays active. At startup, Metask (and any session that names no
provider) keeps the historical `core/auth.zig` path byte for byte — stored
OAuth, stored key, and the one-shot descriptor. Any other profile resolves in
its own scope, and the stored Metask model/effort selection is not applied to
it.

`AuthScheme` is materialized by the transport: `bearer` (default, identical to
the historical bytes), `api_key_header`, `custom_header`, and `signed_adapter`
(reviewed adapters, P2).

There is deliberately **no query-parameter placement**. A secret in a query
string lands in server access logs, proxy logs, and referrer headers, and it
would flow into the endpoint strings this subsystem already refuses to let carry
credentials — `EndpointPolicy` rejects a URL with userinfo for exactly that
reason. A provider that only accepts a query key is better served by a relay
that turns a header into one.

## OAuth

Metask's OAuth stays in `core/auth.zig`, byte for byte. `provider/oauth.zig` is
the same lifecycle for any profile that declares an OAuth credential kind and a
token endpoint — OpenAI and Codex first — kept inside the provider subsystem so
it is reachable from provider-scoped resolution and so a token for one vendor
can never satisfy another.

Three properties carry the design:

- **Single flight.** N turns discovering an expired access token at once perform
  *one* refresh. Without it, a rotated refresh token makes the losers of the
  race present a token the server has already invalidated, and the session dies
  with an authentication error that looks random. Waiters block on a condition
  and take the winner's result.
- **Rotated-refresh persistence is atomic, and happens first.** A provider that
  returns a new refresh token has already invalidated the old one, so the write
  (temp file + fsync + rename, 0600) completes *before* the new tokens become
  the live ones. The worst case is then a token saved but not yet in memory,
  which the next load recovers; the alternative — used but not saved — locks the
  user out permanently.
- **The refresh margin is generous.** A token that expires mid-flight fails the
  request it was attached to, so refresh triggers `REFRESH_MARGIN_SECONDS`
  before the server's expiry rather than at it.

`invalid_grant` is terminal: the user must log in again, and reporting it as a
transport failure would point a retry loop at an endpoint that can only keep
saying no.

The refresh runs at the **turn boundary**, not only at commit. A commit copies
the token that was valid then; a session that runs past its expiry would keep
presenting it and start failing with 401s that look like a broken key. Single
flight means concurrent turns still perform one exchange, and every borrower —
clients, subagent registry, swarm context — is repointed before the old bytes
are released, because a background request thread reads them. It renews the
credential of the route the clients are bound to (the last commit's, or the
one the session started on), and only when that route was bound with its
OAuth token: the kernel's effective selection can name another route (a
global or once pick under a session one), and a key or a pool account a route
was bound with stays. A transport's own refresh on a 401 `token_expired` is
dropped when the route moved while it ran.

The module performs no I/O. The token exchange is a caller-supplied function, so
every lifecycle test drives a fake exchange and none needs a network;
`src/api/oauth_exchange.zig` is the production half, one small auditable
`refresh_token` grant over HTTP.

### Obtaining the first token

The lifecycle above starts from a token that already exists. `metacodes login
--provider <id>` is how one is obtained (issue #33), and it runs in
`src/api/oauth_login.zig` — the kernel side, so a front end invokes a flow
rather than implementing one. Two grants, because one does not cover the field:

- **Loopback redirect + PKCE** is the default. A browser and a short-lived
  listening socket on the same machine is the normal desktop case, and PKCE is
  what keeps an observed redirect from being replayable.
- **Device code (RFC 8628)** is the flow for headless and SSH sessions, which
  have no browser to open and no loopback address an authorization server could
  redirect to. `authorization_pending` and `slow_down` are the normal course of
  such a flow; `access_denied` and `expired_token` end it.

Both end in the same durable import as `--oauth-token-json`, which stays
supported and is still the right path for CI and recovery. An interactive login
and an imported token response are therefore indistinguishable to everything
downstream.

A `custom_providers.<id>.oauth` block must be paired with an OAuth credential
kind in `credential_kinds` (`openai_oauth` or `openai_codex_oauth`). Credential
resolution opens the OAuth session only for those kinds, so a definition
without one describes a login that would be stored and never consulted; it is
rejected at parse time as `OAuthWithoutOAuthCredentialKind`, and both login
paths refuse such a provider before writing or opening a browser.

The **OAuth client is recorded with the login**, not re-derived at refresh time.
The refresh grant must present the same client the authorization grant was
issued to, so a client that lives only in configuration would break the login
the moment that configuration moved. A profile may declare one
(`oauth_client_id`); a configured provider declares it under
`custom_providers.<id>.oauth`; an installation declares the client it
registered for a built-in profile under `providers.<id>.oauth_client_id` in
`~/.metacodes/config.json` (#87), and `--client-id` supplies one for a single
login. Precedence is `--client-id`, then the configured client, then the
profile's declaration; whichever wins is the one recorded with the login.
Built-in profiles deliberately declare no client id: the client an
installation presents is registered by whoever runs it, and shipping a
guessed one would point every user's first exchange at a client that is not
theirs. That is the resolution of #87: the built-in `openai` profile stays
undeclared, the installation configures its own registration once, and
`/login openai` and `metacodes login --provider openai` then need no
`--client-id`. A metask-registered default, if
one is ever wanted, is a one-line profile constant behind the same precedence.

A profile that declares neither an authorization nor a device endpoint has no
interactive flow, and says so at the entry point instead of failing later at a
null URL.

What a profile can say about its browser sign-in, beyond the endpoints and the
client: the redirect host (`oauth_redirect_host`, `localhost` unless the
client registered `127.0.0.1`; the listener is on the IPv4 loopback either
way), the only ports the redirect may use (`oauth_callback_ports`, tried in
order, all taken an error that names them; empty keeps 1456, then 1457, then
any), parameters after the standard ones (`oauth_authorize_params`), where
signing out revokes the refresh token (`oauth_revocation`, JSON or form), and
how far the vendor stands behind the sign-in (`oauth_support`). A refusal that
comes back with the right state ends the wait and says what the server said;
one with another state is a stale tab and is answered and ignored.

A start reads a provider's stored sign-in below every key
(`main.providerSignInToken`), refreshing it first when it is at or past
expiry, so `--provider <id>`, `-p` and a stored `/model` default on that
provider run on it as a `/model` pick does. `metacodes logout --provider <id>`
and `/logout <provider>` remove it, revoked first where the profile declares an
endpoint (`api/oauth_revoke.zig`, bounded as Metask's revocation is).

### A key grant: OpenRouter's sign-in

OpenRouter signs a user in on its own site and hands back an API key of the
user's own account (https://openrouter.ai/docs/guides/overview/auth/oauth,
checked 2026-11-18). That is not OAuth as above — no client id, no token
endpoint, nothing to refresh, a JSON exchange — so a profile declares it as
`key_grant` (`provider/profile.zig`): the origin, the page, exchange, key
description and manage paths, and the label the key is given. The key it
hands back is stored as the profile's key setup kind, exactly as a pasted key
is, and resolves the same way (below).

`api/openrouter_login.zig` runs it two ways, on the `LoginWorker` like every
other sign-in (`provider_login.Flow.key_grant`):

- **The browser here.** The page address carries an S256 challenge, a state,
  the prefilled label, and a loopback callback on any free port — OpenRouter
  takes any, and names such a sign-in after it (`localhost:1456`). The callback
  is taken only with its own state; a refusal, which OpenRouter sends back
  without one, ends the wait at once (`CallbackServer.denied_body`) rather
  than leaving a tab that says "State mismatch".
- **Another device.** Without a callback the page shows the code, which the
  user pastes back here; the verifier never leaves this machine. This is the
  way over SSH, offered first there, and `--device-code` starts it: OpenRouter
  has no device-code grant, and this is what it documents for a machine with
  no browser.

`POST /api/v1/auth/keys` trades the code and the verifier; `GET /api/v1/key`
then describes the key (label, spending limit, expiry, free tier), and that
description is stored beside it (`api_key_store.Meta`, never a secret) for
`login status` and the sign-in's own line. Nothing here can delete the key on
OpenRouter — that takes a management key — so signing out removes it from this
machine and names the page its owner deletes it on (`<origin>/keys/<sha256
hex of the key>`), and a sign-in that replaces a key names the old one's page.

`METACODES_OPENROUTER_URL` (https, or plain http to a loopback host, read from
the process environment only) replaces the origin, and `Host.rebaseOrigin`
moves the profile's requests and key check onto it too: one variable moves
every address, so a test pointed at a mock cannot reach the real site. Moving
can only fail on a profile the check no longer admits, and then the process
stops rather than send anything where the variable was set to keep it from.

### Stored API keys and the guided key login

Some providers have a plan whose keys are created on a web page and offer no
grant a third-party client could run; the GLM Coding Plan is the first. Such a
profile declares `api_key_setup` (`provider/profile.zig`): the credential kind
the key is, the pages it is created on (`KeyPage { id, label, url, check_url,
check_wire, region }`), and a note shown before the user picks one. Validation
requires an accepted kind, at least one page and unique ids; a page's `url` must
be https, and so must its `check_url`, unless the profile's endpoint policy
admits it (plain http to a loopback host, or a definition that turned TLS off
for its own endpoint): the check carries the key, so it may go only where the
provider's requests do. The Coding Plan
declares four plan pages — China and Global, personal and team — and its note
says why the standard API-key page is the wrong one: since 2026-10-16 a key
from it bills the account balance even on the Coding Plan endpoints. The page
offered first follows the region of the chosen channel (`defaultKeyPage`).
Kimi Code (`kimi-code`, its own `kimi_code_api_key` kind) declares the Kimi
Code Console twice, China and Global, each checked on its own host's
`/coding/v1/models`; its note says a Moonshot open-platform key does not work
there.

Every other built-in vendor declares its key pages too, so `/login <id>` and
`login --provider <id>` reach all of them; a test in `provider/registry.zig`
holds every built-in profile but Metask to it. OpenAI (`platform.openai.com/
api-keys`) and Gemini (`aistudio.google.com/apikey`) have one page; Qwen
(the Model Studio console of Beijing and of Singapore), MiniMax
(`platform.minimax.cn` and `platform.minimax.io`) and the Moonshot open
platform (`platform.kimi.com` and `platform.kimi.ai`) have one per region,
each checked against its own region's `/models`, because their keys do not
cross regions. OpenAI also declares an OAuth grant but no client to present
with it (see above): until an installation configures one, both front ends
take a pasted key for it, as `/login` always did when `prepareFlow` refused.

The login is a `provider_login.Flow` variant (`ApiKeyPrepared`), so the CLI,
`/login` and the picker share it with the OAuth grants and run it on the same
`LoginWorker`. `prepareApiKey` trims what a paste adds around the key; `run`
checks the key with a GET of the page's `check_url` — the plan's
`/models` list, which answers 401 without a valid key and is not a model call
— and only then writes it. The GET carries the key the way the profile's
requests do (`ProviderProfile.auth`, through `catalog_fetch.Request.credential`):
Gemini reads `x-goog-api-key` and takes a bearer token for an OAuth token,
answering 401 whatever the key. A 401/403 is `KeyRefused`, and so is any
status the profile's `classify_error` reads as an invalid key or a denial:
Gemini answers a wrong key with 400 `INVALID_ARGUMENT`, reason
`API_KEY_INVALID` (a 400 for any other reason, an unsupported location say,
is not about the key). Any other failure is
`KeyCheckFailed`, and so is a 2xx that is not the provider answering — HTML
from a captive portal, or the `"success": false` body Z.AI answers some
failures with — and a redirect: a GET that carries a credential never follows
one (`catalog_fetch`), because std's client re-sends the header to whatever
host it names, and a host that never saw the key says nothing about it. In
every case nothing is written. `login --no-check` stores without the GET, for
a network that cannot reach it.

The key is written to `<state root>/keys/<provider>.json`
(`provider/api_key_store.zig`), 0600, through the same atomic writer as an
OAuth login, and never to `config.json`, which may only name environment
variables. The file is per provider, and so is the lookup: startup
(`resolveProviderScopedSecret`) and a picker commit (`bindCommittedSelection`)
load only the file of the provider being resolved, and pass it as
`stored_api_key`, after the profile's environment aliases. A key stored for
Z.AI therefore cannot authenticate any other provider. A file that does not
parse, carries an unknown schema or kind, or holds an empty key is an error
the user is told about, not a missing key. `metacodes logout --provider <id>`
removes it.

`METACODES_KEY_CHECK_URL` replaces every page's check URL — the local mock the
tests use, as `METASK_GATEWAY_URL` is for Metask. Only https or plain http to
an exact loopback host is accepted, because the check carries the key.

A provider the user defined (`custom_providers`, below) gets a key setup too,
built from its definition (`custom_provider.zig`, `pastedKeySetup`) whenever it
accepts an API key: one page with no `url` — whoever runs a relay or a server
hands its keys out, so there is nothing to open — labelled with its display
name, and a `check_url` that is the model listing of its default channel
(`provider/model_listing.zig`: `{base}/models`, `{root}/v1/models?limit=1000`
with `anthropic-version`, which `check_wire` asks for, or
`{root}/v1beta/models?pageSize=1000`). A `bedrock_converse` channel lists
nothing, so its key is stored unchecked, like the built-in Bedrock's. The CLI
then prompts `Paste the API key for <name>` without opening a page, `/login
<id>` goes straight to the paste, and the key file records no page. A key that
the endpoint cannot check (no listing) is stored with `--no-check`.

The two front ends differ only in how the key is typed. The CLI prompts for
the plan, prints the page whole, opens it, and reads the key with echo off;
echo goes off before the prompt is written, so a paste that arrives early is
not echoed by the terminal (`--api-key-stdin` and `--key-page` script it).
`/login` lists such a provider as "API key" and walks plan page → paste. Its
list shows twelve providers; the pane neither scrolls nor filters, so the
ones past them are named under the list by id (`N more not shown: /login
<provider> (…)`), and `/login <id>` starts any of them directly. Both
mask the key as a character count and draw the page URL whole so it can be
copied. The picker takes no key (#488): it does not list such a provider
until a key resolves for it.

## Controls

`ControlSpec` is provider-declared and versioned; the kernel owns no control
vocabulary. `reasoning_effort` and serving latency/priority are separate
controls — the kernel does not assume "fast" means less reasoning, or that a
reasoning enum is shared across vendors.

Changing model, protocol, region, plan, or offer revalidates every control.
Unsupported values are cleared or normalized according to the declared policy
(`reject`/`clamp`/`map`), never carried over. Identity and controls commit
atomically; a rejected combination leaves the old runtime active.

A control may declare its provider's default (`ControlSpec.default_value`):
the value the provider uses when a request names none. DeepSeek's
`reasoning_effort` declares `high`, as its API documents. The kernel
substitutes a declared default only under the `map` policy; the picker shows
it as the value a route starts at when the session wants no level, commits it
by name, and draws no separate `default` for that control. A level the
session runs with, `none` included, is still the one wanted.

Control values are bounded and copyable (8 controls, 48-byte ids, 192-byte
values) because a selection is persisted, snapshotted per turn, and compared
across revisions. Exceeding a bound is an error, not truncation.

## Routing

`RoutePolicy` separates route selection from model identity. Hard constraints
reject anything that cannot be *proved* to qualify — an unknown price under a
price ceiling, an unknown context window under a minimum, or a currency that
does not match the constraint's currency. Every numeric constraint carries its
units. `PinnedOffer` never falls back; fallback exists only through an explicit
`AutoRoute` policy, and each fallback preserves both requested and actual offer
identity in an `ActualRouteEvent`.

## Control plane

One kernel API serves the TUI, Web UI, CLI, and future clients:
`model.list`, `model.describe`, `selection.validate`, `selection.resolve`,
`selection.commit`, plus a replayable event journal. Clients never read provider
environment variables, probe endpoints, refresh tokens, instantiate provider
clients, infer identity from prefixes, or rewrite a request model id.

Scope is explicit: `once` applies to the next turn and expires, `session`
affects one session, `global` is durable after an explicit action. Each turn
snapshots the committed selection at its start, so a mid-stream commit affects
only the next turn. Mutations carry expected revisions; a stale write is a
structured conflict, never last-writer-wins. A commit the host cannot bind (no
credential for the route, say) is reverted: its scope holds what it held
before (`Kernel.revertCommit`), the journal records `runtime.switch_failed`
with `binding_failed`, and the session stays on the route it was on.

Event payloads are ids and enums only. There is deliberately no free-form string
field a prompt, token, or provider body could travel in. An evicted cursor is
reported as a gap rather than replayed incompletely, and `events.replay` copies
under the lock so a client never walks a ring that eviction is memmoving.

Producers exist today for `runtime.selection_changed`, `runtime.switch_failed`,
`route.actual`, `failover`, and `catalog.updated`. `pricing.updated`,
`auth.changed`, `credential.expiring`, and `provider.degraded` are declared with
their payload shapes but have no producer until the catalog refresh, credential
store, and health plane land — see the deferred list.

## Persistence

`~/.metacodes/config.json` gains `schema_version`, `config_revision`,
`providers`, `aliases`, `global_selection`, `presets`, `directory_presets`, and
`last_operation_id`. The
document is a provider *map*: several providers, accounts, regions, and relays
coexist, and disabling one preserves its configuration and credential reference.

Every commit takes the cross-process lock, re-reads the document, replays
idempotently when the operation id is among the retained recent keys (a bounded
ring, so a retry is still recognized after other commits have landed), rejects a
stale expected revision, applies the mutation, bumps the revision, and merges
only the keys the control plane owns — then writes a same-directory temporary
file, fsyncs it, renames it over the target, and fsyncs the parent directory.
Crash-injection tests cover both the pre-fsync and pre-rename points, and a
failed read is an error rather than an empty document: treating an I/O failure
as "no configuration" would truncate every other writer's data.

`config_store` is the sole authority for `config_revision`. The kernel mirrors
it through `adoptConfigRevision` and never invents one, so the number a client
receives from `model.list` is the number `selection.commit` compares against.
A `global` commit therefore reports `requires_persist`; the embedder writes it
and feeds the resulting revision back.

The order-preserving merge (`src/util/json_merge.zig`) also fixed a pre-existing
data-loss bug: `src/app/config.zig`'s writer serialized only its own five fields
and therefore deleted `theme`, `mcp_servers`, `permission_rules`, and
`model_tiers` on every theme change. It now merges, and refuses to overwrite a
document it cannot parse.

A newer `schema_version` is rejected rather than silently merged. A document
with no `schema_version` is legacy state and loads as an empty provider map.

## CLI

```sh
metacodes --provider zai-coding-plan --channel cn-anthropic --model glm-5.3
```

- `--provider <id|alias>` (or `METACODES_PROVIDER`) switches startup from
  model-name inference to registry route resolution.
- `--channel <id>` narrows to one endpoint/region/plan binding.
- `--offer <offer-id>` pins one exact reproducible route.
- `--preset <name>` (or `METACODES_PRESET`) applies a named selection from
  `config.json` `presets`; `--model`, `--channel` and `--reasoning-effort`
  replace one of its fields for that run, `--provider` and `--offer` set it
  aside ([LOCAL_CONFIG.md](LOCAL_CONFIG.md#presets)).
- `--base-url <url>` is validated against the profile and route policy first.
  Without `--channel` it belongs to one channel: the default channel when all
  its routes accept the URL, otherwise the first channel whose routes do. A URL
  no channel accepts is refused with the default channel's reason.

A model declared on several channels resolves on the profile's default channel,
the rule a bare `--provider` and an unlisted model follow too. Only a choice the
default channel cannot settle (the model on two wires there) is an error listing
the candidate offer ids. A model the profile does not declare still routes —
proxies legitimately accept private model names — with metadata left unknown.

The built-in inventories name the current frontier models with their documented
limits and reasoning controls (`reasoning_effort`, as the picker's reasoning
line shows): OpenAI `gpt-6-astra`, `gpt-6.1-sol`, `gpt-6-luna` on the Responses wire
only (tool calls need it there), Gemini `gemini-4-argon`, `gemini-3.8-flash`, and
the GLM Coding Plan's `glm-5.3`, `glm-5.3-flash`. Metask's inventory is the
gateway's own `/v1/models` whenever it answers.

Sessions that name no provider keep the historical path unchanged.

## User-defined providers

`custom_providers` in `~/.metacodes/config.json` defines provider instances that
go through the same `ProviderRegistry.register` call and the same validation as
a built-in profile, so nothing downstream can tell the difference. What differs
is ownership: a built-in profile is comptime data, while a configured one is
parsed into an arena that must outlive the registry borrowing its strings.

```json
"custom_providers": {
  "house-relay": {
    "display_name": "House relay",
    "aliases": ["relay"],
    "auth": {"kind": "custom_header", "header": "X-Relay-Token", "value_prefix": "Token "},
    "env_aliases": [{"name": "RELAY_TOKEN", "kind": "api_key", "canonical": true}],
    "endpoint_policy": {"required_path_fragments": ["/relay"]},
    "channels": [{
      "id": "primary", "base_url": "https://relay.example.com/relay/v1", "region": "eu",
      "protocol": {"wire": "openai_chat", "path_suffix": "/completions", "id": "relay_openai"},
      "dialect": "glm"
    }],
    "models": [{
      "request_model_id": "relay-glm-pro", "canonical_model_id": "zai/glm-4.6",
      "limits": {"context_window": 200000, "max_output_tokens": 128000},
      "capabilities": {"tools": "supported", "vision": "unsupported"},
      "price": {"currency": "EUR", "input": 2.5, "output": 9, "discount_basis_points": 9000},
      "controls": [{"id": "reasoning_effort", "kind": "enumeration", "values": ["low", "high"]}]
    }]
  }
}
```

**The schema is declarative and cannot execute anything.** There is no field for
code, a callback, a shell command, or a request template, and unknown keys are
ignored rather than interpreted. A hostile config can misroute the user's own
traffic — which the endpoint policy still constrains — but it cannot read
prompts or reach a credential it was not given. `quote_hook` and
`classify_error` stay at their defaults for configured providers; those are code
and belong to a reviewed profile.

`dialect` (on a channel, or on one model) names the vendor whose parameters the
requests carry — a value of `Vendor` in `src/provider/vendor.zig`. On a channel
it covers every model the channel serves; on a model, that model only. Absent, the
vendor is inferred from the model name; a value that names no vendor fails the
definition (`UnknownDialect`) rather than being guessed.

A protocol is a **wire**, optionally with a different request path. That is what
relays, gateways, and self-hosted servers actually differ by, and it keeps them
inside the schema: the wire selects the transport, the path suffix rides along
in the offer. A genuinely novel wire is rejected (`UnknownWire`) rather than
guessed — that case needs a reviewed adapter (P2).

`ModelOffer` carries the wire beside the protocol id for this reason. Re-parsing
the id would report "no transport" for a declarative protocol that has one.

Declared limits, capabilities, prices, and controls carry
`Provenance.source = user_config` and a price is marked `estimated`: a number
the user typed is a declaration, not a vendor observation, and must not read as
one. Everything else about it is ordinary — the picker, `model.list`,
`quote.estimate`, and token admission treat it exactly like a built-in offer.

The lifecycle is reachable through the control plane, not only by editing the
file: `/providers` lists routes, `/providers enable|disable <id>` toggles an
instance, and `/providers remove <id>` deletes its configuration. Disabling
preserves the instance's configuration and credential references — that is the
whole difference from removing it — and excludes it from the *catalog*, so
"disabled" is true in the picker, `model.list`, and `--provider` at once rather
than being re-checked at three call sites. For a provider defined in
`custom_providers`, removing takes the definition too (below): removing only
its `providers.<id>` left the definition in the file, and the provider came
back at the next start.

`metacodes providers add|probe|list|remove` (`src/app/providers_cli.zig`;
the user's guide is [PROVIDERS.md](PROVIDERS.md#a-model-api-of-your-own))
writes and reads the same section without hand-written JSON:

- `add <id> --base-url <url> --protocol <wire> [--protocol <wire>[=<url>]]…
  [--model <id>]… [--probe] [--display-name] [--dialect] [--key-env <VAR>]
  [--auth bearer|header:<name>[:<prefix>]] [--subscription-plan] [--replace]`
  renders the definition
  (`custom_provider.renderDraft`: what a person would write, and nothing
  more), one channel per wire with ids named after the wire (`openai`,
  `responses`, `anthropic`, `gemini`, `bedrock`), so adding a second protocol
  never renames the first channel and the offer ids derived from it. An
  Anthropic or Gemini base is stored without the `/v1` or `/v1beta` its
  transport appends (`model_listing.channelBase`). With no arguments at a
  terminal it asks for each part; without a terminal a missing part is an
  error. `--replace` patches an existing definition
  (`custom_provider.patchEntry`): only what it is given changes, and a model
  that stays keeps its object (price, limits, controls). The id never changes.
- The write is `config_store.putCustomProvider`: a `CommitRequest` with a
  `member_edits` entry (`json_merge.MemberField`, the one member
  `custom_providers.<id>`) under the same lock, re-read and atomic rename as
  every commit, and a `validate` hook that judges the complete document about
  to be written — inside the lock, so no other writer can change it in
  between. The CLI's hook runs the stages `--check-providers` runs
  (`adoptCustomProviders`, `ingestConfiguredCatalogs`,
  `applyProviderConfiguration`): the definitions must load after an `add`,
  and no stage that loaded before may stop loading. A refusal is
  `error.Rejected`, and nothing is written. Before it, the command refuses
  what it can name: an endpoint the default policy refuses (plain http to
  another host, userinfo, `%`-escapes), the id or alias of a built-in
  profile, a taken id without `--replace`, a `--key-env` another provider
  reads (a key there would go to both), and — with `--replace` — a new
  origin while `keys/<id>.json` holds a key stored for the old one (the old
  origins read from the definition as written, so one that does not load
  cannot skip the check).
- `probe <id> | --base-url <url> --protocol <wire>` asks the model listing
  (`api/model_probe.zig` over `catalog_fetch`, so a request that carries a
  key follows no redirect), with the key placed by the profile's auth
  scheme, and stores nothing. `add --probe` writes the limits a listing
  reports with each model it adds.
- `remove <id>` is `providers_cli.removeProvider`, which `/providers remove`
  calls for a defined provider too: one commit
  (`config_store.removeCustomProvider`) drops `custom_providers.<id>`,
  `providers.<id>` and a `global_selection` that resolved to it (only if it is
  still the selection the command resolved), then `keys/<id>.json` and
  `oauth/<id>.json` go.

The host reads `custom_providers` once, when it is created, so every one of
these applies from the next start, and each command says so; a running
session keeps listing a removed provider until then.

`metacodes --check-providers` is the dry run. It builds the provider runtime the
same way a session does — built-ins, `custom_providers`, configured catalogs,
the credential pool, the disabled set — so it cannot describe a different set of
routes than the one a session gets. It validates the configuration and prints
every route it produces — provider, channel, protocol, endpoint, wire
model id, context, price — and exits non-zero on a bad definition. No credential
is resolved and no request URL is built, which is exactly when a bad definition
should be explained. Validation itself happens at parse time: an endpoint the
provider's own policy forbids, a plaintext non-loopback host, a URL carrying
userinfo, a missing channel or model, an unknown auth scheme, or a price in an
unknown currency all fail before registration.

## Provider catalogs

### The built-in OpenRouter

The built-in `openrouter` profile is the router itself, the way Metask's
profile is its gateway: one channel, `auto`, whose requests carry no
`provider` object and leave the upstream to OpenRouter's default routing
(price, speed, uptime, with fallbacks; a conversation stays with an upstream
while its prompt cache is warm). That route is what a model offer of this
profile is. Which upstream answered is OpenRouter's to report; recording it
on the actual-route event is not implemented yet (see *Not implemented yet*).

Its models are the account's own listing, `GET /api/v1/models/user`, which
applies the account's provider preferences, privacy settings and guardrails.
`api/openrouter_catalog.zig` keeps the models that take tools over chat
completions, with the fields a route reads, and `Host.ingestOpenRouterBuiltin`
makes them one `auto` offer each, priced at the model's listed price (the
upstream OpenRouter picks may charge otherwise). The listing is fetched after
a sign-in or a pasted key, on `/providers refresh`, and in the REPL's
background when none is kept or it is a day old and a key is set; it is kept
in `<state root>/cache/models/`, and every start reads the kept copy whatever
its age, so a stored pin resolves without a request. Compiled in is only
OpenRouter's router model, `openrouter/auto`, so the provider is listed before
a sign-in and keeps a route if the listing cannot be fetched.

Pinning one upstream — an offer per endpoint, its request naming the
endpoint's tag in `provider.order` with `allow_fallbacks: false` — is the
catalog path below, not the built-in profile's.

### Catalog documents

`src/provider/openrouter.zig` adapts the OpenRouter shape, which is the one
worth adapting: it is a router, so it already separates the two things a
metadata source must keep separate.

- **Models** (`GET /models`) describe a canonical model — name, context length,
  declared pricing, supported parameters.
- **Endpoints** (`GET /models/{id}/endpoints`) describe the *routes* behind that
  model, one per upstream provider, each with its own context length, price,
  quantization, and status.

They are parsed separately and stay separate. A model with three endpoints
becomes three offers; merging them would reproduce exactly the "a model name
identifies the route" mistake this whole model corrects. An endpoint's channel
is named by its routing tag (`deepinfra/fp8` → `deepinfra-fp8`), which names
the same endpoint for every model it serves, so one channel holds them all;
two endpoints from one upstream provider (different quantizations, say) have
different tags and stay distinct. A request names the model by its id, never
by the endpoint's display `name`. OpenRouter prices its router models at
`"-1"` ("whatever the picked model costs"): that is an unknown price, not a
reason to refuse the listing.

Endpoint values win over model values, and only where the endpoint has one: an
endpoint that omits pricing inherits the model's declared price with
`inherited` provenance rather than becoming free, and one that omits a context
length inherits rather than becoming unlimited. An endpoint that never reported
a status has `unknown` health, which is not the same as having reported "fine".
A price string that is not a number is an error, not a zero.

Provider preferences compile into `RoutePolicy`. `only`/`ignore` and the numeric
ceilings become *hard* constraints; `order` and `sort` become preferences that
never reject — reading a preference as a constraint would silently drop routes
the user did not exclude. `allow_fallbacks` defaults the kernel's way (off),
because a selection that silently tries a second route is not the one the user
inspected. `PriceConstraint` carries per-direction ceilings, since a router's
price limit is per direction and folding both into one number is wrong in
whichever direction it rounds.

Router metadata folds into the `ActualRouteEvent` the kernel already derived —
usage, cost, latency, fallback attempts, status — and deliberately never
rewrites `requested`. What the user asked for is not something the router gets
to change after the fact. The upstream provider arrives as a channel slug, not a
string, because an event payload carries ids and enums only.

Catalogs are named by `provider_catalogs` in `config.json` and may be read from
disk (`models_file`, `endpoint_files`) or fetched (`models_url`,
`endpoint_urls`, with an optional `credential_env` for an authenticated
endpoint). `/providers refresh` performs the fetch. The parsing, offer
construction, and events are identical either way — the host cannot fetch,
because a transport dependency there would break the isolation gate, so
`api/catalog_fetch.zig` does the GET and hands the bytes in. A refresh that
fails leaves the previous catalog in place: a stale catalog is a far better
answer than an empty one, and every pin stays resolvable because offer ids are
derived from the stable binding.

Each ingest keeps its own arena until the host ends (`Host.catalog_arenas`).
One shared slot let an ingest for one provider free the strings behind
another provider's profile, which the rebuild inside that same ingest then
read; and a same-provider replace cannot free its predecessor either, because
the retired catalog and any picker snapshot taken before the swap still borrow
its model names.

Ingesting a catalog moves the catalog revision and emits `catalog.updated`,
`pricing.updated`, and — when an endpoint reports degraded or unavailable —
`provider.degraded`. `auth.changed` and `credential.expiring` have producers on
the kernel (`noteAuthChanged`, `noteCredentialExpiring`) for the credential
resolver to call. A pin survives an ingest: `OfferId` is derived from the stable
binding, so a rebuild reproduces it.

## TUI

`Ctrl+O` and `/model` open the same picker; transcript viewing moved to
`Ctrl+X Ctrl+O` (same letter, on the existing `Ctrl+X` prefix) with
`/transcript` as the documented equivalent. Both paths are covered by TTY
regressions, including the Kitty CSI-u forms, so the rebinding cannot leave
either action unreachable.

One screen, models first:

```text
  Model                                  apply to  [this session]  from now on  this turn   tab
  Metask · signed in · billed to your Metask account
  >* glm-5.3-flash                    200K
     glm-5.3                          200K   2 routes
  DeepSeek · key from .env · billed to your DeepSeek account
     DeepSeek V4 Pro                    1M   2 routes
  Reasoning effort   default  low  medium  [high]  max          ←/→
```

A row per model, grouped by *canonical id*, never by visible name: two
channels serving "GLM-4.6" over different protocols, regions, or prices are
different routes, and collapsing them by display name would hide the choice the
offer model exists to give. The providers are headings, the one in use first,
each saying where its credential comes from and who bills it; a typed filter
drops the headings and lists the matches flat, naming each one's provider. A
model served on several routes lists them under it, in words ("OpenAI Chat
API"), while the cursor is on it: Enter on the model takes its preferred route
(the one in use, else the first), Enter on a route takes that one. The
reasoning effort the focused route declares is a line under the list, changed
with ←/→ from any row; the level wanted is remembered, and each model shows and
commits the nearest one its vocabulary has. The level the session runs with,
`none` and `minimal` included, is the one wanted when the picker opens; with
nothing wanted, a route whose control declares its provider's default
(DeepSeek: `high`) starts at that value. A provider no commit could bind now
is not listed, and a filter does not find its models; when no provider is
listed, the list says so and points to `/login` and to this install's `.env`,
by its path.

The picker is modal for the keyboard and not for the session. Plain characters
are its filter, so the draft in the input box is untouched and a reply keeps
streaming; a commit during a reply changes the next turn, not the one in flight.
`Ctrl+C`/`Ctrl+D` deliberately pass through, so there is always an exit that does
not depend on the picker's own state machine. `q` closes only on an empty
filter, which keeps it typeable inside a model name.

Enter commits at the scope the header brackets. Session is the default, and
`Tab` cycles session → global → once, so any durable write is an explicit act
the user can see before pressing Enter. A successful commit closes the overlay
and prints one line into the transcript (`switched to glm-5.3 for this session
· reasoning high`) — a picker that vanishes without saying which of several
same-named routes it chose leaves the user unable to tell — and closing it
without one says what stays (`kept glm-5.3-flash · reasoning high`).

A committed route is broadcast on the existing UI event stream as a
`config_changed` → `route` event carrying provider, channel, protocol, wire
model id, offer id, credential *reference*, and scope. The model name alone
would not do: a visible name can come from several providers, channels,
protocols, and accounts, so a name-only broadcast announces a change an
out-of-process client cannot tell apart from another. The credential reference
travels; the secret never does.

`src/repl/model_picker.zig` holds the state machine, `model_picker_view.zig` the
drawing, and `picker_host.zig` performs the commit against the session.
`zig build test:picker` compiles the first two from a root that reaches the
provider kernel and the terminal theme and nothing else — the mirror of
`test:provider`, proving the picker stays a *client* of the control plane rather
than a second place identity is decided.

`/model use <id>` still works. It resolves against the offer catalog first, so a
model served by another provider or protocol switches in place; a name carried
by several routes is reported with their offer ids instead of guessed, and an
offer id is accepted verbatim. Names the catalog does not declare fall through
to the historical path, which still serves proxies and server-catalog models.

On the historical Metask API-key route — no provider named, or `metask` named
with an API key, and no Metask session login — the Metask offers are the ones
the session's own gateway lists. A key's gateway serves the models of that
key's group, which need not include any of the compiled profile's Claude
models, and `--base-url` may name another gateway entirely; the compiled
inventory at the default gateway therefore listed routes the session could not
use and none it could. `App.MetaskKeyRoute` records the route at startup, and
every `/v1/models` answer from that gateway — the startup probe (fetched, read
from the `/v1/models` cache, or refreshed in the background) and a `/models`
key switch — goes through one seam (`App.adoptMetaskKeyModels`) into
`Host.ingestMetask(..., .messages)`: one Messages offer per listed model at the
session's own endpoint, no Chat Completions offer (the session's transport is
Messages, the key was never shown to serve Chat, and two wires per model would
make `/model use <id>` ambiguous). The host stays lazy; it ingests the newest
document when it is built, and a document that arrives after that re-ingests at
once. The running model's offer on that endpoint is seeded as the session
selection, so the picker, `/providers`, and `/alias pin` see the current route.
A commit onto a Metask offer there binds the session's own key — picked in
`/models`, else the one the session started with, stored login included —
ahead of the environment, as every turn on that route already does. With no
answer from the gateway the compiled inventory stays. A Metask session login
ingests its authenticated gateway's catalog with both wires, as before.

`/login [<provider>] [--device-code] [--no-browser] [--client-id <client>]` is
the TUI's OAuth setup path (issue #33). Without a provider it opens a Login
pane listing every provider `provider_login.prepareFlow` accepts; with one it
starts that provider's sign-in. It is the kernel flow the CLI runs —
`api/provider_login.zig` decides whether a login can start and typed-refuses
when it cannot, `api/oauth_login.zig` runs the generic grant and
`api/metask_oauth.zig` Metask's own JSON device grant (`provider_login.Flow`)
— on a `LoginWorker` thread whose transcript (the URL to open, the code to
enter) the pane draws, and it ends in the same durable import, so a login made
here and one made from the shell are indistinguishable afterwards. Esc cancels
the sign-in and the pane closes at once; a worker still inside a request it
cannot abandon is parked on the App and joined once it settles. Without a
terminal, `/login <provider>` runs the flow blocking, with its instructions on
stderr. The loopback wait polls its socket (`platform/net.pollReadable`) and
checks an `AbortSignal` every 100 ms, and both device-code polls sleep in the
same slices, so every flow can be cancelled from another thread (#67).

The picker lists only routes a commit can apply as they are (#488). When it
opens, and whenever its catalog is refreshed, the host judges every offer by
the binding a commit runs (`App.judgeReadiness`): the same credential material
(`App.credentialSources`: the pool, the provider's stored key, for Metask the
session's own key or the `auth.json` sign-in, `--api-key`, the environment and
the `.env` layer below it) through `runtime_binding.bindOffer`, with one
difference — a stored OAuth login stands for the token a commit would refresh
first, so judging sends no request. The picker hides the offers that would
not bind (`Picker.setReadiness`), so a provider none of whose offers would is
not listed at all. A commit that still fails with `MissingCredentials` (the
credential went away after the picker opened) enters `Stage.setup`, which
shows the provider's `model_picker.Setup` — the variable its key is read
from, `/login` for Metask — with this install's `.env` and
`doc/LOCAL_CONFIG.md`, and takes no other key than Esc and `q`. The picker
never signs in or takes a key: the credential stage #67 put in it is gone,
and `/login <id>` is where both happen. A commit that moves the session to
another provider says, on a second line of its confirmation, who bills the
session from then on.

## Module map

| File | Responsibility |
|---|---|
| `src/provider/ids.zig` | `Slug`, `OfferId` derivation, revision counters |
| `src/provider/offer.zig` | `ModelOffer`, limits, tri-state capabilities, quotes, admission |
| `src/provider/controls.zig` | `ControlSpec`, values, validation, revalidation |
| `src/provider/credential.zig` | typed credentials, provider-scoped resolution, auth materialization |
| `src/provider/profile.zig` | `ProviderProfile`, `ChannelDescriptor`, protocols, endpoint policy |
| `src/provider/profiles/*.zig` | one file per built-in provider |
| `src/provider/registry.zig` | the extension point + offer catalog |
| `src/provider/selection.zig` | `RuntimeSelection`, `RoutePolicy`, resolution, legacy migration |
| `src/provider/alias.zig` | pinned/floating alias resolution |
| `src/app/route_strings.zig` | one-generation retention of the live route's strings |
| `src/provider/config_doc.zig` | versioned document model and serialization |
| `src/provider/config_store.zig` | atomic, revisioned, idempotent writer |
| `src/provider/control_plane.zig` | UI-independent kernel API and event journal |
| `src/provider/runtime_binding.zig` | selection → transport parameters |
| `src/provider/startup.zig` | CLI/bootstrap route resolution |
| `src/provider/host.zig` | process-lifetime registry + catalog + kernel |
| `src/provider/custom_provider.zig` | `custom_providers` schema, validation, materialization; rendering and patching a definition |
| `src/provider/model_listing.zig` | where each wire lists its models, and reading the answer (no I/O) |
| `src/api/model_probe.zig` | the model-listing GET (`providers probe`, `add --probe`) |
| `src/app/providers_cli.zig` | `metacodes providers` (`add`, `probe`, `list`, `remove`); the removal `/providers remove` shares |
| `src/provider/openrouter.zig` | model/endpoint catalogs, router entries, preferences → `RoutePolicy`, router metadata |
| `src/provider/profiles/openrouter.zig` | the built-in OpenRouter: the `auto` router channel, the key grant, the key page |
| `src/api/openrouter_login.zig` | OpenRouter's key grant: browser and other-device ways, the exchange, the key description, the manage page |
| `src/api/openrouter_catalog.zig` | the account's listing for the built-in OpenRouter: trimmed, kept, refreshed in the background |
| `src/provider/bedrock_catalog.zig` | Bedrock foundation-model and inference-profile catalogs → a region's channel |
| `src/provider/vendor.zig` | `Vendor`, the dialect a route declares |
| `src/provider/request_profile.zig` | `RequestProfile`, what one endpoint requires of every request on a route |
| `src/provider/chatgpt_claims.zig` | the ChatGPT workspace inside OpenAI's OAuth tokens |
| `src/api/dialects/<vendor>.zig` | one vendor's dialect; its header is the integration document |
| `src/api/dialects/registry.zig` | vendor → dialect file, name inference, the header contract test |
| `src/api/bedrock_client.zig` | Bedrock Converse transport |
| `src/api/aws_event_stream.zig` | AWS event-stream framing (decode, CRC checks) |
| `src/provider/oauth.zig` | provider-scoped OAuth lifecycle (no I/O) |
| `src/provider/api_key_store.zig` | provider-scoped API keys at rest, one 0600 file per provider |
| `src/api/oauth_exchange.zig` | the `refresh_token` grant over HTTP |
| `src/api/oauth_login.zig` | the interactive first-token grants (PKCE, device) |
| `src/api/oauth_revoke.zig` | signing out of a provider's sign-in: revoke the refresh token, then delete |
| `src/api/codex_usage.zig` | the Codex backend's usage refusals and their wording |
| `src/api/provider_login.zig` | the login entry both the CLI and `/login` call: typed refusals, then grant + durable import (#33), or the checked pasted key |
| `src/api/login_worker.zig` | a prepared login on a worker thread: `AbortSignal` cancellation, bounded `Notify` transcript, atomic state (#67) |
| `src/api/catalog_fetch.zig` | catalog GET, bounded and status-classified |
| `src/repl/model_picker.zig` | picker state machine (pure) |
| `src/repl/model_picker_view.zig` | picker rendering |
| `src/repl/picker_host.zig` | commit + rebind against the session |
| `src/api/auth_header.zig` | transport-side auth materialization |
| `src/util/json_merge.zig` | order-preserving JSON object merge |
| `src/util/json.zig` | canonical JSON string escaping and UTF-8 repair |

`zig build test:provider` compiles the subsystem from a narrow root, proving it
builds standalone. It does **not** enforce the import boundary — that root sits
at `src/`, so every file below it is importable, and adding `src/client.zig`
compiles cleanly. `zig build test` runs it and `test:picker`.

`zig build subsystem:boundary` enforces the rule where the rule lives, in the
source: every `@import` in `src/provider/**` must resolve inside the subsystem,
to one of seven named leaf files or the five files they reach, or to
`std`/`builtin`/`platform`; the picker's two files may reach the provider kernel
and the terminal theme and nothing else. The rule covers the closure, not just
the first hop: each file a subsystem reaches is held to the same lists, test
blocks included, because an isolation root compiles every test in every file it
reaches. A file of the other subsystem is entered but not followed, since its
own entry checks it. Imports are resolved against the importing file, so
`../ids.zig` from a profile and `ids.zig` from the kernel are checked as the one
path they name — and the gate is verified to reject `../client.zig` from the
kernel, `../../client.zig` from a profile, `../app.zig` and `loop.zig` from the
picker, a test in `api/model_name.zig` that imports the system prompt, and
`types.zig` importing `core/stall_gate.zig`. The first-hop version of this
check missed the last two, and both isolation roots came to compile the whole
application.

## Not implemented yet

Listed rather than left silent. Each is a decision with a reason, not an
omission — and none of them is an acceptance criterion of the issue.

- **`chatgpt-codex`'s device-code sign-in, usage headers and compressed
  bodies.** The Codex CLI has its own JSON device-code flow for SSH sessions
  (`/api/accounts/deviceauth/*`), not RFC 8628, which is not written. The
  backend's `x-codex-*` headers (used percent, reset time) are not read, and
  request bodies are not zstd-compressed, which the backend wants above about
  1 MiB. The model list is static, and a 401 is not answered with one refresh
  and a replay as Metask's gateway is.

- **Bedrock SigV4 and AWS profiles.** The Bedrock transport authenticates with
  a Bedrock API key only; access keys, session tokens and `~/.aws` profiles
  need request signing, which is not written.
- **Bedrock over the AgentCore C ABI and to sealed Skills.** ABI v1 has no
  provider code for Bedrock (adding one is an ABI revision), and SSP/1's
  `provider.kind` has no Bedrock value, so a Bedrock session cannot delegate
  to a sealed Skill gateway: the client refuses it as an undelegable route
  and the gateway refuses the kind (`doc/SEALED_SKILL_PROTOCOL.md` §3.4).
- **Thinking fields for non-Claude models on Bedrock.** DeepSeek, Qwen, Kimi
  and MiniMax on Bedrock think by their own defaults; only Claude and gpt-oss
  get fields in `additionalModelRequestFields`.

- **Defined providers while a session runs.** The host reads
  `custom_providers` once, when it starts; `metacodes providers` changes apply
  from the next start, and `/providers refresh` re-reads only
  `provider_catalogs`. Re-adopting definitions live would free strings a
  running route may still borrow.

- **Reviewed protocol extensions (P2).** A genuinely novel wire format needs a
  signed adapter reference, which needs review and signing infrastructure. The
  declarative schema covers relays, gateways, and self-hosted servers, which
  differ by path rather than by wire; anything else is rejected (`UnknownWire`)
  rather than guessed.

- **The upstream OpenRouter picked, on the actual-route event.** Its answers
  name the upstream (`provider`), and `openrouter.parseRouterMetadata` reads
  it, but no production path records an actual route for any provider yet
  (`Kernel.recordActualRoute` has no caller outside tests), and the event has
  no field for an upstream. Recording it needs both, and belongs with pinning
  an upstream from `/model` (an offer per endpoint of the built-in profile,
  fetched for one model when asked): neither is built.

- **Per-offer capacity.** Throughput stays `unknown`: OpenRouter's endpoint rows
  do not carry it, so `hard_min_throughput_tps` can only ever reject. Latency is
  in the same position until a health plane observes it.
- **Catalog- and config-sourced prices (P1).** The `metask` profile ships a
  real quote (see *Pricing*), so `model.list` and `quote.estimate` return known
  prices for it. `openai` and `gemini` stay `unknown` until a provider catalog
  or user config supplies rates; `zai-coding-plan` stays `unknown` by design.
- **Auth scheme over the AgentCore C ABI.** `App`, background subagent jobs,
  swarm teammates, and `AgentSession` all carry the resolved route's auth
  scheme. `AgentSession.Config` accepts it, but `agentcore/abi_v1.zig` does not
  expose it, so a C embedder still gets the default bearer — adding it is an ABI
  revision, not a wiring fix.
