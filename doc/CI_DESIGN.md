# CI design: PR validation, release targets and the legs

`ci.yml` runs the AGENTS.md pre-submit checklist on three platforms plus the
offline TTY suites. This document covers how a required job skips work (§1),
which of that work a change has to pay for (§2), how approved PRs
land after validation against current main (§3), and how one
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

Manual runs are always `full`, and so are an empty diff and any error.
Neither CI workflow runs on ordinary pushes to main.

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

## 3. PR-only validation and merge policy

Run full primary-platform CI on `pull_request`, then merge the exact reviewed
head. Ordinary pushes to `main` do not repeat that run. The four required
check names and their GitHub Actions source stay unchanged. `Protect main`
must require branches to be up to date and must not require a merge queue.
If main advances, merge main into the PR branch and repeat review and CI.
A busy main can therefore still require several updates.

The [local watcher](PR_AGENT_LOOP.md) makes an ordinary merge commit for a
stale branch, validates it through `dx`, pushes it, and waits for fresh
review and PR CI. Conflicts go to the original worker. Before merging it
rechecks head/base and effective branch rules, then calls the merge API with
the reviewed head SHA. Strict server-side checks close the race where main
moves after that recheck. No deferred auto-merge or admin bypass is used.

### Policy migration

After deploying the workflow and watcher, a repository rules administrator
previews and applies the migration from a checkout containing the tooling:

```sh
python3 .github/pr-policy.py
python3 .github/pr-policy.py --apply
```

The preview prints existing and proposed rules. The write fetches the current
ruleset, removes only `merge_queue`, enables strict required status checks,
and preserves every other protection, check source and bypass actor. It
refuses inactive or broad rulesets and verifies effective main rules after
the write. It refuses to write if GitHub hides the bypass-actor list, rather
than replace a ruleset whose complete contents it cannot read. Restart local
watchers from the updated checkout before cutover. A maintain role alone
cannot apply it. The watcher refuses direct
merges until this policy is active.

The workflows retain `merge_group` as migration compatibility, so this change
can land under the old rules. After the queue rule is removed those events
are not emitted. Existing queued PRs are left alone by an upgraded watcher.
The legacy handler diffs against `base_sha` and retains release version
ordering checks; it is not the normal delivery path.

### Reusable full-CI evidence

`Full PR evidence` waits for every CI suite, including SDK and Windows TTY,
to succeed. Only full-scope, non-fast-path PR runs upload `pr-ci-evidence`:
the tested merge commit/tree, head/base, repository, run ID and attempt.
The release fast path finds a merged PR for the exact base commit, requires
a successful run of `ci.yml`, and compares downloaded evidence with the base's
actual Git tree. Head-only checks, docs/eval/fast-path runs, unrelated trees,
push runs and missing or expired artifacts do not prove full validation.
Evidence expires after 90 days; expiration costs a full run.

### Platform allocation

| Platform | PR CI | Release |
|---|---|---|
| Linux x86_64, macOS ARM64, Windows x86_64 | Full native suites, subject to scope rules in §2 | Native release suites and artifacts |
| Linux ARM64 | No extra cross-stage leg | Native ARM64 release suite plus musl cross-stage check |
| macOS x86_64 | No Intel cross-build | Native Intel release suite and executable baseline check |
| Windows ARM64 GNU/MSVC | No cross-build | SDK cross-build and consumer link checks, required before drafting |

Windows ARM64 is not a native runtime test or supported CLI release unit:
there is no ARM64 Windows TinyKG bundle. Lightweight manifest and installer
fixture tests stay in PR CI; they do not build every target. Formal release
builds remain cold and tied to the release ref.

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
| `gates-linux` | `units`, `product`, `release`, `checks` | One flag each, below |
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
| `release` | The bundle verification, the install prefix, kernel provenance and staging, the release layout, `install.sh` (`install.ps1` on Windows) and the reproducible archive; on POSIX also the footprint red lines (`scripts/perf_baseline.sh`, report-only: written to the job summary, never fails the leg); on macOS also its native ARM64 executable built for the release target and held to it (`scripts/check_binary_baseline.py`); on Windows also the version state gate and the Windows script suites |
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
| A step in `ci.yml` | The leg flag of the work it belongs to (`units`, `integration`, `product`, `release`, `checks`) | Those legs | `test_ci_scope.py`: only the listed setup steps carry no flag, and every flag is set by a leg |
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
