# CI design: PR validation, release targets and the legs

`ci.yml` runs the AGENTS.md pre-submit checklist on three platforms plus the
offline TTY suites. This document covers how a required job skips work (§1),
which of that work a change has to pay for (§2), how approved PRs
land after validation against current main (§3), and how one
platform's work is spread over several runners so that a run takes about as
long as its longest leg rather than the sum of a platform's steps (§4),
which run writes the caches the others read (§5), and where the macOS and
Windows gates run: a self-hosted VM pool first, the hosted legs as the
fallback (§6).

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

The switches below decide which steps run. Each one fails open: an empty value,
meaning its decision job failed, runs the step.

| Switch | Decided by | Effect |
|---|---|---|
| `FAST_PATH` | `Release fast path` job (`scripts/release_fast_path.py`) | `true` for a generated release or reopen bump over a green base: only the checkout and the version state gate run ([RELEASE_AUTOMATION_DESIGN.md](RELEASE_AUTOMATION_DESIGN.md) §3). |
| `SUITES` | `Change scope` job (`scripts/ci_scope.py`) | `false` for a documentation-only change: the POSIX `checks` legs run only the documentation, version-state and gate-manifest checks, the other gate legs only check out, and the Windows legs run nothing. |
| `TTY` | `Change scope` job | `false` for a change confined to documentation and the evaluation harness: the TTY shards run nothing. The `SDK bindings` jobs read the same output as `SDK`. They are not required, but they report the same way, so they can become required without holding such PRs. Those jobs also rehearse a formal AgentCore release on the real build ([RELEASE_AUTOMATION_DESIGN.md](RELEASE_AUTOMATION_DESIGN.md) §2a). |
| `DOC_REFERENCES` | `Change scope` job | Runs protocol path/pin validation on the Linux checks leg when a protocol-listed path changes, or the protocol's documentation path list changes. |
| `RELEASE_DOCS` | `Change scope` job | Runs documents-only release staging, byte/inventory verification and notices checks on the Linux checks leg when a source in `release/documents.json` changes. Only this leg installs Zig for a narrow release-document change; it builds no application or Lean kernel. |

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
In a legacy merge queue group it is the group's `base_sha`. Renames count as a delete
plus an add. A move remains documentation when both paths are document
inputs; moving into a code/input tree takes the wider scope.

| Scope | Every changed path is | What runs |
|---|---|---|
| `docs` | `doc/**`, top-level `*.md`, release-document sources, plus protocol edits limited to documentation paths; additions, edits and deletions | Documentation links/facts, their tests, gate manifest, version state and whitespace; independently selected protocol references and release-document checks |
| `eval` | documentation, `scripts/eval/**` or `evals/**` | All three gates in full; the TTY jobs report success without running |
| `full` | anything else | Everything |

Manual and scheduled runs are always `full`, and so are an empty diff and
any error. Neither CI workflow runs on ordinary pushes to main; their nightly
run on main is a full run that saves the caches (§5).

The scope step writes a **CI change attribution** job summary: the base,
event, effective scope, reason, planned checks and a status/path/scope table.
The decision considers every changed path; the table displays at most 200.
A path's narrow scope does not override a wider scope required by another
path or by unavailable attribution inputs. This is a plan, not test-result evidence.

`agentcore-windows.yml` keeps its native-gate path filter for pull requests
and legacy merge groups. Required jobs
continue reporting under their existing names; a missing scope output runs
the expensive steps.

The document checks have separate boundaries:

- **Links and documented facts.** These existing cheap checks run on every
  documentation change, including deletion and relocation, and catch broken
  backlinks and fact registrations.
