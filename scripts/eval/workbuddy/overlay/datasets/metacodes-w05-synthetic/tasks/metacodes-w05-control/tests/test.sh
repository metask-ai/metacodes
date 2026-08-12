#!/bin/bash
set -euo pipefail
mkdir -p /logs/verifier
expected="$(mktemp)"
printf 'metacodes workbuddy w05 ok\n' > "$expected"
if cmp -s "$expected" /workspace/result.txt \
  && grep -qx 'immutable synthetic w05 seed' /workspace/seed.txt; then
  printf '1\n' > /logs/verifier/reward.txt
  printf '{"artifact":"pass","seed":"pass","quality_evidence":false}\n' \
    > /logs/verifier/w05-verdict.json
else
  printf '0\n' > /logs/verifier/reward.txt
  printf '{"artifact":"fail","seed":"unknown","quality_evidence":false}\n' \
    > /logs/verifier/w05-verdict.json
fi
