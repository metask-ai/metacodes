# Third-party notices

This inventory supports release review; the license files in each dependency are
authoritative. The table is rendered by `scripts/gen_third_party_notices.py`
from the dependency manifests; edit the manifests or `release/notices.static.md`,
never this file (`zig build release:notices` fails when it is stale).

| Component | Form | Source | License handling |
|---|---|---|---|
| highlight-zig | checked-in Zig source snapshot | `lib/highlight-zig/SOURCE.txt` (https://github.com/shuzuan-org/highlight-zig, commit `1645c82e0300`) | retain its bundled license |
| ripgrep 15.2.0 | checked-in target-specific upstream release binaries, redistributed as the AgentCore bundle `bin/rg[.exe]` runtime asset | `vendor/ripgrep/manifest.json` (https://github.com/BurntSushi/ripgrep, revision `e89fff89ac`) | MIT OR Unlicense; MIT text retained at `vendor/ripgrep/LICENSE-MIT` and shipped with the bundle notice |
| TinyKG 0.3.0 | checked-in target-specific CLI and daemon binaries | `vendor/tinykg/manifest.json` (https://github.com/metask-ai/tinykg, source commit `0b04014ba8d0`) | Apache-2.0; license retained at `vendor/tinykg/LICENSE` |
| Zig standard library/toolchain | build toolchain | ziglang.org | governed by Zig distribution terms |
| Lean 4 toolchain (leanprover/lean4:v4.14.0) | build toolchain for the release/formal gates; its runtime is statically linked into locally built formal-kernel binaries (not checked in) | `control-plane/lean/lean-toolchain` | Apache-2.0; review before distributing any built kernel binary |

Historical tree-sitter and TinyKG source snapshots remain in Git history but are
not part of the current source tree. Before public launch, run a complete history
and release-artifact license scan and confirm that the binary manifest, upstream
source link, and retained Apache-2.0 text satisfy the intended distribution.
