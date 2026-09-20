# TinyKG integration

TinyKG is a separately maintained executable. Metacodes does not vendor its
source, build it, download it, search `PATH`, or discover a sibling checkout.
The source repository instead contains one manually reviewed, cross-platform CLI
bundle so a clean checkout has a deterministic TinyKG runtime by default.

## Checked-in contracts

Two files serve different purposes:

- `deps/tinykg.json` freezes TinyKG version 0.3.0 for both roles in the current bundle, upstream repository,
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

The v2 bundle has a `cli` and `daemon` row for every target family. CLI assets
are named `tinykg-*`; daemon assets are named `tinykgd-*`.

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
4. executable format and declared architectures: static ELF rejects dynamic
   program headers, universal Mach-O validates each non-overlapping slice, and
   Windows requires an x86_64 PE32+ console subsystem;
5. an embedded exact `tinykg 0.3.0` marker, or `tinykgd 0.3.0` for a daemon artifact;
6. target-family ownership;
7. a second digest over the private staging temporary before atomic replacement,
   so a source-path race cannot replace the last known-good output.

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

Bundle replacement is an explicit release operation, never part of `zig build`.
Run the reproducible builder from the Metacodes checkout:

```sh
python3 scripts/build_tinykg_bundle.py --source /path/to/tinykg \
  --commit <40-lowercase-hex-commit> --version <semver>
```

It verifies the clean pinned work tree and Zig version, exports to a fixed
`/tmp/metacodes-tinykg-release-src-<commit-prefix>` root, builds stripped
ReleaseSafe CLI and daemon binaries for all declared targets, scans every
executable (including both universal slices), probes native storage/schema, and
regenerates the v2 manifest and CLI contract before running attestation. Use
`--dry-run` to print the exact commands without building.

It finally rewrites the `tinykg-bundle-table` block in `build.zig`. That table
is the second committed copy of every digest: `tinykg:stage` passes the table
entry to the staging script, which refuses to install a byte unless the bundle
manifest agrees with it. A regenerated bundle therefore lands in one commit
that changes the binaries, the manifest and the table together, and any later
edit to one of them alone fails the next build.

The old manual checklist is retained as review guidance:

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
4. Replace only the generated files under `vendor/tinykg/bin/`, then update every
   SHA-256, `source_commit`, and build field in `vendor/tinykg/manifest.json`.
5. Retain the upstream Apache-2.0 text in `vendor/tinykg/LICENSE`; update
   `deps/tinykg.json` if CLI/storage/schema compatibility changed.
6. Scan printable strings in every executable (and both universal Mach-O slices)
   for personal paths and secret-shaped data.
7. Run `python3 scripts/verify_tinykg_binary.py`, the bundle unit tests,
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
Automatic staged lookup is limited to `<prefix>/bin` and
`<prefix>/eval/bin` executable layouts. It never walks arbitrary ancestors in
search of a `vendor/` directory.

`METACODES_KGD_BIN` selects an explicitly staged `tinykgd` for diagnostics and
for the local service described below.

## The local service: `kg install` and `kgd`

A shared deployment runs TinyKG Web in front of one `tinykgd`. A single machine
runs the same contract from the product binary instead:

```sh
metacodes kg install     # create the store, the key and daemon.json
metacodes kgd            # serve it in the foreground until Ctrl+C
```

`kg install` resolves the staged executables, creates the Store when it is
absent, generates a 256-bit API key, computes the build id from the two TinyKG
executables and the metadata the CLI declares, and writes `daemon.json` (0600)
in a 0700 directory. It starts nothing. Re-running it keeps the existing key,
port and Store, so reconfiguring never locks out a session that already read
them; `--port` and `--store` change them deliberately.

`kgd` owns one `tinykgd` child and serves `POST /api/run`,
`POST /api/import-markdown` and `GET /api/ready` on loopback, authenticated by
`x-api-key`. It reads its port, key and Store from the same `daemon.json` the
sessions read, so the service and its clients cannot disagree about where it
listens. The envelope it returns names `metacodes-kgd` as its implementation;
clients accept that name and `tinykg-web`, and pin the build id on top of it.

