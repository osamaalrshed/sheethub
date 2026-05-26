# Production Deployment Guide

This walks through deploying SheetsHub to a Linux server. Tested with
Ubuntu 22.04 / 24.04, but anything with Docker Engine + Compose works.

---

## 1. Prepare the server

Sized for ~500 users editing intermittently:

| Resource | Minimum | Recommended |
|---|---|---|
| CPU | 2 vCPU | 4 vCPU |
| RAM | 4 GB | 8 GB |
| Disk | 20 GB SSD | 50 GB SSD |

Install Docker and Compose plugin:

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
# log out and back in for the group change to apply
docker --version && docker compose version
```

---

## 2. Get the code

```bash
sudo mkdir -p /opt/sheethub
sudo chown $USER:$USER /opt/sheethub
cd /opt/sheethub
git clone https://github.com/osamaalrshed/sheethub.git .
```

---

## 3. Configure secrets

```bash
cp .env.example .env
# Generate a strong JWT secret
echo "NC_AUTH_JWT_SECRET=$(openssl rand -hex 32)" >> .env.notes
# Generate strong passwords
echo "POSTGRES_SUPERUSER_PASSWORD=$(openssl rand -hex 16)" >> .env.notes
echo "POSTGRES_NOCODB_PASSWORD=$(openssl rand -hex 16)" >> .env.notes
# (then copy values from .env.notes into .env and rm .env.notes)
```

Fields you MUST set:

| Field | Notes |
|---|---|
| `POSTGRES_SUPERUSER_PASSWORD` | Strong (32+ chars). Rotated rarely. |
| `POSTGRES_NOCODB_PASSWORD`   | Used by NocoDB + sync. |
| `ETL_READER_PASSWORD`        | For BI tools / external read-only access. |
| `NC_AUTH_JWT_SECRET`         | Random 32+ chars. Treat like a session key. |
| `NC_ADMIN_EMAIL`             | Your real admin email — used by the JS admin detector. |
| `NC_ADMIN_PASSWORD`          | Strong. 8+ chars, uppercase, number, special. |
| `NC_PUBLIC_URL`              | Public URL users access. **No trailing slash.** |
| `CH_HOST`                    | ClickHouse hostname/IP your sync service can reach. |
| `CH_USER`, `CH_PASSWORD`, `CH_DATABASE` | ClickHouse credentials. |

Update `nginx/admin-detector.js` if your admin email differs from
`admin@nocodb.local`:

```js
const ADMIN_EMAILS = ['admin@yourcompany.com'];   // ← edit this
```

---

## 4. First startup

```bash
docker compose up -d
docker compose ps                 # all services should be "healthy" or "running"
docker compose logs -f nocodb     # wait for "Server started" (~30s)
```

Open `${NC_PUBLIC_URL}` and sign in with `NC_ADMIN_EMAIL` /
`NC_ADMIN_PASSWORD`.

---

## 5. Set up workspaces (one-time)

```bash
cd setup
pip3 install -r requirements.txt   # or: python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt
python3 setup_nocodb.py
```

This creates three test users (`finance@`, `sales@`, `ops@`) as Editor on
the base. Adjust `setup_nocodb.py` for real production users, or use the
NocoDB UI directly under **Team & Settings → Members**.

---

## 6. Expose the service publicly

You have three options:

### Option A — direct on port 80 (simplest, no SSL)

Edit `docker-compose.yml`:
```yaml
nginx:
  ports:
    - "80:80"   # was: "${NOCODB_PORT:-8080}:80"
```

### Option B — behind a reverse proxy you already run (Caddy, Traefik, etc.)

Keep the internal port (e.g. `8080:80`) and route from your existing proxy.
Update `NC_PUBLIC_URL=https://sheetshub.yourcompany.com` to match.

### Option C — TLS via Caddy (recommended for new servers)

Add a Caddy service to a `docker-compose.tls.yml`:

