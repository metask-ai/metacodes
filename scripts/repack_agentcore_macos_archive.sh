#!/bin/sh
set -eu

if [ "$#" -ne 1 ] || [ ! -f "$1" ] || [ -L "$1" ]; then
    echo "usage: repack_agentcore_macos_archive.sh <regular-static-archive>" >&2
    exit 2
fi

archive=$1
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/metask-agentcore-repack.XXXXXX")
output="${archive}.repacked.$$"
cleanup() {
    chmod -R u+rwX "$work_dir" 2>/dev/null || true
    rm -rf "$work_dir"
    rm -f "$output"
}
trap cleanup EXIT HUP INT TERM

cd "$work_dir"
/usr/bin/ar -x "$archive"
set -- ./*.o
if [ ! -e "$1" ]; then
    echo "AgentCore archive contains no object members" >&2
    exit 1
fi

# Zig's BSD archive records extracted members with mode 000 and may place the
# bundled compiler_rt member at two-byte alignment. Apple ld requires readable
# object files and eight-byte Mach-O member alignment. Rebuilding from the
# extracted objects with Apple libtool fixes both while preserving all members.
chmod u+rw "$@"
/usr/bin/libtool -static -o "$output" "$@"
mv "$output" "$archive"
