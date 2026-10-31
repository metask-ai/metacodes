# CI design: required checks, change scope, the merge queue and the legs

`ci.yml` runs the AGENTS.md pre-submit checklist on three platforms plus the
offline TTY suites. This document covers how a required job skips work (§1),
which of that work a change has to pay for (§2), how a batch of approved PRs
lands without every PR merging `main` in and starting over (§3), and how one
platform's work is spread over several runners so that a run takes about as
long as its longest leg rather than the sum of a platform's steps (§4).

## 1. Required checks and how a job skips work

The `Protect main` ruleset requires `Gates (Linux)`, `Gates (macOS)`,
`Gates (Windows)` and `TTY (Linux)`. Each is a result job over that
platform's legs or shards (§4). The legs and shards always run and report
under their own names, and so do the result jobs. Work is skipped by step
conditions, never by skipping a job, for two reasons:

- A matrix job skipped by a job-level `if` reports under its unexpanded name
  (`Gates (Linux) / ${{ matrix.leg }}`), and a skipped result job would count
  as a passing required check.
- A workflow `paths` filter leaves the check pending the same way, which is
  how doc-only PRs were blocked in #134.

Three switches decide which steps run. Each one fails open: an empty value,
meaning its decision job failed, runs the step.

| Switch | Decided by | Effect |
|---|---|---|
| `FAST_PATH` | `Release fast path` job (`scripts/release_fast_path.py`) | `true` for a generated release or reopen bump over a green base: only the checkout and the version state gate run ([RELEASE_AUTOMATION_DESIGN.md](RELEASE_AUTOMATION_DESIGN.md) §3). |
| `SUITES` | `Change scope` job (`scripts/ci_scope.py`) | `false` for a documentation-only change: the POSIX `checks` legs run only the documentation, version-state and gate-manifest checks, the other gate legs only check out, and the Windows legs run nothing. |
| `TTY` | `Change scope` job | `false` for a change confined to documentation and the evaluation harness: the TTY shards run nothing. The `SDK bindings` jobs read the same output as `SDK`. They are not required, but they report the same way, so they can become required without holding such PRs. Those jobs also rehearse a formal AgentCore release on the real build ([RELEASE_AUTOMATION_DESIGN.md](RELEASE_AUTOMATION_DESIGN.md) §2a). |

`scripts/tests/test_ci_scope.py` pins the wiring:

- the gate steps that still run on a documentation-only change;
- that every other step of the legs and shards reads its switch, as
  `!= 'false'`, together with `FAST_PATH`;
- that each required check is a result job that passes only when every leg
  or shard under it succeeded (§4);
- which base each decision step diffs against, per event.

## 2. Change scope

`scripts/ci_scope.py` compares the changed paths against a base. On a pull
request the base is `HEAD^1`, the first parent of the merge commit CI tests.
In a merge queue group it is the group's `base_sha`. Renames count as a delete
plus an add, so moving a file out of `doc/` is a code change.

| Scope | Every changed path is | What runs |
|---|---|---|
| `docs` | `doc/**`, or a top-level `*.md` other than the three the release layout installs, added or edited (not removed or changed in type) | Documentation link and fact checks, their unit tests, the gate-manifest test, the version state gate and the diff check |
| `eval` | documentation, `scripts/eval/**` or `evals/**` | All three gates in full; the TTY jobs report success without running |
| `full` | anything else | Everything |

Push and manual runs are always `full`, and so are an empty diff and any
error.

The boundaries are deliberately narrow:

- **`README.md`, `CHANGELOG.md` and `THIRD_PARTY_NOTICES.md` are not
  documentation for this purpose.** `build.zig` installs all three into the
  release layout, and `gen_third_party_notices.py --check` regenerates the
  notices. A test checks the list against `build.zig`.
- **Removing or moving a documentation file is a code change.** Other files
  pin doc paths: `evals/plugin-v1/protocol.json` lists some in
  `implementation_paths`, which `zig build test` resolves. Adding or editing
  a doc file is harmless, because that fingerprint is stale by design.
- **Markdown outside `doc/` and the top level is an input.** Prompt templates
  are `@embedFile`'d, and agent and Skill fixtures are read by tests.
- **The evaluation harness keeps the gates.** `zig build test` runs its suites
  and the smokes against the built binary, for example
  `scripts/eval/chained_memory_smoke.py`. It skips only the TTY suites, which
  drive the interactive binary and read neither tree.

