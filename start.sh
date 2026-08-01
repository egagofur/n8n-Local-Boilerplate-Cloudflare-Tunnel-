#!/usr/bin/env bash
# Start n8n stack (Postgres + n8n + optional Cloudflare Tunnel).
# Usage:
#   ./start.sh              # respect COMPOSE_PROFILES in .env (default: tunnel)
#   ./start.sh --local      # postgres + n8n only (no public tunnel)
#   ./start.sh --tunnel     # Quick Tunnel + auto curl/sync webhook base
#   ./start.sh --named      # named tunnel (CLOUDFLARE_TUNNEL_TOKEN + WEBHOOK_URL)
#   ./start.sh --sync       # same as tunnel align; never restarts cloudflared
#   ./start.sh --no-watch   # do not start background tunnel↔n8n watcher
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

MODE="auto" # auto | local | tunnel | named
SYNC_ONLY=0
START_WATCH=1
WATCH_PID_FILE="${ROOT_DIR}/.tunnel-watch.pid"
WATCH_LOG_FILE="${ROOT_DIR}/.tunnel-watch.log"

usage() {
  cat <<'EOF'
Usage: ./start.sh [options]

  --local     Local only (no Cloudflare Tunnel; no public exposure)
  --tunnel    Quick Tunnel; curl live URL and auto-sync n8n if mismatch
  --named     Named tunnel (CLOUDFLARE_TUNNEL_TOKEN + WEBHOOK_URL in .env)
  --sync      Align n8n to current tunnel only (never restart cloudflared)
  --no-watch  Do not start background auto-sync watcher
  -h, --help  Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local) MODE="local"; shift ;;
    --tunnel) MODE="tunnel"; shift ;;
    --named) MODE="named"; shift ;;
    --sync) SYNC_ONLY=1; MODE="tunnel"; shift ;;
    --no-watch) START_WATCH=0; shift ;;
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
    if [[ -z "${CLOUDFLARE_TUNNEL_TOKEN:-}" || -z "${WEBHOOK_URL:-}" ]]; then
      err "named-tunnel requires CLOUDFLARE_TUNNEL_TOKEN and WEBHOOK_URL in .env"
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

scrape_current_tunnel_url() {
  local id
  id="$(cloudflared_id)"
  if [[ -z "$id" ]]; then
    printf ''
    return
  fi
  docker logs "$id" 2>&1 \
    | grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' \
    | tail -n 1 || true
}

# Live check: NXDOMAIN / dead Quick Tunnel hosts fail here.
curl_tunnel_ok() {
  local base="$1"
  local code
  if [[ -z "$base" ]]; then
    return 1
  fi
  base="${base%/}"
  code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 12 \
    "${base}/healthz" 2>/dev/null || echo 000)"
  # 200 = n8n healthz via tunnel. Some edge cases return 502 while DNS still works —
  # treat 2xx/3xx/401/403 as "host exists and tunnel is up".
  case "$code" in
    2*|3*|401|403) return 0 ;;
    *) return 1 ;;
  esac
}

# Resolve a tunnel URL that both appears in cloudflared logs AND answers over HTTPS.
resolve_live_tunnel_url() {
  local max_attempts="${1:-45}"
  local i url=""
  for ((i = 1; i <= max_attempts; i++)); do
    url="$(scrape_current_tunnel_url)"
    if [[ -n "$url" ]]; then
      if curl_tunnel_ok "$url"; then
        printf '%s' "$url"
        return 0
      fi
      # Stale hostname still sitting in logs (NXDOMAIN) — wait for a new one
      if [[ $((i % 5)) -eq 0 ]]; then
        warn "Tunnel host in logs is not reachable yet (or dead DNS): $url — retrying..."
      fi
    fi
    sleep 2
  done
  return 1
}

