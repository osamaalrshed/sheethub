# sync-service — registry-driven Postgres → ClickHouse incremental CDC

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ PostgreSQL                                                       │
│                                                                  │
│  sync_config.tables   ← registry                                 │
│  ┌───────────────┬──────────────┬──────────────────┐             │
│  │ source_schema │ source_table │ destination      │             │
│  │ finance       │ cost_centers │ finance_cost_…   │             │
│  │ ...           │              │                  │             │
│  └───────────────┴──────────────┴──────────────────┘             │
│                                                                  │
│  audit.change_log     ← all INSERT/UPDATE/DELETE events           │
└─────────────────────────────────────────────────────────────────┘
                            │ every SYNC_INTERVAL_SECONDS (default 3s)
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│ sync-service (Python container)                                  │
│                                                                  │
│  1. Read sync_config.tables                                      │
│  2. For each table:                                              │
│     - If CH table doesn't exist → introspect PG, generate DDL,   │
│       CREATE TABLE IF NOT EXISTS in CH                           │
│     - If never bootstrapped → bulk-copy current rows             │
│     - Else: read audit.change_log since cursor, append           │
│       rows to CH with _version + _deleted columns                │
└─────────────────────────────────────────────────────────────────┘
                            │
                            ▼
                       ClickHouse
                  (ReplacingMergeTree)
