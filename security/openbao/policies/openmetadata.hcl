# OpenBao ACL Policy — OpenMetadata
# Principle of least privilege: read-only access to OpenMetadata-specific paths only.

# ── OpenMetadata runtime secrets ──────────────────────────────────────────────
path "secret/data/metadata/openmetadata/*" {
  capabilities = ["read"]
}
path "secret/metadata/metadata/openmetadata/*" {
  capabilities = ["list"]
}

# ── PostgreSQL (OpenMetadata metadata DB) ─────────────────────────────────────
path "secret/data/db/postgres/openmetadata" {
  capabilities = ["read"]
}

# ── Elasticsearch (OpenMetadata search backend) ────────────────────────────────
# Covered by metadata/openmetadata/elasticsearch above.

# ── Keycloak client secret (OpenMetadata OIDC login) ─────────────────────────
path "secret/data/identity/keycloak/clients/openmetadata" {
  capabilities = ["read"]
}

# ── Self-renewal ───────────────────────────────────────────────────────────────
path "auth/approle/role/openmetadata-role/secret-id" {
  capabilities = ["create", "update"]
}

# ── PKI ───────────────────────────────────────────────────────────────────────
path "pki/issue/lakehouse-intermediate" {
  capabilities = ["create", "update"]
}
