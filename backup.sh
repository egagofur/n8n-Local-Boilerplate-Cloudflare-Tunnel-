#!/usr/bin/env bash
# Backup n8n Postgres DB + n8n_data volume into ./backups/
# Usage: ./backup.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

if ! command -v docker >/dev/null 2>&1; then
  echo "[ERROR] docker not found" >&2
  exit 1
fi

if [[ ! -f .env ]]; then
  echo "[ERROR] .env not found. Run ./start.sh once or copy .env.example." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${ROOT_DIR}/backups/${STAMP}"
mkdir -p "$OUT_DIR"

PG_ID="$(docker compose ps -q postgres 2>/dev/null || true)"
if [[ -z "$PG_ID" ]]; then
  echo "[ERROR] postgres container is not running. Start the stack with ./start.sh first." >&2
  exit 1
fi

echo "[INFO] Dumping Postgres database '${POSTGRES_DB}'..."
docker compose exec -T postgres \
  pg_dump -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" --no-owner --format=custom \
  > "${OUT_DIR}/n8n.pgdump"

echo "[INFO] Archiving n8n_data volume..."
# Resolve actual volume name from compose project
N8N_VOL="$(docker volume ls --format '{{.Name}}' | grep -E '_n8n_data$' | head -n1 || true)"
if [[ -z "$N8N_VOL" ]]; then
  # Fallback common project name
  N8N_VOL="n8n_n8n_data"
fi

if docker volume inspect "$N8N_VOL" >/dev/null 2>&1; then
  docker run --rm \
    -v "${N8N_VOL}:/from:ro" \
    -v "${OUT_DIR}:/to" \
    alpine:3.20 \
    tar czf "/to/n8n_data.tar.gz" -C /from .
else
  echo "[WARN] Volume ${N8N_VOL} not found; skipped n8n_data archive."
fi

# Save non-secret runtime metadata (not .env secrets)
cat > "${OUT_DIR}/meta.txt" <<EOF
created_at=${STAMP}
postgres_image=${POSTGRES_IMAGE:-unknown}
n8n_image=${N8N_IMAGE:-unknown}
timezone=${GENERIC_TIMEZONE:-}
webhook_url=${WEBHOOK_URL:-}
note=Restore encryption requires the SAME N8N_ENCRYPTION_KEY from .env (not stored here).
EOF

echo "[INFO] Backup written to: ${OUT_DIR}"
echo "[INFO] Keep your .env N8N_ENCRYPTION_KEY safe — backups cannot decrypt credentials without it."
ls -lh "$OUT_DIR"
