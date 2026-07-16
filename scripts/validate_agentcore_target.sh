#!/bin/sh
set -eu

target_was_explicit=$1
resolved_target=$2

if [ "$target_was_explicit" != true ]; then
    echo "AgentCore release bundle requires explicit -Dtarget=aarch64-macos.13.0" >&2
    exit 1
fi
case "$resolved_target" in
    aarch64-macos.13.0*) ;;
    *)
        echo "AgentCore v1 bundle target must be aarch64-macos.13.0 (resolved: $resolved_target)" >&2
        exit 1
        ;;
esac
