#!/usr/bin/env bash
# Start n8n stack (Postgres + n8n + optional Cloudflare Tunnel).
# Usage:
#   ./start.sh              # respect COMPOSE_PROFILES in .env (default: tunnel)
#   ./start.sh --local      # postgres + n8n only (no public tunnel)
#   ./start.sh --tunnel     # force Quick Tunnel profile
#   ./start.sh --named      # force named tunnel (requires CLOUDFLARE_TUNNEL_TOKEN + WEBHOOK_URL)
#   ./start.sh --sync       # keep running tunnel URL; only re-apply webhook env to n8n
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

MODE="auto" # auto | local | tunnel | named
SYNC_ONLY=0

usage() {
  cat <<'EOF'
Usage: ./start.sh [options]

  --local     Local only (no Cloudflare Tunnel; no public exposure)
  --tunnel    Quick Tunnel (ephemeral https://*.trycloudflare.com)
  --named     Named tunnel (CLOUDFLARE_TUNNEL_TOKEN + WEBHOOK_URL in .env)
  --sync      Do not restart tunnel; read current trycloudflare URL and re-apply to n8n
  -h, --help  Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local) MODE="local"; shift ;;
    --tunnel) MODE="tunnel"; shift ;;
    --named) MODE="named"; shift ;;
    --sync) SYNC_ONLY=1; MODE="tunnel"; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "[ERROR] Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

log() { echo "[INFO] $*"; }
err() { echo "[ERROR] $*" >&2; }
warn() { echo "[WARN] $*" >&2; }

normalize_url() {
  local u="${1:-}"
  if [[ -z "$u" ]]; then
    printf ''
    return
  fi
  printf '%s' "${u%/}/"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    err "Required command not found: $1"
    exit 1
  fi
}

require_cmd docker
if ! docker compose version >/dev/null 2>&1; then
  err "Docker Compose v2 is required (docker compose)."
  exit 1
fi

if [[ ! -f .env ]]; then
  if [[ -f .env.example ]]; then
    cp .env.example .env
    log "Created .env from .env.example"
    log "IMPORTANT: edit .env — set POSTGRES_PASSWORD and N8N_ENCRYPTION_KEY before production use."
  else
    err ".env is missing and .env.example was not found."
    exit 1
  fi
fi

# Docker Compose prefers shell environment over the project .env file.
# After changing WEBHOOK_URL we always re-export before compose recreate.
set -a
# shellcheck disable=SC1091
source .env
set +a

N8N_PORT="${N8N_PORT:-5678}"
PLACEHOLDER_PASSWORD="change_this_to_a_secure_password"
PLACEHOLDER_KEY="change_this_to_a_random_32byte_hex_string"

if [[ "${POSTGRES_PASSWORD:-}" == "$PLACEHOLDER_PASSWORD" ]] || \
   [[ "${N8N_ENCRYPTION_KEY:-}" == "$PLACEHOLDER_KEY" ]] || \
   [[ -z "${N8N_ENCRYPTION_KEY:-}" ]]; then
  warn "Default or empty secrets detected in .env."
  warn "  openssl rand -hex 16   # POSTGRES_PASSWORD"
  warn "  openssl rand -hex 32   # N8N_ENCRYPTION_KEY"
fi

case "$MODE" in
  local)
    export COMPOSE_PROFILES=""
    PROXY_HOPS_TARGET=0
    ;;
  tunnel)
    export COMPOSE_PROFILES="tunnel"
    PROXY_HOPS_TARGET=1
    ;;
  named)
    export COMPOSE_PROFILES="named-tunnel"
    PROXY_HOPS_TARGET=1
    if [[ -z "${CLOUDFLARE_TUNNEL_TOKEN:-}" ]]; then
      err "named-tunnel requires CLOUDFLARE_TUNNEL_TOKEN in .env"
      exit 1
    fi
    if [[ -z "${WEBHOOK_URL:-}" ]]; then
      err "named-tunnel requires WEBHOOK_URL in .env"
      exit 1
    fi
    ;;
  auto)
    COMPOSE_PROFILES="${COMPOSE_PROFILES:-tunnel}"
    export COMPOSE_PROFILES
    if [[ "$COMPOSE_PROFILES" == "tunnel" || "$COMPOSE_PROFILES" == "named-tunnel" ]]; then
      PROXY_HOPS_TARGET=1
    else
      PROXY_HOPS_TARGET=0
    fi
    if [[ "$COMPOSE_PROFILES" == "named-tunnel" ]]; then
      if [[ -z "${CLOUDFLARE_TUNNEL_TOKEN:-}" || -z "${WEBHOOK_URL:-}" ]]; then
        err "named-tunnel requires CLOUDFLARE_TUNNEL_TOKEN and WEBHOOK_URL in .env"
        exit 1
      fi
    fi
    ;;
esac

