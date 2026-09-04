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
- TinyKG is a separately built external binary dependency. The repository owns one
  manually reviewed cross-platform binary bundle, selected by target and pinned
  by SHA-256. Never add TinyKG source vendoring, download-on-build, `PATH` search,
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
zig build test
scripts/test_coverage_audit.sh
python3 scripts/check_doc_links.py
python3 scripts/check_doc_facts.py
git diff --check
```

`zig build gate:pr` runs this list. CI runs the same commands (the full suite in
Debug, the core suite in ReleaseSafe; `scripts/tests/test_gate_manifest.py`
asserts every command above has a CI step), so this block is the single source.
Run the full suite with `-Doptimize=ReleaseSafe` as well when a change touches
unsafe code or an ABI.

The native bundled TinyKG is wired into tests by default. Supply
`-Dtinykg-bin` and `-Dtinykg-sha256` together only to audit an explicit override.
Do not run paid or provider-backed benchmarks without explicit user authorization,
a dollar cap, and the durable budget journal.

Judge a build by its exit code and `Build Summary`, never by the presence of
`failed command:`. The Zig 0.16 build runner routes every step that wrote to
stderr through the failure printer, so a passing step is tagged ` w` and
followed by `failed command: <cmd> --listen=-` while the build still exits 0
(`master` renames that tag to ` stderr` but keeps the wording). Suites whose
subject logs diagnostics on expected error paths trip this on every run;
`agentcore-abi-contract` does so through its HTTP 529 and connection-drop tests.

## Repository hygiene

- Keep secrets, personal paths, generated evaluation runs, binaries, and local
  TinyKG stores out of Git. The manifest-pinned release assets under
  `vendor/tinykg/bin/` and `vendor/ripgrep/bin/` are the only binary
  exceptions; both are manually reviewed upstream artifacts pinned by SHA-256
  and inventoried by their verify scripts.
- Use `rg`/`rg --files` for discovery and `apply_patch` for source edits.
- Do not overwrite unrelated worktree changes. Destructive Git commands require
  explicit authorization.
- Public API changes must update `doc/API.md`, the normative protocol document,
  SDK fixtures, and an end-to-end consumer test in the same change.
