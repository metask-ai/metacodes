#!/usr/bin/env bash
# Provision the pinned WorkBuddy-Bench checkout the installed-adapter tests
# (scripts/eval/tests/test_workbuddy_adapter.py) run against: the pinned
# commit, this repository's overlay, and WorkBuddy's locked environment in
# <dest>/.venv. Prints the directory to export as METACODES_WORKBUDDY_CHECKOUT.
#
# usage: provision_checkout.sh <dest> [--source <git url or path>]
#
#   <dest>    a directory that does not exist yet (or is empty)
#   --source  fetch the pinned commit from a mirror (a local clone, say)
#             instead of GitHub; origin still names the upstream, which
#             install_overlay requires
#
# Needs git, python3 and uv. Network: the commit (unless --source) and the
# packages uv.lock pins, from PyPI.
set -euo pipefail

if [[ $# -ne 1 && $# -ne 3 ]] || [[ $# -eq 3 && $2 != --source ]]; then
  echo "usage: $0 <dest> [--source <git url or path>]" >&2
  exit 2
fi
dest=$1
upstream=https://github.com/Tencent/WorkBuddy-Bench.git
source=${3:-$upstream}

repo_root=$(cd "$(dirname "$0")/../../.." && pwd)
commit=$(cd "$repo_root" && python3 -c 'from scripts.eval.workbuddy import WORKBUDDY_PINNED_COMMIT as c; print(c)')

if [[ -e $dest ]] && [[ -n $(ls -A "$dest") ]]; then
  echo "error: $dest exists and is not empty" >&2
  exit 1
fi
mkdir -p "$dest"
dest=$(cd "$dest" && pwd)

git init -q "$dest"
git -C "$dest" remote add origin "$upstream"
git -C "$dest" fetch -q --depth 1 "$source" "$commit"
git -C "$dest" checkout -q --detach FETCH_HEAD
if [[ $(git -C "$dest" rev-parse HEAD) != "$commit" ]]; then
  echo "error: fetched $(git -C "$dest" rev-parse HEAD), expected $commit" >&2
  exit 1
fi

(cd "$repo_root" && python3 -m scripts.eval.workbuddy.install_overlay "$dest") >&2
uv sync --quiet --frozen --python 3.12 --project "$dest" >&2

echo "$dest"