wait_for_service_healthy() {
  local service="$1"
  local attempts="${2:-40}"
  local i id health has_hc
  for ((i = 1; i <= attempts; i++)); do
    id="$(docker compose ps -q "$service" 2>/dev/null || true)"
    if [[ -z "$id" ]]; then
      sleep 2
      continue
    fi
    health="$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id" 2>/dev/null || echo missing)"
    has_hc="$(docker inspect --format='{{if .State.Health}}yes{{else}}no{{end}}' "$id" 2>/dev/null || echo no)"
    if [[ "$has_hc" == "yes" ]]; then
      [[ "$health" == "healthy" ]] && return 0
    else
      [[ "$health" == "running" ]] && return 0
    fi
    sleep 2
  done
  err "Service '$service' did not become healthy in time. Try: docker compose logs $service"
  return 1
}

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
    log "Verified n8n env webhook base: $got"
    return 0
  fi

  warn "n8n env mismatch (expected=$expected got=${got:-<empty>}) — auto-sync recreate..."
  set_webhook_url "$expected"
  recreate_n8n
  got="$(get_n8n_webhook_url)"
  if [[ "$got" != "$expected" ]]; then
    err "Still mismatched after recreate (n8n=${got:-<empty>})."
    return 1
  fi
  log "Verified n8n env webhook base after auto-sync: $got"
}

# Core: curl live tunnel, compare n8n, auto-sync if needed. Used by --tunnel and --sync.
align_tunnel_webhook() {
  local public_url current
  log "Resolving live Cloudflare Tunnel URL (log scrape + curl /healthz)..."
  if ! public_url="$(resolve_live_tunnel_url 45)"; then
    # One recovery path: restart tunnel once (new host), then align
    if [[ "$SYNC_ONLY" -eq 1 ]]; then
      err "No reachable trycloudflare URL (and --sync will not restart tunnel)."
      err "Run: ./start.sh --tunnel"
      return 1
    fi
    warn "No reachable tunnel URL — restarting cloudflared once..."
    docker compose restart cloudflared >/dev/null 2>&1 || docker compose up -d cloudflared
    sleep 3
    if ! public_url="$(resolve_live_tunnel_url 45)"; then
      err "Failed to get a reachable Cloudflare Tunnel URL."
      err "Check: docker compose logs cloudflared"
      return 1
    fi
  fi

  public_url="$(normalize_url "$public_url")"
  log "Live tunnel (curl OK): $public_url"

  current="$(get_n8n_webhook_url)"
  if [[ -n "$current" ]] && ! curl_tunnel_ok "$current"; then
    warn "n8n still points at dead host: $current"
  fi

  if [[ "$current" == "$public_url" ]]; then
    log "n8n already matches live tunnel — no recreate needed."
    set_webhook_url "$public_url" # keep .env in sync even if already applied
  else
    if [[ -n "$current" ]]; then
      log "Auto-sync: n8n=$current  →  tunnel=$public_url"
    else
      log "Auto-sync: applying tunnel URL to n8n (was empty)."
    fi
    set_webhook_url "$public_url"
    recreate_n8n
    # Tunnel must not have rotated during recreate
    local again
    again="$(scrape_current_tunnel_url)"
    if [[ -n "$again" && "$(normalize_url "$again")" != "$public_url" ]]; then
      if curl_tunnel_ok "$again"; then
        warn "Tunnel rotated during recreate → $(normalize_url "$again") — syncing again."
        public_url="$(normalize_url "$again")"
        set_webhook_url "$public_url"
        recreate_n8n
      fi
    fi
  fi

  verify_n8n_webhook_url "$public_url"
  if ! curl_tunnel_ok "$public_url"; then
    err "Post-sync curl failed for $public_url"
    return 1
  fi
  log "Curl check OK: ${public_url}healthz"
  PUBLIC_URL="$public_url"
  return 0
}

stop_tunnel_watch() {
  if [[ -f "$WATCH_PID_FILE" ]]; then
    local pid
    pid="$(cat "$WATCH_PID_FILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      log "Stopped tunnel watcher (pid $pid)."
    fi
    rm -f "$WATCH_PID_FILE"
  fi
}

