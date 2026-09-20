# TinyKG binary bundle

This directory contains the manually maintained TinyKG CLI bundle consumed by a
normal Metacodes build. It contains no TinyKG source code and no runtime store.

`manifest.json` binds every asset to its target family, executable format,
architectures, SHA-256, upstream commit, Zig version, and ReleaseSafe/strip build
profile. `deps/tinykg.json` independently pins the CLI and store contract.

Supported assets (each target family has a CLI and daemon artifact in a v2
manifest):

- `bin/tinykg-macos-universal`: macOS arm64 and x86_64;
- `bin/tinykg-linux-x86_64`: static-musl x86_64 Linux;
- `bin/tinykg-linux-aarch64`: static-musl arm64 Linux;
- `bin/tinykg-windows-x86_64.exe`: x86_64 Windows.
- `bin/tinykgd-macos-universal`, `bin/tinykgd-linux-x86_64`,
  `bin/tinykgd-linux-aarch64`, and `bin/tinykgd-windows-x86_64.exe`: matching
  `tinykgd` daemon assets.

The default build selects exactly one target-compatible asset, verifies the
manifest digest and executable format, and installs it as
`zig-out/vendor/tinykg/tinykg[.exe]`. A native build additionally executes the
version and fresh-store probes. See `doc/TINYKG_INTEGRATION.md` before manually
replacing any asset.
