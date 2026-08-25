# Roadmap

Project status is tracked as milestones. Each milestone has explicit exit
criteria and links to the evidence that closes them; status changes land as
pull requests to this file. Dates are not promised — a milestone is *done* when
its criteria are met, not when a calendar says so. After public launch these
milestones can be mirrored to GitHub milestones/issues; this file remains the
source of truth.

Current version: pre-1.0, declared by `build.zig.zon` (code copy in
`src/version.zig`, agreement enforced by `zig build test`). Repository is
pre-publication; see [OPEN_SOURCE_READINESS.md](OPEN_SOURCE_READINESS.md).
The table below is the single status ledger; section headings stay stable.

| Milestone | Theme | Status |
|---|---|---|
| M0 | Standalone repository baseline | **Done** |
| M1 | CI healthy and fast on real runners | **In progress** |
| M2 | Open-source publication | **Blocked on owner decisions** |
| M3 | Benchmark evidence | **In progress** |
| M4 | Interface freeze (v0.2) | Planned |
| — | v1.0 horizon criteria | Defined below |

## M0 — Standalone repository baseline

Extracted from the original monorepo with history preserved; `main` is the
primary branch.

- [x] Independent build/package root; standalone CI definitions.
- [x] TinyKG source replaced by the cross-platform SHA-256-pinned binary bundle
      with an explicit override contract ([doc/TINYKG_INTEGRATION.md](doc/TINYKG_INTEGRATION.md)).
- [x] Contribution, governance, conduct, support, security, third-party docs.
- [x] Public API and embedding-surface inventory ([doc/API.md](doc/API.md)).
- [x] Documentation governance pass: superseded process/design-iteration docs
      removed, dangling doc references repaired, doc index covers the living
      set ([doc/README.md](doc/README.md)).

## M1 — CI healthy and fast on real runners

GitHub-hosted runners are currently unavailable for this account (billing), so
CI targets self-hosted runners (Linux X64, macOS ARM64, Windows X64).

- [x] Self-hosted workflow migration implemented and validated by dispatch runs
      (all CI jobs green at validation time).
- [x] `zig build test` passes on a clean checkout without a Lean toolchain:
      the olean-gated manifest cases skip explicitly, and CI builds Lean, runs
      them, and escalates that skip to a failure via
      `METACODES_TEST_REQUIRE_LEAN_SDK` (the native-driver Lean lifecycle
      cases remain opt-in via their `METACODES_TEST_PROJECT_*` env fixtures).
- [x] Zig caches persist per runner (checkout's workspace clean no longer
      forces cold rebuilds); pull-request jobs carry a fork-isolation guard.
- [x] CI green on `main` push (merge commit af1ea06: CI and AgentCore Windows
      both succeeded on the self-hosted fleet).
- [x] Default CI wall-clock under ~15 min per platform with warm caches
      (post-cache-fix: Linux ≈ 4.5 min, macOS ≈ 9 min, Windows gates ≈ 2 min);
      keep it there — heavyweight gates (`rule-control`, AgentCore Windows)
      stay in their own workflows.
- [ ] Release-gate isolation: `rule-control` currently shares the
      `[self-hosted, macOS, ARM64]` label set with pull_request CI jobs;
      before public visibility, give it a dedicated or ephemeral runner so
      PR-authored code cannot precondition the machine that produces release
      decisions.
- Runner prerequisites: `python3`, `git`, and either preinstalled `rg` or
  passwordless `sudo apt-get` (Linux) / Homebrew (macOS) for ci.yml's
  presence-guarded ripgrep install; missing prerequisites fail the job loudly.
- Owner alternative: restoring GitHub-hosted billing would re-enable
  `ubuntu-latest`/`macos-latest` as a fallback matrix.

## M2 — Open-source publication

The tracked checklist — and the authoritative checkbox state — is
[OPEN_SOURCE_READINESS.md](OPEN_SOURCE_READINESS.md); it is deliberately not
mirrored here. Blocking items are owner decisions, not engineering tasks:
license selection (SDK staging currently declares `NOASSERTION`),
organization/repository ownership and public naming, private security and
conduct-reporting contacts, the independent full-history secret scan and
history-publication decision, plus the launch-gate hardening steps (branch
protection, required CI, private vulnerability reporting, least-privilege
Actions, self-hosted runner isolation, immutable checksummed pre-release
tag). M2 closes when that checklist is complete.

## M3 — Benchmark evidence

Protocols, current results, and claim boundaries live in
[doc/BENCHMARKS.md](doc/BENCHMARKS.md).

- [x] Evaluation control plane (rollout model, paired stats, budget receipts,
      release gate) with its own test suite (`zig build test:eval`).
- [x] WorkBuddy-Bench integration: pinned framework, separable overlay,
      anti-contamination cohorts, W0/W0.5 zero-provider slices passed.
- [x] Internal paired baselines recorded (plugin-v1 pairs; dev16 campaign
      directional results; long-horizon calibration fail-closed lessons).
- [ ] Internal attribution ladder to a frozen candidate (single-factor TinyKG,
      single-factor Lean, 2×2 factorial with preregistered analysis).
- [ ] WorkBuddy W1 Code canary re-run; then W2–W6 dev regression (per-stage
      status: the ladder table in [doc/BENCHMARKS.md](doc/BENCHMARKS.md)).
- [ ] Promotion A/B unseen batches; sealed-156 held-out run (one-shot).

## M4 — Interface freeze v0.2

Freeze the surfaces hosts depend on. Preconditions are already written down:

- [ ] AgentCore ABI v1 stability freeze: close the open items in
      [doc/AGENTCORE_V1_EXPERIMENTAL_LEDGER.md](doc/AGENTCORE_V1_EXPERIMENTAL_LEDGER.md),
      then pass the reference-closure audit and the real-consumer gate
      ([doc/AGENTCORE_BINARY_ABI.md](doc/AGENTCORE_BINARY_ABI.md)).
- [ ] Re-verify the full supported-target matrix at the frozen revision
      (currently only `aarch64-macos` is fully verified at revision 13).
- [ ] Plugin manifest/process-protocol v1 freeze with negative-test coverage.
- [ ] CLI: versioned `--version`/`--help` surface and changelog discipline for
      flag changes.

## v1.0 horizon

Not scheduled; requires all of the above plus:

- sealed-cohort external benchmark results published with receipts;
- cross-platform release gates (ReleaseSafe + AgentCore consumer) green on the
  supported matrix;
- at least one external (non-author) AgentCore consumer in production use;
- semantic-versioned compatibility promises for CLI, Zig module, and ABI
  bundles.
