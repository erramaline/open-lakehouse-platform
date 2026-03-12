# OpenBao ACL Policy — Grafana
# Principle of least privilege: read Grafana admin password + datasource secrets only.

# ── Grafana admin credentials ──────────────────────────────────────────────────
path "secret/data/observability/grafana/*" {
  capabilities = ["read"]
}
path "secret/metadata/observability/grafana/*" {
  capabilities = ["list"]
}

# ── Keycloak client secret (Grafana OIDC login) ───────────────────────────────
path "secret/data/identity/keycloak/clients/grafana" {
  capabilities = ["read"]
}

# ── Alertmanager webhook (Grafana alert contacts) ─────────────────────────────
# Only read — cannot write or modify alerting config
path "secret/data/observability/alertmanager/webhook" {
  capabilities = ["read"]
}

# ── Self-renewal ───────────────────────────────────────────────────────────────
path "auth/approle/role/grafana-role/secret-id" {
  capabilities = ["create", "update"]
}

# ── PKI ───────────────────────────────────────────────────────────────────────
path "pki/issue/lakehouse-intermediate" {
  capabilities = ["create", "update"]
}
