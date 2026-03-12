#!/usr/bin/env bash
# =============================================================================
# generate-service-cert.sh <service-name> <san>
# =============================================================================
# Signs a TLS certificate for a service using the local Root CA.
#
# Arguments:
#   $1  service-name  — used as directory name and cert CN (e.g. trino-coordinator)
#   $2  san           — comma-separated Subject Alternative Names
#                       (e.g. "DNS:trino-coordinator,DNS:localhost,IP:127.0.0.1")
#
# Outputs (in ${CA_DIR}/<service-name>/):
#   server.key      — Service private key (2048-bit RSA, mode 600)
#   server.csr      — Certificate signing request
#   server.crt      — Signed certificate (90-day validity)
#   fullchain.crt   — server.crt + rootCA.crt (full chain for TLS servers)
#
# Environment variables:
#   CA_DIR          — path to CA output dir (default: ./output)
#   CERT_DAYS       — cert validity in days (default: 90)
# =============================================================================
set -euo pipefail

# ─── Colours ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; RESET='\033[0m'
log()  { echo -e "${GREEN}[CERT:${SVC}]${RESET} $*"; }
warn() { echo -e "${YELLOW}[CERT:${SVC}]${RESET} $*"; }
err()  { echo -e "${RED}[CERT:${SVC}]${RESET} $*" >&2; exit 1; }

# ─── Prerequisites ────────────────────────────────────────────────────────────
command -v openssl &>/dev/null || err "openssl not found. Install: apt install openssl"

# ─── Args ─────────────────────────────────────────────────────────────────────
[[ $# -lt 2 ]] && err "Usage: $0 <service-name> <san>\n  Example: $0 trino-coordinator \"DNS:trino-coordinator,DNS:localhost,IP:127.0.0.1\""

SVC="$1"
SAN="$2"

# ─── Config ───────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CA_DIR="${CA_DIR:-${SCRIPT_DIR}/output}"
CERT_DAYS="${CERT_DAYS:-90}"
OUT_DIR="${CA_DIR}/${SVC}"

# ─── CA existence check ───────────────────────────────────────────────────────
[[ -f "${CA_DIR}/rootCA.key" ]] || err "Root CA key not found at ${CA_DIR}/rootCA.key. Run generate-ca.sh first."
[[ -f "${CA_DIR}/rootCA.crt" ]] || err "Root CA cert not found at ${CA_DIR}/rootCA.crt. Run generate-ca.sh first."

mkdir -p "${OUT_DIR}"

# ─── Idempotency check ────────────────────────────────────────────────────────
if [[ -f "${OUT_DIR}/server.crt" ]]; then
    EXPIRY=$(openssl x509 -noout -enddate -in "${OUT_DIR}/server.crt" | cut -d= -f2)
    # Check if cert expires in < 14 days
    EXPIRY_EPOCH=$(date -d "${EXPIRY}" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "${EXPIRY}" +%s 2>/dev/null || echo 0)
    NOW_EPOCH=$(date +%s)
    DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))
    if [[ ${DAYS_LEFT} -gt 14 ]]; then
        warn "Certificate for '${SVC}' already exists (expires in ${DAYS_LEFT} days). Skipping."
        exit 0
    fi
    warn "Certificate for '${SVC}' expires in ${DAYS_LEFT} days — regenerating."
fi

# ─── OpenSSL extension config ─────────────────────────────────────────────────
EXT_CONF=$(mktemp /tmp/cert-ext-XXXXXX.cnf)
trap 'rm -f "${EXT_CONF}"' EXIT

cat > "${EXT_CONF}" <<EOF
[req]
default_bits        = 2048
default_md          = sha256
prompt              = no
distinguished_name  = dn

[dn]
C  = US
ST = Local
L  = Dev
O  = OpenLakehouse
CN = ${SVC}

[v3_server]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid,issuer
basicConstraints       = critical, CA:FALSE
keyUsage               = critical, digitalSignature, keyEncipherment
extendedKeyUsage       = serverAuth, clientAuth
subjectAltName         = ${SAN}
EOF

# ─── Generate private key ─────────────────────────────────────────────────────
log "Generating private key (2048-bit RSA)..."
openssl genrsa -out "${OUT_DIR}/server.key" 2048 2>/dev/null
chmod 600 "${OUT_DIR}/server.key"

# ─── Generate CSR ─────────────────────────────────────────────────────────────
log "Generating CSR..."
openssl req \
    -new \
    -key    "${OUT_DIR}/server.key" \
    -out    "${OUT_DIR}/server.csr" \
    -config "${EXT_CONF}"

# ─── Sign with Root CA ────────────────────────────────────────────────────────
log "Signing certificate with Root CA (${CERT_DAYS} days)..."
openssl x509 \
    -req \
    -in         "${OUT_DIR}/server.csr" \
    -CA         "${CA_DIR}/rootCA.crt" \
    -CAkey      "${CA_DIR}/rootCA.key" \
    -CAserial   "${CA_DIR}/rootCA.srl" \
    -CAcreateserial \
    -out        "${OUT_DIR}/server.crt" \
    -days       "${CERT_DAYS}" \
    -sha256 \
    -extfile    "${EXT_CONF}" \
    -extensions v3_server \
    2>/dev/null
chmod 644 "${OUT_DIR}/server.crt"

# ─── Build full chain ─────────────────────────────────────────────────────────
cat "${OUT_DIR}/server.crt" "${CA_DIR}/rootCA.crt" > "${OUT_DIR}/fullchain.crt"
chmod 644 "${OUT_DIR}/fullchain.crt"

# ─── Summary ─────────────────────────────────────────────────────────────────
log "✓ Certificate issued for '${SVC}':"
log "  Key:       ${OUT_DIR}/server.key"
log "  Cert:      ${OUT_DIR}/server.crt"
log "  Fullchain: ${OUT_DIR}/fullchain.crt"
log "  SAN:       ${SAN}"
openssl x509 -noout -dates -in "${OUT_DIR}/server.crt" | sed "s/^/  /"
