-- Mirror of finance.cost_centers (Postgres).
-- Small dimension table (~tens of rows). No partition; single ORDER BY on PK.
CREATE TABLE IF NOT EXISTS finance_cost_centers
(
    code           String,
    name           String,
    manager_email  Nullable(String),
    status         LowCardinality(String),
    created_at     DateTime64(6, 'UTC'),
    updated_at     DateTime64(6, 'UTC'),
    _version       DateTime64(6, 'UTC'),
    _deleted       UInt8 DEFAULT 0
)
ENGINE = ReplacingMergeTree(_version)
ORDER BY code;
