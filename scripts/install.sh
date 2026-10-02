#!/bin/sh
# Install metacodes on macOS or Linux: the TUI, TinyKG (CLI + daemon) and both
# Lean kernels as one isolated install with its own state root, the AgentCore
# SDK, and a launcher on PATH. Rerunning upgrades in place and keeps the state.
#
#   curl -fsSL https://raw.githubusercontent.com/metask-ai/metacodes/main/scripts/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/metask-ai/metacodes/main/scripts/install.sh | sh -s -- --version 0.3.0
#   scripts/install.sh --dev                   # build this checkout, install it as `metacodes-dev`
#   scripts/install.sh metacodes-<version>-<target>.tar.gz
#
# The install itself is `bin/metacodes install` inside the release unit
# (src/app/install.zig), the same code on every platform; this script only
# obtains a unit — a published release, an archive or directory you name, or
# one built from a checkout — and calls it (doc/INSTALL_DESIGN.md §4).
#
# Two installs side by side, one released and one from your checkout, are the
# default: they differ in prefix, launcher name and state root, so neither can
# see the other's config, credentials, KG store or sessions.
set -eu

repo="metask-ai/metacodes"

usage() {
  cat <<'EOF'
usage: install.sh [options] [ARCHIVE|UNIT-DIR]

Where the release unit comes from (one of):
  (nothing)           the latest published release, downloaded and SHA-256 checked
  --version X.Y.Z     that published release instead of the latest
  --dev               build the checkout this script belongs to (needs zig, elan, python3)
  --source DIR        build the checkout at DIR (implies --dev; use it with curl | sh)
  ARCHIVE|UNIT-DIR    a downloaded release archive (.tar.gz) or an unpacked unit

Where it goes:
  --prefix DIR        install directory (default ~/.local/opt/metacodes,
                      ~/.local/opt/metacodes-dev with --dev)
  --state-dir DIR     state root (default <prefix>/state)
  --link DIR          directory for the launcher (default ~/.local/bin)
  --link-name NAME    launcher name (default metacodes, metacodes-dev with --dev)
  --no-link           do not write a launcher
  --sdk ARCHIVE|DIR   use this AgentCore SDK instead of the matching one
  --no-sdk            do not install the AgentCore SDK
  --force             also replace foreign files at --prefix or another launcher
  --release-base URL  mirror of https://github.com/metask-ai/metacodes/releases
  -h, --help          this text

Rerunning over an install of this product replaces its version and keeps its
state root; foreign files and other launchers are never replaced without --force.
EOF
}

die() { echo "install.sh: $*" >&2; exit 1; }
note() { echo "install.sh: $*" >&2; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# fetch <url> <file>
fetch() {
  if command -v curl >/dev/null 2>&1; then curl -fsSL --retry 3 -o "$2" "$1" </dev/null
  elif command -v wget >/dev/null 2>&1; then wget -q -O "$2" "$1" </dev/null
  else die "need curl or wget to download a release"; fi
}

# The tag GitHub's /releases/latest redirects to (no API, no rate limit).
latest_tag() {
  if command -v curl >/dev/null 2>&1; then
    final=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$1/latest" </dev/null) || return 1
  else
    final=$(wget -q -S --spider "$1/latest" 2>&1 </dev/null | awk 'tolower($1)=="location:"{u=$2} END{print u}') || return 1
  fi
  final=${final%/}
  case "$final" in */tag/*) echo "${final##*/tag/}" ;; *) return 1 ;; esac
}

# The release target this host runs (release/LAYOUT.md).
host_target() {
  os=$(uname -s); arch=$(uname -m)
  case "$os:$arch" in
    Darwin:arm64|Darwin:aarch64) echo "aarch64-macos" ;;
    Linux:x86_64|Linux:amd64) echo "x86_64-linux-gnu" ;;
    MINGW*|MSYS*|CYGWIN*) die "on Windows use scripts/install.ps1" ;;
    *) die "no metacodes release is built for $os $arch (aarch64 macOS and x86_64 Linux are; --dev builds one from source)" ;;
  esac
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

# download_asset <base> <tag> <name> <sums-file>: the asset beside a sidecar
# taken from the release's SHA256SUMS, so unpack() checks it.
download_asset() {
  sum=$(awk -v n="$3" '$2==n {print $1}' "$4")
  [ -n "$sum" ] || die "release $2 lists no $3"
  fetch "$1/download/$2/$3" "$work/$3" || die "could not download $1/download/$2/$3"
  echo "$sum  $3" > "$work/$3.sha256"
  echo "$work/$3"
}

