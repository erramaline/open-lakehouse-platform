#!/usr/bin/env bash
# =============================================================================
# import-policies.sh — Import Ranger policies via REST API (idempotent)
# =============================================================================
# Checks if each policy exists by name; only creates if missing.
# Uses Ranger Admin REST API v2.
# =============================================================================
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; RESET='\033[0m'
log()  { echo -e "${GREEN}[ranger-import]${RESET} $*"; }
warn() { echo -e "${YELLOW}[ranger-import]${RESET} $*"; }
err()  { echo -e "${RED}[ranger-import]${RESET} $*" >&2; exit 1; }

# ─── Prerequisites ────────────────────────────────────────────────────────────
for cmd in curl jq; do
    command -v "${cmd}" &>/dev/null || err "${cmd} not found."
done

# ─── Config ───────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/local/.env}"
[ -f "${ENV_FILE}" ] && { set -a; source "${ENV_FILE}"; set +a; }

RANGER_URL="${RANGER_URL:-http://localhost:6080}"
RANGER_ADMIN_USER="${RANGER_ADMIN_USER:-admin}"
RANGER_ADMIN_PASS="${RANGER_ADMIN_PASS:-}"
SERVICE_NAME="${RANGER_SERVICE_NAME:-trino_lakehouse}"

[ -z "${RANGER_ADMIN_PASS}" ] && err "RANGER_ADMIN_PASS env var is required."

# Basic-auth header value (avoid shell injection by encoding separately)
AUTH_HEADER="Authorization: Basic $(echo -n "${RANGER_ADMIN_USER}:${RANGER_ADMIN_PASS}" | base64 -w0)"

POLICY_DIR="${SCRIPT_DIR}/policies"
POLICIES=(
    "schema-access.json"
    "iceberg-row-filter.json"
    "iceberg-column-mask.json"
    "audit-policy.json"
)

# ─── Wait for Ranger ──────────────────────────────────────────────────────────
log "Waiting for Ranger Admin at ${RANGER_URL}..."
for i in $(seq 1 30); do
    HTTP=$(curl -sf -o /dev/null -w "%{http_code}" "${RANGER_URL}/login.jsp" 2>/dev/null || echo "000")
    [[ "${HTTP}" == "200" ]] && break
    [[ "${i}" -eq 30 ]] && err "Ranger Admin not reachable after 150s."
    sleep 5
done
log "✓ Ranger Admin reachable."

# ─── Helper: does policy exist by name? ───────────────────────────────────────
policy_exists() {
    local name="$1"
    local encoded_name
    encoded_name=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "${name}" 2>/dev/null || \
                   echo "${name// /%20}")
    local count
    count=$(curl -sf \
        -H "${AUTH_HEADER}" \
        -H "Content-Type: application/json" \
        "${RANGER_URL}/service/public/v2/api/policy?serviceName=${SERVICE_NAME}&policyName=${encoded_name}" | \
        jq '.totalCount // 0')
    [[ "${count}" -gt 0 ]]
}

# ─── Helper: import a single policy file ──────────────────────────────────────
import_policy() {
    local file="$1"
    local filepath="${POLICY_DIR}/${file}"

    [ -f "${filepath}" ] || { warn "Policy file not found: ${filepath}"; return 1; }

    local policy_name
    policy_name=$(jq -r '.policyName' "${filepath}")
    local policy_type
    policy_type=$(jq -r '.policyType' "${filepath}")

    log "Processing policy '${policy_name}' (type=${policy_type})..."

    if policy_exists "${policy_name}"; then
        warn "  → Already exists — skipping '${policy_name}'."
        return 0
    fi

    # Inject the correct service name (may differ from dev default)
    local payload
    payload=$(jq --arg svc "${SERVICE_NAME}" '.serviceName = $svc' "${filepath}")

    local http_code
    http_code=$(curl -sf -X POST \
        -H "${AUTH_HEADER}" \
        -H "Content-Type: application/json" \
        -d "${payload}" \
        -o /tmp/ranger_response.json \
        -w "%{http_code}" \
        "${RANGER_URL}/service/public/v2/api/policy" 2>/dev/null || echo "000")

    if [[ "${http_code}" == "200" ]] || [[ "${http_code}" == "201" ]]; then
        local created_id
        created_id=$(jq -r '.id // "unknown"' /tmp/ranger_response.json)
        log "  ✓ Created policy '${policy_name}' (id=${created_id})."
    else
        local error_msg
        error_msg=$(jq -r '.msgDesc // .message // "unknown error"' /tmp/ranger_response.json 2>/dev/null || echo "unknown error")
        err "  Failed to create policy '${policy_name}' (HTTP ${http_code}): ${error_msg}"
    fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────
log "Importing ${#POLICIES[@]} Ranger policies into service '${SERVICE_NAME}'..."
echo ""

for policy_file in "${POLICIES[@]}"; do
    import_policy "${policy_file}"
done

echo ""
log "✓ All policies imported."
log "View in Ranger UI: ${RANGER_URL}"
rm -f /tmp/ranger_response.json
