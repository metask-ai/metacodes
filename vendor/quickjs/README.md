# vendored QuickJS (manifest-pinned upstream source)

- Upstream: https://bellard.org/quickjs/
- Release: 2025-09-13, official archive revision 2,
  `https://bellard.org/quickjs/quickjs-2025-09-13-2.tar.xz`
- Archive SHA-256: `996c6b5018fc955ad4d06426d0e9cb713685a00c825aa5c0418bd53f7df8b0b4`
- License: MIT, see `LICENSE` in this directory.
- Manifest: `manifest.json` (`metacodes.quickjs-source/v1`) pins the archive, every
  vendored file, every patch and every patched result by SHA-256.

## What is here

Only the engine sources and headers from the archive, **byte for byte**: no
`qjs`/`qjsc` executables, no `quickjs-libc`, no filesystem, process, network or
module loader, no tests. `.gitattributes` marks the directory `-whitespace` so
the repository's whitespace check never asks for upstream bytes to be edited,
and `linguist-vendored` so it stays out of language statistics; the upstream
`.c`/`.h` files are also `linguist-generated`, which collapses their diffs on
GitHub while the patches, this README and the manifest stay expanded.

Builds never fetch the engine. QuickJS is compiled from source because it is
statically linked into metacodes and AgentCore with hidden symbols; a prebuilt
library cannot do that on every target.

## Local changes

Upstream files are never edited in place. Each local change is one patch in
`patches/`, applied in manifest order at build time by
`scripts/stage_quickjs_sources.py` (exact positions, no fuzz) into a build
directory:

| Patch | Why |
|---|---|
| `0001-optional-atomics.patch` | Lets `-DMETACODES_NO_ATOMICS` drop `Atomics` and its pthread dependency. Upstream defines `CONFIG_ATOMICS` unconditionally, so no compiler flag alone can turn it off. |
| `0002-typed-dbuf-realloc.patch` | Replaces a cast of `js_realloc_rt` to `DynBufReallocFunc` with a correctly typed adapter. Calling through the cast traps clang's function sanitizer in Debug and ReleaseSafe builds. |

Anything that a `-D` define or a compiler flag can do belongs in `build.zig`,
not in a patch.

## Verification

```sh
python3 scripts/verify_quickjs_sources.py
```

This runs in `zig build test:units`, and therefore in `zig build test` and
`gate:pr`. It checks file and patch hashes, that the directory holds exactly the
declared files, that the compiled sources and every header they include are
pinned, that the patches apply exactly, and the patched digests.
To prove provenance against the official archive (offline, nothing
downloaded):

```sh
curl -fLO https://bellard.org/quickjs/quickjs-2025-09-13-2.tar.xz
python3 scripts/verify_quickjs_sources.py --archive quickjs-2025-09-13-2.tar.xz
```

## Updating

1. Download the new official archive and record its SHA-256.
2. Copy the same engine files from it into this directory, unmodified.
3. Re-create each patch against the new sources (`diff -u --label a/<file> --label b/<file>`),
   keeping the description lines at the top; drop patches upstream made unnecessary.
4. Update `manifest.json`: release, archive URL, SHA-256 and root, and the digests of
   `files`, `patches` and `patched`.
5. Run `python3 scripts/verify_quickjs_sources.py --archive <archive>`.
