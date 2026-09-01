# AgentCore SDK

This directory contains source-free host bindings for the experimental AgentCore
C ABI v1 revision 16:

- `metask/agentcore.h` — normative C11/C++17 layout declarations;
- `zig/` — typed Zig consumer bindings;
- `rust/` — Rust sys bindings and build integration;
- `VERSION` — SDK package version, distinct from ABI revision.

Do not copy individual files into a release. Consume the complete generated bundle
and validate its manifest, hashes, target, ABI version, exact 64-byte root, all
five mandatory typed tables, function slots, and reserved fields. Revision 16 is
the Agent Runtime surface; it does not expose an independent Completion client.
`session_run_input` accepts text, typed Skill, and multimodal inputs; a
`RUN_INPUT_MULTIMODAL` Run submits an ordered `RunInputPartV1` array of text,
base64 image, and base64 PDF document parts. Image and document parts are
preflighted independently against the Session model's `image_input` and
`pdf_input` capabilities — vision does not imply document input — and a
document is additionally admitted as a real, unencrypted PDF within the byte
and page limits before the Run is admitted.
`SessionHostConfigV1.protocol_kind_code` is provider-scoped: zero preserves the
provider default, while OpenAI may explicitly select
`OPENAI_PROTOCOL_RESPONSES`. Pair it with `provider_kind_code`, the full endpoint
override in `base_url`, and the Session model; no URL/model inference occurs.
Build and exercise a native bundle with:

```sh
zig build agentcore:gate -Dtarget=<native-target> -Doptimize=ReleaseSafe
```

Normative semantics and the support matrix are in
[`doc/AGENTCORE_BINARY_ABI.md`](../doc/AGENTCORE_BINARY_ABI.md).
