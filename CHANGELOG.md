# Changelog

The standalone repository is versioned per `build.zig.zon`; the first tagged
release is `0.1.0` (2026-08-29). Entries titled **"Historical —"** were
imported from the pre-extraction `cc-zig` line — their version numbers and
dates are historical labels, not release promises of this repository. Current
status, compatibility boundaries, and entry points are defined by
[README](README.md), [ROADMAP](ROADMAP.md), [doc/API.md](doc/API.md), and
[OPEN_SOURCE_READINESS.md](OPEN_SOURCE_READINESS.md).

## Unreleased

### Added

- The provider-offer capability vocabulary's comptime coverage guard now binds
  the real runtime capability enum instead of a hand-copied duplicate, so the
  next runtime capability added without an offer mapping is a compile error
  rather than a silent gap.

### Changed

- MCP tool results decide inline-vs-publish from the caller's
  `result_budget.Budget.per_result_bytes` on both MCP paths — the classic
  `McpClient` and the AgentCore `mcp_result_stream` projector — the same number
  the native tools have used since #41, instead of private 64KB / 1MB constants
  that only coincided with it (issue #43). `McpClient.callToolBodyAbortable` /
  `listResourcesBodyAbortable` / `readResourceBodyAbortable`,
  `mcp_result_stream.project` and `mcp_runtime.Client.callToolBody` take that
  budget as a required parameter; embedders pass `ctx.result_budget` verbatim.
  This is a breaking signature change for library consumers.

### Removed

- First-class PDF document input is withdrawn (issue #25). Agent Core carries
  cross-format, cross-provider, cross-host input modalities; parsing a
  container format, judging its pages, encryption and structure, and
  attributing budget from that judgement are not Core's job — and a lexical
  scan could not answer those questions correctly anyway, which is how it
  produced three ways to reject a valid document. Removed: the `document`
  block and its neutral IR, `core/pdf.zig`, `supports_pdf_input` /
  `Capability.pdf_input`, the dialect document serializer, transcript and
  checkpoint persistence, `RUN_INPUT_PART_DOCUMENT`, and the headless `--pdf`
  flag. The `Read` tool description stays corrected: it still does not claim
  PDF reading or a `pages` parameter.
  Compatibility: a transcript or checkpoint recorded with a document block is
  refused explicitly rather than partially read — the transcript loader is now
  atomic and reports a dedicated error with an actionable message, and the
  checkpoint decoder reports `UNSUPPORTED` (not `CORRUPT`) for an intact
  checkpoint carrying the permanently reserved block tag `7`, and only after
  its digest has been verified. While the observation channel stays usable, the
  terminal `run_state` snapshot is published exactly once from the Run's final
  result: a post-admission cleanup failure closes it as `poisoned`, an abort accepted from
  the `finalizing` callback is reflected as `aborted` (it used to leave a
  `completed` snapshot beside `STOP_ABORTED`), Runs that never ran the loop — a
  clean failure, a Skill aborted during activation, a synthetic completion —
  no longer stay at `starting`, degraded tool-set observation no longer
  suppresses the closure, and a Host that rejects the terminal snapshot — or
  any callback failure the Session already recorded — fails the Run with the
  recorded callback status and poisons the Session instead of being reported a
  successful Run.
- AgentCore ABI v1 returns to **revision 15**; `RUN_INPUT_PART_DOCUMENT`,
  `MAX_RUN_INPUT_DOCUMENT_DATA_BYTES_V1` and status
  `DOCUMENT_INPUT_UNSUPPORTED` are gone. No bundle was ever published from a
  revision-16 tree (the only release, `0.1.0`, is revision 14, has no assets,
  and no workflow publishes or uploads a bundle), so revision 15 keeps a single meaning and
  the codes need no tombstone. SDK package version returns to `0.2.0-dev`.

### Fixed

- A CAS publication failure (a full session quota, for example) no longer turns
  a bounded MCP result into a tool error. All three publishers — the native
  spool, the classic `McpClient` and the AgentCore projector — share
  `result_budget.retainInlineAfterFailedPublish` and keep the bytes inline up to
  their own materialization ceiling (64KB for the two that would have to read
  from disk, the 1MB frame limit for the classic client, which already holds
  the bytes), so the conversation projection renders its bounded head/tail
  envelope with `storage_error` exactly as it did before the threshold change.
- AgentCore's request preflight (`canonicalRequestBytes`) charges image tool
  results as native bytes only when the configured model accepts image
  input; on a text-only route the estimate is exactly the placeholder request
  the serializer sends. Previously the full base64 length was added back
  unconditionally, so a few large image results on deepseek-chat / glm-5.2
  returned `checkpoint_budget_exhausted` for a request of a few hundred
  bytes, and repeated it on every later run because those results are
  non-trimmable.
- Image results now have a wire-size safety net: they bypass the byte
  budgets, so five parallel 3.75 MB pictures could produce a request no
  provider accepts. `types.MAX_IMAGE_RESULT_BYTES_PER_REQUEST` (16 MiB) caps
  the base64 image bytes per request: the projection spills the largest
  images of the current turn beyond the cap into artifact envelopes, and the
  agent loop stubs the oldest already-delivered image results before each
  request until the history fits (first-class user images count against
  the allowance and a fresh tool turn is projected against what they leave;
  the block-level watermark is persisted in the transcript, so a resumed
  session trims exactly the pictures earlier requests delivered natively and
  reports explicitly when only non-trimmable images exceed the cap).
  Gemini 3 function responses embed only
  PNG/JPEG/WebP; `image/gif` results now go out as a sibling `inline_data`
  part instead of being rejected. The stream handle reports the exact
  tool_use ids whose image went out as a placeholder, so a plugin dialect
  that serializes some MIME types natively and refuses others no longer pins
  the natively-sent pictures.
- OpenAI chat/completions and Gemini dropped every text block that shared a
  message with tool results: the PostToolUse `additionalContext`, the
  verification checkpoint, the requirement-ledger prompt and similar host
  text that the agent loop appends to the tool-result user message never
  reached those providers (Anthropic and the OpenAI Responses protocol were
  unaffected). The chat serializer now re-sends that text as a user message
  after the tool messages (or as the last part of the image follow-up
  message), and Gemini appends it as trailing text parts of the same user
  content. Covered by serializer tests and by the hook-pipeline component
  test, which now asserts the context on the wire.
- The image projection exemption (issue #26, below) is covered end to end by
  an agent-loop test that reads an 80 KiB-base64 PNG through the real `Read`
  tool and asserts the image block on the wire, and the same exemption now
  also holds at the two other layers that rewrite a tool result before
  serialization: microcompact no longer clears an image
  result under the recent-N pressure valve (a `Read(image)` with two parallel
  siblings was cleared before the provider ever saw it), and the AgentCore
  `ToolEnvironment` no longer promotes an image above `tool_result_cap_bytes`
  to an artifact (the payload cap is charged at the vision estimate, the
  durable budget at the real bytes). In exchange the shared predicate
  `extractImageResult` only accepts the canonical Read shape: allowlisted
  media type (`image/png|jpeg|gif|webp`), standard base64, at most
  `MAX_IMAGE_BYTES` of payload, exactly the three keys in any order with only
  whitespace after the closing brace, so a plugin cannot obtain an unbounded
  exemption by prefixing arbitrary output with `{"type":"image"`. `result_projection.Stats.projected_bytes` stays a
  real byte count; the turn-budget decision moved to a new `budget_bytes`.
  The predicate is structural (any field order, standard JSON whitespace,
  exactly the three keys, raw content bounded by `MAX_IMAGE_RESULT_BYTES`),
  so surrounding whitespace cannot smuggle an oversized payload past the
  budget and a JSON serializer that does not escape `/` still produces an
  image. Microcompact protects only images that have not yet been delivered
  to the provider, where delivery is an explicit per-message watermark
  (`Message.delivered`) advanced by the agent loop once the provider has
  accepted a request for streaming — and, for messages holding an image
  result, only when the serializer actually sent native image parts (a
  non-vision model only received the placeholder; the serializer reports the
  affected tool_use ids back on `StreamHandle.image_placeholder_ids`, and the
  flag lives on each tool_result block) — never inferred from a locally
  appended assistant message; delivered
  images clear like any result, so the pressure valve keeps working on
  image-heavy history, and images are never truncated. AgentCore `settleSuccess` now counts live
  sibling reservations against the hard budget, so an inline image whose
  durable bytes exceed its own reservation is refused instead of consuming
  the space a parallel tool had already reserved.
- Transcript resume no longer treats a failed `read` as end-of-file: `EINTR` (a
  Ctrl+C or terminal resize during `/resume`) is retried, and any other read error
  makes `loadTranscript` and the compact-state meta loader fail with `ReadFailed`
  instead of silently restoring a truncated or empty history. The `/resume`
  listing keeps skipping a session whose `meta.json` cannot be read. Surfaced by
  the Codex cross-review on #46.
- Restoring a persisted compact projection is all-or-nothing: `restoreCompactState`
  allocates the summary before touching either field, so an allocation failure
  during resume leaves a genuine full replay rather than an advanced boundary with
  no summary (and no dangling summary pointer).
- A KG client that owns no Store can no longer create one (issue #30).
  `KgClient.store_path` was a single `[]const u8` carrying two meanings — a
  real path under the CLI transport, and the marker `"daemon-owned"` under the
  daemon transport, meaning *this client owns no Store*. Nothing in the type
  stopped the marker from reaching a call that treats it as a path, and
  `cloneForThread` did exactly that: it guarded on `transport == .daemon`,
  while the marker is set for `.daemon` **and** `.unconfigured`, so an
  unconfigured parent fell through to the CLI reconstruction, which re-resolved
  a real `bin_path` and then ran `tinykg init daemon-owned`. Because the marker
  is relative, the Store materialised in the process's current directory — for
  the TTY e2e suite, the git worktree, as untracked `daemon-owned/` and
  `daemon-owned.tinykg-daemon.lock` that no `.gitignore` rule covered.
  The field is now `store: StoreRef`, a union of `.owned` (an absolute path)
  and `.unowned`; `argvSlot()` serves the argv slot the wire protocol
  reserves, and `fsPath()` returns an optional that every filesystem call must
  unwrap. A relative store path from config or `METACODES_KG_STORE` is
  completed against `home` rather than taken as given, so no configuration can
  steer the Store — or the five sibling artifacts derived from it — into the
  current directory. **Breaking for source-level consumers:** `store_path` is
  replaced by `store`.
- `zig build --build-file control-plane/build.zig rule-check` passes again. It
  demanded that every discovered test be imported into `tests/integration_suite.zig`
  while build.zig panics if a *dedicated* test appears there, so the reported
  omission was unfixable as stated: satisfying the rule aborted the build and
  took seven rules down with it. The sensor kept a hand-written copy of
  build.zig's `aggregate_test_exclusions` that had gained neither the second
  entry nor a way to notice; it now parses that list from build.zig, and
  additionally requires each excluded test to have its own `root_source_file`,
  so being excluded from the aggregate means having a home rather than merely
  having a file.
- The OpenAI Responses protocol now replays reasoning items across tool
  continuations (issue #23). Requests use `store:false`, so the server keeps no
  copy of the response and reasoning context survives only if the client sends
  the server's own `reasoning` items — `id`, `summary`, `encrypted_content` —
  back verbatim; previously they were parsed away and the next request carried
  only the function call and its result. Items are captured from
  `response.output_item.done` **and** from the terminal response's `output`
  array, deduplicated by id so an item present in both is replayed exactly
  once, and emitted first among their message's `input` items, matching the
  server's own output order. Replay is model-scoped: after a mid-session model
  switch the stale encrypted state is dropped rather than sent to a model that
  would reject it. Reasoning items persist through the JSONL transcript and the
  AgentCore checkpoint (block tag 6). A conversation without reasoning items
  serializes byte-identically to before.
- Image tool results are no longer spilled into artifact envelopes before the
  dialect layer can serialize them (issue #26). `result_projection` rewrote any
  tool result above a `clamp(window/8, 8 KB, 64 KB)` threshold, while the
  `Read` tool accepts images up to 3.75 MB — so essentially every real
  screenshot became an envelope and the native image serialization added in
  #24 never ran on it, on every provider. Image-shaped results (detected with
  the existing `dialect.extractImageResult`, not a second sniffer) are now
  exempt from byte-length spilling in both projection passes, and the per-turn
  budget charges an image at `IMAGE_TOKEN_ESTIMATE` instead of its base64
  length, so one screenshot no longer evicts unrelated tool results. Images
  stay bounded by `MAX_IMAGE_BYTES`, and non-image results project
  byte-identically to before.

- Image tool results (the `Read` tool's
  `{"type":"image","media_type":...,"data":...}` form) are now serialized
  natively on every protocol family instead of being passed to the model as a
  multi-megabyte base64 text string on OpenAI and Gemini. Vision models get
  the image itself: OpenAI chat/completions sends a short pointer in the tool
  message and the image in an immediately following user message (tool
  message content officially accepts text only); the OpenAI Responses
  protocol sends `function_call_output.output` as an official `input_image`
  parts array; Gemini 3 uses the official multimodal function response
  (`functionResponse.parts[].inlineData`), older Gemini models get a sibling
  `inline_data` part in the same user turn. A model without vision gets a
  short explicit placeholder — never the raw base64 — including text models
  behind Anthropic-compatible gateways, which previously received an `image`
  source block they reject. Non-image tool results and Claude vision
  serialization stay byte-identical (prompt-cache prefixes unaffected).

### Added

- Provider profiles, model offers, and a UI-independent runtime control plane
  (issue #16, delivery slice P0 plus the Z.AI GLM Coding Plan provider).
  `ProviderProfile → ChannelDescriptor → ModelOffer → RuntimeSelection`
  replaces "a model name identifies the route": relays, regions, plans,
  accounts, and BYOK bindings now produce distinct offers for the same visible
  model, and `OfferId` is a domain-separated digest over the normalized stable
  binding so a metadata refresh moves `offer_revision` without moving a pinned
  selection. Adding a vendor is one `src/provider/profiles/<vendor>.zig` file
  plus one line in `BUILTIN_PROFILES`; the transport is selected by the offer's
  protocol, which retires `main.zig`'s model-name prefix guessing for every
  session that names a provider. New CLI flags `--provider`, `--channel`, and
  `--offer`; a model matching several routes reports the candidate offer ids
  instead of guessing, and a `--base-url` override is validated against the
  profile and route policy before any request URL is constructed. Ships
  `metask`, `openai`, `gemini`, and `zai-coding-plan` profiles — the last with
  all four documented China/global × OpenAI/Anthropic-wire routes, its own
  credential kind, `ZAI_API_KEY`/`GLM_API_KEY`/`Z_AI_API_KEY` aliases, and a
  forbidden-path rule that makes silent fallback to the general
  `/api/paas/v4` surface unrepresentable. Credentials become typed, secret-free
  `CredentialRef`s resolved in provider scope, so a Metask key can no longer
  authenticate an OpenAI or Z.AI route; the transports materialize a
  provider-declared `AuthScheme` (bearer, `x-api-key`, custom header) instead of
  a hard-coded bearer header. Metadata is conservative throughout: distinct
  context/input/output limits with fail-closed admission, tri-state
  capabilities, `unknown` (never zero) prices, and per-field provenance.
  `~/.metacodes/config.json` gains a schema-versioned, monotonically revisioned
  provider map written under a cross-process lock via temp-file + fsync +
  rename, with idempotent retries and deterministic revision conflicts. See
  [doc/PROVIDER_OFFER_ARCHITECTURE.md](doc/PROVIDER_OFFER_ARCHITECTURE.md),
  including its explicit list of deferred slices.
  Endpoint policy refuses two whole classes of URL rather than pattern-matching
  them: a percent-encoded host or path (a substring rule over encoded bytes is
  not a rule while the server still decodes it) and any URL carrying userinfo
  (that string becomes `ModelOffer.endpoint_ref` and flows into `model.list`,
  events, and setup output, none of which redact it). The control plane guards
  its mutable state and hands `model.list` results into a caller-owned buffer,
  so two clients cannot invalidate each other's page; `events.replay` copies
  under the lock. `config_store` is the single authority for `config_revision`
  — the kernel mirrors it through `adoptConfigRevision` rather than keeping a
  second counter — and idempotency keys are a bounded ring, so a retry is still
  recognized after other commits have landed.

- Cross-UI model picker, durable selection at startup, and built-in pricing
  (issue #16, further P1 slices). `Ctrl+O` and `/model` open one picker —
  provider → canonical model → channel/offer → options → commit — that reads
  offers from the control plane and mutates only through it. Offers are grouped
  by canonical id, never by visible name, so two channels serving "GLM-4.6"
  over different protocols, regions, or prices stay separate rows showing their
  endpoint, wire model id, limits, price, and health. The picker is modal for
  the keyboard and not for the session: typing filters, the draft in the input
  box is untouched, a reply keeps streaming, and a mid-stream commit takes
  effect on the next turn. Session is the default scope and `Tab` cycles to
  `global`/`once`, so a durable write is always an explicit act the footer
  spells out before Enter. Transcript viewing moves to `Ctrl+X Ctrl+O` — same
  letter, on the existing `Ctrl+X` prefix — with `/transcript` as the
  documented equivalent; TTY regressions cover both paths, including their
  Kitty CSI-u forms. `/model use <id>` now resolves against the offer catalog
  first, so a model served by another provider or protocol switches in place; a
  name carried by several routes reports their offer ids instead of guessing,
  and an offer id is accepted verbatim. `/models` keeps account-key selection,
  which is a credential choice rather than a route.
  A selection committed with `global` scope is now read back at startup:
  `applyPersistedGlobalSelection` applies it before model-name inference, and a
  stored pin the catalog no longer offers is a startup error naming the offer
  and the way out — never a silent fallback to another vendor. Session scope
  gets its own document and its own file (`<session>/runtime-selection.json`)
  rather than sharing the global key, so one session's choice cannot become
  everyone's. The `metask` profile ships a real quote derived from
  `util/pricing.zig` — the same table `/cost` reports with, asserted equal
  field by field — while `zai-coding-plan` deliberately stays `unknown` because
  a Coding Plan subscription is not billed per token. `Quote` gains a cache-write
  rate so an estimate over a cached turn is not silently low.
  New gate `zig build test:picker` compiles the picker from a root reaching the
  provider kernel and the terminal theme and nothing else.

- User-defined providers (issue #16, P1). A `custom_providers` section in
  `~/.metacodes/config.json` defines provider instances that go through the same
  registration and validation as a built-in profile, so the picker, `--provider`,
  `model.list`, `quote.estimate`, and token admission treat them identically.
  The schema is declarative and cannot execute anything: there is no field for
  code, a callback, a shell command, or a request template, and unknown keys are
  ignored rather than interpreted. A protocol is a *wire* plus an optional
  request path — what relays and gateways actually differ by — so a relay needs
  no adapter, while a genuinely novel wire is rejected rather than guessed.
  Declared limits, capabilities, prices, and controls carry
  `user_config` provenance and a configured price is marked estimated, because a
  number the user typed is a declaration and not a vendor observation. New
  `--check-providers` dry run validates the configuration and prints every route
  it produces — provider, channel, protocol, endpoint, wire model id, context,
  price — with no credential resolved and no request URL built.

- Provider catalog adapters and the events they enable (issue #16, P1).
  `src/provider/openrouter.zig` parses model and endpoint documents
  *separately* — a model with three endpoints becomes three offers, because a
  model name is not a route — and merges them so an endpoint's own values win
  while an absent one inherits with `inherited` provenance instead of becoming
  free or unlimited. An endpoint that never reported a status has `unknown`
  health, not healthy; a price string that is not a number is an error, not a
  zero. Provider preferences compile into `RoutePolicy` with `only`/`ignore` and
  the numeric ceilings as hard constraints and `order`/`sort` as preferences
  that never reject, and `PriceConstraint` gained per-direction ceilings because
  a router's price limit is per direction. Router metadata folds usage, cost,
  latency, and fallback attempts into the `ActualRouteEvent` the kernel derived
  without rewriting what was requested. Ingesting a catalog moves the catalog
  revision and emits `catalog.updated`, `pricing.updated`, and
  `provider.degraded`; `auth.changed` and `credential.expiring` gained kernel
  producers. Catalogs are named by a `provider_catalogs` section in
  `config.json` and read from disk, so no transport dependency enters the
  provider subsystem.

- Provider-scoped OAuth lifecycle (issue #16, P1). `provider/oauth.zig` runs
  refresh, single flight, and rotated-refresh persistence for any profile that
  declares an OAuth credential kind and a token endpoint — OpenAI and Codex
  first; Metask keeps its historical `core/auth.zig` path byte for byte. N turns
  discovering an expired token at once perform exactly one refresh, because with
  a rotating refresh token the losers of that race would present a token the
  server already invalidated. The rotated token is persisted atomically (temp
  file + fsync + rename, 0600) *before* it becomes the live one: a provider that
  rotated has already killed the old token, so "used but not saved" locks the
  user out while "saved but not yet live" is recovered by the next load. Refresh
  triggers a margin before expiry, since a token that expires mid-flight fails
  the request it was attached to, and `invalid_grant` is terminal rather than a
  transport error a retry loop would chew on. The module performs no I/O — the
  exchange is a function pointer, with `api/oauth_exchange.zig` as the
  production `refresh_token` grant — so every lifecycle test drives a fake and
  none needs a network. `metacodes login --provider <id> --oauth-token-json
  <file>` imports the first token into that provider's own store.

- Selection scope, auth-scheme inheritance, and the query-auth decision
  (issue #16). A `session`-scoped commit is now written to the session's own
  `runtime-selection.json` and restored by `/resume`; because session scope is
  narrower than global, a resumed session continues on the route it was using
  rather than whatever became global meanwhile, and a stored route that no
  longer resolves is reported instead of silently replaced. The resolved route's
  auth scheme now reaches swarm teammates and `AgentSession` as well as `App`
  and background subagent jobs — a worker sending bearer at an `x-api-key`
  endpoint has the right key and the wrong header — and a route switch moves the
  swarm context with it so a teammate spawned afterwards cannot dial the
  previous provider. `AgentJobRegistry.setRoute` moves key, endpoint, transport,
  and scheme together for the same reason.
  `AuthScheme.api_key_query` is **removed** rather than implemented. A secret in
  a query string lands in server access logs, proxy logs, and referrer headers,
  and it would flow into the endpoint strings this subsystem already refuses to
  let carry credentials — the endpoint policy rejects userinfo URLs for exactly
  that reason.

- Credential pools: several accounts per provider, each its own route
  (issue #16, P2). A `credentials` list on a configured provider declares
  accounts **by reference** — id, environment-variable name, kind, priority —
  so no secret enters `config.json`, which several tools read and which is not
  mode 0600; a literal `secret` key is rejected at parse time. A bound
  credential participates in the offer id, so each account becomes its own offer
  and appears as its own row in the picker with an `account=` column. That also
  removes the need for a separate credential stage: the accounts already are
  offers. Because the offer names the credential, binding uses that member
  rather than the pool's highest-priority one — resolving to a different account
  would make the offer id identify a route the request does not take. Selection
  among unbound members is deterministic (priority, then id) so configuration
  order cannot make a failover irreproducible, and members that are invalid,
  cooling down, expired, or empty are skipped. `noteFailure` maps a
  provider-classified failure to the right state: a rate limit earns a cooldown,
  an authentication failure marks the credential invalid, and a transient
  network error changes nothing. The pool is consulted after every existing
  source, so a single-credential setup resolves exactly as before.
  `credential.expiring` and `auth.changed` now have producers on the OAuth path,
  which is the only thing that knows a credential's expiry.

- TinyKG decision audit plane (issue #16). Control-plane events are projected
  into an append-only record under `metacodes/provider-decisions` at the turn
  boundary — accepted and rejected selections with the catalog and config
  revisions that make them reproducible, actual routes with fallback attempts
  and cost/latency aggregates, failovers, catalog and pricing refreshes, and
  credential status changes. `provider.degraded` health samples are deliberately
  excluded: the requirement names high-frequency observations as something that
  must not accumulate in the graph. The projection is safe by construction —
  event payloads are ids and enums with no free-form field — and a test asserts
  no recorded line contains a quote, a URL, `Bearer`, or `sk-`. The plane is
  optional: nothing on the request path calls it, and a TinyKG outage is counted
  rather than propagated into routing.

- Catalog fetching and learned credential failover (issue #16). Provider
  catalogs may now be fetched (`models_url`, `endpoint_urls`, optional
  `credential_env`) as well as read from disk, with `/providers refresh` driving
  it; a refresh that fails leaves the previous catalog in place, because a stale
  catalog is a better answer than an empty one and every pin stays resolvable.
  The fetch lives in `api/catalog_fetch.zig` rather than in the provider
  subsystem, which must not depend on a transport. `/providers` also lists every
  route with its account, context, and price. Credential failure state is now
  learned and durable: a rate limit records a cooldown and an authentication
  failure records an invalidation, through the same lock, revision, and atomic
  write as every other mutation, so the next process skips the credential
  instead of rediscovering the limit by hitting it. The class is the provider's
  own classification, and a transient network failure records nothing.

- Local route aliases (issue #16, P2 follow-up). `AliasEntry` was a declared
  record with no producer or consumer; `/alias` now creates, lists, resolves,
  and removes them. A **pinned** alias stores the offer and revision and means
  the same route across catalog refreshes — reporting an error when that route
  is gone rather than resolving to a neighbour, because a pin that quietly moves
  is not a pin. A **floating** alias stores the selector and re-resolves, and
  records what it landed on so a route stays attributable after the fact; a
  selector matching several routes is an error listing the candidates, not a
  guess. Either policy produces a *pinned* runtime selection, since the alias
  already decided and leaving it auto would let it re-resolve mid-turn against a
  catalog the user never saw.

- Provider lifecycle through the control plane, and a five-vendor capability
  fixture (issue #16). `/providers enable|disable|remove <id>` manages a
  provider instance without editing `config.json` by hand; disabling preserves
  its configuration and credential references — the difference from removing it
  — and excludes it from the *catalog*, so "disabled" is true in the picker,
  `model.list`, and `--provider` at once instead of being re-checked at three
  call sites. A new capability-matrix fixture declares DeepSeek V4, GLM-5.3,
  Kimi K3, GPT-5.6, and MiniMax M3 with timestamped, provider-declared
  capabilities and four different control vocabularies, and asserts what no
  name-inference rule could get right: reasoning supported / unsupported /
  unknown across three models, GLM's peer `reasoning_content` as a separate
  capability, a latency tier on one model and a service tier on another, and
  channel-specific limits narrowing a model's own. New L2 coverage proves a
  control change alters the bytes actually sent (and that leaving it unset
  smuggles no default onto the wire), and that a provider's opaque control
  metadata round-trips through `model.list` into the picker without any core,
  TUI, or Web change.
  A committed route is also broadcast on the existing UI event stream as a
  `config_changed` → `route` event carrying provider, channel, protocol, wire
  model id, offer id, credential reference, and scope — the model name alone
  would announce a change an out-of-process client cannot tell apart from
  another, since one visible name can come from several providers, channels,
  protocols, and accounts. The credential reference travels; the secret does
  not.

- AgentCore ABI v1 revision 15: `session_run_input` gains
  `RUN_INPUT_MULTIMODAL` — an ordered `RunInputPartV1` array of text and
  base64 image parts (per image capped at the Read tool's 3.75 MB raw limit,
  total bounded by the 16 MiB input cap) that becomes one first-class
  multimodal user record with the exact-reservation admission invariant, full
  checkpoint/restore round-trip, and a pre-admission image-capability
  preflight returning the new status
  `METASK_AGENTCORE_STATUS_IMAGE_INPUT_UNSUPPORTED` (28) before any Provider
  request. C header, Zig SDK (`runMultimodal`, `textPart`/`imagePart`), Rust
  bindings, and both source-free consumers move to revision 15 atomically;
  source embedders get `AgentSession.runUserParts` /
  `Conversation.appendUserParts` and the example gains `METACODES_IMAGE`.
  Fixed en route: the provider-neutral canonical request projection (durable
  budget accounting, journal request identity, token estimates) no longer
  re-applies per-model image capability — previously any image run on a
  vision model whose name lacks `claude` (every OpenAI/Gemini model) failed
  inside accounting with `ImageInputUnsupported` before the real request was
  sent (`json.serializeCanonicalRequestProjection`).
- Model tiers (issue #11 core-side fix): subagent/skill model pins and
  `/model` now resolve tier names — `low`/`mid`/`high`, with legacy aliases
  `haiku`/`sonnet`/`opus` mapping to the same tiers — against a per-provider
  table in `~/.metacodes/config.json` (`model_tiers`, keyed by provider kind,
  each tier an optional `{model, effort}`). An unconfigured tier inherits the
  session model/effort; the hardcoded alias→Anthropic-ID map is gone, so a
  tier or alias can never inject a cross-provider model ID — the mechanism
  that made Explore subagents send `claude-3-5-haiku-20241022` to
  OpenAI-compatible relays and fail with an opaque 503 while the parent
  session worked. The built-in `Explore` agent now pins tier `low`
  (previously `haiku`); `/model <tier>` applies the configured tier model and
  keeps the existing cross-provider guard for unresolved literals. Tier
  `effort` rides the existing per-family dialect translation, which now also
  covers MiniMax: M3 gets the native three-state
  `thinking:{type: disabled|adaptive|enabled}` mapping (compat
  `reasoning.effort` strings are accepted upstream but do not tune depth, so
  they are not sent), and M2.x — where thinking is always on — sends only
  `reasoning_split:true` so reasoning arrives as `reasoning_content`.
  OpenAI/Anthropic/GLM/Kimi/DeepSeek translations were already built in.

### Changed

- Language server integration is **on by default**; the new `--no-lsp` turns it
  off (issue #17 follow-on). `--lsp` still works and now simply reasserts the
  default, so existing command lines keep running; the last of `--lsp` /
  `--no-lsp` on the line wins.
  - *Why flip it.* Since `1515b34` removed tree-sitter, `CodeMap`,
    `FindSymbol`, `Read(outline: true)` and Edit/Write post-write diagnostics
    all source symbols from LSP, so an opt-in flag meant the default
    configuration ran four features in a degraded state. The flag was also a
    redundant second gate: the real gate is and remains runtime — a registered
    server for the extension, its binary actually installed, the file inside a
    git workspace, a `root_marker` hit — followed by lazy spawn keyed by
    `server_id+root`, a 10-minute idle reaper, a client-count ceiling and the
    broken-set. On a machine with no language server installed, enabling it
    starts no process at all.
  - *What it costs.* The one newly-involuntary path is post-write diagnostics.
    Measured on this repository with zls: 112 ms cold, 52 ms warm per write.
    The 14 s/26 s constants in `lsp/service.zig` are ceilings for heavier
    servers, not typical values; the disk write itself is never blocked and the
    wait is Ctrl+C-interruptible.
  - *Escape hatch reaches subprocesses.* `--no-lsp` propagates to
    out-of-process teammates, which would otherwise start their own servers
    against the lead's explicit choice.
  - *Not closed by this change.* Subagents still run without LSP:
    `agent_loop.Options.lsp` is deliberately not threaded into child loops
    because `lsp/client.zig` requires `sendRequest`/`sendNotification` from a
    single caller thread while subagents run on background threads, so lifting
    it needs send-side serialization in the Client, not a one-line passthrough.
    For the same reason independent sessions cannot share a `Service`, so each
    out-of-process teammate and each `--serve-multi` daemon session starts its
    own servers; `--no-lsp` is the lever meanwhile.
  - *Rejected.* Enabling by project size — `root_markers` already encode "this
    is a real project", and large trees are exactly where indexing is most
    expensive, so size-as-eagerness is backwards. Auto-installing language
    servers — it contradicts the repository's binary policy, spans six
    unrelated install channels, would execute npm `postinstall` outside the
    permission and sandbox layers, and a version-mismatched server is worse
    than an absent one because nothing signals the error.

### Fixed

- `~/.metacodes/config.json` writes no longer delete other writers' keys. The
  config writer serialized only its own five fields, so any theme change
  silently dropped `mcp_servers`, `permission_rules`, and `model_tiers`. It now
  merges through an order-preserving JSON merge, refuses to overwrite a document
  it cannot parse, and treats a failed read as an error rather than as an empty
  document — descriptor exhaustion or a transient I/O error would otherwise
  truncate the whole file.

- The language server binary lookup is platform-correct, so the LSP subsystem
  is no longer unconditionally dead on Windows. `lsp/servers.zig`'s `which`
  hardcoded three POSIX assumptions — split `PATH` on `:`, join with `/`,
  test executability with `access(X_OK)` — and every one of them fails on
  Windows: `C:\bin;C:\other` split on `:` yields `C`, `\bin;C`, `\other`
  (none of them a directory), and executability there is decided by the
  `PATHEXT` extension list while every registered `ServerDef.binary` is an
  extensionless name (`zls`, `gopls`, `clangd`). Both consumers flow through
  that one function, so they failed together: `Service.getOrSpawn` could never
  start a server, and the issue #17 capability gate `servers.binaryAvailable`
  reported "the '<binary>' language server is not installed (not found in
  PATH)" for every language even when it was installed. This predates issue
  #17; that work only made the failure legible. The lookup now lives in the
  portable layer as `platform.exe_lookup` (separator, joiner, `PATHEXT`
  probing with the cmd.exe default list, quoted `PATH` segments,
  drive-relative names, and no extension appended to a name that already
  carries one), and `which` is a one-line delegation. `realProbe` also stops
  accepting a *directory* as an executable, which plain `access(X_OK)` did on
  POSIX. Empty `PATH` segments are still skipped rather than searching the
  working directory, which POSIX would allow but is a PATH-injection surface.
- `zig build test:platform` ran **zero** tests, and `windows:gate` depends on
  it — so the "Native Windows platform gate" step was passing vacuously for
  its entire unit-test half. `src/platform/platform.zig` aggregated the
  submodules as `pub const x = @import(...)` with no `test` block referencing
  them, and Zig only collects tests from files it analyzes. Adding the block
  turns up 52 tests (43 pass / 9 environment-skipped) that had never run. The
  LSP suite (`test:lsp`) now also runs on that gate, and the workflow's path
  filter covers `src/lsp/**`, since server lookup is native-platform logic.
  Independently of that gate, `ci.yml`'s per-module `zig test
  src/platform/<module>.zig` loops — the unfiltered ones that run on every PR,
  on POSIX and on the Windows runner — now include the new module, so the
  Windows-semantics assertions run on both.

- The new lookup's parsing is a pure function over an explicit `Style` plus a
  supplied `PATH`/`PATHEXT` string, so Windows semantics are asserted on
  **every** host — including the regression case that splitting `C:\bin;C:\other`
  on `:` shreds it — instead of behind a `SkipZigTest` on non-Windows machines.
  `lsp/servers.zig`'s own `which` test likewise stopped skipping on Windows and
  now asserts against `cmd`/`cmd.exe` there and `sh` on POSIX.
  Windows support for the subsystem as a whole is **not** claimed: process
  spawn, pipes, polling and termination already have real Windows
  implementations, but `workspace.isInsideWorkspace` only accepts `/` as a
  path boundary (so every file is judged outside the workspace),
  `client.pathToUri` emits `file://C:\proj\a.zig` where LSP requires
  `file:///c%3A/proj/a.zig`, and `CreateProcess` cannot launch the `.cmd`
  shims npm installs for `typescript-language-server`. Those three are
  enumerated in the status table at the top of `src/lsp/lsp.zig`, which is the
  single place that states Windows readiness.

- Symbol capability gaps no longer masquerade as "symbol not defined"
  (issue #17). `FindSymbol` returned a bare `[]` whenever `--lsp` was on but
  the language server binary was missing, because the *decide* predicate
  (`symbol_provider.hasSymbolsFor`) consulted only the compile-time
  `SERVERS` extension table while the *use* predicate
  (`lsp.Service.getOrSpawn`) additionally resolved the binary, spawned it,
  and consulted the broken-set — a two-state type (`!Symbols`) squeezing a
  three-state reality. The shape was inherited from the tree-sitter era, when
  statically linked grammars made "extension registered" equivalent to
  "capability available"; commit `1515b34` changed the dependency to an
  external runtime process without updating the capability contract.
  The predicate is now single-sourced and runtime-aware
  (`lsp.servers.binaryAvailable`), and the symbol path carries an explicit
  third state (`lsp/capability.zig` `Unavailable{reason, detail}`,
  `symbol_provider.Outcome`, `lsp.Service.fetchSymbols`) with one shared
  wording table. `FindSymbol` now appends a qualifier naming the missing
  binary (and flags partial results when only some candidate files were
  skipped), `CodeMap` prints the specific reason instead of `(no symbols)`,
  and `Read(outline: true)` explains why it fell back to a full read rather
  than degrading silently. When a scan spans several languages the reported
  reason is the most *actionable* one rather than the first encountered — rg
  walks in parallel, so a README that merely mentions the name could otherwise
  make the answer "no language server is registered for this file type" and
  bury the "pyright is not installed" that the caller can act on. The
  per-file capability answer is memoized for the duration of one scan
  (`symbol_provider.CapabilityCache`, caller-owned, no global state): the
  predicate costs a PATH scan — measured at 36–43 µs with a 30-entry PATH —
  and FindSymbol asks it once per candidate file, up to ~3200, for at most
  seven distinct answers. Regression tests cover the **server-absent** side
  unconditionally — synthetic `ServerDef`s with absolute-path binaries make
  that side reachable on any machine, replacing the
  `if (which("zls") == null) return error.SkipZigTest` pattern that had
  skipped exactly the half where the defect lived.

## 0.1.0 — 2026-08-29

### Security

- Third-party GitHub Actions are pinned to full commit SHAs, and the Windows
  Rust bootstrap downloads a version-pinned `rustup-init` verified by SHA-256
  before execution — the action set and the installer are no longer mutable at
  fetch time. (The Rust `stable` toolchain itself stays rustup-managed behind
  the presence guard: it installs once and is not re-resolved per run.)
- `scripts/verify_tinykg_binary.py` now inventories `vendor/tinykg/bin/`:
  an executable not declared by the manifest fails the gate (per-binary
  hashes cannot see extra files).
- The rule-control telemetry artifact no longer records the runner's absolute
  workspace path, and feedback child processes run with secret-named
  environment variables removed (name denylist: `*API_KEY*`, `*ACCESS_KEY*`,
  `*PRIVATE_KEY*`, `*TOKEN*`, `*SECRET*`, `*PASSWORD*`, `*CREDENTIAL*`), so
  echoed child environments do not carry those variables into uploaded
  artifacts.

### Added

- The AgentCore bundle now ships ripgrep as a manifest runtime asset
  (issue #8 follow-up): `vendor/ripgrep/` grows a TinyKG-style manifest-pinned
  cross-platform set of upstream official 14.1.1 release binaries
  (macos-aarch64/x86_64, linux-x86_64 musl static, the existing
  windows-x86_64; `aarch64-windows` explicitly maps to the x86_64 executable
  via Windows-on-ARM x64 emulation), verified fail-closed by
  `scripts/verify_ripgrep_binary.py` (SHA-256, format magic, exact `bin/`
  inventory) in CI. `zig build agentcore:bundle` stages the target's binary as
  `bin/rg[.exe]` (SHA-verified by `scripts/stage_ripgrep_binary.py`), records
  it in the manifest `files` allowlist plus a new `runtime_assets` declaration
  (name/version/revision/path/upstream/license/role), and ships the MIT text
  as `bin/ripgrep-LICENSE-MIT`; the source-free consumer validates the asset
  hash and declaration, and a target with no vendored ripgrep fails bundle
  assembly. The toolchain resolver's stale `./vendor/ripgrep/rg` fallback now
  points at the real per-target vendored binaries, so dev/CI checkouts resolve
  rg without a system installation.
- UI-neutral session command surface (issue #3): all raw input now flows
  through one typed pipeline (`session_intent.parse` →
  `SessionService.dispatch` → `RunPlan`), shared verbatim by the terminal
  REPL, `--web`, and the daemon. Web/daemon gain `/commit` `/review` `/init`
  `/retry` `/mode` and `!cmd` over `POST /command` (single- and multi-session
  daemons previously answered 501; they now serve the rich `/state` snapshot
  too), the REPL gains `/mode [name]`, and run-option assembly collapses into
  one canonical `session_service.buildRunOptions` — fixing silent capability
  loss where skill-triggered and injected runs were missing
  agents/skills/MCP/cron wiring, and web runs were missing
  LSP/swarm/background-request wiring. Locked by
  `tests/component/session_api_parity_test.zig`.
- Explicit OpenAI Responses API support: `--openai-protocol
  chat_completions|responses` (alias `chat`; env `METACODES_OPENAI_PROTOCOL`)
  selects the OpenAI wire protocol — never inferred from `--base-url` or the
  model name, and invalid values fail closed. `responses` speaks
  `/v1/responses`: typed SSE events (`response.output_text.delta`,
  `response.output_item.added`, `response.function_call_arguments.*`,
  `response.completed`/`incomplete`/`failed`), `input` items with
  `function_call`/`function_call_output` call_id round-trip, top-level
  `instructions`, flat tools, `reasoning:{effort}` (capped at `high`), and
  `store:false`. Subagents and teammates inherit the parent's protocol choice.
- `metacodes --version` prints `metacodes <semver>`; help banner now names the
  project instead of the legacy internal product name. The semver has one
  in-source authority (`src/version.zig`, consumed by the CLI, `lib.VERSION`,
  and the MCP clientInfo handshake), and `zig build test` asserts the real
  binary's `--version` output against `build.zig.zon` end to end.
- `scripts/eval/plugin_release_gate.py --refresh-implementation-fingerprint`:
  the supported repin path after intentional changes to pinned implementation
  files (previously a hand-patched hex edit); validate paths stay fail-closed.
- `scripts/check_doc_links.py` runs over git-tracked markdown, understands
  link titles/angle destinations and CommonMark fence pairing, and is wired
  into `scripts/test_all_gates.sh` and the AGENTS.md pre-submit list, not just
  CI.
- [ROADMAP.md](ROADMAP.md): project status tracked as milestones with exit
  criteria and evidence links.
- [doc/BENCHMARKS.md](doc/BENCHMARKS.md): consolidated benchmark index —
  local performance gates, internal paired evidence, and the external
  WorkBuddy-Bench mainline with ladder status.

### Changed

- `tools.ToolDispatcher` now resolves every per-name execution metadata query
  through one required `metadataFn` returning `?ToolMeta` (executor kind,
  permission category, replay declaration, prefetch flag); the five per-field
  callbacks (`prefetchSafeFn`/`hostSyncFn`/`builtinFn`/`categoryFn`/
  `replayDeclarationFn`) are removed. Dispatch and metadata share one entry
  lookup, so builtin identity, classification, replay and scheduling flags can
  no longer drift apart across the AgentCore wrapper layers
  (budget/Skill/MCP). Consistency consequences: builtin file tools keep their
  `file_refs`/file-change evidence and Read resolves to a `.read_only` replay
  through wrapped Run surfaces, and Host/MCP tools carry their declared
  executable categories through wrappers (ask in default mode, deny in plan,
  instead of a silent name-based allow). With a Session dispatcher present, a
  name the directory cannot resolve now conservatively classifies as
  `.execute` — never the legacy unknown-name read fallback — and dispatching
  it still fails as UnknownTool. The AgentCore C ABI is unaffected.
- ToolDispatcher metadata hardening: `validateMetadataCoverage()` walks the
  advertised directory and reports the first dispatchable name lacking
  metadata (asserted in Debug at the composed Run surface, so a wrapper that
  adds a name but forgets the metadata branch fails loudly); the session
  budget layer now classifies Tool-vs-MCP operations from the same metadata
  resolution dispatch uses instead of the unfiltered MCP view (a
  selected-but-expired alias no longer reserves under MCP caps while dispatch
  answers UnknownTool; `ToolEnvironment.mcp_view` is removed). The MCP-class
  boundary is now the `.external` executor kind, which also covers the Skill
  overlay tool — with the default equal caps this changes nothing, and the
  taxonomy question is tracked as ledger item E12. The Skill overlay also
  refuses to build over a base surface that already advertises a tool named
  `Skill` (`error.SkillToolNameCollision`) instead of silently shadowing it
  while sending duplicate definitions to the provider.
- CI migrated to self-hosted runners (Linux X64, macOS ARM64, Windows X64)
  with a pinned Lean toolchain build. No GitHub-hosted path remains in the
  workflows; restoring account billing would allow reintroducing hosted
  runners as a fallback matrix (tracked in ROADMAP M1). Pull-request jobs
  carry a fork-isolation guard, and Zig caches live in persistent per-runner
  storage so checkout's workspace clean no longer forces cold rebuilds.
- The CI workflow runs one consolidated `Gates (<platform>)` job per platform
  instead of three jobs queueing on each platform's single runner (the macOS
  test job previously waited ~5 minutes behind its sibling jobs), and Lean
  `.lake` build products persist per runner alongside the Zig caches so the
  kernel stops cold-building every run.
- `leanprover/lean-action` removed from all workflows: on every run it
  executed an unpinned installer streamed from elan's `master` branch on the
  persistent runners (the same class of mutable-fetch-and-execute the rustup
  bootstrap fix closed), cost ~40 s, and the per-run elan reinstall
  invalidated Lake's traces so the kernel rebuilt despite the restored
  `.lake`. elan is now a presence-checked runner prerequisite and CI drives
  `lake build` directly; this also removes two per-run action-tarball
  downloads from job setup, which the macOS runner's GitHub connectivity made
  expensive (a single action download was measured at 2m16s).
- Eight paid-runner L2 cases (seven in
  `scripts/eval/tests/test_memory_budget_runtime.py`, one v7-receipt case in
  `test_memory_agent_runtime.py`) that exercise the production macOS Seatbelt
  runner now skip explicitly off macOS (previously they errored on non-macOS
  hosts, and the child-signal case was mis-gated to POSIX). The macOS CI leg
  still executes them, and the maintainer rule-control gate fails closed on
  any skipped test.
- Documentation governance pass: superseded per-revision AgentCore design
  iterations, dated TUI progress transcripts, and unreferenced U-series drafts
  removed (recoverable from git history); doc index now covers the living
  document set; dangling references from source comments to removed docs
  repaired; `tests/README.md` rewritten to match the real build-step surface.
- `zig build test` now passes on a clean checkout without a Lean toolchain:
  eval cases that require the compiled Lean SDK skip explicitly when
  `control-plane/lean/.lake` is absent. CI builds Lean and sets
  `METACODES_TEST_REQUIRE_LEAN_SDK=1`, which turns that skip into a failure so
  an olean path drift cannot become a permanent silent skip; the guard path
  itself is imported from `project_harness_evolution.SDK_OLEAN_RELATIVE`.

### Fixed

- Glob/Grep runtime dependencies now participate in tool availability
  validation (issue #8): catalog admission probes that the ripgrep executable
  actually resolves (`RG_BIN` → `PATH` → next to the host executable → system
  fallbacks), so Runtime creation fails with a typed
  `error.ToolDependencyUnavailable` — surfaced through the AgentCore ABI as
  `STATUS_INVALID_ARGUMENT` with a diagnostic naming the missing executable
  and the provisioning options — instead of advertising tools to the Provider
  that fail their first invocation with `RipgrepNotFound`. Hosts without `rg`
  select a tool set omitting `Glob`/`Grep` (probe available as
  `util_toolchain.ripgrepPath()`); dependency-free selections are unaffected.
  Locked by deterministic negative/positive tests at the toolchain, catalog,
  Runtime, and ABI layers.
- Plan-mode classification escape on the CLI (no-dispatcher) path: a model
  emitting a case-variant builtin name (e.g. `bash`) was classified by the
  unknown-name read fallback and allowed in plan mode, then deterministically
  repaired to `Bash` at dispatch and really executed. Permission
  classification and rule matching now normalize with the same resolver the
  dispatcher uses, so plan mode denies what will actually run; truly unknown
  names keep the read fallback and the UnknownTool guidance.
- `/retry` after an auto-compact could roll the conversation back past the
  compact boundary, leaving the active window projecting empty (the request
  contained only the compact summary — no user message — and later turns
  stayed hidden behind the stale boundary). The rollback now clamps the
  boundary to the retried user message under the snapshot lock.
- OpenAI streaming hardening (adversarial review of the Responses work): SSE
  lines longer than the 8KB transfer buffer no longer kill the stream with
  `StreamTooLong` — `OpenAIStream` now falls back to the same 16MB-capped
  overflow accumulation the Anthropic path uses, so Responses terminal events
  carrying the full accumulated payload (`response.output_text.done`,
  `response.completed`, `response.function_call_arguments.done`) parse instead
  of forcing a discarded, re-billed turn. Under `protocol=responses`,
  `--response-format` (as top-level `text.format`), `--prompt-cache-key`, and
  `--parallel-tool-calls` are serialized instead of silently no-oping.
  Streamed tool-call `arguments` fragments (chat and Responses) accumulate as
  raw escaped bytes and decode exactly once at flush, so a `\uXXXX` surrogate
  pair split across two deltas no longer becomes two U+FFFD. Responses event
  dispatch no longer trusts the first `"type"` in the raw event (a server
  serializing `item` before the top-level `type` previously dropped the
  function call), and parallel/interleaved Responses tool calls are covered by
  a cassette test.
- Transcript persistence survives `/retry`: the writer's append-only
  assumption broke on rollback (flushed count is monotonic), so a retry that
  shrank and regrew the conversation left the regenerated turn unpersisted
  and resuming the session revived the discarded pre-retry turn. Prefix-
  destroying mutations (retry rollback, compact's wholesale replacement) now
  bump a shrink epoch and the writer atomically rewrites the transcript.
  Semantics note: the transcript is a live-state mirror — after a rewrite,
  tool results that microcompact/truncation had already stubbed in memory
  are stubbed on disk too (resume reproduces what the model actually saw;
  previously microcompacted outputs came back verbatim on resume, and
  combined with a retry rollback the restored history could misalign). A
  no-op retry (nothing rolled back, no boundary clamp) does not trigger a
  rewrite.
- Ctrl+B (background the current session) now rotates the foreground to a
  fresh session id, transcript writer, and cleared goal state. Previously
  the fresh conversation kept the old session's writer and corrupted the
  old transcript (misaligned appends; after the rewrite fix, a prior
  retry/compact in the old session would have made the next flush replace
  it wholesale). The old session's transcript is now sealed as-is and
  stays resumable.
- Task-obligation tracking survives case-variant tool names end to end:
  both the dispatch-side accounting and the result-side met-confirmation
  now key on the canonical name / pending id (a lowercase `bash` call that
  really executed previously left the obligation unmet with a bounded
  spurious nudge).
- `/resume` now clears the active skill before switching session identity:
  previously the next run in the resumed session (e.g. an immediate
  `/retry`) executed under the previous session's skill tool policy, and the
  old skill execution state leaked (unregistered under the wrong id).
- Headless (`-p`) runs now carry the real session id into the agent loop
  (previously the default `single`), so KG task claims/leases from
  concurrent headless processes sharing a store no longer collide on one
  identity.
- `--response-format json_schema` now serializes the API-required
  `format.name` (constant `"response"`) on both the Chat Completions and
  Responses wires; both previously omitted it, so json_schema requests were
  rejected server-side with "Missing required parameter".
- OpenAI-compatible streaming now decodes the JSON string escapes of SSE
  fragments: `delta.content` and `reasoning_content` (GLM/Kimi/DeepSeek/Qwen/
  Mistral) previously reached the conversation and thinking stream as raw
  escaped bytes, so `\n`/`\t`/`\uXXXX` rendered as literals. Both paths (and
  streamed tool-call `arguments`) now share one unescaping extractor in
  `util/json.zig`.

## 0.1.0 — standalone extraction and embedding boundary

### Changed

- Extracted `metacodes` as a history-preserving standalone repository whose
  primary branch is `main`.
- Replaced vendored TinyKG source compilation with a manually maintained native
  binary contract: explicit absolute path, operator-observed SHA-256, exact CLI
  version, fresh-store format/schema probe, atomic staging, and deterministic
  provenance receipt.
- Removed ambient TinyKG discovery from runtime and tests. TinyKG-dependent gates
  now fail closed or skip explicitly when no attested binary is injected.
- Added public API, contribution, security, governance, support, third-party, and
  open-source readiness documentation.
- Removed generated evaluation-run artifacts from the published source tree;
  local copies remain ignored and recoverable from the pre-extraction history.

### Security

- Prepared the extracted history for removal of a legacy hard-coded provider token
  before any remote publication. Public visibility remains blocked on an
  independent full-history scan and owner-selected project license.

## Historical — Stage 3 parity (2026-05-29, cc-zig line)

REPL / TUI 体验追齐。

### Added
- **History JSONL**：历史改 JSONL（每行一个 JSON 字符串），多行命令可安全 round-trip；自动迁移旧版纯文本。
- **代码块语法高亮**：render.zig 对 fenced code block 做轻量 token 高亮（关键字/字符串/数字/注释），通用关键字集覆盖 zig/c/ts/js/py/rust/go。
- **TAB 补全**：行首 slash 命令补全 + 路径补全（complete.zig）；唯一直接补全，多个列出 + 补到公共前缀。
- **Ctrl+R 反向历史搜索**：实时匹配 + Enter 接受 / Esc 取消。
- **粘贴检测 + 外部存储**：bracketed paste mode；大粘贴（>12 行或 >1600 字节）存 `~/.cc-zig/pastes/<N>.txt` + 插入 `[Pasted text #N +M lines]` 占位符，提交前展开为真实内容（paste.zig）。
- **`/agents` / `/permissions` / `/memory`**：列 sub-agent 能力 / 显示权限模式+规则 / 跨 session 记忆（`~/.cc-zig/memory.md`，`/memory add`）。

## Historical — Stage 2 parity (2026-05-29, cc-zig line)

工具层 P1 语义对齐。

### Added
- **Read 图像**：`.png/.jpg/.jpeg/.gif/.webp` 读为 base64 + media_type，api/request.zig 序列化时发成真正的 image content block（非文本 dump）；3.75MB 上限。
- **Read 设备路径黑名单**：`/dev/zero` `/dev/random` `/dev/fd/*` 等会 hang 的路径直接拒绝。
- **Edit/Write structuredPatch + gitDiff**：返回结构化 hunk（LCS diff，core/patch.zig）+ 标准 unified diff，不再只有 `{"success":true}`。
- **Edit 安全限制**：`MAX_EDIT_FILE_SIZE` 1 GiB 拒绝 + smart-quote 归一化 fallback（文件弯引号 “ ” ‘ ’ ↔ old_string 直引号）。
- **Write 自动建父目录**（mkdir -p 语义）。
- **Skill `allowed_tools` 软约束**：激活带 allowed_tools 的 skill 时在指令顶部注入工具白名单声明（硬隔离待 forked-subagent）。
- **MCP `resources/list` + `resources/read`**：client 方法 + `<server>__list_resources` / `<server>__read_resource` 工具。

## Historical — Stage 0+1 parity (2026-05-29, cc-zig line)

macOS 移植 + Phase A/B 残留补齐（当时的 survey 文档已移出仓库，见 git 历史）。

### Fixed
- **macOS 编译**：`job_registry.zig` 的 `std.c.getrandom`（macOS libc 无此调用）改为读 `/dev/urandom`。
- **macOS 崩溃**：`read_state.zig` 的 `statFd`/`statPath` 之前硬用 Linux `statx`，在 macOS 上对任何已存在文件做 Write/Edit 会 `signal SYS`。改为按 OS comptime 分支（Linux statx / 其它 fstat）。
- 测试中的 `/etc/hostname`（macOS 不存在）改为 `/etc/hosts`。
- **452→459 测试在 macOS 全绿。**

### Added
- **Headless 模式**：`-p "prompt"` / `--print` 单次运行后退出；`-` 从 stdin 读 prompt。
- **`--json`**：headless 下输出 NDJSON result 事件（stop_reason/turns/tool_calls/usage/text）。
- **`/model [name]`**：无参列当前 + 服务端 catalog；有参切换并重建 system prompt + 重算 max_tokens。
- **Grep 全局分页**：`offset` + 全局 `head_limit`（替代之前每文件 `-m`）+ `appliedLimit` 翻页提示。

## Historical — cc-zig v1.0.0 (2026-04-20, legacy internal numbering)

cc-zig 线的首个内部可用版本；该版本号属于历史 cc-zig 项目，与本仓库的
`0.1.0` semver 无关。从 TypeScript 版 Claude Code 移植到当时的 Zig dev 工具链
（现行工具链契约见 `build.zig.zon`）。

### Highlights

- **真流式 SSE**：基于 `std.Io.Reader.takeDelimiter`，首字节延迟与网络实时性一致；不再有 4MB 一次性加载
- **AbortSignal**：Ctrl+C 在 ≤ 250ms 内切断 HTTP stream 和正在运行的子进程（SIGTERM → 2s → SIGKILL，setpgid 防孤儿）
- **6 个内建工具**：Read / Write / Edit / Glob / Bash / Grep，全部对齐 TS 版参数
- **MCP 客户端**：stdio transport + JSON-RPC 2.0，动态注册到 registry
- **Skills 体系**：`~/.cc-zig/skills/<name>/SKILL.md` + 项目级覆盖 + system prompt 注入 + Skill 工具按需激活
- **REPL 增强**：termios raw mode、行编辑（↑↓←→/Home/End/Ctrl+A/E/U/K）、命令历史文件持久化、多行输入（`\` 续行 / `"""` 块）、Markdown 渲染
- **配置持久化**：`~/.cc-zig/config.json`
- **Subagent**：嵌套 agent 执行接口
- **Compact**：对话历史压缩（诚实 MVP：丢最老一半，不假摘要）

### 数据

| 指标 | 值 |
|---|---|
| 测试 | **294/294 绿** |
| ReleaseSmall 二进制 | **588K** |
| 启动时间 | < 10ms |
| 代码行数 | 7434 行 |
| 源文件数 | 44 |
| main.zig | 121 行 |

### 里程碑回顾

| M | 成果 |
|---|---|
| M0 结构重组 | 2432 行单体 → 27 文件分层，消除 `__TOOL_RESULT__:` hack，修复 `unescapeString` 内存 bug |
| M1 真流式 + Abort | EventIterator、AbortSignal、SIGINT、setpgid 子进程清理 |
| M2 工具参数对齐 | ToolContext 签名改造、Read offset/limit、Grep 9 参数、Bash timeout、Edit MultipleMatches |
| M3 权限 | 骨架就绪（M0.6），完整实现延后到沙箱阶段 |
| M4 REPL 增强 | 行编辑、历史、Markdown、多行、/retry / /compact |
| M5 MCP + Skills | stdio transport + JSON-RPC 2.0 + DynRegistry；SKILL.md 加载 + 发现 + 激活 + /skills |
| M6 配置 + Subagent + Compact | config.json 持久化、spawnAgent API、Conversation.compact |
| M7 v1.0 发布 | 全测试绿、文档更新 |

### 已知限制

- 权限系统只做 bypass/plan/deny-dangerous 骨架，完整决策树延后到沙箱版本
- Compact 采用"丢最老一半"策略，不调 API 生成摘要
- 分页（less 风格）未实现
- 语法高亮、文件名 Tab 补全未实现
- Windows/macOS 未验证（开发环境 Linux only）

### 参考

当时引用的架构计划、工作记忆与 TypeScript 原版参考均属 pre-extraction
monorepo,已不在本仓库;需要时从提取前的历史仓库查阅。
