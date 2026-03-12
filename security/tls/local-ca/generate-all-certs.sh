#!/usr/bin/env bash
# =============================================================================
# generate-all-certs.sh — Issue TLS certificates for all platform services
# =============================================================================
# Calls generate-service-cert.sh for every service in the Docker Compose stack.
# Idempotent: skips certs that are still valid (> 14 days remaining).
#
# Usage:
#   ./generate-all-certs.sh             # use default CA_DIR=./output
#   CA_DIR=/opt/lakehouse/tls ./generate-all-certs.sh
#   CERT_DAYS=365 ./generate-all-certs.sh   # override validity
# =============================================================================
set -euo pipefail

# ─── Colours ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; RESET='\033[0m'
log()  { echo -e "${GREEN}[ALL-CERTS]${RESET} $*"; }
warn() { echo -e "${YELLOW}[ALL-CERTS]${RESET} $*"; }
err()  { echo -e "${RED}[ALL-CERTS]${RESET} $*" >&2; exit 1; }

# ─── Config ───────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CA_DIR="${CA_DIR:-${SCRIPT_DIR}/output}"
export CERT_DAYS="${CERT_DAYS:-90}"

GEN="${SCRIPT_DIR}/generate-service-cert.sh"
[[ -x "${GEN}" ]] || err "${GEN} is not executable. Run: chmod +x ${GEN}"

# ─── Step 1: Ensure Root CA exists ────────────────────────────────────────────
if [[ ! -f "${CA_DIR}/rootCA.crt" ]]; then
    log "Root CA not found — generating..."
    "${SCRIPT_DIR}/generate-ca.sh"
else
    EXPIRY=$(openssl x509 -noout -enddate -in "${CA_DIR}/rootCA.crt" | cut -d= -f2)
    log "Root CA: ${CA_DIR}/rootCA.crt (expires: ${EXPIRY})"
fi

# ─── Service cert definitions ─────────────────────────────────────────────────
# Format: "service-name" "SAN list (comma-separated)"
# SAN items: DNS:<hostname>, IP:<address>
# Each service gets both its Docker Compose service name and localhost for dev.

declare -a SERVICES=(
    # ── Storage ────────────────────────────────────────────────────────────
    "minio-1"
        "DNS:minio-1,DNS:minio,DNS:localhost,IP:127.0.0.1"
    "minio-2"
        "DNS:minio-2,DNS:minio,DNS:localhost,IP:127.0.0.1"
    "minio-3"
        "DNS:minio-3,DNS:minio,DNS:localhost,IP:127.0.0.1"
    "minio-4"
        "DNS:minio-4,DNS:minio,DNS:localhost,IP:127.0.0.1"

    # ── Database ───────────────────────────────────────────────────────────
    "postgresql"
        "DNS:postgresql,DNS:pgbouncer,DNS:localhost,IP:127.0.0.1"
    "pgbouncer"
        "DNS:pgbouncer,DNS:localhost,IP:127.0.0.1"

    # ── Secrets ────────────────────────────────────────────────────────────
    "openbao-1"
        "DNS:openbao-1,DNS:openbao,DNS:localhost,IP:127.0.0.1"
    "openbao-2"
        "DNS:openbao-2,DNS:openbao,DNS:localhost,IP:127.0.0.1"
    "openbao-3"
        "DNS:openbao-3,DNS:openbao,DNS:localhost,IP:127.0.0.1"

    # ── Identity ───────────────────────────────────────────────────────────
    "keycloak"
        "DNS:keycloak,DNS:localhost,IP:127.0.0.1"

    # ── Catalog ────────────────────────────────────────────────────────────
    "polaris"
        "DNS:polaris,DNS:localhost,IP:127.0.0.1"
    "nessie"
        "DNS:nessie,DNS:localhost,IP:127.0.0.1"

    # ── Policy ─────────────────────────────────────────────────────────────
    "ranger-admin"
        "DNS:ranger-admin,DNS:ranger,DNS:localhost,IP:127.0.0.1"

    # ── Compute ────────────────────────────────────────────────────────────
    "trino-coordinator"
        "DNS:trino-coordinator,DNS:trino,DNS:localhost,IP:127.0.0.1"
    "trino-worker-1"
        "DNS:trino-worker-1,DNS:localhost,IP:127.0.0.1"
    "trino-worker-2"
        "DNS:trino-worker-2,DNS:localhost,IP:127.0.0.1"
    "trino-worker-3"
        "DNS:trino-worker-3,DNS:localhost,IP:127.0.0.1"
    "trino-gateway"
        "DNS:trino-gateway,DNS:localhost,IP:127.0.0.1"

    # ── Search ─────────────────────────────────────────────────────────────
    "elasticsearch"
        "DNS:elasticsearch,DNS:localhost,IP:127.0.0.1"

    # ── Metadata ───────────────────────────────────────────────────────────
    "openmetadata-server"
        "DNS:openmetadata-server,DNS:openmetadata,DNS:localhost,IP:127.0.0.1"

    # ── Ingestion ──────────────────────────────────────────────────────────
    "airflow-webserver"
        "DNS:airflow-webserver,DNS:airflow,DNS:localhost,IP:127.0.0.1"
    "docling-api"
        "DNS:docling-api,DNS:docling,DNS:localhost,IP:127.0.0.1"

    # ── Observability ──────────────────────────────────────────────────────
    "prometheus"
        "DNS:prometheus,DNS:localhost,IP:127.0.0.1"
    "grafana"
        "DNS:grafana,DNS:localhost,IP:127.0.0.1"
    "loki"
        "DNS:loki,DNS:localhost,IP:127.0.0.1"
    "otel-collector"
        "DNS:otel-collector,DNS:localhost,IP:127.0.0.1"
)

# ─── Iteration ────────────────────────────────────────────────────────────────
TOTAL=$(( ${#SERVICES[@]} / 2 ))
COUNT=0
SKIPPED=0
ISSUED=0
ERRORS=0

log "Issuing certificates for ${TOTAL} services (CA_DIR=${CA_DIR}, CERT_DAYS=${CERT_DAYS})..."
echo ""

for (( i=0; i<${#SERVICES[@]}; i+=2 )); do
    SVC="${SERVICES[i]}"
    SAN="${SERVICES[i+1]}"
    COUNT=$(( COUNT + 1 ))

    printf "${GREEN}[%2d/%d]${RESET} %-30s → %s\n" "${COUNT}" "${TOTAL}" "${SVC}" "${SAN}"

    if "${GEN}" "${SVC}" "${SAN}" 2>&1 | grep -q "Skipping"; then
        SKIPPED=$(( SKIPPED + 1 ))
    else
        if "${GEN}" "${SVC}" "${SAN}" &>/dev/null; then
            ISSUED=$(( ISSUED + 1 ))
        else
            warn "FAILED to issue cert for ${SVC}"
            ERRORS=$(( ERRORS + 1 ))
        fi
    fi
done

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
log "═══ Certificate generation summary ═══"
log "  Total services : ${TOTAL}"
log "  Issued (new)   : ${ISSUED}"
log "  Skipped (valid): ${SKIPPED}"
[[ ${ERRORS} -gt 0 ]] && warn "  Errors         : ${ERRORS}" || log "  Errors         : 0"
log "  Output dir     : ${CA_DIR}/"
echo ""

if [[ ${ERRORS} -gt 0 ]]; then
    err "Some certificates failed to generate. Check errors above."
fi

log "✓ All certificates ready."
log ""
log "To copy to local/volumes/tls/ for Docker Compose:"
log "  rsync -a ${CA_DIR}/ local/volumes/tls/"
