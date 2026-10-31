# AgentCore SDK

This directory contains source-free host bindings for the experimental AgentCore
C ABI v1 revision 26:

- `metask/agentcore.h` — normative C11/C++17 layout declarations;
- `zig/` — typed Zig consumer bindings;
- `rust/` — Rust sys bindings and build integration;
- `python/` — the `metacodes` Python package: a ctypes binding over the shared
  library with a high-level Runtime/Session API, Python tools, events and
  permission handling ([python/README.md](python/README.md));
- `node/` — the `metacodes` Node package: a Node-API addon over the shared
  library with the same API shape for JavaScript ([node/README.md](node/README.md));
- `VERSION` — AgentCore's own SemVer version, distinct from the main project's
  and from the ABI revision. Every package carries it; `agentcore-releases.json`
  maps each release to its ABI revision and to the metacodes releases that ship it
  ([doc/RELEASE_AUTOMATION_DESIGN.md](../doc/RELEASE_AUTOMATION_DESIGN.md) §2a);
- `CHANGELOG.md` — AgentCore's changes and migration steps. A change a Host can
  see gets an entry here.

Do not copy individual files into a release. Consume the complete generated bundle
and validate its manifest, hashes, target, ABI version, exact 80-byte root, all
seven mandatory typed tables, function slots, and reserved fields. Revision 26 is
the Agent Runtime surface; it does not expose an independent Completion client.
`SessionCreateConfigV1.prompt_profile` edits the named system-prompt sections
(replace the identity, add Host sections; governance sections stay locked) and
is frozen into the Session and its checkpoints; `session_control->set_prompt_profile`
replaces it while idle. `RunOptionsV1.context_blocks` adds volatile Host facts to
one Run as user-role context instead of system-prompt text.
`session_control->update_permission_mode` changes an existing Session's
permission mode in place while idle: same handle and Conversation, a new policy
generation, every Session grant revoked; `describe` reports `permission_mode`.
`session->update_credential` replaces a Session's provider credential in place,
idle or during a Run, from any thread or callback: every request sent afterwards
(later turns, retries, compaction, Skills, tool providers, requests still
waiting for a connection) carries it, a request already sent keeps the old one, and provider,
scheme, `base_url` and model stay; refusals keep the previous credential.
`session->submit_input` hands the active Run more user text from any thread or
callback; the Run appends it at its next turn boundary and reports each
adoption as `input_adopted`, and `RunResultV1.input_accepted_count` /
`input_adopted_count` reconcile every submitted input on every return.
`skill->resolve_catalog` merges the default `.agents/skills` sources with up to
64 Host-registered sources. Their source priorities (`SkillSourceV1.priority`,
`SkillCatalogQueryV1.default_user_source_priority` and
`default_workspace_source_priority`, all 0 by default) rank same-scope sources
that define one Skill name: the higher one wins instead of both becoming a
`source_conflict`. Workspace still beats User, and a tie at the top still
conflicts.
`session_run_input` accepts text, typed Skill, and multimodal inputs; a
`RUN_INPUT_MULTIMODAL` Run submits an ordered `RunInputPartV1` array of text and
base64 image parts, preflighted against the Session model's image capability.
Every Run's context leads with today's date and time zone unless the Host
supplies its own `currentDate` block or sets `RunOptionsV1.time_context_code`
to `TIME_CONTEXT_OFF`; `TIME_CONTEXT_UTC_OFFSET` dates the Run in
`utc_offset_minutes` instead of the process's zone.
`SessionHostConfigV1.model_capabilities` lets the Host declare which of its
models take image input; a declaration outranks the built-in model-family
table, holds across `set_model` and restore, and `describe` reports the answer
with its source. An image Run for a model nothing covers is refused as
`IMAGE_INPUT_CAPABILITY_UNKNOWN` (29), distinct from `IMAGE_INPUT_UNSUPPORTED`
(28).
The `goal` table gives a Session one objective with an optional token budget:
`get` writes it as JSON, `set` replaces it, `update` changes objective, budget
and status together or not at all, and `clear` removes it. A
`RUN_INPUT_GOAL_CONTINUATION` Run, whose input the runtime writes from the
goal, works toward it; every Run that begins on an active goal is charged to
it, `goal_updated` events report the budget running out and each Run's
settlement, and checkpoints carry the goal. Refusals are `GOAL_CONFLICT` (30).
The `team` table gives a Session its host-scheduled team (issue #277): with
`RuntimeConfigV1.enable_teams` the team tools (`TeamCreate`, `TeamDelete`,
`SendMessage`, `SpawnTeammate`) enter the catalog and a lead or member Session
carries a `SessionHostConfigV1.team`. `describe` writes the roster and pending
spawn requests as JSON; `poll` takes the lead's next queued input, marked read.
AgentCore runs no teammate threads — the Host creates the member Sessions a
lead's pending spawns name.
`SessionHostConfigV1.protocol_kind_code` is provider-scoped: zero preserves the
provider default, while OpenAI may explicitly select
`OPENAI_PROTOCOL_RESPONSES`. Pair it with `provider_kind_code`, the full endpoint
override in `base_url`, and the Session model; no URL/model inference occurs.
Hosts that load a library at run time (Python `ctypes`, Node FFI, JNA, .NET
P/Invoke) use the bundle's shared library (`lib/libmetask_agentcore.so`,
`.dylib`, or `metask_agentcore.dll`) and resolve `metask_agentcore_get_api`;
`shared_library` in `manifest.json` records its digest-pinned path, load name
and needed system libraries.
Build and exercise a native bundle with:

```sh
zig build agentcore:gate -Dtarget=<native-target> -Doptimize=ReleaseSafe
```

Normative semantics and the support matrix are in
[`doc/AGENTCORE_BINARY_ABI.md`](../doc/AGENTCORE_BINARY_ABI.md).
