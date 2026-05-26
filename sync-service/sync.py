"""Registry-driven Postgres → ClickHouse incremental CDC sync.

Tables to sync are listed in `sync_config.tables` (a Postgres table).
Adding a new table is purely a SQL operation:

    CREATE TABLE marketing.campaigns (...);
    SELECT audit.register_table('marketing', 'campaigns');

The sync container picks it up on its next cycle:
  1. Introspects the source schema in information_schema.
  2. Auto-generates a ClickHouse DDL with proper Decimal / DateTime64 /
     Nullable handling, plus _version and _deleted columns.
  3. CREATE TABLE IF NOT EXISTS in ClickHouse (admin can override
     ORDER BY / PARTITION BY via the registry).
  4. Bootstrap-copies current source rows on first sight.
  5. Applies audit-log changes incrementally on every subsequent run.

ClickHouse rows always include _version (= source change_at) and
_deleted (0|1). Queries should use FINAL or argMax to deduplicate, and
filter WHERE _deleted = 0 to hide tombstones.

No container restarts required to add tables — only when the sync code
itself changes.
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
import clickhouse_connect

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("sync")

INTERVAL = int(os.environ.get("SYNC_INTERVAL_SECONDS", 1800))
STATE_TABLE = "sheetshub_sync_state"

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


# Preserve numeric precision when reading JSONB (audit.change_log columns).
# Default Python json loader turns "150000.00" into float, losing precision.
def _jsonb_load_decimal_safe(s):
    return json.loads(s, parse_float=Decimal)


psycopg2.extras.register_default_jsonb(loads=_jsonb_load_decimal_safe, globally=True)


# ── PG → CH type mapping ───────────────────────────────────────────────────

def pg_to_ch_type(udt: str, char_len, num_p, num_s) -> str:
    """Map a Postgres type to its ClickHouse equivalent.
    Inputs come from information_schema.columns (udt_name, character_maximum_length,
    numeric_precision, numeric_scale).
    """
    u = udt.lower()
    if u in ("int2", "smallint"):       return "Int16"
    if u in ("int4", "integer"):        return "Int32"
    if u in ("int8", "bigint"):         return "Int64"
    if u in ("float4", "real"):         return "Float32"
    if u in ("float8", "double precision"):
                                        return "Float64"
    if u == "numeric":
        if num_p is not None:
            return f"Decimal({int(num_p)}, {int(num_s or 0)})"
        return "Float64"  # unbounded numeric — fallback
    if u in ("bool", "boolean"):        return "Bool"
    if u == "date":                     return "Date"
    if u == "timestamp":                return "DateTime64(6)"
    if u in ("timestamptz", "timestamp with time zone"):
                                        return "DateTime64(6, 'UTC')"
    if u in ("time", "timetz"):         return "String"
    if u == "uuid":                     return "UUID"
    if u in ("json", "jsonb"):          return "String"
    if u in ("varchar", "text", "bpchar", "char", "character", "character varying"):
        # FixedString for short single-character fixed types only
        if u in ("bpchar", "char") and char_len and char_len <= 16:
            return f"FixedString({int(char_len)})"
        return "String"
    return "String"  # safe default


# ── Source schema introspection ─────────────────────────────────────────────

def introspect_columns(pg, schema: str, table: str):
    """Return ordered list of column metadata dicts."""
    with pg.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute("""
            SELECT column_name, udt_name, character_maximum_length,
                   numeric_precision, numeric_scale, is_nullable
            FROM information_schema.columns
            WHERE table_schema = %s AND table_name = %s
            ORDER BY ordinal_position
        """, (schema, table))
        return cur.fetchall()


def primary_key_columns(pg, schema: str, table: str):
    """Return the primary-key column names, in order."""
    with pg.cursor() as cur:
        cur.execute(f"""
            SELECT a.attname
            FROM pg_index i
            JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
            WHERE i.indrelid = %s::regclass AND i.indisprimary
            ORDER BY array_position(i.indkey, a.attnum)
        """, (f"{schema}.{table}",))
        return [r[0] for r in cur.fetchall()]


# ── ClickHouse DDL generation ───────────────────────────────────────────────

def generate_ddl(dest: str, columns, order_by: str, partition_by: str) -> str:
    """Build a CREATE TABLE IF NOT EXISTS for ClickHouse."""
    col_defs = []
    for c in columns:
        ch_type = pg_to_ch_type(
            c["udt_name"], c["character_maximum_length"],
            c["numeric_precision"], c["numeric_scale"]
        )
        if c["is_nullable"] == "YES":
            ch_type = f"Nullable({ch_type})"
        col_defs.append(f'    {c["column_name"]} {ch_type}')

    col_defs.append('    _version  DateTime64(6, \'UTC\')')
    col_defs.append('    _deleted  UInt8 DEFAULT 0')

    partition_clause = f"PARTITION BY {partition_by}\n" if partition_by else ""

    return (
        f"CREATE TABLE IF NOT EXISTS {dest}\n"
        f"(\n" + ",\n".join(col_defs) + "\n)\n"
        f"ENGINE = ReplacingMergeTree(_version)\n"
        f"{partition_clause}"
        f"ORDER BY {order_by}"
    )


# ── State table ─────────────────────────────────────────────────────────────

def ensure_state_table(ch):
    ch.command(f"""
        CREATE TABLE IF NOT EXISTS {STATE_TABLE}
        (
            source_table  String,
            last_log_id   UInt64,
            last_sync_at  DateTime64(6, 'UTC'),
            rows_applied  UInt64
        )
        ENGINE = ReplacingMergeTree(last_sync_at)
        ORDER BY source_table
    """)


def get_cursor(ch, source_table):
    cnt = ch.query(
        f"SELECT count() FROM {STATE_TABLE} WHERE source_table = %(t)s",
        parameters={"t": source_table},
    ).first_row[0]
    if cnt == 0:
        return None
    return int(ch.query(
        f"SELECT argMax(last_log_id, last_sync_at) FROM {STATE_TABLE} WHERE source_table = %(t)s",
        parameters={"t": source_table},
    ).first_row[0])


def set_cursor(ch, source_table, last_log_id, rows):
    ch.insert(
        STATE_TABLE,
        [[source_table, int(last_log_id), datetime.now(timezone.utc), int(rows)]],
        column_names=["source_table", "last_log_id", "last_sync_at", "rows_applied"],
    )


# ── Registry ────────────────────────────────────────────────────────────────

def load_registry(pg):
    with pg.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute("""
            SELECT source_schema, source_table, destination,
                   order_by, partition_by, bootstrapped_at
            FROM sync_config.tables
            WHERE enabled = TRUE
            ORDER BY source_schema, source_table
        """)
        return cur.fetchall()


def update_registry_after_run(pg, schema, table, bootstrapped: bool):
    with pg.cursor() as cur:
        if bootstrapped:
            cur.execute("""
                UPDATE sync_config.tables
                SET bootstrapped_at = COALESCE(bootstrapped_at, now()),
                    last_synced_at  = now()
                WHERE source_schema = %s AND source_table = %s
            """, (schema, table))
        else:
            cur.execute("""
                UPDATE sync_config.tables
                SET last_synced_at = now()
                WHERE source_schema = %s AND source_table = %s
            """, (schema, table))
    pg.commit()


# ── Type coercion for JSONB values ─────────────────────────────────────────

_ISO_DATETIME_PREFIX_LEN = 19
_ISO_DATE_LEN = 10


def coerce_jsonb_value(v):
    """JSONB stores timestamps/dates as ISO strings; clickhouse-connect
    needs Python datetime/date for temporal columns. Convert in-flight."""
    if not isinstance(v, str):
        return v
    if len(v) >= _ISO_DATETIME_PREFIX_LEN and v[10] in ('T', ' '):
        try:
            return datetime.fromisoformat(v.replace('Z', '+00:00'))
        except ValueError:
            pass
    if len(v) == _ISO_DATE_LEN and v[4] == '-' and v[7] == '-':
        try:
            return date.fromisoformat(v)
        except ValueError:
            pass
    return v


# ── Per-table work ──────────────────────────────────────────────────────────

def ensure_destination_table(pg, ch, tbl):
    """Create the ClickHouse mirror table if it doesn't exist."""
    dest = tbl["destination"]
    schema, table = tbl["source_schema"], tbl["source_table"]

    exists = ch.query(
        "SELECT count() FROM system.tables WHERE database = %(db)s AND name = %(t)s",
        parameters={"db": CH["database"], "t": dest},
    ).first_row[0] > 0
    if exists:
        return

    columns = introspect_columns(pg, schema, table)
    if not columns:
        raise RuntimeError(f"source table {schema}.{table} has no columns")

    pks = primary_key_columns(pg, schema, table)
    order_by = tbl["order_by"] or (pks[0] if len(pks) == 1 else f"({', '.join(pks)})")
    ddl = generate_ddl(dest, columns, order_by, tbl["partition_by"])
    log.info("creating CH table %s\n%s", dest, ddl)
    ch.command(ddl)


