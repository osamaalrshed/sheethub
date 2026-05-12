#!/usr/bin/env bash
# Creates application users and grants database-level privileges.
# Passwords come from env vars injected via docker-compose.yml.
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "postgres" <<-EOSQL
    -- NocoDB app user: full access to metadata DB and data DB
    CREATE USER ${POSTGRES_NOCODB_USER} WITH PASSWORD '${POSTGRES_NOCODB_PASSWORD}';
    GRANT ALL PRIVILEGES ON DATABASE nocodb_meta      TO ${POSTGRES_NOCODB_USER};
    GRANT ALL PRIVILEGES ON DATABASE business_inputs  TO ${POSTGRES_NOCODB_USER};

    -- ETL read-only user: connect only to the data DB (schema grants follow in 03)
    CREATE USER ${ETL_READER_USER} WITH PASSWORD '${ETL_READER_PASSWORD}';
    GRANT CONNECT ON DATABASE business_inputs TO ${ETL_READER_USER};
EOSQL

# PostgreSQL 15+ revoked CREATE on public schema by default — restore it for nocodb_user
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "nocodb_meta" <<-EOSQL
    GRANT ALL ON SCHEMA public TO ${POSTGRES_NOCODB_USER};
EOSQL

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "business_inputs" <<-EOSQL
    GRANT CREATE ON DATABASE business_inputs TO ${POSTGRES_NOCODB_USER};
    GRANT ALL ON SCHEMA public TO ${POSTGRES_NOCODB_USER};
EOSQL

echo "[02] Users created: ${POSTGRES_NOCODB_USER}, ${ETL_READER_USER}"
