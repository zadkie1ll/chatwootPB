#!/usr/bin/env bash
set -euo pipefail
psql --username "$POSTGRES_USER" --dbname postgres --set=ON_ERROR_STOP=1 <<'SQL'
\getenv integration_password INTEGRATION_DB_PASSWORD
CREATE ROLE integration LOGIN PASSWORD :'integration_password' NOSUPERUSER NOCREATEDB NOCREATEROLE;
CREATE DATABASE integration_lab OWNER integration;
REVOKE ALL ON DATABASE integration_lab FROM PUBLIC;
SQL