- **Protocol references.** A change to a path named in
  `evals/plugin-v1/protocol.json` runs
  `python3 scripts/eval/plugin_release_gate.py --validate-only`
  (`zig build doc:references`). This checks regular paths, schema and
  candidate/scenario/evaluator pins without a product build or provider
  request. The implementation fingerprint remains stale between freezes by
  design. A protocol edit can stay in `docs` only when its parsed before/after
  values differ solely in documentation entries of `implementation_paths`;
  non-document paths, budgets, runtime pins and all other fields must retain
  their values and types. Other protocol edits keep the evaluation suites.
- **Release documents.** `release/documents.json` is shared by
  `release:stage` and `release:docs`. The latter copies only those documents
  and licences. `zig build release:docs:check --prefix <empty-directory>`
  additionally checks generated notices and verifies that each installed byte
  matches its source, the versioned changelog name is correct, and the prefix
  contains exactly the document inventory. README, changelog, notices and
  listed licence changes trigger this check without compiling binaries.
- **Type changes and unknown metadata.** A file changed into a symlink, an
  unreadable source manifest or an unclassifiable protocol edit takes the
  full scope. The check scripts and manifest definitions themselves take the
  full scope when changed.

The remaining boundaries are deliberately narrow:
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
to succeed; macOS and Windows through `Gates (macOS)` and `Gates (Windows)`,
wherever the gates ran (§6). Only full-scope, non-fast-path PR runs upload `pr-ci-evidence`:
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
| `gates-macos-vm` | `all`, on a pool VM (§6) | Every flag of the `gates-macos` legs in one job |
| `windows-gates` | `units`, `integration`, `product`, `release` | One flag each |
| `windows-gates-vm` | `all`, on a pool VM (§6) | Every flag of the `windows-gates` legs in one job |
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
  macOS jobs; the self-hosted pool (§6), when it is on, takes the gates off
  that limit.
- **Cache lines.** Each gate leg keeps its own Zig cache line
  (`gates-<leg>`, §5), since each builds a different share of the graph. The
  TTY shards build the same binaries and share one.
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

## 5. Caches: main writes, pull requests read

Every runner starts empty, so a job compiles only what it cannot restore.
Until November 2026 every run both restored and saved, through setup-zig's
`use-cache` and `actions/cache`, and two things went wrong (measured
2026-11-18):

- **The first run of every pull request compiled cold.** A run can restore
  what its own ref saved and what its base branch saved, never another pull
  request's caches. Pull requests saved only to their own ref, and since main
  pushes stopped running CI (§3) nothing saved to `main`: it held three
  entries, a macOS Lean cache, one 92 MB Zig cache and the Zig tarball.
- **Pull requests crowded each other out.** Cache keys are immutable, so
  every run saved a new copy of every line: 2 to 2.9 GB per run of a pull
  request. The repository held 12.3 GB against GitHub's 10 GB, and GitHub
  evicts the least recently used entries, so a pull request's entries could
  be gone before it pushed again.

So one run writes and every other run reads:

| Run | `WARM_CACHE` | Zig cache | Lean toolchain and products |
|---|---|---|---|
| `main`'s `schedule` run (19:00 UTC nightly) or a `workflow_dispatch` on `main` | `true` | Starts empty; each line saves what it built under `zig-0.16.0-<os>-<arch>-<line>-run-<run id>-<attempt>` | Restores; the `units` leg saves when no entry holds this hash of the Lean sources |
| Everything else: pull requests, a legacy merge group, a dispatch on another branch | `false` | Restores the newest entry `main` saved for its line (that key without the run ID, matched as a prefix); saves nothing | Restores; saves nothing |

A line is a gate leg (`gates-<leg>`), a platform's TTY shards (`tty`, saved
by shard 1), a platform's SDK job (`sdk`) or the AgentCore Windows gate
(`agentcore-gate`, `agentcore-windows.yml`). setup-zig still points
`ZIG_GLOBAL_CACHE_DIR` and `ZIG_LOCAL_CACHE_DIR` at `.zig-cache`, with its own
cache off because it saves on every run; `actions/cache` (restore, then save
at the end of the job) gave way to `actions/cache/restore` and
`actions/cache/save` for the same reason. setup-zig still caches the Zig
tarball itself (about 50 MB) under an exact key and saves it only on a miss,
so once `main`'s warm run holds it a pull request only reads it.

