# Release runners

`.github/workflows/release.yml` (#82, #47 stage 7) builds every release on
GitHub-hosted runners: `ubuntu-latest` (x86_64), `macos-latest` (arm64) and
`windows-latest` (x86_64). The dedicated self-hosted `metacodes-release` pool
this document used to design is no longer planned: the repository is public,
hosted standard runners are free for public repositories, and organization
policy keeps public repositories off the organization's self-hosted fleet
(2026-09-21).

## Why hosted runners give the isolation the pool was for

The pool existed for three properties: a release build must not compete with
the PR queue, must not inherit a cache another branch wrote, and must be the
only workload that can ever hold the credential that creates a GitHub Release.
An ephemeral hosted runner gives all three by construction: every job gets a
fresh machine, `release.yml` runs `setup-zig` with `use-cache: false` so a
release always compiles cold, and the token exists only inside the `publish`
job.

## Shape

| Property | Value |
|---|---|
| Runners | `ubuntu-latest`, `macos-latest`, `windows-latest`; one job per platform, `publish` on `ubuntu-latest` |
| Trigger | `workflow_dispatch` only, inputs `tag` (bare `X.Y.Z` for the stable channel, a branch or full 40-hex commit SHA for `0.x.y-dev` pre-releases; `actions/checkout` rejects short SHAs) and `dry_run` (default `true`: build, verify, archive and upload artifacts, no draft) |
| Toolchain | Zig 0.16.0 from `mlugg/setup-zig` (no cache); the images' Python and Rust stable (`cargo`); `bindgen` 0.72.1 installed by `cargo install bindgen-cli --locked` in the job for the AgentCore gate's bindings-regen check; PyYAML from `requirements-dev.txt` |
| Network | `zig build` downloads nothing: ripgrep and TinyKG are vendored and hash-checked (`verify_ripgrep_binary.py`, `verify_tinykg_binary.py`). The job itself reaches GitHub (checkout, `setup-zig`, artifacts) and crates.io (`bindgen`) |

## Credentials

- Build jobs run with `permissions: contents: read` and need no secret.
- Only the `publish` job holds `contents: write`, only through the ephemeral
  `GITHUB_TOKEN`, and only to run `gh release create --draft --verify-tag`. No
  long-lived token is stored anywhere.
- The draft is published by a human in the GitHub UI after reading the
  SHA256SUMS; the workflow never flips a release to public.

## Reproducibility

- Every run starts from `actions/checkout` with `fetch-depth: 0` and
  `fetch-tags: true` (the stable channel needs `git describe --tags
  --exact-match HEAD`). Prefixes and archives live under `$RUNNER_TEMP`.
- The reproducibility step archives twice into two directories and compares
  them byte for byte; a difference fails the release before anything is
  uploaded.

## Triggers

`release.yml` runs on a bare `X.Y.Z` tag push and on `workflow_dispatch`
(`doc/RELEASE_AUTOMATION_DESIGN.md` stage C). The stable path is normally
reached through `release-tag.yml`, which tags a merged release PR and
dispatches `release.yml` explicitly (a tag created with the repository token
does not fire the push trigger). Pre-releases (`0.x.y-dev+<commit12>`) stay on
`workflow_dispatch`; the `publish` job refuses any ref that is not a bare tag at
HEAD, so a pre-channel run stops at artifacts whatever `dry_run` says. The
remaining "Final launch gate" item in `OPEN_SOURCE_READINESS.md` is the
immutable pre-release with checksums (design §10).

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
