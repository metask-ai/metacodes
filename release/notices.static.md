# Third-party notices

This inventory supports release review; the license files in each dependency are
authoritative. The table is rendered by `scripts/gen_third_party_notices.py`
from the dependency manifests; edit the manifests or `release/notices.static.md`,
never this file (`zig build release:notices` fails when it is stale).

<!-- table: rendered by scripts/gen_third_party_notices.py from the manifests -->

Historical tree-sitter and TinyKG source snapshots remain in Git history but are
not part of the current source tree. Before public launch, run a complete history
and release-artifact license scan and confirm that the binary manifest, upstream
source link, and retained Apache-2.0 text satisfy the intended distribution.
