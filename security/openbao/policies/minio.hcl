# OpenBao ACL Policy — MinIO
# Principle of least privilege: read access to MinIO service account credentials.
# MinIO uses short-lived access key / secret key pairs per service account.

# ── Root credentials (needed only during initial bootstrap) ───────────────────
# NOTE: Only the rotation script has write access; this policy is read-only.
path "secret/data/storage/minio/root" {
  capabilities = ["read"]
}

# ── Service account credentials (Polaris, ingestion pipeline, audit) ──────────
path "secret/data/storage/minio/*" {
  capabilities = ["read"]
}
path "secret/metadata/storage/minio/*" {
  capabilities = ["list"]
}

# ── Self-renewal (AppRole secret-id refresh) ──────────────────────────────────
path "auth/approle/role/minio-role/secret-id" {
  capabilities = ["create", "update"]
}

# ── PKI: request TLS certificate for mTLS ─────────────────────────────────────
path "pki/issue/lakehouse-intermediate" {
  capabilities = ["create", "update"]
}
