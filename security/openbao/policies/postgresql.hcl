# OpenBao ACL Policy — PostgreSQL
# Principle of least privilege: read-only access to database credentials.
# PostgreSQL itself does not run an AppRole agent; this policy is used by
# sidecar init-containers and the bootstrap script to fetch credentials.

# ── Root superuser credentials (bootstrap only, used by init-scripts) ─────────
path "secret/data/postgresql/root" {
  capabilities = ["read"]
}
path "secret/metadata/postgresql/root" {
  capabilities = ["list"]
}

# ── Per-database credentials (read by the respective service init containers) ──
path "secret/data/db/postgres/*" {
  capabilities = ["read"]
}
path "secret/metadata/db/postgres/*" {
  capabilities = ["list"]
}

# ── PKI: request TLS client certificate for mTLS connections ──────────────────
path "pki/issue/lakehouse-intermediate" {
  capabilities = ["create", "update"]
}
