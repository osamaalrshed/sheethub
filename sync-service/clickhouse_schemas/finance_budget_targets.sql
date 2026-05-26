-- Mirror of finance.budget_targets (Postgres).
-- Time-series style: typical queries filter/group by year and department,
-- so we partition by year and order by (year, department, quarter, id).
CREATE TABLE IF NOT EXISTS finance_budget_targets
(
    id             Int32,
    year           UInt16,
    quarter        LowCardinality(FixedString(2)),
    department     LowCardinality(String),
    target_amount  Decimal(14, 2),
    owner          Nullable(String),
    updated_at     DateTime64(6, 'UTC'),
    _version       DateTime64(6, 'UTC'),
    _deleted       UInt8 DEFAULT 0
)
ENGINE = ReplacingMergeTree(_version)
PARTITION BY year
ORDER BY (year, department, quarter, id);
