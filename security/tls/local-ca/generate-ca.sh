#!/usr/bin/env bash
# =============================================================================
# generate-ca.sh — Create the local development Root CA
# =============================================================================
# Outputs:
#   ${CA_DIR}/rootCA.key   — Root CA private key (4096-bit RSA, mode 600)
#   ${CA_DIR}/rootCA.crt   — Root CA self-signed certificate (10-year validity)
#   ${CA_DIR}/rootCA.srl   — Serial number file
# =============================================================================
set -euo pipefail

# ─── Colours ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; RESET='\033[0m'
log()  { echo -e "${GREEN}[CA]${RESET} $*"; }
warn() { echo -e "${YELLOW}[CA]${RESET} $*"; }
err()  { echo -e "${RED}[CA]${RESET} $*" >&2; exit 1; }

# ─── Prerequisites ────────────────────────────────────────────────────────────
command -v openssl &>/dev/null || err "openssl not found. Install: apt install openssl"

# ─── Config ───────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CA_DIR="${CA_DIR:-${SCRIPT_DIR}/output}"
CA_SUBJECT="${CA_SUBJECT:-/C=US/ST=Local/L=Dev/O=OpenLakehouse/CN=Open Lakehouse Local CA}"
CA_DAYS="${CA_DAYS:-3650}"   # 10 years for local dev CA

mkdir -p "${CA_DIR}"
chmod 750 "${CA_DIR}"

# ─── Idempotency check ────────────────────────────────────────────────────────
if [[ -f "${CA_DIR}/rootCA.crt" && -f "${CA_DIR}/rootCA.key" ]]; then
    EXPIRY=$(openssl x509 -noout -enddate -in "${CA_DIR}/rootCA.crt" | cut -d= -f2)
    warn "Root CA already exists (expires: ${EXPIRY}). Skipping regeneration."
    warn "To regenerate: rm ${CA_DIR}/rootCA.{key,crt,srl} && run again."
    exit 0
fi

# ─── OpenSSL config for v3 CA ─────────────────────────────────────────────────
CA_CONF=$(mktemp /tmp/ca-openssl-XXXXXX.cnf)
trap 'rm -f "${CA_CONF}"' EXIT

cat > "${CA_CONF}" <<EOF
[req]
default_bits        = 4096
default_md          = sha256
prompt              = no
distinguished_name  = dn
x509_extensions     = v3_ca

[dn]
C  = US
ST = Local
L  = Dev
O  = OpenLakehouse
CN = Open Lakehouse Local CA

[v3_ca]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints       = critical, CA:TRUE, pathlen:1
keyUsage               = critical, digitalSignature, cRLSign, keyCertSign
EOF

# ─── Generate CA private key ──────────────────────────────────────────────────
log "Generating Root CA private key (4096-bit RSA)..."
openssl genrsa -out "${CA_DIR}/rootCA.key" 4096 2>/dev/null
chmod 600 "${CA_DIR}/rootCA.key"
log "Root CA key: ${CA_DIR}/rootCA.key"

# ─── Generate self-signed Root CA certificate ─────────────────────────────────
log "Generating self-signed Root CA certificate (${CA_DAYS} days)..."
openssl req \
    -new -x509 \
    -key    "${CA_DIR}/rootCA.key" \
    -out    "${CA_DIR}/rootCA.crt" \
    -days   "${CA_DAYS}" \
    -config "${CA_CONF}" \
    -extensions v3_ca
chmod 644 "${CA_DIR}/rootCA.crt"

# ─── Initialize serial number ─────────────────────────────────────────────────
echo "01" > "${CA_DIR}/rootCA.srl"
log "Root CA certificate: ${CA_DIR}/rootCA.crt"

# ─── Summary ─────────────────────────────────────────────────────────────────
log "Root CA fingerprint (SHA-256):"
openssl x509 -noout -fingerprint -sha256 -in "${CA_DIR}/rootCA.crt"
log "Root CA validity:"
openssl x509 -noout -dates -in "${CA_DIR}/rootCA.crt"

echo ""
log "✓ Root CA created successfully in ${CA_DIR}/"
echo ""
warn "To trust this CA on your machine:"
warn "  macOS:  sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ${CA_DIR}/rootCA.crt"
warn "  Linux:  sudo cp ${CA_DIR}/rootCA.crt /usr/local/share/ca-certificates/lakehouse-local-ca.crt && sudo update-ca-certificates"
warn "  Windows: Import ${CA_DIR}/rootCA.crt into 'Trusted Root Certification Authorities'"
