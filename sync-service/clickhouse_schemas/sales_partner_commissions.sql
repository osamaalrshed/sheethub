-- Mirror of sales.partner_commissions (Postgres).
-- Small reference table. Commission_rate stays as Decimal(5,4) — financial
-- precision must not roundtrip through Float64.
CREATE TABLE IF NOT EXISTS sales_partner_commissions
(
    id               Int32,
    partner_name     String,
    commission_rate  Decimal(5, 4),
    effective_date   Date,
    status           LowCardinality(String),
    updated_at       DateTime64(6, 'UTC'),
    _version         DateTime64(6, 'UTC'),
    _deleted         UInt8 DEFAULT 0
)
ENGINE = ReplacingMergeTree(_version)
ORDER BY (partner_name, effective_date, id);