```yaml
services:
  caddy:
    image: caddy:2-alpine
    restart: unless-stopped
    ports: ["80:80", "443:443"]
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
    networks: [sheetshub-net]

volumes:
  caddy_data:
```

And `Caddyfile`:
```
sheetshub.yourcompany.com {
    reverse_proxy nginx:80
}
```

Then: `docker compose -f docker-compose.yml -f docker-compose.tls.yml up -d`.

---

## 7. Operational tasks

### Daily backups (recommended)

```bash
crontab -e
# Add:
0 2 * * * /opt/sheethub/scripts/backup.sh >> /opt/sheethub/backups/backup.log 2>&1
```

Keep at least 7 days. Periodically test a restore.

### Updating NocoDB

Pinning to `2026.05.0` means our customizations don't break. **Don't update
unless a security advisory or critical bug fix forces it.** See
[CUSTOMIZATIONS.md](CUSTOMIZATIONS.md#update-strategy) for the procedure.

### Monitoring

Quick health check (cron every minute):
```bash
curl -sf http://localhost:8080/api/v1/health || echo "NocoDB down" | mail -s "alert" you@example.com
```

For real monitoring, expose container metrics to Prometheus (each service
exposes basic logs via `docker compose logs`).

### Resource usage

Typical idle: 1-2 GB RAM total. Sync runs cost negligibly extra. Disk grows
mostly with audit log — prune old `audit.change_log` rows after ClickHouse
has confirmed them if disk pressure builds:

```sql
DELETE FROM audit.change_log WHERE changed_at < now() - interval '90 days';
```

---

## 8. Connecting ClickHouse

The sync service connects to ClickHouse using the `CH_*` env vars. Three
common deployment patterns:

| ClickHouse location | Set `CH_HOST` to | extra_hosts in compose |
|---|---|---|
| Separate container in same compose | Service name (e.g. `clickhouse`) | not needed |
| Separate VM/server on private network | Internal hostname or IP | not needed |
| Same host as Docker (rare) | `host.docker.internal` | uncomment in `docker-compose.yml` |
| Managed cloud (ClickHouse Cloud) | The provided endpoint | not needed; set `CH_PORT=8443` (HTTPS) |

---

## 9. Firewall

Open only:
- `80`/`443` if internet-facing
- `5432` ONLY if external tools (BI, analytics) need direct read access (use `etl_reader` for these)

Do not expose Postgres to the internet — always behind a VPN or private network.

---

## 10. Troubleshooting

| Symptom | Fix |
|---|---|
| `permission denied for schema public` | PostgreSQL 15+ requires explicit grant. See `postgres/init/02-create-users.sh` — it handles this. |
| `Forbidden host name or IP address` from NocoDB | NocoDB's SSRF block. Our compose uses subnet `100.64.0.0/24` to avoid it; don't change. |
| Login works but UI is broken | Hard-refresh (Ctrl+Shift+R). The `admin-detector.js` runs once per page load. |
| Admin sees the restricted UI | Edit `ADMIN_EMAILS` in `nginx/admin-detector.js`, restart nginx. |
| Sync logs show "permission denied for schema analytics" | Run: `GRANT CREATE ON SCHEMA analytics TO nocodb_user;` |
| ClickHouse connection refused | `CH_HOST` unreachable from inside the sync container. Test with `docker compose exec sync python -c "import socket; socket.create_connection(('$CH_HOST', $CH_PORT), 5)"`. |

---

## 11. Going further

- **HA**: replicate PostgreSQL with Patroni or use a managed PG (RDS/CloudSQL/etc.)
- **Real-time sync**: switch to `docker-compose.dev.yml` to add the 2-second polling sync (not recommended for prod)
- **Custom roles**: NocoDB Enterprise has proper per-column permissions; current free-tier setup uses CSS hides

See [CUSTOMIZATIONS.md](CUSTOMIZATIONS.md) for the full reference of what's
been customized and why.