upsert_env() {
  local key="$1"
  local value="$2"
  if grep -q "^${key}=" .env 2>/dev/null; then
    if [[ "${OSTYPE:-}" == darwin* ]]; then
      sed -i '' "s|^${key}=.*|${key}=${value}|" .env
    else
      sed -i "s|^${key}=.*|${key}=${value}|" .env
    fi
  else
    printf '%s=%s\n' "$key" "$value" >> .env
  fi
}

# Write + export so compose cannot keep a stale shell value.
set_webhook_url() {
  local url
  url="$(normalize_url "${1:-}")"
  upsert_env "WEBHOOK_URL" "$url"
  export WEBHOOK_URL="$url"
  export N8N_WEBHOOK_URL="$url"
}

get_n8n_webhook_url() {
  local id got=""
  id="$(docker compose ps -q n8n 2>/dev/null || true)"
  if [[ -z "$id" ]]; then
    printf ''
    return
  fi
  got="$(docker exec "$id" printenv N8N_WEBHOOK_URL 2>/dev/null || true)"
  if [[ -z "$got" ]]; then
    got="$(docker exec "$id" printenv WEBHOOK_URL 2>/dev/null || true)"
  fi
  normalize_url "$got"
}

cloudflared_id() {
  docker compose ps -q cloudflared 2>/dev/null || true
}

# Only scrape URLs from the *current* cloudflared container lifetime (avoids stale hosts).
scrape_current_tunnel_url() {
  local id
  id="$(cloudflared_id)"
  if [[ -z "$id" ]]; then
    printf ''
    return
  fi
  # docker logs --since relative to now; use container start via inspect + full logs and take last
  docker logs "$id" 2>&1 \
    | grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' \
    | tail -n 1 || true
}

wait_for_tunnel_url() {
  local max_attempts="${1:-45}"
  local i url=""
  for ((i = 1; i <= max_attempts; i++)); do
    url="$(scrape_current_tunnel_url)"
    if [[ -n "$url" ]]; then
      printf '%s' "$url"
      return 0
    fi
    sleep 2
  done
  return 1
}

wait_for_service_healthy() {
  local service="$1"
  local attempts="${2:-40}"
  local i id health
  for ((i = 1; i <= attempts; i++)); do
    id="$(docker compose ps -q "$service" 2>/dev/null || true)"
    if [[ -z "$id" ]]; then
      sleep 2
      continue
    fi
    health="$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id" 2>/dev/null || echo missing)"
    if [[ "$health" == "healthy" || "$health" == "running" ]]; then
      if [[ "$health" == "healthy" || "$health" == "running" ]]; then
        [[ "$health" == "healthy" || "$health" == "running" ]] && {
          # For services with healthchecks, require healthy
          if docker inspect --format='{{if .State.Health}}yes{{else}}no{{end}}' "$id" 2>/dev/null | grep -q yes; then
            [[ "$health" == "healthy" ]] && return 0
          else
            [[ "$health" == "running" ]] && return 0
          fi
        }
      fi
    fi
    sleep 2
  done
  err "Service '$service' did not become healthy in time. Try: docker compose logs $service"
  return 1
}

# Recreate ONLY n8n so cloudflared keeps its trycloudflare hostname.
recreate_n8n() {
  log "Recreating n8n only (--no-deps) so the tunnel URL does not rotate..."
  docker compose up -d --force-recreate --no-deps n8n
  wait_for_service_healthy n8n 40
}

verify_n8n_webhook_url() {
  local expected
  expected="$(normalize_url "${1:-}")"
  local got
  got="$(get_n8n_webhook_url)"

  if [[ -z "$expected" ]]; then
    return 0
  fi

  if [[ "$got" == "$expected" ]]; then
    log "Verified n8n webhook base: $got"
    return 0
  fi

  err "n8n webhook URL mismatch."
  err "  expected: $expected"
  err "  got:      ${got:-<empty>}"
  err "Retrying once with explicit export..."
  set_webhook_url "$expected"
  recreate_n8n
  got="$(get_n8n_webhook_url)"
  if [[ "$got" != "$expected" ]]; then
    err "Still mismatched (n8n=${got:-<empty>})."
    return 1
  fi
  log "Verified n8n webhook base after retry: $got"
}

upsert_env "N8N_PROXY_HOPS" "$PROXY_HOPS_TARGET"
upsert_env "COMPOSE_PROFILES" "${COMPOSE_PROFILES}"
export N8N_PROXY_HOPS="$PROXY_HOPS_TARGET"
export COMPOSE_PROFILES

stop_unused_tunnels() {
  case "${COMPOSE_PROFILES}" in
    tunnel)
      docker compose --profile named-tunnel stop cloudflared-named >/dev/null 2>&1 || true
      docker compose --profile named-tunnel rm -f cloudflared-named >/dev/null 2>&1 || true
      ;;
    named-tunnel)
      docker compose --profile tunnel stop cloudflared >/dev/null 2>&1 || true
      docker compose --profile tunnel rm -f cloudflared >/dev/null 2>&1 || true
      ;;
    *)
      docker compose --profile tunnel --profile named-tunnel stop cloudflared cloudflared-named >/dev/null 2>&1 || true
      docker compose --profile tunnel --profile named-tunnel rm -f cloudflared cloudflared-named >/dev/null 2>&1 || true
      ;;
  esac
}

