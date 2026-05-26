-- ============================================================
-- Sync registry — controls which tables get synced to ClickHouse.
-- ============================================================
-- Admin workflow (from any DBeaver / psql, no server access):
--
--   1. Create the source table in Postgres.
--   2. Run:    SELECT audit.register_table('marketing', 'campaigns');
--   3. Wait up to one sync interval (default 30 min).
--      The sync service auto-creates the matching ClickHouse table
--      and bootstraps current rows.
--
-- Override defaults for big or hot tables:
--   UPDATE sync_config.tables
--   SET order_by    = '(year, region, id)',
--       partition_by = 'year'
--   WHERE source_schema='sales' AND source_table='regional_targets';
--
-- Temporarily disable a table:
--   UPDATE sync_config.tables SET enabled = FALSE
--   WHERE source_schema='X' AND source_table='Y';

CREATE SCHEMA IF NOT EXISTS sync_config;

-- ── Registry table ──────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS sync_config.tables (
    source_schema     TEXT        NOT NULL,
    source_table      TEXT        NOT NULL,
    destination       TEXT        NOT NULL,                -- ClickHouse table name
    order_by          TEXT,                                -- optional override; defaults to PK
    partition_by      TEXT,                                -- optional override
    enabled           BOOLEAN     NOT NULL DEFAULT TRUE,
    bootstrapped_at   TIMESTAMPTZ,                         -- set by sync after first run
    last_synced_at    TIMESTAMPTZ,                         -- set by sync after each run
    notes             TEXT,                                -- free-text for admin
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (source_schema, source_table)
);

COMMENT ON TABLE  sync_config.tables IS 'Registry of business tables synced to ClickHouse';
COMMENT ON COLUMN sync_config.tables.order_by    IS 'CH ORDER BY clause; defaults to primary key';
COMMENT ON COLUMN sync_config.tables.partition_by IS 'CH PARTITION BY clause; default = no partitioning';

GRANT USAGE ON SCHEMA sync_config TO nocodb_user;
GRANT SELECT, UPDATE, INSERT ON sync_config.tables TO nocodb_user;
GRANT SELECT ON sync_config.tables TO etl_reader;

-- ── audit.register_table() — the one-call helper ───────────────────────────
-- Validates the source table, attaches the audit trigger, and adds the
-- registry entry. Runs as SECURITY DEFINER so app users can register
-- tables without owning sync_config.

CREATE OR REPLACE FUNCTION audit.register_table(
    p_schema       TEXT,
    p_table        TEXT,
    p_destination  TEXT DEFAULT NULL,
    p_order_by     TEXT DEFAULT NULL,
    p_partition_by TEXT DEFAULT NULL
) RETURNS sync_config.tables AS $$
DECLARE
    result sync_config.tables%ROWTYPE;
BEGIN
    -- 1) Table must exist
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = p_schema AND table_name = p_table
    ) THEN
        RAISE EXCEPTION 'Source table %.% does not exist — create it first', p_schema, p_table;
    END IF;

    -- 2) Table must have a primary key (needed for ReplacingMergeTree dedup)
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.table_constraints
        WHERE table_schema = p_schema AND table_name = p_table
          AND constraint_type = 'PRIMARY KEY'
    ) THEN
        RAISE EXCEPTION 'Source table %.% must have a primary key (required for ClickHouse dedup)',
                        p_schema, p_table;
    END IF;

    -- 3) Attach audit trigger if not already present
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgrelid = format('%I.%I', p_schema, p_table)::regclass
          AND tgname  = 'trg_audit'
    ) THEN
        EXECUTE format(
            'CREATE TRIGGER trg_audit AFTER INSERT OR UPDATE OR DELETE ON %I.%I '
            'FOR EACH ROW EXECUTE FUNCTION audit.log_change()',
            p_schema, p_table
        );
    END IF;

    -- 4) Upsert the registry row
    INSERT INTO sync_config.tables (source_schema, source_table, destination,
                                     order_by, partition_by)
    VALUES (
        p_schema,
        p_table,
        COALESCE(p_destination, p_schema || '_' || p_table),
        p_order_by,
        p_partition_by
    )
    ON CONFLICT (source_schema, source_table) DO UPDATE
        SET destination  = EXCLUDED.destination,
            order_by     = EXCLUDED.order_by,
            partition_by = EXCLUDED.partition_by
    RETURNING * INTO result;

    RETURN result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION audit.register_table IS
  'Validates a source table, attaches the audit trigger, and registers it for ClickHouse sync.';

-- ── Seed the registry with the six existing business tables ────────────────
-- Pre-tuned ORDER BY / PARTITION BY values match the hand-crafted DDL we
-- had before — no performance regression on these tables.

SELECT audit.register_table('finance',    'cost_centers',
                            'finance_cost_centers',
                            'code', NULL);

SELECT audit.register_table('finance',    'budget_targets',
                            'finance_budget_targets',
                            '(year, department, quarter, id)', 'year');

SELECT audit.register_table('sales',      'regional_targets',
                            'sales_regional_targets',
                            '(year, region, quarter, id)', 'year');

SELECT audit.register_table('sales',      'partner_commissions',
                            'sales_partner_commissions',
                            '(partner_name, effective_date, id)', NULL);

SELECT audit.register_table('operations', 'vendor_master',
                            'operations_vendor_master',
                            'vendor_id', NULL);

SELECT audit.register_table('operations', 'maintenance_schedules',
                            'operations_maintenance_schedules',
                            '(equipment_id, id)', NULL);
