# n8n Local Boilerplate

Run **n8n** on your machine with **Docker**, **Postgres**, and optional **public HTTPS webhooks** (Cloudflare Tunnel).

**Need:** [Docker](https://docs.docker.com/get-docker/) (Compose v2) · macOS / Linux / Windows (Git Bash or WSL)

---

## Quick start

```bash
cp .env.example .env
```

Set secrets in `.env` (recommended before real use):

```bash
openssl rand -hex 16   # → POSTGRES_PASSWORD
openssl rand -hex 32   # → N8N_ENCRYPTION_KEY
```

```bash
./start.sh             # default: Quick Tunnel (public webhooks)
# bash start.sh        # if ./ is blocked
```

| | |
|--|--|
| **UI** | http://localhost:5678 |
| **Public URL** | printed by `start.sh` |
| **Stop** | `./stop.sh` |
| **Backup** | `./backup.sh` |

Create a strong owner password on first open. Never commit `.env`. If you lose `N8N_ENCRYPTION_KEY`, saved credentials cannot be decrypted.

---

## Modes

| Goal | Command |
|------|---------|
| Public webhooks (random URL) | `./start.sh` or `./start.sh --tunnel` |
| Local only (no public access) | `./start.sh --local` |
| Stable custom domain | `./start.sh --named` *(see below)* |

**Local** — safest. Postgres + n8n only.

**Quick Tunnel** — free HTTPS (`*.trycloudflare.com`). URL **changes** on every tunnel restart. The tunnel exposes **all of n8n** (UI + API + webhooks), not just webhooks.

**Named tunnel** — stable hostname:

1. Create a tunnel in [Cloudflare Zero Trust](https://one.dash.cloudflare.com/) and copy the token  
2. In `.env`:

```env
COMPOSE_PROFILES=named-tunnel
CLOUDFLARE_TUNNEL_TOKEN=eyJ...
WEBHOOK_URL=https://n8n-hooks.yourdomain.com/
```

3. Prefer restricting the hostname to `/webhook/`, `/webhook-test/`, `/form/`  
4. Run `./start.sh --named`

---

## Everyday commands

```bash
./start.sh --local              # start without tunnel
./stop.sh                       # stop (keeps data)
./stop.sh --volumes             # stop + delete data (careful)
./backup.sh                     # dump DB + n8n volume → backups/

docker compose logs -f n8n      # logs
docker compose logs -f cloudflared

# After editing .env, reload n8n env vars:
docker compose up -d --force-recreate --no-deps n8n
```

---

## Security (short)

- Quick Tunnel = **lab tool**, not production  
- Public URL can reach the **full UI** — use a strong owner password  
- Don’t leave tunnel mode open unattended on untrusted networks  
- Keep `.env` private  

---

## Backup

With the stack running:

```bash
./backup.sh
```

Creates `backups/<timestamp>/` (`n8n.pgdump`, `n8n_data.tar.gz`). Keep the same `N8N_ENCRYPTION_KEY` to restore credentials.

DB restore sketch:

```bash
docker compose exec -T postgres pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  --clean --if-exists < backups/.../n8n.pgdump
```

---

## FAQ

| Problem | Fix |
|---------|-----|
| `Permission denied` | `chmod +x start.sh stop.sh backup.sh` or `bash start.sh` |
| Webhook URL changed | Normal for Quick Tunnel → use `--named` for a stable URL |
| Webhooks still show localhost | Run `./start.sh --tunnel` again (it recreates n8n) |
| No public exposure | `./start.sh --local` |
| Windows scripts fail | Use Git Bash or WSL |

---

## Files

```text
docker-compose.yml   postgres · n8n · cloudflared
start.sh / stop.sh / backup.sh
.env.example         template (safe to commit)
.env                 secrets (gitignored)
```

Data lives in Docker volumes (`postgres_data`, `n8n_data`), not a local `data/` folder.
