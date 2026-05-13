"""Near-real-time Postgres → Postgres incremental sync.

Reads audit.change_log on the SOURCE database every POLL_SECONDS,
applies each new INSERT / UPDATE / DELETE to the DESTINATION database
(into the analytics schema).

You can run this:
  - on the source machine (writes go over the network to dest)
  - on the destination machine (reads come over the network from source)
  - on a third machine entirely

The destination schema and tables are auto-created on first run.

Env vars:
  Source (required):
    PG_HOST, PG_PORT, PG_USER, PG_PASSWORD, PG_DATABASE
  Destination (optional, defaults to source for same-DB POC):
    DEST_HOST, DEST_PORT, DEST_USER, DEST_PASSWORD, DEST_DATABASE
"""
import logging
import os
import sys
import time
from pathlib import Path

import psycopg2
import psycopg2.extras
import yaml

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("realtime")

CFG = yaml.safe_load(Path(__file__).parent.joinpath("config.yaml").read_text())
TABLES = CFG["tables"]
POLL_SECONDS = float(CFG.get("poll_seconds", 2.0))
DEST_SCHEMA = CFG.get("destination_schema", "analytics")

SRC = {
    "host":     os.environ["PG_HOST"],
    "port":     int(os.environ.get("PG_PORT", 5432)),
    "user":     os.environ["PG_USER"],
    "password": os.environ["PG_PASSWORD"],
    "dbname":   os.environ["PG_DATABASE"],
}

DEST = {
    "host":     os.environ.get("DEST_HOST",     SRC["host"]),
    "port":     int(os.environ.get("DEST_PORT", SRC["port"])),
    "user":     os.environ.get("DEST_USER",     SRC["user"]),
    "password": os.environ.get("DEST_PASSWORD", SRC["password"]),
    "dbname":   os.environ.get("DEST_DATABASE", SRC["dbname"]),
}


# ── Destination schema bootstrapping (auto-create) ─────────────────────────

def ensure_dest_schema(src_conn, dest_conn):
    """Create the analytics schema, cursor table, and a mirror per source table."""
    with dest_conn.cursor() as cur:
        cur.execute(f'CREATE SCHEMA IF NOT EXISTS "{DEST_SCHEMA}"')
        cur.execute(f"""
            CREATE TABLE IF NOT EXISTS "{DEST_SCHEMA}"._sync_cursor (
                table_schema TEXT NOT NULL,
                table_name   TEXT NOT NULL,
                last_log_id  BIGINT NOT NULL DEFAULT 0,
                updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
                PRIMARY KEY (table_schema, table_name)
            )
        """)

    for full in TABLES:
        schema, name = full.split(".", 1)
        if not table_exists_on_dest(dest_conn, name):
            ddl = build_create_table_sql(src_conn, schema, name)
            with dest_conn.cursor() as cur:
                cur.execute(ddl)
            log.info("created destination table %s.%s", DEST_SCHEMA, name)
    dest_conn.commit()


def table_exists_on_dest(conn, name):
    with conn.cursor() as cur:
        cur.execute(
            "SELECT 1 FROM information_schema.tables WHERE table_schema=%s AND table_name=%s",
            (DEST_SCHEMA, name),
        )
        return cur.fetchone() is not None


def build_create_table_sql(src_conn, schema, name):
    """Inspect source column types and build a matching CREATE TABLE for the destination."""
    with src_conn.cursor() as cur:
        cur.execute("""
            SELECT column_name,
                   udt_name,
                   character_maximum_length,
                   numeric_precision,
                   numeric_scale,
                   is_nullable,
                   column_default
            FROM information_schema.columns
            WHERE table_schema=%s AND table_name=%s
            ORDER BY ordinal_position
        """, (schema, name))
        cols = cur.fetchall()

    parts = []
    for col, udt, maxlen, num_p, num_s, nullable, default in cols:
        t = pg_type(udt, maxlen, num_p, num_s)
        line = f'"{col}" {t}'
        if nullable == "NO":
            line += " NOT NULL"
        # Defaults are skipped; the source values come in via the sync.
        parts.append(line)

    pks = source_pk_cols(src_conn, schema, name)
    if pks:
        pk_sql = ", ".join(f'"{c}"' for c in pks)
        parts.append(f"PRIMARY KEY ({pk_sql})")

    return f'CREATE TABLE "{DEST_SCHEMA}"."{name}" ({", ".join(parts)})'


