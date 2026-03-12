#!/usr/bin/env bash
# =============================================================================
# 01-init-openbao.sh — Initialize OpenBao Raft cluster
# =============================================================================
# Steps:
#   1. Wait for openbao-1 to be reachable
#   2. Initialize the Raft cluster (generates unseal keys + root token)
#   3. Unseal all 3 nodes
#   4. Enable auth methods: token, approle
#   5. Enable secrets engines: KV v2, PKI
#   6. Write ALL service secrets to KV v2
#   7. Create per-service AppRole credentials
#   8. Apply all policies from volumes/openbao/policies/
#
# Prerequisites:
#   - docker compose up -d openbao-{1,2,3}
#   - All 3 nodes must show "service_healthy" before running this script
#   - Run from project root or set REPO_ROOT
#
# WARNING: This script writes secret material to .openbao-init-output.json.
#          Add that file to .gitignore and delete it after securely storing the
#          unseal keys and root token.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
ENV_FILE="${REPO_ROOT}/local/.env"

log()  { echo "[01-init-openbao] $*"; }
ok()   { echo "[01-init-openbao] ✓ $*"; }
err()  { echo "[01-init-openbao] ✗ $*" >&2; exit 1; }

# ─── Load .env ────────────────────────────────────────────────────────────────
[ -f "${ENV_FILE}" ] || err ".env file not found at ${ENV_FILE}. Copy .env.example and fill secrets."
# shellcheck disable=SC1090
set -a; source "${ENV_FILE}"; set +a

OPENBAO_ADDR="${OPENBAO_ADDR:-http://localhost:8200}"
INIT_OUTPUT="${REPO_ROOT}/.openbao-init-output.json"

export BAO_ADDR="${OPENBAO_ADDR}"
export BAO_SKIP_VERIFY="true"

command -v jq  >/dev/null || err "jq is required. Install with: brew install jq / apt install jq"
command -v bao >/dev/null || {
    # Try via docker exec if bao CLI not available locally
    BAO="docker compose -f ${REPO_ROOT}/local/docker-compose.yml exec -T openbao-1 bao"
    log "bao CLI not found locally — will use 'docker compose exec'"
}
BAO="${BAO:-bao}"

# ─── Step 1: Wait for openbao-1 ───────────────────────────────────────────────
log "Waiting for OpenBao API at ${OPENBAO_ADDR}..."
for i in $(seq 1 30); do
    if curl -sf "${OPENBAO_ADDR}/v1/sys/health" &>/dev/null; then
        ok "OpenBao API is reachable."
        break
    fi
    [ "$i" -eq 30 ] && err "Timeout waiting for OpenBao. Is the container running?"
    sleep 5
done

# ─── Step 2: Check if already initialized ─────────────────────────────────────
INITIALIZED=$(curl -sf "${OPENBAO_ADDR}/v1/sys/health" | jq -r '.initialized // false')
if [ "${INITIALIZED}" = "true" ]; then
    log "OpenBao already initialized."
    if [ -f "${INIT_OUTPUT}" ]; then
        ROOT_TOKEN=$(jq -r '.root_token' "${INIT_OUTPUT}")
        UNSEAL_KEY_1=$(jq -r '.unseal_keys_b64[0]' "${INIT_OUTPUT}")
        UNSEAL_KEY_2=$(jq -r '.unseal_keys_b64[1]' "${INIT_OUTPUT}")
        UNSEAL_KEY_3=$(jq -r '.unseal_keys_b64[2]' "${INIT_OUTPUT}")
        log "Loaded keys from ${INIT_OUTPUT}."
    else
        err "OpenBao is initialized but ${INIT_OUTPUT} not found. Provide root token manually."
    fi
