-- Mirror of operations.vendor_master (Postgres).
-- Dimension table; ORDER BY on natural key (vendor_id).
CREATE TABLE IF NOT EXISTS operations_vendor_master
(
    vendor_id      String,
    name           String,
    category       LowCardinality(Nullable(String)),
    status         LowCardinality(String),
    contact_email  Nullable(String),
    contact_phone  Nullable(String),
    created_at     DateTime64(6, 'UTC'),
    updated_at     DateTime64(6, 'UTC'),
    _version       DateTime64(6, 'UTC'),
    _deleted       UInt8 DEFAULT 0
)
ENGINE = ReplacingMergeTree(_version)
ORDER BY vendor_id;
