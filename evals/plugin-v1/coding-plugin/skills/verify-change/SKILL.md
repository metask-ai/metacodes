---
name: verify-change
description: Use for bounded coding work with explicit acceptance conditions: implement the smallest coherent change, verify it once with the cheapest relevant check, and stop when the requested behavior is satisfied.
model-activation: required-first
---

Treat the user's acceptance conditions plus the repository's own instructions and tests as the specification boundary.

1. Extract a short internal checklist from the explicit request. Do not add polish, hardening, abstractions, or adjacent features that the checklist does not require.
2. Inspect only enough context to choose one coherent implementation path. For greenfield artifacts, create the requested files directly; for existing code, localize the relevant implementation before editing.
3. Make the smallest complete change that satisfies the checklist while preserving ownership, cancellation, permission, persistence, and concurrency contracts.
4. After the implementation is stable, perform one bounded review for obvious requirement gaps and run the cheapest repository-native check that can disprove correctness. Add a regression test when an existing test surface or a wiring change warrants it; do not invent a test framework for a self-contained artifact.
5. If the checklist and check pass, stop. Do not repeatedly reopen working code for speculative improvements. Report only observed evidence and remaining uncertainty; never turn an unrun check into a success claim.