else
    # ─── Step 2a: Initialize ────────────────────────────────────────────────────
    log "Initializing OpenBao Raft cluster..."
    INIT_RESPONSE=$(curl -sf -X POST "${OPENBAO_ADDR}/v1/sys/init" \
        -H "Content-Type: application/json" \
        -d '{"secret_shares": 5, "secret_threshold": 3}')

    echo "${INIT_RESPONSE}" > "${INIT_OUTPUT}"
    chmod 600 "${INIT_OUTPUT}"

    ROOT_TOKEN=$(echo "${INIT_RESPONSE}"   | jq -r '.root_token')
    UNSEAL_KEY_1=$(echo "${INIT_RESPONSE}" | jq -r '.keys_base64[0]')
    UNSEAL_KEY_2=$(echo "${INIT_RESPONSE}" | jq -r '.keys_base64[1]')
    UNSEAL_KEY_3=$(echo "${INIT_RESPONSE}" | jq -r '.keys_base64[2]')

    ok "OpenBao initialized. Init output saved to ${INIT_OUTPUT}"
    log "IMPORTANT: Backup ${INIT_OUTPUT} securely and delete it from this server!"
fi

export BAO_TOKEN="${ROOT_TOKEN}"

# ─── Step 3: Unseal all 3 nodes ───────────────────────────────────────────────
unseal_node() {
    local node_url="$1"
    log "Unsealing ${node_url}..."

    SEALED=$(curl -sf "${node_url}/v1/sys/health" | jq -r '.sealed // true')
    if [ "${SEALED}" = "false" ]; then
        ok "${node_url} already unsealed."
        return
    fi

    for key in "${UNSEAL_KEY_1}" "${UNSEAL_KEY_2}" "${UNSEAL_KEY_3}"; do
        curl -sf -X POST "${node_url}/v1/sys/unseal" \
            -H "Content-Type: application/json" \
            -d "{\"key\": \"${key}\"}" > /dev/null
    done
    ok "${node_url} unsealed."
}

# Replace localhost with Docker service names for inter-cluster unseal
OPENBAO_1_ADDR="${OPENBAO_ADDR}"
OPENBAO_2_ADDR="${OPENBAO_ADDR/openbao-1/openbao-2}"
OPENBAO_3_ADDR="${OPENBAO_ADDR/openbao-1/openbao-3}"

# For local execution, all nodes are accessible via their published ports
# openbao-1: 8200 (default), openbao-2: mapped in compose, etc.
# If running locally (not inside Docker), use localhost with port mapping offsets.
if echo "${OPENBAO_ADDR}" | grep -q "localhost"; then
    OPENBAO_1_ADDR="http://localhost:8200"
    OPENBAO_2_ADDR="http://localhost:8201"  # If individual ports mapped
    OPENBAO_3_ADDR="http://localhost:8202"
fi

unseal_node "${OPENBAO_1_ADDR}"
# Wait for raft cluster join before unsealing followers
sleep 5
unseal_node "${OPENBAO_2_ADDR}" 2>/dev/null || log "openbao-2 not yet reachable (ok if using shared port)"
unseal_node "${OPENBAO_3_ADDR}" 2>/dev/null || log "openbao-3 not yet reachable (ok if using shared port)"

# ─── Step 4: Enable secrets engines ───────────────────────────────────────────
log "Enabling KV v2 secrets engine at 'secret/'..."
curl -sf -X POST "${OPENBAO_ADDR}/v1/sys/mounts/secret" \
    -H "X-Vault-Token: ${ROOT_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"type": "kv", "options": {"version": "2"}}' > /dev/null 2>&1 || true
ok "KV v2 engine enabled."

log "Enabling PKI secrets engine at 'pki/'..."
curl -sf -X POST "${OPENBAO_ADDR}/v1/sys/mounts/pki" \
    -H "X-Vault-Token: ${ROOT_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"type": "pki", "config": {"max_lease_ttl": "8760h"}}' > /dev/null 2>&1 || true
ok "PKI engine enabled."

log "Enabling AppRole auth method..."
curl -sf -X POST "${OPENBAO_ADDR}/v1/sys/auth/approle" \
    -H "X-Vault-Token: ${ROOT_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"type": "approle"}' > /dev/null 2>&1 || true
ok "AppRole auth enabled."

