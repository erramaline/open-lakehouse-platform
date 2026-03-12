# OpenBao ACL Policy — Trino
# Principle of least privilege: read-only access to Trino-specific paths only.

# ── Compute secrets ────────────────────────────────────────────────────────────
path "secret/data/compute/trino/*" {
  capabilities = ["read"]
}
path "secret/metadata/compute/trino/*" {
  capabilities = ["list"]
}

# ── Polaris service account (needed to authenticate to Polaris REST catalog) ──
path "secret/data/catalog/polaris/trino" {
  capabilities = ["read"]
}

# ── Keycloak client secret (for JWT validation config) ────────────────────────
path "secret/data/identity/keycloak/clients/trino" {
  capabilities = ["read"]
}

# ── Ranger shared secret (for Ranger plugin auth) ─────────────────────────────
path "secret/data/policy/ranger/trino-plugin-shared-secret" {
  capabilities = ["read"]
}

# ── MinIO ingestion account (for reading raw/staging data) ────────────────────
path "secret/data/storage/minio/ingestion" {
  capabilities = ["read"]
}

# ── Self-renewal (AppRole secret-id refresh) ──────────────────────────────────
path "auth/approle/role/trino-role/secret-id" {
  capabilities = ["create", "update"]
}

# ── PKI: request TLS cert for mTLS ────────────────────────────────────────────
path "pki/issue/lakehouse-intermediate" {
  capabilities = ["create", "update"]
}
