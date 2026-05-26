-- Mirror of operations.maintenance_schedules (Postgres).
-- Common access pattern: "what needs maintenance next?" — ORDER BY equipment_id.
CREATE TABLE IF NOT EXISTS operations_maintenance_schedules
(
    id              Int32,
    equipment_id    String,
    frequency_days  Int32,
    last_done       Nullable(Date),
    next_due        Nullable(Date),
    owner           Nullable(String),
    created_at      DateTime64(6, 'UTC'),
    updated_at      DateTime64(6, 'UTC'),
    _version        DateTime64(6, 'UTC'),
    _deleted        UInt8 DEFAULT 0
)
ENGINE = ReplacingMergeTree(_version)
ORDER BY (equipment_id, id);
