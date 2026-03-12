#!/usr/bin/env bash
# =============================================================================
# PostgreSQL initialization script
# Creates all service databases and per-service users with least-privilege.
# This script runs automatically via /docker-entrypoint-initdb.d/ on first boot.
# =============================================================================
set -euo pipefail

log() { echo "[init-databases] $*"; }

create_db_and_user() {
    local db="$1"
    local user="$2"
    local password="$3"

    log "Creating database '${db}' and user '${user}'..."

    psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname postgres <<-EOSQL
        DO \$\$
        BEGIN
            IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${user}') THEN
                CREATE ROLE ${user} WITH LOGIN PASSWORD '${password}';
            END IF;
        END
        \$\$;

        SELECT 'CREATE DATABASE ${db} OWNER ${user}'
        WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${db}')
        \gexec

        GRANT ALL PRIVILEGES ON DATABASE ${db} TO ${user};
        ALTER DATABASE ${db} OWNER TO ${user};
EOSQL
}

log "Starting database initialization..."

# Keycloak
create_db_and_user \
    "${KEYCLOAK_DB:-keycloak}" \
    "${KEYCLOAK_DB_USER:-keycloak_user}" \
    "${KEYCLOAK_DB_PASSWORD:?KEYCLOAK_DB_PASSWORD not set}"

# Apache Polaris
create_db_and_user \
    "${POLARIS_DB:-polaris}" \
    "${POLARIS_DB_USER:-polaris_user}" \
    "${POLARIS_DB_PASSWORD:?POLARIS_DB_PASSWORD not set}"

# Project Nessie
create_db_and_user \
    "${NESSIE_DB:-nessie}" \
    "${NESSIE_DB_USER:-nessie_user}" \
    "${NESSIE_DB_PASSWORD:?NESSIE_DB_PASSWORD not set}"

# Apache Ranger
create_db_and_user \
    "${RANGER_DB:-ranger}" \
    "${RANGER_DB_USER:-ranger_user}" \
    "${RANGER_DB_PASSWORD:?RANGER_DB_PASSWORD not set}"

# Apache Airflow
create_db_and_user \
    "${AIRFLOW_DB:-airflow}" \
    "${AIRFLOW_DB_USER:-airflow_user}" \
    "${AIRFLOW_DB_PASSWORD:?AIRFLOW_DB_PASSWORD not set}"

# OpenMetadata
create_db_and_user \
    "${OPENMETADATA_DB:-openmetadata}" \
    "${OPENMETADATA_DB_USER:-openmetadata_user}" \
    "${OPENMETADATA_DB_PASSWORD:?OPENMETADATA_DB_PASSWORD not set}"

# Trino Gateway (uses its own DB for state)
create_db_and_user \
    "trino_gateway" \
    "${TRINO_GATEWAY_DB_USER:-trino_gw_user}" \
    "${TRINO_GATEWAY_DB_PASSWORD:?TRINO_GATEWAY_DB_PASSWORD not set}"

log "All databases and users created successfully."
