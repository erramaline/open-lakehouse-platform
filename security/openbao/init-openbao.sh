#!/usr/bin/env bash
# =============================================================================
# init-openbao.sh — Complete idempotent OpenBao Raft cluster initialization
# =============================================================================
# Steps:
#   1.  Check prerequisites (bao CLI, jq, curl)
#   2.  Initialize 3-node Raft cluster (5 key shares, 3 threshold)
#   3.  Unseal all 3 nodes
#   4.  Enable KV v2 secrets engine at path `secret/`
#   5.  Enable PKI engine, generate root CA, configure intermediate CA role
#   6.  Enable Kubernetes auth method
#   7.  Enable AppRole auth method
#   8.  Write all service secrets to KV v2 (idempotent)
#   9.  Apply all service policies from ./policies/
#   10. Create AppRole credentials per service
#
# Outputs:
#   .openbao-init-output.json  — root token + key shares (mode 600, gitignored)
#   .approle-<service>.json    — role_id + secret_id per service (mode 600)
#
# Environment:
#   OPENBAO_ADDR    — address of the active OpenBao node (default: http://localhost:8200)
#   OPENBAO_ADDR_2  — address of 2nd Raft node  (default: http://localhost:8201)
#   OPENBAO_ADDR_3  — address of 3rd Raft node  (default: http://localhost:8202)
#   ENV_FILE        — path to .env file          (default: ./local/.env)
# =============================================================================
set -euo pipefail

# ─── Colours ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; RESET='\033[0m'
BOLD='\033[1m'
log()  { echo -e "${GREEN}[OpenBao]${RESET} $*"; }
warn() { echo -e "${YELLOW}[OpenBao]${RESET} $*"; }
err()  { echo -e "${RED}[OpenBao]${RESET} $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}${GREEN}══[ $* ]══${RESET}"; }

# ─── Prerequisites ────────────────────────────────────────────────────────────
section "Prerequisites"
for cmd in bao jq curl; do
    command -v "${cmd}" &>/dev/null || err "${cmd} not found. Install it before running this script."
    log "✓ ${cmd} available"
done

# ─── Config ───────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/local/.env}"
POLICY_DIR="${SCRIPT_DIR}/policies"
INIT_OUTPUT="${REPO_ROOT}/.openbao-init-output.json"

OPENBAO_ADDR="${OPENBAO_ADDR:-http://localhost:8200}"
OPENBAO_ADDR_2="${OPENBAO_ADDR_2:-http://localhost:8201}"
OPENBAO_ADDR_3="${OPENBAO_ADDR_3:-http://localhost:8202}"

[ -f "${ENV_FILE}" ] && { set -a; source "${ENV_FILE}"; set +a; } || \
    warn ".env file not found at ${ENV_FILE} — using environment variables only."

export BAO_ADDR="${OPENBAO_ADDR}"

# ─── Step 1: Wait for OpenBao to be reachable ─────────────────────────────────
section "1. Wait for OpenBao"
log "Waiting for OpenBao at ${OPENBAO_ADDR}..."
for i in $(seq 1 40); do
    HTTP=$(curl -sf -o /dev/null -w "%{http_code}" "${OPENBAO_ADDR}/v1/sys/health" 2>/dev/null || echo "000")
    # 200 = initialized+unsealed, 429 = standby, 472 = DR, 473 = perf standby
    # 501 = not initialized (expected on first run), 503 = sealed (not yet unsealed)
    if [[ "${HTTP}" =~ ^(200|429|472|473|501|503)$ ]]; then
        log "OpenBao reachable (HTTP ${HTTP})."
        break
    fi
    [[ $i -eq 40 ]] && err "Timeout waiting for OpenBao at ${OPENBAO_ADDR}"
    sleep 3
done

# ─── Step 2: Initialize (idempotent) ──────────────────────────────────────────
section "2. Initialize Raft Cluster"

INIT_STATUS=$(curl -sf "${OPENBAO_ADDR}/v1/sys/init" | jq -r .initialized)

