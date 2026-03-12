# =============================================================================
# OpenBao policy: polaris
# Grants Polaris read access to its DB credentials and MinIO service account.
# =============================================================================

path "secret/data/polaris/*" {
  capabilities = ["read"]
}

path "secret/metadata/polaris/*" {
  capabilities = ["list"]
}
