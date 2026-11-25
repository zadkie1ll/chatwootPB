#!/usr/bin/env bash
set -euo pipefail
# Run only on the first initialization of the dedicated lab volume.
# Password passed over psql stdin, never printed or placed in a command argument.
psql --username "$POSTGRES_USER" --dbname postgres --set=ON_ERROR_STOP=1 <<'SQL'
\getenv app_password CW_DATABASE_PASSWORD
CREATE ROLE chatwoot LOGIN PASSWORD :'app_password' NOSUPERUSER NOCREATEDB NOCREATEROLE;
CREATE DATABASE chatwoot_lab OWNER chatwoot;
REVOKE ALL ON DATABASE chatwoot_lab FROM PUBLIC;
SQL
psql --username "$POSTGRES_USER" --dbname chatwoot_lab --set=ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS vector;
SQL
