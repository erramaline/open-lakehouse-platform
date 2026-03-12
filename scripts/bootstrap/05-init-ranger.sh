#!/usr/bin/env bash
# =============================================================================
# 05-init-ranger.sh — Bootstrap Apache Ranger 2.6.0
# =============================================================================
# Steps:
#   1. Download Ranger Trino plugin JAR (if not present)
#   2. Wait for Ranger Admin to be healthy
#   3. Register Trino service definition via Ranger REST API
#   4. Create initial policies (trino service + deny-all default)
#   5. Trigger manual user/group sync from Keycloak (via LDAP)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
ENV_FILE="${REPO_ROOT}/local/.env"

log()  { echo "[05-init-ranger] $*"; }
ok()   { echo "[05-init-ranger] ✓ $*"; }
err()  { echo "[05-init-ranger] ✗ $*" >&2; exit 1; }

[ -f "${ENV_FILE}" ] || err ".env file not found at ${ENV_FILE}"
set -a; source "${ENV_FILE}"; set +a

RANGER_URL="${RANGER_URL:-http://localhost:6080}"
RANGER_USER="${RANGER_ADMIN_USER:-admin}"
RANGER_PASS="${RANGER_ADMIN_PASSWORD}"
RANGER_AUTH="${RANGER_USER}:${RANGER_PASS}"

RANGER_VERSION="2.6.0"
PLUGIN_DIR="${REPO_ROOT}/local/volumes/trino/ranger-plugin"
PLUGIN_JAR="${PLUGIN_DIR}/ranger-${RANGER_VERSION}-trino-plugin.tar.gz"
APACHE_DL="https://archive.apache.org/dist/ranger/${RANGER_VERSION}"

# ─── Step 1: Download Trino plugin ────────────────────────────────────────────
log "Checking Ranger Trino plugin..."
mkdir -p "${PLUGIN_DIR}"

if ls "${PLUGIN_DIR}"/ranger-trino-plugin-impl-*.jar &>/dev/null 2>&1; then
    ok "Ranger Trino plugin JAR already present in ${PLUGIN_DIR}."
else
    log "Downloading Ranger ${RANGER_VERSION} Trino plugin..."
    TARBALL="ranger-${RANGER_VERSION}-trino-plugin.tar.gz"

    if [ ! -f "${PLUGIN_DIR}/${TARBALL}" ]; then
        wget -q --show-progress \
            "${APACHE_DL}/${TARBALL}" \
            -O "${PLUGIN_DIR}/${TARBALL}" || \
        curl -L --progress-bar \
            "${APACHE_DL}/${TARBALL}" \
            -o "${PLUGIN_DIR}/${TARBALL}" || \
        err "Failed to download Ranger Trino plugin. Check DL URL: ${APACHE_DL}/${TARBALL}"
    fi

    log "Extracting Ranger Trino plugin..."
    tar -xzf "${PLUGIN_DIR}/${TARBALL}" \
        --wildcards "*/lib/ranger-trino-plugin-impl-*.jar" \
        --strip-components=2 \
        -C "${PLUGIN_DIR}/"

    # Also extract the Ranger-related deps (ranger-plugins-common etc.)
    tar -xzf "${PLUGIN_DIR}/${TARBALL}" \
        --wildcards "*/lib/*.jar" \
        --strip-components=2 \
        -C "${PLUGIN_DIR}/" 2>/dev/null || true

    ok "Ranger Trino plugin JAR extracted to ${PLUGIN_DIR}."
fi

# ─── Step 2: Wait for Ranger Admin ────────────────────────────────────────────
log "Waiting for Ranger Admin on ${RANGER_URL}..."
for i in $(seq 1 60); do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        -u "${RANGER_AUTH}" "${RANGER_URL}/service/public/v2/api/servicedef" 2>/dev/null || echo "000")
    if [ "${HTTP_CODE}" = "200" ]; then
        ok "Ranger Admin is healthy."
        break
    fi
    [ "$i" -eq 60 ] && err "Timeout waiting for Ranger Admin at ${RANGER_URL}."
    sleep 5
