# Third-party notices

This inventory supports release review; the license files in each dependency are
authoritative.

| Component | Form | Source | License handling |
|---|---|---|---|
| highlight-zig | checked-in Zig source snapshot | `lib/highlight-zig/SOURCE.txt` | retain its bundled license |
| ripgrep | distributed helper binary | `vendor/ripgrep/` | review and ship upstream notices/license |
| TinyKG | optional external native binary | `deps/tinykg.json` | Apache-2.0 dependency; not part of repository source |
| Zig standard library/toolchain | build toolchain | ziglang.org | governed by Zig distribution terms |

Historical tree-sitter and TinyKG source snapshots remain in Git history but are
not part of the current source tree or release bundle. Before public launch, run a
complete history and release-artifact license scan and update this inventory with
exact versions and license-file paths.
