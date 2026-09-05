# The `metacodes-release` runners

Design for the dedicated release runners (#82, #47 stage 7, owner decision Q4).
`.github/workflows/release.yml` targets them by label; until they exist the
workflow runs only as a dry run on the PR pool, and the tag trigger stays off.

## Why a separate pool

The PR runners (`[self-hosted, <OS>, <ARCH>]`) execute code from every same-repo
branch, share one persistent Zig cache per machine, and are serialized with the
AgentCore and rule-control workflows through concurrency groups. A release build
must not compete with that queue, must not inherit a cache another branch wrote,
and must be the only workload that can ever hold the credential that creates a
GitHub Release. Isolation by machine is the simplest boundary that gives all
three.

## Labels and shape

| Property | Value |
|---|---|
| Labels | `[self-hosted, metacodes-release, Linux, X64]`, `[self-hosted, metacodes-release, macOS, ARM64]`, `[self-hosted, metacodes-release, Windows, X64]` |
| Count | one runner per platform; the workflow's matrix has one job per platform |
| Registration | repository-level runner group `metacodes-release`, restricted to the `Release` workflow (GitHub → Settings → Actions → Runner groups → "Selected workflows") |
| Account | a dedicated unprivileged OS user; no access to developer home directories or PR-pool workspaces |
| Egress | HTTPS to `github.com`, `api.github.com`, `objects.githubusercontent.com` and the Actions artifact service (`*.actions.githubusercontent.com`, `*.blob.core.windows.net`): the build jobs upload the archives with `actions/upload-artifact` and `publish` downloads them. Verify with one dry run before registering the runner; the CI pool's Linux runner resets that upload today (`ECONNRESET`, run 33939121801), which is why dry runs tolerate a failed upload |
| Toolchain | Zig 0.16.0 installed by `mlugg/setup-zig` in the job, exactly as CI does; Python ≥ 3.9 from the OS; `git`; `gh`; a Rust stable toolchain (`cargo`) and `bindgen` 0.72.1 for the AgentCore gate's link probe and bindings-regen check — the workflow's toolchain inventory fails a release job that lacks them |
| Network | outbound only to GitHub (checkout, `setup-zig` download, artifact upload). Nothing in `zig build` downloads: ripgrep and TinyKG are vendored and hash-checked (`verify_ripgrep_binary.py`, `verify_tinykg_binary.py`) |

The PR pool keeps its labels; nothing here changes `ci.yml`.

## Credentials

- Build jobs run with `permissions: contents: read` and need no secret.
- Only the `publish` job holds `contents: write`, only through the ephemeral
  `GITHUB_TOKEN`, and only to run `gh release create --draft --verify-tag`. No
  long-lived token is stored on any runner.
- The draft is published by a human in the GitHub UI after reading the
  SHA256SUMS; the workflow never flips a release to public.

## Caches and cleanup

- `ZIG_GLOBAL_CACHE_DIR` / `ZIG_LOCAL_CACHE_DIR` point at a per-runner directory
  as in CI; Zig's cache is content-addressed and folds the compiler version into
  every hash, so reuse across releases is safe. Wipe it when the toolchain
  changes.
- Every run starts from `actions/checkout` with `fetch-depth: 0` and
  `fetch-tags: true` (the stable channel needs `git describe --tags
  --exact-match HEAD`), and `git clean -ffdx` removes anything a previous run
  left. Prefixes and archives live under `$RUNNER_TEMP`, which the runner
  deletes after the job.
- The reproducibility step archives twice into two directories and compares
  them byte for byte; a difference fails the release before anything is
  uploaded.

## Enabling the tag trigger

Until the runners are registered, `release.yml` is `workflow_dispatch` only and
the `runner_pool: pr-pool` input lets a maintainer dry-run the workflow on the CI
machines (`dry_run: true`, no publish; `tag` takes a branch name or a full
40-hex commit SHA, since `actions/checkout` rejects short SHAs). A pr-pool dry
run joins the CI runner lane of the branch it was dispatched from (`github.ref`,
normally main; the `tag` input picks what to build, not the lane), so it queues
behind the CI job a merge
just started instead of sharing the box with it, and a push to that lane while
the dry-run job is still queued cancels it (re-dispatch). Once the three
runners report online:

1. Remove the `pr-pool` choice from the workflow input.
2. Add `on: push: tags: ["[0-9]+.[0-9]+.[0-9]+"]` so a bare `X.Y.Z` tag builds
   the stable channel automatically; keep pre-releases (`0.x.y-dev+<commit12>`)
   on `workflow_dispatch` only (#47 Q3).
3. Tick the two "Final launch gate" items in `OPEN_SOURCE_READINESS.md` that
   point here (dedicated runner; immutable pre-release with checksums).

## What a release proves

Each platform job runs the repository's own gates in release configuration:
`verify_tinykg_binary.py`, `verify_ripgrep_binary.py`, `zig build test
-Doptimize=ReleaseSafe`, `zig build release:verify` (the seven-point acceptance
of #47 §5.4 on the staged prefix, from outside it), `zig build agentcore:gate`
for the native target, then `release:archive` and `agentcore:archive`. The
`publish` job downloads every platform's archives, writes
`metacodes-<version>-SHA256SUMS` with `release_sums.py`, and attaches archives
and sums to a draft release created with `--verify-tag`. A consumer verifies an
unpacked archive on a clean machine with `scripts/verify_release_bundle.py
--native <dir>`.
