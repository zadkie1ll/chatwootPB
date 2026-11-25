#!/usr/bin/env bash
# Explicit operator startup after resource and image checks.
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$project_root"
if [[ "${1:-}" != '--approved' ]]; then
  echo 'Start is disabled. After the owner approves startup and RAM is upgraded: bash scripts/server/start.sh --approved' >&2
  exit 2
fi
python3 scripts/server/preflight.py
# Build/load images separately on a build host; this server is not a build machine.
for release_archive in release-images gateway-images; do
  if [[ -f "$release_archive.tar.gz" ]]; then
    sha256sum -c "$release_archive.sha256"
    gzip -dc "$release_archive.tar.gz" | docker image load
  fi
done
while IFS= read -r image_reference; do
  docker image inspect "$image_reference" >/dev/null
done < <(bash scripts/compose.sh --profile antivirus config --images | sort -u)
python3 - <<'PY'
from pathlib import Path
p = Path('.env')
s = p.read_text()
s = s.replace('SERVER_PREPARED_ONLY=true', 'SERVER_PREPARED_ONLY=false')
p.write_text(s)
PY
bash scripts/compose.sh up --no-build --pull never -d postgres redis chatwoot-prepare
bash scripts/compose.sh wait chatwoot-prepare
bash scripts/compose.sh --profile tools run --rm --pull never --no-deps corporate-bootstrap
bash scripts/compose.sh --profile antivirus up --no-build --pull never -d
bash scripts/compose.sh ps -a
