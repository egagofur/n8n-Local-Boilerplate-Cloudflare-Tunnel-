#!/usr/bin/env bash
# Start n8n stack (Postgres + n8n + optional Cloudflare Tunnel).
# Usage:
#   ./start.sh              # respect COMPOSE_PROFILES in .env (default: tunnel)
#   ./start.sh --local      # postgres + n8n only (no public tunnel)
#   ./start.sh --tunnel     # force Quick Tunnel profile
#   ./start.sh --named      # force named tunnel (requires CLOUDFLARE_TUNNEL_TOKEN + WEBHOOK_URL)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

MODE="auto" # auto | local | tunnel | named

usage() {
  cat <<'EOF'
Usage: ./start.sh [options]

  --local     Local only (no Cloudflare Tunnel; no public exposure)
  --tunnel    Quick Tunnel (ephemeral https://*.trycloudflare.com)
  --named     Named tunnel (CLOUDFLARE_TUNNEL_TOKEN + WEBHOOK_URL in .env)
  -h, --help  Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local) MODE="local"; shift ;;
    --tunnel) MODE="tunnel"; shift ;;
    --named) MODE="named"; shift ;;
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

# --- Ensure .env exists -------------------------------------------------------
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

# Load selected keys for local checks / banner (do not export whole file blindly)
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
  echo "[WARN] Default or empty secrets detected in .env."
  echo "[WARN] Generate and set secure values before storing real credentials:"
  echo "[WARN]   openssl rand -hex 16   # POSTGRES_PASSWORD"
  echo "[WARN]   openssl rand -hex 32   # N8N_ENCRYPTION_KEY"
  echo "[WARN] Changing N8N_ENCRYPTION_KEY later will break existing encrypted credentials."
fi

# --- Resolve compose profile mode ---------------------------------------------
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
      err "COMPOSE_PROFILES=named-tunnel requires CLOUDFLARE_TUNNEL_TOKEN in .env"
      exit 1
    fi
    if [[ -z "${WEBHOOK_URL:-}" ]]; then
      err "Named tunnel requires WEBHOOK_URL set to your stable HTTPS base (trailing slash)."
      exit 1
    fi
    ;;
  auto)
    # Keep COMPOSE_PROFILES from .env (default tunnel in .env.example)
    COMPOSE_PROFILES="${COMPOSE_PROFILES:-tunnel}"
    export COMPOSE_PROFILES
    if [[ "$COMPOSE_PROFILES" == "tunnel" || "$COMPOSE_PROFILES" == "named-tunnel" ]]; then
      PROXY_HOPS_TARGET=1
    else
      PROXY_HOPS_TARGET=0
    fi
    if [[ "$COMPOSE_PROFILES" == "named-tunnel" ]]; then
      if [[ -z "${CLOUDFLARE_TUNNEL_TOKEN:-}" ]]; then
        err "named-tunnel profile requires CLOUDFLARE_TUNNEL_TOKEN in .env"
        exit 1
      fi
      if [[ -z "${WEBHOOK_URL:-}" ]]; then
        err "named-tunnel profile requires WEBHOOK_URL in .env"
        exit 1
      fi
    fi
    ;;
esac

# Persist proxy hops + profile into .env so recreate picks them up
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

upsert_env "N8N_PROXY_HOPS" "$PROXY_HOPS_TARGET"
upsert_env "COMPOSE_PROFILES" "${COMPOSE_PROFILES}"

# Re-source after upserts
set -a
# shellcheck disable=SC1091
source .env
set +a
export COMPOSE_PROFILES

# Stop tunnel services that are not part of the selected profile so mode switches
# (e.g. tunnel → local) do not leave a public endpoint running.
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

log "Starting services (COMPOSE_PROFILES='${COMPOSE_PROFILES:-<none>}')..."
stop_unused_tunnels
docker compose up -d