def bootstrap(pg, ch, tbl):
    """Copy current source rows into the CH mirror with _version=now and _deleted=0."""
    schema, table, dest = tbl["source_schema"], tbl["source_table"], tbl["destination"]
    cols_meta = introspect_columns(pg, schema, table)
    col_names = [c["column_name"] for c in cols_meta]

    with pg.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(f'SELECT * FROM "{schema}"."{table}"')
        rows = cur.fetchall()

    if rows:
        now = datetime.now(timezone.utc)
        ch_rows = [[r[c] for c in col_names] + [now, 0] for r in rows]
        ch.insert(dest, ch_rows, column_names=col_names + ["_version", "_deleted"])

    with pg.cursor() as cur:
        cur.execute("SELECT COALESCE(max(id), 0) FROM audit.change_log")
        max_id = cur.fetchone()[0]
    set_cursor(ch, f"{schema}.{table}", max_id, len(rows))
    update_registry_after_run(pg, schema, table, bootstrapped=True)
    log.info("bootstrap %s.%s — copied %s rows (cursor → %s)", schema, table, len(rows), max_id)


def apply_incremental(pg, ch, tbl):
    """Replay new audit.change_log entries for this table into ClickHouse."""
    schema, table, dest = tbl["source_schema"], tbl["source_table"], tbl["destination"]
    source_full = f"{schema}.{table}"

    cursor = get_cursor(ch, source_full)
    if cursor is None:
        bootstrap(pg, ch, tbl)
        return 0

    cols_meta = introspect_columns(pg, schema, table)
    col_names = [c["column_name"] for c in cols_meta]

    with pg.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute("""
            SELECT id, action, old_data, new_data, changed_at
            FROM audit.change_log
            WHERE table_schema = %s AND table_name = %s AND id > %s
            ORDER BY id
        """, (schema, table, cursor))
        changes = cur.fetchall()

    if not changes:
        update_registry_after_run(pg, schema, table, bootstrapped=False)
        return 0

    ch_rows = []
    for c in changes:
        data = c["old_data"] if c["action"] == "D" else c["new_data"]
        deleted = 1 if c["action"] == "D" else 0
        if data is None:
            continue
        ch_row = [coerce_jsonb_value(data.get(col)) for col in col_names] + [c["changed_at"], deleted]
        ch_rows.append(ch_row)

    if ch_rows:
        ch.insert(dest, ch_rows, column_names=col_names + ["_version", "_deleted"])

    max_id = changes[-1]["id"]
    set_cursor(ch, source_full, max_id, len(ch_rows))
    update_registry_after_run(pg, schema, table, bootstrapped=False)
    log.info("applied %s changes for %s (cursor %s → %s)", len(ch_rows), source_full, cursor, max_id)
    return len(ch_rows)


# ── Driver ──────────────────────────────────────────────────────────────────

def run_once(pg, ch):
    registry = load_registry(pg)
    total = 0
    for tbl in registry:
        try:
            ensure_destination_table(pg, ch, tbl)
            total += apply_incremental(pg, ch, tbl)
        except Exception:
            log.exception("apply failed for %s.%s — will retry next interval",
                          tbl["source_schema"], tbl["source_table"])
    log.info("run complete — applied=%s rows across %s tables", total, len(registry))


def one_pass():
    pg = psycopg2.connect(**PG)
    ch = clickhouse_connect.get_client(**CH)
    try:
        ensure_state_table(ch)
        run_once(pg, ch)
    finally:
        pg.close()
        ch.close()


def main():
    log.info("sync starting; interval=%ss", INTERVAL)
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
