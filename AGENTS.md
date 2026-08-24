# Contributor instructions

These rules apply to the entire repository.

## Engineering contract

- Use the Zig version declared by `build.zig.zon` and CI. Verify unfamiliar
  standard-library APIs against the installed toolchain instead of relying on
  memory from another Zig release.
- Develop type first: define the state model and signatures, then let the compiler
  drive the implementation.
- Make illegal states unrepresentable. Prefer tagged unions, distinct ID types,
  explicit error sets, and compile-time validation over optional-field protocols.
- Every allocation has an owner. Name allocators by lifetime (`gpa`, `arena`,
  `scratch`) and place `defer` immediately after successful resource acquisition.
- Preserve the kernel boundaries: plugins cannot replace the AgentLoop or bypass
  permission, sandbox, budget, formal verdicts, TinyKG admission, or artifact CAS.
- Provider-visible bytes are a cache contract. Runtime generation, plugin paths,
  journals, timestamps, and equivalent configuration churn must not enter prompts.
- TinyKG is an explicit external binary. Never add source vendoring, `PATH` search,
  sibling-checkout discovery, or stale build-output fallback.

## Definition of done

Declaration = wiring = L2 evidence. A schema/config/API field is not implemented
until a component or integration test proves input X changes the real downstream
request, child process, durable state, or host-visible result Y. Silent no-ops are
not accepted.

Before submitting:

```sh
zig fmt --check build.zig src tests
zig build test:lib -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseSafe
scripts/test_coverage_audit.sh
git diff --check
```

Supply `-Dtinykg-bin` and `-Dtinykg-sha256` only when the changed tests require
TinyKG. Do not run paid or provider-backed benchmarks without explicit user
authorization, a dollar cap, and the durable budget journal.

## Repository hygiene

- Keep secrets, personal paths, generated evaluation runs, binaries, and local
  TinyKG stores out of Git.
- Use `rg`/`rg --files` for discovery and `apply_patch` for source edits.
- Do not overwrite unrelated worktree changes. Destructive Git commands require
  explicit authorization.
- Public API changes must update `doc/API.md`, the normative protocol document,
  SDK fixtures, and an end-to-end consumer test in the same change.
