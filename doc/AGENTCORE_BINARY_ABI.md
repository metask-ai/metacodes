# AgentCore binary library ABI v1

The AgentCore bundle is a thin binary facade over the existing internal
execution engine. Consumers do not add implementation source to their build
graph, and the Host owns all UI. AgentCore is versioned and distributed as an
independent component; this ABI does not expose or define any host product.

ABI v1 is an experimental in-process embedding contract for synchronous,
stateful AgentSession execution. It does not expose or define a host product
model.

**Status: experimental.** Revision 26 is one exact hard-cut Agent Runtime wire
shape. It keeps the existing checkpoint/restore, durable budget, MCP
Runtime/Session seams, Workspace Skill source/identity/policy binding,
hash-pinned process-tool packages, Host/MCP byte-zero Tool Result streaming,
active-Run intent/result journal, Revision 15's multimodal Run input,
Revision 17's per-file `file_target` Session grants, and Revision 18's Host
control of the system prompt (see "System prompt profiles and context
blocks"): `SessionCreateConfigV1.prompt_profile`,
`session_control->set_prompt_profile`, `RunOptionsV1.context_blocks`, and the
`prompt_manifest` observation event, Revision 19's
`session_control->update_permission_mode` (see "Permission mode updates"), and
Revision 20's `session->submit_input` with the `input_adopted` event and the
`RunResultV1` input counts (see "Active-Run input"), and Revision 21's Host
model-capability declarations (`SessionHostConfigV1.model_capabilities`,
`ModelCapabilityV1`, status 29 `IMAGE_INPUT_CAPABILITY_UNKNOWN`, and the
described `image_input`; see "Model capabilities"), and Revision 22's time
context (`RunOptionsV1.time_context_code` and `utc_offset_minutes`, and by
default a `currentDate` block leading every Run's context; see "Time
context"), and Revision 23’s Session goal (the `goal` table with `get`,
`set`, `update` and `clear`, the `RUN_INPUT_GOAL_CONTINUATION` input kind,
status 30 `GOAL_CONFLICT`, the `goal_updated` event and checkpoint marker 10;
see "Goals"), and Revision 24's host-scheduled team (see "Teams"): a seventh
root table, `team`, with `describe` and `poll`; the
`RuntimeConfigV1.enable_teams` flag that admits the team tools (`TeamCreate`,
`TeamDelete`, `SendMessage`, `SpawnTeammate`) to the catalog; and the
`SessionHostConfigV1.team` membership (`TeamConfigV1`, with `TEAM_ROLE_LEAD`
and `TEAM_ROLE_MEMBER`), Host-supplied at create and restore with no
checkpoint state, and Revision 25's `session->update_credential` (see
"Credential updates"), which replaces an existing Session's provider
credential in place, while idle or during a Run, from any thread or from the
Session's own callbacks, and the `MAX_CREDENTIAL_BYTES_V1` limit. Over
Revision 25 it adds Skill source priorities (#390, see "Skill catalog and
typed input"): `SkillSourceV1.priority` and the
`SkillCatalogQueryV1.default_user_source_priority` and
`default_workspace_source_priority` fields rank same-scope sources that define
one invocation name, where Revision 25 could only report them as a
`source_conflict`. They take former reserved words; zero keeps Revision 25's
resolution. No table, struct, or descriptor changes size, and the root stays
80 bytes. Revision 16 stays
skipped: it named the withdrawn first-class PDF input on `main`, and a
revision keeps a single meaning. The independent public Completion facade
stays removed. This is not a general v1 stability promise.

Consumers must pin an exact bundle (the manifest records the source commit)
and treat a different revision as incompatible. Layouts, numeric values,
function-table order, and semantics may change only through another explicit
revision cut while v1 remains experimental.

The current experimental bundle is **ABI v1 revision 26**. Revision 26 is a
hard-cut replacement for every earlier revision. The root is no longer a
capability-tagged flat table. It is an 80-byte exact layout containing the
stable 16-byte discovery prefix, `buffer_release`, and seven non-null typed
table pointers. Every table is mandatory at discovery; consumers simply avoid
calling domains they do not use. There is no `query_interface`, string ID,
optional-capability negotiation, or compatibility shim:

- `metask_agentcore_api_v1` is 80 bytes and requires `abi_revision == 26`;
- Runtime, Session, Session Control, Skill, MCP, Goal, and Team tables are
  respectively 24, 56, 80, 32, 40, 40, and 24 bytes;
- the root plus child tables expose 31 functions: root `buffer_release` and
  30 domain slots;
- `MAX_CREDENTIAL_BYTES_V1` (16 KiB) bounds one `update_credential` candidate;
- `RuntimeConfigV1`, `SessionHostConfigV1`, `SessionCreateConfigV1`,
  `SessionRestoreConfigV1`, `RunInputV1`, and `RunResultV1` are respectively
  96, 168, 64, 64, 104, and 72 bytes on the required 64-bit ABI;
  `RuntimeConfigV1` replaces one reserved word with `enable_teams` (offset 64),
  the flag that admits the team tools.
  `RunInputPartV1` is 72 bytes, and `RunInputV1` replaces two former reserved
  words with the `parts` pointer (offset 72) and `part_count` (offset 80) of
  the multimodal input kind; `RunResultV1` replaces its first reserved word
  with `input_accepted_count` (offset 40) and `input_adopted_count`
  (offset 44);
- `SubmittedInputV1` and `InputReceiptV1` are respectively 48 and 24 bytes;
- `PromptSectionV1`, `PromptProfileV1`, and `ContextBlockV1` are respectively
  72, 56, and 56 bytes; `SessionCreateConfigV1` replaces one reserved word with
  the nullable `prompt_profile` pointer (offset 32), and the 40-byte
  `RunOptionsV1` replaces two with the `context_blocks` pointer (offset 8) and
  `context_block_count` (offset 16), and its next with `time_context_code`
  (offset 24) and `utc_offset_minutes` (offset 28);
- `ProcessPluginSourceV1` and `RuntimePluginConfigV1` are respectively 48 and
  72 bytes; `HostResultSinkV1` and `HostStreamToolV1` are respectively 56 and
  96 bytes; the single `runtime->create` takes a nullable plugin config, where
  null and an empty valid config both mean no extra plugins;
- `McpConnectorV1` and `McpServerV1` are respectively 88 and 232 bytes;
  `McpResponseV1` is 40 bytes and carries the final HTTP status beside its
  Host-owned bounded control-frame body;
  `request` remains the bounded control-frame operation and
  `request_tool_stream` is mandatory for `tools/call`;
- checkpoint, restore, describe, MCP refresh/describe/apply/selection,
  Permission rule and mode update, compact, abort, submit_input, and
  update_credential entries are mandatory;
- `SkillSourceV1`, `SkillPolicyV1`, and `SkillCatalogQueryV1` are respectively
  64, 56, and 80 bytes; `SkillSourceV1` replaces its first reserved word with
  the `int32_t` `priority` (offset 40) and a zero `reserved0` (offset 44), and
  `SkillCatalogQueryV1` its last reserved word with the `int32_t`
  `default_user_source_priority` (offset 72) and
  `default_workspace_source_priority` (offset 76);
- public status code 26 is a permanent tombstone; decoding it yields unknown,
  while `SKILL_CATALOG_INCOMPLETE` remains 27, `IMAGE_INPUT_UNSUPPORTED`
  is 28, `IMAGE_INPUT_CAPABILITY_UNKNOWN` is 29, and `GOAL_CONFLICT` is 30;
- `SessionHostConfigV1` stays 168 bytes and replaces two of its three reserved
  words with the `model_capabilities` pointer (offset 144) and
  `model_capability_count` (offset 152), and its last reserved word with the
  nullable `team` pointer (offset 160); `ModelCapabilityV1` is 40 bytes;
- `GoalSetV1` and `GoalUpdateV1` are respectively 56 and 64 bytes;
- `TeamConfigV1` is 88 bytes; `TeamApiV1` is 24 bytes;
- `manifest.json` keeps schema version 1 and records revision 26 and root size
  80. Child-table validation belongs to ABI discovery and is not duplicated in
  bundle metadata.

Revision 26 provides no earlier AgentCore revision compatibility, shim, dual dispatch, or old
table layout. Consumers update the header, SDK, manifest, and library
atomically, validate the stable
`struct_size`/`abi_version` prefix before reading later fields, then validate
the exact root and every child table before publishing a safe API. Every
per-Run callback validates and copies any retained `RunContext`
fields during the callback, and Host registries bind/compare `session_id`
atomically under their per-Session lock.

Revision 26 deliberately exposes explicit process-package sources, their
namespaced `host_tool` contributions, and explicit Host stream-tool
descriptors. It does not expose the generic
data/static plugin grouping model or `metacodes.plugin-inventory/v1`; those
remain available through the source-level Zig Runtime plus CLI/Web JSON Host
interfaces. Projecting generic inventory into this binary table requires a
later explicit ABI revision. A revision-26 consumer must not infer plugin
identity from tool or Skill names, and every reserved field remains zero.

### Revision 26 table topology

The root layout is exact on the required 64-bit pointer ABI:

| Offset | Field | Contract |
|---:|---|---|
| 0 | `struct_size` | exactly 80 |
| 4 | `abi_version` | exactly 1 |
| 8 | `abi_revision` | exactly 26 |
| 12 | `reserved0` | zero |
| 16 | `buffer_release` | non-null function |
| 24 | `runtime` | non-null 24-byte table |
| 32 | `session` | non-null 56-byte table |
| 40 | `session_control` | non-null 80-byte table |
| 48 | `skill` | non-null 32-byte table |
| 56 | `mcp` | non-null 40-byte table |
| 64 | `goal` | non-null 40-byte table |
| 72 | `team` | non-null 24-byte table |

Each child begins with `{uint32_t struct_size, uint32_t reserved0}` followed by
these mandatory slots in this order:

| Table | Ordered function slots |
|---|---|
| Runtime | `create`, `destroy` |
| Session | `create`, `destroy`, `run_input`, `abort`, `submit_input`, `update_credential` |
| Session Control | `restore`, `describe`, `set_model`, `update_permission_rules`, `compact`, `abort_compact`, `export_checkpoint`, `set_prompt_profile`, `update_permission_mode` |
| Skill | `resolve_catalog`, `release_catalog`, `bind_policy` |
| MCP | `apply_configuration`, `refresh`, `describe`, `update_selection` |
| Goal | `get`, `set`, `update`, `clear` |
| Team | `describe`, `poll` |

A validator first checks non-null root alignment and only the stable
`struct_size`/`abi_version` prefix. It may read later root fields only after the
exact 80-byte/version check, and may dereference a child only after that child
pointer is non-null and aligned. Wrong revision, reserved values, child sizes,
or any null slot reject the entire discovery. The 280-byte Revision 13 root and
the 64-byte Revision 14 through 22 roots and the 72-byte Revision 23 root
therefore fail at root size without an out-of-bounds read. The 80-byte
Revision 24 and 25 roots and a reference layout of the same size fail at the
revision check, since none carries 26; a Revision 24 Session table is also 8
bytes short of the 56 of Revisions 25 and 26, as a Revision 19 Session table
was of the 48 of Revisions 20 through 24. A Revision 25 root has Revision 26's
table and struct sizes and is told apart only by its revision; a Revision 25
library would reject the Revision 26 source priorities as nonzero reserved
words.

A future stability freeze first requires closure of the open items tracked in
`doc/AGENTCORE_V1_EXPERIMENTAL_LEDGER.md` (every group A item closed; every
group B item given an explicit disposition, with B1/B3 fixed or formally
argued). Only then do the two independent gates apply:

1. **Reference-closure audit** — every identifier, handle, or key the ABI
   hands to the Host must have a documented way for the Host to obtain or
   resolve it. Any dangling reference fails the audit.
2. **Real-consumer gate** — at least one consumer not written by the library
   authors exercises the claimed capability matrix (multiple concurrent
   Sessions × runtime-level Host tools × cross-thread abort) against the
   candidate surface.

## Build and verify

Use the repository-pinned Zig toolchain and an explicit target. A cross-target
bundle build compiles and link-checks source-free Zig, C, and C++17 consumers
without trying to execute foreign binaries:

```sh
zig build agentcore:bundle \
  -Dtarget=x86_64-windows-msvc \
  -Doptimize=ReleaseSmall
```

On a matching native host, the delivery gate runs the ABI tests, creates the
bundle, links the source-free consumers, and executes them:

```sh
zig build agentcore:gate \
  -Dtarget=x86_64-windows-msvc \
  -Doptimize=ReleaseSmall
```

`agentcore:gate` and `agentcore:consumer` require an explicit target that can
run on the current host. They fail during graph construction for a foreign
target and direct cross-target validation to `agentcore:bundle`.

To keep a validation run isolated from previous output, use a new empty prefix.
For example, on a native macOS arm64 host:

```sh
prefix=$(mktemp -d)
zig build agentcore:gate --prefix "$prefix" \
  -Dtarget=aarch64-macos.13.0 \
  -Doptimize=ReleaseSafe \
  -Dagentcore-strip=true
```

`--prefix /absolute/path` changes the install prefix. The target-specific
bundle root is nested below it so different resolved targets cannot overwrite
each other:

```text
<prefix>/agentcore/<resolved-target>/
├── lib/<target static-library filename>
├── lib/<target shared-library filename>
├── bin/rg[.exe]
├── bin/ripgrep-LICENSE-MIT
├── include/metask/agentcore.h
├── bindings/zig/
│   ├── build.zig
│   ├── build.zig.zon
│   └── src/{root,protocol,types}.zig
├── bindings/rust/
│   ├── Cargo.toml
│   ├── Cargo.lock
│   ├── link.cfg
│   ├── build.rs
│   ├── examples/link_probe.rs
│   └── src/{lib,raw}.rs
├── README.md
└── manifest.json
```

The manifest records vendor/component identity, package and source identity,
the package target plus producer Zig and Cargo targets, optimization and strip
settings, binary ABI status/version/revision, system link requirements, the
shared library record, the declared runtime assets, and SHA-256 for every
shipped file. The source-free
consumer validates those fields,
the complete manifest file whitelist, and every declared payload hash, then
applies the declared link inputs to every language probe. Bundles require an
explicit `-Dtarget=<triple>` so an artifact cannot silently inherit the build
host. Files outside the manifest are local staging residue, not compatibility
surface: consumers ignore them and the archive command never includes them.

`bin/rg[.exe]` is the ripgrep runtime asset backing the built-in `Glob`/`Grep`
tools. Bundle assembly stages it from the repository's manifest-pinned vendored
set (`vendor/ripgrep/manifest.json`, upstream official release binaries,
SHA-256 verified at staging), records it in the manifest `files` whitelist, and
declares it under `runtime_assets` (name, upstream version and revision, path,
license, role); the MIT license text ships beside it as
`bin/ripgrep-LICENSE-MIT`. A target with no vendored ripgrep artifact fails
bundle assembly instead of shipping tools that cannot execute;
`aarch64-windows` deliberately maps to the x86_64 executable, which
Windows-on-ARM runs through its built-in x64 emulation. Hosts deploy the file
next to their own executable (that location is probed automatically) or point
`RG_BIN` at it.

`agentcore:bundle` cross-compiles one bundle per explicit target and link-checks
source-free Zig, C, and C++17 consumers against the installed artifacts. The
static library filename comes from Zig `out_filename` for that target (`.a` or
`.lib`) and is recorded in the manifest. The Windows/MSVC archive also exports
the `unlink`, `mkdir`, `rmdir`, `access`, `chdir`, and `getcwd` CRT spelling
shims needed by the current implementation. The x86_64 Windows/GNU archive
exports a strong `roundq`: bundled `compiler_rt` defines it weakly, GNU ld does
not load an archive member for a weak definition, and MinGW's libraries do not
provide it. These link-visible support symbols are not AgentCore ABI entry
points and carry no consumer stability promise; consumers must not call or
otherwise depend on them.

Every bundle also carries the same library as a shared library for Hosts that
can only load one at run time (Python `ctypes`, Node FFI/`koffi`, JNA, .NET
P/Invoke): `lib/libmetask_agentcore.so`, `lib/libmetask_agentcore.dylib`, or
`lib/metask_agentcore.dll`. A Host loads that file (on Windows with
`LoadLibraryEx` and `LOAD_WITH_ALTERED_SEARCH_PATH`, or with the DLL's
directory on the search path), resolves `metask_agentcore_get_api`, and from
there uses exactly the C ABI above; the library must stay loaded while any
Runtime it created exists. Its only ABI export is `metask_agentcore_get_api`
(ELF hides everything else with a version script). Two toolchain names are
also present and inert: Zig exports its DLL entry point `_DllMainCRTStartup`
from a Windows DLL, and its Mach-O linker exports the synthesized
`__mh_dylib_header` and `___dso_handle`; none is callable ABI. The macOS
install name is `@rpath/libmetask_agentcore.dylib`, the ELF soname
`libmetask_agentcore.so`. The manifest's `shared_library` records the path
(also pinned in `files`), `entry_point`, that load name (`install_name`, null
on Windows) and `needed`, the libraries the loader must find, read from the
built image. Bundle assembly refuses a shared library that exports anything
else or needs anything a clean installation of its OS lacks, with one
exception: an MSVC-ABI DLL needs the Visual C++ runtime (`VCRUNTIME140.dll`),
which its Host provides (Python ships it); the `x86_64-windows-gnu` release
bundle needs only Windows system DLLs. The native gate runs the C consumer a
second time against the shared library through `dlopen`/`LoadLibraryEx`, with
no AgentCore link input, from discovery through a complete Run.
`agentcore:consumer` additionally runs the resulting programs, while
`agentcore:gate` combines that native consumer check with the ABI test suite
and runs the Rust ABI link probe plus crate unit tests. macOS bundles are
repacked from their object members with Apple `ar`/`libtool` before manifest
hashing; this preserves bundled `compiler_rt` while satisfying Apple `ld`'s
8-byte Mach-O archive-member alignment. A non-macOS build host therefore fails
closed instead of publishing a macOS AgentCore archive it cannot normalize.

`agentcore:rust` builds and links the bundled `metask-agentcore-sys` link probe.
Its `build.rs` reads the generated `link.cfg` line format instead of parsing the
full bundle manifest; the manifest remains the source of the projected target
and system-link values.
The checked-in raw Rust declarations are regenerated with bindgen 0.72.1 using
the fixed `x86_64-unknown-linux-gnu` Clang layout target and hermetic minimal
standard-type headers, so regeneration does not inherit the build host target.
`agentcore:archive` creates a coordinate-rooted Windows zip or Unix tar.gz from
only the manifest whitelist plus `manifest.json`, and writes an adjacent
SHA-256 file; it rejects an existing coordinate instead of overwriting it.

Current delivery status is intentionally target-specific:

| Target | Bundle/archive | Native source-free consumption |
|---|---|---|
| `aarch64-macos` | revision 25 ReleaseSafe bundle archived and gated by a `release.yml` dry run (`macos-latest`, run 40787422095, 2026-10-28); revision 24 ReleaseSafe bundle, schema-1 manifest, public-symbol, and source-free link gates passed locally (2026-10-17); revision 26 not revalidated | revision 25 native gate passed in run 40787422095; revision 24 native gate passed locally (2026-10-17): C and Zig source-free consumers (Session goals: the C one sets a goal, runs a goal-continuation Run whose runtime-written input the mock finds, sees it charged and is refused once the goal is paused; the Zig one carries a goal across checkpoint and restore over OpenAI Responses and keeps charging it; time context with a Host UTC offset; Host model-capability declarations; both submitting input to an active Run; host-scheduled teams: both consumers create a team member Session and read its roster through `team->describe` and its empty inbox through `team->poll`, and the L2 suite drives a lead delegating by `SpawnTeammate` and a member replying through the public ABI), C/C++ header compile, Rust SDK tests and link probe, including multimodal, fresh/restore and continued Runs; revision 26 not revalidated |
| `x86_64-windows-msvc` | revision 26 ReleaseSafe bundle, schema-1 manifest, public-symbol, and source-free link gates passed locally (2026-10-29), revision 25 on 2026-10-28; CI (`agentcore-windows.yml`, GitHub-hosted `windows-latest`) builds and gates it | revision 26 native gate (`zig build agentcore:gate -Dtarget=x86_64-windows-msvc -Doptimize=ReleaseSafe`) passed locally (2026-10-29): both source-free consumers, the Rust crate tests and the ABI suite, including the Workspace Skill source-priority L2 test; revision 25 native gate passed locally (2026-10-28): the C consumer, statically linked and loading the DLL, rotates the provider credential from inside its Host stream tool callback mid-Run and again while idle, the Zig consumer does the same from its Host tool callback, and each consumer's loopback provider sees the creation, rotated and idle credentials in that order; revision 24 passed in CI on `main` at `7efc170d` (run 39107702062, 2026-10-18); the workflow repeats the gate on every push to `main` and on pull requests touching the native-gate paths |
| `aarch64-windows-msvc` | revision 14 evidence retained; revision 26 not revalidated | native revision 26 gate pending |
| `aarch64-windows-gnu` | revision 14 evidence retained; revision 26 not revalidated | native revision 26 gate pending |
| `x86_64-windows-gnu` | revision 25 ReleaseSafe bundle archived by a `release.yml` dry run (`windows-latest`, run 40787422095, 2026-10-28) | revision 25 native gate passed in that run (revision 19 in the 0.5.0 release run 38111469169); revision 26 pending until the next release run |
| `x86_64-linux-gnu` | revision 25 ReleaseSafe bundle archived by a `release.yml` dry run (`ubuntu-latest`, run 40787422095, 2026-10-28) | revision 25 native gate passed in that run (revision 19 in the 0.5.0 release run 38111469169); revision 26 pending until the next release run |
| `aarch64-linux-gnu` | revision 25 ReleaseSafe bundle archived by a `release.yml` dry run on GitHub's hosted arm64 Linux runner (`ubuntu-24.04-arm`, run 40787422095, 2026-10-28, #307) | revision 25 native gate (`zig build agentcore:gate`, Rust triple `aarch64-unknown-linux-gnu`) passed in that run; revision 26 pending until the next release run |
| `x86_64-macos` | revision 25 ReleaseSafe bundle archived by a `release.yml` dry run on GitHub's hosted Intel macOS runner (`macos-15-intel`, run 40787422095, 2026-10-28, #307) | revision 25 native gate (`zig build agentcore:gate`) passed in that run; revision 26 pending until the next release run |

Cross-build success is not a support claim. In particular, the empty macOS
framework list remains provisional until the corresponding native gates pass.
This validation status is not an ABI restriction.

Revision 26 hard-cuts the current schema-1 manifest contract in place. The
manifest records the exact ABI version, revision, and root size, while runtime
discovery validates all seven mandatory child tables. There is no manifest
migration, dual parser, capability negotiation, or duplicated child-table
inventory; earlier-revision bundles are rejected by their recorded revision,
and Revision 13 additionally by root size.

ReleaseSafe bundles strip DWARF by default; the explicit
`-Dagentcore-strip=true` in the release command pins that policy in build
automation. Debug symbols belong in a separately retained symbols artifact,
not in the consumer bundle.

## Typed Zig SDK

The shipped Zig SDK remains source-free. `bindings/zig/src/types.zig`
contains the raw ABI declarations plus validated `Status` and `StopReason`
enums. `bindings/zig/src/protocol.zig` owns the ABI v1 `CoreEvent`,
`UiRequest`, `UiResponse`, and Skill-catalog wire types, their typed decoders,
the request-aware UI response encoder, and the bounded Skill-arguments
encoder. `bindings/zig/src/root.zig` re-exports both layers beside raw API-table
access.

`decodeCoreEvent` returns an owned `ParsedCoreEvent` whose value is either
`known: CoreEvent` or `unknown: { tag, payload_json }`. This lets an older Host
ignore or retain a valid observation event added by a newer ABI-v1 library.
The common known-event path scans the top-level tag and performs one typed
parse; only an unknown tag pays for a dynamic JSON tree.
`decodeUiRequest` and `decodeUiResponse` remain strict because an unknown
control message cannot be answered safely. All decoded strings and arrays
remain valid until `deinit`; consumers must not copy an owner and deinitialize
both copies.

`decodeSkillCatalog` returns an owned `ParsedSkillCatalog` for
`metask.skill-catalog/v1`. Revision 15 hard-cut the current experimental shape
of that schema, and Revision 26 keeps it: every earlier unreleased experimental
shape bearing the same token is void, and consumers must interpret the
descriptor only with the exact bundle they pin. The decoder validates the
schema, the 1024-Skill limit, identity forms, duplicate concrete `skill_id` or
`skill_policy_key` records, health and issue consistency, and each Skill
argument schema. AgentCore remains the canonical producer and independently
enforces those uniqueness invariants before publication. Because decoded
strings and arrays are allocator-owned, the consumer may release the AgentCore
descriptor buffer immediately after decoding.
`encodeSkillArguments` accepts positional UTF-8 values, enforces the 64-value
and encoded 1 MiB limits, and returns the allocator-owned canonical
`{"values":[...]}` representation accepted by `sessionRunSkill`.

```zig
var parsed = try sdk.decodeCoreEvent(allocator, event_json);
defer parsed.deinit();
switch (parsed.value) {
    .known => |event| consume(event),
    .unknown => |event| retainOrIgnore(event.tag, event.payload_json),
}

var catalog = try sdk.decodeSkillCatalog(allocator, descriptor_json);
defer catalog.deinit();

const arguments_json = try sdk.encodeSkillArguments(
    allocator,
    &.{ "src/main.zig", "deep" },
);
defer allocator.free(arguments_json);
```

Known payloads accept additive fields. Multiple tags, duplicate tags, malformed
JSON, and invalid known payloads are rejected. Adding an optional field or a new
observation tag is compatible; removing a tag, changing a required field, or
adding a UI request/response tag is breaking and requires a new ABI. Opaque
JSON-bearing strings are not recursively interpreted by the SDK.

`encodeUiResponse` returns an allocator-owned buffer suitable for
`metask_agentcore_owned_bytes_v1`, rejects response tags that do not match the request, and
validates the answer count for `ask_question`.

The public `CoreEvent` schema is not the internal frontend/daemon union.
`src/agentcore/protocol_v1.zig` exhaustively maps internal events to the
v1 DTO before serialization. Presentation hints (`set_current_tool`,
`clear_current_tool`), implementation diagnostics (`diag_*`), and
App/daemon coordination events (`config_changed`, `session_lifecycle`,
`agent_lifecycle`, `tasks_changed`, `ui_request_pending`) do not cross the
ABI. Future internal event additions fail the adapter compilation until they
are explicitly mapped or excluded.

The v1 observation set is:

| Semantic group | Event | Meaning |
|---|---|---|
| Assistant visible-output segment protocol | `output_segment_begin` | Opens one visible-output segment and identifies its Run-local index, turn, and continuation group |
| Assistant visible-output segment protocol | `text_chunk` | UTF-8 data delta belonging to the currently open visible-output segment |
| Assistant visible-output segment protocol | `output_segment_end` | Closes that segment with the authoritative `commentary` / `final` / `continued` / `partial` / `discarded` disposition and byte count |
| Model reasoning-channel observation | `thinking_chunk` | Model reasoning delta, outside visible-output segments and final-output reconstruction |
| Provider stream boundary and retry | `stream_done` | One Provider stream completed; not a segment, turn, or Run completion signal |
| Provider stream boundary and retry | `retry_notice` | Provider retry attempt and delay |
| Tool execution observation | `tool_start` | Tool invocation identity, name, and input |
| Tool execution observation | `tool_progress` | Incremental progress text for one tool call |
| Tool execution observation | `tool_result` | Completed tool result, error flag, elapsed time, and optional successful file observations |
| Workspace modification evidence | `file_changes` | Per-file outcomes, locators, byte counts, and bounded unified diffs from one typed file-tool call |
| Run state and coarse progress | `run_state` | Root Run phase snapshot, per-Run transition sequence, turn/tool-call sample, and owned in-flight tool identities |
| Run state and coarse progress | `progress` | Current 1-based turn and cumulative tool-call progress sample; not a lifecycle boundary |
| Context management and accounting | `usage` | Token-usage delta |
| Context management and accounting | `context_warning` | Context-pressure thresholds and level |
| Context management and accounting | `auto_compact` | Conversation compaction summary |
| Permission-decision evidence | `permission_provenance` | Final Permission decision, canonical source, request binding, generation, and typed callback outcome |
| System prompt audit | `prompt_manifest` | The sections of the system prompt this Run sends (id, order, origin, class, SHA-256) and the prompt's SHA-256, when it differs from the previous Run's |
| Goal accounting | `goal_updated` | The Session's goal changed during this Run: its budget ran out (`budget_limited`), or the Run ended and its usage and time are on the goal; carries the whole goal as `goal->get` writes it (see "Goals") |
| Model failure detail | `model_error` | Why this Run stopped with `STOP_API_ERROR`: category, upstream code and type, displayable message, HTTP status, request id and retry guidance; exactly one, before the terminal `run_state` (see "Model failure detail") |
| Host input adoption | `input_adopted` | An input accepted by `submit_input` was appended to the Conversation before request `turn`; carries its `input_id` and receipt `sequence` (see "Active-Run input") |

Events describe observations, not commands. A Host may render, aggregate,
persist, or ignore them; consuming an event never drives the core execution
loop.

`on_event` is a non-durable Run observation stream delivered serially per
Session. A Host processes one Session's events in callback-arrival order, and
the callback is not concurrently re-entered for that Session even when events
originate from concurrent Tool workers. Different Sessions have no global
ordering and may invoke their callbacks concurrently. The stream has no common
event sequence number, cursor, replay, or exactly-once contract; only
`run_state.transition_seq` orders RunState snapshots.

`on_event` is mandatory in Revision 26. `run_state` is emitted for admitted-run
start, phase/tool-set/turn/tool-call changes, and terminal closure; it is not a
mirror of text or usage deltas. Its `transition_seq` starts at 1 for each Run
and advances only for emitted RunState snapshots. While the observation
channel stays usable, terminal closure is published exactly once, from the
Run's final result — an abort accepted from the `finalizing` callback is
reflected as `aborted`, a Run that never ran the loop still receives it, and a
post-admission cleanup failure closes it as `poisoned` — and it is delivered
even when tool-set observation was degraded. A Host that rejects any snapshot
(the terminal one included) fails the Run with `CALLBACK_FAILED` and poisons
the Session; a snapshot that could not be built fails it with the recorded
status (`OUT_OF_MEMORY`) the same way. No terminal snapshot is delivered after
that, and no later Run on that Session can report success. Usage remains authoritative
in the existing usage event stream.

Visible assistant output is bracketed by `output_segment_begin` and
`output_segment_end`. Their `index`, `turn`, and `group` match, at most one
segment is open in a Run, and `index` increases within that Run. Every
`text_chunk` belongs to the currently open segment. `thinking_chunk` is an
independent reasoning channel and never contributes to a visible segment or
final output. The closing `bytes` is the segment's UTF-8 byte count and its
disposition is authoritative:

- `commentary`: visible process output, not part of the completed answer;
- `continued`: retained pending another segment in the same `group`;
- `final`: completes the answer together with preceding `continued` segments
  in that group;
- `partial`: visible but incomplete output;
- `discarded`: rolled-back bytes that the Host must remove or ignore.

`stream_done` means only that one Provider stream ended; it neither closes nor
classifies an output segment. Hosts must not reconstruct final-output semantics
from Tool boundaries or Provider stop edges. Usage events are exact deltas and
must use checked arithmetic.

`file_changes` is emitted once for each typed file-tool call after the turn's
Tools have completed and before the corresponding `tool_result`. Its `id` is
the Tool-use identity used to correlate the two events. Each record carries a
typed destination locator, an optional source locator for moves, `kind`,
`status`, Tool identity, agent depth, before/after byte counts, and an optional
bounded unified diff. `rejected`, `failed`, and `no_change` records are evidence
of an attempted outcome, not claims that disk contents changed. `overflow` or
`lost` makes incomplete batch evidence explicit. This contract covers typed
file Tools only; filesystem mutations performed through `Bash` are not
observed by it.

Core file-change evidence may retain arbitrary file bytes, but AgentCore's JSON
boundary publishes `unified_diff` only as valid UTF-8. A diff whose only
invalidity is an incomplete trailing code point is shortened to its complete
UTF-8 prefix; any other non-UTF-8 diff is omitted. Both cases set
`diff_complete` to false while preserving the record, locator, outcome, byte
counts, and batch completeness flags. This normalization affects only the
serialized AgentCore observation and does not mutate Core-owned evidence.

`output_segment_begin` and `output_segment_end` are additive ABI-v1 observation
tags. Older Hosts decode them through the `unknown` observation path; no C ABI
layout, function table, or ABI revision change is involved.

`file_changes` is likewise an additive ABI-v1 observation tag. Its JSON bytes
are borrowed only for the synchronous callback; the Zig SDK decoder returns an
owned typed value. Older Hosts retain the event through the `unknown` path.

`thinking_chunk` is an additive ABI-v1 observation event. An older Host may
decode it through the `unknown` observation path and ignore or retain it in
accordance with the forward-compatibility rules above.

`tool_result.file_refs` is an optional Revision 26 observation field. It is
present only for successful selected built-in file-tool executions and contains
at most 32 entries. Each entry has one locator union (`workspace_path`,
`absolute_path`, or `uri`), an open-ended bounded `kind` string, a bounded
title, and an optional range whose `start`/`end` each contain 1-based `line`
and UTF-16 `column` positions (half-open). The v1 limits are 4096
bytes per path, 8192 bytes per URI, 256 bytes per title, and 64 bytes per kind.
The field is evidence only: the Host decides whether and how to open a target;
an absolute locator does not grant authorization. Failed, denied, rejected,
unobserved, or unavailable executions do not emit write-class references.

## Contract

`metask_agentcore_get_api(1)` is the only discovery symbol. ABI v1 exposes
opaque Runtime, Session, and Skill-catalog handles, synchronous typed Runs,
abort, built-in and synchronous Host tools, tagged CoreEvent JSON, and
synchronous Host UI JSON.
Runtime copies Host tool metadata and callback references and must outlive every
Session. The Host retains ownership of each Host tool `ctx` and keeps it valid
until Runtime destruction succeeds. Session owns provider credentials,
workspace inputs, tool selection, Conversation, permission memory, jobs, and
Run state and an optional retained catalog snapshot. Session callback
descriptors are copied at creation; the Host retains
their `ctx` and keeps it valid until Session destruction succeeds.

### Process-plugin Runtime configuration

Revision 26 uses one `runtime->create(runtime_config, plugin_config,
out_runtime, out_diagnostic)`. The Runtime config is required; the plugin
config is nullable. Null and an empty, well-formed `RuntimePluginConfigV1`
create equivalent no-extra-plugin generations. Descriptor arrays and path
bytes are borrowed only until the call returns. A successful Runtime owns an
immutable copy of all published plugin/tool state, while a failed call
publishes no Runtime.

`RuntimePluginConfigV1` accepts at most 64 `ProcessPluginSourceV1` records and
at most 1024 Host stream tools subject to the Runtime-wide tool ceiling. Each
source has an absolute UTF-8 package root and one exact layer code:
`BUILTIN`, `PERSONAL`, `PROJECT`, `SESSION`, or `MANAGED`. Higher layers win for
the same PluginId; duplicates at one layer, invalid dependencies, contribution
collisions, relative paths, symlinked package roots, malformed/reserved fields,
or any strict manifest/process/handshake failure reject Runtime creation. A
non-empty process source set fails closed on Windows in process protocol v1.

### Host byte-zero Tool Result streaming

`HostStreamToolV1` is a distinct descriptor rather than optional fields on
`HostToolV1`; one tool therefore cannot inhabit both the completed-buffer and
streaming states. The descriptor metadata is borrowed only during Runtime
creation and copied into the immutable Runtime. Its `ctx` remains Host-owned
until Runtime destruction succeeds.

For each admitted invocation AgentCore creates a private Session spool before
calling `execute_stream`. The callback receives one synchronous, borrowed,
write-only `HostResultSinkV1`. It may call `write` sequentially with arbitrary
byte slices, including empty slices, but must not retain the sink, use it from
another thread, or call it after `execute_stream` returns. AgentCore alone owns
commit and rollback authority. The sink reports exact `HOST_SINK_*` status:
aborted, over the 128 MiB artifact maximum, failed I/O, and closed are latched,
so later writes and an attempted successful return cannot hide an earlier
failure.

`HOST_OK` requires a known non-zero media code, canonical empty detail, and a
healthy sink. It always commits an artifact receipt—even when the payload is
small—so this registration type has one deterministic result shape. The
Conversation receives only the stable content-addressed envelope, SHA-256,
length, media type, and fixed head/tail preview; no temporary or machine-local
path enters model input. Equal byte streams therefore produce equal model
input, and `ReadArtifact` is frozen into the Session tool directory before the
first provider request, preserving the prompt-cache prefix.

`HOST_FAILED`, `HOST_REJECTED`, `HOST_FATAL`, malformed status/media/detail,
callback errors, cancellation, and sink failures discard every partial byte
and publish no CAS object. Failure/rejection detail follows the existing
bounded UTF-8 ownership contract and is released exactly once; success detail
is illegal. A callback should stop producing immediately after a non-OK sink
status. `session_run_input` remains the callback quiescence boundary.

Each contributed provider name is the reversible namespaced global tool name,
is classified as native `execute`, and remains subject to Session selection,
Permission, budget and abort. Permission identity uses the existing public
`host` namespace plus a non-zero 32-byte binding derived from plugin id,
version, pinned executable SHA-256, global tool name and validated reserialized
input schema.
The binding—not the display name alone—enters Permission provenance and
checkpoint authority resolution. Process tools deliberately have no
`allow_session`/`deny_session` candidate in revision 26, so a Host may answer
only the offered one-shot choices unless an independent native rule decides
first. Changing executable/package/schema authority invalidates a restored
binding instead of silently reauthorizing the new implementation.

The child protocol, empty-environment behavior, entrypoint containment/hash
checks, handshake, framing, timeout/output caps, process-group cancellation and
reaping rules are normative in `PLUGIN_PROCESS_PROTOCOL.md`. This ABI is a
configuration path into that kernel-owned executor; it does not turn the child
into a Host callback or expose a raw kernel pointer.

One Session accepts one active Run at a time. A successful Run returns to idle
and the Host may start another Run on the same stateful Conversation. `Status`
describes whether the ABI call itself succeeded. `StopReason` is meaningful
only when `session_run_input` returns `METASK_AGENTCORE_STATUS_OK` and is one of `end_turn`,
`max_turns`, `aborted`, `tool_error`, `api_error`, `tool_loop`,
`checkpoint_budget_exhausted`, or `checkpoint_resource_limit`. The last two are
the public durable-budget terminals
`METASK_AGENTCORE_STOP_CHECKPOINT_BUDGET_EXHAUSTED` and
`METASK_AGENTCORE_STOP_CHECKPOINT_RESOURCE_LIMIT`; their detailed outcome is
also reported through `RunResultV1.checkpoint_outcome_code` and result flags.
The Core `stalled` stop (the stall gate ended a run whose tool rounds kept
returning nothing new) is a controlled breaker stop and is reported as
`tool_loop`. The Core `max_tokens_exhausted` stop (the provider still cut the
output at its max-token limit after the last allowed continuation) is a
provider outcome and is reported as `api_error`. Its terminal RunState is
`failed`, its visible text arrives as an output group that ends `partial`, and
the Session stays usable for the next Run. Internal `suspended`, `backgrounded`, and a raw unprojected Core `budget` stop
remain unrepresentable in v1. If one of those internal states reaches the
facade it is a contract failure, not an additional public stop code. Because
the stateful Run may already have committed Conversation changes, that failure
poisons the ABI facade and subsequent Run or abort calls return
`METASK_AGENTCORE_STATUS_INVALID_STATE`; destroy remains valid.

The synchronous `session_run_input` return is a quiescence boundary: every callback
started for that Run, and every paired release callback for its Host-owned
outputs, has completed before the call returns. Callbacks from the next Run on
the same Session therefore cannot overlap callbacks from the completed Run.
The facade keeps the Session call gate through result/diagnostic publication;
an overlapping Run or destroy returns `METASK_AGENTCORE_STATUS_BUSY`. Releasing that gate is
the completion linearization point, after which the completed call no longer
reads Session storage and destroy may free it. Matching `session_abort` bypasses
this gate so it can remain useful while the synchronous Run is active.
That exception permits overlap only with the matching Run. It does not permit
any later Session call to overlap an in-flight abort call.

`run_id` is a non-zero `uint64_t` Run identifier assigned by the Host and
scoped to one Session. Each admitted Run must have a `run_id` strictly greater
than that of the previously admitted Run in the same Session. Values need not
be contiguous, and different Sessions may use the same values. An admitted
`run_id` is consumed even if that Run is later aborted or fails during
execution; it must never be reused or wrapped. Rejection before admission never
advances the Session's last admitted `run_id`. An otherwise valid proposed
value strictly greater than the last admitted ID therefore remains available
for retry; zero and stale values do not become valid through retry. After
admitting `UINT64_MAX`, the Session cannot admit another Run and the Host must
create a new Session.

Every per-Run callback receives a borrowed `metask_agentcore_run_context_v1`. Its `session`
is the original public Session handle, its `run_id` is the admitted Run ID, and
its non-empty `session_id` is stable for that Session's lifetime and distinct
from every other live Session. The context and its `session_id` bytes are valid
only until that callback returns. A Host that retains identity must deep-copy
the bytes; pointer identity across callbacks is never promised. A shared Host
registry must bind the first observed ID and compare all later IDs atomically
under the same per-Session lock. A missing/invalid ID, unknown Session handle,
wrong active Run ID, or binding mismatch is a fatal callback-channel failure.

Run admission is the `run_id` lifecycle boundary. Validation failures
(`METASK_AGENTCORE_STATUS_INVALID_ARGUMENT` /
`METASK_AGENTCORE_STATUS_RESOURCE_LIMIT`) and admission failures
(`METASK_AGENTCORE_STATUS_BUSY` / `METASK_AGENTCORE_STATUS_STALE_RUN`) do not
mutate the Conversation or consume `run_id`. Skill materialization occurs
after admission but before Conversation mutation: failure there consumes
`run_id`, cleans the activation, and returns the Session to idle. Once
Conversation mutation or provider/tool execution begins,
`METASK_AGENTCORE_STATUS_OUT_OF_MEMORY`,
`METASK_AGENTCORE_STATUS_CORE_ERROR`,
`METASK_AGENTCORE_STATUS_CALLBACK_FAILED`, or
`METASK_AGENTCORE_STATUS_INTERNAL_ERROR` poisons the Session because execution
may have committed Conversation changes or external side effects. Subsequent
Run and abort calls then return `METASK_AGENTCORE_STATUS_INVALID_STATE`;
destroy remains valid. `METASK_AGENTCORE_STATUS_OK`, including a terminal
`METASK_AGENTCORE_STOP_ABORTED`, returns the Session to idle. A too-late abort
also leaves the already-idle Session reusable.

Durable pre-admission uses exact canonical records that are available without
effects: a Text prompt or a typed Skill invocation record. Skill body
rendering can read files or execute admitted shell injection, so it remains
after Run admission. Its exact durable delta is reconciled atomically before
Conversation mutation; input-cap excess becomes a resource-limit terminal and
insufficient durable capacity becomes budget-exhausted. AgentCore never moves
materialization or shell execution before admission merely to estimate bytes,
and it does not reserve the entire configured input cap for every Skill.

Given a valid Session handle, the poisoned-state check takes precedence over
remaining `session_run_input` and `session_abort` argument validation. ABI v1 does
not define status precedence when multiple other input or admission errors are
present in the same call.

ABI v1 provides no in-place recovery or mutation of a poisoned Session. The
Host must destroy that physical handle. Revision 26 checkpoint/restore creates
a new handle from a previously exported committed checkpoint; it does not
reconstruct state that was never successfully exported or resume an active
Run.

When facade poison occurs after Core has returned to an inspectable idle state,
`session_describe` succeeds and reports lifecycle `poisoned`; it must not report
`idle`. An active ordinary Session activity makes `session_describe` return
`METASK_AGENTCORE_STATUS_BUSY`, so a successful Revision 26 description does not
emit lifecycle `busy`.

A checkpoint is resumable model state, not a raw transcript archive. Before
compact it contains the complete Conversation. After compact it contains the
summary plus active messages and omits the hidden raw prefix already replaced
by that summary. Restore materializes the summary as leading assistant context,
so continued Runs and later compaction preserve the same model-visible state.
The checkpoint `max_messages` limit counts that materialized summary as one
message in addition to the encoded active-message count.

Conversation blocks are encoded with tag bytes `1=text`, `2=tool_use`,
`3=tool_result`, `4=thinking`, `5=image`, `6=reasoning_item`. An image block
carries two encoded strings, `media_type` then base64 `data`; raw image bytes
never enter the envelope, so every string still satisfies the UTF-8 validation
rule. A reasoning-item block also carries two encoded strings, the owning
`model` then the provider's verbatim item JSON (UTF-8 by construction: it is
the server's own wire text). Tags `5` and `6` are additive extensions:
checkpoints written before them decode unchanged, while an older reader that
encounters either fails closed with `Corrupt` instead of silently dropping
model-visible image content or provider reasoning continuity.

Tag `7` is permanently reserved and never written. It carried the document
block of the withdrawn first-class PDF input; a checkpoint containing one is
intact rather than damaged, so decoding reports `UNSUPPORTED` (schema this
build no longer supports) rather than `CORRUPT`, which would send a Host
hunting for storage faults. Integrity is established first: the block is
stepped over through the hasher in its revision-16 layout, the digest is
verified, and only then is `UNSUPPORTED` reported — a damaged file whose bytes
merely read as tag `7` still reports `CORRUPT`. The tag stays reserved because any build that ran
that revision could have written one, and reusing `7` for a different block
would silently misread those files.
Hosts that require verbatim historical audit must persist the event/transcript
stream separately. This projection is what allows compact to reduce durable
usage for a near-hard Session.

On a usable Session, `session_abort` requires a non-zero `run_id`; zero returns
`METASK_AGENTCORE_STATUS_INVALID_ARGUMENT`. While a Run is active, its exact `run_id`
requests cooperative abort and any other value returns
`METASK_AGENTCORE_STATUS_STALE_RUN`. While the Session is idle, the most recently admitted
`run_id` returns `METASK_AGENTCORE_STATUS_TOO_LATE` and any other value returns
`METASK_AGENTCORE_STATUS_STALE_RUN`. A poisoned Session returns
`METASK_AGENTCORE_STATUS_INVALID_STATE` regardless of the supplied ID.

### Model failure detail

`STATUS_OK`, `STOP_API_ERROR` and an empty diagnostic keep their meaning: the
call succeeded and the Run failed on the model. Every Run whose
`RunResultV1.stop_reason_code` is `STOP_API_ERROR` also delivers exactly one
`model_error` observation event, through its own `on_event` call and before its
terminal `run_state`, so a Host that has the result has the reason. No other Run
delivers one: a failed attempt that a retry recovered from reports nothing, and
a budget stop that outranks the loop's stop reports `STOP_CHECKPOINT_*` as
before. A Host that rejects the event fails the Run with `CALLBACK_FAILED`, like
any other observation.

`model_error` is an additive observation tag. It adds no C layout, function
slot or revision, and an older Host decodes it through the `unknown` path.

```json
{"model_error":{"run_id":7,"category":"rate_limited","code":"insufficient_quota",
 "type":"insufficient_quota","message":"You exceeded your current quota",
 "http_status":429,"request_id":"req_1","retry":"unknown","retry_after_ms":null,
 "attempts":1,"truncated":false}}
```

| Field | Meaning |
| --- | --- |
| `run_id` | The Run, equal to the callback's `RunContextV1.run_id` |
| `category` | One of the closed set below |
| `code` | The upstream's most specific identifier, verbatim up to the limit: `error.code`, else Gemini's `error.status`, else a numeric code in decimal, else `error.type`. Null if it sent none |
| `type` | The upstream's `error.type`, or null |
| `message` | Safe to display (see below). Never empty |
| `http_status` | The final response's status: the failing one, or 200 for a failure inside an accepted stream. Null when no response head arrived |
| `request_id` | From `x-metask-request-id`, `request-id`, `x-request-id`, `x-goog-request-id`, `x-amzn-requestid` or `x-ms-request-id`, in that order, else the error body's `request_id`. Null if none |
| `retry` | `retryable`, `not_retryable` or `unknown` |
| `retry_after_ms` | The failing response's `Retry-After`, when it sent one |
| `attempts` | Physical attempts of the request that failed, AgentCore's own retries included |
| `truncated` | A string above was cut at its size limit |

`category` describes the failure, from transport facts and the provider's
technical error types: `authentication` (401), `permission` (403),
`payment_required` (402), `not_found` (404), `invalid_request` (other 4xx and
3xx), `context_window`, `rate_limited` (429), `overloaded` (503, 529),
`server_error` (other 5xx), `timeout` (408, 504, and AgentCore's own head and
body idle limits), `connection` (no response head), `stream_interrupted` (an
accepted stream dropped, died or ended without saying how it stopped),
`output_limit` (`max_tokens_exhausted`, the one `STOP_API_ERROR` that is not a
failed request) and `unknown`.

AgentCore implements no billing, balance, quota or access rules. It does not
read meaning into `code`: the business answer is the Host's to draw from `code`
and `message`, and a code no release has seen passes through unchanged. Do not
branch on `category` for those decisions. An insufficient balance arrives as
402 on one provider, 429 on a second, and 400 or a stream frame on others, and
the category follows the status while `code` carries the fact.

`retry` is what AgentCore can stand behind for sending the same request again. A
server-sent `Retry-After` makes it `retryable`. A 408, 429 or 5xx is `retryable`
only when the upstream's code and type are absent or name a technical condition
(`rate_limit_error`, `overloaded_error`, `server_error` and the like); any other
code makes it `unknown`, because a 429 can be a burst limit or an exhausted
quota and only that code tells them apart. Other 4xx and 3xx are
`not_retryable`. An error frame is `retryable` or `not_retryable` when both its
identifiers are recognized and `unknown` otherwise.

All strings are bounded and sanitized before they reach the event: `code` and
`type` and `request_id` at 128 bytes, `message` at 1024, cut on a UTF-8 boundary
and flagged by `truncated`; control bytes, C1 codes and invalid UTF-8 are
flattened to spaces. The credential the request carried is masked, as are values
of recognizable shape (`sk-`, `AIza`, `eyJ`, `Bearer …`, and `api_key=`,
`token:`, `password=` and similar pairs), each replaced by `[REDACTED]`.
The patterns are defence in depth, not a proof that a provider's free text holds
no sensitive data. AgentCore keeps only the credential's length and hash for this
comparison, never a copy, so `update_credential`'s erasure guarantee holds.

The detail belongs to the Run that recorded it. Concurrent Runs on other
Sessions, other threads' subagents, and a subagent nested in this Run's tool call
each write their own, and a model-invoked fork's failure stays that tool's
result. A Skill invocation in its own context is the Run, so its failure is.

### Manual compact

`session_compact` runs the canonical default compact policy as a best-effort
Conversation maintenance operation. Revision 26 has no Host-supplied target
token budget and does not guarantee that the result fits the context window of
the current or a future model. `session_set_model` and `session_compact` are
independent primitives, not a compound model-migration transaction.

On `METASK_AGENTCORE_STATUS_OK`, `CompactResultV1.before_context_tokens` and
`after_context_tokens` are context-size estimates for UI and policy decisions;
they are not provider billing values. The four provider usage-delta fields are
semantically separate. `METASK_AGENTCORE_COMPACT_DEGRADED` exposes no structured
reason in Revision 26, and a Host must not infer one by parsing diagnostics.

Assistant text and other execution output are delivered through `on_event`.
`RunResultV1` is a terminal summary containing stop reason, turns, and tool
calls; it is not an output buffer. Its fields are defined only when
`session_run_input` returns `METASK_AGENTCORE_STATUS_OK`. On any non-OK status
their contents are unspecified and the Host must not inspect them — with two
exceptions: the budget fields on `CHECKPOINT_BUDGET_REQUIRED` (see durable
budget), and `input_accepted_count` / `input_adopted_count`, which are defined
on every status (see "Active-Run input").

Relative paths supplied to `Read`, `Write`, `Edit`, `Glob`, and `Grep` resolve
against `workspace_root`; Bash also runs with that directory as its cwd.
`workspace_root` is an execution context, not a filesystem jail: absolute
paths remain usable unless the Host selects and configures a separate sandbox
policy. Invalid workspace paths, unavailable/duplicate selected tools, and a
shell tool selected under the disabled shell policy fail Session creation with
`METASK_AGENTCORE_STATUS_INVALID_ARGUMENT` and do not publish a Session handle.
`workspace_home` may be empty, in which case it defaults to the canonicalized
`workspace_root`; a non-empty value must be absolute.

### Provider protocol selection

`SessionHostConfigV1` defines one provider connection as
`provider_kind_code + protocol_kind_code + base_url`; the model remains in the
fresh-create input or restored checkpoint. `protocol_kind_code` occupies byte
offset 140 in the unchanged 168-byte Host config and accepts:

- `METASK_AGENTCORE_PROTOCOL_DEFAULT` (`0`): use the selected provider's
  existing default. In Revision 26 that means Anthropic Messages, OpenAI Chat
  Completions, or Gemini GenerateContent;
- `METASK_AGENTCORE_OPENAI_PROTOCOL_RESPONSES` (`1`): valid only with
  `METASK_AGENTCORE_PROVIDER_OPENAI`; serialize `POST /v1/responses` request
  bodies and parse the typed Responses SSE event stream.

Anthropic and Gemini reject every non-zero protocol code. OpenAI rejects every
code other than `0` and `1`. Unknown or mismatched codes return
`METASK_AGENTCORE_STATUS_INVALID_ARGUMENT` during fresh creation or restore,
before any Provider request is attempted. AgentCore never infers a protocol
from `base_url` or the model name. For OpenAI, an empty `base_url` lets the
selected protocol choose its official endpoint; a non-empty `base_url` is the
complete endpoint override and does not alter the selected protocol.

The selection is Session-stable. It is retained when `set_model` rebuilds the
Provider and inherited by Skill child Providers. Restore uses the current Host
protocol selection just as it uses the current Host provider, credential, and
endpoint; the checkpoint does not persist or override connection authority.

### Model capabilities

Whether a model takes image input is answered, strongest first, by:

1. the Host: `SessionHostConfigV1.model_capabilities`;
2. the provider's model catalog, when the Session has one (AgentCore
   Sessions do not fetch one);
