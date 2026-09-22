# Release automation design: version bumping, cutting, tagging, publishing

Status: implemented 2026-09-22 (§8 lists the files). Builds on the mechanism that already exists
(`release:stage` → `release:manifest` → `release:check` / `release:verify` →
`release:archive` → `release:sums`, `.github/workflows/release.yml`,
`release/LAYOUT.md`, `doc/RELEASE_RUNNER.md`). Nothing here replaces those
steps; the design adds the missing front half (deciding the version and cutting
the release) and closes the gaps listed in §9.

## 1. Goals and non-goals

Goals:

- The version number is never typed by hand. It is derived from the commits
  merged since the last release and written to every place that carries it in
  one atomic change.
- A release is a reviewable pull request first and a tag second: the ruleset
  gates it exactly like any other change, and the tag is created only from the
  merge commit of that PR.
- Every artifact that leaves CI is traceable to one tag, one manifest and one
  `SHA256SUMS`, and the draft release is still published by a human.
- Pre-releases stay possible on demand without tags and without touching the
  version files.

Non-goals (unchanged from `release/LAYOUT.md`): shipping the TinyKG daemon or
the Lean governance kernels in the release unit; signing/attestation beyond
what §7 schedules as a follow-up; a release cadence policy (when to cut is a
human decision, the mechanism only makes it cheap).

## 2. Version model

- SemVer `MAJOR.MINOR.PATCH`. `build.zig.zon` `.version` is the repository
  authority; `src/version.zig` `semver` is the single in-source mirror and
  `scripts/eval/runtime_arm_smoke.py --expected-version` already fails
  `zig build test` when the two disagree. The design keeps both files and has
  the cut script edit them together.
- Between releases `main` carries the **next** version with the `-dev`
  pre-release part (`0.2.0-dev`); `--version` and the manifest append
  `+<commit12>` (and `.dirty`). A release commit drops `-dev`; the tag is the
  bare `X.Y.Z`. This is the existing #47 §6 / Q1 rule and stays.
- Bump level is computed from the Conventional-Commit **types** of the first
  line of every commit reachable from `main` since the last tag (`git log
  <tag>..main --no-merges`). `main` takes merge commits (the repository
  convention), so PR-internal commit types are visible; a squash or rebase
  merge leaves a single non-merge commit on the first-parent line whose subject
  is still classified, and the cut lists such commits in the PR body because
  their inner types are lost (the history before the convention has several,
  e.g. `subagent: … (#111)`). Normalization: the type is
  the text before the first `(` or `:` on the first line, lowercased,
  trailing `!` noted; anything that does not parse (`merge main`, free text,
  non-Latin subjects) or is not in the table is **unknown** and contributes
  nothing. The cut PR body lists every unknown-typed commit so the reviewer can
  raise the level by hand; the script never guesses.

  | commits contain | bump | pre-1.0 (current) |
  |---|---|---|
  | `!` after the type or a `BREAKING CHANGE:` footer | major | minor |
  | `feat` | minor | minor |
  | `fix`, `perf` | patch | patch |
  | only `ci`, `test`, `tests`, `docs`, `chore`, `eval`, `review`, `scripts`, `core`, `build`, `cli`, `transport`, `picker`, `vendor`, `gate`, `merge`, unknown | none | none |

  "none" means the cut is refused unless `--force-level` is given: a release
  with no user-visible change is a human decision, not a scheduled accident.
  Pre-1.0, a breaking change bumps MINOR (SemVer §4 leaves 0.x free; the table
  is one line in the script and flips to MAJOR at 1.0.0).
- Two candidates, the larger wins: `bump(last tag)` and the `-dev` version on
  `main` with `-dev` dropped. `main` at `0.2.0-dev` with only fixes since
  `0.1.0` still cuts `0.2.0`, because the `-dev` number is a floor a
  maintainer set on purpose (stage D, or by hand when a minor is planned).
  The result is always strictly greater than the last tag (`bump(tag)` is,
  for every level, and the floor cannot pull it below); the script asserts it
  anyway. The mid-flight state (`main` carrying the bare released version
  before the reopen PR) is caught earlier by the `-dev` check in stage A.
  Between a release and the next cut, `--version` on `main` therefore shows
  the floor (`0.2.1-dev+…`), not the version the commits will eventually
  imply; that is a display of intent, not a prediction.

## 3. Pipeline: four stages, two of them already exist

