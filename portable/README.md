# SheetsHub — Portable Stack (No Docker, No Admin)

Self-contained Windows version of the NocoDB POC that runs as **regular user processes**.
No installer, no admin rights, no Docker required.

## What you'll get
- PostgreSQL (data store)
- NocoDB (UI on `http://localhost:8181` proxied through nginx)
- nginx (CSS/JS customizations, single URL entry point)
- Python sync-service (Postgres → ClickHouse hourly)

All running from this `portable/` folder. Closing the start window stops everything.

---

## One-time setup

### 1. Download the four binaries

| Tool | Download | Extract to |
|---|---|---|
| **PostgreSQL** | [EnterpriseDB binaries](https://www.enterprisedb.com/download-postgresql-binaries) — pick "Windows x86-64" zip | `portable/_bin/postgres/` (so `_bin/postgres/bin/postgres.exe` exists) |
| **nginx** | https://nginx.org/en/download.html — "nginx/Windows-1.x.x" zip | `portable/_bin/nginx/` (so `_bin/nginx/nginx.exe` exists) |
| **NocoDB** | https://github.com/nocodb/nocodb/releases — `Noco-win-arm64.exe` or `Noco-win-x64.exe` | Rename to `Noco.exe`, place at `portable/_bin/nocodb/Noco.exe` |
| **Python 3.12 embeddable** | https://www.python.org/downloads/windows/ — "Windows embeddable package (64-bit)" zip | `portable/_bin/python/` (so `_bin/python/python.exe` exists) |

> Folder structure after extracting:
> ```
> portable/
> ├── _bin/
> │   ├── postgres/bin/postgres.exe
> │   ├── nginx/nginx.exe
> │   ├── nocodb/Noco.exe
> │   └── python/python.exe
> ├── start.bat
> ├── stop.bat
> └── ...
> ```

### 2. Enable pip in embeddable Python

Open `portable/_bin/python/python312._pth` in a text editor and uncomment the line `#import site`.
Then in cmd, from that folder:
```cmd
curl -O https://bootstrap.pypa.io/get-pip.py
python.exe get-pip.py
python.exe -m pip install -r ..\..\sync\requirements.txt
```

### 3. Copy `.env.example` to `.env` and fill in the secrets

```cmd
copy .env.example .env
```

Edit `.env` and replace the `CHANGE_ME_*` values.

### 4. Initialize PostgreSQL (one time)

```cmd
init-postgres.bat
```

Creates the data folder, sets up databases, applies the init scripts.

---

## Daily use

**Start everything:**
```cmd
start.bat
```
Opens four small windows — one per service. Leave them running.

**Open the app:** http://localhost:8181

**Stop everything:**
```cmd
stop.bat
```
or close all four windows.

---

## Differences from the Docker version

| Aspect | Docker | Portable |
|---|---|---|
| Networking | container names (`postgres`, `nocodb`) | all on `127.0.0.1` |
| PostgreSQL port | host 5433 → container 5432 | direct `5432` |
| Sync service ClickHouse host | `host.docker.internal` | `localhost` |
| Logs | `docker compose logs` | each service has its own window |
| Storage | Docker volumes | `portable/data/` folder |

Everything else (CSS hides, JS detection, audit triggers, sync logic) is byte-for-byte the same files as the Docker version.
