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
| Runners | `ubuntu-latest` (x86_64 Linux), `ubuntu-24.04-arm` (aarch64 Linux), `macos-latest` (aarch64 macOS), `macos-15-intel` (x86_64 macOS), `windows-latest`; one job per release unit, each native to its target, `publish` on `ubuntu-latest` |
| CLI target | An explicit Zig target per unit, never the runner's own: `x86_64-linux-gnu.2.31`, `aarch64-linux-gnu.2.31`, `aarch64-macos.13.0`, `x86_64-macos.13.0`, `x86_64-windows-gnu` (`cli_target` in the matrix, passed to `release:verify` and `release:archive`). It means the baseline CPU and the oldest glibc or macOS the unit supports; `scripts/check_binary_baseline.py` fails a unit whose executable needs more |
| Trigger | `workflow_dispatch` only, inputs `tag` (bare `X.Y.Z` for the stable channel, a branch or full 40-hex commit SHA for `0.x.y-dev` pre-releases; `actions/checkout` rejects short SHAs) and `dry_run` (default `true`: build, verify, archive and upload artifacts, no draft) |
| Toolchain | Zig 0.16.0 from `mlugg/setup-zig` (no cache); the images' Python and Rust stable (`cargo`); for the test suite's Glob and Grep tests the image's `rg`, or where the image has none (the arm64 Linux runner) the vendored, attested binary the unit ships (`stage_ripgrep_binary.py`); `bindgen` 0.72.1 installed by `cargo install bindgen-cli --locked` in the job for the AgentCore gate's bindings-regen check; PyYAML from `requirements-dev.txt`; elan 4.2.4 from its pinned release asset (`scripts/ci/install-elan.sh`, Git Bash on Windows) and the Lean toolchain `control-plane/lean/lean-toolchain` names, to build both kernels the unit ships (`zig build kernels:stage`, then `scripts/kernel_pins.py`) |
| Network | `zig build` downloads nothing: ripgrep and TinyKG are vendored and hash-checked (`verify_ripgrep_binary.py`, `verify_tinykg_binary.py`). The job itself reaches GitHub (checkout, `setup-zig`, artifacts, the elan asset and the Lean toolchain elan resolves) and crates.io (`bindgen`) |

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
for the native target, then `release:archive` and `agentcore:archive`. Between
`release:verify` and the archives, `scripts/check_binary_baseline.py`
disassembles the unit's executable and fails it on any instruction beyond the
baseline CPU (no AVX, AVX2 or AVX-512 on x86_64; no SVE or Armv8.6 matrix
instructions on aarch64), on a GLIBC symbol version newer than the target's
glibc, or on a minimum macOS newer than the target's. A Mach-O is
disassembled in llvm-objdump's Mach-O mode, which prints the ranges the linker
lists in `LC_DATA_IN_CODE` (an x86_64 switch's jump table inside `__text`) as
data; the check fails unless every such range came back as data. The macOS
`release` leg of `ci.yml` builds both macOS executables for their targets and
runs the same check on every change. On macOS and Linux,
`scripts/install.sh` then installs the job's own archives as a published
release, from a loopback mirror that holds only that unit, so it must pick the
archive by the host's target. The
`publish` job downloads every platform's archives, writes
`metacodes-<version>-SHA256SUMS` with `release_sums.py`, and attaches archives
and sums to a draft release created with `--verify-tag`. A consumer verifies an
unpacked archive on a clean machine with `scripts/verify_release_bundle.py
--native <dir>`.

## Debug symbols

A Linux unit ships its executable stripped and its debug symbols as a separate
release asset, `metacodes-<version>-<target-id>-debug.tar.gz`.

**How they are built.** `release.yml`'s Linux units, and the `release` leg of
`ci.yml` on Linux, build with `-Drelease-symbols=true`. The release executable
is linked once, with DWARF and a GNU build ID. Then binutils splits it:
`objcopy --only-keep-debug` writes `metacodes.debug`, and `objcopy --strip-all
--add-gnu-debuglink=metacodes.debug` writes the `bin/metacodes` the unit ships.
Zig 0.16's own `objcopy --extract-to` reports "unimplemented" for this
executable.

`src/main.zig` keeps stack tracing off in every ReleaseSmall build. Without
that, DWARF would link in about 100 KB of unwinding code; with it, a stripped
build is byte-identical whether the line is there or not. Measured on x86_64
Linux, the shipped executable is 256 bytes larger than a release-layout link
without DWARF: the build-ID note, the debug link and alignment. Its `.text`
differs by 14 bytes. The two halves come from one link, and the build ID and
the debug link's CRC-32 prove it.

**What the asset holds.** `release:archive` writes it beside the unit's
archive. It holds a single file, `metacodes-<version>-<target-id>-debug/bin/metacodes.debug`.

**How it is checked.** `scripts/release_archive.py --kind symbols` refuses to
write it unless the unit's `bin/metacodes` names that exact file: the same
build ID, and a `.gnu_debuglink` whose name and CRC-32 match. Two runs produce
the same bytes, and the reproducibility step compares the symbols archive with
the unit's archive.

**Where it goes.** `SHA256SUMS` lists it, and the draft release carries it as
an asset. It is never part of the unit's own archive. Neither `install.sh` nor
`metacodes update` downloads it.

### Reading a core dump

Use the symbols of the release that crashed: `readelf -n` prints the same
`Build ID` for the executable and for its `metacodes.debug`.

```sh
tar -xzf metacodes-<version>-<target-id>-debug.tar.gz
gdb -s metacodes-<version>-<target-id>-debug/bin/metacodes.debug \
    -e ~/.local/opt/metacodes/bin/metacodes -c core -ex 'thread apply all bt'
```

gdb can also find the symbols by itself, in either of two places:

- `metacodes.debug` copied beside the executable that crashed. gdb follows
  `.gnu_debuglink` and checks the CRC.
- The build-ID tree: `<dir>/.build-id/<first two hex digits>/<rest>.debug`,
  with `set debug-file-directory <dir>:/usr/lib/debug`. Keep `/usr/lib/debug`
  in that list so the C library's frames stay named.

**Why the symbols matter.** Without them a stripped executable's frames have
no names. Once the executable also drops `.eh_frame`, gdb cannot unwind past
the first frame either. The symbol file carries `.debug_frame`, from which gdb
rebuilds every thread's whole stack with function names and source lines.
