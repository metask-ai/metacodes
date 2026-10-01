# CLI release layout

The `metacodes-cli` release unit is the default install prefix sealed with a
manifest (#47 §5.2, stage 5 / #80). `zig build release:stage -Drelease-layout=true
--prefix <dir>` produces the tree; `release:manifest` writes `manifest.json`;
`release:check` validates it statically; `release:verify` (native target only)
also runs the executables. Nothing outside this tree is part of the unit, and a
file inside it that the manifest does not name fails `release:check`.

The unit is complete on every release target (manifest `schema_version` 2,
doc/INSTALL_DESIGN.md): the TUI, the full TinyKG (CLI and daemon) and both Lean
governance kernels, with nothing to install beside it.

```
metacodes-<version>-<target-id>/
├── bin/
│   ├── metacodes[.exe]                 role=primary_executable
│   └── rg[.exe]                        role=runtime_asset (ripgrep, Glob/Grep)
├── libexec/metacodes/
│   ├── metacodes-formal-kernel[.exe]   role=runtime_asset (formal_kernel)
│   │   + .provenance.json, .build-receipt.json
│   └── metacodes-project-kernel[.exe]  role=runtime_asset (project_kernel)
│       + .provenance.json
├── vendor/tinykg/
│   ├── tinykg[.exe]                    role=runtime_asset (memory / task control plane)
│   ├── tinykg.provenance.json          staging receipt (scripts/stage_tinykg_binary.py)
│   ├── tinykgd[.exe]                   role=runtime_asset (shared TinyKG store service)
│   └── tinykgd.provenance.json         staging receipt
├── share/licenses/
│   ├── metacodes-LICENSE               the repository LICENSE (MIT)
│   ├── ripgrep-LICENSE-MIT             vendor/ripgrep/LICENSE-MIT
│   ├── tinykg-LICENSE                  vendor/tinykg/LICENSE (Apache-2.0)
│   ├── lean4-LICENSE, gmp-COPYING.LESSERv3, gmp-COPYINGv3, gmp-COPYINGv2,
│   │   libuv-LICENSE, libuv-LICENSE-extra   vendor/lean-runtime/ (runtime linked into the kernels)
│   └── THIRD_PARTY_NOTICES.md          rendered by scripts/gen_third_party_notices.py
├── share/doc/
│   ├── README.md                       the repository README
│   └── CHANGELOG-<version>.md          the repository CHANGELOG at this version
└── manifest.json                       release/manifest.schema.json; not listed in its own files[]
```

| Path | Role | Where it comes from | Who checks it |
|---|---|---|---|
| `bin/metacodes[.exe]` | the product | `zig build` (the executable is always `ReleaseSmall`, see `build.zig`; `-Doptimize` only affects the test binaries) | `--version --json` must be a strict subset of the manifest (`release:verify`) |
| `bin/rg[.exe]` | runtime asset | `scripts/stage_ripgrep_binary.py` from `vendor/ripgrep/manifest.json` | digest in `files[]` and `components[]`; `doctor --strict` resolves it here under the release layout |
| `vendor/tinykg/tinykg[.exe]` | runtime asset | `scripts/stage_tinykg_binary.py` from `vendor/tinykg/manifest.json` | digest; `doctor --strict`; `tinykg version` equals `components[tinykg].version` (`release:verify`) |
| `vendor/tinykg/tinykg.provenance.json` | staging receipt | same script | listed in `files[]`; `components[tinykg].provenance_path` |
| `vendor/tinykg/tinykgd[.exe]` + receipt | runtime asset | the same bundle, role `daemon` | digest pinned by the executable under the release layout; `doctor --strict`; same version and source commit as `tinykg` (`release/manifest_contract.zig`) |
| `libexec/metacodes/metacodes-{formal,project}-kernel[.exe]` + sidecars | runtime assets | `zig build kernels:stage` (scripts/build-{formal,project-harness}-kernel.sh: axiom audit, native smoke, `check_kernel_self_contained.py`) | digest pinned by the executable (`-D{formal,project}-kernel-sha256`); `doctor --strict` resolves each adjacent and its own loader accepts the sidecar |
| `share/licenses/*` | licence texts and notices | repository files, `THIRD_PARTY_NOTICES.md` generated | every `components[].license_path` exists and is non-empty; the notices name every runtime asset |
| `share/doc/*` | operator documentation | repository files | listed in `files[]` |
| `manifest.json` | the contract | `scripts/release_manifest.zig` | `release/manifest_contract.zig` (schema, identity, files, components, compatibility) |

The Lean kernels are built natively on each release runner, linked
self-contained (only OS libraries; the Lean runtime, GMP and libuv are static,
their licences ship under `share/licenses/`), and pinned into the executable,
so a release build is two invocations:

```
zig build kernels:stage --prefix <dir>
zig build release:verify -Drelease-layout=true --prefix <dir> $(python3 scripts/kernel_pins.py <dir>)
```

`release:stage` refuses to run without both pins, and `release:verify` /
`verify_install_prefix.py --release --doctor` fail unless every runtime asset
resolves inside the unit and matches what the executable pins.

The relative position of `bin/` and `vendor/tinykg/` is load-bearing: the
executable resolves TinyKG at `../vendor/tinykg/` from its own directory and, under
the release layout, ripgrep beside itself before `PATH` (#78, #79). "Its own
directory" is the physical one: the self-executable path is passed through
`realpath` before any adjacent lookup, so `ln -s <prefix>/bin/metacodes
~/bin/metacodes` keeps rg, both Lean kernels and TinyKG resolving inside
`<prefix>` rather than beside the symlink. On Windows the same holds for an
NTFS symlink or a junction (`mklink /J`): the executable's physical path comes
from `platform.fs.finalPath`, which resolves through a file handle
(`GetFinalPathNameByHandleW`) rather than lexically. Unpack the archive
anywhere; do not move files inside it.

## Release channels

`release.version` is the repository version (`build.zig.zon`, mirrored by
`src/version.zig`). A version without a pre-release part is the **stable**
channel: `release.tag` is the bare `X.Y.Z` git tag (the repository's tag
convention, #47 Q1), the working tree must be clean, and `git describe --tags
--exact-match HEAD` must equal the version — `release:manifest` refuses to
write otherwise. A version with a pre-release part (`0.2.0-dev`) is the **pre**
channel: `version` gains `+<commit12>` as build metadata, `tag` is null, and a
missing `share/licenses/metacodes-LICENSE` is a warning rather than an error.

## Archives

`zig build release:archive` (after `release:verify`, or `release:check` for a
cross target) writes `metacodes-<version>-<target-id>.tar.gz` (`.zip` on
Windows) plus `<archive>.sha256` into `-Drelease-archive-dir` (default `dist/`,
never inside the prefix). The archive holds exactly the manifest's files plus
`manifest.json` under a `metacodes-<version>-<target-id>/` root; members carry
no owner, group, timestamp or host name, so two runs over the same prefix are
byte-identical — CI compares them, and re-running `release:archive` into a
directory that already holds the archive succeeds only when the bytes are the
same (it never replaces an archive). `zig build release:sums` joins every
`.sha256` under the archive directory into `metacodes-<version>-SHA256SUMS`
(`sha256sum -c` format), re-verifying each sidecar against its archive first.

The channel gate applies at archive time too (#47 Q1/Q3): a stable version
archives only from a clean tree whose HEAD carries the bare `X.Y.Z` tag; a
pre-release (`0.x.y-dev+<commit12>`) archives from any commit but is published
only through `workflow_dispatch`, never attached to a Release automatically.
The AgentCore SDK packager (`scripts/package_agentcore.py`) shares the same
core (`scripts/release_archive.py --kind agentcore`) and keeps its historical
refusal of untagged stable versions.

## Publishing

A release is cut, tagged and drafted by the four stages of
`doc/RELEASE_AUTOMATION_DESIGN.md`: a maintainer runs `python3
scripts/release_cut.py` (version derived from the Conventional-Commit types
since the last tag, `## Unreleased` becomes the release section, release PR
labelled `release`); merging that PR makes `release-tag.yml` tag the merge
commit and dispatch `release.yml`; `release.yml` (also on a hand-pushed bare
`X.Y.Z` tag) runs the whole chain per platform on GitHub-hosted runners
(`doc/RELEASE_RUNNER.md`) and leaves a *draft* GitHub Release holding every
archive, its `.sha256`, and `metacodes-<version>-SHA256SUMS`, with the
CHANGELOG section as notes; the maintainer then runs `python3
scripts/release_cut.py --reopen` and publishes the draft after verifying an
unpacked archive on a clean machine with `scripts/verify_release_bundle.py
--native`. Pre-releases are dispatched by hand and never auto-attached (#47
Q3); a bare `X.Y.Z` tag push also triggers the stable build
(`doc/RELEASE_RUNNER.md`, "Triggers").

## What is deliberately not in the unit

Debug executables, the test harness servers, evaluation shadows, the AgentCore
bundle (a separate unit with its own manifest), and anything a developer builds
into `zig-out/` that the manifest does not name.
