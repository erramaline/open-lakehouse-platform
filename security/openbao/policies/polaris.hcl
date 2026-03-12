# OpenBao ACL Policy — Apache Polaris
# Principle of least privilege: read-only access to Polaris-specific paths only.

# ── Polaris admin + service credentials ───────────────────────────────────────
path "secret/data/catalog/polaris/*" {
  capabilities = ["read"]
}
path "secret/metadata/catalog/polaris/*" {
  capabilities = ["list"]
}

# ── PostgreSQL (Polaris DB backend) ───────────────────────────────────────────
path "secret/data/db/postgres/polaris" {
  capabilities = ["read"]
}

# ── MinIO (Polaris uses S3 for Iceberg warehouse storage) ─────────────────────
path "secret/data/storage/minio/polaris" {
  capabilities = ["read"]
}

# ── Keycloak client secret (Polaris OIDC validation) ─────────────────────────
# Polaris validates tokens from Trino/Airflow clients; no client secret needed here.
# Uncomment if Polaris acts as an OIDC client itself:
# path "secret/data/identity/keycloak/clients/polaris" {
#   capabilities = ["read"]
# }

# ── Self-renewal ───────────────────────────────────────────────────────────────
path "auth/approle/role/polaris-role/secret-id" {
  capabilities = ["create", "update"]
}

# ── PKI ───────────────────────────────────────────────────────────────────────
path "pki/issue/lakehouse-intermediate" {
  capabilities = ["create", "update"]
}
