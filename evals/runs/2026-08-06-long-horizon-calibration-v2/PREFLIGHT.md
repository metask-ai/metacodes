# Long-horizon calibration preflight — 2026-08-06

Status: authorized and technically ready; no paid rollout had started when this
record was written. Observed model/network spend remains `$0`.

This directory is the immutable input bundle for the non-confirmatory
18-rollout calibration. It is mechanism/calibration-readiness evidence, not a
calibration result and not confirmatory outcome evidence.

## Frozen contract

- metacodes revision: `9e3898fcd0e5de194cf4adefd375deee07406b4c`
- authorization commit: `9e3898f` (`eval: authorize bounded calibration rollouts`)
- reproducible-link fix: `d5efc71` (`formal: make Darwin checker builds reproducible`)
- experiment fingerprint: `fa9128a5bd6823bb`
- plan fingerprint: `183a5d15ba1d3dd0`
- planned schedule: 1 non-scoring task × 3 arms × 6 trials = 18 rollouts
- calibration cap: `$100` and 3,000,000 tokens
- aggregate cap: `$1000` and 30,000,000 tokens
- confirmatory paid rollout remains disabled
- execution still requires the independent CLI key `--allow-paid-rollouts`

Artifact identities are recorded in `SHA256SUMS`. The TinyKG arm alone receives
the TinyKG and formal-kernel paths; Codex-style and Claude-style arms receive
neither. The formal artifact fingerprint is
`9832552a23d2d5e0e709d58824cd2bbd534d21fe4c1d3d45d5fb4be2e3d57f88`.

## Reproducibility finding

Before `d5efc71`, three links from unchanged Lean sources produced equal-size
but different binaries: `abba7177…`, `d8717a51…`, and `c5c51380…`. Comparing
two fresh outputs found 54 differing bytes: the 16-byte Mach-O `LC_UUID` plus
derived ad-hoc code-sign fields. The build script passed a random `mktemp`
basename to Apple's linker; that basename became the code-sign identifier.

The fix keeps a private random parent directory but uses the stable basename
`metacodes-formal-kernel`, links independently twice, and fails unless `cmp`
reports byte identity. Two complete post-fix builds both produced:

```text
sha256 = 1fb436a9fdcc300f94519dfea7d999a1fd94a1dd1da9d8cf91fdb1b09450b838
bytes  = 6542888
```

The frozen native artifact passed the Lean axiom audit, admit/block smoke tests,
and canonical-protocol rejection test. Its adjacent provenance binds Lean
4.14.0, Darwin arm64, Apple clang linking, source hashes, binary hash and build
time.

## Preflight verification

- clean detached worktree at the frozen revision
- `zig build`: passed
- `zig build test:eval`: 93 passed, 1 explicit native opt-in skip
- runtime arm smoke: all three arms passed with `paid=0`, `network=0`
- two independently generated dry-run plans: byte-identical
- dry-run plan SHA-256:
  `6625d3ee72c33f0c71493ea26fb61b9153532c49ce39f270da21635435df285b`

Promotion remains fail-closed: all 18 rollouts must be valid, cost/token
telemetry must be complete, the schedule and identities must match, and the
stage must remain below its budget. A promotion receipt may be generated only
from the three authoritative checkpoint files; the 54-rollout confirmatory
stage must not start from this preflight record alone.