**Why nightly, not after every merge.** Zig 0.16's build runner cannot
compile tests without running them, so warming a line means running it. A
run after every merge would bring back the post-merge full run §3 removed,
and take macOS jobs during the working day. A cache a few hours old costs
little: Zig recompiles every artifact whose sources changed, so a pull
request that changes `src/` rebuilds the app and the large test binaries
from either cache. What `main`'s cache saves is what changes rarely: Zig's
runtime libraries, the Lean products, TinyKG staging, the tools, and test
binaries the change does not reach. Dispatch `CI` on `main` to warm at once,
for example after a Zig or Lean toolchain bump.

**What it costs.** One full CI run a night, about thirty jobs and four on
macOS, which also reports `main`'s health. A pull request's second push
restores `main`'s cache, not its own first run's; it recompiles what its
change reaches either way. The warm run starts each Zig line empty, so an
entry holds only what the current tree builds and does not grow night after
night (setup-zig's `cache-size-limit` guarded against that growth before);
earlier nights' entries are no longer read and are evicted first.
`rule-control.yml` (dispatch only) and `release.yml` (no Zig cache) keep
their own settings.

`scripts/tests/test_ci_scope.py` (`CacheTest`) pins the wiring: nothing but
the warm run saves; each restore key is its save key without the run ID, and
both run wherever Zig is set up; `WARM_CACHE` is true only for `main`'s
scheduled or dispatched run.

## 6. The macOS and Windows gates: a self-hosted runner first, hosted legs as the fallback

Each of the two platforms has a self-hosted runner for this repository:
macOS on the organization's Mac Studio, Windows on AIPC. The gates of an
organization member's pull request try it first; every other pull request
stays on hosted runners.

**For now, a runner on the host.** Since 2026-11-19 macOS uses
`MacStudio-metacodes`, a runner on the Mac Studio's own `ci-host` account (no
VM: an idle macOS guest took all 32 GB), in the runner group
`metacodes-public-ephemeral` with the label `metacodes-macos-vm`, one job at
a time (`slots: 1`). Windows stays switched off until AIPC has a runner.
Nothing isolates one job from the next or from the host account, so the
guard is who gets there, in two places:

