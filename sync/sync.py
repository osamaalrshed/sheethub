"""
ETL sync: PostgreSQL business_inputs → SQL Server business_inputs
Truncate-and-load per table; schema/database created if missing.

Usage:
    python sync.py                         # one-shot
    python sync.py --watch --interval 60   # poll every 60 s
"""

import argparse
import logging
import os
import time
from datetime import datetime, timezone

import psycopg2
import psycopg2.extras
import pyodbc

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)-8s %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger(__name__)

# ── Connection helpers ────────────────────────────────────────────────────────

def pg_connect():
    return psycopg2.connect(
        host=os.environ["PG_HOST"],
        port=int(os.environ.get("PG_PORT", 5432)),
        dbname=os.environ["PG_DATABASE"],
        user=os.environ["PG_USER"],
        password=os.environ["PG_PASSWORD"],
    )


def mssql_connect(database="master"):
    conn_str = (
        "DRIVER={ODBC Driver 18 for SQL Server};"
        f"SERVER={os.environ['MSSQL_HOST']},{os.environ.get('MSSQL_PORT', 1433)};"
        f"DATABASE={database};"
        f"UID={os.environ['MSSQL_USER']};"
        f"PWD={os.environ['MSSQL_PASSWORD']};"
        "TrustServerCertificate=yes;"
    )
    return pyodbc.connect(conn_str, autocommit=True)


# ── Type mapping: PostgreSQL → SQL Server ─────────────────────────────────────

_TYPE_MAP = {
    "character varying": "NVARCHAR",
    "varchar":           "NVARCHAR",
    "text":              "NVARCHAR(MAX)",
    "integer":           "INT",
    "int":               "INT",
    "int4":              "INT",
    "bigint":            "BIGINT",
    "int8":              "BIGINT",
    "smallint":          "SMALLINT",
    "int2":              "SMALLINT",
    "numeric":           "DECIMAL",
    "decimal":           "DECIMAL",
    "real":              "REAL",
    "float":             "FLOAT",
    "double precision":  "FLOAT",
    "boolean":           "BIT",
    "bool":              "BIT",
    "date":              "DATE",
    "timestamp without time zone": "DATETIME2",
    "timestamp with time zone":    "DATETIMEOFFSET",
    "timestamptz":       "DATETIMEOFFSET",
    "timestamp":         "DATETIME2",
    "char":              "NCHAR",
    "character":         "NCHAR",
    "json":              "NVARCHAR(MAX)",
    "jsonb":             "NVARCHAR(MAX)",
    "uuid":              "UNIQUEIDENTIFIER",
    "bytea":             "VARBINARY(MAX)",
    "serial":            "INT",
    "bigserial":         "BIGINT",
}


def _map_type(data_type: str, char_max: int | None, num_prec: int | None, num_scale: int | None) -> str:
    base = _TYPE_MAP.get(data_type.lower(), "NVARCHAR(MAX)")
    if base == "NVARCHAR":
        if char_max and 0 < char_max <= 4000:
            return f"NVARCHAR({char_max})"
        return "NVARCHAR(MAX)"
    if base in ("DECIMAL", "NUMERIC"):
        if num_prec:
            return f"DECIMAL({num_prec},{num_scale or 0})"
        return "DECIMAL(18,6)"
    if base == "NCHAR":
        return f"NCHAR({char_max or 1})"
    return base


# ── Schema discovery ──────────────────────────────────────────────────────────

def discover_tables(pg_conn) -> list[tuple[str, str]]:
    """Return [(schema, table), ...] for all user schemas in business_inputs."""
    with pg_conn.cursor() as cur:
        cur.execute("""
            SELECT table_schema, table_name
            FROM information_schema.tables
            WHERE table_type = 'BASE TABLE'
              AND table_schema NOT IN ('pg_catalog','information_schema','public')
            ORDER BY table_schema, table_name
        """)
        return cur.fetchall()


def get_columns(pg_conn, schema: str, table: str) -> list[dict]:
    with pg_conn.cursor() as cur:
        cur.execute("""
            SELECT column_name,
                   data_type,
                   character_maximum_length,
                   numeric_precision,
                   numeric_scale,
                   is_nullable
            FROM information_schema.columns
            WHERE table_schema = %s AND table_name = %s
            ORDER BY ordinal_position
        """, (schema, table))
        return [
            {
                "name":       row[0],
                "data_type":  row[1],
                "char_max":   row[2],
                "num_prec":   row[3],
                "num_scale":  row[4],
                "nullable":   row[5] == "YES",
            }
            for row in cur.fetchall()
        ]


# ── SQL Server setup ──────────────────────────────────────────────────────────

def ensure_mssql_database(ms_conn, db_name: str) -> None:
    cursor = ms_conn.cursor()
    cursor.execute(
        "SELECT 1 FROM sys.databases WHERE name = ?", db_name
    )
    if not cursor.fetchone():
        cursor.execute(f"CREATE DATABASE [{db_name}]")
        log.info("Created SQL Server database [%s]", db_name)


