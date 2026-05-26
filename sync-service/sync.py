"""Postgres -> ClickHouse incremental CDC sync.

Architecture:
  1. PostgreSQL audit triggers record every INSERT/UPDATE/DELETE on the
     business schemas into audit.change_log (with old_data / new_data jsonb).
  2. Every interval_seconds, this service reads new audit rows since the
     last cursor and appends them to ClickHouse — append-only writes only.
  3. ClickHouse tables use ReplacingMergeTree(_version) so multiple versions
     of the same primary key collapse to the latest in background merges.
  4. Deletes become append rows with _deleted = 1. Queries filter on it.

Why this pattern:
  - ClickHouse is not optimized for in-place UPDATE / DELETE; append-only
    plus version columns is the canonical Postgres-CDC-to-ClickHouse pattern.
  - Incremental: only the rows that actually changed are transferred, so it
    scales independently of source-table size.
  - Idempotent: replaying the same audit-log range produces the same result
    (later versions win; earlier rows are merged away).

State per source table is kept in `sheetshub_sync_state` (in ClickHouse) so
the service is stateless and can be killed and restarted at any time.

Each destination table has explicit DDL in clickhouse_schemas/ — engineers
edit those files to tune ORDER BY / PARTITION BY for their access patterns.
Auto-generated schemas with `ORDER BY tuple()` would waste ClickHouse's
columnar performance.
"""
import json
import logging
import os
import sys
import time
from datetime import date, datetime, timezone
from decimal import Decimal
from pathlib import Path

import psycopg2
import psycopg2.extras
import yaml
import clickhouse_connect


# Preserve numeric precision when reading JSONB — by default Python's json
# loader turns "150000.00" into 150000.0 (float64), which loses precision for
# financial data. Register a Decimal-safe JSONB loader globally on this
# connection's typecasters so audit.change_log.new_data values come back as
# Decimal instead of float.
def _jsonb_load_decimal_safe(s):
    return json.loads(s, parse_float=Decimal)


psycopg2.extras.register_default_jsonb(loads=_jsonb_load_decimal_safe, globally=True)

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("sync")

ROOT       = Path(__file__).parent
CFG        = yaml.safe_load((ROOT / "config.yaml").read_text())
INTERVAL   = int(CFG.get("interval_seconds", 1800))
TABLES     = CFG["tables"]
SCHEMA_DIR = ROOT / "clickhouse_schemas"

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

STATE_TABLE = "sheetshub_sync_state"


# ── One-time setup: DDL + sync-state table ──────────────────────────────────

def apply_ddl(ch):
    """Apply every CREATE TABLE IF NOT EXISTS from clickhouse_schemas/.
    Convention: one DDL statement per file. Safe to run on every start;
    existing tables are not touched.
    """
    files = sorted(SCHEMA_DIR.glob("*.sql"))
    for f in files:
        stmt = f.read_text().strip().rstrip(";").strip()
        if stmt:
            ch.command(stmt)
    log.info("applied %s ClickHouse DDL file(s)", len(files))


def ensure_state_table(ch):
    ch.command(f"""
        CREATE TABLE IF NOT EXISTS {STATE_TABLE}
        (
            source_table   String,
            last_log_id    UInt64,
            last_sync_at   DateTime64(6, 'UTC'),
            rows_applied   UInt64
        )
        ENGINE = ReplacingMergeTree(last_sync_at)
        ORDER BY source_table
    """)


def get_cursor(ch, source_table):
    """Return the last applied log id for this source table, or None if it
    has never been bootstrapped.

    NB: We have to check row existence explicitly because ClickHouse's
    `max()` over an empty set returns 0 (the default for UInt64), not NULL.
    Using 0 as the "never bootstrapped" sentinel would incorrectly trigger
    incremental sync on a fresh deployment.
    """
    cnt = ch.query(
        f"SELECT count() FROM {STATE_TABLE} WHERE source_table = %(t)s",
        parameters={"t": source_table},
    ).first_row[0]
    if cnt == 0:
        return None
    val = ch.query(
        f"SELECT argMax(last_log_id, last_sync_at) FROM {STATE_TABLE} WHERE source_table = %(t)s",
        parameters={"t": source_table},
    ).first_row[0]
    return int(val)


# JSONB stores timestamps as ISO strings — clickhouse-connect's DateTime64
# writer expects Python datetime, not str. Heuristic coercion based on the
# string shape; safe for our schemas (no free-text columns shaped like ISO).
_ISO_DATETIME_PREFIX_LEN = 19   # "YYYY-MM-DDTHH:MM:SS"
_ISO_DATE_LEN = 10              # "YYYY-MM-DD"

