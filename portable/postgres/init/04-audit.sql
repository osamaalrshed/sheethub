-- ============================================================
-- Audit infrastructure
-- ============================================================
-- Captures every INSERT / UPDATE / DELETE on business tables.
-- Survives row deletes, captures bulk operations, queryable.
--
-- For CDC: read rows with changed_at > last_sync_time.
-- For audit:  filter by table_schema/name, changed_by, date.
--
-- "changed_by" is the PostgreSQL role (usually nocodb_user).
-- "application_user" is optional — set with:
--     SET app.user = 'finance@test.local';
-- before queries to capture the real NocoDB user.

CREATE SCHEMA IF NOT EXISTS audit;

CREATE TABLE IF NOT EXISTS audit.change_log (
    id               BIGSERIAL    PRIMARY KEY,
    changed_at       TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    changed_by       TEXT         NOT NULL,
    application_user TEXT,
    table_schema     TEXT         NOT NULL,
    table_name       TEXT         NOT NULL,
    action           CHAR(1)      NOT NULL CHECK (action IN ('I','U','D')),
    old_data         JSONB,
    new_data         JSONB
);

CREATE INDEX IF NOT EXISTS idx_change_log_changed_at ON audit.change_log (changed_at DESC);
CREATE INDEX IF NOT EXISTS idx_change_log_table     ON audit.change_log (table_schema, table_name);
CREATE INDEX IF NOT EXISTS idx_change_log_user      ON audit.change_log (changed_by);

-- Generic trigger function — works for any table regardless of PK structure
CREATE OR REPLACE FUNCTION audit.log_change() RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO audit.change_log (
        changed_by, application_user, table_schema, table_name, action, old_data, new_data
    ) VALUES (
        current_user,
        current_setting('app.user', true),
        TG_TABLE_SCHEMA,
        TG_TABLE_NAME,
        substr(TG_OP, 1, 1),
        CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN to_jsonb(OLD) END,
        CASE WHEN TG_OP IN ('INSERT','UPDATE') THEN to_jsonb(NEW) END
    );
    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Attach triggers to all 6 business tables
DO $$
DECLARE
    t RECORD;
BEGIN
    FOR t IN
        SELECT table_schema, table_name
        FROM information_schema.tables
        WHERE table_schema IN ('finance','sales','operations')
          AND table_type = 'BASE TABLE'
    LOOP
        EXECUTE format(
            'DROP TRIGGER IF EXISTS trg_audit ON %I.%I;
             CREATE TRIGGER trg_audit
             AFTER INSERT OR UPDATE OR DELETE ON %I.%I
             FOR EACH ROW EXECUTE FUNCTION audit.log_change();',
            t.table_schema, t.table_name,
            t.table_schema, t.table_name
        );
    END LOOP;
END $$;

-- Grants: nocodb_user can SELECT from audit so it shows up in NocoDB
GRANT USAGE ON SCHEMA audit TO nocodb_user;
GRANT SELECT ON audit.change_log TO nocodb_user;
GRANT USAGE, SELECT ON SEQUENCE audit.change_log_id_seq TO nocodb_user;
-- Read-only ETL user also gets read access
GRANT USAGE ON SCHEMA audit TO etl_reader;
GRANT SELECT ON audit.change_log TO etl_reader;
