#!/usr/bin/env bash
# Install elan (the Lean toolchain manager) from a pinned release asset whose
# SHA-256 is pinned here, never from the mutable elan-init.sh on elan's master
# branch. Idempotent: an existing $ELAN_HOME/bin/elan (for example restored by
# actions/cache) is kept. The toolchain named in control-plane/lean/lean-toolchain
# installs on first use through elan's own resolver.
#
# Under GitHub Actions the elan bin directory is appended to $GITHUB_PATH so
# later steps see `lake` and `lean`; elsewhere the caller adds it to PATH.
set -euo pipefail

ELAN_VERSION=4.2.4
case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)
    asset=elan-x86_64-unknown-linux-gnu.tar.gz
    sha256=42b94d4244e8353142c456ec0e4ca6528fd898a6c604d4059f494e706e431f63
    ;;
  Linux-aarch64)
    asset=elan-aarch64-unknown-linux-gnu.tar.gz
    sha256=05febd124d84ebf994b2e7479922a5650b1e950c17ae3bd1ddd776b65bb72bf9
    ;;
  Darwin-arm64)
    asset=elan-aarch64-apple-darwin.tar.gz
    sha256=7ad829861392c718dfebde3a83b5c8508df47be02af68894b094b0b3952616e5
    ;;
  Darwin-x86_64)
    asset=elan-x86_64-apple-darwin.tar.gz
    sha256=8a340b309d8ed2e96f930761fa223b3af57a38f5d253b53ac90293c9516f8cd4
    ;;
  MINGW*-x86_64|MSYS*-x86_64)
    # GitHub's Windows runners run this through Git Bash; the Lean kernels
    # ship in the Windows release unit too (doc/INSTALL_DESIGN.md §5).
    asset=elan-x86_64-pc-windows-msvc.zip
    sha256=fad2e980a191c15884cc1d80d170ffc5fa84f3774541020145b66d1a644c6111
    ;;
  *)
    echo "install-elan: unsupported host $(uname -s)-$(uname -m)" >&2
    exit 1
    ;;
esac

elan_home="${ELAN_HOME:-$HOME/.elan}"
exe=""
python=python3
# On Windows `python3` may be the Microsoft Store stub; the runner's real
# interpreter is `python`.
case "$asset" in *.zip) exe=".exe"; python=python ;; esac

if [[ -x "$elan_home/bin/elan$exe" ]]; then
  echo "install-elan: keeping existing $("$elan_home/bin/elan$exe" --version) at $elan_home"
else
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  url="https://github.com/leanprover/elan/releases/download/v$ELAN_VERSION/$asset"
  echo "install-elan: fetching $url"
  curl --proto '=https' --tlsv1.2 --location --retry 5 --retry-connrefused --fail --silent --show-error -o "$tmp/$asset" "$url"
  "$python" - "$tmp/$asset" "$sha256" <<'PY'
import hashlib
import sys

path, expected = sys.argv[1], sys.argv[2]
with open(path, "rb") as handle:
    actual = hashlib.sha256(handle.read()).hexdigest()
if actual != expected:
    sys.exit("install-elan: SHA-256 mismatch for %s: expected %s, got %s; refusing to execute" % (path, expected, actual))
print("install-elan: SHA-256 verified")
PY
  if [[ "$asset" == *.zip ]]; then
    "$python" -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$tmp/$asset" "$tmp"
  else
    tar -xzf "$tmp/$asset" -C "$tmp"
  fi
  ELAN_HOME="$elan_home" "$tmp/elan-init$exe" -y --no-modify-path --default-toolchain none
  echo "install-elan: installed $("$elan_home/bin/elan$exe" --version) at $elan_home"
fi

if [[ -n "${GITHUB_PATH:-}" ]]; then
  # A later `shell: cmd` / PowerShell step reads GITHUB_PATH as a Windows path.
  if [[ -n "$exe" ]] && command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$elan_home/bin" >> "$GITHUB_PATH"
  else
    echo "$elan_home/bin" >> "$GITHUB_PATH"
  fi
fi
