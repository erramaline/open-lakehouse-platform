#!/usr/bin/env bash
# =============================================================================
# configure-keycloak.sh — Bootstrap Keycloak realm, clients, and users
# =============================================================================
# Idempotent: checks if realm/clients/users exist before creating them.
# Uses KC Admin REST API (Bearer token auth — avoids embedding credentials).
# =============================================================================
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; RESET='\033[0m'
log()  { echo -e "${GREEN}[kc-configure]${RESET} $*"; }
warn() { echo -e "${YELLOW}[kc-configure]${RESET} $*"; }
err()  { echo -e "${RED}[kc-configure]${RESET} $*" >&2; exit 1; }

# ─── Prerequisites ────────────────────────────────────────────────────────────
for cmd in curl jq envsubst; do
    command -v "${cmd}" &>/dev/null || err "'${cmd}' not found. Install it first."
done

# ─── Config ───────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/local/.env}"
[ -f "${ENV_FILE}" ] && { set -a; source "${ENV_FILE}"; set +a; }

KC_URL="${KEYCLOAK_URL:-http://localhost:8080}"
KC_ADMIN="${KEYCLOAK_ADMIN_USER:-admin}"
KC_ADMIN_PASS="${KEYCLOAK_ADMIN_PASSWORD:-}"
REALM="lakehouse"

[ -z "${KC_ADMIN_PASS}" ] && err "KEYCLOAK_ADMIN_PASSWORD is required."

REALM_DIR="${SCRIPT_DIR}/realm-config"
CLIENTS_DIR="${REALM_DIR}/clients"

# ─── Wait for Keycloak ────────────────────────────────────────────────────────
log "Waiting for Keycloak at ${KC_URL}/health/ready..."
for i in $(seq 1 60); do
    HTTP=$(curl -sf -o /dev/null -w "%{http_code}" "${KC_URL}/health/ready" 2>/dev/null || echo "000")
    [[ "${HTTP}" == "200" ]] && break
    [[ "${i}" -eq 60 ]] && err "Keycloak not ready after 300s."
    sleep 5
done
log "✓ Keycloak is ready."

# ─── Authenticate — obtain admin access token ─────────────────────────────────
log "Authenticating as admin..."
TOKEN_RESPONSE=$(curl -sf -X POST \
    "${KC_URL}/realms/master/protocol/openid-connect/token" \
    -d "client_id=admin-cli" \
    -d "username=${KC_ADMIN}" \
    --data-urlencode "password=${KC_ADMIN_PASS}" \
    -d "grant_type=password" \
    -H "Content-Type: application/x-www-form-urlencoded")

TOKEN=$(echo "${TOKEN_RESPONSE}" | jq -r '.access_token // ""')
[ -z "${TOKEN}" ] && err "Failed to obtain admin token. Check credentials."
log "✓ Admin token obtained."

AUTH_HEADER="Authorization: Bearer ${TOKEN}"

# ─── Helper functions ─────────────────────────────────────────────────────────
kc_get() {
    curl -sf -H "${AUTH_HEADER}" "${KC_URL}/admin/realms/${1}" 2>/dev/null || echo "{}"
}

realm_exists() {
    kc_get "${REALM}" | jq -e '.realm == "'"${REALM}"'"' &>/dev/null
}

client_exists() {
    local client_id="$1"
    curl -sf -H "${AUTH_HEADER}" \
        "${KC_URL}/admin/realms/${REALM}/clients?clientId=${client_id}" 2>/dev/null | \
        jq -e 'length > 0' &>/dev/null
}

user_exists() {
    local username="$1"
    curl -sf -H "${AUTH_HEADER}" \
        "${KC_URL}/admin/realms/${REALM}/users?username=${username}&exact=true" 2>/dev/null | \
        jq -e 'length > 0' &>/dev/null
}