3. the built-in model-family table, which knows some names to take images
   and some not to;
4. nobody: the model is treated as not taking images, and an image Run is
   refused as `IMAGE_INPUT_CAPABILITY_UNKNOWN` (29) rather than sent on a
   guess, since a route can drop an image without an error.

Each `ModelCapabilityV1` names one model (non-empty UTF-8, at most
`MAX_MODEL_CAPABILITY_MODEL_BYTES_V1` = 256 bytes, matched against the model
a request names ignoring case) and sets `image_input_code` to
`CAPABILITY_SUPPORTED` (1) or `CAPABILITY_UNSUPPORTED` (2). Zero is not a
declaration: leave a model out to make no statement. At most
`MAX_MODEL_CAPABILITIES_V1` = 256 entries; null with a zero count is none; a
pointer with a zero count, a count with a null pointer, two entries naming the
same model, an unknown code, a wrong `struct_size`, or non-zero reserved words
are `INVALID_ARGUMENT`; too many entries or too long a name is
`RESOURCE_LIMIT`; the model names count toward
`MAX_SESSION_METADATA_BYTES_V1`. Everything is validated before a Session
exists. The array is borrowed for `create` or `restore` and copied; the
declarations then hold for the Session's model, every `set_model` target, and
the Session's tool-scoped providers. Checkpoints carry none: a restore uses
the declarations of the Host config it is given.

