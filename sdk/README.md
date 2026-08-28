# AgentCore SDK

This directory contains source-free host bindings for the experimental AgentCore
C ABI v1 revision 14:

- `metask/agentcore.h` — normative C11/C++17 layout declarations;
- `zig/` — typed Zig consumer bindings;
- `rust/` — Rust sys bindings and build integration;
- `VERSION` — SDK package version, distinct from ABI revision.

Do not copy individual files into a release. Consume the complete generated bundle
and validate its manifest, hashes, target, ABI version, exact 64-byte root, all
five mandatory typed tables, function slots, and reserved fields. Revision 14 is
the Agent Runtime surface; it does not expose an independent Completion client.
Build and exercise a native bundle with:

```sh
zig build agentcore:gate -Dtarget=<native-target> -Doptimize=ReleaseSafe
```

Normative semantics and the support matrix are in
[`doc/AGENTCORE_BINARY_ABI.md`](../doc/AGENTCORE_BINARY_ABI.md).