if [[ "${INIT_STATUS}" == "true" ]]; then
    warn "OpenBao already initialized. Loading existing init output..."
    [[ -f "${INIT_OUTPUT}" ]] || err \
        "Already initialized but ${INIT_OUTPUT} not found. Cannot proceed without key shares."
    ROOT_TOKEN=$(jq -r .root_token "${INIT_OUTPUT}")
    UNSEAL_KEYS=$(jq -r '.keys[]' "${INIT_OUTPUT}")
else
    log "Initializing 3-node Raft cluster (5 shares, threshold 3)..."
    INIT_RESP=$(curl -sf -X POST "${OPENBAO_ADDR}/v1/sys/init" \
        -H "Content-Type: application/json" \
        -d '{"secret_shares":5,"secret_threshold":3,"stored_shares":0}')

    echo "${INIT_RESP}" > "${INIT_OUTPUT}"
    chmod 600 "${INIT_OUTPUT}"

    ROOT_TOKEN=$(echo "${INIT_RESP}" | jq -r .root_token)
    UNSEAL_KEYS=$(echo "${INIT_RESP}" | jq -r '.keys[]')
    log "✓ Initialized. Init output saved to ${INIT_OUTPUT} (mode 600)."
    warn "IMPORTANT: Back up ${INIT_OUTPUT} securely. Loss = permanent data loss."
fi

# ─── Step 3: Unseal all nodes ─────────────────────────────────────────────────
section "3. Unseal Nodes"

unseal_node() {
    local addr="$1"
    local label="$2"

    # Skip if already unsealed
    SEALED=$(curl -sf "${addr}/v1/sys/health" | jq -r '.sealed // true')
    if [[ "${SEALED}" == "false" ]]; then
        log "Node ${label} already unsealed."
        return
    fi

    log "Unsealing ${label} (${addr})..."
    local count=0
    while read -r key; do
        [[ $count -ge 3 ]] && break
        curl -sf -X POST "${addr}/v1/sys/unseal" \
            -H "Content-Type: application/json" \
            -d "{\"key\":\"${key}\"}" > /dev/null
        count=$(( count + 1 ))
    done <<< "${UNSEAL_KEYS}"

    SEALED_AFTER=$(curl -sf "${addr}/v1/sys/health" | jq -r '.sealed // true')
    [[ "${SEALED_AFTER}" == "false" ]] && log "✓ ${label} unsealed." || \
        warn "${label} may still be sealed — check manually."
}

unseal_node "${OPENBAO_ADDR}"   "Node-1"
# Give nodes a moment to join Raft
sleep 2
unseal_node "${OPENBAO_ADDR_2}" "Node-2"
sleep 1
unseal_node "${OPENBAO_ADDR_3}" "Node-3"

export BAO_TOKEN="${ROOT_TOKEN}"

# ─── Helper: BAO API call ─────────────────────────────────────────────────────
bao_api() {
    local method="$1"; local path="$2"; local body="${3:-}"
    if [[ -n "${body}" ]]; then
        curl -sf -X "${method}" "${OPENBAO_ADDR}/v1/${path}" \
            -H "X-Vault-Token: ${ROOT_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "${body}"
    else
        curl -sf -X "${method}" "${OPENBAO_ADDR}/v1/${path}" \
            -H "X-Vault-Token: ${ROOT_TOKEN}"
    fi
}

