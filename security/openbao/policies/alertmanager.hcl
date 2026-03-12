# OpenBao ACL Policy — Alertmanager
# Principle of least privilege: read-only access to webhook URLs and
# notification credentials. Alertmanager cannot modify secrets.

# ── Webhook and notification channel credentials ──────────────────────────────
path "secret/data/observability/alertmanager/*" {
  capabilities = ["read"]
}
path "secret/metadata/observability/alertmanager/*" {
  capabilities = ["list"]
}

# ── SMTP credentials (if email alerting is configured) ────────────────────────
# Scoped to alertmanager only — cannot access other SMTP credentials.
path "secret/data/observability/alertmanager/smtp" {
  capabilities = ["read"]
}

# ── Self-renewal (AppRole secret-id refresh) ──────────────────────────────────
path "auth/approle/role/alertmanager-role/secret-id" {
  capabilities = ["create", "update"]
}

# ── PKI: request TLS certificate for mTLS with Prometheus ────────────────────
path "pki/issue/lakehouse-intermediate" {
  capabilities = ["create", "update"]
}
