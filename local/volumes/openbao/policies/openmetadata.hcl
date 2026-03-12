# =============================================================================
# OpenBao policy: openmetadata
# Grants OpenMetadata access to its DB credentials and Keycloak OIDC secret.
# =============================================================================

path "secret/data/openmetadata/*" {
  capabilities = ["read"]
}

path "secret/metadata/openmetadata/*" {
  capabilities = ["list"]
}
