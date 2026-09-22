# Release automation design: version bumping, cutting, tagging, publishing

Status: design (2026-09-22). Builds on the mechanism that already exists
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
  line of every commit on `main` since the last tag (merge commits are skipped,
  their PR commits are what count):

  | commits contain | bump | pre-1.0 (current) |
  |---|---|---|
  | `!` after the type or a `BREAKING CHANGE:` footer | major | minor |
  | `feat` | minor | minor |
  | `fix`, `perf` | patch | patch |
  | only `ci`, `test`, `tests`, `docs`, `chore`, `eval`, `review`, `scripts`, `core`, `merge`, unknown | none | none |

  "none" means the cut is refused unless `--force-level` is given: a release
  with no user-visible change is a human decision, not a scheduled accident.
  Pre-1.0, a breaking change bumps MINOR (SemVer §4 leaves 0.x free; the table
  is one line in the script and flips to MAJOR at 1.0.0).
- The computed version must be **greater** than the `-dev` version currently
  on `main` only in the sense that it is the same numbers with `-dev` dropped
  or higher; if `main` says `0.2.0-dev` and the commits imply a patch of
  `0.1.0`, the cut still produces `0.2.0` (the `-dev` number is a floor set
  when the previous release reopened development, see §3 stage D).

## 3. Pipeline: four stages, two of them already exist

```
A cut ──▶ release PR ──(human merges)──▶ B tag ──▶ C build+draft ──(human publishes)──▶ D reopen dev
   scripts/release_cut.py         release-tag.yml      release.yml (tag push)         release-tag.yml
```

### Stage A — cut (`scripts/release_cut.py`, `release-cut.yml`)

Triggered by `workflow_dispatch` (inputs: `level` = `auto` | `patch` | `minor`
| `major`, `dry_run`). Runs on `ubuntu-latest` with `contents: write` and
`pull-requests: write` through the ephemeral token. The script (Python 3.9,
stdlib only, tested under `scripts/tests/`):

1. `git describe --tags --abbrev=0` → last tag; `git log <tag>..HEAD
   --format=%s%n%b --no-merges` → bump level per §2; version = bump applied to
   the last tag, floored at the `-dev` version in `build.zig.zon`.
2. Rewrites, in one commit on branch `release/<version>`:
   - `build.zig.zon` `.version = "<version>"`, `src/version.zig`
     `pub const semver = "<version>";`
   - `CHANGELOG.md`: the `## Unreleased` block becomes `## <version> — <UTC
     date>` with its `### Added/Changed/Fixed/…` subsections; an empty
     `## Unreleased` is reinserted above it. A block that is empty of entries
     refuses the cut (the changelog is the release note, see stage C).
   - `evals/plugin-v1/protocol.json` implementation fingerprint via
     `python3 scripts/eval/plugin_release_gate.py
     --refresh-implementation-fingerprint` (last, as always).
3. Opens the release PR with title `release: <version>` and label `release`.
   The body is the new changelog section plus the bump derivation (which
   commits drove the level) so a reviewer can dispute the level, not just the
   diff.

The PR is gated by the ordinary ruleset (four required checks, branch up to
date). Merging it is the human decision that a release happens.

### Stage B — tag (`release-tag.yml`)

`on: pull_request: types: [closed]` filtered on `merged == true` and the
`release` label. The job reads the version from `build.zig.zon` on the merge
commit, refuses if it still carries `-dev` or if the tag exists, then creates
the annotated tag `<version>` on `github.event.pull_request.merge_commit_sha`
and pushes it. Tags are never moved; a mistaken release is followed by a new
patch release, not a re-tag.

### Stage C — build and draft (`release.yml`, extended)

Add `on: push: tags: ["[0-9]+.[0-9]+.[0-9]+"]` (the TODO in
`doc/RELEASE_RUNNER.md` "Enabling the tag trigger"). The matrix, the seven-point
`release:verify`, the double-archive comparison and the `publish` job stay.
Two changes to `publish`:

- version is read from the tag (`github.ref_name`) on tag runs and from the
  manifest on dispatch runs; `release_sums.py` and `gh release create` receive
  that value, never a branch name (fixes gap §9.3).
- release notes come from the CHANGELOG section for that version
  (`scripts/release_notes.py <version>` prints it) instead of the fixed
  sentence; the draft is still published by a human.

`workflow_dispatch` remains for pre-releases: `dry_run` builds a
`X.Y.Z-dev+<commit12>` bundle and uploads artifacts only. `--verify-tag` is
skipped on that path because there is no tag (today it is unconditional and
would fail).

### Stage D — reopen development (same `release-tag.yml`)

After the tag is pushed the job opens a second, trivial PR `chore: reopen
<next>-dev` that sets `build.zig.zon` / `src/version.zig` to `X.Y.(Z+1)-dev`
and re-adds the empty `## Unreleased` block if the cut left none. PATCH is the
default floor; a maintainer who knows the next release is a minor edits the
number in that PR. This keeps `main` always one `-dev` ahead of the last tag,
which is what `release_manifest.zig`'s `pre` channel and `--version` assume.

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

## 7. Follow-ups scheduled, not designed here

- Provenance attestation (`actions/attest-build-provenance`) on the archives
  and `SHA256SUMS`; SBOM (`OPEN_SOURCE_READINESS.md` launch-gate items).
- Extending the release matrix to every vendored target (`x86_64-macos`,
  `aarch64-linux`): needs a runner-independent `release:verify` path (see
  `ci.yml` cross-target `release:check` comment).

## 8. Change list

| file | change |
|---|---|
| `scripts/release_cut.py` (new) | bump computation, version/changelog rewrite, PR body; `--dry-run` prints the plan |
| `scripts/release_notes.py` (new) | print one CHANGELOG section |
| `scripts/tests/test_release_cut.py` (new) | level table, floor rule, changelog rewrite idempotence, refusal cases |
| `.github/workflows/release-cut.yml` (new) | stage A |
| `.github/workflows/release-tag.yml` (new) | stages B and D |
| `.github/workflows/release.yml` | tag trigger, version from tag/manifest, notes from changelog, no `--verify-tag` on dispatch |
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
- Stage D reopens at PATCH `-dev`; a minor is a one-number edit in that PR.
- The cut refuses a release whose commits carry no `feat`/`fix`/`perf` unless
  forced.
- Attestation and SBOM stay follow-ups (§7).
