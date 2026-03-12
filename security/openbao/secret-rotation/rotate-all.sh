#!/usr/bin/env bash
# =============================================================================
# rotate-all.sh — Orchestrate full secret rotation in safe dependency order
# =============================================================================
# Order (chosen to minimise blast radius):
#   1. PostgreSQL passwords  (no other secret depends on these)
#   2. MinIO service account keys
#   3. Application secrets (Keycloak client secrets, Airflow fernet key, etc.)
# Full health gate between each group.
# =============================================================================
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; RESET='\033[0m'
log()  { echo -e "${GREEN}[rotate-all]${RESET} $*"; }
warn() { echo -e "${YELLOW}[rotate-all]${RESET} $*"; }
err()  { echo -e "${RED}[rotate-all]${RESET} $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

ROTATE_DB="${SCRIPT_DIR}/rotate-db-passwords.sh"
ROTATE_MINIO="${SCRIPT_DIR}/rotate-minio-keys.sh"

# ─── Helper: health check all core services ───────────────────────────────────
health_gate() {
    local label="$1"
    log "━━━ Health gate: ${label} ━━━"
    local failed=0

    check() {
        local svc="$1"; local url="$2"; local code="$3"
        if curl -sf -o /dev/null -w "%{http_code}" "${url}" 2>/dev/null | grep -qE "${code}"; then
            log "  ✓ ${svc}"
        else
            warn "  ✗ ${svc} not healthy at ${url}"
            failed=$((failed + 1))
        fi
    }

    ENV_FILE="${ENV_FILE:-${REPO_ROOT}/local/.env}"
    [ -f "${ENV_FILE}" ] && { set -a; source "${ENV_FILE}"; set +a; }

    PG_HOST="${POSTGRES_HOST:-localhost}"
    MINIO_URL="${MINIO_URL:-http://localhost:9000}"

    check "PostgreSQL" "http://${PG_HOST}:${POSTGRES_PORT:-5432}" "(52|000)"
    # MinIO — health check endpoint
    check "MinIO" "${MINIO_URL}/minio/health/live" "200"
    # OpenBao
    check "OpenBao" "${OPENBAO_ADDR:-http://localhost:8200}/v1/sys/health" "200|429|473"

    if [[ "${failed}" -gt 0 ]]; then
        err "Health gate '${label}': ${failed} service(s) unhealthy — aborting rotation."
    fi
    log "✓ All services healthy — continuing."
    echo ""
}

# ─── Dry-run flag ─────────────────────────────────────────────────────────────
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true && warn "DRY RUN mode — no actual changes."

run() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        warn "[dry-run] would run: bash $*"
    else
        bash "$@"
    fi
}

# ─── Main rotation sequence ───────────────────────────────────────────────────
log "╔══════════════════════════════════════════════════════════╗"
log "║         Open Lakehouse Platform — Full Rotation          ║"
log "╚══════════════════════════════════════════════════════════╝"
echo ""

health_gate "pre-rotation"

log "━━━ Phase 1: PostgreSQL passwords ━━━"
for svc in keycloak polaris nessie ranger airflow openmetadata trino_gateway; do
    run "${ROTATE_DB}" "${svc}"
done
log "✓ Phase 1 complete."
echo ""

health_gate "post-db-rotation"

log "━━━ Phase 2: MinIO service account keys ━━━"
for svc in polaris ingestion audit; do
    run "${ROTATE_MINIO}" "${svc}"
done
log "✓ Phase 2 complete."
echo ""

health_gate "post-minio-rotation"

log "━━━ Phase 3: Application secrets ━━━"
BAO_ADDR="${OPENBAO_ADDR:-http://localhost:8200}"
ROOT_TOKEN="${BAO_TOKEN:-$(jq -r .root_token "${REPO_ROOT}/.openbao-init-output.json" 2>/dev/null || echo "")}"

rotate_app_secret() {
    local label="$1"; local path="$2"; shift 2
    local payload="$*"
    if [[ "${DRY_RUN}" == "true" ]]; then
        warn "[dry-run] would rotate ${label} at secret/data/${path}"
        return
    fi
    log "Rotating ${label}..."
    curl -sf -X PUT "${BAO_ADDR}/v1/secret/data/${path}" \
        -H "X-Vault-Token: ${ROOT_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"data\":{${payload}}}" > /dev/null
    log "✓ ${label} rotated."
}

# Airflow fernet key (must be Fernet-valid 32-byte base64url key)
FERNET_KEY=$(python3 -c \
    "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())" \
    2>/dev/null || \
    openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')
rotate_app_secret "Airflow fernet key" "ingestion/airflow/fernet-key" \
    "\"key\":\"${FERNET_KEY}\""

# Airflow webserver secret
WEBSERVER_SECRET=$(openssl rand -hex 32)
rotate_app_secret "Airflow webserver secret" "ingestion/airflow/webserver-secret" \
    "\"secret_key\":\"${WEBSERVER_SECRET}\""

# OpenMetadata JWT signing secret
OM_JWT=$(openssl rand -hex 32)
rotate_app_secret "OpenMetadata JWT secret" "metadata/openmetadata/jwt-secret" \
    "\"secret\":\"${OM_JWT}\""

# Alertmanager webhook token
AM_TOKEN=$(openssl rand -hex 24)
rotate_app_secret "Alertmanager webhook token" "observability/alertmanager/webhook" \
    "\"token\":\"${AM_TOKEN}\""

# Grafana admin password
GRAFANA_PASS=$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9@#' | head -c 20)
rotate_app_secret "Grafana admin password" "observability/grafana/admin" \
    "\"username\":\"admin\",\"password\":\"${GRAFANA_PASS}\""

log "✓ Phase 3 complete."
echo ""

health_gate "post-rotation"

log "╔══════════════════════════════════════════════════════════╗"
log "║             Full rotation completed successfully          ║"
log "╚══════════════════════════════════════════════════════════╝"
log "Next steps:"
log "  • Audit OpenBao KV version history: bao kv metadata get -mount=secret <path>"
log "  • Verify service logs for successful re-authentication"
log "  • Run smoke tests: make test-smoke"