```
A cut ──▶ release PR ──(human merges)──▶ B tag ──▶ C build+draft ──(human publishes)──▶ D reopen dev
   release_cut.py (maintainer)   release-tag.yml      release.yml (dispatched by B,     release_cut.py --reopen
                                 (pull_request_target) or a hand-pushed tag)            (maintainer)
```

### Stage A — cut (`scripts/release_cut.py`, run by a maintainer)

A maintainer runs `python3 scripts/release_cut.py [--level auto|patch|minor|
major] [--dry-run]` on an up-to-date `main` checkout; the script ends by
running `gh pr create` under the maintainer's own `gh` login. It is **not** a
workflow on purpose: a pull request created (or a branch pushed) with the
repository's `GITHUB_TOKEN` does not trigger `pull_request` workflows (GitHub's
recursion guard), so a bot-opened release PR would sit at "required checks
missing" forever. A GitHub App installation token would lift that limit; it is
not worth a stored credential for a command a maintainer runs a few times a
month. The script (Python 3.9, stdlib only, tested under `scripts/tests/`):

1. Refuses unless `build.zig.zon` on `main` carries `-dev` (otherwise a
   release is mid-flight: "reopen first"). `git describe --tags --abbrev=0` →
   last tag; `git log <tag>..HEAD --format=%s%n%b --no-merges` → bump level per
   §2; version = the larger of bump(last tag) and the `-dev` floor, and
   strictly greater than the last tag.
2. Rewrites, in one commit on branch `release/<version>`:
   - `build.zig.zon` `.version = "<version>"`, `src/version.zig`
     `pub const semver = "<version>";`
   - `CHANGELOG.md`: the `## Unreleased` block becomes `## <version> — <UTC
     date>` with its `### Added/Changed/Fixed/…` subsections; an empty
     `## Unreleased` is reinserted above it. The parser fails closed: exactly
     one `## Unreleased` heading, at least one `- ` entry under it, no existing
     `## <version>` heading, headings only from the Keep-a-Changelog set;
     anything else refuses the cut with the offending line.
   - `evals/plugin-v1/protocol.json` implementation fingerprint via
     `python3 scripts/eval/plugin_release_gate.py
     --refresh-implementation-fingerprint` (last, as always).
3. Pushes branch `release/<version>` (`--force-with-lease`: the branch is
   generated, re-running the cut after more merges simply regenerates it) and
   opens the PR with title `release: <version>` and label `release`. The body
   is the new changelog section plus the bump derivation (which commits drove
   the level, which are unknown-typed, which have no changelog line) so a
   reviewer can dispute the level, not just the diff. Every external command
   is an argv list (`subprocess.run([...])`, no shell), the body goes through
   `--body-file`, and repository, base and head are fixed arguments, so commit
   subjects and changelog text can never become flags or commands.

The PR is gated by the ordinary ruleset (four required checks, branch up to
date). Its merge commit carries the bare version before any tag exists, which
the existing chain refuses (`release:manifest` stable channel needs `git
describe --exact-match`); CI therefore runs `check_version_state.py
--rehearse` first, which on a `release/<version>` head (and on main's own run
of the release merge commit) tags HEAD **locally, never pushed**, so
`release:verify` / `release:archive` exercise the candidate exactly as the
tag build will. Re-running the cut updates the open release PR in place; a
second, different release PR is refused (one cut in flight), and a branch that
already went through a merged PR is refused (a version is released once). The
script also requires `main` to equal freshly fetched `origin/main`. Merging
the PR is the human decision that a release happens.

### Stage B — tag (`release-tag.yml`)

`on: pull_request_target: types: [closed], branches: [main]` (and
`base.ref == 'main'` in the job condition, so a labelled PR merged into an
unprotected branch cannot mint a tag) — not `pull_request`: a
`pull_request` run executes the workflow file from the PR's merge commit, so a
PR that edited `release-tag.yml` would run its own edit with the write token
below. `pull_request_target` runs the file from the base branch, and the job
**checks out nothing**: every input is read through the API. It has
`permissions: contents: write, actions: write` (tag creation and
`workflow_dispatch`; nothing else) and `GH_TOKEN: ${{ github.token }}` in
`env`. It runs only when all of these hold: `merged == true`, the `release`
label is present, `head.repo.full_name == github.repository`, and the PR
title is `release: <version>` where `<version>` equals `.version` in
`build.zig.zon` fetched with `gh api
repos/{owner}/{repo}/contents/build.zig.zon?ref=<merge_commit_sha>` and
carries no `-dev`. It never uses `GITHUB_SHA` / `GITHUB_REF` (for a closed PR
those name the base branch and its latest merge, which a later merge can move);
the tag is created through the git-data API at
`github.event.pull_request.merge_commit_sha`. If the tag already exists it must
peel to that same SHA (a hand-made tag at the right commit is fine); a tag at
another commit **fails the job** with both SHAs in the log, it is never
silently accepted.

