# TinyKG staging directory

`zig build tinykg:stage -Dtinykg-bin=... -Dtinykg-sha256=...` installs a
validated native binary and provenance receipt under `zig-out/vendor/tinykg/`.

This source-tree directory is documentation only. Do not copy or commit a TinyKG
binary here. The accepted contract is `deps/tinykg.json`; operational details are
in `doc/TINYKG_INTEGRATION.md`.
