#!/bin/sh
set -eu

target_was_explicit=$1
resolved_target=$2

if [ "$target_was_explicit" != true ]; then
    echo "AgentCore release bundle requires explicit -Dtarget=<triple>" >&2
    exit 1
fi
if [ -z "$resolved_target" ]; then
    echo "AgentCore release bundle resolved an empty target" >&2
    exit 1
fi
