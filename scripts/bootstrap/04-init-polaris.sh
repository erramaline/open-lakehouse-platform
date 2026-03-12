#!/usr/bin/env bash
# =============================================================================
# 04-init-polaris.sh — Bootstrap Apache Polaris 1.2.0
# =============================================================================
# Steps:
#   1. Wait for Polaris API to be healthy
#   2. Obtain bootstrap OAuth2 token (root/management credentials)
#   3. Create the 'lakehouse' catalog (REST, S3 warehouse)
#   4. Create namespaces: finance, hr, operations, dev
#   5. Create service principals: trino, airflow
#   6. Grant catalog-level privileges to each principal
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
ENV_FILE="${REPO_ROOT}/local/.env"

log()  { echo "[04-init-polaris] $*"; }
ok()   { echo "[04-init-polaris] ✓ $*"; }
err()  { echo "[04-init-polaris] ✗ $*" >&2; exit 1; }

[ -f "${ENV_FILE}" ] || err ".env file not found at ${ENV_FILE}"
set -a; source "${ENV_FILE}"; set +a

POLARIS_URL="${POLARIS_URL:-http://localhost:8181}"
POLARIS_MGMT_URL="${POLARIS_MGMT_URL:-http://localhost:8182}"

# ─── Step 1: Wait for Polaris ─────────────────────────────────────────────────
log "Waiting for Polaris API on ${POLARIS_URL}..."
for i in $(seq 1 40); do
    if curl -sf "${POLARIS_MGMT_URL}/healthcheck" &>/dev/null; then
        ok "Polaris is healthy."
        break
    fi
    [ "$i" -eq 40 ] && err "Timeout waiting for Polaris at ${POLARIS_MGMT_URL}/healthcheck"
    sleep 5
done

# ─── Step 2: Obtain management token ──────────────────────────────────────────
log "Obtaining Polaris bootstrap OAuth2 token..."