def pg_type(udt, maxlen, num_p, num_s):
    if udt == "varchar":
        return f"varchar({maxlen})" if maxlen else "text"
    if udt == "bpchar":
        return f"char({maxlen})" if maxlen else "char"
    if udt == "numeric":
        if num_p:
            return f"numeric({num_p},{num_s or 0})"
        return "numeric"
    # The udt_name for most types is already the SQL name (int4, int8, timestamptz, ...).
    return udt


# ── Sync cursor (on destination) ───────────────────────────────────────────

def get_cursor(dest_conn, schema, name):
    """Return the last applied log id, or None if this table has never been bootstrapped."""
    with dest_conn.cursor() as cur:
        cur.execute(
            f'SELECT last_log_id FROM "{DEST_SCHEMA}"._sync_cursor WHERE table_schema=%s AND table_name=%s',
            (schema, name),
        )
        row = cur.fetchone()
        return row[0] if row else None


def set_cursor(dest_conn, schema, name, log_id):
    """Upsert the cursor — row may not exist yet on first bootstrap."""
    with dest_conn.cursor() as cur:
        cur.execute(
            f"""
            INSERT INTO "{DEST_SCHEMA}"._sync_cursor (table_schema, table_name, last_log_id, updated_at)
            VALUES (%s, %s, %s, now())
            ON CONFLICT (table_schema, table_name)
            DO UPDATE SET last_log_id = EXCLUDED.last_log_id, updated_at = now()
            """,
            (schema, name, log_id),
        )
    dest_conn.commit()


# ── Primary key lookup (on source) ─────────────────────────────────────────

_pk_cache = {}


def source_pk_cols(src_conn, schema, name):
    key = f"{schema}.{name}"
    if key in _pk_cache:
        return _pk_cache[key]
    with src_conn.cursor() as cur:
        cur.execute(
            """
            SELECT a.attname
            FROM pg_index i
            JOIN pg_attribute a ON a.attrelid=i.indrelid AND a.attnum = ANY(i.indkey)
            WHERE i.indrelid = %s::regclass AND i.indisprimary
            ORDER BY a.attnum
            """,
            (f"{schema}.{name}",),
        )
        cols = [r[0] for r in cur.fetchall()]
    _pk_cache[key] = cols
    return cols


# ── Apply a single change against destination ──────────────────────────────

def apply_change(dest_conn, src_conn, action, schema, name, old_data, new_data):
    dest = f'"{DEST_SCHEMA}"."{name}"'
    pks = source_pk_cols(src_conn, schema, name)
    if not pks:
        raise RuntimeError(f"no primary key on {schema}.{name}; cannot apply incrementally")

    with dest_conn.cursor() as cur:
        if action == "I":
            cols = list(new_data.keys())
            placeholders = ", ".join(["%s"] * len(cols))
            cols_sql = ", ".join(f'"{c}"' for c in cols)
            cur.execute(
                f'INSERT INTO {dest} ({cols_sql}) VALUES ({placeholders}) ON CONFLICT DO NOTHING',
                [new_data[c] for c in cols],
            )
        elif action == "U":
            non_pk = [c for c in new_data.keys() if c not in pks]
            set_sql = ", ".join(f'"{c}" = %s' for c in non_pk)
            where_sql = " AND ".join(f'"{c}" = %s' for c in pks)
            vals = [new_data[c] for c in non_pk] + [new_data[c] for c in pks]
            cur.execute(f'UPDATE {dest} SET {set_sql} WHERE {where_sql}', vals)
            if cur.rowcount == 0:
                cols_all = list(new_data.keys())
                placeholders = ", ".join(["%s"] * len(cols_all))
                cols_sql = ", ".join(f'"{c}"' for c in cols_all)
                cur.execute(
                    f'INSERT INTO {dest} ({cols_sql}) VALUES ({placeholders})',
                    [new_data[c] for c in cols_all],
                )
        elif action == "D":
            where_sql = " AND ".join(f'"{c}" = %s' for c in pks)
            cur.execute(f'DELETE FROM {dest} WHERE {where_sql}', [old_data[c] for c in pks])


