# n8n Local Boilerplate (+ Cloudflare Tunnel)

Practical boilerplate to run **n8n** locally with **Docker**, **PostgreSQL**, and optional **public HTTPS webhooks** via **Cloudflare Tunnel**.

| Mode | Command | Public URL |
|------|---------|------------|
| Quick Tunnel (default) | `./start.sh` or `./start.sh --tunnel` | Ephemeral `https://*.trycloudflare.com` |
| Local only | `./start.sh --local` | None (safest) |
| Named tunnel | `./start.sh --named` | Stable hostname you configure |

---

## What you get

- **n8n** (pinned image) with Postgres backend  
- **Automatic `WEBHOOK_URL` wiring** for Quick Tunnel (with correct container **recreate**, not a no-op restart)  
- **Healthchecks** so tunnel starts after n8n is ready  
- **Compose profiles** for local / quick tunnel / named tunnel  
- **`backup.sh` / `stop.sh`** for day-2 ops  
- Safer defaults: diagnostics off, execution pruning, proxy hops for tunnel mode  

---

## Prerequisites

| OS | Terminal |
|----|----------|
| **macOS** | Terminal / iTerm2 |
| **Linux** | Any shell |
| **Windows** | **Git Bash** (recommended) or **WSL** |

Also required:

- [Docker](https://docs.docker.com/get-docker/) with **Compose v2** (`docker compose`)
- For Quick Tunnel: outbound HTTPS access to Cloudflare

---

## Quick start

### 1. Configure environment

```bash
cp .env.example .env
```

Set strong secrets **before** storing real credentials in n8n:

```bash
# macOS / Linux / Git Bash
echo "POSTGRES_PASSWORD=$(openssl rand -hex 16)"
echo "N8N_ENCRYPTION_KEY=$(openssl rand -hex 32)"
```

Paste those values into `.env`.  
**Never commit `.env`.** Losing `N8N_ENCRYPTION_KEY` makes stored credentials unrecoverable.

### 2. Start

```bash
./start.sh
# or: bash start.sh
```

### 3. Open n8n

- **Local UI:** `http://localhost:5678` (or your `N8N_PORT`)
- **Public base (tunnel):** printed by `start.sh`

Create the owner account immediately with a strong password.

### 4. Stop

```bash
./stop.sh
# or: docker compose --profile tunnel --profile named-tunnel down
```

Data persists in Docker volumes until you run `./stop.sh --volumes`.

---

## Modes in detail

### Local only (no internet exposure)

```bash
./start.sh --local
```

Uses Postgres + n8n only. Best default when you do not need inbound webhooks.

### Quick Tunnel (ephemeral HTTPS)

```bash
./start.sh --tunnel
# or COMPOSE_PROFILES=tunnel in .env (default in .env.example)
```

`start.sh` will:

1. Start Postgres → wait healthy → start n8n → wait healthy → start `cloudflared`
2. Scrape `https://….trycloudflare.com` from tunnel logs  
3. Write `WEBHOOK_URL` into `.env`  
4. **`docker compose up -d --force-recreate --no-deps n8n`** so the new env is actually applied  

**Caveats:**

- URL **changes** when the tunnel container restarts (free Quick Tunnel behavior).
- Tunnel targets `http://n8n:5678` → the **entire n8n HTTP surface** is reachable (UI + API + webhooks), not webhook paths only.

### Named tunnel (stable hostname)

1. Create a tunnel in [Cloudflare Zero Trust](https://one.dash.cloudflare.com/) and copy the token.  
2. In `.env`:

```env
COMPOSE_PROFILES=named-tunnel
CLOUDFLARE_TUNNEL_TOKEN=eyJ...
WEBHOOK_URL=https://n8n-hooks.yourdomain.com/
```

3. Prefer locking the public hostname to webhook paths only (`/webhook/`, `/webhook-test/`, `/form/`, etc.) in Cloudflare.  
4. Run:

```bash
./start.sh --named
```

---

## Security notes (read this)

1. **Quick Tunnel is a lab tool**, not production hardening.  
2. Anyone with the public URL may reach the **full n8n UI** unless you restrict paths (named tunnel / reverse proxy).  
3. Always set a strong n8n owner password.  
4. Do not leave tunnel mode running unattended on untrusted networks.  
5. Keep `.env` private; it holds DB password and encryption key.  
6. Pin image tags in `.env` (`N8N_IMAGE`, `CLOUDFLARED_IMAGE`) for reproducible upgrades.

---

## Backup & restore

### Backup

With the stack running:

```bash
./backup.sh
```

Creates `backups/<timestamp>/` with:

- `n8n.pgdump` — Postgres custom-format dump  
- `n8n_data.tar.gz` — n8n binary/config volume (when present)  
- `meta.txt` — non-secret metadata  

**You must retain the same `N8N_ENCRYPTION_KEY`** to decrypt credentials after restore.

### Restore (overview)

```bash
# Start only Postgres if needed, then:
docker compose exec -T postgres pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists < backups/.../n8n.pgdump
```

Restore `n8n_data` by extracting the tarball into the named volume (advanced; prefer consistent encryption key + DB restore first).

---

## Day-2 commands

```bash
# Logs
docker compose --profile tunnel logs -f

# Logs for one service
docker compose logs -f n8n
docker compose logs -f cloudflared

# Apply .env changes to n8n (env is only reloaded on recreate)
docker compose up -d --force-recreate --no-deps n8n

# Upgrade images (after editing N8N_IMAGE / tags in .env)
docker compose pull
./start.sh
```

---

## Project layout

```text
.
├── docker-compose.yml   # postgres, n8n, cloudflared (+ named profile)
├── start.sh             # boot + tunnel URL + force-recreate n8n
├── stop.sh              # compose down (+ optional --volumes)
├── backup.sh            # pg_dump + n8n_data archive
├── .env.example         # template (safe to commit)
├── .env                 # local secrets (gitignored)
├── .gitignore
└── README.md
```

Persistence uses **Docker named volumes** (`postgres_data`, `n8n_data`), not a bind-mounted `data/` folder.

---

## FAQ

**Q: `Permission denied` on `./start.sh`?**  
A: `chmod +x start.sh stop.sh backup.sh` or run `bash start.sh`.

**Q: Why did the public webhook URL change?**  
A: Quick Tunnel issues a new random hostname on tunnel restart. Use a **named tunnel** for a stable URL.

**Q: Webhooks still show `localhost` in the n8n UI?**  
A: `WEBHOOK_URL` must be applied via **recreate** (handled by `start.sh`). Check `.env` and run `./start.sh --tunnel` again, or:

```bash
docker compose up -d --force-recreate --no-deps n8n
```

**Q: Windows without Git Bash?**  
A: Use Git Bash or WSL so bash scripts work.

**Q: How do I avoid public exposure entirely?**  
A: `./start.sh --local` or set `COMPOSE_PROFILES=` (empty) in `.env`.

**Q: Can I use this for production payments?**  
A: Not with Quick Tunnel alone. Use a stable host, path-restricted ingress, backups, pinned images, and proper access control.

---

## Changelog (hardening)

- Fix: apply `WEBHOOK_URL` with **force-recreate** (not `restart`)  
- Add: `.env` bootstrap, secret warnings, Docker Compose checks  
- Add: n8n healthcheck; tunnel waits for healthy n8n  
- Add: compose profiles `tunnel` / `named-tunnel`; `--local` / `--tunnel` / `--named`  
- Add: pinned image tags (overridable via `.env`)  
- Add: `.gitignore`, `stop.sh`, `backup.sh`, security + ops docs  
- Add: safer n8n defaults (diagnostics off, prune, proxy hops in tunnel mode)  
