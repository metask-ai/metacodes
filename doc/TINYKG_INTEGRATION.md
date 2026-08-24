# TinyKG integration

TinyKG is a separately maintained executable. Metacodes neither vendors its source
nor discovers a developer checkout implicitly.

## Checked-in contract

`deps/tinykg.json` freezes the accepted TinyKG CLI version, source repository,
license identifier, storage format, and store schema. `scripts/stage_tinykg_binary.py`
requires all of the following before copying any bytes:

1. an absolute, regular, non-symlink executable path;
2. a maintainer-observed lowercase SHA-256;
3. exact `tinykg version` output;
4. successful initialization of a fresh temporary store;
5. matching storage-format and schema versions.

The staged output and deterministic provenance receipt are installed below
`zig-out/vendor/tinykg/`. The receipt never records the maintainer's source path.

```sh
tinykg_bin=/absolute/path/to/tinykg
tinykg_sha=$(shasum -a 256 "$tinykg_bin" | awk '{print $1}')

zig build tinykg:stage \
  -Dtinykg-bin="$tinykg_bin" \
  -Dtinykg-sha256="$tinykg_sha"
```

`-Dtinykg-bin` and `-Dtinykg-sha256` are a pair; supplying only one is rejected
during build-graph construction. `-Dtinykg=true` is intentionally unsupported.

## Runtime modes

The normal shared-store mode is an authenticated Metacodes-owned Web transport to
one `tinykgd`/StoreActor. Configure it through `~/.metacodes/kg/daemon.json`,
`METACODES_KG_CONFIG`, or the explicit URL/key/build-id environment variables.
Build identity and schema are pinned by the client. Failure degrades KG features
without disabling the rest of the agent; it never falls back to a raw shared store.

An isolated, single-process development or benchmark store may use:

```sh
export METACODES_KG_TRANSPORT=cli-exclusive
export METACODES_KG_BIN=/absolute/path/to/attested/tinykg
export METACODES_KG_STORE=/fresh/private/store.kg
```

The exclusive CLI mode must not point at the canonical shared store.

## Ownership boundary

Metacodes owns proposals, policy/Lean admission, re-observation, transactions,
budgets, recovery classification, and final receipts. TinyKG owns storage,
authenticated daemon execution, graph primitives, generation/CAS checks, and its
own binary release process. High-level operation journals stay in Metacodes;
TinyKG stores durable task/provenance facts rather than every transient effect.

The TinyKG skill used by maintainers for cross-session project control is a third
boundary. It does not configure the embedded runtime and its remote credentials are
never read by Metacodes.

## Maintainer verification

Release-control tests require both variables and fail closed if either is absent:

```sh
export METACODES_TEST_TINYKG_BIN="$tinykg_bin"
export METACODES_TEST_TINYKG_SHA256="$tinykg_sha"
python scripts/verify_tinykg_binary.py
```

Tests never search `PATH`, sibling repositories, or stale `zig-out` artifacts.