# Build a release unit from a checkout, the way release.yml does: kernels
# first, their digests pinned into the executable, then release:verify.
build_from_source() { # <checkout> <unit-dir> <target>
  command -v zig >/dev/null 2>&1 || die "--dev needs zig 0.16 on PATH"
  command -v python3 >/dev/null 2>&1 || die "--dev needs python3 on PATH"
  if ! command -v lake >/dev/null 2>&1; then
    [ -x "$HOME/.elan/bin/lake" ] || die "--dev needs elan (lake) for the Lean kernels: https://github.com/leanprover/elan"
    PATH="$HOME/.elan/bin:$PATH"; export PATH
  fi
  note "building $1 ($(git -C "$1" rev-parse --short HEAD 2>/dev/null || echo '?')) into $2"
  rm -rf "$2"
  (cd "$1" && zig build kernels:stage -Dlean-kernels=on -Doptimize=ReleaseSafe --prefix "$2") </dev/null >&2
  pins=$(cd "$1" && python3 scripts/kernel_pins.py "$2" </dev/null)
  # $pins is two -D options; it is split on purpose.
  # shellcheck disable=SC2086
  (cd "$1" && zig build release:verify -Drelease-layout=true -Doptimize=ReleaseSafe --prefix "$2" $pins) </dev/null >&2
  if [ -z "$sdk" ] && [ "$want_sdk" = 1 ]; then
    mkdir -p "$work/sdk-dist"
    (cd "$1" && zig build agentcore:archive -Dtarget="$3" -Doptimize=ReleaseSafe -Dagentcore-archive-dir="$work/sdk-dist") </dev/null >&2
    for candidate in "$work"/sdk-dist/metask-agentcore-*-"$3".tar.gz; do
      [ -f "$candidate" ] && sdk=$candidate
    done
    [ -n "$sdk" ] || die "agentcore:archive produced no SDK archive for $3"
  fi
}

