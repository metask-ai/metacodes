#!/bin/sh
# Install metacodes from a release archive (or an unpacked release unit) on
# macOS or Linux: the TUI, TinyKG (CLI + daemon) and both Lean kernels, as one
# isolated install with its own state root, plus a launcher on PATH.
#
# This script only unpacks; the install itself is `bin/metacodes install`
# inside the unit (src/app/install.zig), the same code on every platform
# (doc/INSTALL_DESIGN.md §4).
#
#   scripts/install.sh metacodes-<version>-<target>.tar.gz
#   scripts/install.sh --prefix ~/opt/mc-work --link-name mc-work \
#       --sdk agentcore-<version>-<target>.tar.gz metacodes-<version>-<target>.tar.gz
#
# Options (all optional):
#   --prefix DIR      install here (default: ~/.local/opt/metacodes)
#   --state-dir DIR   keep this install's state there (default: <prefix>/state)
#   --sdk ARCHIVE|DIR also install the AgentCore SDK under <prefix>/sdk/agentcore
#   --link DIR        directory on PATH for the launcher (default: ~/.local/bin)
#   --link-name NAME  launcher name (default: metacodes; give each install its own)
#   --no-link         do not write a launcher
#   --force           replace a different version or foreign files at --prefix
#
# An archive with a `<archive>.sha256` sidecar beside it is checked first.
set -eu

prefix="${HOME}/.local/opt/metacodes"
link="${HOME}/.local/bin"
link_name="metacodes"
state_dir=""
sdk=""
force=""
unit=""

die() { echo "install.sh: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) [ $# -ge 2 ] || die "--prefix needs a directory"; prefix=$2; shift 2 ;;
    --state-dir) [ $# -ge 2 ] || die "--state-dir needs a directory"; state_dir=$2; shift 2 ;;
    --sdk) [ $# -ge 2 ] || die "--sdk needs an archive or directory"; sdk=$2; shift 2 ;;
    --link) [ $# -ge 2 ] || die "--link needs a directory"; link=$2; shift 2 ;;
    --link-name) [ $# -ge 2 ] || die "--link-name needs a name"; link_name=$2; shift 2 ;;
    --no-link) link=""; shift ;;
    --force) force="--force"; shift ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    -*) die "unknown option $1 (see --help)" ;;
    *) [ -z "$unit" ] || die "one release archive or unit, not two"; unit=$1; shift ;;
  esac
done
[ -n "$unit" ] || die "name the release archive (metacodes-<version>-<target>.tar.gz) or an unpacked unit"

work=$(mktemp -d "${TMPDIR:-/tmp}/metacodes-install.XXXXXX")
trap 'rm -rf "$work"' EXIT INT TERM

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# An unpacked unit directory: the one holding manifest.json, at the given path
# or one level below it (the archive's metacodes-<version>-<target>/ root).
unit_root() {
  if [ -f "$1/manifest.json" ]; then echo "$1"; return; fi
  for candidate in "$1"/*/; do
    if [ -f "${candidate}manifest.json" ]; then echo "${candidate%/}"; return; fi
  done
  die "$1 holds no release manifest.json"
}

unpack() { # <archive-or-dir> <scratch-subdir>
  if [ -d "$1" ]; then unit_root "$1"; return; fi
  [ -f "$1" ] || die "$1 does not exist"
  if [ -f "$1.sha256" ]; then
    expected=$(awk '{print $1; exit}' "$1.sha256")
    actual=$(sha256_of "$1")
    [ "$expected" = "$actual" ] || die "$1: SHA-256 $actual does not match $1.sha256 ($expected)"
  fi
  mkdir -p "$work/$2"
  archive=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
  case "$archive" in
    *.tar.gz|*.tgz) tar -xzf "$archive" -C "$work/$2" ;;
    *.zip) (cd "$work/$2" && unzip -q "$archive") ;;
    *) die "$1: expected a .tar.gz release archive" ;;
  esac
  unit_root "$work/$2"
}

# Plain assignments: `set -e` stops on a failed command substitution only
# there, not inside the arguments of another command.
root=$(unpack "$unit" cli)
[ -x "$root/bin/metacodes" ] || die "$root/bin/metacodes is missing; is this a metacodes release unit?"
sdk_root=""
if [ -n "$sdk" ]; then
  sdk_root=$(unpack "$sdk" sdk)
fi

set -- install --prefix "$prefix"
[ -n "$state_dir" ] && set -- "$@" --state-dir "$state_dir"
[ -n "$sdk_root" ] && set -- "$@" --sdk "$sdk_root"
if [ -n "$link" ]; then
  set -- "$@" --link "$link" --link-name "$link_name"
fi
[ -n "$force" ] && set -- "$@" --force

"$root/bin/metacodes" "$@"

if [ -n "$link" ]; then
  case ":${PATH}:" in
    *":${link}:"*) ;;
    *) echo "note: $link is not on PATH; add it to run \`$link_name\` directly" ;;
  esac
fi