done

# ─── Ranger helper functions ───────────────────────────────────────────────────
ranger_get() {
    curl -sf -u "${RANGER_AUTH}" -H "Accept: application/json" \
        "${RANGER_URL}${1}"
}

ranger_post() {
    curl -sf -u "${RANGER_AUTH}" \
        -H "Content-Type: application/json" -H "Accept: application/json" \
        -X POST "${RANGER_URL}${1}" -d "${2}"
}

ranger_put() {
    curl -sf -u "${RANGER_AUTH}" \
        -H "Content-Type: application/json" -H "Accept: application/json" \
        -X PUT "${RANGER_URL}${1}" -d "${2}"
}

# ─── Step 3: Create/verify Trino service ─────────────────────────────────────
log "Registering Trino service in Ranger..."

SERVICE_EXISTS=$(ranger_get "/service/public/v2/api/service?serviceName=trino_lakehouse" | \
    python3 -c "import sys,json; s=json.load(sys.stdin); print('yes' if s.get('id') else 'no')" 2>/dev/null || echo "no")

if [ "${SERVICE_EXISTS}" = "yes" ]; then
    log "Ranger Trino service 'trino_lakehouse' already exists."
else
    ranger_post "/service/public/v2/api/service" '{
      "name":        "trino_lakehouse",
      "displayName": "Trino Lakehouse",
      "description": "Trino cluster connected to Polaris + Nessie catalogs",
      "type":        "trino",
      "isEnabled":   true,
      "configs": {
        "jdbc.driverClassName": "io.trino.jdbc.TrinoDriver",
        "jdbc.url":             "jdbc:trino://trino-coordinator:8080",
        "username":             "'"${RANGER_TRINO_USER:-trino}"'",
        "password":             "'"${RANGER_TRINO_PASSWORD:-}"'"
      }
    }'
    ok "Ranger Trino service 'trino_lakehouse' created."
fi

# ─── Step 4: Create access policies ───────────────────────────────────────────

create_policy_if_missing() {
    local policy_name="$1"
    local policy_json="$2"

    EXISTS=$(ranger_get "/service/public/v2/api/policy?serviceName=trino_lakehouse&policyName=${policy_name}" | \
        python3 -c "import sys,json; ps=json.load(sys.stdin); print('yes' if ps else 'no')" 2>/dev/null || echo "no")

    if [ "${EXISTS}" = "yes" ]; then
        log "Policy '${policy_name}' already exists."
    else
        ranger_post "/service/public/v2/api/policy" "${policy_json}"
        ok "Policy '${policy_name}' created."
    fi
}

# Policy: analysts — SELECT on all tables in curated.*
create_policy_if_missing "analysts-select-curated" '{
  "name":        "analysts-select-curated",
  "description": "Analysts can SELECT from all tables in the curated namespace",
  "service":     "trino_lakehouse",
  "isEnabled":   true,
  "isAuditEnabled": true,
  "resources": {
    "catalog":   {"values":["lakehouse"],"isExcludes":false,"isRecursive":false},
    "schema":    {"values":["curated"],"isExcludes":false,"isRecursive":false},
    "table":     {"values":["*"],"isExcludes":false,"isRecursive":false},
    "column":    {"values":["*"],"isExcludes":false,"isRecursive":false}
  },
  "policyItems": [{
    "accesses":   [{"type":"select","isAllowed":true}],
    "users":      [],
    "groups":     ["lakehouse-analyst"],
    "conditions": [],
    "delegateAdmin": false
  }]
}'

