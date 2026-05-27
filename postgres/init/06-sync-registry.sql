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

-- ── Settings table — small key/value store for sync-wide config ───────────
-- Currently used to control auto-discovery scopes. Editable via SQL.

CREATE TABLE IF NOT EXISTS sync_config.settings (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    notes TEXT
);

INSERT INTO sync_config.settings (key, value, notes) VALUES
    ('auto_register_schemas',
     'finance,sales,operations,marketing,hr',
     'Comma-separated list of schemas where new tables are auto-registered for sync on CREATE TABLE')
ON CONFLICT (key) DO NOTHING;

GRANT SELECT, UPDATE ON sync_config.settings TO nocodb_user;

-- ── Event trigger: auto-register new tables created in tracked schemas ─────
-- Fires on CREATE TABLE inside Postgres. Filters to the schemas listed in
-- sync_config.settings.auto_register_schemas, skips tables whose name starts
-- with "tmp_" (convention for scratch/temp work that shouldn't be synced),
-- and only registers tables that have a primary key (silent skip otherwise).
--
-- This is what makes the "admin creates a table from NocoDB UI → it
-- automatically flows to ClickHouse" workflow possible.

CREATE OR REPLACE FUNCTION audit.auto_register_new_table()
RETURNS event_trigger
LANGUAGE plpgsql
AS $$
DECLARE
    obj          RECORD;
    v_schema     TEXT;          -- local vars renamed to avoid shadowing
    v_table      TEXT;          -- the column of the same name from
    v_allowed    TEXT[];        -- pg_event_trigger_ddl_commands().
BEGIN
    SELECT string_to_array(value, ',')
      INTO v_allowed
      FROM sync_config.settings
     WHERE key = 'auto_register_schemas';

    IF v_allowed IS NULL THEN
        RETURN;  -- setting missing → nothing to do
    END IF;

    FOR obj IN
        SELECT cmd.schema_name AS s, cmd.object_identity AS oi
          FROM pg_event_trigger_ddl_commands() AS cmd
         WHERE cmd.command_tag = 'CREATE TABLE'
           AND cmd.schema_name IS NOT NULL
    LOOP
        v_schema := obj.s;
        v_table  := trim(BOTH '"' FROM split_part(obj.oi, '.', 2));

        IF NOT (v_schema = ANY(v_allowed)) THEN
            CONTINUE;
        END IF;
        IF v_table LIKE 'tmp\_%' ESCAPE '\' OR v_table LIKE '\_%' ESCAPE '\' THEN
            CONTINUE;
        END IF;

        -- register_table validates PK existence and attaches the audit
        -- trigger. If the new table has no PK we want to skip silently
        -- (admin can add a PK later and re-register manually).
        BEGIN
            PERFORM audit.register_table(v_schema, v_table);
            RAISE NOTICE 'Auto-registered new table %.% for ClickHouse sync',
                         v_schema, v_table;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'Skipped auto-register of %.%: %',
                         v_schema, v_table, SQLERRM;
        END;
    END LOOP;
END;
$$;

DROP EVENT TRIGGER IF EXISTS trg_auto_register_table;
CREATE EVENT TRIGGER trg_auto_register_table
    ON ddl_command_end
    WHEN TAG IN ('CREATE TABLE')
    EXECUTE FUNCTION audit.auto_register_new_table();

-- ── Pause / resume / unregister helpers ────────────────────────────────────
-- All callable from any DB client. SECURITY DEFINER so app users can use them.

CREATE OR REPLACE FUNCTION audit.pause_sync(p_schema TEXT, p_table TEXT)
RETURNS sync_config.tables AS $$
DECLARE result sync_config.tables%ROWTYPE;
BEGIN
    -- Audit trigger keeps running, so resume() catches up via the change log.
    UPDATE sync_config.tables
       SET enabled = FALSE
     WHERE source_schema = p_schema AND source_table = p_table
    RETURNING * INTO result;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Table %.% is not registered for sync', p_schema, p_table;
    END IF;
    RETURN result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION audit.pause_sync IS
  'Stops syncing the table to ClickHouse, but keeps capturing changes in the audit log.';

CREATE OR REPLACE FUNCTION audit.resume_sync(p_schema TEXT, p_table TEXT)
RETURNS sync_config.tables AS $$
DECLARE result sync_config.tables%ROWTYPE;
BEGIN
    UPDATE sync_config.tables
       SET enabled = TRUE
     WHERE source_schema = p_schema AND source_table = p_table
    RETURNING * INTO result;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Table %.% is not registered for sync', p_schema, p_table;
    END IF;
    RETURN result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION audit.resume_sync IS
  'Re-enables sync for a paused table. The next sync run catches up via the audit log.';

CREATE OR REPLACE FUNCTION audit.unregister_table(p_schema TEXT, p_table TEXT)
RETURNS void AS $$
BEGIN
    -- Drop the audit trigger if it exists.
    IF EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgrelid = format('%I.%I', p_schema, p_table)::regclass
          AND tgname  = 'trg_audit'
    ) THEN
        EXECUTE format('DROP TRIGGER trg_audit ON %I.%I', p_schema, p_table);
    END IF;
    -- Remove the registry row. Existing ClickHouse data is left intact —
    -- drop the CH table manually if you want a full cleanup.
    DELETE FROM sync_config.tables
     WHERE source_schema = p_schema AND source_table = p_table;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION audit.unregister_table IS
  'Detaches the audit trigger and removes the table from sync_config.tables. Does NOT drop ClickHouse data.';

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