```

The service is append-only. ClickHouse merges by `_version` in the
background. Queries use `FINAL WHERE _deleted = 0` to see current state.

---

## Add a new table to sync — SQL only, no SSH

### The simplest case: NocoDB UI or `CREATE TABLE` is enough

If the new table lives in one of the auto-discovered schemas (see
`sync_config.settings.auto_register_schemas` — default `finance, sales,
operations, marketing, hr`), a plain `CREATE TABLE` is all you need:

```sql
CREATE TABLE marketing.campaigns (
    id         SERIAL PRIMARY KEY,
    name       VARCHAR(150) NOT NULL,
    budget     NUMERIC(14, 2) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

A Postgres event trigger (`trg_auto_register_table`) fires on
`CREATE TABLE`, sees the schema is in the allowlist, validates the PK,
attaches the audit trigger, and inserts the registry row — **all
without you touching `sync_config.tables`**. This works whether the
table is created from DBeaver, psql, **or from NocoDB's "Create Table"
UI**.

Tables named `tmp_*` or starting with `_` are skipped (use this for
scratch tables that shouldn't sync).

### Deferred bootstrap: schema iteration doesn't leak into ClickHouse

A registered table is only bootstrapped into ClickHouse once the first
INSERT fires its audit trigger. Until then — while you're still adding
columns, renaming them, changing types, etc. — sync **skips** the
table entirely. The CH mirror appears only when you start adding data,
which means it's created from the *final* schema in one shot.

This matters because NocoDB implements column renames as DROP + ADD.
Without deferred bootstrap, every rename would leak a ghost column
into CH (CH can't tell a rename from an unrelated drop). With it, all
that DDL noise is absorbed pre-data and CH sees only the final layout.

Trade-off: empty tables never appear in CH. If you genuinely want a
schema-only mirror before any data exists, insert a placeholder row
(or `DELETE` it again — the audit log still records the event and
that's enough to flip the table into "ready" state).

### Adding a schema to the auto-register allowlist

```sql
UPDATE sync_config.settings
SET value = 'finance,sales,operations,marketing,hr,product'
WHERE key = 'auto_register_schemas';
```

Effective on the next `CREATE TABLE` — no restart.

### Explicit registration (for schemas NOT in the allowlist)

```sql
CREATE TABLE somewhere_else.thing (id SERIAL PRIMARY KEY, ...);
SELECT audit.register_table('somewhere_else', 'thing');
```

### After registration

That's it. Within one sync interval (default 3s — near-real-time), the sync container:

1. Introspects `marketing.campaigns` columns from `information_schema`
2. Generates the matching ClickHouse DDL with proper `Decimal` /
   `DateTime64(6, 'UTC')` / `Nullable` types
3. Creates the CH table (`ENGINE = ReplacingMergeTree(_version)`,
   `ORDER BY` defaults to the source PK)
4. Bootstrap-copies current rows
5. Marks bootstrapped in `sync_config.tables.bootstrapped_at`
6. From the next cycle onward, applies audit-log events incrementally

To **force an immediate sync** instead of waiting:

```bash
docker compose exec sync python sync.py --once
```

---

## Tune a table's ClickHouse schema

The defaults (auto-generated DDL, `ORDER BY = primary key`, no partitioning)
work fine for small tables. For large or hot tables you may want to tune.

**Set the override BEFORE first sync** (recommended — gets used immediately):

```sql
SELECT audit.register_table(
    'sales', 'huge_events',
    'sales_huge_events',                   -- destination
    '(event_date, customer_id, id)',       -- ORDER BY
    'toYYYYMM(event_date)'                 -- PARTITION BY
);
```

**Change AFTER first sync** (requires dropping the CH table and re-bootstrapping):

```sql
-- 1) Update the registry
UPDATE sync_config.tables
SET order_by    = '(event_date, customer_id, id)',
    partition_by = 'toYYYYMM(event_date)'
WHERE source_schema='sales' AND source_table='huge_events';

-- 2) Drop the CH table and reset the cursor (in ClickHouse):
--    DROP TABLE sales_huge_events;
--    ALTER TABLE sheetshub_sync_state DELETE WHERE source_table='sales.huge_events';
--
-- Next sync recreates the table with the new DDL and re-bootstraps.
```

---

## Operations

### Pause a table (stop syncing, keep audit log capturing)

```sql
SELECT audit.pause_sync('marketing', 'campaigns');
```

Audit trigger keeps recording. ClickHouse data stays put. New audit
entries accumulate. When you re-enable:

```sql
SELECT audit.resume_sync('marketing', 'campaigns');
```

…the next sync run catches up on everything that happened during the pause.

### Stop syncing a table permanently (remove trigger + registry entry)

```sql
SELECT audit.unregister_table('marketing', 'campaigns');
```

This:
- Drops the audit trigger (no more change capture)
- Removes the entry from `sync_config.tables`
- **Leaves ClickHouse data intact** — `DROP TABLE marketing_campaigns` in
  ClickHouse separately if you want a full cleanup.

To re-enable later: `SELECT audit.register_table('marketing', 'campaigns');`
(or just `CREATE TABLE` again if it was dropped).

### Manual flag toggle (alternative to pause_sync)

```sql
UPDATE sync_config.tables
SET enabled = FALSE
WHERE source_schema='X' AND source_table='Y';
```

Same effect as `pause_sync()`.

### See what's being synced

```sql
SELECT source_schema, source_table, destination,
       order_by, partition_by,
       enabled, bootstrapped_at, last_synced_at
FROM sync_config.tables
ORDER BY source_schema, source_table;
```

### Run sync manually

```bash
docker compose exec sync python sync.py --once
```

Useful after registering a new table or for debugging.

### Change the sync interval

`SYNC_INTERVAL_SECONDS` env var (in `.env`, falls back to 3s). Lower for
tighter latency, raise (e.g. 1800) to batch changes every 30 min instead.
This is the only setting that still requires a container restart.

---

## Schema evolution

**Adding a column** to a source table:

1. `ALTER TABLE finance.cost_centers ADD COLUMN region TEXT;` in Postgres.
2. Manually mirror the change in ClickHouse:
   ```sql
   ALTER TABLE finance_cost_centers ADD COLUMN region Nullable(String);
   ```
3. Next sync run picks up the new column automatically — sync re-introspects
   the source on every cycle.

**Dropping or renaming a column**: harder. Coordinate with downstream
consumers, plan a migration window.

---

## How types are mapped (auto-generation)

| Postgres                          | ClickHouse                       |
|-----------------------------------|----------------------------------|
| `smallint`                        | `Int16`                          |
| `integer`                         | `Int32`                          |
| `bigint`                          | `Int64`                          |
| `real`                            | `Float32`                        |
| `double precision`                | `Float64`                        |
| `numeric(p, s)`                   | `Decimal(p, s)` ← precision kept |
| `numeric` (unbounded)             | `Float64` (fallback)             |
| `boolean`                         | `Bool`                           |
| `date`                            | `Date`                           |
| `timestamp`                       | `DateTime64(6)`                  |
| `timestamp with time zone`        | `DateTime64(6, 'UTC')`           |
| `uuid`                            | `UUID`                           |
| `varchar`, `text`                 | `String`                         |
| `char(n)` (n ≤ 16)                | `FixedString(n)`                 |
| `json`, `jsonb`                   | `String`                         |
| (NULL-able)                       | wrapped in `Nullable(...)`       |

`_version DateTime64(6, 'UTC')` and `_deleted UInt8 DEFAULT 0` are appended
to every table automatically.

---

## Failure modes

| Failure | Behaviour |
|---|---|
| Postgres unreachable | Run aborts, retries next interval. No partial state. |
| ClickHouse unreachable | Same — surface, retry. Cursor not advanced. |
| Source has no PK | `register_table()` raises; sync skips the table if force-inserted into registry. |
| Single table errors mid-run (e.g. weird type) | That table is skipped; others continue. Cursor unchanged for the failing one. |
| Service restarted mid-run | Cursors are durable in CH; next start picks up where it left off. |
| Source table dropped in PG | Sync errors when introspecting; `enabled = FALSE` to silence. |

---

## Limitations / known tech-debt

- **No retry-with-backoff inside a run.** A transient CH blip wastes a
  whole cycle. (Roadmap.)
- **No auto-prune of `audit.change_log`.** It grows forever. Schedule a
  retention job that deletes rows older than 30 days **after** all
  cursors have passed them.
- **Single-process sequential applies.** Fine for ≤50 tables.
- **Schema changes are partial.** Adding columns auto-detected; renaming
  / dropping needs human coordination.
- **Auto-DDL means no PR review for new schemas.** Mitigation: the registry
  is queryable and is itself audited (it lives in `business_inputs`, where
  audit triggers are attached — meta!).

---

## Layout

```
sync-service/
├── Dockerfile
├── requirements.txt    # psycopg2-binary, clickhouse-connect
├── sync.py             # the whole service (~280 lines)
└── README.md           # you are here
```

No config files. The registry IS the config.