A tag created with `GITHUB_TOKEN` does not fire `release.yml`'s `push: tags`
trigger (recursion guard), so the job then starts stage C explicitly:
`gh workflow run release.yml --ref <version> -f tag=<version> -f dry_run=false`.
`workflow_dispatch` is the documented exception to the guard, the run uses the
workflow file **at the tag** (the file must also exist on the default branch),
and the dispatch path of `release.yml` already accepts a bare tag. Tags are
never moved; a mistaken release is followed by a new patch release, not a
re-tag.

### Stage C — build and draft (`release.yml`, extended)

Add `on: push: tags: ["[0-9]+.[0-9]+.[0-9]+"]` (the TODO in
`doc/RELEASE_RUNNER.md` "Enabling the tag trigger") for tags a maintainer
pushes by hand; stage B reaches the same workflow through `workflow_dispatch`.
The matrix, the seven-point `release:verify`, the double-archive comparison and
the `publish` job stay. `share/doc/CHANGELOG-<version>.md` is the whole
`CHANGELOG.md` copied at stage time (`build.zig` release extras), so the cut's
changelog rewrite imposes no parser contract on the bundle. Two changes to
`publish`:

- one event-aware pair of values replaces every `inputs.tag` use (today it
  appears in the concurrency group, both checkouts and the publish job, and is
  empty on a `push` event): `RELEASE_REF = inputs.tag || github.ref_name`,
  and `publish` runs on a tag push or on `dry_run=false`, but its first step
  refuses any ref that is not a bare `X.Y.Z` tag at HEAD (and runs
  `check_version_state.py`), so a branch or SHA ref always stops at artifacts
  (fixes gap §9.3: `release_sums.py` and `gh release create` never see a
  branch name). Concurrency groups on `RELEASE_REF`.
- reruns are safe: `gh release view <tag>` decides between `create --draft` and
  `upload --clobber` onto the existing draft, and a release a human already
  published (`isDraft == false`) is immutable to the job, which stops instead;
  because build artifacts expire after seven days, a rerun always rebuilds
  from the immutable tag rather than reusing artifacts.
- release notes come from the CHANGELOG section for that version
  (`scripts/release_notes.py <version>` prints it) instead of the fixed
  sentence; the draft is still published by a human.

`workflow_dispatch` remains for pre-releases: `dry_run` builds a
`X.Y.Z-dev+<commit12>` bundle and uploads artifacts only. `--verify-tag` is
skipped on that path because there is no tag (today it is unconditional and
would fail).

### Stage D — reopen development (`scripts/release_cut.py --reopen`)

