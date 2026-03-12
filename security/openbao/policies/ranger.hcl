# OpenBao ACL Policy — Apache Ranger Admin
# Principle of least privilege: read-only access to Ranger-specific paths only.

# ── Ranger admin + DB credentials ─────────────────────────────────────────────
path "secret/data/policy/ranger/*" {
  capabilities = ["read"]
}
path "secret/metadata/policy/ranger/*" {
  capabilities = ["list"]
}

# ── PostgreSQL (Ranger DB) ─────────────────────────────────────────────────────
path "secret/data/db/postgres/ranger" {
  capabilities = ["read"]
}

# ── Keycloak — Ranger LDAP federation token ───────────────────────────────────
path "secret/data/identity/keycloak/admin" {
  capabilities = ["read"]
}

# ── Self-renewal ───────────────────────────────────────────────────────────────
path "auth/approle/role/ranger-role/secret-id" {
  capabilities = ["create", "update"]
}

# ── PKI: request TLS cert ─────────────────────────────────────────────────────
path "pki/issue/lakehouse-intermediate" {
  capabilities = ["create", "update"]
}