## 3. Merge queue

With the ruleset's "require branches to be up to date" policy, every merge to
`main` invalidates the green checks of every other open PR. Each PR must then
merge `main` in and run the full workflow again, and the PRs merge one after
another. With N PRs ready, that is close to N²/2 runs in series.

The merge queue removes the up-to-date requirement and tests what will
actually land:

- An approved PR joins the queue. The queue builds a temporary branch for it,
  `gh-readonly-queue/main/pr-<n>-<sha>`, with `main` plus every PR ahead of
  it and the PR itself merged in order. The workflow runs on that branch
  through the `merge_group` event.
- Each entry is tested once, on top of the entries ahead of it. Up to the
  build concurrency of these runs go in parallel. Up to that many queued PRs
  therefore take about one run's wall time and one run each, instead of
  runs in series plus a merge-`main`-and-rerun round for each PR still
  waiting.
- When an entry's run passes, the queue merges it together with the entries
  ahead of it that passed, up to the maximum group size, and `main` becomes
  exactly a tested tree. When it fails, the queue drops that PR and rebuilds
  the entries behind it without it.

`ci.yml` and `agentcore-windows.yml` run on `merge_group`. In a group:

- **Change scope** diffs the whole group against its `base_sha`, so a group
  of documentation PRs still skips the suites.
- **Release fast path** also diffs against `base_sha`. Only a group whose
  whole diff is the generated bump takes the fast path, which in practice
  means the bump queued alone.
- **Version state gate.** The event carries no pull request. The group's ref
  names the PR at its head, the newest entry, so the gate checks that PR's
  head branch, title and labels. The release PR therefore passes only as its
  group's head. A PR queued behind it sees the bare released version and is
  dropped from the queue, exactly as it would be refused on `main`, until
  the reopen PR has merged
  ([RELEASE_AUTOMATION_DESIGN.md](RELEASE_AUTOMATION_DESIGN.md) stage D).
  This relies on every entry having to pass its own run. Under "only the
  head must pass" (HEADGREEN), a PR queued just ahead of the reopen PR would
  merge with it although its own run was refused.

### Switching it on

The workflows above report on `merge_group` before the rule exists, so the
ruleset can be switched in one edit. A maintainer makes it in `Protect main`:

- **Required status checks:** keep the four checks, and turn off "require
  branches to be up to date before merging"; the queue provides that
  guarantee.
