# AgentCore SDK

This directory contains source-free host bindings for the experimental AgentCore
C ABI v1 revision 18:

- `metask/agentcore.h` — normative C11/C++17 layout declarations;
- `zig/` — typed Zig consumer bindings;
- `rust/` — Rust sys bindings and build integration;
- `VERSION` — SDK package version, distinct from ABI revision.

Do not copy individual files into a release. Consume the complete generated bundle
and validate its manifest, hashes, target, ABI version, exact 64-byte root, all
five mandatory typed tables, function slots, and reserved fields. Revision 18 is
the Agent Runtime surface; it does not expose an independent Completion client.
`SessionCreateConfigV1.prompt_profile` edits the named system-prompt sections
(replace the identity, add Host sections; governance sections stay locked) and
is frozen into the Session and its checkpoints; `session_control->set_prompt_profile`
replaces it while idle. `RunOptionsV1.context_blocks` adds volatile Host facts to
one Run as user-role context instead of system-prompt text.
`session_run_input` accepts text, typed Skill, and multimodal inputs; a
`RUN_INPUT_MULTIMODAL` Run submits an ordered `RunInputPartV1` array of text and
base64 image parts, preflighted against the Session model's image capability.
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
