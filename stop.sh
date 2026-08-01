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

# Stop background tunnel↔n8n auto-sync watcher if running
WATCH_PID_FILE="${ROOT_DIR}/.tunnel-watch.pid"
if [[ -f "$WATCH_PID_FILE" ]]; then
  pid="$(cat "$WATCH_PID_FILE" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    echo "[INFO] Stopped tunnel watcher (pid $pid)."
  fi
  rm -f "$WATCH_PID_FILE"
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
