#!/usr/bin/env bash
# =============================================================================
# 03-init-minio.sh — Create MinIO buckets, enable Object Lock on audit/
# =============================================================================
# Steps:
#   1. Wait for MinIO cluster to be healthy
#   2. Configure mc alias
#   3. Create all required buckets (raw, staging, curated, iceberg, backup, audit)
#   4. Enable versioning on all buckets
#   5. Configure S3 Object Lock COMPLIANCE mode on audit/ (7 years)
#   6. Create MinIO service accounts (per-service access keys)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
ENV_FILE="${REPO_ROOT}/local/.env"

log()  { echo "[03-init-minio] $*"; }
ok()   { echo "[03-init-minio] ✓ $*"; }
err()  { echo "[03-init-minio] ✗ $*" >&2; exit 1; }

[ -f "${ENV_FILE}" ] || err ".env file not found at ${ENV_FILE}"
set -a; source "${ENV_FILE}"; set +a

MINIO_ALIAS="local"
MINIO_URL="${MINIO_URL:-http://localhost:9000}"

command -v mc &>/dev/null || err "MinIO Client (mc) not found. Install: https://min.io/docs/minio/linux/reference/minio-mc.html"

# ─── Step 1: Configure mc alias ───────────────────────────────────────────────
log "Configuring mc alias '${MINIO_ALIAS}'..."
mc alias set "${MINIO_ALIAS}" "${MINIO_URL}" \
    "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" --insecure
ok "mc alias configured."

# ─── Step 2: Wait for MinIO cluster ───────────────────────────────────────────
log "Waiting for MinIO cluster to be ready..."
for i in $(seq 1 30); do
    if mc admin info "${MINIO_ALIAS}" --insecure &>/dev/null; then
        ok "MinIO cluster is healthy."
        break
    fi
    [ "$i" -eq 30 ] && err "Timeout waiting for MinIO cluster."
    sleep 5
done

# ─── Step 3: Create buckets ────────────────────────────────────────────────────
create_bucket() {
    local bucket="$1"
    local with_lock="${2:-false}"

    if mc ls "${MINIO_ALIAS}/${bucket}" --insecure &>/dev/null; then
        log "Bucket '${bucket}' already exists."
        return
    fi

    if [ "${with_lock}" = "true" ]; then
        mc mb --with-lock "${MINIO_ALIAS}/${bucket}" --insecure
        ok "Created '${bucket}' (Object Lock enabled)."
    else
        mc mb "${MINIO_ALIAS}/${bucket}" --insecure
        ok "Created '${bucket}'."
    fi
}

create_bucket "raw"
create_bucket "staging"
create_bucket "curated"
create_bucket "iceberg"
create_bucket "backup"
create_bucket "audit" "true"   # WORM bucket — Object Lock required

# ─── Step 4: Enable versioning on all buckets ─────────────────────────────────
for bucket in raw staging curated iceberg backup audit; do
    log "Enabling versioning on '${bucket}'..."
    mc version enable "${MINIO_ALIAS}/${bucket}" --insecure
    ok "Versioning enabled on '${bucket}'."
done

# ─── Step 5: Object Lock COMPLIANCE on audit/ ─────────────────────────────────
log "Configuring Object Lock COMPLIANCE (7 years) on 'audit/'..."
mc retention set --default COMPLIANCE "7y" "${MINIO_ALIAS}/audit" --insecure
ok "Object Lock COMPLIANCE 7-year retention configured on 'audit/'."

# ─── Step 6: Create service accounts ──────────────────────────────────────────

create_service_account() {
    local name="$1"
    local access_key="$2"
    local secret_key="$3"
    local policy_json="$4"

    log "Creating service account '${name}' (access_key: ${access_key})..."

    # Check if already exists
    if mc admin user svcacct ls "${MINIO_ALIAS}" --insecure 2>/dev/null | grep -q "${access_key}"; then
        log "Service account '${access_key}' already exists."
        return
    fi

    # Create service account with inline policy
    mc admin user svcacct add "${MINIO_ALIAS}" "${MINIO_ROOT_USER}" \
        --access-key "${access_key}" \
        --secret-key "${secret_key}" \
        --policy <(echo "${policy_json}") \
        --insecure
    ok "Service account '${name}' created."
}

# Polaris: read/write on iceberg/ bucket
POLARIS_POLICY='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:GetObject","s3:PutObject","s3:DeleteObject","s3:ListBucket","s3:GetBucketLocation"],
    "Resource": ["arn:aws:s3:::iceberg/*","arn:aws:s3:::iceberg"]
  }]
}'
create_service_account "polaris" "${MINIO_POLARIS_ACCESS_KEY}" "${MINIO_POLARIS_SECRET_KEY}" "${POLARIS_POLICY}"

# Ingestion (Airflow + Docling): read/write on raw/ and staging/
INGESTION_POLICY='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:GetObject","s3:PutObject","s3:DeleteObject","s3:ListBucket","s3:GetBucketLocation"],
    "Resource": [
      "arn:aws:s3:::raw/*","arn:aws:s3:::raw",
      "arn:aws:s3:::staging/*","arn:aws:s3:::staging",
      "arn:aws:s3:::curated/*","arn:aws:s3:::curated",
      "arn:aws:s3:::iceberg/*","arn:aws:s3:::iceberg",
      "arn:aws:s3:::backup/*","arn:aws:s3:::backup"
    ]
  }]
}'
create_service_account "ingestion" "${MINIO_INGESTION_ACCESS_KEY}" "${MINIO_INGESTION_SECRET_KEY}" "${INGESTION_POLICY}"

# Audit (OTel Collector): WRITE ONLY on audit/
AUDIT_POLICY='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:PutObject","s3:GetBucketLocation"],
    "Resource": ["arn:aws:s3:::audit/*","arn:aws:s3:::audit"]
  }]
}'
create_service_account "audit" "${MINIO_AUDIT_ACCESS_KEY}" "${MINIO_AUDIT_SECRET_KEY}" "${AUDIT_POLICY}"

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
log "Bucket summary:"
mc ls "${MINIO_ALIAS}" --insecure

echo ""
ok "MinIO initialization complete!"
log "Next step: run scripts/bootstrap/04-init-polaris.sh"