An isolated second world — a scratch store on another port, leaving the default
untouched — is one command plus one variable:

```sh
metacodes kg install --config ~/scratch-kg.json --store /tmp/scratch.kg.v2 --port 8900
METACODES_KG_CONFIG=~/scratch-kg.json metacodes kgd
METACODES_KG_CONFIG=~/scratch-kg.json metacodes        # a session in that world
```

Properties worth knowing:

- The service handles one connection at a time, because `tinykgd` answers one
  request at a time. A whole request must arrive within 30 seconds, and the
  client is authenticated after the head and before the body is read, so an
  unauthenticated peer cannot make it read a large body.
- A `tinykgd` that accepts a request and stops answering desynchronizes the
  pipe. The service reports 503, stops, and says to start it again rather than
  queueing every later request behind a read that will not return.
- Nothing starts the daemon automatically yet, there is no idle exit, and the
  daemon is still not part of the product install.
- Known limitation on Windows: the bridge's response deadline cannot interrupt
  a write that is already blocked, because anonymous pipes have no portable
  writability query (`PipeChild.pollWritable` returns true there). A request is
  capped at the daemon's own 1 MB ceiling and the child is the `tinykgd` this
  product ships, so the exposure is a misbehaving child rather than a hostile
  one; making it interruptible needs overlapped I/O.

Because nothing starts it, the daemon is **not** part of the default install or
the release layout: `zig build tinykg:stage` (and the test wiring) install it
under `zig-out/vendor/tinykg/`, while `zig build --prefix <dir>` carries only
the assets `release/manifest_contract.zig` declares and
`scripts/verify_install_prefix.py` expects. `metacodes doctor` therefore reports
`tinykgd` as unresolved in a plain install. The change that starts the daemon
adds it to the install step, the release manifest and the prefix inventory
together.

When the runtime is degraded, the diagnosis is retained with a kind and a
fixed repair hint:

| Kind | Hint |
|---|---|
| `unconfigured` | write `~/.metacodes/kg/daemon.json` (0600) or set the KG URL/key/build-id variables |
| `config_unsafe` | make the file regular, non-symlink, under 64 KB, and mode 0600 |
| `config_invalid` | fix the URL, API key, and expected build-id JSON |
| `daemon_unreachable` | start tinykgd/tinykg-web at the configured URL |
| `auth_failed` | match the daemon's `TINYKG_WEB_API_KEY` |
| `pin_mismatch` | use the running daemon's catalog build/schema values |
| `store_contract_mismatch` | migrate storage and schema to 3/3 |
| `server_degraded` | inspect the daemon's degraded-store logs |
| `cli_bin_missing` | set `METACODES_KG_BIN` or install the staged bundle |
| `cli_store_failed` | inspect the reason for disk, permission, or store corruption |

A daemon without `/api/ready` (404/405/501) is treated as ready once `store-info`
succeeded; only an explicit `degraded`/`ready:false` answer yields `server_degraded`.
Degraded sessions re-probe from the KG tools after 5 seconds, doubling to a
5 minute cap; `/kg` probes immediately. A root client whose diagnosis is
`unconfigured`, `config_unsafe` or `config_invalid` re-reads `daemon.json` (or
the environment) on that probe, so a configuration repaired mid-session takes
effect without a restart. Subagent and teammate clones never re-read
configuration: a transport rebuilt inside a clone would carry a private write
fence, and the ambiguous-commit poison must stay shared across the in-process
client family. Clones created after the root re-read inherit its binding. The
state appears in the startup line, `/kg`, and `metacodes doctor`, whose `kg`
object names the configuration source (`METACODES_KG_CONFIG`, `env` for the
`METACODES_KG_*` triple, or the default `daemon.json` path).

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
