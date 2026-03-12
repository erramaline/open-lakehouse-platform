#!/usr/bin/env bash
# =============================================================================
# rotate-minio-keys.sh — MinIO service account key rotation (idempotent)
# =============================================================================
# Steps:
#   1. Generate new random access/secret key pair
#   2. Create new MinIO service account with new keys
#   3. Write new keys to OpenBao KV v2
#   4. Signal consumer services to reload (K8s rolling restart)
#   5. Disable old service account in MinIO
#   6. Verify new keys work
# =============================================================================
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; RESET='\033[0m'
log()  { echo -e "${GREEN}[rotate-minio]${RESET} $*"; }
warn() { echo -e "${YELLOW}[rotate-minio]${RESET} $*"; }
err()  { echo -e "${RED}[rotate-minio]${RESET} $*" >&2; exit 1; }

# ─── Prerequisites ────────────────────────────────────────────────────────────
for cmd in mc bao jq openssl; do
    command -v "${cmd}" &>/dev/null || err "${cmd} not found."
done

# ─── Config ───────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/local/.env}"
[ -f "${ENV_FILE}" ] && { set -a; source "${ENV_FILE}"; set +a; }

BAO_ADDR="${OPENBAO_ADDR:-http://localhost:8200}"
MINIO_URL="${MINIO_URL:-http://localhost:9000}"
MINIO_ALIAS="local-rotation"
ROOT_TOKEN="${BAO_TOKEN:-$(jq -r .root_token "${REPO_ROOT}/.openbao-init-output.json" 2>/dev/null || echo "")}"
[ -z "${ROOT_TOKEN}" ] && err "BAO_TOKEN not set and .openbao-init-output.json not found."

# ─── Which service account to rotate ─────────────────────────────────────────
TARGET="${1:-}"
VALID_TARGETS="polaris ingestion audit"
if [[ -z "${TARGET}" ]]; then
    warn "Usage: $0 <polaris|ingestion|audit>"
    warn "  Or:  $0 all   (rotate all service accounts)"
    exit 1
fi

rotate_account() {
    local svc="$1"
    local bao_path="storage/minio/${svc}"

    log "═══ Rotating MinIO service account: ${svc} ═══"

    # 1. Read current access key from OpenBao
    CURRENT_KEY=$(curl -sf -H "X-Vault-Token: ${ROOT_TOKEN}" \
        "${BAO_ADDR}/v1/secret/data/${bao_path}" | \
        jq -r '.data.data.access_key // ""')

    # 2. Generate new key pair (MinIO access keys: 20 chars uppercase alphanumeric)
    NEW_ACCESS_KEY=$(openssl rand -base64 15 | tr -dc 'A-Z0-9' | head -c 20)
    NEW_SECRET_KEY=$(openssl rand -base64 40 | tr -dc 'A-Za-z0-9' | head -c 40)

    # 3. Configure mc alias
    mc alias set "${MINIO_ALIAS}" "${MINIO_URL}" \
        "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" --insecure &>/dev/null

    # 4. Create new service account
    log "Creating new MinIO service account for '${svc}'..."
    mc admin user svcacct add "${MINIO_ALIAS}" "${MINIO_ROOT_USER}" \
        --access-key "${NEW_ACCESS_KEY}" \
        --secret-key "${NEW_SECRET_KEY}" \
        --insecure &>/dev/null
    log "✓ New service account created (access_key: ${NEW_ACCESS_KEY})"

    # 5. Write new keys to OpenBao (overwrites old version)
    log "Writing new keys to OpenBao at secret/data/${bao_path}..."
    curl -sf -X PUT "${BAO_ADDR}/v1/secret/data/${bao_path}" \
        -H "X-Vault-Token: ${ROOT_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"data\":{\"access_key\":\"${NEW_ACCESS_KEY}\",\"secret_key\":\"${NEW_SECRET_KEY}\"}}" > /dev/null
    log "✓ New keys written to OpenBao."

    # 6. Verify new keys work
    log "Verifying new keys..."
    mc alias set "${MINIO_ALIAS}-new" "${MINIO_URL}" \
        "${NEW_ACCESS_KEY}" "${NEW_SECRET_KEY}" --insecure &>/dev/null
    mc ls "${MINIO_ALIAS}-new" --insecure &>/dev/null && log "✓ New keys verified." || \
        err "New keys failed verification! Old keys still active."
    mc alias remove "${MINIO_ALIAS}-new" &>/dev/null || true

    # 7. Signal consumers to reload (Docker Compose: restart; K8s: rolling update)
    if command -v kubectl &>/dev/null; then
        case "${svc}" in
            polaris)    kubectl rollout restart deployment/polaris -n lakehouse-data 2>/dev/null    || true ;;
            ingestion)  kubectl rollout restart deployment/airflow -n lakehouse-ingest 2>/dev/null  || true
                        kubectl rollout restart deployment/docling -n lakehouse-ingest 2>/dev/null  || true ;;
            audit)      kubectl rollout restart deployment/otel-collector -n lakehouse-obs 2>/dev/null || true ;;
        esac
        log "✓ Rolling restart triggered for consumers of '${svc}'."
    else
        warn "kubectl not available — restart services manually or via 'make dev-restart'."
    fi

    # 8. Disable old service account (after consumers have restarted)
    if [[ -n "${CURRENT_KEY}" ]]; then
        log "Disabling old service account (access_key: ${CURRENT_KEY})..."
        sleep 10   # Grace period for in-flight requests
        mc admin user svcacct disable "${MINIO_ALIAS}" "${CURRENT_KEY}" --insecure &>/dev/null || \
            warn "Could not disable old key '${CURRENT_KEY}' (may not exist or already disabled)."
        log "✓ Old key disabled."
    fi

    mc alias remove "${MINIO_ALIAS}" &>/dev/null || true
    log "✓ MinIO key rotation complete for '${svc}'."
    echo ""
}

# ─── Execute ──────────────────────────────────────────────────────────────────
if [[ "${TARGET}" == "all" ]]; then
    for svc in polaris ingestion audit; do
        rotate_account "${svc}"
    done
else
    [[ "${VALID_TARGETS}" =~ ${TARGET} ]] || err "Unknown target '${TARGET}'. Valid: ${VALID_TARGETS} all"
    rotate_account "${TARGET}"
fi

log "✓ MinIO key rotation complete."