def coerce_jsonb_value(v):
    if not isinstance(v, str):
        return v
    if len(v) >= _ISO_DATETIME_PREFIX_LEN and v[10] in ('T', ' '):
        try:
            # fromisoformat accepts "2024-01-15T10:30:00+00:00" and similar.
            # Replace trailing Z with explicit UTC offset for older Python.
            return datetime.fromisoformat(v.replace('Z', '+00:00'))
        except ValueError:
            pass
    if len(v) == _ISO_DATE_LEN and v[4] == '-' and v[7] == '-':
        try:
            return date.fromisoformat(v)
        except ValueError:
            pass
    return v


def set_cursor(ch, source_table, last_log_id, rows):
    ch.insert(
        STATE_TABLE,
        [[source_table, int(last_log_id), datetime.now(timezone.utc), int(rows)]],
        column_names=["source_table", "last_log_id", "last_sync_at", "rows_applied"],
    )


# ── Bootstrap on first run for a table ──────────────────────────────────────

def bootstrap(pg, ch, tbl):
    """Copy current source state into ClickHouse with _version=now, _deleted=0.
    Then advance the cursor to the highest current audit-log id so we don't
    re-apply the same rows incrementally.
    """
    source = tbl["source"]
    dest   = tbl["destination"]
    cols   = tbl["columns"]
    schema, name = source.split(".", 1)

    with pg.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(f'SELECT * FROM "{schema}"."{name}"')
        rows = cur.fetchall()

    if rows:
        now = datetime.now(timezone.utc)
        ch_rows = [[r[c] for c in cols] + [now, 0] for r in rows]
        ch.insert(dest, ch_rows, column_names=cols + ["_version", "_deleted"])

    with pg.cursor() as cur:
        cur.execute("SELECT COALESCE(max(id), 0) FROM audit.change_log")
        max_id = cur.fetchone()[0]

    set_cursor(ch, source, max_id, len(rows))
    log.info("bootstrap %s — copied %s rows (cursor → %s)", source, len(rows), max_id)


# ── Incremental apply (the main work) ───────────────────────────────────────

def apply_incremental(pg, ch, tbl):
    """Read audit.change_log since the table's cursor and append each row
    to the ClickHouse mirror as (data..., _version=changed_at, _deleted=flag).
    """
    source = tbl["source"]
    dest   = tbl["destination"]
    cols   = tbl["columns"]

    cursor = get_cursor(ch, source)
    if cursor is None:
        bootstrap(pg, ch, tbl)
        return 0

    schema, name = source.split(".", 1)
    with pg.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute("""
            SELECT id, action, old_data, new_data, changed_at
            FROM audit.change_log
            WHERE table_schema = %s AND table_name = %s AND id > %s
            ORDER BY id
        """, (schema, name, cursor))
        changes = cur.fetchall()

    if not changes:
        return 0

    ch_rows = []
    for c in changes:
        # For deletes we use old_data (the row that just disappeared).
        # For inserts and updates, new_data holds the post-change snapshot.
        data    = c["old_data"] if c["action"] == "D" else c["new_data"]
        deleted = 1 if c["action"] == "D" else 0
        if data is None:
            continue  # defensive — shouldn't happen with our triggers
        ch_row = [coerce_jsonb_value(data.get(col)) for col in cols] + [c["changed_at"], deleted]
        ch_rows.append(ch_row)

    if ch_rows:
        ch.insert(dest, ch_rows, column_names=cols + ["_version", "_deleted"])

    max_id = changes[-1]["id"]
    set_cursor(ch, source, max_id, len(ch_rows))
    log.info("applied %s changes for %s (cursor %s → %s)",
             len(ch_rows), source, cursor, max_id)
    return len(ch_rows)


# ── Driver ──────────────────────────────────────────────────────────────────

def run_once(pg, ch):
    total = 0
    for tbl in TABLES:
        try:
            total += apply_incremental(pg, ch, tbl)
        except Exception:
            log.exception("apply failed for %s — will retry next interval",
                          tbl.get("source"))
    log.info("run complete — applied=%s rows across %s tables", total, len(TABLES))


def one_pass():
    pg = psycopg2.connect(**PG)
    ch = clickhouse_connect.get_client(**CH)
    try:
        apply_ddl(ch)
        ensure_state_table(ch)
        run_once(pg, ch)
    finally:
        pg.close()
        ch.close()


def main():
    log.info("sync starting; interval=%ss tables=%s", INTERVAL, len(TABLES))
    while True:
        try:
            one_pass()
        except Exception:
            log.exception("run errored, will retry in %ss", INTERVAL)
        time.sleep(INTERVAL)


if __name__ == "__main__":
    if "--once" in sys.argv:
        one_pass()
    else:
        main()
