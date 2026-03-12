# OpenBao ACL Policy — Docling (IBM document parser)
# Principle of least privilege: minimal access — only MinIO write + own secrets.

# ── Docling runtime secrets (API keys, model config) ──────────────────────────
path "secret/data/ingestion/docling/*" {
  capabilities = ["read"]
}
path "secret/metadata/ingestion/docling/*" {
  capabilities = ["list"]
}

# ── MinIO ingestion account (write parsed documents to staging/) ───────────────
path "secret/data/storage/minio/ingestion" {
  capabilities = ["read"]
}

# ── Self-renewal ───────────────────────────────────────────────────────────────
path "auth/approle/role/docling-role/secret-id" {
  capabilities = ["create", "update"]
}

# ── PKI ───────────────────────────────────────────────────────────────────────
path "pki/issue/lakehouse-intermediate" {
  capabilities = ["create", "update"]
}
