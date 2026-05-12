-- One-shot Windows portable init script.
-- Variables passed via psql -v: nocodb_user, nocodb_pw, etl_user, etl_pw.

-- 1. Databases
CREATE DATABASE nocodb_meta;
CREATE DATABASE business_inputs;

-- 2. Users
CREATE USER :nocodb_user WITH PASSWORD :'nocodb_pw';
GRANT ALL PRIVILEGES ON DATABASE nocodb_meta      TO :nocodb_user;
GRANT ALL PRIVILEGES ON DATABASE business_inputs  TO :nocodb_user;

CREATE USER :etl_user WITH PASSWORD :'etl_pw';
GRANT CONNECT ON DATABASE business_inputs TO :etl_user;

-- 3. Public schema grants (PostgreSQL 15+ requires explicit GRANT)
\c nocodb_meta
GRANT ALL ON SCHEMA public TO :nocodb_user;

\c business_inputs
GRANT CREATE ON DATABASE business_inputs TO :nocodb_user;
GRANT ALL ON SCHEMA public TO :nocodb_user;
