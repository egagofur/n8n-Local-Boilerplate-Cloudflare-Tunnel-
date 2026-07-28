#!/usr/bin/env bash
# Stop the n8n stack. Data in Docker volumes is preserved.
# Usage:
#   ./stop.sh           # docker compose down
#   ./stop.sh --volumes # also remove named volumes (DESTRUCTIVE)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

REMOVE_VOLUMES=0
if [[ "${1:-}" == "--volumes" ]]; then
  REMOVE_VOLUMES=1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "[ERROR] docker not found" >&2
  exit 1
fi

if [[ ! -f .env && -f .env.example ]]; then
  # compose still works; profiles may be empty
  :
fi

if [[ $REMOVE_VOLUMES -eq 1 ]]; then
  echo "[WARN] This will delete postgres_data and n8n_data volumes."
  read -r -p "Type 'yes' to continue: " confirm
  if [[ "$confirm" != "yes" ]]; then
    echo "Aborted."
    exit 1
  fi
  docker compose --profile tunnel --profile named-tunnel down -v
  echo "[INFO] Stack stopped and volumes removed."
else
  # Include all profiles so tunnel containers are also stopped
  docker compose --profile tunnel --profile named-tunnel down
  echo "[INFO] Stack stopped. Volumes preserved."
  echo "[INFO] Start again with: ./start.sh"
fi