- **Add "require merge queue"** with these settings:
  - merge method: merge commit (the repository's history convention);
  - build concurrency 5: up to five entries tested at once, about thirty
    hosted jobs each, four of them on macOS (§4);
  - maximum group size 5 and minimum 1. With a minimum of 1 the wait time
    setting has no effect;
  - only merge non-failing pull requests (ALLGREEN), which the release
    ordering above relies on;
  - status check timeout 120 minutes. The long pole is a version-bump entry:
    `Release fast path` can wait up to 45 minutes for the base's push run
    before the gates start, and then they run in full if that run was not
    green.

### What stays the same

Pushes to `main` still run the full workflow. The release fast path needs
that run, because its base check is the base commit's push run
(`release_fast_path.py`). When merges land back to back, the concurrency
group cancels the older push run. A release or reopen PR whose base run was
cancelled then takes the full path, which costs one run and never coverage.

Once the queue merges every PR, the push run repeats an entry's run on the
same tree. Replacing it, for instance with a nightly full run plus a
fast-path base check that accepts the merge group run, is the next step and
is not designed here. The per-PR `pull_request` run also stays full for now;
with the queue as the final gate it could shrink to a subset.

## 4. Legs, shards and result jobs

Until October 2026 each platform's gates ran on one runner and the TTY
suites ran one case after another, so a run took about 31 minutes: Gates
(Linux) about 25, Gates (macOS) 22 to 33, Gates (Windows) about 19, TTY
(Linux) about 17 and TTY (Windows) about 31. Little of that is a single
long task:

- On a three-core macOS runner `zig build test` compiles about twenty
  artifacts that each take in most of the tree (the ReleaseSmall app and its
  shadow, the Debug app, the test binaries, the drivers), all through LLVM.
- Gates (Linux) ran the ReleaseSafe core suite, the arm64 cross-stage and
  the release layout one after another behind its suite.
- The TTY cases mostly wait for the screen to settle, a few seconds each.

So the work is spread over runners, and each required check is a result job
over its platform's share:

| Job | Runners | What each one runs |
|---|---|---|
| `gates-linux` | `units`, `product`, `release`, `cross`, `checks` | One flag each, below |
| `gates-macos` | `units-checks`, `product`, `release` | `units` and `checks` on one; one flag each on the others |
| `windows-gates` | `units`, `integration`, `product`, `release` | One flag each |
| `tty-linux` | three shards | Every third case of `tests/tty` |
| `tty-windows` | eight shards | Every eighth case, under ConPTY |

The gate flags (Windows has no `checks` leg; its version state gate runs on
`release`):

| Flag | Steps |
|---|---|
| `units` | `zig build test:units`, and on POSIX `test:integration` in the same build; the native platform modules (on `product` on Windows) |
| `integration` | Windows only: `zig build test:integration`, whose integration suite waits five minutes for the ReleaseSmall app there |
| `product` | `zig build test:product` (the smokes, and the evaluation suite as three shards), with the pinned WorkBuddy-Bench checkout (POSIX); the native platform modules on Windows |
| `release` | The bundle verification, the install prefix, kernel provenance and staging, the release layout, `install.sh` (`install.ps1` on Windows) and the reproducible archive; on POSIX also the footprint red lines (`scripts/perf_baseline.sh`, report-only: written to the job summary, never fails the leg); on Windows also the version state gate and the Windows script suites |
| `cross` | Linux only: the arm64 cross-stage, a third ReleaseSmall build |
| `checks` | `zig fmt`, the version state gate, `zig build test:lib -Doptimize=ReleaseSafe`, the coverage audit, the documentation checks and notices (Linux), the script unit suites and `git diff --check` |

The rules that keep the split from dropping coverage:

- **`zig build test` is exactly its three parts.** In `build.zig`, `test`
  depends on `test:units` (the unit and component test binaries and the
  script unit suites), `test:integration` (the integration suite, which runs
  against the installed ReleaseSmall CLI, and the spikes) and
  `test:product` (the built product end to end: the evaluation harness, the
  smokes, the daemon, the TinyKG transport), and nothing else is wired into
  it. Every part runs with the same options.
  `scripts/tests/test_gate_manifest.py` checks both, and
  `scripts/tests/test_ci_scope.py` that every platform runs all three. A new
  check goes into one of the parts; wired straight into `test`, it would run
  on no CI runner.
- **Every step a flag gates runs on some runner.** A step without a flag is
  environment setup (the checkout, Zig, Lean, ripgrep, bubblewrap, the
  Python dependencies) and runs on every leg, so each leg sees the
  environment the single job had. `scripts/tests/test_ci_scope.py` checks
  that every flag a step reads on a platform is set by one of its legs, and
  that both POSIX jobs run one step list (a YAML alias).
- **A result job passes only when every leg did.** `Gates (Linux)` and the
  other result jobs need their leg job, run under `always()` so that they
  are never skipped, and pass only if every need's result is `success`. A
  failed, cancelled or skipped leg fails the check. `TTY (Windows)` is not
  required, but it reports the same way so that it can become required.
- **The TTY shards partition the cases.** `run_tty_tests.py --shard K/N`
  (or `TTY_SHARD`) runs the cases whose index in the sorted list is `K-1`
  modulo `N`; a TTY case checks that the shards cover the list exactly once.
  Shards run on separate runners, not concurrently on one, because the
  cases assert pty timing.

What it costs:

- **Duplicate compilation.** Each leg compiles what its steps need, so the
  ReleaseSmall app, for example, is built on several runners of a platform.
  Hosted standard runners are free for a public repository; only wall time
  is scarce.
- **Concurrency.** The organization runs at most 60 hosted jobs and five
  macOS jobs at once. A run uses about thirty jobs, four of them on macOS
  (three gate legs and `SDK bindings (macOS)`), so macOS groups the flags
  instead of giving each its own runner. Runs that overlap can still queue
  macOS jobs.
- **Cache lines.** Each gate leg keeps its own setup-zig cache
  (`cache-key: ${{ matrix.leg }}`), since each builds a different share of
  the graph. The TTY shards build the same binaries and share one.
- **Build runner jobs.** The suite steps pass `-j$ZIG_BUILD_JOBS`: 8 on the
  four-core Linux and Windows runners, 6 on the three-core macOS one, whose
  7 GB cannot hold more overlapping LLVM builds. The build runner runs that
  many steps at once, one per core by default, and a run step keeps its slot
  while its child mostly waits. At one per core the smokes kept the two
  drivers the evaluation suite needs from compiling for several minutes.
- **Commands that inherit the terminal run one at a time.** The build
  runner holds its stderr lock while such a command runs, whatever `-j`
  says. The smokes still do, so they run in series. The evaluation suite
  ran behind them as one such process and was the longest; it now runs as
  three shards with captured output (`scripts/eval/tests/run_shard.py`,
  every third module group), beside the smokes and each other. The
  plugin-v1 modules are one group: one of them edits a pinned input of the
  live checkout and restores it, and the first merge-queue run of the
  shards caught another one, in a different shard, hashing that file. The build runner
  prints a captured command's output when it ends.

### Where a new check goes

Each kind of addition has one place, and the tests named here refuse the
ones that land nowhere:

| Adding | Goes into | Runs on | Enforced by |
|---|---|---|---|
| A Zig test in an existing root (`src/**`, `tests/component`, the integration inventory) | Nothing to wire | The part that compiles that root | The roots' own inventories and `scripts/test_coverage_audit.sh` |
| A new test binary or build step | `test:units` if it needs no installed product, `test:integration` if it runs the installed CLI, `test:product` if it drives the built product end to end | Every platform's legs for that part | `test_gate_manifest.py`: `test` is exactly the three parts |
| A module under `scripts/eval/tests/` | Nothing to wire, unless it shares state outside its own temporary directories with another module (the live checkout, a fixed path): then both declare one `EVAL_SHARD_GROUP`, and the group runs in one shard, in order | An evaluation suite shard of `test:product` | `test_run_shard.py`: the shards partition the modules, and the plugin-v1 group stays in one shard |
| A case under `tests/tty/cases/` | Nothing to wire | A TTY shard | The TTY case `test_runner_shards` |
| A suite under `scripts/tests/` | A command in a `test:*` part of `build.zig`, or a step with a leg flag in `ci.yml` | That part or leg | `test_gate_manifest.py`: every module runs on pull requests, or is listed with where it runs instead |
| A step in `ci.yml` | The leg flag of the work it belongs to (`units`, `integration`, `product`, `release`, `cross`, `checks`) | Those legs | `test_ci_scope.py`: only the listed setup steps carry no flag, and every flag is set by a leg |
| A smoke or another long command in `test:product` | Captured output (`expectExitCode(0)`) when it should overlap the rest; inheriting the terminal, it waits for every other such command | The product legs | Build Summary durations |

When a part outgrows its legs, the Build Summary of the slowest leg says
which steps to move; a new leg is a matrix entry plus, on Linux and Windows,
nothing else (macOS is held to three by the five-job limit).

The suite steps run with `--summary all`, so every run records the duration
of each build step. When one leg becomes the long pole, its Build Summary
says which steps to move: between the parts in `build.zig`, or between the
flags in `ci.yml`.

### Measured

The runs of the change that introduced the legs (#353). It touched no file
under `src/`, so from the second run on most compilations were cache hits;
a change to `src/` recompiles what depends on it, and its legs take longer.

| Run | Layout | Wall time |
|---|---|---|
| Before | One gate job per platform, one TTY job per platform | About 31 minutes (the 30 runs before) |
| 1 | First split, every cache cold | 20.4 minutes |
| 2 | The resume smoke's capture server answers in full; Windows halves | 13.8 minutes |
| 3 | Legs rebalanced from run 2's Build Summaries | 12.9 minutes |
| 4 | Three parts, three macOS legs, a Linux `cross` leg, six Windows TTY shards | 13.1 minutes, 10.9 without the 2.2 minutes a macOS leg queued behind another PR's run |
| 5 | Every cache line warm | 11.9 minutes |
| 6 | Suite steps at `-j8` (`-j6` on macOS) | 10.4 minutes |
| 7 | Evaluation suite as three captured shards, eight Windows TTY shards | 9.1 minutes |

In run 7 the longest jobs were Windows TTY shards (5.0 to 8.8 minutes; the
slowest holds a 78-second case and a slow debug build), Gates (Windows) /
product (8.2), Gates (macOS) / product (7.2) and Gates (Linux) / units
(7.1). The organization's job limits bound what more legs can buy: a run
uses about thirty-five jobs, so two overlapping runs already reach the limit
of 60, and four macOS jobs leave one of the five for every other run.