# Policy: engineers — full access to all catalogs
create_policy_if_missing "engineers-full-access" '{
  "name":        "engineers-full-access",
  "description": "Data engineers have full access to all catalogs",
  "service":     "trino_lakehouse",
  "isEnabled":   true,
  "isAuditEnabled": true,
  "resources": {
    "catalog":   {"values":["*"],"isExcludes":false,"isRecursive":false},
    "schema":    {"values":["*"],"isExcludes":false,"isRecursive":false},
    "table":     {"values":["*"],"isExcludes":false,"isRecursive":false},
    "column":    {"values":["*"],"isExcludes":false,"isRecursive":false}
  },
  "policyItems": [{
    "accesses":   [
      {"type":"select","isAllowed":true},
      {"type":"insert","isAllowed":true},
      {"type":"update","isAllowed":true},
      {"type":"delete","isAllowed":true},
      {"type":"create","isAllowed":true},
      {"type":"drop","isAllowed":true},
      {"type":"alter","isAllowed":true},
      {"type":"index","isAllowed":true},
      {"type":"lock","isAllowed":true},
      {"type":"all","isAllowed":true}
    ],
    "users":      [],
    "groups":     ["lakehouse-engineer"],
    "conditions": [],
    "delegateAdmin": false
  }]
}'

# Policy: column masking — mask PII columns (email, phone, ssn) for non-steward users
create_policy_if_missing "pii-column-masking" '{
  "name":        "pii-column-masking",
  "description": "Mask PII columns (email, phone, ssn) for non-stewards",
  "service":     "trino_lakehouse",
  "policyType":  1,
  "isEnabled":   true,
  "isAuditEnabled": true,
  "resources": {
    "catalog":   {"values":["lakehouse"],"isExcludes":false,"isRecursive":false},
    "schema":    {"values":["*"],"isExcludes":false,"isRecursive":false},
    "table":     {"values":["*"],"isExcludes":false,"isRecursive":false},
    "column":    {"values":["email","phone","ssn"],"isExcludes":false,"isRecursive":false}
  },
  "dataMaskPolicyItems": [{
    "accesses":       [{"type":"select","isAllowed":true}],
    "users":          [],
    "groups":         ["lakehouse-analyst","lakehouse-engineer"],
    "conditions":     [],
    "delegateAdmin":  false,
    "dataMaskInfo":   {"dataMaskType":"MASK_SHOW_LAST_4"}
  }]
}'

# Policy: admin — all except UGS admin
create_policy_if_missing "admins-full-access" '{
  "name":        "admins-full-access",
  "description": "Platform admins have unrestricted Trino access",
  "service":     "trino_lakehouse",
  "isEnabled":   true,
  "isAuditEnabled": true,
  "resources": {
    "catalog":   {"values":["*"],"isExcludes":false,"isRecursive":false},
    "schema":    {"values":["*"],"isExcludes":false,"isRecursive":false},
    "table":     {"values":["*"],"isExcludes":false,"isRecursive":false},
    "column":    {"values":["*"],"isExcludes":false,"isRecursive":false}
  },
  "policyItems": [{
    "accesses":   [{"type":"all","isAllowed":true}],
    "users":      [],
    "groups":     ["lakehouse-admin"],
    "conditions": [],
    "delegateAdmin": true
  }]
}'

# ─── Step 5: Trigger user/group sync ──────────────────────────────────────────
log "Triggering Ranger User/Group Sync from Keycloak LDAP..."
ranger_post "/service/xusers/secure/ugsync/audits" '{}' &>/dev/null || \
    log "(sync trigger may not be available via REST — sync runs every 30 min automatically)"

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
log "Ranger services:"
ranger_get "/service/public/v2/api/service" | \
    python3 -c "import sys,json; [print(f'  - {s[\"name\"]} (id={s[\"id\"]})'  ) for s in json.load(sys.stdin)]" 2>/dev/null || true

log "Ranger policies:"
ranger_get "/service/public/v2/api/policy?serviceName=trino_lakehouse" | \
    python3 -c "import sys,json; [print(f'  - {p[\"name\"]}') for p in json.load(sys.stdin)]" 2>/dev/null || true

echo ""
ok "Ranger initialization complete!"
log "Ranger Admin UI: ${RANGER_URL}"
log "Next step: run scripts/bootstrap/06-init-openmetadata.sh"
