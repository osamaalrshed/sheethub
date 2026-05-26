-- Mirror of sales.regional_targets (Postgres).
-- Partitioned by year for query pruning. ORDER BY (year, region, quarter, id)
-- supports filter on year and group by region.
CREATE TABLE IF NOT EXISTS sales_regional_targets
(
    id                Int32,
    region            LowCardinality(String),
    quarter           LowCardinality(FixedString(2)),
    year              UInt16,
    target_revenue    Decimal(14, 2),
    achieved_revenue  Nullable(Decimal(14, 2)),
    updated_at        DateTime64(6, 'UTC'),
    _version          DateTime64(6, 'UTC'),
    _deleted          UInt8 DEFAULT 0
)
ENGINE = ReplacingMergeTree(_version)
PARTITION BY year
ORDER BY (year, region, quarter, id);
