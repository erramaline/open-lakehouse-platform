# =============================================================================
# OpenBao policy: trino
# Grants Trino coordinator and workers read-only access to their secrets.
# Path: secret/data/trino/* (KV v2)
# =============================================================================

# Trino reads its S3 credentials, Polaris OAuth2 client secret, and shared secret
path "secret/data/trino/*" {
  capabilities = ["read"]
}

path "secret/metadata/trino/*" {
  capabilities = ["list"]
}

# Trino needs to read PKI certs for mTLS (coordinator ↔ worker)
# In K8s prod: cert-manager handles this; in local dev: certs from 00-init-tls.sh
path "pki/issue/trino" {
  capabilities = ["create", "update"]
}
