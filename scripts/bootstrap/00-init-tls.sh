#!/usr/bin/env bash
# =============================================================================
# 00-init-tls.sh — Generate local CA and TLS certificates for all services
# =============================================================================
# Generates:
#   - A self-signed local CA  (lakehouse-local-ca)
#   - Per-service TLS certificates signed by the local CA
#
# Output directory: local/volumes/tls/
# Structure:
#   volumes/tls/ca/         — CA cert and key
#   volumes/tls/<service>/  — cert.pem, key.pem, fullchain.pem per service
#
# Services covered: openbao, keycloak, polaris, nessie, trino, ranger,
#   minio, postgresql, openmetadata, airflow, elasticsearch, grafana, docling
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TLS_DIR="${REPO_ROOT}/local/volumes/tls"
CA_DIR="${TLS_DIR}/ca"

# Certificate parameters
CA_SUBJECT="/C=US/O=Open Lakehouse Platform/CN=Lakehouse Local CA"
CERT_DAYS=365     # 1 year for local dev (prod uses cert-manager + OpenBao PKI)
CA_DAYS=3650      # 10 years for local CA

log()  { echo "[00-init-tls] $*"; }
ok()   { echo "[00-init-tls] ✓ $*"; }
err()  { echo "[00-init-tls] ✗ $*" >&2; exit 1; }

command -v openssl >/dev/null || err "openssl not found. Install openssl."

# Create output directories
mkdir -p "${CA_DIR}"

# ─── Step 1: Generate Local CA ─────────────────────────────────────────────────

if [ -f "${CA_DIR}/ca.crt" ]; then
    log "Local CA already exists — skipping CA generation."
else
    log "Generating local CA key and certificate..."
    openssl genrsa -out "${CA_DIR}/ca.key" 4096
    openssl req -x509 -new -nodes \
        -key "${CA_DIR}/ca.key" \
        -sha256 \
        -days "${CA_DAYS}" \
        -out "${CA_DIR}/ca.crt" \
        -subj "${CA_SUBJECT}"
    ok "Local CA certificate generated at ${CA_DIR}/ca.crt"
fi

# ─── Helper: generate a cert for a service ────────────────────────────────────

generate_cert() {
    local service="$1"
    shift
    local sans=("$@")   # additional Subject Alternative Names

    local svc_dir="${TLS_DIR}/${service}"
    mkdir -p "${svc_dir}"

    if [ -f "${svc_dir}/cert.pem" ]; then
        log "Certificate for '${service}' already exists — skipping."
        return
    fi

    log "Generating certificate for '${service}'..."

    # Build SAN extension config
    local san_string="DNS:${service},DNS:localhost,IP:127.0.0.1"
    for san in "${sans[@]}"; do
        san_string="${san_string},${san}"
    done

    # Generate private key
    openssl genrsa -out "${svc_dir}/key.pem" 2048

    # Generate CSR
    openssl req -new \
        -key "${svc_dir}/key.pem" \
        -subj "/C=US/O=Open Lakehouse Platform/CN=${service}" \
        -addext "subjectAltName=${san_string}" \
        -out "${svc_dir}/${service}.csr"

    # Sign with local CA
    openssl x509 -req \
        -in "${svc_dir}/${service}.csr" \
        -CA "${CA_DIR}/ca.crt" \
        -CAkey "${CA_DIR}/ca.key" \
        -CAcreateserial \
        -out "${svc_dir}/cert.pem" \
        -days "${CERT_DAYS}" \
        -sha256 \
        -extfile <(echo "subjectAltName=${san_string}")

    # Create fullchain (cert + CA)
    cat "${svc_dir}/cert.pem" "${CA_DIR}/ca.crt" > "${svc_dir}/fullchain.pem"

    # Cleanup CSR
    rm -f "${svc_dir}/${service}.csr"

    ok "Certificate for '${service}' generated."
}

# ─── Step 2: Generate per-service certificates ─────────────────────────────────

generate_cert "openbao-1" "DNS:openbao-1" "IP:172.30.0.10"
generate_cert "openbao-2" "DNS:openbao-2" "IP:172.30.0.11"
generate_cert "openbao-3" "DNS:openbao-3" "IP:172.30.0.12"
generate_cert "keycloak"
generate_cert "polaris"
generate_cert "nessie"
generate_cert "trino-coordinator" "DNS:trino-coordinator"
generate_cert "trino-worker-1"    "DNS:trino-worker-1"
generate_cert "trino-worker-2"    "DNS:trino-worker-2"
generate_cert "trino-worker-3"    "DNS:trino-worker-3"
generate_cert "trino-gateway"
generate_cert "ranger-admin"      "DNS:ranger-admin"
generate_cert "minio"             "DNS:minio-1" "DNS:minio-2" "DNS:minio-3" "DNS:minio-4"
generate_cert "postgresql"
generate_cert "pgbouncer"
generate_cert "elasticsearch"
generate_cert "openmetadata-server"
generate_cert "airflow-webserver"
generate_cert "grafana"
generate_cert "docling-api"
generate_cert "otel-collector"
generate_cert "loki"
generate_cert "prometheus"

# ─── Step 3: Set restrictive permissions (keys must not be world-readable) ──────
find "${TLS_DIR}" -name "key.pem" -exec chmod 600 {} \;
find "${TLS_DIR}" -name "ca.key"  -exec chmod 600 {} \;

# ─── Step 4: Print summary ─────────────────────────────────────────────────────
log "TLS certificate summary:"
for svc_dir in "${TLS_DIR}"/*/; do
    svc=$(basename "${svc_dir}")
    if [ -f "${svc_dir}/cert.pem" ]; then
        expiry=$(openssl x509 -noout -enddate -in "${svc_dir}/cert.pem" | cut -d= -f2)
        echo "  ${svc}: expires ${expiry}"
    fi
done

echo ""
ok "All TLS certificates generated in ${TLS_DIR}"
echo ""
echo "To trust the local CA on macOS:"
echo "  sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ${CA_DIR}/ca.crt"
echo ""
echo "To trust the local CA on Linux (Ubuntu/Debian):"
echo "  sudo cp ${CA_DIR}/ca.crt /usr/local/share/ca-certificates/lakehouse-local-ca.crt"
echo "  sudo update-ca-certificates"
