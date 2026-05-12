#!/usr/bin/env bash
# Backup script for the NocoDB POC stack.
#
# Backs up:
#   - PostgreSQL:  nocodb_meta     →  backups/pg-nocodb_meta-<ts>.sql
#   - PostgreSQL:  business_inputs →  backups/pg-business_inputs-<ts>.sql
#
# Usage:
#   ./scripts/backup.sh
#
# Prerequisites:
#   - Docker Compose stack is running.
#   - Run from the project root (where docker-compose.yml lives).
#
# Daily cron (Linux/macOS) — add with: crontab -e
#   0 2 * * * /path/to/nocodb-poc/scripts/backup.sh >> /path/to/nocodb-poc/backups/backup.log 2>&1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BACKUP_DIR="${PROJECT_ROOT}/backups"
TS="$(date -u +%Y%m%d-%H%M%S)"

# Load .env so we have PG credentials
# shellcheck disable=SC1091
if [ -f "${PROJECT_ROOT}/.env" ]; then
  set -a
  source "${PROJECT_ROOT}/.env"
  set +a
fi

POSTGRES_SUPERUSER="${POSTGRES_SUPERUSER:-postgres}"

mkdir -p "${BACKUP_DIR}"

echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] Starting backup…"

# ── PostgreSQL: nocodb_meta ───────────────────────────────────────────────────
PG_META_FILE="${BACKUP_DIR}/pg-nocodb_meta-${TS}.sql"
echo "  Dumping PostgreSQL nocodb_meta → $(basename "${PG_META_FILE}")"
docker compose -f "${PROJECT_ROOT}/docker-compose.yml" exec -T postgres \
  pg_dump -U "${POSTGRES_SUPERUSER}" -d nocodb_meta \
  > "${PG_META_FILE}"
echo "  OK  ($(wc -c < "${PG_META_FILE}") bytes)"

# ── PostgreSQL: business_inputs ───────────────────────────────────────────────
PG_DATA_FILE="${BACKUP_DIR}/pg-business_inputs-${TS}.sql"
echo "  Dumping PostgreSQL business_inputs → $(basename "${PG_DATA_FILE}")"
docker compose -f "${PROJECT_ROOT}/docker-compose.yml" exec -T postgres \
  pg_dump -U "${POSTGRES_SUPERUSER}" -d business_inputs \
  > "${PG_DATA_FILE}"
echo "  OK  ($(wc -c < "${PG_DATA_FILE}") bytes)"

echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] Backup complete."
echo "  Files in ${BACKUP_DIR}:"
ls -lh "${BACKUP_DIR}"/ | grep "${TS}" || true
