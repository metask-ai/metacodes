# TinyKG integration

TinyKG is a separately maintained executable. Metacodes does not vendor its
source, build it, download it, search `PATH`, or discover a sibling checkout.
The source repository instead contains one manually reviewed, cross-platform CLI
bundle so a clean checkout has a deterministic TinyKG runtime by default.

## Checked-in contracts

Two files serve different purposes:

- `deps/tinykg.json` freezes TinyKG CLI version 0.2.0, upstream repository,
  Apache-2.0 license identifier, storage format 3, and store schema 3.
- `vendor/tinykg/manifest.json` freezes the exact redistributed executable bytes:
  upstream commit, Zig version, ReleaseSafe/strip profile, target ownership,
  executable format, architectures, source-tree path, and SHA-256.

The bundle currently supports:

| Target family | Bundle key | Artifact |
|---|---|---|
| macOS arm64 or x86_64 | `macos-universal` | universal Mach-O with both slices |
| Linux x86_64 | `linux-x86_64` | static-musl ELF |
| Linux arm64 | `linux-aarch64` | static-musl ELF |
| Windows x86_64 | `windows-x86_64` | PE32+ console executable |

Windows arm64 and other targets are not declared. A normal product build for an
undeclared target still builds Metacodes without TinyKG; `tinykg:stage` fails with
an explicit unsupported-target message.

## Default selection and staging

`zig build` selects exactly one artifact from the build target and installs it as
`zig-out/vendor/tinykg/tinykg` or `tinykg.exe`. The installed location also gets a
deterministic `tinykg.provenance.json`; no source-machine path enters the receipt.

Every stage verifies:

1. regular, non-symlink executable input;
2. build-table digest equals the bundle manifest digest;
3. complete SHA-256 of the asset;
4. executable format and declared architectures;
5. an embedded exact `tinykg 0.2.0` version marker;
6. target-family ownership.

When the selected bundle can execute on the build host, staging additionally runs
`tinykg version`, initializes a fresh temporary store, and checks storage/schema
3/3. Cross staging cannot execute the foreign binary and therefore relies on the
checked-in release attestation plus the byte/format/architecture gates.

Useful commands:

```sh
zig build                    # Metacodes + native bundled TinyKG
zig build tinykg:stage       # validate/stage only TinyKG
zig build dev:full           # Debug Metacodes + bundled TinyKG
zig build -Dtinykg-bundled=false  # intentionally omit TinyKG
```

The fast `zig build dev` path remains app-only. The ordinary install and test
graphs use the bundled native artifact by default.

## Explicit maintainer override

An operator can audit a candidate native binary without changing checked-in
assets:

```sh
tinykg_bin=/absolute/path/to/tinykg
tinykg_sha=$(shasum -a 256 "$tinykg_bin" | awk '{print $1}')

zig build tinykg:stage \
  -Dtinykg-bin="$tinykg_bin" \
  -Dtinykg-sha256="$tinykg_sha"
```

The two options are inseparable, the path must be absolute, and the candidate can
only be staged on a matching native runner. `-Dtinykg=true` remains unsupported;
legacy `-Dtinykg=false` disables the bundle.

## Manual bundle maintenance

Bundle replacement is an explicit release operation, never part of `zig build`:

1. Select and review one immutable commit in
   `https://github.com/metask-ai/tinykg`.
2. In that separate repository, build stripped `ReleaseSafe` executables with the
   Zig version recorded in the new manifest. Build macOS arm64+x86_64 and combine
   them into one signed universal Mach-O; build Linux x86_64/arm64 as static musl;
   build Windows x86_64 as PE32+. Use a fixed non-personal source root (the current
   v0.2.0 bundle used `/tmp/metacodes-tinykg-release-src-a0544788`) because C
   `__FILE__` strings can otherwise disclose a maintainer's absolute path.
3. Run the native TinyKG release tests in its own repository. Execute version and
   fresh-store probes on native runners for each redistributed platform.
4. Replace only the four files under `vendor/tinykg/bin/`, then update every
   SHA-256, `source_commit`, and build field in `vendor/tinykg/manifest.json`.
5. Retain the upstream Apache-2.0 text in `vendor/tinykg/LICENSE`; update
   `deps/tinykg.json` if CLI/storage/schema compatibility changed.
6. Scan printable strings in every executable (and both universal Mach-O slices)
   for personal paths and secret-shaped data.
7. Run `python scripts/verify_tinykg_binary.py`, the bundle unit tests,
   `zig build tinykg:stage`, cross-target staging for all four target families,
   and the full ReleaseSafe/L2 gates.

Never repin a digest merely to silence a failure. A byte change requires a new
reviewed upstream commit/build receipt or a documented reproducibility finding.

## Runtime modes

The normal shared-store mode is an authenticated Metacodes-owned Web transport to
one `tinykgd`/StoreActor. Configure it through `~/.metacodes/kg/daemon.json`,
`METACODES_KG_CONFIG`, or the explicit URL/key/build-id environment variables.
Build identity and schema are pinned by the client. Failure degrades KG features
without disabling the rest of the agent; it never falls back to a raw shared store.

An isolated, single-process development or benchmark store may use the staged
bundle explicitly:

```sh
export METACODES_KG_TRANSPORT=cli-exclusive
export METACODES_KG_BIN="$PWD/zig-out/vendor/tinykg/tinykg"
export METACODES_KG_STORE=/fresh/private/store.kg
```

The exclusive CLI mode must not point at the canonical shared store.

## Ownership and prompt-cache boundary

Metacodes owns proposals, policy/Lean admission, re-observation, transactions,
budgets, recovery classification, and final receipts. TinyKG owns storage,
authenticated daemon execution, graph primitives, generation/CAS checks, and its
own release process. High-level operation journals stay in Metacodes; TinyKG stores
durable task/provenance facts rather than every transient effect.

Bundle keys, paths, hashes, staging receipts, runtime versions, and store
bookkeeping never enter provider-visible prompt bytes. A bundle replacement with
equivalent governed memory content therefore does not invalidate prompt cache.

The TinyKG skill used by maintainers for cross-session task control is a third
boundary. It does not configure the embedded runtime and its credentials are never
read by Metacodes.
