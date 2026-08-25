#!/bin/bash
# Run EVERY test gate, including the env-gated suites that silently skip
# without their fixtures. The Grep/Glob container outage survived ~200 trials
# partly because "run all the tests" had no single command that actually ran
# all the tests — dev-only suites passed while deployment reality went
# unasserted. Set the env vars below to real fixtures where available.
set -uo pipefail
cd "$(dirname "$0")/.."

: "${METACODES_WB_CORPUS:=/private/tmp/workbuddy-full-20260816/results}"
: "${METACODES_WORKBUDDY_CHECKOUT:=/private/tmp/workbuddy-full-20260816}"
# Default-strict like CI: a missing compiled Lean SDK is a coverage hole, not
# a pass. Hosts without a Lean toolchain fail loudly here; run
# `lake build` in control-plane/lean, or export the var as 0 to accept skips.
: "${METACODES_TEST_REQUIRE_LEAN_SDK:=1}"
export METACODES_WB_CORPUS METACODES_WORKBUDDY_CHECKOUT METACODES_TEST_REQUIRE_LEAN_SDK

fail=0
run() { echo "== $*"; "$@" || { echo "GATE FAILED: $*"; fail=1; }; }

run zig fmt --check build.zig src tests
run python3 scripts/check_doc_links.py
run zig build test
run zig build test:lib
run uv run --no-project --with pytest,pyyaml python -m pytest scripts/eval/tests/ -q \
    --ignore=scripts/eval/tests/test_native_runtime.py

# Report skips loudly: a skipped gated suite is a coverage hole, not a pass.
echo "== env gates: corpus=$([ -d "$METACODES_WB_CORPUS" ] && echo present || echo MISSING)" \
     "checkout=$([ -d "$METACODES_WORKBUDDY_CHECKOUT" ] && echo present || echo MISSING)"
exit $fail