# Bring stack up carefully:
# - Start postgres + n8n first
# - Start cloudflared only after n8n is healthy
# - Prefer --no-recreate for cloudflared so Quick Tunnel host stays stable
log "Starting services (COMPOSE_PROFILES='${COMPOSE_PROFILES:-<none>}')..."
stop_unused_tunnels

docker compose up -d postgres
wait_for_service_healthy postgres 30
docker compose up -d --no-deps n8n
wait_for_service_healthy n8n 40

PUBLIC_URL=""

if [[ "${COMPOSE_PROFILES}" == "tunnel" ]]; then
  cf_id="$(cloudflared_id)"
  cf_running=0
  if [[ -n "$cf_id" ]] && docker inspect -f '{{.State.Running}}' "$cf_id" 2>/dev/null | grep -q true; then
    cf_running=1
  fi

  if [[ "$SYNC_ONLY" -eq 1 ]]; then
    log "Sync mode: keep current cloudflared container..."
    if [[ "$cf_running" -ne 1 ]]; then
      log "cloudflared not running — starting it (this creates a new public URL)."
      docker compose up -d cloudflared
    fi
  else
    if [[ "$cf_running" -eq 1 ]]; then
      log "cloudflared already running — keeping it (URL stays stable)."
      # Ensure compose still tracks it without recreate
      docker compose up -d --no-recreate cloudflared >/dev/null 2>&1 || true
    else
      log "Starting cloudflared Quick Tunnel..."
      docker compose up -d cloudflared
    fi
  fi

  log "Waiting for trycloudflare URL from current cloudflared container..."
  URL="$(wait_for_tunnel_url 45 || true)"
  if [[ -z "$URL" ]]; then
    err "Failed to retrieve Cloudflare Tunnel URL."
    err "Check: docker compose logs cloudflared"
    exit 1
  fi

  PUBLIC_URL="$(normalize_url "$URL")"
  log "Cloudflare Tunnel URL: $PUBLIC_URL"

  CURRENT_N8N="$(get_n8n_webhook_url)"
  set_webhook_url "$PUBLIC_URL"

  if [[ "$CURRENT_N8N" == "$PUBLIC_URL" ]]; then
    log "n8n already has matching webhook base — skip recreate."
  else
    if [[ -n "$CURRENT_N8N" ]]; then
      log "n8n had stale webhook base: $CURRENT_N8N"
    fi
    recreate_n8n
    # After n8n-only recreate, confirm tunnel did not rotate
    URL2="$(scrape_current_tunnel_url)"
    if [[ -n "$URL2" && "$(normalize_url "$URL2")" != "$PUBLIC_URL" ]]; then
      warn "Tunnel URL changed unexpectedly to $(normalize_url "$URL2") — re-applying."
      PUBLIC_URL="$(normalize_url "$URL2")"
      set_webhook_url "$PUBLIC_URL"
      recreate_n8n
    fi
  fi
  verify_n8n_webhook_url "$PUBLIC_URL"

  echo ""
  warn "Re-register external webhooks (WhatsApp / Midtrans / Telegram) with the public base above."
  warn "Path stays the same (e.g. /webhook/wa-service); only the host changes on Quick Tunnel."
  warn "Stable host: ./start.sh --named"

elif [[ "${COMPOSE_PROFILES}" == "named-tunnel" ]]; then
  docker compose up -d cloudflared-named
  PUBLIC_URL="$(normalize_url "${WEBHOOK_URL}")"
  log "Named tunnel active. WEBHOOK_URL=${PUBLIC_URL}"
  set_webhook_url "$PUBLIC_URL"
  recreate_n8n
  verify_n8n_webhook_url "$PUBLIC_URL"

else
  log "Local-only mode: no public tunnel."
  set_webhook_url ""
  recreate_n8n
fi

echo ""
echo "--------------------------------------------------"
echo " Status: n8n environment is active"
echo " Local UI:      http://localhost:${N8N_PORT}"
if [[ -n "$PUBLIC_URL" ]]; then
  echo " Public base:   ${PUBLIC_URL}"
  echo " n8n webhook:   $(get_n8n_webhook_url)"
  echo " Example:       ${PUBLIC_URL}webhook/wa-service"
  echo ""
  echo " SECURITY: tunnel may expose the FULL n8n UI. Use a strong owner password."
else
  echo " Public base:   (none — local only)"
fi
echo " Stop:          ./stop.sh"
echo " Backup:        ./backup.sh"
echo " Re-sync URL:   ./start.sh --sync"
echo "--------------------------------------------------"
