#!/usr/bin/env bash
# =============================================================================
# 02-init-keycloak.sh — Import realm and verify OIDC clients
# =============================================================================
# Steps:
#   1. Wait for Keycloak to be healthy
#   2. Verify realm 'lakehouse' was imported on startup (--import-realm flag)
#   3. Verify all 5 OIDC clients exist
#   4. Create/update test users if missing
#   5. Print OIDC discovery URL for validation
#
# Prerequisites:
#   - docker compose up -d keycloak
#   - Keycloak must show service_healthy
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
ENV_FILE="${REPO_ROOT}/local/.env"

log()  { echo "[02-init-keycloak] $*"; }
ok()   { echo "[02-init-keycloak] ✓ $*"; }
err()  { echo "[02-init-keycloak] ✗ $*" >&2; exit 1; }

[ -f "${ENV_FILE}" ] || err ".env file not found at ${ENV_FILE}"
set -a; source "${ENV_FILE}"; set +a

KC_URL="${KEYCLOAK_URL:-http://localhost:8080}"
KC_REALM="${KEYCLOAK_REALM:-lakehouse}"
KC_ADMIN="${KEYCLOAK_ADMIN}"
KC_ADMIN_PW="${KEYCLOAK_ADMIN_PASSWORD}"

command -v curl >/dev/null || err "curl is required."
command -v jq   >/dev/null || err "jq is required."

# ─── Step 1: Wait for Keycloak ────────────────────────────────────────────────
log "Waiting for Keycloak at ${KC_URL}..."
for i in $(seq 1 40); do
    if curl -sf "${KC_URL}/health/ready" &>/dev/null; then
        ok "Keycloak is ready."
        break
    fi
    [ "$i" -eq 40 ] && err "Timeout waiting for Keycloak."
    sleep 5
done

# ─── Step 2: Get admin token ──────────────────────────────────────────────────
log "Authenticating as Keycloak admin..."
ADMIN_TOKEN=$(curl -sf -X POST "${KC_URL}/realms/master/protocol/openid-connect/token" \
    -d "client_id=admin-cli" \
    -d "username=${KC_ADMIN}" \
    -d "password=${KC_ADMIN_PW}" \
    -d "grant_type=password" | jq -r '.access_token')

[ -n "${ADMIN_TOKEN}" ] || err "Failed to authenticate as Keycloak admin."
ok "Admin token obtained."

auth_header() { echo "Authorization: Bearer ${ADMIN_TOKEN}"; }

# ─── Step 3: Verify realm 'lakehouse' exists ──────────────────────────────────
log "Verifying realm '${KC_REALM}'..."
REALM_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
    -H "$(auth_header)" \
    "${KC_URL}/admin/realms/${KC_REALM}")

if [ "${REALM_STATUS}" = "200" ]; then
    ok "Realm '${KC_REALM}' exists."
else
    log "Realm '${KC_REALM}' not found (status: ${REALM_STATUS}). Importing..."
    REALM_FILE="${REPO_ROOT}/local/volumes/keycloak/realm-export.json"
    [ -f "${REALM_FILE}" ] || err "realm-export.json not found at ${REALM_FILE}."

    # Substitute client secrets from env vars before posting
    REALM_JSON=$(envsubst < "${REALM_FILE}")

    curl -sf -X POST "${KC_URL}/admin/realms" \
        -H "$(auth_header)" \
        -H "Content-Type: application/json" \
        -d "${REALM_JSON}" > /dev/null
    ok "Realm '${KC_REALM}' imported."
fi

# ─── Step 4: Verify OIDC clients ──────────────────────────────────────────────
EXPECTED_CLIENTS=("trino" "airflow" "openmetadata" "grafana" "minio")

for client in "${EXPECTED_CLIENTS[@]}"; do
    log "Checking OIDC client '${client}'..."
    CLIENT_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
        -H "$(auth_header)" \
        "${KC_URL}/admin/realms/${KC_REALM}/clients?clientId=${client}")

    CLIENTS_FOUND=$(curl -sf \
        -H "$(auth_header)" \
        "${KC_URL}/admin/realms/${KC_REALM}/clients?clientId=${client}" \
        | jq '. | length')

    if [ "${CLIENTS_FOUND}" -gt 0 ]; then
        ok "Client '${client}' found."
    else
        err "Client '${client}' NOT found in realm '${KC_REALM}'. Re-import realm or add manually."
    fi
done

# ─── Step 5: Verify sample users ───────────────────────────────────────────────
EXPECTED_USERS=("alice.engineer" "bob.analyst" "carol.steward" "dave.admin" "eve.steward")

for username in "${EXPECTED_USERS[@]}"; do
    log "Checking user '${username}'..."
    USER_COUNT=$(curl -sf \
        -H "$(auth_header)" \
        "${KC_URL}/admin/realms/${KC_REALM}/users?username=${username}&exact=true" \
        | jq '. | length')

    if [ "${USER_COUNT}" -gt 0 ]; then
        ok "User '${username}' exists."
    else
        log "User '${username}' not found — realm import may have failed. Import manually if needed."
    fi
done

# ─── Step 6: Print OIDC discovery endpoints ────────────────────────────────────
echo ""
log "OIDC Configuration for realm '${KC_REALM}':"
echo "  Discovery URL:    ${KC_URL}/realms/${KC_REALM}/.well-known/openid-configuration"
echo "  JWKS URL:         ${KC_URL}/realms/${KC_REALM}/protocol/openid-connect/certs"
echo "  Token endpoint:   ${KC_URL}/realms/${KC_REALM}/protocol/openid-connect/token"
echo "  Auth endpoint:    ${KC_URL}/realms/${KC_REALM}/protocol/openid-connect/auth"

# Quick validation
DISCOVERY=$(curl -sf "${KC_URL}/realms/${KC_REALM}/.well-known/openid-configuration")
ISSUER=$(echo "${DISCOVERY}" | jq -r '.issuer')
echo ""
ok "OIDC discovery endpoint reachable. Issuer: ${ISSUER}"
echo ""
ok "Keycloak initialization complete!"
log "Next step: run scripts/bootstrap/03-init-minio.sh"
