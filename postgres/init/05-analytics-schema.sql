-- ============================================================
-- Analytics destination schema — receives near-real-time copies of
-- finance/sales/operations tables via the realtime-sync service.
-- ============================================================
-- The analytics tables mirror the source schemas exactly so the
-- sync code can use auto-derived column lists.

CREATE SCHEMA IF NOT EXISTS analytics;

-- Tracks per-table sync state (last audit.change_log id processed)
CREATE TABLE IF NOT EXISTS analytics._sync_cursor (
    table_schema TEXT NOT NULL,
    table_name   TEXT NOT NULL,
    last_log_id  BIGINT NOT NULL DEFAULT 0,
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (table_schema, table_name)
);

-- Mirror tables — same shape as source.
CREATE TABLE IF NOT EXISTS analytics.cost_centers          (LIKE finance.cost_centers          INCLUDING DEFAULTS);
CREATE TABLE IF NOT EXISTS analytics.budget_targets        (LIKE finance.budget_targets        INCLUDING DEFAULTS);
CREATE TABLE IF NOT EXISTS analytics.regional_targets      (LIKE sales.regional_targets        INCLUDING DEFAULTS);
CREATE TABLE IF NOT EXISTS analytics.partner_commissions   (LIKE sales.partner_commissions     INCLUDING DEFAULTS);
CREATE TABLE IF NOT EXISTS analytics.vendor_master         (LIKE operations.vendor_master      INCLUDING DEFAULTS);
CREATE TABLE IF NOT EXISTS analytics.maintenance_schedules (LIKE operations.maintenance_schedules INCLUDING DEFAULTS);

GRANT USAGE, CREATE ON SCHEMA analytics TO nocodb_user;
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE ON ALL TABLES IN SCHEMA analytics TO nocodb_user;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA analytics TO nocodb_user;
-- Future tables created by the sync service inherit the right grants
ALTER DEFAULT PRIVILEGES IN SCHEMA analytics
  GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE ON TABLES TO nocodb_user;
