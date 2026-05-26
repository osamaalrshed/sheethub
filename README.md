# SheetsHub

A Dockerized business-data platform: business users edit data in a spreadsheet
UI ([NocoDB](https://github.com/nocodb/nocodb)) backed by PostgreSQL, with
every change auto-synced to ClickHouse every 30 minutes for analytics.

```
┌──────────────────────────────────────────────────────────────────┐
│ Business user (browser)         http://<your-host>:8080          │
└──────────────────────┬───────────────────────────────────────────┘
                       ▼
              ┌──────────────────┐
              │  nginx           │  CSS + JS overlay (SheetsHub
              │  reverse proxy   │  branding, hide admin UI from
              └────────┬─────────┘  business users, block public
                       │            share URLs)
                       ▼
              ┌──────────────────┐
              │  NocoDB          │  Pinned 2026.05.0
              └────────┬─────────┘
                       │
                       ▼
              ┌──────────────────┐
              │  PostgreSQL 16   │  Operational store
              │                  │   - nocodb_meta
              │                  │   - business_inputs
              │                  │       (finance / sales / operations)
              │                  │   - audit.change_log
              └────────┬─────────┘
                       │  every 30 min, only changed tables
                       ▼
              ┌──────────────────┐
              │  ClickHouse      │  Analytics store
              └──────────────────┘  (external — outside this compose)
```

---

## Prerequisites

| Platform | Requirement |
|---|---|
| Windows / macOS | [Docker Desktop](https://www.docker.com/products/docker-desktop/) ≥ 4.x |
| Linux server    | Docker Engine ≥ 24 + [Compose plugin](https://docs.docker.com/compose/install/linux/) |

External: a ClickHouse instance the sync service can reach (or skip if you
don't need analytics sync yet — the rest of the stack works without it).

---

## Quick start

```bash
git clone https://github.com/osamaalrshed/sheethub.git
cd sheethub
cp .env.example .env
# edit .env — replace every CHANGE_ME_ value
docker compose up -d
```

NocoDB will be ready in ~30 seconds at `http://localhost:8080`. Sign in with
the admin credentials from `.env`.

---

## What runs

| Service | Container | Port | Purpose |
|---|---|---|---|
| `postgres`  | `sheetshub-postgres` | `5432`* | Operational DB + NocoDB metadata + audit log |
| `nocodb`    | `sheetshub-nocodb`   | internal `8080` | Spreadsheet UI |
| `nginx`     | `sheetshub-nginx`    | `8080`* | Reverse proxy + UI overlay |
| `sync`      | `sheetshub-sync`     | — | Postgres → ClickHouse, every 30 min |

\* Configurable via `POSTGRES_PORT` and `NOCODB_PORT` in `.env`.

---

## How it works end-to-end

1. **A user edits a row** in NocoDB through the browser
2. **NocoDB writes to PostgreSQL** (data lives in `business_inputs.{finance,sales,operations}.*`)
3. **PostgreSQL triggers** capture the change in `audit.change_log` (`old_data`, `new_data`, `action`, `changed_at`)
4. **Every 30 minutes**, the `sync` service polls `audit.change_log` per table — if there's been any activity since last sync, it drops and reloads the matching ClickHouse table; otherwise skips
5. **Analytics queries** run against ClickHouse, never against the operational PostgreSQL

The 30-minute interval is set in [`sync-service/config.yaml`](sync-service/config.yaml). Change it and restart the `sync` container.

---

## Project layout

```
sheethub/
├── docker-compose.yml          ← production stack (postgres, nocodb, nginx, sync)
├── docker-compose.dev.yml      ← optional dev-only services (realtime PG→PG sync)
├── .env.example                ← copy to .env, fill in secrets
├── README.md                   ← you are here
├── DEPLOYMENT.md               ← production deployment guide
├── CUSTOMIZATIONS.md           ← reference of every UI/data customization
│
├── nginx/
│   ├── nocodb.conf             ← reverse-proxy config
│   ├── custom.css              ← UI hides (scoped to body:not(.is-admin))
│   └── admin-detector.js       ← admin detection + SheetsHub logo replacement
│
├── postgres/init/              ← runs on first DB startup
│   ├── 01-create-databases.sh
│   ├── 02-create-users.sh
│   ├── 03-load-sample-data.sql
│   ├── 04-audit.sql            ← audit.change_log + triggers
│   └── 05-analytics-schema.sql ← analytics schema (used by dev realtime-sync)
│
├── setup/                      ← one-time NocoDB workspace setup (Python)
│   ├── requirements.txt
│   └── setup_nocodb.py
│
├── sync-service/               ← production sync (Postgres → ClickHouse, 30 min)
│   ├── Dockerfile
│   ├── requirements.txt
│   ├── config.yaml
│   └── sync.py
│
├── realtime-sync/              ← dev tool — 2-second PG → PG incremental sync
│   ├── Dockerfile              ← same shape as sync-service
│   ├── requirements.txt
│   ├── config.yaml
│   ├── sync.py
│   └── README.md
│
├── scripts/
│   ├── backup.sh
│   └── restore.sh
│
└── portable/                   ← optional: run the stack without Docker
    ├── README.md               ← how to run it on Windows with downloaded binaries
    └── ...
```

---

## Common operations

```bash
# Start
docker compose up -d

# Stop (preserve data)
docker compose down

# View logs (all services)
docker compose logs -f

# View logs for one service
docker compose logs -f sync

# Force a manual sync run (don't wait for the 30-minute timer)
docker compose exec sync python sync.py --once

# Connect to PostgreSQL
docker compose exec postgres psql -U postgres -d business_inputs

# Inspect audit log
docker compose exec postgres psql -U postgres -d business_inputs -c \
  "SELECT changed_at, action, table_schema, table_name FROM audit.change_log ORDER BY id DESC LIMIT 10;"

# Wipe everything including data volumes (irreversible)
docker compose down -v
```

---

## Backups

```bash
# Run a backup (creates timestamped SQL dumps in ./backups/)
./scripts/backup.sh

# Restore from backup
./scripts/restore.sh backups/pg-business_inputs-20260514-020000.sql

# Schedule daily backups via cron
crontab -e
# 0 2 * * * /opt/sheethub/scripts/backup.sh >> /opt/sheethub/backups/backup.log 2>&1
```

---

## Next steps

| If you want to … | Read |
|---|---|
| Deploy to a server | [DEPLOYMENT.md](DEPLOYMENT.md) |
| Understand every UI/data customization | [CUSTOMIZATIONS.md](CUSTOMIZATIONS.md) |
| Demo near-real-time PG → PG replication | [realtime-sync/README.md](realtime-sync/README.md) |
| Run without Docker (no admin needed) | [portable/README.md](portable/README.md) |
