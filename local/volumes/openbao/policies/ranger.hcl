# =============================================================================
# OpenBao policy: ranger
# Grants Ranger Admin read access to its database password and admin credentials.
# =============================================================================

path "secret/data/ranger/*" {
  capabilities = ["read"]
}

path "secret/metadata/ranger/*" {
  capabilities = ["list"]
}