TOKEN_RESPONSE=$(curl -sf -X POST "${POLARIS_URL}/api/catalog/v1/oauth/tokens" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=client_credentials" \
    -d "client_id=${POLARIS_BOOTSTRAP_CLIENT_ID}" \
    -d "client_secret=${POLARIS_BOOTSTRAP_CLIENT_SECRET}" \
    -d "scope=PRINCIPAL_ROLE:ALL")

ACCESS_TOKEN=$(echo "${TOKEN_RESPONSE}" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
[ -z "${ACCESS_TOKEN}" ] && err "Failed to obtain Polaris token."
ok "Polaris token obtained."

POLARIS_AUTH="Authorization: Bearer ${ACCESS_TOKEN}"

# ─── Helper: Polaris API calls ────────────────────────────────────────────────
polaris_get() {
    local path="$1"
    curl -sf -H "${POLARIS_AUTH}" "${POLARIS_URL}${path}"
}

polaris_post() {
    local path="$1"
    local body="$2"
    curl -sf -X POST -H "${POLARIS_AUTH}" -H "Content-Type: application/json" \
        "${POLARIS_URL}${path}" -d "${body}"
}

polaris_put() {
    local path="$1"
    local body="$2"
    curl -sf -X PUT -H "${POLARIS_AUTH}" -H "Content-Type: application/json" \
        "${POLARIS_URL}${path}" -d "${body}"
}

polaris_delete() {
    local path="$1"
    curl -sf -X DELETE -H "${POLARIS_AUTH}" "${POLARIS_URL}${path}" || true
}

# ─── Step 3: Create 'lakehouse' catalog ───────────────────────────────────────
log "Creating 'lakehouse' catalog..."

CATALOG_EXISTS=$(polaris_get "/api/management/v1/catalogs" | \
    python3 -c "import sys,json; cats=json.load(sys.stdin).get('catalogs',[]); print('yes' if any(c['name']=='lakehouse' for c in cats) else 'no')" 2>/dev/null || echo "no")

if [ "${CATALOG_EXISTS}" = "yes" ]; then
    log "Catalog 'lakehouse' already exists."
else
    polaris_post "/api/management/v1/catalogs" '{
      "catalog": {
        "name": "lakehouse",
        "type": "INTERNAL",
        "properties": {
          "default-base-location": "s3://iceberg/",
          "s3.endpoint": "http://minio-1:9000",
          "s3.path-style-access": "true",
          "s3.access-key-id": "'"${MINIO_POLARIS_ACCESS_KEY}"'",
          "s3.secret-access-key": "'"${MINIO_POLARIS_SECRET_KEY}"'",
          "client.region": "us-east-1"
        },
        "storageConfigInfo": {
          "storageType": "S3",
          "allowedLocations": ["s3://iceberg/"]
        }
      }
    }'
    ok "Catalog 'lakehouse' created."
fi

# ─── Step 4: Create namespaces ──────────────────────────────────────────────
for ns in finance hr operations dev; do
    log "Creating namespace '${ns}' in catalog 'lakehouse'..."
    NS_EXISTS=$(polaris_get "/api/catalog/v1/lakehouse/namespaces" | \
        python3 -c "import sys,json; ns=json.load(sys.stdin).get('namespaces',[]); print('yes' if ['${ns}'] in ns else 'no')" 2>/dev/null || echo "no")

    if [ "${NS_EXISTS}" = "yes" ]; then
        log "Namespace '${ns}' already exists."
    else
        polaris_post "/api/catalog/v1/lakehouse/namespaces" \
            '{"namespace":["'"${ns}"'"],"properties":{"location":"s3://iceberg/'"${ns}"'/","owner":"dave.admin"}}'
        ok "Namespace '${ns}' created."
    fi
done

# ─── Step 5: Create service principals ────────────────────────────────────────
create_principal() {
    local name="$1"
    local client_id="$2"

    log "Creating principal '${name}' (client_id: ${client_id})..."

    PRINCIPAL_EXISTS=$(polaris_get "/api/management/v1/principals" | \
        python3 -c "import sys,json; ps=json.load(sys.stdin).get('principals',[]); print('yes' if any(p['name']=='${name}' for p in ps) else 'no')" 2>/dev/null || echo "no")

    if [ "${PRINCIPAL_EXISTS}" = "yes" ]; then
        log "Principal '${name}' already exists."
        return
    fi

    PRINCIPAL_RESPONSE=$(polaris_post "/api/management/v1/principals" \
        '{"principal":{"name":"'"${name}"'","clientId":"'"${client_id}"'","type":"SERVICE"}}')
    ok "Principal '${name}' created."
    echo "${PRINCIPAL_RESPONSE}" | python3 -c "
import sys, json
r = json.load(sys.stdin)
cred = r.get('credentials', {})
print('[04-init-polaris]   clientId:', r.get('clientId',''))
print('[04-init-polaris]   clientSecret:', cred.get('clientSecret','(use existing secret from .env)'))
"
}

create_principal "trino-svc"   "${POLARIS_TRINO_CLIENT_ID}"
create_principal "airflow-svc" "${POLARIS_AIRFLOW_CLIENT_ID}"

# ─── Step 6: Create principal roles and grant catalog privileges ───────────────
create_and_grant_principal_role() {
    local principal_name="$1"
    local role_name="${principal_name}-role"

    log "Creating principal role '${role_name}'..."
    ROLE_EXISTS=$(polaris_get "/api/management/v1/principal-roles" | \
        python3 -c "import sys,json; rs=json.load(sys.stdin).get('roles',[]); print('yes' if any(r['name']=='${role_name}' for r in rs) else 'no')" 2>/dev/null || echo "no")

    if [ "${ROLE_EXISTS}" != "yes" ]; then
        polaris_post "/api/management/v1/principal-roles" \
            '{"principalRole":{"name":"'"${role_name}"'"}}'
        ok "Principal role '${role_name}' created."
    else
        log "Principal role '${role_name}' already exists."
    fi

    # Assign role to principal
    log "Assigning '${role_name}' to principal '${principal_name}'..."
    polaris_put "/api/management/v1/principals/${principal_name}/principal-roles" \
        '{"principalRole":{"name":"'"${role_name}"'"}}' &>/dev/null || \
        log "(assignment may already exist)"

    # Grant catalog role CATALOG_MANAGE_CONTENT to the principal role
    log "Granting catalog privileges to '${role_name}'..."
    polaris_post "/api/management/v1/catalogs/lakehouse/catalog-roles" \
        '{"catalogRole":{"name":"'"${role_name}-catalog"'"}}' &>/dev/null || true

    GRANT_BODY='{
      "grant": {
        "type": "catalog",
        "privilege": "CATALOG_MANAGE_CONTENT"
      }
    }'
    polaris_put "/api/management/v1/catalogs/lakehouse/catalog-roles/${role_name}-catalog/grants" \
        "${GRANT_BODY}" &>/dev/null || log "(grant may already exist)"

    # Assign catalog role to principal role
    polaris_put "/api/management/v1/catalogs/lakehouse/catalog-roles/${role_name}-catalog/principal-roles" \
        '{"principalRole":{"name":"'"${role_name}"'"}}' &>/dev/null || \
        log "(catalog role assignment may already exist)"

    ok "Privileges granted to '${principal_name}'."
}

create_and_grant_principal_role "trino-svc"
create_and_grant_principal_role "airflow-svc"

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
log "Polaris catalogs:"
polaris_get "/api/management/v1/catalogs" | python3 -m json.tool 2>/dev/null || true

log "Polaris principals:"
polaris_get "/api/management/v1/principals" | python3 -m json.tool 2>/dev/null || true

echo ""
ok "Polaris initialization complete!"
log "Next step: run scripts/bootstrap/05-init-ranger.sh"