- **The plan** sends a pull request to the runner only when GitHub reports
  its author as an organization `MEMBER` or `OWNER`, or as a `COLLABORATOR`;
  everyone else, and an unknown association, goes `hosted` ("external
  contributor"). It never decides by fork: most members open pull requests
  from their own forks.
- **The runner**, whatever a pull request's own `ci.yml` asks for: a hook
  before every job lets through only organization members and collaborators
  with write access and fails any other job. That is the boundary, since a
  pull request runs its own copy of this plan; the plan only keeps external
  pull requests from turning red there. Outside contributors' fork pull
  requests also wait for a maintainer's approval before any workflow runs.

`COLLABORATOR` counts because GitHub reports a member whose membership is
private that way when they have direct access to the repository, as the
runner's hook does for collaborators with write access. The repository has no
outside collaborators (checked 2026-11-19); adding one with write access
would let their pull requests use the runner too. A private member without
direct access shows as `CONTRIBUTOR` and stays on hosted runners until they
make the membership public. The single-use VM pools
([VM_POOLS.md](VM_POOLS.md)) are kept for AIPC or a later host and would
serve the same labels and wiring. Below, "pool" means whichever runner
serves a platform's label.

Hosted macOS is the bottleneck: five jobs at once for the organization, three
cores and 7 GB each. On 2026-11-17/18 a macOS job waited a median 7.5 minutes
for a runner (p90 27.8) while Linux and Windows waited seconds, and macOS
finished last in 38 of 39 runs. Hosted Windows does not queue (median 0.1
minutes; the legs ran a median 7.2 minutes); its pool can win only on a job's
own speed, so each platform has its own switch and its own measurements.

**One job on a VM, legs on hosted runners.** A pool VM has the cores and
memory a hosted runner lacks, so `gates-macos-vm` and `windows-gates-vm` run
every flag of their hosted legs in one job (`Gates (macOS) / all`, `Gates
(Windows) / all`, the platform's shared step list, its own cache line
`gates-all`), without the legs' repeated checkout, setup and compilation.
Hosted runners keep the split legs of §4. TTY (Windows), the SDK jobs and
AgentCore Windows stay on hosted runners.

**The switch.** `.github/runner-pools.json` holds, per platform, `self_hosted`
(on or off), the pool's `label`, its `slots`, the `pickup_timeout_minutes`,
the pool job's `zig_build_jobs` and `timeout_minutes`. A file, not a
repository variable: vars and secrets do not reach a fork's pull request,
which most pull requests here are, while every pull request's merge commit
carries `main`'s switch. Switching a pool off is a pull request whose own run
already obeys it.

**Where a run goes** (`runner-plan`, `scripts/ci_pool_plan.py plan`). With the
run's read-only token it lists this repository's other CI jobs once, counts
per platform those that hold or wait for one of its pool's VMs, and decides
each platform, first match wins:

| Situation | Mode |
|---|---|
| Switch off, unreadable or invalid | `hosted` |
| Release fast path, or a documentation-only change | `hosted` (the gates only check out) |
| `main`'s warm run (§5) | `both`, so both cache lines stay warm |
| Not a pull request, or its author is not an organization `MEMBER`, `OWNER` or `COLLABORATOR` | `hosted` |
| Running plus waiting pool jobs fill the slots | `hosted` |
| A pool job has waited longer than the pickup timeout | `hosted`: the pool may be down |
| Otherwise | `self-hosted` |
| Any error reading GitHub | `hosted` |

**Falling back after dispatch.** Two runs can see the same free slot, and a
pool can fail after a run chose it. `gates-macos-watch` and
`windows-gates-watch` (`… watch`) follow their run's pool job: a VM that
takes it within the pickup timeout is followed to the end and its conclusion
reported; otherwise `fallback=true`, and the hosted legs, which wait for the
watch on `self-hosted`, run. If a VM takes the pool job after that, its
stand-down step sees the finished watch and sets `FAST_PATH=true`, so every
later step skips (the pool job's env leaves `FAST_PATH` to that step).

**The required checks** (`gates-macos-result`, `gates-windows-result`, `…
verdict`) never need a pool job: a pool that is down would keep it queued for
GitHub's 24 hours. Each reads its platform's plan, watch and hosted legs:

| Mode | `Gates (macOS)` / `Gates (Windows)` passes when |
|---|---|
| `hosted`, or no plan | the hosted legs succeeded |
| `self-hosted` | the watch reports the pool job succeeded; after a fallback, the hosted legs succeeded |
| `both` | the hosted legs succeeded, and the pool job succeeded or no VM took it |

A pool job that fails (a test, or its VM) is a failure, not a fallback;
rerunning the run decides again. Costs: the plan adds a few seconds before
the macOS and Windows gates; a run on a pool keeps an ubuntu watch job beside
it; a fallback after dispatch costs the pickup timeout; on the nightly `both`
run the hosted legs start after the pool job ends, since they wait for the
watch; a pool job no VM ever takes stays queued in its run until a VM takes
it (and stands down) or GitHub's 24 hours pass, without affecting the
required check.

`scripts/tests/test_ci_pool_plan.py` pins the decisions, the watch, the
stand-down and the verdict for both platforms, and the wiring: each pool job
is every hosted leg of its platform in one, the required checks never need
them, and only they use the pools' labels (no workflow uses `self-hosted`).
