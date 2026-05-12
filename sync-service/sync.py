"""Postgres → ClickHouse one-way sync service.

For each configured table:
  1. Check audit.change_log: has anything changed since the last successful sync?
  2. If yes — drop+recreate the table in ClickHouse and reload all rows.
  3. If no — skip.

Runs in a loop with a configurable interval (default 1 hour).
"""
import logging
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import psycopg2
import psycopg2.extras
import yaml
import clickhouse_connect

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("sync")

CONFIG = yaml.safe_load(Path(__file__).parent.joinpath("config.yaml").read_text())
TABLES = CONFIG["tables"]
INTERVAL = int(CONFIG.get("interval_seconds", 3600))

PG = {
    "host":     os.environ["PG_HOST"],
    "port":     int(os.environ.get("PG_PORT", 5432)),
    "user":     os.environ["PG_USER"],
    "password": os.environ["PG_PASSWORD"],
    "dbname":   os.environ["PG_DATABASE"],
}

CH = {
    "host":     os.environ["CH_HOST"],
    "port":     int(os.environ.get("CH_PORT", 8123)),
    "username": os.environ.get("CH_USER", "default"),
    "password": os.environ.get("CH_PASSWORD", ""),
    "database": os.environ.get("CH_DATABASE", "default"),
}


# ── Type mapping ────────────────────────────────────────────────────────────

PG_TO_CH = {
    "smallint":             "Int16",
    "integer":              "Int32",
    "bigint":               "Int64",
    "real":                 "Float32",
    "double precision":     "Float64",
    "numeric":              "Float64",
    "boolean":              "Bool",
    "text":                 "String",
    "character varying":    "String",
    "character":            "String",
    "varchar":              "String",
    "date":                 "Date",
    "time without time zone":      "String",
    "time with time zone":         "String",
    "timestamp without time zone": "DateTime64(6)",
    "timestamp with time zone":    "DateTime64(6, 'UTC')",
    "uuid":                 "String",
    "json":                 "String",
    "jsonb":                "String",
}


def pg_to_ch_type(pg_type: str, nullable: str) -> str:
    base = PG_TO_CH.get(pg_type.lower(), "String")
    return f"Nullable({base})" if nullable == "YES" else base


# ── Sync state (lives in ClickHouse so it's near the data) ─────────────────

SYNC_STATE_TABLE = "sheetshub_sync_state"


def ensure_sync_state(ch):
    ch.command(f"""
        CREATE TABLE IF NOT EXISTS {SYNC_STATE_TABLE} (
            table_full_name String,
            last_sync_at    DateTime64(6, 'UTC'),
            rows_synced     UInt64
        ) ENGINE = ReplacingMergeTree(last_sync_at)
        ORDER BY table_full_name
    """)


def get_last_sync(ch, table_full_name: str):
    res = ch.query(
        f"SELECT max(last_sync_at) FROM {SYNC_STATE_TABLE} WHERE table_full_name = %(t)s",
        parameters={"t": table_full_name},
    )
    if res.row_count and res.first_row[0]:
        return res.first_row[0]
    return datetime(1970, 1, 1, tzinfo=timezone.utc)


def record_sync(ch, table_full_name: str, rows: int):
    ch.insert(
        SYNC_STATE_TABLE,
        [[table_full_name, datetime.now(timezone.utc), rows]],
        column_names=["table_full_name", "last_sync_at", "rows_synced"],
    )


# ── Sync one table ──────────────────────────────────────────────────────────

def has_changes(pg, schema: str, table: str, since) -> bool:
    with pg.cursor() as cur:
        cur.execute("""
            SELECT 1 FROM audit.change_log
            WHERE table_schema = %s AND table_name = %s AND changed_at > %s
            LIMIT 1
        """, (schema, table, since))
        return cur.fetchone() is not None


def get_pg_columns(pg, schema: str, table: str):
    with pg.cursor() as cur:
        cur.execute("""
            SELECT column_name, data_type, is_nullable
            FROM information_schema.columns
            WHERE table_schema = %s AND table_name = %s
            ORDER BY ordinal_position
        """, (schema, table))
        return cur.fetchall()


def reload_table(pg, ch, full_name: str) -> int:
    schema, table = full_name.split(".", 1)
    ch_table = f"{schema}_{table}"

    cols = get_pg_columns(pg, schema, table)
    if not cols:
        log.warning("table %s has no columns or doesn't exist — skipping", full_name)
        return 0

    col_defs = ", ".join(f"`{c[0]}` {pg_to_ch_type(c[1], c[2])}" for c in cols)
    ch.command(f"DROP TABLE IF EXISTS `{ch_table}`")
    ch.command(f"CREATE TABLE `{ch_table}` ({col_defs}) ENGINE = MergeTree ORDER BY tuple()")

    with pg.cursor() as cur:
        cur.execute(f'SELECT * FROM "{schema}"."{table}"')
        rows = cur.fetchall()

    if rows:
        col_names = [c[0] for c in cols]
        ch.insert(ch_table, rows, column_names=col_names)

    return len(rows)


# ── Main loop ───────────────────────────────────────────────────────────────

def run_once(pg, ch):
    synced = skipped = 0
    for full_name in TABLES:
        schema, table = full_name.split(".", 1)
        last_sync = get_last_sync(ch, full_name)

        if not has_changes(pg, schema, table, last_sync):
            skipped += 1
            log.info("skip %s (no changes since %s)", full_name, last_sync)
            continue

        try:
            n = reload_table(pg, ch, full_name)
            record_sync(ch, full_name, n)
            synced += 1
            log.info("synced %s — %s rows", full_name, n)
        except Exception:
            log.exception("failed to sync %s", full_name)

    log.info("run complete — synced=%s skipped=%s", synced, skipped)


def one_pass():
    """Run a single sync pass and exit."""
    pg = psycopg2.connect(**PG)
    ch = clickhouse_connect.get_client(**CH)
    try:
        ensure_sync_state(ch)
        run_once(pg, ch)
    finally:
        pg.close()
        ch.close()


def main():
    log.info("sync-service starting, interval=%ss, tables=%s", INTERVAL, len(TABLES))
    while True:
        try:
            one_pass()
        except Exception:
            log.exception("sync run errored, will retry next interval")
        time.sleep(INTERVAL)


if __name__ == "__main__":
    if "--once" in sys.argv:
        one_pass()
    else:
        main()
