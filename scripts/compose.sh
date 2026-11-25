#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
if [[ -f .env ]] && grep -q '^SERVER_PREPARED_ONLY=true$' .env 2>/dev/null; then
  for compose_argument in "$@"; do
    case "$compose_argument" in
      up|start|restart|run|create|build)
        echo 'Server is prepared-only. Startup/build is disabled until the owner approves and memory preflight passes.' >&2
        exit 2
        ;;
    esac
  done
fi
if ! command -v docker >/dev/null; then
  echo 'Docker CLI unavailable. Install/start a Docker Engine (for example Colima) first.' >&2
  exit 1
fi
if docker compose version >/dev/null 2>&1; then
  exec docker compose --project-directory "$project_root" --env-file .env --env-file infra/images.lock.env "$@"
fi
if command -v docker-compose >/dev/null; then
  exec docker-compose --project-directory "$project_root" --env-file .env --env-file infra/images.lock.env "$@"
fi
echo 'Docker Compose v2+ is unavailable.' >&2
exit 1
