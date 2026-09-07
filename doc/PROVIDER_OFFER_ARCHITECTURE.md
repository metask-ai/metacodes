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

## Conservative metadata

Every optional field means *unknown*, and unknown never resolves in the
permissive direction:

- **Limits.** `context_window`, `max_input_tokens`, `max_output_tokens`, and
  `max_completion_tokens` stay distinct. `intersect` takes the tightest known
  bound per field and fails closed on incomparable token units.
- **Admission.** An unknown required limit is either an explicit conservative
  cap (flagged as such in the result) or a rejection — never "unlimited".
  `glm-4.5-air` ships with unknown limits on purpose so a built-in profile
  exercises that path.
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
an ambiguity error, not a silent first-wins pick.

Error classification is provider-owned: `429` with quota wording is
`quota_exceeded` (not retryable) while plain throttling is `rate_limited`
(retryable); invalid key, wrong endpoint, and permission failures never retry as
transport errors.

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
offer id identify a route the request does not take.

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

Because aliases are profile data, a Metask key is not reachable from an OpenAI
or Z.AI resolution at all. At startup, Metask (and any session that names no
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
are released, because a background request thread reads them.

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
`/login openai`, `metacodes login --provider openai` and the picker's
credential stage then need no `--client-id`. A metask-registered default, if
one is ever wanted, is a one-line profile constant behind the same precedence.

A profile that declares neither an authorization nor a device endpoint has no
interactive flow, and says so at the entry point instead of failing later at a
null URL.

## Controls

`ControlSpec` is provider-declared and versioned; the kernel owns no control
vocabulary. `reasoning_effort` and serving latency/priority are separate
controls — the kernel does not assume "fast" means less reasoning, or that a
reasoning enum is shared across vendors.

Changing model, protocol, region, plan, or offer revalidates every control.
Unsupported values are cleared or normalized according to the declared policy
(`reject`/`clamp`/`map`), never carried over. Identity and controls commit
atomically; a rejected combination leaves the old runtime active.

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
structured conflict, never last-writer-wins.

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
`providers`, `aliases`, `global_selection`, and `last_operation_id`. The
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
metacodes --provider zai-coding-plan --channel cn-anthropic --model glm-4.6
```

- `--provider <id|alias>` (or `METACODES_PROVIDER`) switches startup from
  model-name inference to registry route resolution.
- `--channel <id>` narrows to one endpoint/region/plan binding.
- `--offer <offer-id>` pins one exact reproducible route.
- `--base-url <url>` is validated against the profile and route policy first.

A model that matches several routes is an error listing the candidate offer ids,
not a guess. A model the profile does not declare still routes — proxies
legitimately accept private model names — with metadata left unknown.

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
      "protocol": {"wire": "openai_chat", "path_suffix": "/completions", "id": "relay_openai"}
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
than being re-checked at three call sites.

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
identifies the route" mistake this whole model corrects. Two endpoints from one
upstream provider (different quantizations, say) get distinct channel slugs, so
neither disappears.

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

```text
Provider → Canonical model → Channel/Offer (optional) → Options (optional) → Commit
```

The channel step is skipped when a canonical model has exactly one offer, and
the options step when the offer declares no controls. Offers are grouped by
*canonical id*, never by visible name: two channels serving "GLM-4.6" over
different protocols, regions, or prices are different routes, and collapsing
them by display name would hide the choice the offer model exists to give.

The picker is modal for the keyboard and not for the session. Plain characters
are its filter, so the draft in the input box is untouched and a reply keeps
streaming; a commit during a reply changes the next turn, not the one in flight.
`Ctrl+C`/`Ctrl+D` deliberately pass through, so there is always an exit that does
not depend on the picker's own state machine. `q` closes only on an empty
filter, which keeps it typeable inside a model name.

Enter commits at the scope the footer names. Session is the default, and `Tab`
cycles session → global → once, so any durable write is an explicit act the user
can see before pressing Enter. A successful commit closes the overlay and prints
one line into the transcript — a picker that vanishes without saying which of
several same-named routes it chose leaves the user unable to tell.

A committed route is broadcast on the existing UI event stream as a
`config_changed` → `route` event carrying provider, channel, protocol, wire
model id, offer id, credential *reference*, and scope. The model name alone
would not do: a visible name can come from several providers, channels,
protocols, and accounts, so a name-only broadcast announces a change an
out-of-process client cannot tell apart from another. The credential reference
travels; the secret never does.

`src/repl/model_picker.zig` holds the state machine, `model_picker_view.zig` the
drawing, and `picker_host.zig` performs the commit against the session.
`zig build test:picker` compiles all three from a root that reaches the provider
kernel and the terminal theme and nothing else — the mirror of `test:provider`,
proving the picker stays a *client* of the control plane rather than a second
place identity is decided.

`/model use <id>` still works. It resolves against the offer catalog first, so a
model served by another provider or protocol switches in place; a name carried
by several routes is reported with their offer ids instead of guessed, and an
offer id is accepted verbatim. Names the catalog does not declare fall through
to the historical path, which still serves proxies and server-catalog models.

`/login <provider> [--device-code] [--no-browser] [--client-id <client>]` is
the TUI's OAuth setup path (issue #33). It is the kernel flow the CLI runs —
`api/provider_login.zig` decides whether a login can start and typed-refuses
when it cannot, `api/oauth_login.zig` runs the grant — with the REPL's
transcript as the notify sink, and it ends in the same durable import, so a
login made here and one made from the shell are indistinguishable afterwards.
`/login` blocks the REPL until the flow completes, as `metacodes login` blocks
the terminal; Metask keeps its own JSON device grant on the CLI. The loopback
wait polls its socket (`platform/net.pollReadable`) and checks an
`AbortSignal` every 100 ms, and the device-code poll sleeps in the same
slices, so either flow can be cancelled from another thread (#67).

The picker has a credential stage (#67). A commit that fails with
`MissingCredentials` on an OAuth-capable provider does not leave the overlay:
`picker_host` prepares the same kernel login (`prepareProfile`, so every
refusal — no token endpoint, no client id — is the typed one `/login` gives)
and runs it on a worker thread (`api/login_worker.zig`), whose `Notify` sink is
a bounded buffer the picker draws in place of the route list: the URL to
open, or the device code. The TUI's 100 ms input tick polls the worker; `Esc`
aborts the flow through the signal and returns to the stage the user came
from; a landed login refreshes the catalog and retries the pending commit, so
the route the user chose is the one that becomes active. The state machine
stays pure (`Stage.credential`, `Outcome.login` / `Outcome.cancel_login`); the
thread, the network and `App` live in the host and the worker.

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
| `src/provider/custom_provider.zig` | `custom_providers` schema, validation, materialization |
| `src/provider/openrouter.zig` | model/endpoint catalogs, preferences → `RoutePolicy`, router metadata |
| `src/provider/oauth.zig` | provider-scoped OAuth lifecycle (no I/O) |
| `src/api/oauth_exchange.zig` | the `refresh_token` grant over HTTP |
| `src/api/oauth_login.zig` | the interactive first-token grants (PKCE, device) |
| `src/api/provider_login.zig` | the login entry both the CLI and `/login` call: typed refusals, then grant + durable import (#33) |
| `src/api/login_worker.zig` | a prepared login on a worker thread: `AbortSignal` cancellation, bounded `Notify` transcript, atomic state (#67) |
| `src/api/catalog_fetch.zig` | catalog GET, bounded and status-classified |
| `src/repl/model_picker.zig` | picker state machine (pure) |
| `src/repl/model_picker_view.zig` | picker rendering |
| `src/repl/picker_host.zig` | commit + rebind against the session |
| `src/api/auth_header.zig` | transport-side auth materialization |
| `src/util/json_merge.zig` | order-preserving JSON object merge |

`zig build test:provider` compiles the subsystem from a narrow root, proving it
builds standalone. It does **not** enforce the import boundary — that root sits
at `src/`, so every file below it is importable, and adding `src/client.zig`
compiles cleanly.

`zig build subsystem:boundary` enforces the rule where the rule lives, in the
source: every `@import` in `src/provider/**` must resolve inside the subsystem,
to one of six named leaf files, or to `std`/`builtin`/`platform`; the picker's
two files may reach the provider kernel and the terminal theme and nothing else.
Imports are resolved against the importing file, so `../ids.zig` from a profile
and `ids.zig` from the kernel are checked as the one path they name — and the
gate is verified to reject `../client.zig` from the kernel, `../../client.zig`
from a profile, and `../app.zig` from the picker.

## Not implemented yet

Listed rather than left silent. Each is a decision with a reason, not an
omission — and none of them is an acceptance criterion of the issue.

- **Reviewed protocol extensions (P2).** A genuinely novel wire format needs a
  signed adapter reference, which needs review and signing infrastructure. The
  declarative schema covers relays, gateways, and self-hosted servers, which
  differ by path rather than by wire; anything else is rejected (`UnknownWire`)
  rather than guessed.

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
