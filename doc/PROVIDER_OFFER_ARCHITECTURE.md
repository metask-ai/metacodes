# Provider profiles, model offers, and the runtime control plane

Status: delivery slice **P0 shipped**, plus the Z.AI GLM Coding Plan provider
from P1. Issue: `metask-ai/metacodes#16`.

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
  unknown component makes the whole cost unknown. There is no zero.
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
the historical bytes), `api_key_header`, `custom_header`, `api_key_query`
(rejected by the current transports rather than silently dropped), and
`signed_adapter` (reviewed adapters, P2).

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
| `src/provider/config_doc.zig` | versioned document model and serialization |
| `src/provider/config_store.zig` | atomic, revisioned, idempotent writer |
| `src/provider/control_plane.zig` | UI-independent kernel API and event journal |
| `src/provider/runtime_binding.zig` | selection → transport parameters |
| `src/provider/startup.zig` | CLI/bootstrap route resolution |
| `src/api/auth_header.zig` | transport-side auth materialization |
| `src/util/json_merge.zig` | order-preserving JSON object merge |

`zig build test:provider` compiles the subsystem from a root that reaches only
`std`, `types.zig`, `util/model.zig`, and the portable `platform` layer
(sync/fs). If a provider module ever grows a dependency on the transport, the
TUI, or a UI protocol, that step stops compiling.

## Not implemented yet

Listed rather than left silent. Each is a later delivery slice from the issue.

- **OAuth lifecycle for OpenAI/Codex (P1).** The profile declares the accepted
  kinds and the transport auth shape; the device/PKCE flow, single-flight
  refresh, and rotated-refresh-token persistence are not implemented. Only
  Metask OAuth works today, on its historical path.
- **Provider catalog refresh and health hooks (P1).** Offers come from compiled
  profile data. There is no `GET /models` ingestion, no per-offer health or
  capacity observation, and no OpenRouter model/endpoint adapter. The data model
  carries these fields and `adoptCatalog` can swap in a refreshed catalog, but
  nothing produces one yet, so health and capacity read `unknown`. The
  `pricing.updated`, `auth.changed`, `credential.expiring`, and
  `provider.degraded` event types wait on the same work.
- **Built-in price tables (P1).** `ProviderProfile.quote_hook` and
  `ModelEntry.quote` are wired end to end — the hook is reached through
  `quote.estimate` and the static quote through `model.list` — but no built-in
  profile ships a price table, so built-in quotes read `unknown` until a
  provider catalog or user config supplies one.
- **User-defined providers (P1).** A profile can be registered at runtime
  through the same extension point, but there is no `CustomProviderDefinition`
  config schema, no `DeclarativeProtocolSpec`, and no dry-run/connection test.
- **TUI picker migration (P1).** `/model`, `/models`, and the `Ctrl+O`
  rebinding are unchanged. The control-plane API they should call exists and is
  tested; the TUI does not call it yet.
- **Auth scheme inheritance beyond `AgentJobRegistry`.** `App`'s own clients and
  background subagent jobs carry the resolved route's auth scheme. Swarm
  teammates and `AgentCore` sessions still construct providers with the default
  bearer scheme; they are unaffected today because every built-in profile except
  Gemini uses bearer, and the Gemini transport fixes its own header.
- **`api_key_query` placement.** Rejected by both transports rather than
  silently dropped; it needs URL rewriting in the request path.
- **Session-scoped `runtime-selection.json`.** The document, the store
  (`Store.initSessionFile`), and the isolation between the session file and
  `config.json` exist and are tested, but no session host writes one yet — the
  TUI picker migration is what will. The *global* selection is loaded at boot:
  `applyPersistedGlobalSelection` reads `Store.initHome` before model-name
  inference runs, and a stored pin the catalog no longer offers is a startup
  error rather than a silent fallback to another vendor.
- **Credential pool rotation (P2).** `CredentialRef` carries priority, cooldown,
  and last-error, and resolution honours cooldown and invalid status, but only
  one credential per provider is offered to it.
- **TinyKG audit plane.** No decision/verification nodes are appended.
