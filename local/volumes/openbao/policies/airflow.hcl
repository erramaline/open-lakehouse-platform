# =============================================================================
# OpenBao policy: airflow
# Grants Airflow access to: DB, Fernet key, Redis password, Polaris OAuth2 creds,
# and MinIO service account for ingestion.
# =============================================================================

path "secret/data/airflow/*" {
  capabilities = ["read"]
}

path "secret/metadata/airflow/*" {
  capabilities = ["list"]
}

# Airflow pipelines also need MinIO ingestion credentials
path "secret/data/minio/ingestion" {
  capabilities = ["read"]
}

# Airflow reads Polaris OAuth2 creds to register tables after ingestion
path "secret/data/polaris/airflow-svc" {
  capabilities = ["read"]
}
