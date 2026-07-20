#!/usr/bin/env sh
set -eu

BINDGEN=${BINDGEN:-bindgen}
EXPECTED='bindgen 0.72.1'
ACTUAL=$("$BINDGEN" --version)
if [ "$ACTUAL" != "$EXPECTED" ]; then
    echo "AgentCore Rust bindings require $EXPECTED, got $ACTUAL" >&2
    exit 1
fi

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BINDGEN_INCLUDES="$REPO_ROOT/scripts/agentcore_bindgen_include"
TMP_FILE=$(mktemp)
TMP_NORMALIZED=$(mktemp)
CHECKED_IN_NORMALIZED=$(mktemp)
trap 'rm -f "$TMP_FILE" "$TMP_NORMALIZED" "$CHECKED_IN_NORMALIZED"' EXIT HUP INT TERM

"$BINDGEN" "$REPO_ROOT/sdk/metask/agentcore.h" \
    --output "$TMP_FILE" \
    --allowlist-function '^metask_agentcore_.*' \
    --allowlist-type '^metask_agentcore_.*' \
    --allowlist-var '^METASK_AGENTCORE_.*' \
    --formatter rustfmt \
    -- --target=x86_64-unknown-linux-gnu -std=c11 -nostdinc "-I$BINDGEN_INCLUDES"

sed 's/\r$//' "$TMP_FILE" > "$TMP_NORMALIZED"
sed 's/\r$//' "$REPO_ROOT/sdk/rust/src/raw.rs" > "$CHECKED_IN_NORMALIZED"
if ! cmp -s "$TMP_NORMALIZED" "$CHECKED_IN_NORMALIZED"; then
    echo 'sdk/rust/src/raw.rs is stale; regenerate it with bindgen 0.72.1' >&2
    exit 1
fi