main() {
  prefix=""
  link="${HOME}/.local/bin"
  link_name=""
  state_dir=""
  sdk=""
  want_sdk=1
  force=""
  unit=""
  version=""
  dev=0
  source_dir=""
  base="https://github.com/$repo/releases"

  while [ $# -gt 0 ]; do
    case "$1" in
      --prefix) [ $# -ge 2 ] || die "--prefix needs a directory"; prefix=$2; shift 2 ;;
      --state-dir) [ $# -ge 2 ] || die "--state-dir needs a directory"; state_dir=$2; shift 2 ;;
      --sdk) [ $# -ge 2 ] || die "--sdk needs an archive or directory"; sdk=$2; shift 2 ;;
      --no-sdk) want_sdk=0; shift ;;
      --link) [ $# -ge 2 ] || die "--link needs a directory"; link=$2; shift 2 ;;
      --link-name) [ $# -ge 2 ] || die "--link-name needs a name"; link_name=$2; shift 2 ;;
      --no-link) link=""; shift ;;
      --force) force="--force"; shift ;;
      --version) [ $# -ge 2 ] || die "--version needs X.Y.Z"; version=$2; shift 2 ;;
      --dev) dev=1; shift ;;
      --source) [ $# -ge 2 ] || die "--source needs a checkout"; source_dir=$2; dev=1; shift 2 ;;
      --release-base) [ $# -ge 2 ] || die "--release-base needs a URL"; base=${2%/}; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      -*) die "unknown option $1 (see --help)" ;;
      *) [ -z "$unit" ] || die "one release archive or unit, not two"; unit=$1; shift ;;
    esac
  done
  [ "$dev" = 0 ] || [ -z "$unit$version" ] || die "--dev builds from source; it takes no archive and no --version"
  [ -z "$unit" ] || [ -z "$version" ] || die "name an archive or a --version, not both"
  if [ "$dev" = 1 ]; then
    : "${prefix:=${HOME}/.local/opt/metacodes-dev}"
    : "${link_name:=metacodes-dev}"
  else
    : "${prefix:=${HOME}/.local/opt/metacodes}"
    : "${link_name:=metacodes}"
  fi

  work=$(mktemp -d "${TMPDIR:-/tmp}/metacodes-install.XXXXXX")
  trap 'rm -rf "$work"' EXIT
  trap 'exit 130' INT TERM

  # Plain assignments throughout: `set -e` stops on a failed command
  # substitution only there, not inside the arguments of another command.
  if [ "$dev" = 1 ]; then
    if [ -z "$source_dir" ]; then
      case "$0" in
        */*) source_dir=$(cd "$(dirname "$0")/.." && pwd) ;;
        *) die "--dev from a pipe needs --source <checkout>" ;;
      esac
    fi
    source_dir=$(cd "$source_dir" && pwd)
    [ -f "$source_dir/build.zig" ] && [ -f "$source_dir/scripts/kernel_pins.py" ] || die "$source_dir is not a metacodes checkout"
    target=$(host_target)
    unit="$source_dir/zig-out/dev-unit"
    build_from_source "$source_dir" "$unit" "$target"
  elif [ -z "$unit" ]; then
    target=$(host_target)
    if [ -z "$version" ]; then
      version=$(latest_tag "$base") || die "could not find the latest release at $base (pass --version X.Y.Z)"
    fi
    note "metacodes $version for $target from $base"
    fetch "$base/download/$version/metacodes-$version-SHA256SUMS" "$work/SHA256SUMS" ||
      die "release $version has no metacodes-$version-SHA256SUMS at $base"
    unit=$(download_asset "$base" "$version" "metacodes-$version-$target.tar.gz" "$work/SHA256SUMS")
    if [ -z "$sdk" ] && [ "$want_sdk" = 1 ]; then
      sdk_name=$(awk -v t="-$target.tar.gz" '$2 ~ /^metask-agentcore-/ && substr($2, length($2) - length(t) + 1) == t {print $2; exit}' "$work/SHA256SUMS")
      if [ -n "$sdk_name" ]; then
        sdk=$(download_asset "$base" "$version" "$sdk_name" "$work/SHA256SUMS")
      else
        note "release $version carries no AgentCore SDK for $target; installing without it"
      fi
    fi
  fi

  root=$(unpack "$unit" cli)
  [ -x "$root/bin/metacodes" ] || die "$root/bin/metacodes is missing; is this a metacodes release unit?"
  # Releases before the installer (manifest v1) have no `install` command, and
  # their executable would take the word as a prompt: refuse them here.
  if ! grep -q '"name": *"metacodes-cli"' "$root/manifest.json" ||
     ! grep -Eq '"schema_version": *2[,}[:space:]]' "$root/manifest.json"; then
    die "this release unit predates \`metacodes install\` (manifest v1); use a release that ships it, or --dev"
  fi
  sdk_root=""
  if [ -n "$sdk" ] && [ "$want_sdk" = 1 ]; then
    sdk_root=$(unpack "$sdk" sdk)
  fi

  set -- install --prefix "$prefix" --upgrade
  [ -n "$state_dir" ] && set -- "$@" --state-dir "$state_dir"
  [ -n "$sdk_root" ] && set -- "$@" --sdk "$sdk_root"
  if [ -n "$link" ]; then
    set -- "$@" --link "$link" --link-name "$link_name"
  fi
  [ -n "$force" ] && set -- "$@" --force

  "$root/bin/metacodes" "$@" </dev/null

  # An existing default state (from a development build or an older install)
  # is never merged in silently; say how to reuse it.
  if [ -z "$state_dir" ] && [ -f "$HOME/.metacodes/auth.json" ]; then
    installed_root=$(cd "$prefix" && pwd -P)/state
    if [ ! -f "$installed_root/auth.json" ] && [ ! -f "$installed_root/config.json" ]; then
      note "this install keeps its own state in $installed_root (empty, so sign in once)."
      note "to reuse ~/.metacodes instead, rerun with --state-dir ~/.metacodes, or copy"
      note "config.json, auth.json and models.toml from ~/.metacodes into $installed_root."
    fi
  fi
  if [ -n "$link" ]; then
    case ":${PATH}:" in
      *":${link}:"*)
        resolved=$(command -v "$link_name" 2>/dev/null || true)
        if [ -n "$resolved" ] && [ "$resolved" != "$link/$link_name" ]; then
          note "\`$link_name\` on your PATH is $resolved, which comes before $link/$link_name"
        fi
        ;;
      *) note "$link is not on PATH; add it to run \`$link_name\` directly" ;;
    esac
  fi
}

main "$@"
