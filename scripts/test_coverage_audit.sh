#!/usr/bin/env bash
# Strict sensor adapter for the Lean-backed development-rule control plane.
# Unlike the former substring audit, missing/invalid evidence returns non-zero.

set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 scripts/rule_control.py observe "$@"
