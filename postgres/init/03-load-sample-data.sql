-- Sample business data for the business_inputs database.
-- Run by the PostgreSQL Docker entrypoint after the shell scripts above.
\connect business_inputs

-- ============================================================
-- Schemas
-- ============================================================
CREATE SCHEMA IF NOT EXISTS finance;
CREATE SCHEMA IF NOT EXISTS sales;
CREATE SCHEMA IF NOT EXISTS operations;

-- Grant schema-level access for the app user
GRANT USAGE, CREATE ON SCHEMA finance    TO nocodb_user;
GRANT USAGE, CREATE ON SCHEMA sales      TO nocodb_user;
GRANT USAGE, CREATE ON SCHEMA operations TO nocodb_user;

-- etl_reader gets USAGE only (SELECT on tables comes after INSERT below)
GRANT USAGE ON SCHEMA finance    TO etl_reader;
GRANT USAGE ON SCHEMA sales      TO etl_reader;
GRANT USAGE ON SCHEMA operations TO etl_reader;


-- ============================================================
-- finance.cost_centers  (~15 rows)
-- ============================================================
CREATE TABLE finance.cost_centers (
    code         VARCHAR(10)  PRIMARY KEY,
    name         VARCHAR(100) NOT NULL,
    manager_email VARCHAR(150),
    status       VARCHAR(20)  NOT NULL DEFAULT 'active'
                     CHECK (status IN ('active','inactive')),
    created_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

INSERT INTO finance.cost_centers (code, name, manager_email, status, created_at, updated_at) VALUES
('CC001', 'Engineering',          'alice.chen@company.local',     'active',   '2023-01-15 09:00:00+00', '2024-11-01 10:00:00+00'),
('CC002', 'Product Management',   'bob.martinez@company.local',   'active',   '2023-01-15 09:00:00+00', '2024-10-15 14:30:00+00'),
('CC003', 'Sales - North America','carol.thompson@company.local', 'active',   '2023-01-15 09:00:00+00', '2024-12-01 08:00:00+00'),
('CC004', 'Sales - EMEA',         'david.patel@company.local',    'active',   '2023-02-01 09:00:00+00', '2024-11-20 11:00:00+00'),
('CC005', 'Sales - APAC',         'emily.wong@company.local',     'active',   '2023-02-01 09:00:00+00', '2024-10-05 09:30:00+00'),
('CC006', 'Marketing',            'frank.osei@company.local',     'active',   '2023-01-15 09:00:00+00', '2024-12-10 16:00:00+00'),
('CC007', 'Human Resources',      'grace.kim@company.local',      'active',   '2023-01-15 09:00:00+00', '2024-09-30 10:00:00+00'),
('CC008', 'Finance',              'henry.ross@company.local',     'active',   '2023-01-15 09:00:00+00', '2024-11-15 13:00:00+00'),
('CC009', 'Legal & Compliance',   'isabella.moreau@company.local','active',   '2023-03-01 09:00:00+00', '2024-10-20 09:00:00+00'),
('CC010', 'IT Operations',        'james.okonkwo@company.local',  'active',   '2023-01-15 09:00:00+00', '2024-12-05 11:30:00+00'),
('CC011', 'Customer Success',     'kate.silva@company.local',     'active',   '2023-04-01 09:00:00+00', '2024-11-25 15:00:00+00'),
('CC012', 'Data & Analytics',     'liam.nguyen@company.local',    'active',   '2023-06-01 09:00:00+00', '2024-12-01 10:00:00+00'),
('CC013', 'Supply Chain',         'maya.johansson@company.local', 'active',   '2023-01-15 09:00:00+00', '2024-08-15 08:00:00+00'),
('CC014', 'Facilities',           'noah.al-amin@company.local',   'inactive', '2023-01-15 09:00:00+00', '2024-07-01 09:00:00+00'),
('CC015', 'Executive Office',     'olivia.brennan@company.local', 'active',   '2023-01-15 09:00:00+00', '2024-12-15 17:00:00+00');


-- ============================================================
-- finance.budget_targets  (~30 rows)
-- ============================================================
CREATE TABLE finance.budget_targets (
    id            SERIAL       PRIMARY KEY,
    year          INTEGER      NOT NULL,
    quarter       CHAR(2)      NOT NULL CHECK (quarter IN ('Q1','Q2','Q3','Q4')),
    department    VARCHAR(100) NOT NULL,
    target_amount NUMERIC(14,2) NOT NULL,
    owner         VARCHAR(150),
    updated_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

INSERT INTO finance.budget_targets (year, quarter, department, target_amount, owner, updated_at) VALUES
-- 2024
(2024,'Q1','Engineering',        1800000.00, 'alice.chen@company.local',     '2024-01-10 09:00:00+00'),
(2024,'Q1','Sales - North America',3500000.00,'carol.thompson@company.local','2024-01-10 09:00:00+00'),
(2024,'Q1','Marketing',           850000.00, 'frank.osei@company.local',     '2024-01-10 09:00:00+00'),
(2024,'Q1','IT Operations',       420000.00, 'james.okonkwo@company.local',  '2024-01-10 09:00:00+00'),
(2024,'Q2','Engineering',        1900000.00, 'alice.chen@company.local',     '2024-04-05 09:00:00+00'),
(2024,'Q2','Sales - North America',3800000.00,'carol.thompson@company.local','2024-04-05 09:00:00+00'),
(2024,'Q2','Marketing',           920000.00, 'frank.osei@company.local',     '2024-04-05 09:00:00+00'),
(2024,'Q2','Customer Success',    310000.00, 'kate.silva@company.local',     '2024-04-05 09:00:00+00'),
(2024,'Q3','Engineering',        1950000.00, 'alice.chen@company.local',     '2024-07-03 09:00:00+00'),
(2024,'Q3','Sales - EMEA',       2100000.00, 'david.patel@company.local',    '2024-07-03 09:00:00+00'),
(2024,'Q3','Marketing',           980000.00, 'frank.osei@company.local',     '2024-07-03 09:00:00+00'),
(2024,'Q3','Data & Analytics',    270000.00, 'liam.nguyen@company.local',    '2024-07-03 09:00:00+00'),
(2024,'Q4','Engineering',        2100000.00, 'alice.chen@company.local',     '2024-10-02 09:00:00+00'),
(2024,'Q4','Sales - North America',4200000.00,'carol.thompson@company.local','2024-10-02 09:00:00+00'),
(2024,'Q4','Marketing',          1150000.00, 'frank.osei@company.local',     '2024-10-02 09:00:00+00'),
(2024,'Q4','Human Resources',     380000.00, 'grace.kim@company.local',      '2024-10-02 09:00:00+00'),
-- 2025
(2025,'Q1','Engineering',        2200000.00, 'alice.chen@company.local',     '2025-01-08 09:00:00+00'),
(2025,'Q1','Sales - North America',4000000.00,'carol.thompson@company.local','2025-01-08 09:00:00+00'),
(2025,'Q1','Sales - EMEA',       2400000.00, 'david.patel@company.local',    '2025-01-08 09:00:00+00'),
(2025,'Q1','Marketing',          1050000.00, 'frank.osei@company.local',     '2025-01-08 09:00:00+00'),
(2025,'Q2','Engineering',        2300000.00, 'alice.chen@company.local',     '2025-04-04 09:00:00+00'),
(2025,'Q2','Sales - APAC',       1800000.00, 'emily.wong@company.local',     '2025-04-04 09:00:00+00'),
(2025,'Q2','Marketing',          1100000.00, 'frank.osei@company.local',     '2025-04-04 09:00:00+00'),
(2025,'Q2','Customer Success',    360000.00, 'kate.silva@company.local',     '2025-04-04 09:00:00+00'),
(2025,'Q3','Engineering',        2350000.00, 'alice.chen@company.local',     '2025-07-02 09:00:00+00'),
(2025,'Q3','Sales - North America',4500000.00,'carol.thompson@company.local','2025-07-02 09:00:00+00'),
(2025,'Q3','Data & Analytics',    320000.00, 'liam.nguyen@company.local',    '2025-07-02 09:00:00+00'),
(2025,'Q4','Engineering',        2500000.00, 'alice.chen@company.local',     '2025-10-01 09:00:00+00'),
(2025,'Q4','Sales - EMEA',       2800000.00, 'david.patel@company.local',    '2025-10-01 09:00:00+00'),
(2025,'Q4','Human Resources',     420000.00, 'grace.kim@company.local',      '2025-10-01 09:00:00+00');


-- ============================================================
-- sales.regional_targets  (~20 rows)
-- ============================================================
CREATE TABLE sales.regional_targets (
    id               SERIAL        PRIMARY KEY,
    region           VARCHAR(50)   NOT NULL,
    quarter          CHAR(2)       NOT NULL CHECK (quarter IN ('Q1','Q2','Q3','Q4')),
    year             INTEGER       NOT NULL,
    target_revenue   NUMERIC(14,2) NOT NULL,
    achieved_revenue NUMERIC(14,2),
    updated_at       TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

INSERT INTO sales.regional_targets (region, quarter, year, target_revenue, achieved_revenue, updated_at) VALUES
('North America', 'Q1', 2024, 3500000.00, 3421800.00, '2024-04-05 09:00:00+00'),
('North America', 'Q2', 2024, 3800000.00, 3975200.00, '2024-07-08 09:00:00+00'),
('North America', 'Q3', 2024, 4000000.00, 3880500.00, '2024-10-07 09:00:00+00'),
('North America', 'Q4', 2024, 4200000.00, 4510000.00, '2025-01-10 09:00:00+00'),
('EMEA',          'Q1', 2024, 2100000.00, 1980000.00, '2024-04-05 09:00:00+00'),
('EMEA',          'Q2', 2024, 2300000.00, 2450000.00, '2024-07-08 09:00:00+00'),
('EMEA',          'Q3', 2024, 2100000.00, 2050000.00, '2024-10-07 09:00:00+00'),
('EMEA',          'Q4', 2024, 2400000.00, 2380000.00, '2025-01-10 09:00:00+00'),
('APAC',          'Q1', 2024, 1600000.00, 1540000.00, '2024-04-05 09:00:00+00'),
('APAC',          'Q2', 2024, 1700000.00, 1810000.00, '2024-07-08 09:00:00+00'),
('APAC',          'Q3', 2024, 1800000.00, 1750000.00, '2024-10-07 09:00:00+00'),
('APAC',          'Q4', 2024, 1900000.00, 2010000.00, '2025-01-10 09:00:00+00'),
('LATAM',         'Q1', 2024,  620000.00,  580000.00, '2024-04-05 09:00:00+00'),
('LATAM',         'Q2', 2024,  680000.00,  710000.00, '2024-07-08 09:00:00+00'),
('LATAM',         'Q3', 2024,  700000.00,  665000.00, '2024-10-07 09:00:00+00'),
('LATAM',         'Q4', 2024,  750000.00,  790000.00, '2025-01-10 09:00:00+00'),
('North America', 'Q1', 2025, 4000000.00, NULL,       '2025-01-08 09:00:00+00'),
('EMEA',          'Q1', 2025, 2400000.00, NULL,       '2025-01-08 09:00:00+00'),
('APAC',          'Q1', 2025, 1800000.00, NULL,       '2025-01-08 09:00:00+00'),
('LATAM',         'Q1', 2025,  750000.00, NULL,       '2025-01-08 09:00:00+00');


-- ============================================================
-- sales.partner_commissions  (~10 rows)
-- ============================================================
CREATE TABLE sales.partner_commissions (
    id              SERIAL       PRIMARY KEY,
    partner_name    VARCHAR(150) NOT NULL,
    commission_rate NUMERIC(5,4) NOT NULL,
    effective_date  DATE         NOT NULL,
    status          VARCHAR(20)  NOT NULL DEFAULT 'active'
                        CHECK (status IN ('active','inactive','pending')),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

INSERT INTO sales.partner_commissions (partner_name, commission_rate, effective_date, status, updated_at) VALUES
('Apex Solutions Ltd',      0.0400, '2023-01-01', 'active',   '2024-06-01 09:00:00+00'),
('BlueRidge Partners',      0.0350, '2023-03-01', 'active',   '2024-09-15 09:00:00+00'),
('Clearview Consulting',    0.0300, '2023-01-01', 'active',   '2024-03-20 09:00:00+00'),
('Delta Force Technologies',0.0450, '2023-06-01', 'active',   '2024-11-01 09:00:00+00'),
('Everest Global Group',    0.0250, '2022-07-01', 'inactive', '2024-01-10 09:00:00+00'),
('Forte Channel Advisors',  0.0375, '2023-09-01', 'active',   '2024-10-05 09:00:00+00'),
('Granite Systems Co.',     0.0320, '2024-01-01', 'active',   '2024-12-01 09:00:00+00'),
('Harbor View Associates',  0.0280, '2024-03-01', 'pending',  '2025-01-15 09:00:00+00'),
('Ironclad Resellers',      0.0500, '2022-01-01', 'active',   '2024-07-20 09:00:00+00'),
('Junction Point LLC',      0.0410, '2024-06-01', 'active',   '2024-12-10 09:00:00+00');


-- ============================================================
-- operations.vendor_master  (~25 rows)
-- ============================================================
CREATE TABLE operations.vendor_master (
    vendor_id     VARCHAR(10)  PRIMARY KEY,
    name          VARCHAR(150) NOT NULL,
    category      VARCHAR(50),
    status        VARCHAR(20)  NOT NULL DEFAULT 'active'
                      CHECK (status IN ('active','inactive','on_hold')),
    contact_email VARCHAR(150),
    contact_phone VARCHAR(30),
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

INSERT INTO operations.vendor_master (vendor_id, name, category, status, contact_email, contact_phone, created_at, updated_at) VALUES
('V001', 'Pinnacle Cloud Services',    'IT',           'active',   'billing@pinnaclecloud.local',   '+1-555-0101', '2022-03-01 09:00:00+00', '2024-11-20 09:00:00+00'),
('V002', 'TechArch Infrastructure',    'IT',           'active',   'support@techarch.local',        '+1-555-0102', '2022-03-01 09:00:00+00', '2024-10-15 09:00:00+00'),
('V003', 'Meridian Office Supplies',   'Facilities',   'active',   'orders@meridianoffice.local',   '+1-555-0103', '2022-04-01 09:00:00+00', '2024-09-30 09:00:00+00'),
('V004', 'Cascade Facilities Mgmt',    'Facilities',   'active',   'service@cascadefm.local',       '+1-555-0104', '2022-04-01 09:00:00+00', '2024-12-01 09:00:00+00'),
('V005', 'Vantage Print & Media',      'Marketing',    'active',   'sales@vantageprint.local',      '+1-555-0105', '2022-05-01 09:00:00+00', '2024-08-20 09:00:00+00'),
('V006', 'Brightline Events Co.',      'Marketing',    'active',   'events@brightline.local',       '+1-555-0106', '2022-05-01 09:00:00+00', '2024-11-05 09:00:00+00'),
('V007', 'SwiftRoute Logistics',       'Logistics',    'active',   'dispatch@swiftroute.local',     '+1-555-0107', '2022-06-01 09:00:00+00', '2024-12-10 09:00:00+00'),
('V008', 'Summit Freight Solutions',   'Logistics',    'active',   'ops@summitfreight.local',       '+1-555-0108', '2022-06-01 09:00:00+00', '2024-10-01 09:00:00+00'),
('V009', 'Crestline Legal Advisors',   'Legal',        'active',   'matters@crestlinelegal.local',  '+1-555-0109', '2022-07-01 09:00:00+00', '2024-09-15 09:00:00+00'),
('V010', 'Northern Trust Auditors',    'Finance',      'active',   'audit@northerntrust.local',     '+1-555-0110', '2022-07-01 09:00:00+00', '2024-11-30 09:00:00+00'),
('V011', 'Redwood Staffing Group',     'HR',           'active',   'placements@redwoodstaffing.local','+1-555-0111','2022-08-01 09:00:00+00', '2024-07-10 09:00:00+00'),
('V012', 'Nexus Security Systems',     'Security',     'active',   'contracts@nexussec.local',      '+1-555-0112', '2022-08-01 09:00:00+00', '2024-12-05 09:00:00+00'),
('V013', 'Orion Hardware Supplies',    'IT',           'on_hold',  'sales@orionhw.local',           '+1-555-0113', '2022-09-01 09:00:00+00', '2024-06-01 09:00:00+00'),
('V014', 'Pacific Catering Services',  'Facilities',   'active',   'hello@pacificcatering.local',   '+1-555-0114', '2022-09-01 09:00:00+00', '2024-11-15 09:00:00+00'),
('V015', 'Horizon Data Backup Inc.',   'IT',           'active',   'support@horizonbackup.local',   '+1-555-0115', '2022-10-01 09:00:00+00', '2024-12-01 09:00:00+00'),
('V016', 'Sterling Travel Management', 'Travel',       'active',   'corporate@sterlingtravel.local','+1-555-0116', '2022-10-01 09:00:00+00', '2024-10-20 09:00:00+00'),
('V017', 'Cobalt Analytics Platform',  'IT',           'active',   'billing@cobaltanalytics.local', '+1-555-0117', '2022-11-01 09:00:00+00', '2024-12-15 09:00:00+00'),
('V018', 'Ember Cleaning Services',    'Facilities',   'active',   'service@embercleaning.local',   '+1-555-0118', '2022-11-01 09:00:00+00', '2024-08-30 09:00:00+00'),
('V019', 'Falcon Courier Express',     'Logistics',    'inactive', 'ops@falconcourier.local',       '+1-555-0119', '2022-12-01 09:00:00+00', '2024-05-01 09:00:00+00'),
('V020', 'Granite IT Consulting',      'IT',           'active',   'projects@graniteitc.local',     '+1-555-0120', '2023-01-01 09:00:00+00', '2024-11-01 09:00:00+00'),
('V021', 'Harbor Printing Group',      'Marketing',    'active',   'orders@harborprinting.local',   '+1-555-0121', '2023-02-01 09:00:00+00', '2024-09-05 09:00:00+00'),
('V022', 'Ironwood Furniture Co.',     'Facilities',   'active',   'sales@ironwoodfurniture.local', '+1-555-0122', '2023-03-01 09:00:00+00', '2024-07-20 09:00:00+00'),
('V023', 'Jade Software Licensing',    'IT',           'active',   'licensing@jadesoftware.local',  '+1-555-0123', '2023-04-01 09:00:00+00', '2024-12-10 09:00:00+00'),
('V024', 'Keystone Insurance Group',   'Finance',      'active',   'corporate@keystoneins.local',   '+1-555-0124', '2023-05-01 09:00:00+00', '2024-10-30 09:00:00+00'),
('V025', 'Lighthouse Training Ltd.',   'HR',           'active',   'training@lighthousetraining.local','+1-555-0125','2023-06-01 09:00:00+00','2024-12-01 09:00:00+00');


-- ============================================================
-- operations.maintenance_schedules  (~15 rows)
-- ============================================================
CREATE TABLE operations.maintenance_schedules (
    id             SERIAL       PRIMARY KEY,
    equipment_id   VARCHAR(20)  NOT NULL,
    frequency_days INTEGER      NOT NULL,
    last_done      DATE,
    next_due       DATE,
    owner          VARCHAR(150),
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

INSERT INTO operations.maintenance_schedules (equipment_id, frequency_days, last_done, next_due, owner, created_at, updated_at) VALUES
('HVAC-BLDGA-01',  90,  '2024-10-15', '2025-01-13', 'noah.al-amin@company.local',  '2022-01-01 09:00:00+00', '2024-10-15 12:00:00+00'),
('HVAC-BLDGA-02',  90,  '2024-10-15', '2025-01-13', 'noah.al-amin@company.local',  '2022-01-01 09:00:00+00', '2024-10-15 12:00:00+00'),
('HVAC-BLDGB-01',  90,  '2024-11-01', '2025-01-30', 'noah.al-amin@company.local',  '2022-01-01 09:00:00+00', '2024-11-01 14:00:00+00'),
('ELEV-BLDGA-01',  180, '2024-07-20', '2025-01-16', 'noah.al-amin@company.local',  '2022-01-01 09:00:00+00', '2024-07-20 10:00:00+00'),
('ELEV-BLDGB-01',  180, '2024-08-10', '2025-02-06', 'noah.al-amin@company.local',  '2022-01-01 09:00:00+00', '2024-08-10 10:00:00+00'),
('GEN-MAIN-01',    30,  '2024-12-05', '2025-01-04', 'james.okonkwo@company.local', '2022-06-01 09:00:00+00', '2024-12-05 09:00:00+00'),
('GEN-BACKUP-01',  60,  '2024-11-18', '2025-01-17', 'james.okonkwo@company.local', '2022-06-01 09:00:00+00', '2024-11-18 09:00:00+00'),
('SRV-RACK-01',    365, '2024-03-01', '2025-03-01', 'james.okonkwo@company.local', '2022-01-01 09:00:00+00', '2024-03-01 11:00:00+00'),
('SRV-RACK-02',    365, '2024-03-01', '2025-03-01', 'james.okonkwo@company.local', '2022-01-01 09:00:00+00', '2024-03-01 11:00:00+00'),
('FIRE-BLDGA',     180, '2024-06-15', '2024-12-12', 'noah.al-amin@company.local',  '2022-01-01 09:00:00+00', '2024-06-15 09:00:00+00'),
('FIRE-BLDGB',     180, '2024-06-20', '2024-12-17', 'noah.al-amin@company.local',  '2022-01-01 09:00:00+00', '2024-06-20 09:00:00+00'),
('UPS-MAIN-01',    90,  '2024-09-30', '2024-12-29', 'james.okonkwo@company.local', '2023-01-01 09:00:00+00', '2024-09-30 14:00:00+00'),
('CCTV-SYS-01',    365, '2024-05-01', '2025-05-01', 'noah.al-amin@company.local',  '2022-01-01 09:00:00+00', '2024-05-01 10:00:00+00'),
('VEHICLE-01',     45,  '2024-12-01', '2025-01-15', 'maya.johansson@company.local','2023-03-01 09:00:00+00', '2024-12-01 09:00:00+00'),
('VEHICLE-02',     45,  '2024-11-20', '2025-01-04', 'maya.johansson@company.local','2023-03-01 09:00:00+00', '2024-11-20 09:00:00+00');


-- ============================================================
-- Finalize permissions
-- ============================================================

-- nocodb_user: full access to all tables in all schemas
GRANT ALL PRIVILEGES ON ALL TABLES    IN SCHEMA finance    TO nocodb_user;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA finance    TO nocodb_user;
GRANT ALL PRIVILEGES ON ALL TABLES    IN SCHEMA sales      TO nocodb_user;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA sales      TO nocodb_user;
GRANT ALL PRIVILEGES ON ALL TABLES    IN SCHEMA operations TO nocodb_user;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA operations TO nocodb_user;

-- nocodb_user: inherit access on future tables
ALTER DEFAULT PRIVILEGES IN SCHEMA finance    GRANT ALL ON TABLES    TO nocodb_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA finance    GRANT ALL ON SEQUENCES TO nocodb_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA sales      GRANT ALL ON TABLES    TO nocodb_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA sales      GRANT ALL ON SEQUENCES TO nocodb_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA operations GRANT ALL ON TABLES    TO nocodb_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA operations GRANT ALL ON SEQUENCES TO nocodb_user;

-- etl_reader: SELECT only on all tables
GRANT SELECT ON ALL TABLES IN SCHEMA finance    TO etl_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA sales      TO etl_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA operations TO etl_reader;

-- etl_reader: inherit SELECT on future tables
ALTER DEFAULT PRIVILEGES IN SCHEMA finance    GRANT SELECT ON TABLES TO etl_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA sales      GRANT SELECT ON TABLES TO etl_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA operations GRANT SELECT ON TABLES TO etl_reader;
