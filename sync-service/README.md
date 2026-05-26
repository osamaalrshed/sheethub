# sync-service — Postgres → ClickHouse incremental CDC

## What it does

Every `interval_seconds` (default 1800 = 30 minutes):

1. Reads new rows from `audit.change_log` per source table.
2. For each change (INSERT / UPDATE / DELETE) **appends** a row to the
   matching ClickHouse table with two extra columns:
   - `_version` — the source change timestamp (`changed_at`)
   - `_deleted` — `1` if the source row was deleted, `0` otherwise
3. Updates the cursor in `sheetshub_sync_state` so we never re-apply a row.

ClickHouse uses `ReplacingMergeTree(_version)` to collapse multiple
versions of the same primary key in background merges. The service
never issues `UPDATE` or `DELETE` against ClickHouse — append-only.

## Why this pattern

- **ClickHouse is optimized for appends, not for in-place updates.**
  Sending UPDATE/DELETE statements would defeat its columnar design.
- **Idempotent and replayable.** Re-applying the same audit range
  produces the same final state (later versions win in merges).
- **Incremental.** Only rows that actually changed are transferred —
  scales independently of source table size.
- **Auditable.** All historical versions remain in CH until merges
  collapse them; you can query "what did this row look like yesterday"
  by filtering on `_version`.

This is the canonical pattern recommended by ClickHouse, Tinybird,
Materialize, and most "Postgres CDC to ClickHouse" guides.

## How queries work

Always filter out tombstones and use `FINAL` (or `argMax`) to get the
latest version of each row:

```sql
-- Current state, hides deletes
SELECT * FROM finance_cost_centers FINAL WHERE _deleted = 0;

-- Same idea without FINAL (faster for large tables)
SELECT
    argMax(name, _version)        AS name,
    argMax(status, _version)      AS status,
    argMax(updated_at, _version)  AS updated_at,
    argMax(_deleted, _version)    AS deleted
FROM finance_cost_centers
GROUP BY code
HAVING deleted = 0;
```

If your BI tool exposes raw SELECTs, wrap each base table in a view:

```sql
CREATE VIEW v_finance_cost_centers AS
SELECT * FROM finance_cost_centers FINAL WHERE _deleted = 0;
```

## Layout

```
sync-service/
├── Dockerfile
├── requirements.txt
├── config.yaml                       # table list + sync interval
├── sync.py                           # the pipeline
└── clickhouse_schemas/               # one DDL file per CH table
    ├── finance_cost_centers.sql
    ├── finance_budget_targets.sql
    ├── sales_regional_targets.sql
    ├── sales_partner_commissions.sql
    ├── operations_vendor_master.sql
    └── operations_maintenance_schedules.sql
```

### Adding a new table

1. Add it to `config.yaml` (`source`, `destination`, `columns`).
2. Add `clickhouse_schemas/<destination>.sql` with the table DDL —
   choose `ORDER BY` and `PARTITION BY` to match real query patterns.
3. Always include the trailer:
   ```sql
   _version DateTime64(6, 'UTC'),
   _deleted UInt8 DEFAULT 0
   ```
   and the engine:
   ```sql
   ENGINE = ReplacingMergeTree(_version)
   ```
4. Rebuild the image (Docker layer cache can serve a stale config,
   so use `--no-cache` after editing `config.yaml`).
5. Restart the container. On first run it will bootstrap the new table
   and start tracking its cursor.

### Changing the interval

Edit `interval_seconds` in `config.yaml`, then:

```bash
docker compose build --no-cache sync
docker compose up -d --force-recreate sync
```

`--no-cache` is important: Docker's layer cache can skip rebuilding when
the only change is inside a copied file, leaving the running container
on the previous value.

## Running manually

```bash
# Trigger a one-shot run without waiting for the timer
docker compose exec sync python sync.py --once
```

Useful for debugging or after editing schemas.

## Schema evolution

If you add a column to a source table:

1. Update `clickhouse_schemas/<table>.sql` to add the column.
2. Apply the change in ClickHouse manually:
   ```sql
   ALTER TABLE finance_cost_centers ADD COLUMN new_col String;
   ```
   (The `CREATE TABLE IF NOT EXISTS` in our DDL files won't update
   existing tables.)
3. Add the column to the `columns:` list in `config.yaml`.
4. Restart the sync container. Next run picks up the new column from
   audit rows.

For renaming or dropping columns: harder — coordinate with downstream
consumers, plan a migration window.

## Failure modes

| Failure | Behaviour |
|---|---|
| Postgres unreachable | Run errors out; retries on next interval. No partial state. |
| ClickHouse unreachable | Same — surface the error, retry. Cursor not advanced. |
| Single table errors (e.g. type mismatch) | That table is skipped; others continue. Logged; cursor not advanced for the failing table. |
| `audit.change_log` truncated | Tables already bootstrapped keep their cursors; new audits since the last cursor are missed — manual reconciliation needed. |

## Limitations / known tech-debt

- **No retry-with-backoff inside a run.** A transient CH blip wastes a
  whole interval. (Roadmap.)
- **`CREATE TABLE IF NOT EXISTS` doesn't update existing tables.**
  Schema changes require manual `ALTER TABLE`.
- **No prune of `audit.change_log`.** It grows forever. Plan a
  retention job: delete entries older than 30 days *after* all cursors
  have passed them.
- **Single-process synchronous applies.** Fine for ≤50 tables; for
  bigger fleets, parallelize.
