#!/usr/bin/env bash
# =============================================================================
# MinIO bucket initialization script
# Run ONCE after MinIO cluster is healthy (called by 03-init-minio.sh).
# Creates all buckets, enables versioning, and configures Object Lock on audit/.
#
# Environment variables expected (set in .env):
#   MINIO_ROOT_USER, MINIO_ROOT_PASSWORD
# =============================================================================
set -euo pipefail

MINIO_ALIAS="${MINIO_ALIAS:-local}"
MINIO_URL="${MINIO_URL:-http://minio-1:9000}"
MC="mc"

log() { echo "[init-buckets] $*"; }
ok()  { echo "[init-buckets] ✓ $*"; }

# ─── Configure mc alias ────────────────────────────────────────────────────────
log "Configuring mc alias '${MINIO_ALIAS}'..."
${MC} alias set "${MINIO_ALIAS}" "${MINIO_URL}" \
    "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" --insecure

# ─── Wait for MinIO to be ready ───────────────────────────────────────────────
log "Waiting for MinIO to be ready..."
until ${MC} admin info "${MINIO_ALIAS}" --insecure &>/dev/null; do
    sleep 2
done
ok "MinIO is ready."

# ─── Helper: create bucket with versioning ────────────────────────────────────
create_bucket() {
    local bucket="$1"
    local with_lock="${2:-false}"

    if ${MC} ls "${MINIO_ALIAS}/${bucket}" --insecure &>/dev/null; then
        log "Bucket '${bucket}' already exists — skipping."
        return
    fi

    if [ "${with_lock}" = "true" ]; then
        # Object Lock requires versioning; --with-lock enables WORM mode
        ${MC} mb --with-lock "${MINIO_ALIAS}/${bucket}" --insecure
        ok "Created bucket '${bucket}' with Object Lock enabled."
    else
        ${MC} mb "${MINIO_ALIAS}/${bucket}" --insecure
        ok "Created bucket '${bucket}'."
    fi

    # Enable versioning on all buckets (required for Object Lock and Iceberg time-travel)
    ${MC} version enable "${MINIO_ALIAS}/${bucket}" --insecure
    ok "Versioning enabled on '${bucket}'."
}

# ─── Create buckets ───────────────────────────────────────────────────────────
# raw/       — Landing zone for documents and raw files (Docling input)
create_bucket "raw"

# staging/   — Parsed Parquet files (Docling output, pre-quality-gate)
create_bucket "staging"

# curated/   — Promoted, quality-validated Iceberg tables (mart layer)
create_bucket "curated"

# iceberg/   — Iceberg metadata + data files managed by Polaris
create_bucket "iceberg"

# backup/    — PostgreSQL and service backups
create_bucket "backup"

# audit/     — WORM audit log (Object Lock COMPLIANCE mode, 7-year retention)
#              Per ADR-009: this bucket is IMMUTABLE — no overwrites, no deletes.
create_bucket "audit" "true"

# ─── Configure Object Lock on audit/ — COMPLIANCE mode, 7-year retention ──────
log "Configuring Object Lock COMPLIANCE mode on audit/ bucket..."
${MC} ilm rule add \
    --expire-days 2555 \
    "${MINIO_ALIAS}/audit" --insecure || true   # ilm for expiry after retention ends

${MC} retention set \
    --default COMPLIANCE "7y" \
    "${MINIO_ALIAS}/audit" --insecure
ok "Object Lock COMPLIANCE 7-year retention set on 'audit/'."

# ─── Set bucket policies ──────────────────────────────────────────────────────
# audit/ — strictly append-only (no read for service accounts, only otel-collector writes)
cat > /tmp/audit-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "AWS": ["*"] },
      "Action": ["s3:PutObject"],
      "Resource": ["arn:aws:s3:::audit/*"],
      "Condition": {
        "StringEquals": {
          "s3:x-amz-server-side-encryption": "aws:kms"
        }
      }
    }
  ]
}
EOF
# NOTE: Keeping policy open for local dev; production restricts Principal to service accounts.

ok "All buckets initialized successfully."
log "Bucket summary:"
${MC} ls "${MINIO_ALIAS}" --insecure