# ── Bootstrap: first-time copy of current source state ────────────────────

def bootstrap(src_conn, dest_conn, schema, name):
    dest = f'"{DEST_SCHEMA}"."{name}"'
    src  = f'"{schema}"."{name}"'

    with dest_conn.cursor() as cur:
        cur.execute(f"SELECT count(*) FROM {dest}")
        if cur.fetchone()[0] > 0:
            return  # already has data

    with src_conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(f"SELECT * FROM {src}")
        rows = cur.fetchall()

    if rows:
        cols = list(rows[0].keys())
        placeholders = ", ".join(["%s"] * len(cols))
        cols_sql = ", ".join(f'"{c}"' for c in cols)
        with dest_conn.cursor() as cur:
            psycopg2.extras.execute_batch(
                cur,
                f'INSERT INTO {dest} ({cols_sql}) VALUES ({placeholders})',
                [[r[c] for c in cols] for r in rows],
                page_size=500,
            )

    with src_conn.cursor() as cur:
        cur.execute("SELECT COALESCE(max(id), 0) FROM audit.change_log")
        max_id = cur.fetchone()[0]
    set_cursor(dest_conn, schema, name, max_id)
    dest_conn.commit()
    log.info("bootstrap %s.%s — copied %s rows", schema, name, len(rows))


# ── Polling loop ───────────────────────────────────────────────────────────

def poll_once(src_conn, dest_conn):
    applied = 0
    for full in TABLES:
        schema, name = full.split(".", 1)

        last = get_cursor(dest_conn, schema, name)
        if last is None:
            bootstrap(src_conn, dest_conn, schema, name)
            last = get_cursor(dest_conn, schema, name) or 0

        with src_conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute("""
                SELECT id, action, old_data, new_data
                FROM audit.change_log
                WHERE table_schema=%s AND table_name=%s AND id > %s
                ORDER BY id
            """, (schema, name, last))
            changes = cur.fetchall()

        if not changes:
            continue

        max_id = last
        for c in changes:
            try:
                apply_change(dest_conn, src_conn, c["action"], schema, name, c["old_data"], c["new_data"])
                max_id = c["id"]
                applied += 1
            except Exception:
                log.exception("apply failed id=%s on %s", c["id"], full)
                dest_conn.rollback()
                break

        set_cursor(dest_conn, schema, name, max_id)
        log.info("applied %s changes to %s (cursor -> %s)", len(changes), full, max_id)

    return applied


def main():
    log.info(
        "realtime-sync starting; poll=%ss tables=%s SRC=%s:%s/%s DEST=%s:%s/%s",
        POLL_SECONDS, len(TABLES),
        SRC["host"], SRC["port"], SRC["dbname"],
        DEST["host"], DEST["port"], DEST["dbname"],
    )
    while True:
        try:
            src_conn = psycopg2.connect(**SRC)
            dest_conn = psycopg2.connect(**DEST)
            src_conn.autocommit = False
            dest_conn.autocommit = False

            ensure_dest_schema(src_conn, dest_conn)

            while True:
                try:
                    poll_once(src_conn, dest_conn)
                    src_conn.commit()
                    dest_conn.commit()
                except Exception:
                    log.exception("poll errored; rolling back")
                    src_conn.rollback()
                    dest_conn.rollback()
                time.sleep(POLL_SECONDS)
        except Exception:
            log.exception("connection error; reconnecting in 5s")
            try:
                src_conn.close()
                dest_conn.close()
            except Exception:
                pass
            time.sleep(5)


if __name__ == "__main__":
    if "--once" in sys.argv:
        src_conn = psycopg2.connect(**SRC)
        dest_conn = psycopg2.connect(**DEST)
        ensure_dest_schema(src_conn, dest_conn)
        n = poll_once(src_conn, dest_conn)
        dest_conn.commit()
        print(f"applied {n} changes")
    else:
        main()
