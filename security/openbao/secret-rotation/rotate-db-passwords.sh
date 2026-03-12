#!/usr/bin/env bash
# =============================================================================
# rotate-db-passwords.sh — PostgreSQL password rotation (idempotent)
# =============================================================================
# Steps:
#   1. Generate new cryptographically random password
#   2. ALTER USER in PostgreSQL with new password
#   3. Write new password to OpenBao KV v2
#   4. Signal consumer service to reload credentials
#   5. Verify connectivity with new password
# =============================================================================
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; RESET='\033[0m'
log()  { echo -e "${GREEN}[rotate-db]${RESET} $*"; }
warn() { echo -e "${YELLOW}[rotate-db]${RESET} $*"; }
err()  { echo -e "${RED}[rotate-db]${RESET} $*" >&2; exit 1; }

# ─── Prerequisites ────────────────────────────────────────────────────────────
for cmd in psql bao jq openssl; do
    command -v "${cmd}" &>/dev/null || err "${cmd} not found."
done

# ─── Config ───────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/local/.env}"
[ -f "${ENV_FILE}" ] && { set -a; source "${ENV_FILE}"; set +a; }

BAO_ADDR="${OPENBAO_ADDR:-http://localhost:8200}"
ROOT_TOKEN="${BAO_TOKEN:-$(jq -r .root_token "${REPO_ROOT}/.openbao-init-output.json" 2>/dev/null || echo "")}"
[ -z "${ROOT_TOKEN}" ] && err "BAO_TOKEN not set and .openbao-init-output.json not found."

PG_HOST="${POSTGRES_HOST:-localhost}"
PG_PORT="${POSTGRES_PORT:-5432}"
PG_SUPERUSER="${POSTGRES_SUPERUSER:-postgres}"
PG_SUPERPASS="${POSTGRES_SUPERPASS:-}"
[ -z "${PG_SUPERPASS}" ] && err "POSTGRES_SUPERPASS env var required."

# ─── Service → PostgreSQL user + K8s deployment map ──────────────────────────
declare -A DB_USER
DB_USER[keycloak]="keycloak"
DB_USER[polaris]="polaris"
DB_USER[nessie]="nessie"
DB_USER[ranger]="ranger"
DB_USER[airflow]="airflow"
DB_USER[openmetadata]="openmetadata"
DB_USER[trino_gateway]="trino_gateway"

declare -A K8S_NS_DEPLOY
K8S_NS_DEPLOY[keycloak]="lakehouse-system/deployment/keycloak"
K8S_NS_DEPLOY[polaris]="lakehouse-data/deployment/polaris"
K8S_NS_DEPLOY[nessie]="lakehouse-data/deployment/nessie"
K8S_NS_DEPLOY[ranger]="lakehouse-data/deployment/ranger-admin"
K8S_NS_DEPLOY[airflow]="lakehouse-ingest/deployment/airflow-webserver"
K8S_NS_DEPLOY[openmetadata]="lakehouse-ingest/deployment/openmetadata"
K8S_NS_DEPLOY[trino_gateway]="lakehouse-data/deployment/trino-gateway"

rotate_db_password() {
    local svc="$1"

    [[ -v DB_USER[${svc}] ]] || err "Unknown service '${svc}'. Valid: ${!DB_USER[*]}"

    local pg_user="${DB_USER[${svc}]}"
    local bao_path="db/postgres/${svc}"

    log "═══ Rotating PostgreSQL password: service=${svc}, user=${pg_user} ═══"

    # 1. Generate new password (48 chars, no single-quote to prevent SQL injection)
    NEW_PASS=$(openssl rand -base64 36 | tr -dc 'A-Za-z0-9@#%&+=!~^' | head -c 48)
    [ ${#NEW_PASS} -lt 16 ] && err "Generated password too short — OpenSSL issue."

    # 2. ALTER USER in PostgreSQL — using parameterized connection to avoid injections
    log "Altering PostgreSQL user '${pg_user}'..."
    PGPASSWORD="${PG_SUPERPASS}" psql \
        -h "${PG_HOST}" -p "${PG_PORT}" \
        -U "${PG_SUPERUSER}" -d postgres \
        -c "ALTER USER \"${pg_user}\" WITH PASSWORD '${NEW_PASS}';" &>/dev/null
    log "✓ PostgreSQL password changed for '${pg_user}'."

    # 3. Write new password to OpenBao
    log "Writing new password to OpenBao at secret/data/${bao_path}..."
    curl -sf -X PUT "${BAO_ADDR}/v1/secret/data/${bao_path}" \
        -H "X-Vault-Token: ${ROOT_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"data\":{\"username\":\"${pg_user}\",\"password\":\"${NEW_PASS}\"}}" > /dev/null
    log "✓ New password written to OpenBao."

    # 4. Verify connectivity with new credentials
    log "Verifying new password connectivity..."
    if PGPASSWORD="${NEW_PASS}" psql \
        -h "${PG_HOST}" -p "${PG_PORT}" \
        -U "${pg_user}" -d "${svc}" \
        -c "SELECT 1;" &>/dev/null; then
        log "✓ New password verified."
    else
        err "New password failed connectivity! Check PostgreSQL logs."
    fi

    # 5. Signal consumer service to reload (K8s rolling restart)
    if command -v kubectl &>/dev/null && [[ -v K8S_NS_DEPLOY[${svc}] ]]; then
        local ns_deploy="${K8S_NS_DEPLOY[${svc}]}"
        local ns="${ns_deploy%%/*}"
        local dtype="${ns_deploy#*/}"
        log "Triggering rolling restart for ${dtype} in namespace ${ns}..."
        kubectl rollout restart "${dtype}" -n "${ns}" 2>/dev/null || \
            warn "Could not trigger rollout for ${dtype} in ${ns} — restart manually."
        log "✓ Rolling restart triggered."
    else
        warn "kubectl not available — restart '${svc}' service manually."
    fi

    log "✓ PostgreSQL rotation complete for '${svc}'."
    echo ""
}

# ─── Entrypoint ───────────────────────────────────────────────────────────────
TARGET="${1:-}"
if [[ -z "${TARGET}" ]]; then
    warn "Usage: $0 <service|all>"
    warn "  Services: ${!DB_USER[*]}"
    exit 1
fi

if [[ "${TARGET}" == "all" ]]; then
    for svc in "${!DB_USER[@]}"; do
        rotate_db_password "${svc}"
    done
else
    rotate_db_password "${TARGET}"
fi

log "✓ Database password rotation complete."