A declaration is the Host's statement about its route, not a probe. A model
the Host declares able to take images still receives the request even if the
remote refuses it, and that refusal is the Provider's: the Run ends with
`STOP_API_ERROR`, never re-labelled as status 28 or 29.

`describe` reports the answer for the current model as
`"image_input":{"supported":<bool>,"source":"host"|"catalog"|"model_family"|"unknown"}`;
`source` is `unknown` only together with `supported:false`.

### Time context

A model has no clock. By default each Run's context starts with a block the
runtime writes, labeled `currentDate`:

```text
# currentDate
Today's date is 2026-10-17 (Saturday). Time zone: Asia/Shanghai (UTC+08:00).
```

It is taken when the Run starts and joins that Run's user record with the
Host's context blocks (see "System prompt profiles and context blocks"): history
keeps each Run's own date, and the system prompt - the cached prefix - never
changes with the date. `RunOptionsV1.time_context_code` chooses the zone:

| Code | Meaning |
|---|---|
| `TIME_CONTEXT_SYSTEM` (0, default) | the AgentCore process's time zone (libc `localtime_r` on POSIX, the dynamic time-zone information on Windows). When the platform cannot tell, the date is in UTC and the block says the user's time zone is unknown. |
| `TIME_CONTEXT_UTC_OFFSET` (1) | `utc_offset_minutes` east of UTC, within `MIN_UTC_OFFSET_MINUTES_V1`..`MAX_UTC_OFFSET_MINUTES_V1` (UTC-14:00..UTC+14:00), named `UTC±hh:mm`. For a Host whose users are not where the process runs. |
| `TIME_CONTEXT_OFF` (2) | no block. |