wait_for_service_healthy() {
  local service="$1"
  local attempts="${2:-36}"
  local i id health
  for ((i = 1; i <= attempts; i++)); do
    id="$(docker compose ps -q "$service" 2>/dev/null || true)"
    if [[ -z "$id" ]]; then
      sleep 2
      continue
    fi
    health="$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id" 2>/dev/null || echo missing)"
    if [[ "$health" == "healthy" || "$health" == "running" ]]; then
      # Prefer healthy when a healthcheck exists; "running" means no healthcheck
      if [[ "$health" == "healthy" ]]; then
        return 0
      fi
      # If healthcheck exists, Status is starting/unhealthy/healthy — "running" only without health
      return 0
    fi
    if [[ "$health" == "starting" || "$health" == "unhealthy" ]]; then
      sleep 2
      continue
    fi
    sleep 2
  done
  err "Service '$service' did not become healthy in time. Try: docker compose logs $service"
  return 1
}

log "Waiting for n8n to become healthy..."
wait_for_service_healthy n8n 40

PUBLIC_URL=""

if [[ "${COMPOSE_PROFILES}" == "tunnel" ]]; then
  log "Requesting Cloudflare Quick Tunnel URL..."
  # Restart tunnel so we get a fresh URL and fresh log lines
  docker compose restart cloudflared >/dev/null 2>&1 || docker compose up -d cloudflared

  URL=""
  max_attempts=45
  for ((i = 1; i <= max_attempts; i++)); do
    # Prefer container-specific logs; widen window on later attempts
    since_arg="2m"
    if [[ $i -gt 15 ]]; then
      since_arg="10m"
    fi
    URL="$(
      docker compose logs --no-color --since "$since_arg" cloudflared 2>/dev/null \
        | grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' \
        | tail -n 1 || true
    )"
    if [[ -n "$URL" ]]; then
      break
    fi
    sleep 2
  done

  if [[ -z "$URL" ]]; then
    err "Failed to retrieve Cloudflare Tunnel URL."
    err "Check: docker compose logs cloudflared"
    exit 1
  fi

  # Normalize trailing slash for n8n WEBHOOK_URL
  PUBLIC_URL="${URL%/}/"
  log "Cloudflare Tunnel URL: $PUBLIC_URL"
  upsert_env "WEBHOOK_URL" "$PUBLIC_URL"

  log "Recreating n8n so WEBHOOK_URL / N8N_PROXY_HOPS take effect..."
  # CRITICAL: restart does NOT reload env from .env — force recreate
  docker compose up -d --force-recreate --no-deps n8n
  wait_for_service_healthy n8n 40

elif [[ "${COMPOSE_PROFILES}" == "named-tunnel" ]]; then
  PUBLIC_URL="${WEBHOOK_URL}"
  log "Named tunnel active. WEBHOOK_URL=${PUBLIC_URL}"
  log "Recreating n8n to ensure proxy / webhook env is applied..."
  docker compose up -d --force-recreate --no-deps n8n
  wait_for_service_healthy n8n 40

else
  log "Local-only mode: no public tunnel."
  # Clear stale public WEBHOOK_URL so n8n does not advertise a dead trycloudflare host
  if [[ -n "${WEBHOOK_URL:-}" ]]; then
    log "Clearing previous WEBHOOK_URL from .env (was set for tunnel mode)."
    upsert_env "WEBHOOK_URL" ""
    WEBHOOK_URL=""
  fi
  # Recreate so N8N_PROXY_HOPS=0 and empty WEBHOOK_URL are applied
  docker compose up -d --force-recreate --no-deps n8n
  wait_for_service_healthy n8n 40
fi

echo ""
echo "--------------------------------------------------"
echo " Status: n8n environment is active"
echo " Local UI:      http://localhost:${N8N_PORT}"
if [[ -n "$PUBLIC_URL" ]]; then
  echo " Public base:   ${PUBLIC_URL}"
  echo ""
  echo " SECURITY: Quick/named tunnel can expose the FULL n8n UI,"
  echo " not only webhooks. Set a strong owner password. Prefer"
  echo " path-restricted named tunnels for anything semi-real."
  echo " Do not leave this running unattended on untrusted networks."
else
  echo " Public base:   (none — local only)"
fi
echo " Stop:          ./stop.sh   or   docker compose down"
echo " Backup:        ./backup.sh"
echo "--------------------------------------------------"
