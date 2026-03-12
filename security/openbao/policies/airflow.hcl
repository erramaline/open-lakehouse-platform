# OpenBao ACL Policy — Apache Airflow
# Principle of least privilege: read-only access to Airflow-specific paths only.

# ── Airflow runtime secrets ────────────────────────────────────────────────────
path "secret/data/ingestion/airflow/*" {
  capabilities = ["read"]
}
path "secret/metadata/ingestion/airflow/*" {
  capabilities = ["list"]
}

# ── PostgreSQL (Airflow metadata DB) ──────────────────────────────────────────
path "secret/data/db/postgres/airflow" {
  capabilities = ["read"]
}

# ── Redis (Celery broker) ─────────────────────────────────────────────────────
# Covered by ingestion/airflow/redis above.

# ── MinIO (remote logging + staging data access) ──────────────────────────────
path "secret/data/storage/minio/ingestion" {
  capabilities = ["read"]
}

# ── Keycloak client secret (Airflow OIDC login) ───────────────────────────────
path "secret/data/identity/keycloak/clients/airflow" {
  capabilities = ["read"]
}

# ── Polaris service account (register Iceberg tables) ─────────────────────────
path "secret/data/catalog/polaris/airflow" {
  capabilities = ["read"]
}

# ── dbt credentials ───────────────────────────────────────────────────────────
path "secret/data/transform/dbt/trino" {
  capabilities = ["read"]
}

# ── Self-renewal ───────────────────────────────────────────────────────────────
path "auth/approle/role/airflow-role/secret-id" {
  capabilities = ["create", "update"]
}

# ── PKI ───────────────────────────────────────────────────────────────────────
path "pki/issue/lakehouse-intermediate" {
  capabilities = ["create", "update"]
}