def ensure_mssql_schema(ms_conn, schema: str) -> None:
    cursor = ms_conn.cursor()
    cursor.execute(
        "SELECT 1 FROM sys.schemas WHERE name = ?", schema
    )
    if not cursor.fetchone():
        cursor.execute(f"CREATE SCHEMA [{schema}]")
        log.info("Created SQL Server schema [%s]", schema)


def _build_create_table(schema: str, table: str, columns: list[dict]) -> str:
    col_defs = []
    for col in columns:
        sql_type = _map_type(
            col["data_type"], col["char_max"], col["num_prec"], col["num_scale"]
        )
        nullable = "NULL" if col["nullable"] else "NOT NULL"
        col_defs.append(f"    [{col['name']}] {sql_type} {nullable}")
    return (
        f"CREATE TABLE [{schema}].[{table}] (\n"
        + ",\n".join(col_defs)
        + "\n)"
    )


def ensure_mssql_table(ms_conn, schema: str, table: str, columns: list[dict]) -> None:
    cursor = ms_conn.cursor()
    cursor.execute(
        """
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = ? AND table_name = ?
        """,
        schema, table,
    )
    if not cursor.fetchone():
        ddl = _build_create_table(schema, table, columns)
        cursor.execute(ddl)
        log.info("Created table [%s].[%s]", schema, table)


# ── Row transfer ──────────────────────────────────────────────────────────────

def _placeholders(n: int) -> str:
    return ",".join(["?"] * n)


def sync_table(pg_conn, ms_conn, schema: str, table: str) -> int:
    columns = get_columns(pg_conn, schema, table)
    if not columns:
        log.warning("No columns found for %s.%s — skipping", schema, table)
        return 0

    ensure_mssql_schema(ms_conn, schema)
    ensure_mssql_table(ms_conn, schema, table, columns)

    col_names = [c["name"] for c in columns]
    quoted_cols = ", ".join(f"[{c}]" for c in col_names)
    placeholders = _placeholders(len(col_names))
    insert_sql = f"INSERT INTO [{schema}].[{table}] ({quoted_cols}) VALUES ({placeholders})"

    # Fetch all rows from Postgres
    with pg_conn.cursor(cursor_factory=psycopg2.extras.DictCursor) as pg_cur:
        pg_cur.execute(f'SELECT {", ".join(f"{chr(34)}{c}{chr(34)}" for c in col_names)} FROM "{schema}"."{table}"')
        rows = pg_cur.fetchall()

    # Truncate target and bulk insert
    ms_cur = ms_conn.cursor()
    ms_cur.execute(f"TRUNCATE TABLE [{schema}].[{table}]")
    if rows:
        # Convert row values to plain Python types pyodbc understands
        data = [tuple(row) for row in rows]
        ms_cur.fast_executemany = True
        ms_cur.executemany(insert_sql, data)

    return len(rows)


# ── Main sync loop ────────────────────────────────────────────────────────────

def run_sync() -> None:
    target_db = os.environ.get("MSSQL_DATABASE", "business_inputs")
    started = datetime.now(timezone.utc)
    log.info("=== Sync started at %s ===", started.strftime("%Y-%m-%d %H:%M:%S UTC"))

    try:
        pg_conn = pg_connect()
    except Exception as exc:
        log.error("Cannot connect to PostgreSQL: %s", exc)
        raise

    try:
        ms_master = mssql_connect("master")
        ensure_mssql_database(ms_master, target_db)
        ms_master.close()
        ms_conn = mssql_connect(target_db)
    except Exception as exc:
        log.error("Cannot connect to SQL Server: %s", exc)
        pg_conn.close()
        raise

    tables = discover_tables(pg_conn)
    if not tables:
        log.warning("No tables found in PostgreSQL business_inputs (non-public schemas).")

    total_rows = 0
    errors = 0
    for schema, table in tables:
        t0 = time.monotonic()
        try:
            row_count = sync_table(pg_conn, ms_conn, schema, table)
            elapsed = time.monotonic() - t0
            log.info("  %-30s  %6d rows  %.2fs", f"{schema}.{table}", row_count, elapsed)
            total_rows += row_count
        except Exception as exc:
            elapsed = time.monotonic() - t0
            log.error("  %-30s  FAILED (%.2fs): %s", f"{schema}.{table}", elapsed, exc)
            errors += 1

    pg_conn.close()
    ms_conn.close()

    elapsed_total = (datetime.now(timezone.utc) - started).total_seconds()
    log.info(
        "=== Sync complete: %d tables, %d rows, %d error(s) in %.1fs ===",
        len(tables), total_rows, errors, elapsed_total,
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Sync business_inputs PG → SQL Server")
    parser.add_argument("--watch", action="store_true", help="Run continuously")
    parser.add_argument("--interval", type=int, default=60, help="Seconds between syncs (--watch mode)")
    args = parser.parse_args()

    if args.watch:
        log.info("Watch mode: syncing every %d seconds. Ctrl-C to stop.", args.interval)
        while True:
            try:
                run_sync()
            except Exception as exc:
                log.error("Sync run failed: %s", exc)
            log.info("Next sync in %d seconds…", args.interval)
            time.sleep(args.interval)
    else:
        run_sync()


if __name__ == "__main__":
    main()
