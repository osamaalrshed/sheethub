#!/usr/bin/env bash
# Restore script for the NocoDB POC stack.
#
# Detects the target database from the filename convention:
#   pg-nocodb_meta-<ts>.sql        → PostgreSQL nocodb_meta
#   pg-business_inputs-<ts>.sql   → PostgreSQL business_inputs
#
# Usage:
#   ./scripts/restore.sh backups/pg-business_inputs-20240115-020000.sql
#
# WARNING: This drops and recreates the target database. All current data is lost.
#          Before restoring nocodb_meta, stop NocoDB first:
#            docker compose stop nocodb
#          Restart it after:
#            docker compose start nocodb

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ $# -ne 1 ]; then
  echo "Usage: $0 <backup_file>"
  exit 1
fi

BACKUP_FILE="$1"

# Resolve to absolute path
if [[ "${BACKUP_FILE}" != /* ]]; then
  BACKUP_FILE="${PROJECT_ROOT}/${BACKUP_FILE}"
fi

if [ ! -f "${BACKUP_FILE}" ]; then
  echo "[ERROR] File not found: ${BACKUP_FILE}"
  exit 1
fi

# Load .env
# shellcheck disable=SC1091
if [ -f "${PROJECT_ROOT}/.env" ]; then
  set -a
  source "${PROJECT_ROOT}/.env"
  set +a
fi

POSTGRES_SUPERUSER="${POSTGRES_SUPERUSER:-postgres}"
BASENAME="$(basename "${BACKUP_FILE}")"

echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] Restoring ${BASENAME}…"

if [[ "${BASENAME}" == pg-nocodb_meta-*.sql ]]; then
  TARGET_DB="nocodb_meta"
elif [[ "${BASENAME}" == pg-business_inputs-*.sql ]]; then
  TARGET_DB="business_inputs"
else
  echo "[ERROR] Unrecognised filename pattern: ${BASENAME}"
  echo "        Expected: pg-nocodb_meta-<ts>.sql  or  pg-business_inputs-<ts>.sql"
  exit 1
fi

echo "  Target: PostgreSQL → ${TARGET_DB}"
if [[ "${TARGET_DB}" == "nocodb_meta" ]]; then
  echo "  Tip: stop NocoDB first:  docker compose stop nocodb"
fi

# Terminate active connections, then drop and recreate
docker compose -f "${PROJECT_ROOT}/docker-compose.yml" exec -T postgres \
  psql -U "${POSTGRES_SUPERUSER}" -d postgres -c \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${TARGET_DB}' AND pid <> pg_backend_pid();" \
  > /dev/null 2>&1 || true

docker compose -f "${PROJECT_ROOT}/docker-compose.yml" exec -T postgres \
  psql -U "${POSTGRES_SUPERUSER}" -d postgres \
  -c "DROP DATABASE IF EXISTS ${TARGET_DB}; CREATE DATABASE ${TARGET_DB};"

docker compose -f "${PROJECT_ROOT}/docker-compose.yml" exec -T postgres \
  psql -U "${POSTGRES_SUPERUSER}" -d "${TARGET_DB}" \
  < "${BACKUP_FILE}"

echo "  Restored ${TARGET_DB} from ${BASENAME}"
if [[ "${TARGET_DB}" == "nocodb_meta" ]]; then
  echo "  Restart NocoDB when ready:  docker compose start nocodb"
fi

echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] Restore complete."
