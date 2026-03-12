# =============================================================================
# OpenBao policy: grafana
# Grants Grafana read access to its admin credentials and Keycloak OIDC secret.
# =============================================================================

path "secret/data/grafana/*" {
  capabilities = ["read"]
}

path "secret/metadata/grafana/*" {
  capabilities = ["list"]
}