bao_write_kv() {
    local path="$1"; shift
    # Build JSON from key=value pairs
    local json="{"
    local first=true
    while [[ $# -gt 0 ]]; do
        local kv="$1"; shift
        local k="${kv%%=*}"; local v="${kv#*=}"
        [[ "${first}" == true ]] && first=false || json+=","
        json+="\"${k}\":\"${v}\""
    done
    json+="}"
    bao_api PUT "secret/data/${path}" "{\"data\":${json}}" > /dev/null
    log "  ✓ secret/data/${path}"
}

engine_enabled() {
    bao_api GET "sys/mounts" | jq -r ".[\"${1}/\"] // empty" | grep -q "type" 2>/dev/null
}

# ─── Step 4: Enable KV v2 ─────────────────────────────────────────────────────
section "4. KV v2 Secrets Engine"
if engine_enabled "secret"; then
    warn "KV v2 already mounted at secret/. Skipping."
else
    bao_api POST "sys/mounts/secret" '{"type":"kv","options":{"version":"2"}}' > /dev/null
    log "✓ KV v2 enabled at secret/"
fi

# ─── Step 5: Enable PKI engine ────────────────────────────────────────────────
section "5. PKI Engine + CA"
if engine_enabled "pki"; then
    warn "PKI engine already enabled. Skipping root CA generation."
else
    bao_api POST "sys/mounts/pki" '{"type":"pki"}' > /dev/null
    bao_api POST "sys/mounts/config/pki" '{"max_lease_ttl":"87600h"}' > /dev/null || true
    bao_api PUT "sys/mounts/pki/tune" '{"max_lease_ttl":"87600h"}' > /dev/null
    log "✓ PKI engine enabled at pki/"

    # Generate root CA
    log "Generating PKI root CA..."
    bao_api POST "pki/root/generate/internal" \
        '{"common_name":"Open Lakehouse Internal CA","ttl":"87600h","key_bits":4096}' > /dev/null
    log "✓ PKI root CA generated."

    # Configure URLs
    bao_api POST "pki/config/urls" \
        "{\"issuing_certificates\":\"${OPENBAO_ADDR}/v1/pki/ca\",\"crl_distribution_points\":\"${OPENBAO_ADDR}/v1/pki/crl\"}" > /dev/null

    # Create intermediate role for cert-manager
    bao_api POST "pki/roles/lakehouse-intermediate" \
        '{"allowed_domains":["lakehouse-data","lakehouse-system","lakehouse-obs","lakehouse-storage","lakehouse-ingest","svc.cluster.local","localhost"],"allow_subdomains":true,"allow_bare_domains":false,"max_ttl":"2160h","key_type":"rsa","key_bits":2048,"server_flag":true,"client_flag":true,"require_cn":false}' > /dev/null
    log "✓ PKI role 'lakehouse-intermediate' created."
fi

# ─── Step 6: Kubernetes auth method ───────────────────────────────────────────
section "6. Kubernetes Auth Method"
if bao_api GET "sys/auth" | jq -r '."kubernetes/" // empty' | grep -q "type" 2>/dev/null; then
    warn "Kubernetes auth already enabled. Skipping."
else
    bao_api POST "sys/auth/kubernetes" '{"type":"kubernetes"}' > /dev/null 2>&1 || \
        warn "Kubernetes auth enablement skipped (not in K8s environment — OK for local dev)."
    log "✓ Kubernetes auth configured."
fi

# ─── Step 7: AppRole auth method ──────────────────────────────────────────────
section "7. AppRole Auth Method"
if bao_api GET "sys/auth" | jq -r '."approle/" // empty' | grep -q "type" 2>/dev/null; then
    warn "AppRole auth already enabled. Skipping."
else
    bao_api POST "sys/auth/approle" '{"type":"approle"}' > /dev/null
    log "✓ AppRole auth enabled."
fi

# ─── Step 8: Write all service secrets ────────────────────────────────────────
section "8. Write Service Secrets to KV v2"
log "Writing secrets (idempotent — overwrites with same values from .env)..."

## ── PostgreSQL ──────────────────────────────────────────────────────────────
bao_write_kv "postgresql/root"          "password=${POSTGRES_PASSWORD:-changeme}"
bao_write_kv "db/postgres/keycloak"     "password=${KEYCLOAK_DB_PASSWORD:-changeme}" "username=keycloak"
bao_write_kv "db/postgres/polaris"      "password=${POLARIS_DB_PASSWORD:-changeme}"   "username=polaris"
bao_write_kv "db/postgres/nessie"       "password=${NESSIE_DB_PASSWORD:-changeme}"    "username=nessie"
bao_write_kv "db/postgres/ranger"       "password=${RANGER_DB_PASSWORD:-changeme}"    "username=ranger"
bao_write_kv "db/postgres/airflow"      "password=${AIRFLOW_DB_PASSWORD:-changeme}"   "username=airflow"
bao_write_kv "db/postgres/openmetadata" "password=${OPENMETADATA_DB_PASSWORD:-changeme}" "username=openmetadata"
bao_write_kv "db/postgres/trino_gateway" "password=${TRINO_GATEWAY_DB_PASSWORD:-changeme}" "username=trino_gateway"

## ── MinIO ────────────────────────────────────────────────────────────────────
bao_write_kv "storage/minio/root"      "access_key=${MINIO_ROOT_USER:-minioadmin}" "secret_key=${MINIO_ROOT_PASSWORD:-changeme}"
bao_write_kv "storage/minio/polaris"   "access_key=${MINIO_POLARIS_ACCESS_KEY:-polaris}" "secret_key=${MINIO_POLARIS_SECRET_KEY:-changeme}"
bao_write_kv "storage/minio/ingestion" "access_key=${MINIO_INGESTION_ACCESS_KEY:-ingestion}" "secret_key=${MINIO_INGESTION_SECRET_KEY:-changeme}"
bao_write_kv "storage/minio/audit"     "access_key=${MINIO_AUDIT_ACCESS_KEY:-audit}" "secret_key=${MINIO_AUDIT_SECRET_KEY:-changeme}"

## ── Keycloak ─────────────────────────────────────────────────────────────────
bao_write_kv "identity/keycloak/admin"                "password=${KEYCLOAK_ADMIN_PASSWORD:-changeme}"
bao_write_kv "identity/keycloak/clients/trino"        "secret=${KEYCLOAK_TRINO_CLIENT_SECRET:-changeme}"
bao_write_kv "identity/keycloak/clients/airflow"      "secret=${KEYCLOAK_AIRFLOW_CLIENT_SECRET:-changeme}"
bao_write_kv "identity/keycloak/clients/openmetadata" "secret=${KEYCLOAK_OPENMETADATA_CLIENT_SECRET:-changeme}"
bao_write_kv "identity/keycloak/clients/grafana"      "secret=${KEYCLOAK_GRAFANA_CLIENT_SECRET:-changeme}"
bao_write_kv "identity/keycloak/clients/minio"        "secret=${KEYCLOAK_MINIO_CLIENT_SECRET:-changeme}"

## ── Polaris ───────────────────────────────────────────────────────────────────
bao_write_kv "catalog/polaris/admin"   "client_id=${POLARIS_BOOTSTRAP_CLIENT_ID:-polaris-admin}" "client_secret=${POLARIS_BOOTSTRAP_CLIENT_SECRET:-changeme}"
bao_write_kv "catalog/polaris/trino"   "client_id=${POLARIS_TRINO_CLIENT_ID:-trino-svc}" "client_secret=${POLARIS_TRINO_CLIENT_SECRET:-changeme}"
bao_write_kv "catalog/polaris/airflow" "client_id=${POLARIS_AIRFLOW_CLIENT_ID:-airflow-svc}" "client_secret=${POLARIS_AIRFLOW_CLIENT_SECRET:-changeme}"

## ── Trino ─────────────────────────────────────────────────────────────────────
bao_write_kv "compute/trino/keystore"       "password=${TRINO_KEYSTORE_PASSWORD:-changeme}"
bao_write_kv "compute/trino/internal-secret" "value=${TRINO_INTERNAL_SHARED_SECRET:-changeme}"

## ── Ranger ────────────────────────────────────────────────────────────────────
bao_write_kv "policy/ranger/admin"     "password=${RANGER_ADMIN_PASSWORD:-changeme}"
bao_write_kv "policy/ranger/db"        "password=${RANGER_DB_PASSWORD:-changeme}"
bao_write_kv "policy/ranger/trino-plugin-shared-secret" "value=${RANGER_TRINO_SHARED_SECRET:-changeme}"

## ── Airflow ───────────────────────────────────────────────────────────────────
bao_write_kv "ingestion/airflow/fernet-key"      "value=${AIRFLOW_FERNET_KEY:-changeme}"
bao_write_kv "ingestion/airflow/webserver-secret" "value=${AIRFLOW_WEBSERVER_SECRET_KEY:-changeme}"
bao_write_kv "ingestion/airflow/db"              "password=${AIRFLOW_DB_PASSWORD:-changeme}"
bao_write_kv "ingestion/airflow/redis"           "password=${REDIS_PASSWORD:-changeme}"

## ── OpenMetadata ──────────────────────────────────────────────────────────────
bao_write_kv "metadata/openmetadata/db"            "password=${OPENMETADATA_DB_PASSWORD:-changeme}"
bao_write_kv "metadata/openmetadata/jwt-secret"    "value=${OPENMETADATA_JWT_SECRET:-changeme}"
bao_write_kv "metadata/openmetadata/elasticsearch" "password=${ELASTICSEARCH_PASSWORD:-changeme}"

## ── Observability ─────────────────────────────────────────────────────────────
bao_write_kv "observability/grafana/admin"          "password=${GRAFANA_ADMIN_PASSWORD:-changeme}"
bao_write_kv "observability/alertmanager/webhook"   "url=${ALERTMANAGER_SLACK_WEBHOOK:-https://hooks.slack.com/REPLACE}"

## ── dbt ──────────────────────────────────────────────────────────────────────
bao_write_kv "transform/dbt/trino"  "username=${TRINO_HTTP_USER:-trino}" "password=${TRINO_HTTP_PASSWORD:-changeme}"

log "✓ All secrets written."

# ─── Step 9: Apply policies ───────────────────────────────────────────────────
section "9. Apply Service Policies"
[[ -d "${POLICY_DIR}" ]] || err "Policy directory not found: ${POLICY_DIR}"

for policy_file in "${POLICY_DIR}"/*.hcl; do
    policy_name=$(basename "${policy_file}" .hcl)
    log "Applying policy: ${policy_name}"
    bao_api PUT "sys/policies/acl/${policy_name}" \
        "{\"policy\":$(jq -Rs . < "${policy_file}")}" > /dev/null
    log "  ✓ Policy '${policy_name}' applied."
done

# ─── Step 10: Create AppRole credentials ──────────────────────────────────────
section "10. AppRole Credentials per Service"

create_approle() {
    local service="$1"
    local policy="$2"
    local role_name="${service}-role"
    local out_file="${REPO_ROOT}/.approle-${service}.json"

    # Create role
    bao_api POST "auth/approle/role/${role_name}" \
        "{\"policies\":[\"${policy}\"],\"token_ttl\":\"1h\",\"token_max_ttl\":\"4h\",\"secret_id_ttl\":\"24h\",\"secret_id_num_uses\":0}" > /dev/null

    # Get role_id
    ROLE_ID=$(bao_api GET "auth/approle/role/${role_name}/role-id" | jq -r .data.role_id)

    # Generate secret_id (always regenerate — short-lived)
    SECRET_ID=$(bao_api POST "auth/approle/role/${role_name}/secret-id" '{}' | jq -r .data.secret_id)

    jq -n \
        --arg role_id    "${ROLE_ID}" \
        --arg secret_id  "${SECRET_ID}" \
        --arg service    "${service}" \
        --arg policy     "${policy}" \
        '{service: $service, policy: $policy, role_id: $role_id, secret_id: $secret_id}' \
        > "${out_file}"
    chmod 600 "${out_file}"
    log "✓ AppRole for '${service}' → ${out_file}"
}

create_approle "trino"        "trino"
create_approle "ranger"       "ranger"
create_approle "polaris"      "polaris"
create_approle "airflow"      "airflow"
create_approle "openmetadata" "openmetadata"
create_approle "docling"      "docling"
create_approle "grafana"      "grafana"

# ─── Final summary ────────────────────────────────────────────────────────────
section "✓ OpenBao Initialization Complete"
echo ""
log "OpenBao status:"
bao_api GET "sys/health" | jq '{initialized,sealed,version}' || true
echo ""
log "Mounted engines:"
bao_api GET "sys/mounts" | jq -r 'to_entries[] | "  \(.key) → \(.value.type)"' || true
echo ""
log "Enabled auth methods:"
bao_api GET "sys/auth" | jq -r 'to_entries[] | "  \(.key) → \(.value.type)"' || true
echo ""
warn "Secure storage reminder:"
warn "  ${INIT_OUTPUT} — root token + key shares"
warn "  .approle-*.json       — AppRole credentials per service"
warn "These files are gitignored. Never commit them."