# ─── Step 5: Apply policies ────────────────────────────────────────────────────
POLICY_DIR="${REPO_ROOT}/local/volumes/openbao/policies"
for policy_file in "${POLICY_DIR}"/*.hcl; do
    policy_name=$(basename "${policy_file}" .hcl)
    log "Applying policy '${policy_name}'..."
    policy_content=$(cat "${policy_file}")
    curl -sf -X PUT "${OPENBAO_ADDR}/v1/sys/policies/acl/${policy_name}" \
        -H "X-Vault-Token: ${ROOT_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"policy\": $(echo "${policy_content}" | jq -Rs .)}" > /dev/null
    ok "Policy '${policy_name}' applied."
done

# ─── Step 6: Write service secrets ────────────────────────────────────────────
write_secret() {
    local path="$1"
    local json="$2"
    log "Writing secret at 'secret/${path}'..."
    curl -sf -X POST "${OPENBAO_ADDR}/v1/secret/data/${path}" \
        -H "X-Vault-Token: ${ROOT_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"data\": ${json}}" > /dev/null
}

# PostgreSQL credentials (per service)
write_secret "postgresql/keycloak"     '{"db": "'"${KEYCLOAK_DB}"'", "user": "'"${KEYCLOAK_DB_USER}"'", "password": "'"${KEYCLOAK_DB_PASSWORD}"'"}'
write_secret "postgresql/polaris"      '{"db": "'"${POLARIS_DB}"'", "user": "'"${POLARIS_DB_USER}"'", "password": "'"${POLARIS_DB_PASSWORD}"'"}'
write_secret "postgresql/nessie"       '{"db": "'"${NESSIE_DB}"'", "user": "'"${NESSIE_DB_USER}"'", "password": "'"${NESSIE_DB_PASSWORD}"'"}'
write_secret "postgresql/ranger"       '{"db": "'"${RANGER_DB}"'", "user": "'"${RANGER_DB_USER}"'", "password": "'"${RANGER_DB_PASSWORD}"'"}'
write_secret "postgresql/airflow"      '{"db": "'"${AIRFLOW_DB}"'", "user": "'"${AIRFLOW_DB_USER}"'", "password": "'"${AIRFLOW_DB_PASSWORD}"'"}'
write_secret "postgresql/openmetadata" '{"db": "'"${OPENMETADATA_DB}"'", "user": "'"${OPENMETADATA_DB_USER}"'", "password": "'"${OPENMETADATA_DB_PASSWORD}"'"}'

# MinIO credentials
write_secret "minio/root"       '{"access_key": "'"${MINIO_ROOT_USER}"'", "secret_key": "'"${MINIO_ROOT_PASSWORD}"'"}'
write_secret "minio/polaris"    '{"access_key": "'"${MINIO_POLARIS_ACCESS_KEY}"'", "secret_key": "'"${MINIO_POLARIS_SECRET_KEY}"'"}'
write_secret "minio/ingestion"  '{"access_key": "'"${MINIO_INGESTION_ACCESS_KEY}"'", "secret_key": "'"${MINIO_INGESTION_SECRET_KEY}"'"}'
write_secret "minio/audit"      '{"access_key": "'"${MINIO_AUDIT_ACCESS_KEY}"'", "secret_key": "'"${MINIO_AUDIT_SECRET_KEY}"'"}'

# Polaris
write_secret "polaris/admin"        '{"client_id": "'"${POLARIS_BOOTSTRAP_ADMIN_CLIENT_ID}"'", "client_secret": "'"${POLARIS_BOOTSTRAP_ADMIN_SECRET}"'"}'
write_secret "polaris/trino-svc"    '{"client_id": "'"${POLARIS_TRINO_CLIENT_ID}"'", "client_secret": "'"${POLARIS_TRINO_CLIENT_SECRET}"'"}'
write_secret "polaris/airflow-svc"  '{"client_id": "'"${POLARIS_AIRFLOW_CLIENT_ID}"'", "client_secret": "'"${POLARIS_AIRFLOW_CLIENT_SECRET}"'"}'

# Trino
write_secret "trino/internal"   '{"shared_secret": "'"${TRINO_INTERNAL_SHARED_SECRET}"'"}'

# Ranger
write_secret "ranger/admin"     '{"password": "'"${RANGER_ADMIN_PASSWORD}"'"}'

# Airflow
write_secret "airflow/fernet"   '{"fernet_key": "'"${AIRFLOW_FERNET_KEY}"'", "secret_key": "'"${AIRFLOW_SECRET_KEY}"'"}'
write_secret "airflow/admin"    '{"user": "'"${AIRFLOW_ADMIN_USER}"'", "password": "'"${AIRFLOW_ADMIN_PASSWORD}"'"}'

# Keycloak
write_secret "keycloak/admin"   '{"user": "'"${KEYCLOAK_ADMIN}"'", "password": "'"${KEYCLOAK_ADMIN_PASSWORD}"'"}'
write_secret "keycloak/clients" '{
    "trino": "'"${KEYCLOAK_TRINO_CLIENT_SECRET}"'",
    "airflow": "'"${KEYCLOAK_AIRFLOW_CLIENT_SECRET}"'",
    "openmetadata": "'"${KEYCLOAK_OPENMETADATA_CLIENT_SECRET}"'",
    "grafana": "'"${KEYCLOAK_GRAFANA_CLIENT_SECRET}"'",
    "minio": "'"${KEYCLOAK_MINIO_CLIENT_SECRET}"'"
}'

# Grafana
write_secret "grafana/admin"    '{"user": "'"${GRAFANA_ADMIN_USER}"'", "password": "'"${GRAFANA_ADMIN_PASSWORD}"'", "secret_key": "'"${GRAFANA_SECRET_KEY}"'"}'

# Nessie
write_secret "nessie/auth"      '{"bearer_token": "'"${NESSIE_AUTH_TOKEN}"'"}'

# Docling
write_secret "docling/api"      '{"api_key": "'"${DOCLING_API_KEY}"'"}'

# Redis
write_secret "redis/auth"       '{"password": "'"${REDIS_PASSWORD}"'"}'

# Elasticsearch
write_secret "elasticsearch/auth" '{"password": "'"${ELASTIC_PASSWORD}"'"}'

ok "All secrets written to OpenBao KV v2."

# ─── Step 7: Create AppRole credentials (one per service) ─────────────────────
create_approle() {
    local service="$1"
    local policies="$2"  # comma-separated policy names

    log "Creating AppRole for '${service}'..."
    # Create role
    curl -sf -X POST "${OPENBAO_ADDR}/v1/auth/approle/role/${service}" \
        -H "X-Vault-Token: ${ROOT_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"policies\": [${policies}], \"token_ttl\": \"1h\", \"token_max_ttl\": \"4h\"}" > /dev/null

    # Get role-id
    ROLE_ID=$(curl -sf "${OPENBAO_ADDR}/v1/auth/approle/role/${service}/role-id" \
        -H "X-Vault-Token: ${ROOT_TOKEN}" | jq -r '.data.role_id')

    # Generate secret-id
    SECRET_ID=$(curl -sf -X POST "${OPENBAO_ADDR}/v1/auth/approle/role/${service}/secret-id" \
        -H "X-Vault-Token: ${ROOT_TOKEN}" | jq -r '.data.secret_id')

    ok "AppRole '${service}': role_id=${ROLE_ID}"

    # Save to a per-service file for bootstrap use by 02-06 scripts
    echo "{\"role_id\": \"${ROLE_ID}\", \"secret_id\": \"${SECRET_ID}\"}" \
        > "${REPO_ROOT}/.approle-${service}.json"
    chmod 600 "${REPO_ROOT}/.approle-${service}.json"
}

create_approle "trino"          '"trino"'
create_approle "ranger"         '"ranger"'
create_approle "polaris"        '"polaris"'
create_approle "airflow"        '"airflow"'
create_approle "openmetadata"   '"openmetadata"'
create_approle "docling"        '"docling"'
create_approle "grafana"        '"grafana"'

echo ""
ok "OpenBao initialization complete!"
log "Next step: run scripts/bootstrap/02-init-keycloak.sh"
log "IMPORTANT: Securely store ${INIT_OUTPUT} — delete from this machine after backup."
