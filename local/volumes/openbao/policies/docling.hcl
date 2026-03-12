# =============================================================================
# OpenBao policy: docling
# Grants the Docling API access to MinIO credentials for writing parsed documents.
# =============================================================================

path "secret/data/docling/*" {
  capabilities = ["read"]
}

path "secret/metadata/docling/*" {
  capabilities = ["list"]
}

# Docling writes to MinIO raw/ and staging/ buckets
path "secret/data/minio/ingestion" {
  capabilities = ["read"]
}
