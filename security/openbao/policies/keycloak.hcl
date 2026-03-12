# OpenBao ACL Policy — Keycloak
# Principle of least privilege: read access to Keycloak admin credentials
# and OIDC client secrets. Keycloak is the identity provider for the platform.

# ── Keycloak admin credentials ────────────────────────────────────────────────
path "secret/data/identity/keycloak/admin" {
  capabilities = ["read"]
}
path "secret/metadata/identity/keycloak/admin" {
  capabilities = ["list"]
}

# ── OIDC client secrets (all clients — Keycloak reads them at startup) ─────────
path "secret/data/identity/keycloak/clients/*" {
  capabilities = ["read"]
}
path "secret/metadata/identity/keycloak/clients/*" {
  capabilities = ["list"]
}

# ── Database credentials (Keycloak's own PostgreSQL database) ─────────────────
path "secret/data/db/postgres/keycloak" {
  capabilities = ["read"]
}

# ── Self-renewal (AppRole secret-id refresh) ──────────────────────────────────
path "auth/approle/role/keycloak-role/secret-id" {
  capabilities = ["create", "update"]
}

# ── PKI: request TLS certificate for HTTPS endpoint ──────────────────────────
path "pki/issue/lakehouse-intermediate" {
  capabilities = ["create", "update"]
}