# ─── Step 1: Create realm ─────────────────────────────────────────────────────
log "━━━ Step 1: Realm '${REALM}' ━━━"
if realm_exists; then
    warn "  → Realm '${REALM}' already exists — skipping import."
else
    log "  Importing realm from realm.json..."
    REALM_PAYLOAD=$(envsubst < "${REALM_DIR}/realm.json")
    HTTP=$(curl -sf -X POST \
        -H "${AUTH_HEADER}" \
        -H "Content-Type: application/json" \
        -d "${REALM_PAYLOAD}" \
        -o /dev/null -w "%{http_code}" \
        "${KC_URL}/admin/realms" 2>/dev/null || echo "000")
    [[ "${HTTP}" == "201" ]] && log "  ✓ Realm '${REALM}' created." || \
        err "  Failed to create realm (HTTP ${HTTP})."
fi

# ─── Step 2: Verify / create clients ─────────────────────────────────────────
log "━━━ Step 2: OIDC Clients ━━━"
for client_file in trino airflow openmetadata grafana minio; do
    CLIENT_PATH="${CLIENTS_DIR}/${client_file}.json"
    [ -f "${CLIENT_PATH}" ] || { warn "  Client file not found: ${CLIENT_PATH}"; continue; }
    CLIENT_ID=$(jq -r '.clientId' "${CLIENT_PATH}")
    if client_exists "${CLIENT_ID}"; then
        warn "  → Client '${CLIENT_ID}' already exists — skipping."
    else
        log "  Creating client '${CLIENT_ID}'..."
        PAYLOAD=$(envsubst < "${CLIENT_PATH}")
        HTTP=$(curl -sf -X POST \
            -H "${AUTH_HEADER}" \
            -H "Content-Type: application/json" \
            -d "${PAYLOAD}" \
            -o /dev/null -w "%{http_code}" \
            "${KC_URL}/admin/realms/${REALM}/clients" 2>/dev/null || echo "000")
        [[ "${HTTP}" == "201" ]] && log "  ✓ Client '${CLIENT_ID}' created." || \
            warn "  ✗ Failed to create client '${CLIENT_ID}' (HTTP ${HTTP})."
    fi
done

# ─── Step 3: Verify users ─────────────────────────────────────────────────────
log "━━━ Step 3: Users ━━━"
EXPECTED_USERS=(alice bob carol dan mallory)
for username in "${EXPECTED_USERS[@]}"; do
    if user_exists "${username}"; then
        log "  ✓ User '${username}' exists."
    else
        warn "  ✗ User '${username}' NOT found. Check realm.json import."
    fi
done

# ─── Step 4: Print OIDC discovery endpoints ───────────────────────────────────
log "━━━ OIDC Discovery Endpoints ━━━"
OIDC_BASE="${KC_URL}/realms/${REALM}/protocol/openid-connect"
log "  Realm:           ${KC_URL}/realms/${REALM}"
log "  OIDC Discovery:  ${KC_URL}/realms/${REALM}/.well-known/openid-configuration"
log "  Token endpoint:  ${OIDC_BASE}/token"
log "  Userinfo:        ${OIDC_BASE}/userinfo"
log "  JWKS:            ${OIDC_BASE}/certs"
log "  Logout:          ${OIDC_BASE}/logout"
echo ""

# ─── Step 5: Verify clients ───────────────────────────────────────────────────
log "━━━ Step 5: Client Verification ━━━"
EXPECTED_CLIENTS=(trino airflow openmetadata grafana minio)
ALL_OK=true
for cid in "${EXPECTED_CLIENTS[@]}"; do
    if client_exists "${cid}"; then
        log "  ✓ Client '${cid}' verified."
    else
        warn "  ✗ Client '${cid}' NOT found!"
        ALL_OK=false
    fi
done

if [[ "${ALL_OK}" == "true" ]]; then
    log "✓ Keycloak configuration complete."
else
    warn "Some clients missing — re-run script or import realm.json manually via UI."
    exit 1
fi