For the same recursion-guard reason as stage A, the reopen PR is opened by the
maintainer: `python3 scripts/release_cut.py --reopen` (run right after merging
the release PR; the cut script prints the reminder) sets `build.zig.zon` /
`src/version.zig` to `X.Y.(Z+1)-dev`, re-adds the empty `## Unreleased`
block if the cut left none, repins the fingerprint and opens `chore: reopen
<next>-dev`. PATCH is the default floor; a maintainer who knows the next
release is a minor passes `--reopen-level minor`. Until that PR merges, `main`
carries the released version without `-dev`. Any other change merged in that
window would carry an untagged bare version (`release:manifest` fails for it,
`--version` looks stable). The window is closed by a gate, not by discipline:
a new step in `doc:check` (`scripts/check_version_state.py`, so it runs in
`gate:pr` and on every PR's CI) fails when the version has no `-dev` unless
HEAD is exactly the tag of that version or the PR head branch is
`release/<version>`. A PR that tries to merge during the window therefore goes
red until the reopen PR lands; the cut itself (stage A) also refuses without
`-dev`, see step 1.

## 4. Hotfixes and maintenance lines

Not needed before 1.0 and not automated: a hotfix is a normal fix on `main`
followed by a cut with `level=patch`. If a maintenance line is ever needed, it
is a `release/X.Y` branch created from the tag, and stages A–D run against it
by setting the workflow's `base` input; nothing in the scripts assumes `main`.

## 5. Integrity chain (unchanged, made explicit)

| link | mechanism |
|---|---|
| version ↔ code | `build.zig.zon` + `src/version.zig` mirror, enforced by `runtime_arm_smoke.py` in `zig build test` |
| version ↔ tag | stage B refuses `-dev` and existing tags; `release_manifest.zig` stable channel requires `git describe --exact-match` == version and a clean tree |
| bundle ↔ manifest | `scripts/verify_release_bundle.py` (file set, digests, no symlinks, licences) |
| vendored deps | TinyKG bundle table double digest in `build.zig`, `vendor/ripgrep/manifest.json`, `verify_*_binary.py` before every build |
| runtime | `metacodes doctor --json --strict` inside `release:verify` and `verify_install_prefix.py --doctor` |
| reproducibility | archive twice, `cmp` |
| archives ↔ release | `.sha256` sidecars re-verified by `release_sums.py`, one `SHA256SUMS` per release |

## 6. Failure modes the design must handle

- **Two cuts in flight**: the second `release/<version>` branch name collides
  or the level differs; the script refuses when an open PR with the `release`
  label exists.
- **Commits after the cut PR was opened**: the ruleset's "branch up to date"
  rule blocks the merge; re-running the cut on the same branch recomputes the
  level and rewrites the changelog section (idempotent by construction: it
  always regenerates from `<last tag>..HEAD`).
- **CHANGELOG drift**: PR authors forget the `## Unreleased` entry. The cut
  script's body lists every commit without a changelog line so the reviewer
  can add them in the release PR; the doc gate does not need a new rule.
- **Tag exists but build failed**: re-run `release.yml` for the tag; nothing
  is republished automatically because the draft is human-published.
- **Fingerprint race**: the cut PR repins last; if `main` moves after, the
  merge is blocked by the ruleset and the re-cut repins again.
- **Hand-made tag**: at the merge commit it is accepted; anywhere else stage B
  fails loudly (§3 B). A maintainer who pushes a bare tag by hand still gets a
  build through the `push: tags` trigger and the same publish rules.
- **Draft exists / artifacts expired**: rerun rebuilds from the tag and updates
  the existing draft (§3 C).
- **Malformed changelog**: the cut refuses with the line; nothing is pushed.
- **Stale clone**: the cut and the reopen refuse unless `main` equals freshly
  fetched `origin/main`; the reopen also requires the tag to exist on origin
  and to point at a commit `main` contains.

## 7. Follow-ups scheduled, not designed here

- Provenance attestation (`actions/attest-build-provenance`) on the archives
  and `SHA256SUMS`; SBOM (`OPEN_SOURCE_READINESS.md` launch-gate items).
- Extending the release matrix to every vendored target (`x86_64-macos`,
  `aarch64-linux`): needs a runner-independent `release:verify` path (see
  `ci.yml` cross-target `release:check` comment).

## 8. Change list

| file | change |
|---|---|
| `scripts/release_cut.py` (new) | bump computation, version/changelog rewrite, PR body, `--reopen`; `--dry-run` prints the plan; run by a maintainer, not by CI |
| `scripts/release_notes.py` (new) | print one CHANGELOG section |
| `scripts/check_version_state.py` (new, wired into `doc:check`) | a bare version is legal only on the tagged commit or a `release/<version>` head; closes the reopen window |
| `scripts/tests/test_release_cut.py` (new) | level table, floor rule, changelog rewrite idempotence, refusal cases |
| `.github/workflows/release-tag.yml` (new) | stage B: `pull_request_target: closed`, API-only, tag at `merge_commit_sha`, dispatch `release.yml` |
| `.github/workflows/release.yml` | tag trigger, event-aware `RELEASE_REF`/`DRY_RUN` replacing every `inputs.tag`, publish only for bare tags, rerun-safe draft handling, notes from changelog |
| `release/LAYOUT.md` | fix "ReleaseSafe" (the executable is `ReleaseSmall`, `build.zig`), publish flow with stages A–D |
| `README.md` | Lean kernels are not in the release unit (matches `release/LAYOUT.md`) |
| `doc/RELEASE_RUNNER.md` | replace "Enabling the tag trigger" TODO with the stage C description |
| `CHANGELOG.md` | keep; the `## Unreleased` block becomes a hard requirement for a cut |

## 9. Gaps in the current mechanism this design closes

1. `bin/metacodes` is built `ReleaseSmall` regardless of `-Doptimize`
   (`build.zig` fixed executables); `release/LAYOUT.md` says ReleaseSafe.
   Documentation fix; the CI flag stays for the test binaries.
2. `README.md` says the Lean kernels ship under `libexec/metacodes/`;
   `release/LAYOUT.md` and `verify_install_prefix.py` exclude them. The layout
   is right; README follows.
3. `release.yml` `publish` passes `inputs.tag` (a branch name or SHA on the pre
   channel) to `release_sums.py` and `gh release create --verify-tag`: wrong
   file name, `SAFE_VERSION` rejects `/`, `--verify-tag` cannot pass without a
   tag. Stage C fixes the version source and skips `--verify-tag` off-tag.
4. No tag trigger: stage C adds it.
5. No version bump path at all: stages A, B, D.
6. First tag `0.1.0` exists while `main` is `0.2.0-dev`, so the first cut
   under this design is `0.2.0` with the CHANGELOG `## Unreleased` block as its
   notes.

## 10. Decisions to confirm

- Pre-1.0 breaking changes bump MINOR (table in §2).
- `main` keeps merge-commit merges (PR-internal commit types feed the bump);
  squash-merged history is classified by its squash subject and listed.
- Stage D reopens at PATCH `-dev`; a minor is a one-number edit in that PR.
- The cut refuses a release whose commits carry no `feat`/`fix`/`perf` unless
  forced.
- Attestation and SBOM stay follow-ups (§7).
- Publishing a pre-release (the `OPEN_SOURCE_READINESS.md` launch-gate item
  "immutable pre-release with checksums") needs a tag, and the pre channel's
  version `X.Y.Z-dev+<commit12>` has none by design (`release_manifest.zig`
  sets `tag = null`). Two options, not chosen here: (a) `release.yml` on
  `dry_run=false` for a non-tag ref creates a lightweight tag
  `pre/<version-without-build-metadata>.<yyyymmdd>` on the built commit and a
  GitHub *pre-release* under it — needs the manifest's channel logic to accept
  that tag shape; (b) keep pre builds as artifacts only and satisfy the launch
  gate with the first stable `0.2.0`. (b) is the smaller change.

## 11. Review log

- Round 1 (self): GITHUB_TOKEN recursion guard (stages A/D moved to the
  maintainer, stage B dispatches C), fork guard, floor rule, CHANGELOG staging
  is a whole-file copy, pre-release publication left open.
- Round 2 (Codex, read-only, session `01a0c778`): stage B moved to
  `pull_request_target` with API-only inputs and the tag created at
  `merge_commit_sha` (a `pull_request` run would execute a PR-edited workflow
  with the write token); event-aware `RELEASE_REF`/`DRY_RUN` in `release.yml`;
  bump-type normalization and the merge-commit requirement; strict
  `candidate > last tag`; the reopen window closed by `check_version_state.py`;
  hand-made tags at another commit fail instead of no-op; rerun-safe drafts;
  fail-closed changelog grammar; argv-only subprocesses. Clarified, not
  changed: a `workflow_dispatch` run uses the workflow file at the dispatched
  ref (the file must also exist on the default branch), so the build procedure
  is pinned by the tag.
- Round 3 (Codex on the implementation): `gh workflow run` needs `GH_REPO`
  without a checkout; the release PR could never pass `release:verify` /
  `release:archive` on its untagged merge commit (rehearsal tag, above); the
  real-changelog test demanded a non-empty Unreleased block, which every cut
  empties; reruns could clobber a published release (draft-only now);
  `pull_request_target` gained `branches: [main]` + a base check; shell globs
  accepted `0.2.0-dev` as a bare version (anchored regex); the gate was in
  `doc:check` but `ci.yml` runs scripts individually (explicit step, both
  platforms); cut reruns update the open PR and refuse a second cut; cut and
  reopen verify against a fresh `origin/main` and the remote tag.
- Round 4 (Codex): all nine round-3 items confirmed. Fixed: the rehearsal's
  release-PR exception trusted the branch name alone (a PR from any branch
  named `release/<version>` could pass); in CI it now also needs the trusted
  event metadata `ci.yml` passes (`RELEASE_PR_TITLE == release: <version>`
  and the `release` label), and the merge-subject exception is honoured only
  on push runs; the cut's push lease is taken against the freshly fetched
  remote tip of the release branch; two stale "dispatch-only" / "tag trigger
  is a follow-up" sentences updated.
- Round 5 (Codex): no High or Medium remains; the three round-4 fixes
  confirmed; one strictness nit applied (the merge-subject exception requires
  `GITHUB_EVENT_NAME == push` literally). The rehearsal tag stays a local ref:
  it reaches no staged prefix, bundle check, doctor output, cache or upload.
