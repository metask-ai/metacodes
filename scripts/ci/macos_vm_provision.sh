#!/bin/bash
# Prepares the macOS VM pool's golden image (doc/VM_POOLS.md, "The Mac
# Studio"). Run it inside a VM cloned from a Cirrus Labs macOS base
# image, as that image's admin user, with the pool host's SSH public key:
#
#   ssh admin@<vm> 'bash -s -- "<public key>"' < scripts/ci/macos_vm_provision.sh
#
# Afterwards the VM accepts only that key, its admin password is random and
# unrecorded, and it holds no credential: a job sees only the single-use
# runner configuration the pool hands it. Idempotent; run it again to refresh
# an image (the runner version below is the one GitHub's hosted macOS images
# ran on 2026-11-18; keep it current, a stale runner updates itself on every
# job). Tested by scripts/tests/test_vm_pool.py.
set -euo pipefail

PUBLIC_KEY=${1:?usage: macos_vm_provision.sh "<the pool host's SSH public key>"}
RUNNER_VERSION=2.338.2
RUNNER_SHA256=25a065af409ffa317ab4d5a3b614dd15fc9c40f2172bc1b35a1b1258e919a388
RUNNER_DIR="$HOME/actions-runner"
BREW_PATH="/opt/homebrew/bin:/opt/homebrew/sbin"

case "$PUBLIC_KEY" in
  ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*) ;;
  *) echo "macos_vm_provision: not an SSH public key: $PUBLIC_KEY" >&2; exit 2 ;;
esac
export PATH="$BREW_PATH:$PATH"
command -v brew >/dev/null || { echo "macos_vm_provision: the base image has no Homebrew" >&2; exit 1; }

# What the gates expect from a hosted macOS image (.github/workflows/ci.yml):
# bash 5 for `shell: bash`, Python 3 with pip, ripgrep, and zstd plus GNU tar,
# which actions/cache uses, so the pool restores the caches hosted runs saved.
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1
brew update --quiet
brew install --quiet bash python@3.12 ripgrep zstd gnu-tar coreutils jq git
xcode-select -p >/dev/null || { echo "macos_vm_provision: no Xcode command line tools" >&2; exit 1; }

# The Actions runner, pinned and checked.
archive="$(mktemp -d)/runner.tar.gz"
curl -fsSL -o "$archive" \
  "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-osx-arm64-${RUNNER_VERSION}.tar.gz"
echo "${RUNNER_SHA256}  ${archive}" | shasum -a 256 -c -
rm -rf "$RUNNER_DIR"
mkdir -p "$RUNNER_DIR"
tar -xzf "$archive" -C "$RUNNER_DIR"
rm -f "$archive"
# The runner reads a job's PATH and environment from these files.
printf '%s\n' "$BREW_PATH:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" > "$RUNNER_DIR/.path"
printf '%s\n' "LANG=en_US.UTF-8" "ImageOS=macos26" > "$RUNNER_DIR/.env"

# Only the pool host's key logs in; no password does.
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
printf '%s\n' "$PUBLIC_KEY" > "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"
sudo sed -i '' -E \
  -e 's/^#?PasswordAuthentication .*/PasswordAuthentication no/' \
  -e 's/^#?KbdInteractiveAuthentication .*/KbdInteractiveAuthentication no/' \
  /etc/ssh/sshd_config
grep -q '^PasswordAuthentication no' /etc/ssh/sshd_config || echo 'PasswordAuthentication no' | sudo tee -a /etc/ssh/sshd_config >/dev/null
grep -q '^KbdInteractiveAuthentication no' /etc/ssh/sshd_config || echo 'KbdInteractiveAuthentication no' | sudo tee -a /etc/ssh/sshd_config >/dev/null
sudo dscl . -passwd "/Users/$(id -un)" "$(openssl rand -base64 30)"

# A CI machine: no sleep, no updates, no indexing.
sudo pmset -a sleep 0 displaysleep 0 disksleep 0
sudo softwareupdate --schedule off >/dev/null 2>&1 || true
sudo mdutil -a -i off >/dev/null 2>&1 || true

# Nothing a job could take: no keys, tokens or history.
rm -f "$HOME"/.ssh/id_* "$HOME"/.ssh/known_hosts "$HOME"/.git-credentials "$HOME"/.netrc
rm -rf "$HOME/.config/gh"
rm -f "$HOME"/.zsh_history "$HOME"/.bash_history

echo "provisioned: runner $RUNNER_VERSION, $(python3 --version), $(bash --version | head -n 1)"