# Background loop: only run full --sync when live tunnel host ≠ n8n (or n8n host is dead).
start_tunnel_watch() {
  if [[ "$START_WATCH" -ne 1 ]]; then
    return 0
  fi
  stop_tunnel_watch

  nohup bash -c '
    set +e
    cd "'"$ROOT_DIR"'" || exit 0
    LOG="'"$WATCH_LOG_FILE"'"
    normalize() { local u="${1:-}"; [ -z "$u" ] && { printf ""; return; }; printf "%s" "${u%/}/"; }
    scrape() {
      id=$(docker compose ps -q cloudflared 2>/dev/null) || true
      [ -z "$id" ] && { printf ""; return; }
      docker logs "$id" 2>&1 | grep -oE "https://[a-zA-Z0-9-]+\.trycloudflare\.com" | tail -n 1
    }
    n8n_url() {
      id=$(docker compose ps -q n8n 2>/dev/null) || true
      [ -z "$id" ] && { printf ""; return; }
      got=$(docker exec "$id" printenv N8N_WEBHOOK_URL 2>/dev/null || true)
      [ -z "$got" ] && got=$(docker exec "$id" printenv WEBHOOK_URL 2>/dev/null || true)
      normalize "$got"
    }
    curl_ok() {
      base="${1%/}"
      [ -z "$base" ] && return 1
      code=$(curl -sS -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 12 "${base}/healthz" 2>/dev/null || echo 000)
      case "$code" in 2*|3*|401|403) return 0 ;; *) return 1 ;; esac
    }
    while true; do
      sleep 30
      cf=$(docker compose ps -q cloudflared 2>/dev/null) || true
      n8=$(docker compose ps -q n8n 2>/dev/null) || true
      [ -z "$cf" ] || [ -z "$n8" ] && continue
      live=$(normalize "$(scrape)")
      cur=$(n8n_url)
      need=0
      if [ -n "$live" ] && curl_ok "$live"; then
        if [ "$cur" != "$live" ]; then need=1; fi
      fi
      if [ -n "$cur" ] && ! curl_ok "$cur"; then need=1; fi
      if [ "$need" -eq 1 ]; then
        echo "[$(date -Iseconds)] drift detected live=${live:-?} n8n=${cur:-?} → auto --sync" >>"$LOG"
        ./start.sh --sync --no-watch >>"$LOG" 2>&1 || echo "[$(date -Iseconds)] auto-sync failed" >>"$LOG"
      fi
    done
  ' >/dev/null 2>&1 &
  echo $! >"$WATCH_PID_FILE"
  log "Background tunnel watcher started (pid $(cat "$WATCH_PID_FILE"); checks ~30s; log: .tunnel-watch.log)"
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
      stop_tunnel_watch
      ;;
  esac
}

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
      docker compose up -d --no-recreate cloudflared >/dev/null 2>&1 || true
    else
      log "Starting cloudflared Quick Tunnel..."
      docker compose up -d cloudflared
    fi
  fi

  # --tunnel and --sync share the same curl → match → auto-sync path
  align_tunnel_webhook

  # Keep a lightweight watcher so tunnel rotation self-heals without manual --sync
  if [[ "$START_WATCH" -eq 1 ]]; then
    start_tunnel_watch
  fi

  echo ""
  warn "Re-register external webhooks (WhatsApp / Midtrans / Telegram) if the host changed."
  warn "Path stays the same (e.g. /webhook/wa-service); only the host changes on Quick Tunnel."
  warn "Stable host: ./start.sh --named"

elif [[ "${COMPOSE_PROFILES}" == "named-tunnel" ]]; then
  stop_tunnel_watch
  docker compose up -d cloudflared-named
  PUBLIC_URL="$(normalize_url "${WEBHOOK_URL}")"
  log "Named tunnel active. WEBHOOK_URL=${PUBLIC_URL}"
  set_webhook_url "$PUBLIC_URL"
  recreate_n8n
  verify_n8n_webhook_url "$PUBLIC_URL"

else
  stop_tunnel_watch
  log "Local-only mode: no public tunnel."
  set_webhook_url ""
  recreate_n8n
fi

echo ""
echo "--------------------------------------------------"
echo " Status: n8n environment is active"
echo " Local UI:      http://localhost:${N8N_PORT}"
if [[ -n "${PUBLIC_URL:-}" ]]; then
  echo " Public base:   ${PUBLIC_URL}"
  echo " n8n webhook:   $(get_n8n_webhook_url)"
  echo " Example:       ${PUBLIC_URL}webhook/wa-service"
  if curl_tunnel_ok "$PUBLIC_URL"; then
    echo " Curl /healthz: OK"
  else
    echo " Curl /healthz: FAIL (check tunnel)"
  fi
  echo ""
  echo " SECURITY: tunnel may expose the FULL n8n UI. Use a strong owner password."
  if [[ -f "$WATCH_PID_FILE" ]] && kill -0 "$(cat "$WATCH_PID_FILE" 2>/dev/null)" 2>/dev/null; then
    echo " Auto-sync:     on (watcher every ~30s)"
  fi
else
  echo " Public base:   (none — local only)"
fi
echo " Stop:          ./stop.sh"
echo " Backup:        ./backup.sh"
echo " Manual sync:   ./start.sh --sync"
echo "--------------------------------------------------"
