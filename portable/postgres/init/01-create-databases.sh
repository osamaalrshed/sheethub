#!/usr/bin/env bash
# Creates the two databases NocoDB requires.
# Runs as the postgres superuser inside the container during first-start init.
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "postgres" <<-EOSQL
    CREATE DATABASE nocodb_meta;
    CREATE DATABASE business_inputs;
EOSQL

echo "[01] Databases created: nocodb_meta, business_inputs"
