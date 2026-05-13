# Realtime PG → PG Sync

Polls `audit.change_log` on a source Postgres every 2 seconds and applies
each new INSERT / UPDATE / DELETE to a destination Postgres (into the
`analytics` schema). Destination tables auto-create on first run.

## Run on the destination laptop (no Docker)

You need Python 3.10+ and network access to the source Postgres.

```bash
# 1. Install dependencies
pip install -r requirements.txt

# 2. Set env vars pointing at SOURCE (this laptop) and DESTINATION (local)
set PG_HOST=192.168.100.132        # source laptop's IP
set PG_PORT=5433                   # source PG port (Docker-mapped)
set PG_USER=etl_reader             # read-only is enough on source
set PG_PASSWORD=CHANGE_ME_etl_reader_pass
set PG_DATABASE=business_inputs

set DEST_HOST=localhost            # destination is local on this laptop
set DEST_PORT=5432
set DEST_USER=your_destination_user
set DEST_PASSWORD=your_destination_password
set DEST_DATABASE=your_destination_db

# 3. Run
python sync.py

# Or one-shot for testing:
python sync.py --once
```

## What happens on first run

1. Connects to both SOURCE and DESTINATION
2. Creates `analytics` schema on DESTINATION if missing
3. Creates a matching mirror table for each configured table (reads source
   schema, builds CREATE TABLE on the fly)
4. Bootstrap-copies current rows from source → destination
5. Records the latest audit-log id so subsequent runs only apply new changes
6. Starts polling every 2 seconds

## What happens on subsequent runs

For each configured table:
1. Read `audit.change_log` on SOURCE where `id > last_synced_id`
2. For each new row, apply the corresponding INSERT/UPDATE/DELETE on DESTINATION
3. Update the cursor

## Tables synced

See `config.yaml`. Default: 6 business tables across finance / sales / operations.

## When destination becomes ClickHouse

Replace `apply_change()` with ClickHouse-equivalent inserts (use
`ReplacingMergeTree` with a version column). Everything else stays the same.
