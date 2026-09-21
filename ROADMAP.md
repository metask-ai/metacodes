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
| M1 | CI healthy and fast on real runners | **Done** (hosted runners; record first-run durations) |
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

CI runs on GitHub-hosted runners (`ubuntu-latest`, `macos-latest`,
`windows-latest`). The repository is public, hosted standard runners are free
for public repositories, and organization policy keeps public repositories off
the organization's self-hosted fleet (2026-09-21). The self-hosted era below is
kept as the evidence trail for the gate design; its runner-specific machinery
(persistent caches, fork-isolation guards, per-machine concurrency lanes) is
gone.

- [x] Self-hosted workflow migration implemented and validated by dispatch runs
      (all CI jobs green at validation time). Superseded by the hosted-runner
      migration below.
- [x] `zig build test` passes on a clean checkout without a Lean toolchain:
      the olean-gated manifest cases skip explicitly, and CI builds Lean, runs
      them, and escalates that skip to a failure via
      `METACODES_TEST_REQUIRE_LEAN_SDK` (the native-driver Lean lifecycle
      cases remain opt-in via their `METACODES_TEST_PROJECT_*` env fixtures).
- [x] CI green on `main` push (merge commit af1ea06: CI and AgentCore Windows
      both succeeded on the self-hosted fleet).
- [x] Default CI wall-clock under ~15 min per platform with warm caches on the
      self-hosted fleet. Evidence trail: af1ea06 (three jobs per platform)
      measured ≈ 13 min wall, dominated by the macOS test job queueing ~5 min
      behind its sibling jobs on the single macOS runner; after consolidating
      to one `Gates` job per platform plus persistent Lean products (94c20ee):
      wall 9:14; after dropping lean-action's per-run elan reinstall
      (795bdb3), steady-state **execution** was Linux 1:39 / macOS 5:59 /
      Windows 0:41 with the Lean step at 2 s (cache hit). Heavyweight gates
      (`rule-control`, AgentCore Windows) stay in their own workflows.
- [x] Windows leg runs the repository-wide suite (#53, PR #54). Until then the
      `windows-gates` job only ran the platform modules and bundle checks; the
      full `zig build test` had no Windows CI at all and portability
      regressions accumulated silently (1 compile error, 8 unit tests, 8
      integration shards, 330 Python cases when first run). Kernel-gated tests
      skip on this leg by design (no elan on the Windows leg; `testKernel()`
      returns null on Windows); the paid budget journal, dir_fd-anchored
      publication and anonymous inherited descriptors are POSIX-only and skip
      with stated reasons (`scripts/eval/tests/posix_only.py`).
- [x] Shared-runner serialization (#52 suggestion 3) — the per-machine
      `concurrency` lanes that kept `Gates (Windows)` and AgentCore Windows
      from overlapping on one box (the -j12 AgentCore compile beside the full
      suite was the load behind the #51/#52 flakes). Removed with the move to
      hosted runners: every job has its own machine. `--test-timeout 5m`
      remains the watchdog on every leg.
- [x] Hosted-runner migration (2026-09-21). Every workflow targets
      `ubuntu-latest` / `macos-latest` / `windows-latest`; the fork-isolation
      `if:` guards are gone (a fork PR now runs on an ephemeral machine with a
      read-only token, and a required check that never reports would block the
      PR); Zig caches go through `mlugg/setup-zig`'s `use-cache` (one
      content-addressed directory keyed by OS and Zig version, dropped above
      4 GiB instead of saved); the Lean toolchain and `control-plane/lean/.lake`
      go through `actions/cache` keyed by the pinned toolchain and every Lean
      source; elan installs from a pinned release asset with a pinned SHA-256
      (`scripts/ci/install-elan.sh`, a no-op on a cache hit); PyYAML installs
      from `requirements-dev.txt` on every leg. Timeouts are 45 min per gate
      job (a cold hosted runner compiles the whole tree and the Lean kernel).
      Measured on PR #137 (2026-09-21): cold (no setup-zig/Lean cache) Linux
      13:31, macOS 12:36, Windows 13:57, AgentCore Windows 13:40; warm
      Linux 15:17, macOS 9:26, Windows 4:35, AgentCore Windows 12:50. The
      remaining Windows exposure is tests that still spell fixtures as a
      fixed `/tmp/...` path: they share one directory across the eight
      parallel shards and depend on `\tmp` at the drive root. The 2026-09-21
      losses (four at once on PR #137's second run, two at main@fd8165f1)
      had one cause, found by sampling `D:\tmp` on hosted runners with
      per-test wall-clock stamps: `provider_offer_test`'s OAuth fixtures sat
      directly in `/tmp` and their teardown `rmdir`'d `dirname(path)`, i.e.
      `/tmp` itself; a no-op on POSIX, but on a fresh Windows runner the
      prelude has just created `\tmp` empty, so the call succeeded and every
      `/tmp` fixture in the concurrent shards failed with ENOENT until some
      `mkdirParents` recreated it. Fixed by keeping every fixture in its own
      directory below a per-process root and failing loudly when a teardown
      would reach the temp root. 21 suite files (93 literals) still use
      `/tmp/...`; migration to per-process `%TEMP%` fixtures
      (`src/tools/test_tmp.zig`, `util/fs.zig testing.perPidDir`) remains
      the plan, and the `windows_test_prelude` stays until the last literal
      is gone. Test fixtures must never `rmdir` a directory they did not
      create.
- [x] Release-gate isolation: `rule-control` and every `release.yml` job run
      on ephemeral hosted runners, so PR-authored code cannot precondition the
      machine that produces a release decision. The dedicated
      `metacodes-release` self-hosted pool is no longer planned
      ([doc/RELEASE_RUNNER.md](doc/RELEASE_RUNNER.md)).

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
      (currently only `aarch64-macos` is fully verified at revision 15).
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