`utc_offset_minutes` is zero under every code but `UTC_OFFSET`. A Host block
labeled `currentDate` is the Run's time context: under `SYSTEM` the runtime
adds none, and together with `UTC_OFFSET` it is two answers to one question
and the Run is refused. A Skill invocation carries no context blocks, so it
takes `SYSTEM` (nothing is added) or `OFF`. Every violation is
`INVALID_ARGUMENT` before admission: no `run_id` advances and nothing reaches
the Provider.

### Goals

A Session may have one goal: an objective its Runs work toward, with an
optional token budget (issue #277). AgentCore owns the goal's state, its
accounting and its status rules; the Host decides when to set it, when to run
toward it, and how to show it. The model cannot change the goal.

`goal->get` writes the goal as JSON, `{"goal":null}` or:

```json
{"goal":{"id":"7f3a…(24 hex)","objective":"Ship the importer","status":"active",
 "token_budget":200000,"tokens_used":51234,"time_used_ms":84012,
 "created_at_ms":1792000000000,"updated_at_ms":1792000084012}}
```

`token_budget` is null without a budget. `tokens_used` counts non-cached input
plus output tokens of every provider response (automatic compaction
included) of the Runs charged to the goal; `time_used_ms` is their wall time.
The typed SDKs decode it (`decodeGoalDocument` in Zig).

`goal->set(GoalSetV1)` replaces any goal with a new active one: a new id and
usage from zero. The objective is trimmed and must then be 1 to 4,000 code
points of UTF-8 (`MAX_GOAL_OBJECTIVE_CODEPOINTS_V1`; a view longer than
`MAX_GOAL_OBJECTIVE_BYTES_V1` is refused undecoded). `token_budget` zero means
no budget. `goal->update(GoalUpdateV1)` changes the current goal. Its `fields`
bits say which of `objective`, `token_budget` (zero clears the budget) and
`action_code` apply. A field without its bit must be zero. The changes apply
together or not at all, in that order. "Raise the budget and resume" is
therefore one update. `goal->clear` removes the goal; without one it changes
nothing.

| Action | From | To | Refused |
|---|---|---|---|
| `GOAL_ACTION_PAUSE` | `active`, `paused` | `paused` | any other status (`GoalNotActive`) |
| `GOAL_ACTION_ACTIVATE` | any | `active` | the budget is used up (`BudgetExhausted`): raise or clear it in the same update |
| `GOAL_ACTION_COMPLETE` | any | `complete` | never |
| `GOAL_ACTION_BLOCK` | any but `complete` | `blocked` | `complete` (`GoalComplete`): `ACTIVATE` reopens it |

The runtime reaches the other two statuses itself: `budget_limited` when
usage reaches the budget, and `usage_limited` is reserved for a provider
usage limit (Revision 26 never sets it). A new budget with room makes a
`budget_limited` goal active, and an active goal already past a lowered
budget becomes `budget_limited` at once.

A Run is charged to the goal only if the goal was `active` when the Run
began. It is charged from then to its end, however it ends. A Skill
invocation Run counts like any other, also when the Skill runs in its own
context. A Skill the model forks as a tool call is not charged: it may run
beside other tools. Its `usage` events still reach the Host. If the budget
runs out during the Run, the goal becomes `budget_limited`, a `goal_updated`
event reports it, and at the next turn boundary the model gets one reminder to
wrap up. The Run is not cut off. When the Run ends, another `goal_updated`
event reports the goal with the Run's usage and time.

`RUN_INPUT_GOAL_CONTINUATION` (4) is a Run whose input the runtime writes: a
reminder to keep working toward the objective (XML-escaped in an
`<objective>` element), with the usage so far against the budget, that tells
the model to say when the goal is complete or blocked rather than mark it.
Every `RunInputV1` field is empty; context blocks and time context apply as to
a text Run. Without an active goal the Run is refused before admission as
`GOAL_CONFLICT` (diagnostic `NoGoal` or `GoalNotActive`), and its `run_id`
stays unused. How many continuations to run, and when, is the Host's choice.

Every goal call is synchronous. `get` is BUSY while a Run, compact,
checkpoint or mutation is in progress, like `describe`. `set`, `update` and
`clear` are idle-Session mutations like `set_prompt_profile`, so BUSY during
any of those, and every refusal leaves the goal unchanged. Status 30
`GOAL_CONFLICT` covers a missing goal and a refused action; malformed requests
are `INVALID_ARGUMENT`.

The goal is durable state. A Session with a goal writes checkpoint marker 10:
the marker-9 envelope, whose prompt profile section may be empty, plus a goal
section whose length is in header bytes 164..168. Every field of that section
but the objective is fixed-width, so charging the goal never changes its
size. A new or edited objective, and clear, are admitted against the durable
budget before anything changes (`CHECKPOINT_BUDGET_REQUIRED`). A Session
without a goal keeps writing marker 8 or 9, readable by earlier libraries.
Restore brings the goal back with its id and usage.

### Teams

A Session may belong to a host-scheduled team (issue #277): a lead Session and
the member Sessions it delegates to. AgentCore owns the team directory, the
per-member mailboxes, the roster and the member leases, but runs no teammate
threads of its own. Delegation records a request; the embedding Host creates
and runs each member Session. Teams are opt-in and carry no checkpoint state —
membership is Host-supplied at every create and restore, like model
capabilities.

A Runtime admits the team tools only when `RuntimeConfigV1.enable_teams` is
non-zero: `TeamCreate`, `TeamDelete`, `SendMessage`, and the host-scheduled
`SpawnTeammate`. They are Session-owned builtins (unlike `Task`, a
process-level tool AgentCore does not expose), so a Session also lists the ones
it wants in `allowed_tools`. A Host must never name a team tool in the
Runtime's explicit `builtin_tools`; the flag is the only way in.

A Session joins through `SessionHostConfigV1.team`, a nullable `TeamConfigV1`
(88 bytes) borrowed for the call. Null is no team. `role_code` is
`TEAM_ROLE_LEAD` (1) or `TEAM_ROLE_MEMBER` (2). A lead leaves `team_name` empty
(its `TeamCreate` names the team) or names it, and leaves the member fields
empty. A member sets `team_name` (the team to join), `member_name` (its own
name, at most `MAX_TEAM_MEMBER_BYTES_V1` bytes), `lead_session_id` (the lead's
24-hex logical id) and `member_lease` (a fresh 24-hex per-spawn lease); joining
the roster is idempotent for the same identity. A team requires a workspace
home, under which the team directory lives.

`team->describe(session, out_team_json, out_error)` writes this Session's team
as JSON — BUSY while a Run, compact, checkpoint or mutation is in progress,
like `describe`:

```json
{"team":{"name":"crew","role":"lead","members":[{"name":"solver",
 "session_id":"…","lease_id":"…","status":"active"}],
 "pending_spawns":[{"name":"solver","prompt":"fix the parser",
 "agent_type":null,"effort":null}]}}
```

It is `{"team":null}` when the Session has no team, a fresh lead before its
`TeamCreate` included. `pending_spawns` are the `SpawnTeammate` requests the
lead has recorded and the Host has not yet fulfilled.

`team->poll(session, out_input_json, out_error)` is the lead's side of the
mailbox: it takes the lead's pending inbox as the model input for its next Run,
marks it read, and writes `{"input":null}` or `{"input":"<text>"}`. It is
idle-only; a non-lead or team-less Session always writes `{"input":null}`. The
Host drives a team by creating the member Sessions `describe` lists as pending,
running them, and feeding each lead Run the `poll` input until the inbox is
empty.

### Active-Run input

Revision 20 adds `session->submit_input(session, run_id, input, out_receipt,
out_error)`, which hands the active Run more user text (#270).

`metask_agentcore_submitted_input_v1` is 48 bytes: `struct_size`, a zero
`reserved0`, `input_id`, `text`, and two zero reserved words. `input_id` is the
Host's correlation id: non-zero and unique among the inputs this Run has
accepted (a later Run may use it again). `text` is non-empty UTF-8 with at
least one non-whitespace byte, borrowed for the call and appended to the
Conversation byte for byte. `out_receipt` is required and written only on
`STATUS_OK`: `metask_agentcore_input_receipt_v1.sequence` is the input's
1-based acceptance position in the Run.

| Situation | Status |
|---|---|
| `run_id` names the active Run and it takes input | `OK`: the input is queued |
| zero `run_id` or `input_id`, a malformed struct, a duplicate `input_id`, empty, all-whitespace, or invalid UTF-8 text | `INVALID_ARGUMENT` |
| text above `MAX_SUBMITTED_INPUT_BYTES_V1`, or a Run that already accepted `MAX_SUBMITTED_INPUTS_V1` inputs or that many text bytes in total | `RESOURCE_LIMIT` |
| the Run's durable budget cannot hold the input | `CHECKPOINT_BUDGET_REQUIRED` |
| another Run is active, or no Run with this id is active or most recent | `STALE_RUN` |
| the most recent Run has ended, or is ending (abort requested, a callback failed) — whatever the Session does after it, compact and checkpoint export included | `TOO_LATE` |
| a forked Skill Run that has started its child; a Session being destroyed | `INVALID_STATE` |
| a poisoned Session (checked before every argument) | `INVALID_STATE` |

A refusal changes nothing — it never ends, aborts, or poisons the Run — and
writes no receipt.

**Concurrency.** Like abort, `submit_input` bypasses the facade call gate. It
may overlap the matching synchronous Run from any thread, including from inside
that Run's `on_event`, `on_ui_request`, and Host tool callbacks, and it may
overlap abort and other `submit_input` calls. It never waits for the Run.
Calls are linearized: concurrent accepted inputs get distinct consecutive
sequences. The Host must let every call return before destroy or any later
call on the handle.

**Adoption.** An accepted input becomes its own user record, appended at the
Run's next turn boundary: after the previous turn's tool results and before
the next provider request is built — the boundary the source-level
`UiEvent.queue_message` seam uses. A boundary adopts every pending input, in
acceptance order, and emits one `input_adopted {input_id, sequence, turn}` per
input after appending it; `turn` is the 1-based turn whose request first
carries it, and sequences arrive strictly increasing. So:

- Input accepted before the Run's first request — from the starting
  `run_state` event, say — joins that first request, after the root input
  (`turn` 1).
- Input submitted while a provider stream is open is queued; the request
  already sent is not changed.
- Input submitted while a Permission or AskUserQuestion request waits is
  queued and never taken as the answer: the callback still answers, and the
  input follows that tool turn's results.
- A `max_tokens` continuation boundary adopts nothing, so a truncated answer
  stays one answer; pending input waits for the next ordinary boundary.
- A boundary is only reached when the Run sends another request. A Run that
  ends first — `end_turn`, `max_turns`, abort, a budget stop, an error —
  leaves pending input unadopted; input submitted during the final answer's
  stream is the common case. A Host submits it as the next Run's input.
- Adoption is not provider receipt: the request that carries it may still
  fail.
- Input does not undo actions already performed and does not stop the Run;
  `session_abort` stops it. Once the Run is aborting — an abort was
  requested, or a Host callback failed (an `input_adopted` the Host rejects
  included) — nothing more is adopted, even input accepted earlier, and the
  Run ends at that boundary without another request.
- A forked Skill Run (`RUN_INPUT_SKILL` with `context: fork`) runs on a child
  Conversation that is discarded when it returns: input accepted before the
  fork claims the Run is never adopted, and later input is refused with
  `INVALID_STATE`. Child agents (Task, model-invoked forks) never adopt Host
  input.

**Reconciliation.** Adoption follows acceptance order and each boundary adopts
everything pending, so the adopted inputs are always a prefix of the accepted
ones. `RunResultV1.input_accepted_count` and `input_adopted_count` are written
on every `session_run_input` return, `OK` or not — `CALLBACK_FAILED` and every
other poisoning status included — and are zero when no Run was admitted. The
inputs whose receipt sequence is at most `input_adopted_count` are in the
Conversation; the rest never will be. These counts are the authority: an
`input_adopted` event the Host did not receive (its callback failed, or the
event could not be delivered) proves nothing either way. A call that admitted
no Run reports zero, also when it reused the last admitted `run_id`. A submission that
overlaps the Run's completion either returns `OK` and is counted, or returns
`TOO_LATE` and is not.

**State and budget.** Adopted input is an ordinary user text record: it keeps
its Conversation position, is exported in checkpoints and restored with them,
and is sent in later Runs' requests. Unadopted input leaves no trace. On
acceptance the facade reserves the input's encoded checkpoint bytes: the Run's
host input — the root input and every accepted input together — stays within
`input_cap_bytes`, and what is left under `hard_bytes` must still hold one whole
provider operation at its configured caps (request, result payload, audit and
terminal reserve), so adopting it never makes the next request fail; otherwise
the input is refused with `CHECKPOINT_BUDGET_REQUIRED` and the Run continues. Adoption moves the
reservation into the Session's durable usage; the Run's end releases the
rest. Input passes no permission, sandbox, cancellation, or budget decision:
it only adds a user record.

Support is discovered through Revision 26 itself (the slot is mandatory);
`MAX_SUBMITTED_INPUTS_V1` (64) and `MAX_SUBMITTED_INPUT_BYTES_V1` (16 MiB) are
published constants; `session_describe` is unchanged.

### Credential updates

Revision 25 adds `session->update_credential(session, credential, out_error)`,
which replaces an existing Session's provider credential in place (#336). The
handle, the logical Session ID, the Conversation, permissions and grants, Skill
bindings, the goal, and an active Run stay as they are; checkpoint export,
destroy and restore are not needed, also not while a Run is going.

- **Only the credential.** Provider kind, protocol, authentication scheme (the
  header the credential travels in), `base_url` and model do not change;
  switching accounts or routes still takes a new Session. AgentCore does not
  check that the new credential belongs to the same account, refreshes nothing
  itself, and never asks the Host for a credential.
- **Input.** `credential` is borrowed for the call and copied: 1 to
  `MAX_CREDENTIAL_BYTES_V1` (16 KiB) bytes, each printable ASCII (0x21-0x7E).
  A control byte would split the request header, and no provider issues a key
  or token with a space or a non-ASCII byte.

  | Situation | Status |
  |---|---|
  | the credential is published | `OK` |
  | a null session; an empty credential, a byte outside 0x21-0x7E, or a null pointer with a non-zero length | `INVALID_ARGUMENT` |
  | a credential longer than `MAX_CREDENTIAL_BYTES_V1` | `RESOURCE_LIMIT` |
  | the copy cannot be allocated | `OUT_OF_MEMORY` |
  | a poisoned Session, or one being destroyed (checked before the credential) | `INVALID_STATE` |

  Every refusal leaves the previous credential in effect and never ends,
  aborts or poisons a Run. A diagnostic names the rule, never the bytes. There
  is no `BUSY`.

  Session create and restore apply the same rule to
  `SessionHostConfigV1.api_key`: empty or a refused byte is
  `INVALID_ARGUMENT`, longer than `MAX_CREDENTIAL_BYTES_V1` is
  `RESOURCE_LIMIT`, no handle is published, and the diagnostic names the rule.
  Earlier, create and restore took any UTF-8, and a credential with CR LF
  ended the process at the first request, in the HTTP client's header
  assertion.
- **Effective point.** A provider request reads the credential when it is
  sent: once it holds its connection slot, immediately before it opens the
  connection. Every request sent after the call returns `OK` carries the new
  credential, unless a later update has replaced it: the active Run's next
  turn, a retry of a request whose earlier attempt failed (each attempt is
  sent anew), a compaction summary, a Skill Run and its forked child, and a
  tool's own per-call provider such as `WebSearch`'s, including one built
  before the update, and a request that was already waiting for a connection
  slot when the update returned. A request already sent keeps the previous
  credential: AgentCore does not cancel, change, or replay a request already
  sent or a stream being read, and whether the provider still honors the
  previous credential is the provider's decision. A request that already
  failed authentication is not replayed.
- **Concurrency and order.** Like `abort` and `submit_input`,
  `update_credential` bypasses the facade call gate and never takes the
  callback lock. It may be called from any thread and from inside the
  Session's own callbacks (`on_event`, `on_ui_request`, Host tool `execute` and
  `execute_stream`), while the Session is idle or while a Run, a compaction or
  a checkpoint export is in progress, and concurrently with `abort`,
  `submit_input`, the Session Control calls, and other `update_credential`
  calls. It never waits for any of them. Updates are linearized: each one
  takes effect at a single instant before it returns, so updates that overlap
  take effect in some order, every request sent afterwards uses the last of
  them, and an update that returned before another began
  always takes effect first. A Host that updates from several threads and
  cares which credential wins orders those calls itself. The Host must let
  every `update_credential` call return before it destroys the handle.
- **The bytes.** The Session keeps one copy of its current credential, which
  every provider it builds reads under a lock as it sends a request, and each
  request keeps its own header copy until that request is set up, then erases
  it. The replaced copy is erased and released before
  `update_credential` returns; the last one is erased when the Session is
  destroyed. The Host may erase its own buffer once the call returns.
- **Never recorded.** Checkpoints, `describe`, events, diagnostics, and logs
  carry no credential, so an update changes none of them. Restore is
  unchanged: a restored Session uses the credential in its restore
  configuration (`SessionHostConfigV1.api_key`), never one published to the
  Session that exported the checkpoint.

Support is discovered through Revision 26 itself (the slot is mandatory);
`MAX_CREDENTIAL_BYTES_V1` (16 KiB) is a published constant.

### Active-Run intent/result journal

`SessionHostConfigV1.run_journal_mode_code` is part of the exact revision-23
wire contract and accepts only:

- `METASK_AGENTCORE_RUN_JOURNAL_EPHEMERAL` (`0`): the default, zero-journal-I/O
  embedded profile;
- `METASK_AGENTCORE_RUN_JOURNAL_DURABLE_WORKSPACE` (`1`): append and fsync the
  unified journal under
  `<workspace_home>/.metacodes/agentcore/sessions/<session_id>/`.

The durable profile writes the Run start before provider/tool execution, one
intent/result pair for every physical provider attempt and actual tool
dispatch, then the terminal Run record. The Run start record carries the
manifest of the system prompt that Run sends (see "System prompt profiles and
context blocks"), so the journal alone attributes every request's prompt. Failed provider attempts remain
billable evidence even when no assistant message is committed; absence of a
provider usage object is encoded as unknown, not synthetic zero. Built-in,
Host, process-plugin, MCP, and fork-Skill tools converge on the same journal.
Replay classification is kernel-owned: read-only built-ins may be classified
safe, while Host/plugin declarations without an invocation-bound receipt are
downgraded to never.

The journal is outside Conversation and provider request projection. Enabling
it therefore does not insert prompt bytes, reorder history, or invalidate a
warm prompt-cache prefix. An unfinished pair fails closed, and so does a Run
whose process exited before its terminal record (the next Run reports
`UnfinishedRun`; a Run still held by a live process reports `JournalBusy`);
revision 26 does **not** expose in-place active-Run resume, automatic
tool replay, or exactly-once external effects. It provides durable evidence
and deterministic recovery classification for a later explicit recovery API,
not authority to guess whether an external side effect occurred.

### System prompt profiles and context blocks

AgentCore assembles each Run's system prompt from named kernel sections,
sorted by `(order, id)` and joined with a blank line:

| id | order | class |
|---|---:|---|
| `metacodes:identity` | -1000 | replaceable |
| `metacodes:safety-policy` | -900 | locked |
| `metacodes:system` | 100 | locked |
| `metacodes:doing-tasks` | 200 | replaceable |
| `metacodes:validation` | 300 | replaceable |
| `metacodes:actions` | 400 | replaceable |
| `metacodes:using-tools` | 1000 | replaceable |
| `metacodes:deferred-tools` | 1100 | replaceable (rendered only while deferred tools exist) |
| `metacodes:tone` | 2000 | removable |
| `metacodes:output-efficiency` | 2100 | removable |
| `metacodes:progress` | 2200 | removable |
| `metacodes:env` | 9000 | generated |
| `metacodes:subagent` | -1000 | replaceable (the subagent prompt's opening, in place of identity) |

`locked` sections (the safety policy and the system rules: permission modes,
prompt-injection handling, `<system-reminder>` trust, compaction) and
`generated` sections (the environment facts) never change. A `replaceable`
section takes new non-empty text and cannot be removed; a `removable` section
takes new text or is removed. Without a profile the prompt is byte-identical to
Revision 17.

A `PromptProfileV1` is an ordered list of `PromptSectionV1` edits:

- `PROMPT_OP_ADD` adds a `host:<name>` section with non-empty `text` at
  `order` (any signed value; equal orders are broken by id). Host sections
  between kernel orders interleave with them; the sparse kernel orders leave
  room on purpose.
- `PROMPT_OP_REPLACE` gives a replaceable or removable `metacodes:<name>`
  section non-empty `text`. A conditional section whose condition is off (no
  deferred tools) stays absent.
- `PROMPT_OP_REMOVE` drops a removable `metacodes:<name>` section; `text` is
  canonical empty and `interpolate` zero.

Ids are `metacodes:` or `host:` followed by 1-64 bytes of `[a-z0-9._-]`
starting with a letter or digit; `order` is zero except for `ADD`. With
`interpolate = 1`, `{{model}}`, `{{workspace_root}}`, and `{{platform}}` are
substituted with the Session's current model, workspace root, and the
`win32`/`linux`/`darwin` platform name at render time; any other `{{...}}` is
refused, and `}}` outside a variable is plain text. The whole profile is
validated before it is used: a locked or generated target, removing a
replaceable section, an unknown kernel id, a `metacodes:` id on `ADD`, a
duplicate id, empty text, invalid UTF-8, or a bad variable returns
`STATUS_INVALID_ARGUMENT` with a diagnostic naming the entry index, id, and
rule (human-readable, like every diagnostic); a wrong layout, unknown op code,
or non-canonical empty view also returns `STATUS_INVALID_ARGUMENT`; more than
64 entries, more than 64 KiB in one text, or more than 256 KiB across texts
returns `STATUS_RESOURCE_LIMIT`. Nothing is created or changed on refusal.

Replacing `metacodes:identity` also removes the sentences that belong to the
kernel's own identity: the environment section's product line and the
doing-tasks framing and help bullets. The rendered prompt then names neither
MetaCode nor software engineering, while the locked sections stay verbatim.

The profile is frozen into the Session at creation. `set_prompt_profile`
replaces it (null clears it) only on an idle, unpoisoned Session — an active
facade call returns `STATUS_BUSY` — and an equal profile changes nothing. The
next Run renders from the new profile, so each effective change is exactly one
prompt-cache boundary. The profile is durable Session state: its checkpoint
section counts toward the durable budget like any other replacement
(`STATUS_CHECKPOINT_BUDGET_REQUIRED` when it does not fit).

Subagent and fork-Skill prompts inherit the profile: they render
`metacodes:subagent` and `metacodes:env` (joined by one newline, as before)
plus every `host:` section; edits of sections those prompts do not have do
nothing there. An isolated Skill Run root sends exactly the subagent prompt the
Session recorded for it.

Each Run's journal `run_started` record (durable journal mode) and, when the
prompt differs from the previous Run's (the Session's first Run, a profile or
model change, a different tool surface), a `prompt_manifest` event before the
Run's first provider request report the rendered prompt:

```json
{"prompt_manifest":{"sha256":"<hex>","sections":[
  {"id":"metacodes:identity","order":-1000,"origin":"host","class":"replaceable","sha256":"<hex>"},
  {"id":"metacodes:safety-policy","order":-900,"origin":"kernel","class":"locked","sha256":"<hex>"}]}}
```

Sections appear in render order with the SHA-256 of their text; `origin` is
`host` for a Host section or a replaced kernel section. `describe` adds
`prompt.profile` (the effective entries, texts included) and
`prompt.manifest` (the latest Run's manifest, null before the first Run of
this Session handle).

A checkpoint of a Session without a profile keeps the compatibility-marker-8
envelope byte for byte. A Session with one writes marker 9: the same envelope
plus a seventh section holding the profile, whose length occupies header bytes
184..192. Earlier libraries refuse it as `CHECKPOINT_INCOMPATIBLE` rather than
misreading it. Restore uses the checkpoint's profile, never the Host's, so the
restored Session renders the same system prompt bytes for the same model,
workspace, and tools; a profile the current kernel refuses restores as
`CHECKPOINT_UNSUPPORTED`.

`RunOptionsV1.context_blocks` (with `context_block_count`, null with zero when
absent) carries up to 32 `ContextBlockV1` facts for one `RUN_INPUT_TEXT` or
`RUN_INPUT_MULTIMODAL` Run — the date, the state of the Host's page or
document. Each has a label of 1-64 bytes of `[A-Za-z0-9 ._:/-]` starting with a
letter or digit and non-empty UTF-8 text of at most 64 KiB (256 KiB for labels
and texts together); a text may not contain a `<system-reminder>` tag. They are
rendered, in order, into one text part that leads the Run's user record:

```text
<system-reminder>
The host application provided the following context for this request:
# currentDate
Today's date is 2026/10/02.

      IMPORTANT: this context may or may not be relevant to your tasks. You should not respond to this context unless it is highly relevant to your task.
</system-reminder>
```

It is ordinary Conversation content: it enters the durable budget with the
user record, stays in later requests' history (the cached prefix only grows),
and checkpoints keep it. A `RUN_INPUT_SKILL` Run refuses context blocks with
`STATUS_INVALID_ARGUMENT`. Volatile facts belong here rather than in profile
text, which would move the system prompt and its cache prefix on every change.

The process-wide `METACODES_PROMPT_OVERRIDE_USING_TOOLS` experiment slot sets
the kernel text of `metacodes:using-tools`, so a profile `REPLACE` of that
section takes precedence over it; provider dialect rewrites apply to the
rendered prompt afterwards. Neither is Session customization or part of this
contract.

### Skill catalog and typed input

`runtime_query_skill_catalog` is independent of Session lifetime so a Host may
render a Skill menu before creating its first Task or Session. It resolves one
Workspace authority; it is not a directory-scan mode switch. The safe Zig SDK
therefore deliberately aliases this raw table slot as
`resolveWorkspaceSkillCatalog`.

A successful query returns both an immutable catalog handle and a
library-owned descriptor using schema `metask.skill-catalog/v1`. The descriptor
contains a Runtime-local `catalog_scope_id`, content-derived
`catalog_revision`, health, valid `skills[]`, and typed `issues[]`; it never
contains Skill bodies, physical paths, policy internals, or execution mode.
Isolated invalid slots produce `OK + degraded`. Failure to prove the whole
snapshot complete returns `SKILL_CATALOG_INCOMPLETE`, a null handle, and an
empty descriptor. Structural/resource-limit failures use their dedicated
statuses and likewise publish no partial snapshot.

Every issue carries `kind = invalid | unavailable | conflict`, its typed code,
logical `skill_policy_key`, and provider/source provenance. An
`invalid_resource` issue always carries a typed `reason`; every other issue
code carries `reason: null`. The resource reasons are `file_too_large`,
`skill_too_large`, `too_many_files`, `too_many_entries`,
`directory_too_deep`, `path_too_long`, `unsupported_entry`,
`resource_unavailable`, and `resource_changed`. A failing selected Skill never
falls back to a lower-priority candidate with the same invocation name.

An absent source root contributes no candidates. Any other failure to open,
enumerate, or prove the stability of a source root is a catalog-global
discovery failure. Failure to open or stably inspect one entry below that root
is a failed candidate: it remains subject to normal
invocation-name precedence and, if selected, produces a local resource issue.
An uncertain higher-priority candidate therefore never silently exposes a
lower-priority Skill with the same invocation name.

`SkillCatalogQueryV1.reserved0` must be zero. Default discovery merges exactly
`<workspace_home>/.agents/skills` as User scope (`source_instance_id`
`agents.user.default`) and `<workspace_root>/.agents/skills` as Workspace
scope (`agents.workspace.default`); Workspace wins across scopes. If the
canonical paths are equal, AgentCore registers only the Workspace
contribution, avoiding a synthetic self-conflict.

The Host may add at most 64 `SkillSourceV1` local directories. Each source has
scope `SKILL_SOURCE_USER` or `SKILL_SOURCE_WORKSPACE` and a 1..128 byte stable
ASCII `source_instance_id` using letters, digits, `.`, `_`, `:`, or `-`.
Duplicate canonical roots or source ids are invalid. `SkillSourceV1.reserved0`
and `reserved[]` must be zero.

Every source, default or additional, has a signed 32-bit source priority
(Revision 26, #390). `SkillSourceV1.priority` sets it for an additional
source; `SkillCatalogQueryV1.default_user_source_priority` and
`default_workspace_source_priority` set it for the User and Workspace
`.agents/skills` sources (the User value is unused when the canonical home and
root are equal). Every value is valid, higher ranks higher, and 0 is the
priority of every source the Host leaves unconfigured. For each invocation
name AgentCore selects one candidate:

1. Scope first: a Workspace candidate beats every User candidate, whatever
   their source priorities.
2. Within the remaining scope, the highest source priority wins. The selection
   is a normal result: it adds no issue and leaves the catalog `healthy`.
3. Two or more candidates tied at that highest priority are a
   `source_conflict`; the name is not published. Ties among lower-priority
   candidates never affect a unique winner.
4. A selected candidate whose definition or resources fail reports that issue;
   AgentCore never falls back to a lower-priority candidate.
5. Registration order, root paths, and `source_instance_id` order never choose
   a winner.

Names that only a lower-priority source defines stay available. The
`skills[]` entry, its `source_instance_id` and `skill_id`, policy binding, and
execution all name the selected candidate. A query whose priorities are all
zero (a zero-initialized struct) resolves exactly as Revision 25 did:
same-scope candidates with one invocation name conflict.
For example, a Host that registers `<root>/.codex/skills` (priority 0) and
`<root>/.claude/skills` (priority 10) as Workspace sources gets the `.claude`
version of a `review` Skill both define, while a `zig` Skill only `.codex`
has and a `release` Skill only `.claude` has both stay available. AgentCore
has no built-in ranking of directory names; the Host chooses the order.

Resource accounting includes every regular file below the selected Skill root,
including `SKILL.md` and hidden files; no ignore file is applied. Every regular
file counts toward entry, traversal, file, and content limits. Directories and
special entries count only toward the per-Skill entry and catalog traversal
limits. Symlinks and other special entries produce `unsupported_entry`.
Relative paths use UTF-8 bytes, `/` separators, no Unicode normalization, and
no case folding. MiB means `1024 * 1024` bytes. The initial source enumeration
defines the candidates for one query; later additions are observed by a
subsequent query. Atomicity means that the completed immutable snapshot is
published once, not that the Host filesystem is transactional.

AgentCore does not implicitly read `/etc/metacodes/skills`, `.claude/skills`,
`.codex/skills`, or `.metacodes/skills`. A Host may explicitly register any
local directory only when its contents already use the canonical Agent Skill
format. Directory names do not select a parser; Revision 26 has no Claude/Codex
format adapter or public Provider Registry. The projected provider id is
`agents.directory`.

Each valid `skills[]` entry exposes separate identities:

- `skill_policy_key`: the logical invocation slot, equal to
  `invocation_name` in Revision 26;
- `provider_id`, `source_scope`, `source_instance_id`, and `contribution_id`:
  source identity;
- `content_revision`: body/resources identity;
- `skill_id`: the concrete source + contribution + content execution identity.

`skill_id`, `contribution_id`, `content_revision`, and `catalog_revision` are
64-character lowercase hexadecimal digests. A content change creates a new
`content_revision` and `skill_id`. Policy and execution never authorize a bare
logical name.

Each valid `skills[]` entry contains this fixed argument-schema shape:

```json
{
  "argument_schema": {
    "schema": "metask.skill-arguments/v1",
    "max_values": 64,
    "names": ["target", "scope"]
  }
}
```

`names[]` supplies ordered positional labels for consumer UI:
`arguments_json.values[i]` corresponds to `names[i]`. Names do not declare
required arity. A caller may submit zero through `max_values` strings, including
values beyond `names.len`; `max_values` is the wire upper bound.

`workspace_epoch` is an opaque byte token supplied by the Host. It is compared
only for byte equality inside one canonical Workspace scope and need not be
parseable, monotonic, or comparable across Hosts. Canonical empty `{NULL,0}`
means that the Host has no external Workspace generation. The Host changes the
token when its external Workspace binding generation changes. The token enters
the catalog-revision hash, so changing it produces a new revision and may make
an input prepared for a differently bound Session return `STALE_CATALOG`.

The Host releases its catalog handle exactly once with
`skill_catalog_release`. Session create and idle-only rebind retain their own
reference, so the Host may release its handle immediately after either call
succeeds. A catalog must belong to the same Runtime and canonical Workspace
binding.

`SkillPolicyV1` is default-deny and lists only granted concrete `skill_id`
values. Empty means deny all. Session create/restore require Catalog and Policy
to be both present or both absent. The raw `session_update_skills` slot (safe
SDK alias `sessionBindSkillPolicy`) jointly validates the replacement Catalog
and Policy and atomically commits them only while idle. Any failure preserves
the complete previous binding; it never partially disables exceptions or
unbinds the old catalog. Rebind does not modify Conversation or `run_id`.

`session_run_input` accepts exactly one tagged input. Every kind populates
only its own fields; every other view stays canonical empty, and the
`parts`/`part_count` pair is null/zero except for the multimodal kind:

- `RUN_INPUT_TEXT`: only `text` is non-empty; it is bounded to 16 MiB before
  pointer access or UTF-8 decoding. Slash-looking text has no special meaning.
- `RUN_INPUT_SKILL`: `text` is canonical empty and the Session must have a
  bound catalog. `skill_id`, `catalog_revision`, and `arguments_json` identify
  an explicit Host invocation. Arguments are canonical empty or
  `{"values":["..."]}`, with at most 64 values and 1 MiB encoded JSON.
- `RUN_INPUT_MULTIMODAL`: `text` and the Skill fields are canonical empty;
  `parts` points at 1..64 (`MAX_RUN_INPUT_PARTS_V1`) ordered `RunInputPartV1`
  elements borrowed for the synchronous call. The parts become one user record
  preserving Host order. Each element carries `struct_size` exactly 72, zero
  reserved words, and exactly the fields of its kind:
  - `RUN_INPUT_PART_TEXT`: non-empty UTF-8 `text`; `media_type` and `data`
    canonical empty.
  - `RUN_INPUT_PART_IMAGE`: `media_type` equal to one of `image/png`,
    `image/jpeg`, `image/gif`, or `image/webp` (the same allowlist the
    built-in Read tool derives from file extensions), plus non-empty `data` in
    standard base64 with `=` padding and no whitespace; `text` canonical
    empty. One image payload is bounded to
    `MAX_RUN_INPUT_IMAGE_DATA_BYTES_V1` (5,000,000 bytes — exactly the base64
    encoding of the Read tool's 3.75 MB raw-image cap). Raw image bytes never
    cross the ABI.

  Every declared part length is bounded before the matching payload pointer is
  dereferenced, and the summed part payload (text, media type, and base64
  bytes) is bounded by the same 16 MiB input cap as `RUN_INPUT_TEXT`. Count,
  per-image, and total-payload violations return
  `METASK_AGENTCORE_STATUS_RESOURCE_LIMIT`; every other malformed part is
  `METASK_AGENTCORE_STATUS_INVALID_ARGUMENT`.

  After wire validation, and before admission or any Provider request, a
  multimodal input containing at least one image part is preflighted against
  the Session's current model's image input (the same answer the provider
  serializers enforce; see "Model capabilities"). A refused input returns
  `METASK_AGENTCORE_STATUS_IMAGE_INPUT_UNSUPPORTED` (28) when a source - the
  Host's declaration, the provider catalog, or the built-in model-family
  table - says the model does not take images, and
  `METASK_AGENTCORE_STATUS_IMAGE_INPUT_CAPABILITY_UNKNOWN` (29) when none of
  them says anything about the model. Either way nothing advances `run_id`,
  mutates Conversation, or reaches the Provider — the same pre-Provider
  discipline as the provider-protocol codes above. After 28 the Host may
  retry the same `run_id` after `session_set_model`, or resubmit without
  images; after 29 it may also declare the model in
  `SessionHostConfigV1.model_capabilities` (a new Session or a restore). A
  parts array with no image part needs no image capability. Images in user
  input are never silently dropped, OCR'd, or replaced with placeholder text.

Observable validation order is fixed: malformed wire/identity is
`INVALID_ARGUMENT`; mismatched pinned revision is `STALE_CATALOG`; an unknown
concrete id is `SKILL_NOT_FOUND`; an ungranted concrete id is
`SKILL_POLICY_VIOLATION`; malformed values are `INVALID_SKILL_ARGUMENTS`; and
unavailable execution is `SKILL_UNAVAILABLE`. These failures occur before Run
admission and do not advance `run_id` or mutate Conversation.
Materialization begins only after admission, is private to that activation,
and is removed before terminal return. A Skill can only narrow the Session's
tool, shell, and permission authority.

Text, multimodal, and typed Skill input share one root-record admission
invariant. Text and multimodal reserve their exact encoded root record —
for multimodal that is the checkpoint-encoded ordered text/image user record —
and Skill reserves its exact canonical invocation record before admission.
Skill body rendering may read referenced files or run declared shell
injection, so it remains inside the admitted Run. Before Conversation
mutation, AgentCore atomically replaces the invocation-only estimate with the
exact generated root records. Input-cap failure becomes a bounded
resource-limit outcome and durable-budget shortage becomes a budget-exhausted
outcome. AgentCore neither reserves the entire input cap as a fictional Skill
payload nor moves effectful materialization before admission. An admitted
multimodal record persists through `session_export_checkpoint` as ordered
block tags 1/5, so a restored Session resends the original image bytes.

The Session configuration owns the provider model binding. Skill metadata
cannot replace it: inline Skills ignore `model`, fork Skills with an empty
model or `inherit` use the Session model, and any other fork model is
unavailable in AgentCore. An explicit typed invocation returns
`SKILL_UNAVAILABLE` before admission, so it does not consume `run_id`,
materialize, mutate Conversation, or send a provider request. The Run-local
`Skill` tool reports the same condition as an ordinary structured tool error
with code `ModelOverrideUnavailable`; it does not create a child Run or poison
the outer Run. Every admitted fork child therefore sends the Session model.

A consumer normally uses the Skill ABI in this order:

1. During draft creation, resolve a complete Workspace catalog and render its
   descriptor. On `SKILL_CATALOG_INCOMPLETE`, retain the last-good result.
2. Build a default-deny Policy from concrete descriptor ids and create a
   Session bound to Catalog + Policy.
3. Release the Host's catalog handle; the Session retains its own reference.
4. Submit `RUN_INPUT_SKILL` with an identity and revision from that descriptor.
5. On `STALE_CATALOG`, query again, re-resolve and re-authorize the concrete
   identity from the new descriptor, wait until the Session is idle, atomically
   rebind Catalog + Policy, release the new Host handle, and retry with the same
   `run_id` because the rejected Run was never admitted.

Changing source files alone does not mutate a Session's immutable snapshot;
the old body and resources remain pinned and executable until rebind.
`STALE_CATALOG` means that the input revision differs from the revision
currently bound to the Session. If the new descriptor removes the Skill or
reports it as an issue, the consumer must not blindly retry.

The internal Workspace scope-identity domain remains
`metask-agentcore/abi-v1/revision-5`. It identifies the scope algorithm first
introduced in Revision 5 and is intentionally independent of the current ABI
revision so compatible checkpoint Workspace bindings remain stable.

When a bound snapshot contains at least one model-invocable Skill, AgentCore
adds one Run-local provider tool named `Skill` to both Text Runs and explicit
Skill Runs. It is an internal projection, not another ABI entry point. Its
input is exactly `{"name":"<invocation_name>","values":["..."]}`; `values` is
optional, `origin` and all other fields are invalid, and names resolve only in
the snapshot pinned by that Session. The tool schema and description omit
`disable-model-invocation` Skills. Guessing such a name still fails closed as
an ordinary tool result and never falls back to prompt text.

Inline and fork calls reuse the same typed activation, materialization, and
immutable PolicyFrame lineage as explicit input. Nested activation starts
from the current frame and therefore cannot restore authority removed by an
outer Skill. `Skill` is a serialization boundary: no later tool call in the
same provider response may be speculatively executed before its policy change.
Inline materializations live until Run quiescence; fork execution is
synchronous within the same Host Run and projects its public text and usage
through the ordinary event stream. The provider tool name `Skill` is reserved:
Runtime creation rejects a Host tool with that name.

Fork children cannot suspend for Host UI interaction in Revision 26. Their UI
requester is unavailable, so a child question or permission request fails
closed as an ordinary fork/tool failure attributed to the outer Run. Inline
execution may use the outer Run's synchronous UI callback.

AgentCore exposes no slash parser, Command registry, route field, or
product-specific command. A consumer resolves its own Commands first, maps a
catalog hit to typed Skill input, and treats an unresolved slash as its own
product decision.

### MCP Runtime catalog and Session view

Revision 26 supports exact MCP `2026-07-28`, `2025-11-25`, and `2025-06-18`
connections. Public negotiation codes preserve Revision 6 meanings:
`auto=1`, `modern_only=2`, and exact `legacy_only=3`; exact
`legacy_2025_06_only=4` is appended. Runtime owns negotiation,
transport, canonical catalogs, cache expiry, and immutable generations;
Session owns only a filtered selection, while each Run pins an admitted Tool
environment. Credentials, live connections, and request state never enter a
Session checkpoint.

`auto` probes Modern first. A validated `MethodNotFound` may enter Classic;
stdio probe timeout or child exit may also enter Classic. For Streamable HTTP,
a completed response is reported as `MCP_EXCHANGE_RESPONSE` with its final HTTP
status and body. A bare HTTP 400 from the disposable `server/discover` probe is
Classic evidence; a complete, request-id-matching JSON-RPC response overrides
that default. Strictly valid `-32022` data contributes its `supported` versions,
and malformed typed `-32022`, other JSON-RPC errors, 401/403, every status other
than 2xx/400, and transport failures do not downgrade. No body-shape or string
heuristic is used. Classic starts with an exact 2025-11 request. If that response
selects 2025-06, Runtime closes the connection and reopens exact 2025-06 once.
Only the final exact-era handshake may publish capabilities or create the
operational client.

The Host-owned Connector is also the MCP transport compliance boundary. Every
successful `open` must create a connection context permanently bound to the
provided purpose and exact `requested_era_code`. For Streamable HTTP, the Host
must retain response headers and attach the exact era as
`MCP-Protocol-Version` to every request after successful initialization; when
the server returns `MCP-Session-Id`, the Host must retain it in that connection
context and send it on subsequent HTTP requests. Disposable probes, actual
connections, and connections reopened for another era must not share
`MCP-Session-Id` values or other connection-scoped mutable protocol state.
Host-configured credentials, including authentication cookies, may be reused
only within the same authentication context. The Host must never change an
existing connection's era after inspecting an initialize response: AgentCore
closes a mismatch and performs the exact-era reopen itself.

The `metask_agentcore_mcp_cancellation_v1` descriptor, its `ctx`, and its poll
callback are borrowed only for the synchronous request or notification callback
invocation. A Host must not retain the descriptor or poll it after that callback
returns.

| Responsibility | Owner |
|---|---|
| Candidate selection and validation of the server-selected protocol | AgentCore |
| Closing a mismatch and performing an exact-era reopen | AgentCore |
| JSON-RPC request bodies and Classic lifecycle ordering | AgentCore |
| Probe HTTP status gate, JSON-RPC validation, and era selection | AgentCore |
| HTTP headers, authentication, cookies, session IDs, and connection pooling | Host Connector |
| Reporting every completed HTTP response's final status and body | Host Connector |
| Binding one connection context to `purpose_code` and `requested_era_code` | Host Connector |

Revision 26 separates MCP control and result traffic in the type system.
`McpConnectorV1.request` writes a 40-byte `McpResponseV1` only for bounded
discovery/initialize/catalog control frames. Stdio responses use
`http_status == 0`; Streamable HTTP completed responses use their final status
in the range 200..599. Non-response outcomes use status zero and an empty body.
`release_response` keeps its signature: canonical `{NULL,0}` is never released;
for every other body token AgentCore calls it exactly once with
`&response.body`, including an invalid `{ ptr != NULL, len == 0 }` token. On
actual connections, stdio and HTTP 2xx enter the era parser, HTTP 401/403 map
to `auth_error`, and every other HTTP status maps to `server_error` before
protocol parsing. These failures never switch era or replay `tools/call`.
`MCP_EXCHANGE_FATAL` permanently retires the connection from dispatch; a later
catalog refresh must open a replacement.

`request_tool_stream` is the sole `tools/call` operation: AgentCore creates a
private Session capture before the callback, lends a synchronous
`HostResultSinkV1`, and requires the Host to write the complete JSON-RPC
response from byte zero. The sink advertises a 129MiB response-frame ceiling;
the final model-visible result remains subject to the 128MiB artifact ceiling.

After the callback returns `MCP_EXCHANGE_RESPONSE`, AgentCore seals the private
capture and performs streaming UTF-8/JSON, depth, node, duplicate-key,
JSON-RPC version/id, exact-era result, `content`, `isError`, `_meta`, and
`structuredContent` checks. Only the exact successful top-level `result` byte
range is copied into CAS; the JSON-RPC wrapper is not model-visible. Small
results remain inline. Large successful results become the same path-free,
content-addressed envelope used by Host/process/native tools and are recovered
with `ReadArtifact`. Remote JSON-RPC errors, `isError=true` business results,
malformed frames, cancellation, overflow, and partial connector failures are
bounded structured errors or typed call failures and never publish the private
capture. A connector must not retain the borrowed sink or call it after return.

`metask_agentcore_mcp_notify_fn_v1` has only two outcomes:
`MCP_NOTIFY_OK` means the notification was committed, and `MCP_NOTIFY_FAILED`
means it was not. AgentCore does not branch on a Host-side failure category and
does not retry or replay a failed notification; detailed transport outcomes
belong to `open` and `request`, where AgentCore can act on them.

`runtime_describe_mcp` returns `agentcore.mcp-catalog/v1`. Every server entry
contains `server_binding_identity`, namespace, negotiated protocol,
fingerprint, `cache_scope`, `fresh`, `ttl_remaining_ms`, and its Tool range.
Modern TTL is capped by Runtime policy; Classic adapters receive a
conservative default TTL. A fresh Session selection fails when its server is
expired, restore degrades and invalidates that authority, and a newly admitted
Run never receives stale MCP Tools. An already admitted Run keeps its immutable
environment until terminal completion.

`McpServerV1.configuration_fingerprint` is the Host's nonzero, non-secret name
for the connection a server binding reaches: its endpoint, transport target
and the principal it authenticates as, as the Host defines them. AgentCore
never sees the endpoint, so this value is the connection identity it trusts.
Each MCP Tool's permission binding (`permission_binding` in
`runtime_describe_mcp` and Session `describe`, `tool.binding` in Permission
requests and `permission_provenance`) binds the server binding, the MCP Tool
name, the semantic schema and that fingerprint, and Session grants match on
it (#389):

- **Endpoint moved.** When `apply_configuration` keeps a server binding, Tool
  name and schema but changes the fingerprint, a Session that selected the
  Tool keeps it, and its next call asks again or falls back to the
  permission mode. An `allow_session` or `deny_session` answer given over the
  old connection never decides for the new one. A Host allow or deny rule
  names a Tool, not a connection, so it decides on either.
- **Same connection.** A change that keeps the fingerprint (namespace, client
  information, timeout, negotiation policy, protocol limits) is the same
  connection. The Runtime may reconnect, and grants keep deciding.
- **Host duty.** A Host changes the fingerprint whenever the endpoint, the
  transport target or the authenticated principal changes, and keeps it when
  only a credential for the same principal rotates; secret bytes and digests
  of them never go into it. A fingerprint that hides a move lets grants
  follow it; one that changes on every token refresh asks again each time.
- **Old grants are dropped.** A grant bound to a connection its server has
  left can never decide again, so the Session drops it at the first point
  that sees the change, and reports it:

  | Where | Dropped grants are reported as |
  |---|---|
  | The next Run call, before admission | Session `describe`: `restore.invalidated_mcp_bindings`, `restore.health` `degraded`; no issue |
  | `update_selection` | The same |
  | Restore | Restore report `permission.invalidated_rules` with a `permission` issue (reason `unavailable`, the grant's binding); health `degraded` |

  A change undone before any of these sees it changes nothing. Session
  `describe` reports each Tool's binding for the connection the Session last
  saw: at create, `update_selection`, restore or that Run.

One server's transport, protocol, or catalog resource-limit failure produces a
server-scoped issue and does not suppress healthy servers in the same refresh.
Only Runtime-local failures such as allocation exhaustion abort the refresh.
Modern `tools/list` cache metadata is required; `server/discover` may omit both
cache fields. Each server TTL starts when that server's discovery completes,
not when the multi-server refresh began.

A Host tool's `input_schema_json` root accepts `type` (which must be
`"object"`), `properties`, `required`, and a boolean `additionalProperties`.
Any other root keyword is `STATUS_INVALID_ARGUMENT` with an `InvalidSchema`
diagnostic, because AgentCore refuses to accept a constraint it cannot then
preserve through tool storage, catalog cloning, and Provider request
construction. A boolean `additionalProperties` is preserved end to end and
appears in the Provider request; the schema-valued form
(`"additionalProperties": {...}`) has no internal representation and is
therefore still rejected rather than silently dropped. Nothing here validates
tool arguments against the schema: the constraint is declaration forwarded to
the model provider, which remains the authority on JSON Schema semantics.

Canonical MCP schemas are retained losslessly and dialect-transparently.
Absent `$schema`, explicit JSON Schema 2020-12, explicit Draft-07, and any
other string dialect declaration do not by themselves affect Tool
availability. AgentCore validates bounded JSON structure and the MCP input
object envelope, then projects the common `type`/`properties`/`required` shape
to model providers, plus a boolean root `additionalProperties`; root `$schema`
and non-projected root keywords remain only in the canonical record. A
schema-valued `additionalProperties` is one of those non-projected keywords —
retained canonically, not forwarded, and never a reason a Tool becomes
unavailable.

Forwarding the boolean form is a deliberate behavior change (issue #35): it was
previously dropped, so a server that closed its argument object advertised an
open one to the model. Tools whose schema declares it therefore serialize
differently than they did before, which invalidates the provider prefix cache
for those Sessions once. Tools that never declared it are byte-identical. This is not a claim that AgentCore implements any
complete JSON Schema dialect.

Provider projection must nevertheless be structurally complete. A `$ref` or
`$dynamicRef` inside the projected `properties` tree is unavailable with
`provider_critical_projection_loss`, because the common Provider Tool shape
does not carry the canonical root `$defs`; AgentCore does not silently emit a
dangling reference or resolve it locally. Root `required` entries must be
unique and name projected properties. These are projection-integrity checks,
not JSON Schema instance validation.

Before `tools/call`, AgentCore validates that arguments are a bounded JSON
object and applies Permission, Skill restrictions, and canonical Tool identity.
The MCP server remains authoritative for JSON Schema semantics. AgentCore does
not locally reject an invocation for `required`, property type, `enum`/`const`,
reference, or other schema-constraint mismatch. When `outputSchema` is present,
a successful result must still carry `structuredContent`, but its schema
semantics are server-owned. An `isError=true` Tool business error may omit
`structuredContent` without losing its typed content.

Catalog is the sole executable admission authority. A Snapshot stores only a
canonical Tool and stable model alias for each admitted entry. Structurally
invalid, over-budget, or projection-incomplete schemas and tools requiring MCP
Tasks are visible only as catalog issues and cannot be found or selected;
dialect and semantic keywords alone never create such an issue. Session
materializes a provider
`PreparedTool` only for selected admitted entries; a non-allocation disagreement
with the recorded envelope admission is an invariant violation. View
destruction releases materialized tools before releasing the retained
Snapshot. MCP Tasks, notification pumping, and automatic request replay remain
outside Revision 26.

The value-only MCP checkpoint section has one current `MCPSEL` format and no
independent revision axis. Its decoder rejects every earlier `R6MCP`/`R7MCP`
encoding. Era remains provenance rather than a selection fingerprint input.
The section records no configuration fingerprint: restore binds the selected
Tools to the current catalog's, and the permission section's grants restore
only where their binding names that connection. MCP grants in checkpoints
exported before #389 carry the earlier connection-free binding, so restore
invalidates them.
The outer AgentCore ABI Revision 26 remains the sole compatibility boundary.

### Model-visible MCP diagnostics

MCP Tool failures currently reach the model as compact JSON with `code`,
`phase`, and nullable `rpc_code`. These strings are diagnostic output, not C ABI
`Status` values or a stable ABI control vocabulary; Hosts must not branch
on their spelling or use them to broaden Tool authority. The current uncertain
delivery code is `indeterminate`. Stabilizing this vocabulary requires a later
explicit contract decision rather than treating leaked enum names as wire API.

### Permission rules

A Host states standing policy as three lists of rule strings,
`permission_rule_set_v1.allow`, `.ask` and `.deny`: at Session creation
(`permission_rules` in the Session configuration) and later through
`session_control.update_permission_rules`. An update replaces the whole set
atomically at the idle boundary (`BUSY` while any facade call or Run is
active, `INVALID_STATE` on a poisoned Session), starts a new policy generation
and so clears every Session grant. A set holds at most 1024 rules, each 1 to
65,536 bytes of UTF-8 and 1 MiB in total; exceeding a limit returns
`RESOURCE_LIMIT` and any rule that does not parse returns `INVALID_ARGUMENT`,
in both cases with nothing published. AgentCore reads no settings file: these
lists are the only Host-imported rules.

**Syntax.** Tool names are exact and case-sensitive, and a rule names one Tool:
`Edit(...)` does not cover `Write`, so a Host that means both writes both.

| Rule | Matches |
|---|---|
| `Tool`, `Tool(*)`, `Tool()` | every call of that Tool |
| `Bash(pattern)` | the shell command (below) |
| `Read(path)`, `Edit(path)`, `Write(path)` | that Tool's target path (below), read from `file_path`, else `notebook_path`, else `path` |
| `WebFetch(domain:example.com)` | a `url` whose host is exactly `example.com`; `domain:*.example.com` matches its subdomains only |
| `Skill(name)`, `Skill(prefix *)` | the Skill tool's `name` argument, exactly or by prefix |
| `mcp__server`, `mcp__server__*`, `mcp__server__tool` | MCP Tools of that server, or one Tool (below) |

Every other Tool takes only the bare form. A specifier on any other name parses
but is read as a Bash pattern over a `command` argument, which no other
built-in has, so such a rule never matches (and on a Host Tool it would match
an unrelated `command` argument). `Glob` and `Grep` in particular take no path
specifier. `WebFetch(...)` without `domain:` and an opening `(` without a final
`)` do not parse.

**Bash patterns** describe one command. `git status` matches exactly;
`npm run *` and `npm run:*` match `npm run` or anything starting with
`npm run ` (a word boundary); `*` anywhere else matches any characters,
spaces included. Compound commands (`&&`, `||`, `;`, `|`, `|&`, `&`, newline)
are split: an allow rule must match every segment, a deny or ask rule any
segment, so `Bash(git *)` does not allow `git status && rm x` and `Bash(rm *)`
denies it. Benign wrappers (`timeout`, `nice`, `nohup`, ...) are seen through
by every rule; other wrappers (`env`, `xargs`, ...) only by deny and ask rules.

**Path patterns** start with an anchor:

| Prefix | Base in AgentCore |
|---|---|
| `//` | the filesystem root; on Windows, the root of the target path's own drive, written without the drive letter (`//Users/me/out/**`) |
| `~/` | the Workspace home |
| `/` | the **Workspace root**, not the filesystem root |
| `./` or none | the Workspace root as well: a Session has no process cwd, so both "project root" and "cwd" are `workspace_root` |

After the anchor, `*` matches within one path segment and `**` across
segments (`**/` also matches zero segments); a pattern without `/` matches a
basename at any depth below the base. There is no `?` or character class. The
target is first made what the tool will open: JSON-unescaped, relative paths
joined to the Workspace root, `~/` to the Workspace home, `.`/`..` folded. On
POSIX an existing path is also resolved through symlinks: an allow rule must
match both the written path and its target, a deny or ask rule either. On
Windows comparison is case-insensitive, `\` equals `/`, and symlinks are not
resolved.

**MCP and Host Tool names.** An MCP rule uses the server's namespace and the
MCP tool name the server reports: `mcp__weather__get_forecast`. It never uses
the opaque model-facing alias (`mcp__weather__` plus a digest) that appears in
Tool events. A Host Tool (`host_tool_v1` or a stream tool) is named exactly as
registered, with nothing added (`open_tab`, not `host__open_tab`); a
process-package contribution is named by its namespaced global tool name, the
name the model sees.

**Evaluation order.** For each call the first step that decides wins; the
`permission_provenance.source` it records is shown in parentheses.

1. An active Skill's tool policy (`active_skill`): a call outside it is denied.
   A Skill only narrows; it never allows.
2. Any matching **deny** rule (`explicit_deny`).
3. Core safety (`core_safety`): a `Write` or `Edit` of a protected path
   (`.git/`, `.ssh/`, `.aws/`, `.gnupg/`, `.env`, shell profiles, ...) asks, and
   MCP arguments that fail the tool's schema deny. Such a prompt never offers
   `allow_session`.
4. A matching Session deny grant (`session_deny`).
5. Any matching **ask** rule (`explicit_ask`).
6. Any matching **allow** rule (`explicit_allow`).
7. A matching Session allow grant (`session_allow`).
8. The permission mode. Built-ins use Core's classification
   (`builtin_classification`): `Write` and `Edit` edit, `Bash` executes, and
   every other built-in reads. `full_access` allows everything and `dont_ask`
   denies everything. `default` and `auto` allow reads and ask the rest;
   `accept_edits` also allows `Write` and `Edit` inside the Workspace root and
   asks for them outside it. In those three modes a read-only Bash command (or
   one the Workspace sandbox really confines, when it is set to auto-allow
   them) is allowed. Host, process and MCP Tools (`mode_fallback`) ask, except
   that `dont_ask` denies them and `full_access` allows them.

Under `dont_ask` a call that would ask is denied without calling the Host. A
call that does ask calls the Host and records `callback` with its response.

The lists are not ranked by specificity: any matching deny beats every allow,
and any matching ask beats every allow. A bare `ask: ["Write"]` therefore
overrides `allow: ["Write(/outputs/**)"]`. To allow one directory and ask for
everything else, write only the allow rule and let step 8 ask.

**Example.** Workspace root `/Users/me/MetaBrowser`, mode `default`. Writes and
edits under `/Users/me/MetaBrowser/outputs` need no prompt, every other write
still asks, and the Read tool may not open anything under `secrets`:

```json
{
  "allow": ["Write(//Users/me/MetaBrowser/outputs/**)",
            "Edit(//Users/me/MetaBrowser/outputs/**)"],
  "ask": [],
  "deny": ["Read(//Users/me/MetaBrowser/secrets/**)"]
}
```

Because both directories are inside the Workspace, `Write(/outputs/**)`,
`Edit(/outputs/**)` and `Read(/secrets/**)` are equivalent. Writing
`Write(/Users/me/MetaBrowser/outputs/**)` is a valid rule that never matches:
it names `<workspace_root>/Users/me/...`. Path rules govern only the named file
Tool: `Glob` and `Grep` still list `secrets`, and Bash reads whatever its own
rules allow, so a Host that must keep a directory unreadable also denies
`Glob`, `Grep` and the Bash commands concerned, or keeps the directory outside
the Workspace.

### Permission mode updates

`session_control->update_permission_mode(session, permission_mode_code,
out_error)` changes an existing Session's permission mode in place. The
handle, the logical Session ID, the Conversation and every other Session
setting stay as they are; checkpoint export, destroy and restore are not
needed.

- **Boundary.** Idle only, like every Session Control mutation. While any
  facade call or Run is active it returns `BUSY`: a Run, including one
  suspended in a Permission or other UI callback, a compaction, a checkpoint
  export, another mutation, or a Provider cancel still draining after an
  abort. A poisoned Session returns `INVALID_STATE`, and a code that is not
  one of the five `METASK_AGENTCORE_PERMISSION_*` values returns
  `INVALID_ARGUMENT` with a diagnostic. A mode the Session's settings disable
  (`disableBypassPermissionsMode`, `disableAutoMode`) would also return
  `INVALID_ARGUMENT`, diagnostic `PermissionModeDisabled`; a Session's
  settings are the Host-imported rules, which cannot disable a mode, so this
  does not occur in revision 26. None of these changes anything.
- **Effective point.** The first permission decision after the call returns
  `OK`, which is the first Tool call of the next Run.
- **Grants.** A new mode is a new policy. The call starts a new policy
  generation and revokes every Session grant, `allow_session` and
  `deny_session` alike, as `update_permission_rules` does: an answer the Host
  gave under one mode is not carried into another, whether the new mode is
  stricter or looser. A Host that needs a call blocked under every mode states
  it as a deny rule, which a mode change does not touch. Setting the mode the
  Session already has is a no-op that keeps the generation and the grants.
- **Atomicity.** The new policy fingerprint, the replacement permission state
  and its durable budget admission are prepared before anything is published.
  A failure, including `CHECKPOINT_BUDGET_REQUIRED` from that admission, leaves
  mode, generation, grants and fingerprint as they were.
- **Observability.** `describe` reports `permission_mode` (`default`,
  `accept_edits`, `auto`, `dont_ask` or `full_access`) beside the
  `policy_generation` it belongs to. Permission requests and
  `permission_provenance` events carry the same generation.
- **Checkpoints.** The policy fingerprint after a change is the one a Session
  created with the new mode and the same Host authority has. Export records
  the new mode, fingerprint and generation and holds no revoked grant, so no
  restore can bring one back. A restore under the same mode and authority
  keeps the generation; a restore under a different policy advances it and
  discards the grants, as for any restore. The restore report and `describe`
  count each discarded grant as invalidated, with an issue for it. Restore
  health is `degraded` exactly when some Skill, Permission or MCP grant was
  invalidated: a different policy over a checkpoint without Session rules
  advances the generation and restores `complete` (#334).
- **Other layers.** Explicit rules, Core safety (protected paths), an active
  Skill's narrowing, `allowed_tools` and the Workspace sandbox are separate
  from the mode and keep applying after a change.

### Permission authority and provenance

A Permission callback request carries a `candidate`
(`{"rule_id","scope","target"}`, or null) whenever a Session answer can take
part in later decisions; `deny_session`/`allow_session` echo its `rule_id`.
`scope` says how far the answer reaches:

- `exact_arguments` (every eligible Tool; `target` is null): later calls of
  the same Tool identity with the same canonical argument value. An MCP Tool
  identity includes the connection the call reaches; see [MCP Runtime catalog
  and Session view](#mcp-runtime-catalog-and-session-view).
- `file_target` (built-in `Write` and `Edit` only): later calls of the same
  Tool on the same canonical file, whatever their content or edit strings.
  `target` is that file's canonical path, for the Host to show the user.

AgentCore derives `target` exactly as the tool derives the file it opens: the
tool's own reading of its path argument (`file_path`; `Write` also accepts the
historical `path`), JSON unescaping, `~` against the Workspace home, relative
paths against the Workspace root, then lexical normalization (symlinks are not
resolved). It offers `file_target` only when a strict JSON parse of the
arguments finds the same top-level path string; arguments that the tool and a
JSON reader would resolve to different files (a nested object or an escaped
key carrying a second `file_path`) get `exact_arguments`. A file grant is
bound to its Tool (a `Write` grant does not cover `Edit`) and to the logical
Session, and ranks where `session_allow`/`session_deny` always rank: explicit
deny, Core safety, active Skill narrowing, and explicit ask still decide first.
Checkpoints record each grant's scope. A checkpoint holding a file grant is
refused by an AgentCore older than Revision 17; one without file grants is
byte-identical to before.

Permission response tokens are `deny_once`, `deny_session`, `allow_once`, and
`allow_session`; Session grants never mean cross-Session persistence. Every
final decision carries its canonical source, matching rule when present,
logical Session/Run/tool identity, canonical argument digest, policy
generation, and typed callback outcome in a `permission_provenance` event.
The exact source vocabulary is `core_safety`, `active_skill`, `explicit_deny`,
`session_deny`, `explicit_ask`, `explicit_allow`, `session_allow`,
`builtin_classification`, `mode_fallback`, and `callback`. Explicit settings
deny, shared Core safety, active Skill narrowing, and existing shared Session denial are authority
ceilings: the AgentCore Session seam observes them for provenance but cannot
replace their result.
Host callback response and final authorization are separate facts. Audit
storage is prepared before a Session grant can be added, then the same receipt
is committed only when the authoritative `policy_decision` event supplies the
actual execution result. If durable grant reservation fails, provenance keeps
the Host response but records the final deny; an audit allow/public deny split
is forbidden. Receipt commit performs no allocation.
Publication uses the same Run EventSink as all other public events. If the Host
returns an event-fatal result, the Run terminates with callback failure and the
Session is poisoned; AgentCore must not silently convert that failure into a
permission deny.

AgentCore sets `no_interactive_prompt` as an absolute input-ownership boundary.
After an unavailable, cancelled, or failed UI callback it never reads a process
answer queue or stdin. Public provenance preserves the typed callback outcome.
The current shared bool prompt seam still renders non-answered permission
outcomes to the model as the same ordinary deny Tool result; consumers that
need the distinction must use `permission_provenance` until a shared typed
prompt-outcome contract replaces that seam.

### Completion boundary

Revision 26 exposes no Completion handle, DTO, status, or function slot.
Independent title, summary, classification, and other product-level model calls
belong to the Host or a product plugin. If the Agent itself must invoke such a
capability, the Host exposes a semantically bounded Tool; a generic Completion
Tool is not an AgentCore escape hatch. No internal Completion facade remains;
governed Runtime paths such as compact summary call the neutral Provider
interface directly and define no consumer plugin contract.

ABI v1 has three ownership classes:

| Value | Owner and lifetime | Release |
|---|---|---|
| `metask_agentcore_bytes_view_v1` inputs and event/request views | Borrowed for the current synchronous call or callback | Never released |
| Host tool results and UI responses | Host-owned callback output | Canonical `{NULL,0}` is never released; every other descriptor is passed to its paired Host release callback exactly once, independent of status |
| MCP response bodies | Host-owned callback output inside `metask_agentcore_mcp_response_v1` | Canonical `{NULL,0}` is never released; every other body is passed as `&response.body` to `release_response` exactly once, independent of exchange status or descriptor validity |
| AgentCore catalog descriptors and API diagnostics | Library-owned output | Released only with the discovered `buffer_release` function |

Status controls whether callback output is consumed, not whether it is
released. `METASK_AGENTCORE_HOST_OK` consumes success text. `METASK_AGENTCORE_HOST_FAILED` and
`METASK_AGENTCORE_HOST_REJECTED` may consume UTF-8 detail for a model-visible ordinary tool
error; `METASK_AGENTCORE_HOST_FATAL` and unknown Host status codes ignore output after its
mandatory release and poison the Session. Only `METASK_AGENTCORE_UI_ANSWERED` consumes UI
response JSON. No callback or release callback has thread affinity.

The final `metask_agentcore_owned_bytes_v1 *` argument on AgentCore API calls is an optional,
write-only diagnostic output. AgentCore never reads or releases its previous
value; a Host must call `buffer_release` before reusing a variable that still
contains a diagnostic from an earlier call. Successful calls return canonical
empty. Diagnostic allocation is best-effort and never changes the primary
operation status. Diagnostic text is human-readable, non-normative, and
unstable; consumers must not parse it or branch on its wording. Host-owned
callback output must never be passed to `buffer_release`.

Host tool `execute` receives a borrowed `RunContext` and the provider-produced
tool arguments JSON. The context, its `session_id` view, and arguments view do
not remain valid after the callback returns.

### Callback and concurrency matrix

| Path | Concurrency/ordering | Failure semantics |
|---|---|---|
| `on_event` | Serialized within one Session; different Sessions may call shared Host state concurrently | Any value other than `METASK_AGENTCORE_EVENT_CONTINUE` aborts the Run and poisons the Session |
| Host tool `execute` | Different Sessions and parallel tool calls in one Session may invoke it concurrently | `METASK_AGENTCORE_HOST_FAILED`/`METASK_AGENTCORE_HOST_REJECTED` becomes a normal tool result; `METASK_AGENTCORE_HOST_FATAL` aborts and poisons without a model-visible tool result |
| `on_ui_request` | Synchronous in the Run path | `METASK_AGENTCORE_UI_UNAVAILABLE` is an ordinary reusable outcome; fatal/unknown status or invalid, mismatched, or oversized response aborts and poisons |
| release callbacks | Exactly once for every accepted Host-owned buffer; no thread affinity | Must not re-enter Run or destroy |
| `session_abort` | May run concurrently with the matching synchronous Run, including from a callback | Cooperative; callback or provider code that blocks can delay completion |
| `session_submit_input` | May run concurrently with the matching synchronous Run, with abort, and with other `submit_input` calls, including from a callback | Never blocks on the Run; a refusal changes nothing and never ends, aborts, or poisons the Run |
| `session_update_credential` | May run concurrently with any call on the same handle except `destroy`: a Run (also from inside its callbacks), compact, checkpoint export, mutations, `abort`, `submit_input`, and other updates, which are linearized | Never blocks and never returns `STATUS_BUSY`; a refusal keeps the previous credential and never ends, aborts, or poisons a Run |
| `session_abort_compact` | May run concurrently only with the matching synchronous compact | Cancellation propagates to in-flight provider I/O |
| `set_prompt_profile` | An idle-Session mutation like `set_model`; never concurrent with a Run, compact, checkpoint, or another mutation | Busy Session returns `STATUS_BUSY`; refusal leaves the profile unchanged |
| `update_permission_mode` | An idle-Session mutation like `update_permission_rules`; never concurrent with a Run (including from its callbacks), compact, checkpoint, or another mutation | Busy Session returns `STATUS_BUSY`; any refusal leaves mode, policy generation and grants unchanged |
| `goal->get` | Like `describe`: never concurrent with a Run, compact, checkpoint, or mutation | Busy Session returns `STATUS_BUSY`; a Run reports goal changes as `goal_updated` events instead |
| `goal->set`, `update`, `clear` | Idle-Session mutations like `set_prompt_profile` | Busy Session returns `STATUS_BUSY`; every refusal leaves the goal unchanged |

User input that arrives while a Run is active goes to that Run through
`session_submit_input` (see "Active-Run input"); a Host that wants it to start
a new Run instead still queues it and submits it once the Run returns, or
aborts and resubmits. The untyped in-process steering seam —
`UiBackend.poll` returning `UiEvent.queue_message` — remains a source-level
`metacodes-core` facility; the facade's backend poll always returns null.

Callbacks may request abort, submit input, and update the credential. A
callback attempt to re-enter Run or destroy on the same handle returns
`METASK_AGENTCORE_STATUS_BUSY`; callers must not spin or wait for that
operation from inside the callback. Matching abort, matching `submit_input`,
and `update_credential` are the only concurrency exceptions to ordinary
Session operations. The Host must wait for every `session_abort`,
`session_submit_input`, and `session_abort_compact` call to return before
issuing any subsequent call on the same handle, including a new Run, compact,
mutation, or destroy; a `session_update_credential` call may overlap any of
them and must only return before destroy. A successful destroy invalidates the handle; calling any API with that
pointer afterward is invalid Host behavior. C++ exceptions,
`longjmp`, and other non-local control transfers must never cross an AgentCore
callback or release-callback boundary.

ABI v1 UI response JSON is one of:

```json
{"answers":[{"values":["choice per question"]}]}
{"permission":"allow_once"}
```

Permission also accepts `allow_session`, `deny_once`, and
`deny_session`. The kernel has no plan mode and no plan-approval request, so
ABI v1 has neither. KG counts and Workbench plan-progress state are likewise not part
of this protocol. There is no unversioned `custom` escape hatch. Host tool
input schemas use the AgentCore object-schema subset: `type`, `properties`,
and `required`.

Session permission modes are `default`, `accept_edits`, `auto`, `dont_ask`,
and `full_access`, represented by the corresponding public constants. A
Session starts with the mode in its Host configuration and changes it only
through `update_permission_mode` (see "Permission mode updates"). Which modes
a Host offers is the Host's policy: a Session's only settings are the
Host-imported allow/ask/deny rules, which cannot disable a mode.

ABI v1 supports these built-in tools: `Read`, `Write`, `Edit`, `Glob`, `Grep`,
`Bash`, `BashOutput`, `KillShell`, `WebSearch`, `WebFetch`, and
`AskUserQuestion`. The kernel-owned `ReadArtifact` recovery tool is also
present in every Runtime generation and is automatically selected for every
AgentCore Session; it is not a fallback that admits any other unselected
built-in. `WebSearch` uses the Session's configured internal web
service/provider; it is an ordinary function tool rather than a
provider-specific server-tool descriptor. The Host may select `WebSearch` in
`builtin_tools`, but does not provide or register an executor callback for it.
Its internal search request is the only request that carries a server tool, so
it is the only one that can end in Anthropic's `pause_turn` (the server-side
search loop reached its iteration limit). `WebSearch` does not resume it: it
puts a note that the results may be incomplete in front of whatever arrived,
and when nothing arrived it fails as `WebSearchIncomplete` instead of reporting
an empty search. The Run's own requests carry no server tools.
`WebFetch` is also Session-available, but it currently uses the tool's direct
HTTP/subprocess implementation rather than the Session provider; its network
and redirect policy remains the owning tool's contract. Existing WebFetch
permission-rule and streaming-prefetch behavior also remains in force; Hosts
that need domain restriction must provide the corresponding `WebFetch(domain:…)`
rule. Runtime creation
rejects process-level tools whose dependencies are not owned by AgentSession,
including Task, Cron, KG, MCP, worktree, and notification tools. Adding those
requires a future explicit Host capability contract; they are not silently
advertised with missing state.

`Glob` and `Grep` execute through an external ripgrep executable (`rg`).
Selecting either tool makes its resolution part of Runtime creation: the
resolver probes `RG_BIN`, `PATH`, the directory containing the Host
executable, and the documented system fallback locations. When no executable
resolves, `runtime_create` fails with
`METASK_AGENTCORE_STATUS_INVALID_ARGUMENT` and a `ToolDependencyUnavailable`
diagnostic naming the missing dependency and the accepted provisioning
options, instead of advertising tools whose first invocation would fail with
`RipgrepNotFound`. The bundle itself ships the matching executable as the
`bin/rg[.exe]` runtime asset (see the bundle layout section), so a Host
normally deploys that file next to its own executable — a location the probe
resolves without additional configuration. Hosts that deliberately drop the
asset must also omit `Glob`/`Grep` from `builtin_tools`.

### Resource limits

V1 applies these limits to inputs or identities that amplify library
allocations or unbounded work:

| Limit | Value |
|---|---:|
| total Runtime tools; selected Session tools | 1024 |
| explicit process-plugin sources per Runtime | 64 |
| one Host tool schema | 1 MiB |
| Host tool schema nesting | 32 levels |
| top-level schema properties/required entries | 1024 |
| one synchronous UI response | 1 MiB |
| one raw Host callback success result or failure/rejection detail | 16 MiB |
| default durable Tool/MCP result cap before artifact promotion (canonical image results stay inline, see below) | 2 MiB |
| one Tool Result artifact / one Session artifact CAS | 128 MiB / 1 GiB |
| one `ReadArtifact` chunk | 32 KiB |
| one encoded model-visible Host tool error payload | 1 MiB |
| one Session ID | 64 bytes |
| one Runtime/Session metadata string | 1 MiB |
| total Runtime metadata | 16 MiB |
| total Session metadata | 4 MiB |
| one TextInput prompt; total multimodal part payload | 16 MiB |
| one `update_credential` credential | 16 KiB |
| parts per multimodal input | 64 |
| Host inputs accepted by one Run (`submit_input`) / their text bytes together | 64 / 16 MiB |
| one image part base64 payload | 5,000,000 bytes |
| Skill invocation slots per catalog | 1024 |
| one Skill argument array / JSON | 64 values / 1 MiB |
| one catalog descriptor | 4 MiB |
| one Skill file / total content per Skill | 16 MiB / 32 MiB |
| files / entries per Skill | 1024 / 4096 |
| total catalog content / files | 64 MiB / 16384 |
| catalog traversal entries | 65536 |
| Skill directory depth / relative path | 64 / 4096 UTF-8 bytes |
| retained Skill catalog snapshots per Runtime | 256 MiB resident bytes |
| active materializations per Runtime | 256 MiB |
| MCP Runtime servers / canonical tools | 64 / 1024 |
| MCP schema/arguments JSON container entries / admission work units | 256 / 65536 |
| MCP legacy default TTL / maximum accepted TTL | 30 s / 300 s |
| one Run | 1000 turns |
| one tool_result file_refs array / path / URI / title / kind | 32 / 4096 / 8192 / 256 / 64 bytes |
| one file_changes array / retained unified diff per file | 64 records / 256 KiB |
| prompt profile entries / one section text / all section texts | 64 / 64 KiB / 256 KiB |
| context blocks per Run / one label / one text / all labels and texts | 32 / 64 bytes / 64 KiB / 256 KiB |

MCP schema and invocation JSON cross the depth/node/container/work admission
gate before a dynamic JSON tree is allocated. Invocation JSON must have an
object root; AgentCore does not interpret its values against the retained JSON
Schema.

AgentCore releases every Host callback buffer exactly once. A successful
inline Tool or MCP result larger than its configured durable result cap is
first promoted into the Session CAS and only the bounded recovery envelope is
settled against the durable budget; the raw success is not discarded before
artifact projection. The one exception is a canonical image result (the
`{"type":"image","media_type":…,"data":…}` shape defined in
[doc/API.md](API.md)): it is never promoted, because an envelope would reach
the provider as text instead of a picture. It is settled against the
operation's payload cap at 6,400 payload-budget bytes
(`IMAGE_RESULT_BUDGET_BYTES`) and against the durable budget at its real
bytes. Two situations yield `checkpoint_payload_resource_limit`: a cap
below 6,400 (the per-operation cap check; `required_checkpoint_bytes` is then
the 6,400-byte payload charge that exceeded it), and a settle whose real
durable bytes, plus every live reservation and the terminal reserve, would
exceed `hard_bytes` — with or without sibling reservations
(`required_checkpoint_bytes` is then that full requirement, the same
convention as an admission refusal). The 16 MiB completed-buffer callback boundary remains an
ABI safety cap: legacy synchronous Host results beyond it cannot enter the
library and therefore cannot be recovered. Native/process tools and
`HostStreamToolV1` callbacks that use the byte-zero spool avoid constructing
that raw buffer at all; only their optional failure/rejection detail uses the
completed-buffer cap.

Every AgentCore Session stores artifacts under
`<workspace.home|root>/.metacodes/agentcore/sessions/<logical_session_id>`.
Checkpoint restore preserves the logical Session ID and therefore resolves the
same CAS. `ReadArtifact` is frozen into the provider-visible tool directory
from request one, so a later spill changes neither system prompt nor tool
schema and does not invalidate the prompt-cache prefix.

Configuration and pre-admission Run limits return
`METASK_AGENTCORE_STATUS_RESOURCE_LIMIT`. An oversized UI response is released exactly once,
returns `METASK_AGENTCORE_STATUS_CALLBACK_FAILED`, and poisons the Session because the Host
UI transport violated its callback contract. An oversized Host callback result
at the 16 MiB ABI boundary is released exactly once and becomes an ordinary
Host tool failure. Events are never silently truncated. Event JSON has no
universal size cap.

Runtime metadata includes built-in names and Host tool names, descriptions, and
schemas. Session metadata includes credentials, model/base URL, workspace
paths, and selected tool names. These budgets bound copied configuration; they
do not classify the same-process Host as untrusted.

Completed-buffer Host tool results are UTF-8 text. Invalid UTF-8 is released exactly once and
becomes an ordinary Host tool failure. Binary output requires an explicit
textual encoding such as base64. `HostStreamToolV1` is the explicit exception:
it can declare binary media and stream arbitrary bytes into CAS without
smuggling them through a JSON string.

FAILED/REJECTED detail enters structured JSON only through AgentCore's
serializer. After decoding that JSON, the detail equals the Host's original
UTF-8 text, including quotes, backslashes, newlines, and control characters.
The 1 MiB error-payload limit is measured after escaping and serialization. If
the complete encoded payload would exceed it, AgentCore releases the Host
buffer and emits a bounded generic ordinary tool error instead; this does not
upgrade the outcome to fatal. Hosts must not place credentials in detail.
An encoded Host error payload is semantic model input: generic tool-result
persistence and per-message bulk-result budgets must not replace it with a
persisted or truncated envelope.

All empty `metask_agentcore_owned_bytes_v1` values use the canonical `{NULL, 0}` form. Host
UI fatal/invalid responses are infrastructure failures: they abort the active
Run, poison the Session, and surface as `METASK_AGENTCORE_STATUS_CALLBACK_FAILED` (or
`METASK_AGENTCORE_STATUS_OUT_OF_MEMORY` when response processing exhausts memory).

### Sensitive data

Provider credentials are copied into Session-owned storage and must never
appear in CoreEvent JSON, checkpoints, `describe`, diagnostics, or error
buffers. `update_credential` replaces that copy: the previous one is erased
before the call returns, and the current one when the Session is destroyed
(see "Credential updates"). Prompts, assistant
text, tool inputs/results, and UI payloads are potentially sensitive by
default; the Host owns storage, logging, retention, and redaction. Diagnostic
buffers are human-readable, unstable text and must not be parsed as a machine
protocol. V1 deliberately does not add a `sensitive` boolean that would imply
reliable automatic classification.

### ABI evolution

All v1 POD descriptors and the API table require their exact documented
`struct_size`; every reserved field must be zero. While Revision 26 remains
unreleased and experimental, an explicitly approved hard cut may replace its
wire shape in place only when the library, headers, SDKs, consumers, tests, and
documentation move atomically; the replaced bundle is void and no compatibility
path is provided. Consumers must therefore pin the exact bundle they were built
against. After a revision is formally released, a later breaking v1 bundle must
increment `abi_revision`. Reserved storage is not permission to infer
compatibility. After v1 is genuinely stabilized, later layout, function-table,
or control-message extensions require `metask_agentcore_get_api(2)` and v2
types. Assigning a meaning or non-zero value to a reserved field is always an
explicit wire-contract decision, never an inferred compatible extension.

Revision 26's published POD offsets and sizes require a 64-bit pointer ABI.
The header rejects 32-bit consumers at compile time; a future 32-bit contract
would need separately specified layouts and consumer gates.

Revision 26 has no root capability mask. The seven typed table pointers and
their exact layouts are the complete ABI surface and are all mandatory.
Concrete Runtime and Session configuration still determines which tools and
callbacks are active; that configuration is not ABI capability negotiation.

ABI v1 deliberately does not add a slash/Command ABI, in-place active-Run
resume, asynchronous UI continuations, ABI-level asynchronous operations,
strict Workspace security, Workbench `Output`/`FileChange`/plan-progress models, or a
multi-platform universal bundle. Those are separate contracts, not hidden
behavior in the library facade. This does not remove Bash's existing
tool-managed background jobs, which remain reachable synchronously through
`Bash`, `BashOutput`, and `KillShell`.
