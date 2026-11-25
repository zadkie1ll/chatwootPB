#!/usr/bin/env bash
# Fetch sources only. Does not install dependencies, build images or start services.
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
source_url='https://github.com/chatwoot/chatwoot.git'
source_tag='v4.20.1'
source_commit='b2f94636d325a126a67c6c4c808303d8aa8cbeea'
destination="${1:-$project_root/chatwoot}"

if [[ $# -gt 1 ]]; then
  echo 'Usage: bash scripts/bootstrap-chatwoot.sh [empty-destination]' >&2
  exit 2
fi
if [[ -L "$destination" || -e "$destination" && ! -d "$destination" ]]; then
  echo 'Destination must be an empty directory, not a file or symlink.' >&2
  exit 2
fi
if [[ -d "$destination" && -n "$(ls -A "$destination")" ]]; then
  echo 'Destination is not empty; no existing files were changed.' >&2
  exit 2
fi
command -v git >/dev/null
mkdir -p "$destination"
git init -q "$destination"
git -C "$destination" remote add upstream "$source_url"
git -C "$destination" fetch --depth=1 upstream "refs/tags/$source_tag:refs/tags/$source_tag"
actual_commit="$(git -C "$destination" rev-parse "refs/tags/$source_tag^{commit}")"
if [[ "$actual_commit" != "$source_commit" ]]; then
  echo "Refusing checkout: tag resolved to $actual_commit, expected $source_commit." >&2
  exit 1
fi
git -C "$destination" -c advice.detachedHead=false checkout --detach "$source_commit"
echo "Verified official source $source_tag at $source_commit in $destination"
echo 'Sources include separately licensed enterprise/. Do not build or start before the CE-only procedure in docs/operations.md.'
