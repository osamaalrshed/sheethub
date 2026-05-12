# NocoDB Business Inputs POC

A self-contained Docker Compose stack that puts **NocoDB** (spreadsheet UI) on top of **PostgreSQL** (business data).

```
┌──────────────────────────────────────────────────────┐
│  Business User (browser)                             │
│       │   edits rows via NocoDB UI                  │
│       ▼                                              │
│  ┌──────────┐    reads/writes    ┌─────────────────┐ │
│  │  NocoDB  │◄──────────────────►│   PostgreSQL    │ │
│  │  :8080   │                    │  nocodb_meta    │ │
│  └──────────┘                    │  business_inputs│ │
│                                  │  ├─ finance.*   │ │
│                                  │  ├─ sales.*     │ │
│                                  │  └─ operations.*│ │
│                                  └─────────────────┘ │
└──────────────────────────────────────────────────────┘
```

> SQL Server sync is planned for a later phase. The `sync/` directory contains the ETL service code for when you're ready.


## Prerequisites

| Platform | Requirement |
|----------|-------------|
| Windows / macOS | [Docker Desktop](https://www.docker.com/products/docker-desktop/) ≥ 4.x |
| Linux | Docker Engine ≥ 24 + [Compose plugin](https://docs.docker.com/compose/install/linux/) |

For the setup script (local only — not needed inside Docker):

- Python 3.11+

> **Ports used:** 5432 (Postgres), 8080 (NocoDB).  
> To remap either port, set `POSTGRES_PORT` or `NOCODB_PORT` in your `.env`.


## Setup

### 1. Configure secrets

```bash
cp .env.example .env
```

Open `.env` and replace every `CHANGE_ME_*` value:

| Variable | Description |
|----------|-------------|
| `POSTGRES_SUPERUSER_PASSWORD` | PostgreSQL superuser password |
| `POSTGRES_NOCODB_PASSWORD` | NocoDB app user password |
| `ETL_READER_PASSWORD` | Read-only user password (for future sync) |
| `NC_AUTH_JWT_SECRET` | Random 32+ char string for JWT signing |
| `NC_ADMIN_EMAIL` | Admin login email for NocoDB |
| `NC_ADMIN_PASSWORD` | Admin password (8+ chars, uppercase, number, special) |
| `TEST_USER_PASSWORD` | Shared password for the three test users |

Generate a JWT secret:
```bash
python -c "import secrets; print(secrets.token_hex(32))"
```

### 2. Start the stack

```bash
docker compose up -d
```

Check status:
```bash
docker compose ps
docker compose logs -f nocodb   # watch NocoDB startup (~30s)
```

Both services should show `healthy` before proceeding.

### 3. Run the workspace setup script

```bash
cd setup
pip install -r requirements.txt
python setup_nocodb.py
```

The script:
- Signs in to NocoDB with your admin credentials
- Creates three bases: **Finance**, **Sales**, **Operations** — each connected to the matching PostgreSQL schema
- Creates test users and assigns them as Editor on their respective base

> If base creation fails via API, the script prints step-by-step manual instructions for the NocoDB UI.


## Access

| Service | URL | Credentials |
|---------|-----|-------------|
| NocoDB (admin) | http://localhost:8080 | `NC_ADMIN_EMAIL` / `NC_ADMIN_PASSWORD` from `.env` |
| NocoDB — Finance | http://localhost:8080 | `finance@test.local` / `TEST_USER_PASSWORD` |
| NocoDB — Sales | http://localhost:8080 | `sales@test.local` / `TEST_USER_PASSWORD` |
| NocoDB — Operations | http://localhost:8080 | `ops@test.local` / `TEST_USER_PASSWORD` |
| PostgreSQL | `localhost:5432` | `postgres` / `POSTGRES_SUPERUSER_PASSWORD` |


## Verify the data

Connect to PostgreSQL and inspect the sample data:

```bash
docker compose exec postgres psql -U postgres -d business_inputs \
  -c "\dt finance.*" \
  -c "\dt sales.*" \
  -c "\dt operations.*"
```

Or query a specific table:

```bash
docker compose exec postgres psql -U postgres -d business_inputs \
  -c "SELECT * FROM finance.cost_centers;"
```


## Backup & Restore

### Run a backup

```bash
./scripts/backup.sh
```

Creates timestamped files in `./backups/`:
- `pg-nocodb_meta-<ts>.sql`
- `pg-business_inputs-<ts>.sql`

### Restore from backup

```bash
./scripts/restore.sh backups/pg-business_inputs-20240115-020000.sql
```

> Restoring `nocodb_meta` requires stopping NocoDB first — the script reminds you.

### Suggested daily cron (Linux/macOS)

```bash
crontab -e
# Add:
0 2 * * * /absolute/path/to/nocodb-poc/scripts/backup.sh >> /absolute/path/to/nocodb-poc/backups/backup.log 2>&1
```


## Manual base creation fallback

If `setup_nocodb.py` cannot create bases automatically via API:

1. Sign in at http://localhost:8080 as admin.
2. Click **New Base** → **Connect External Database**.
3. Fill in:
   - **Host**: `postgres` (NocoDB reaches Postgres by Docker service name)
   - **Port**: `5432`
   - **Database**: `business_inputs`
   - **Schema**: `finance` (repeat for `sales` and `operations`)
   - **User**: `nocodb_user`
   - **Password**: value of `POSTGRES_NOCODB_PASSWORD` from `.env`
4. Click **Test Connection**, then **Add Source**.
5. In each base → **Settings → Members**, invite the corresponding user as Editor:
   - Finance → `finance@test.local`
   - Sales → `sales@test.local`
   - Operations → `ops@test.local`


## Project structure

```
nocodb-poc/
├── docker-compose.yml           # postgres + nocodb
├── .env.example                 # copy to .env and fill secrets
├── .gitignore
├── postgres/
│   └── init/
│       ├── 01-create-databases.sh   # creates nocodb_meta + business_inputs
│       ├── 02-create-users.sh       # creates nocodb_user + etl_reader
│       └── 03-load-sample-data.sql  # 3 schemas, 6 tables, ~115 rows
├── setup/
│   ├── requirements.txt
│   └── setup_nocodb.py          # NocoDB API automation
├── sync/                        # SQL Server ETL — wired up in a later phase
│   ├── Dockerfile
│   ├── requirements.txt
│   └── sync.py
├── scripts/
│   ├── backup.sh
│   └── restore.sh
├── backups/                     # gitignored
└── README.md
```


## Moving to a Linux server

```bash
# 1. Install Docker + Compose plugin
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER   # log out and back in

# 2. Copy the project (including your .env)
scp -r ./nocodb-poc user@server:/opt/nocodb-poc

# 3. Fix script permissions (Git may strip the executable bit)
chmod +x /opt/nocodb-poc/postgres/init/*.sh /opt/nocodb-poc/scripts/*.sh

# 4. Start
cd /opt/nocodb-poc
docker compose up -d
```

**Gotchas:**

| Issue | Fix |
|-------|-----|
| NocoDB image tag `2026.05.0` not found | Use `latest` or check [Docker Hub tags](https://hub.docker.com/r/nocodb/nocodb/tags) |
| Port 5432 or 8080 already in use | Set `POSTGRES_PORT` / `NOCODB_PORT` in `.env` |
| `backups/` permission errors | `chmod 777 backups/` on the host |


## Useful commands

```bash
# Tail all logs
docker compose logs -f

# Inspect tables in business_inputs
docker compose exec postgres psql -U postgres -d business_inputs \
  -c "SELECT table_schema, table_name, (SELECT count(*) FROM information_schema.columns c WHERE c.table_schema=t.table_schema AND c.table_name=t.table_name) AS cols FROM information_schema.tables t WHERE table_schema NOT IN ('pg_catalog','information_schema','public') ORDER BY 1,2;"

# Stop everything (volumes preserved)
docker compose down

# Destroy everything including data volumes (⚠ irreversible)
docker compose down -v
```
