# Security Model — Open Lakehouse Platform

> **Version:** 1.0 | **Date:** 2026-03-12

---

## Overview

The platform's security model implements defense-in-depth across six enforcement layers. No single layer is considered sufficient; each layer adds an independent control that limits the blast radius of a compromise in any other layer.

```
L6 — Audit: Immutable, tamper-evident log of all actions
L5 — Secret: Zero hardcoded credentials; dynamic secrets; automatic rotation
L4 — Authorization: Apache Ranger RBAC/ABAC + Polaris catalog roles
L3 — Identity: Keycloak OIDC JWT for users; mTLS for M2M
L2 — Transport: mTLS between all internal services (cert-manager + OpenBao PKI)
L1 — Network: WAF → TLS ingress → K8s NetworkPolicy (default-deny)
```

---

## L1 — Network Security

### Ingress Perimeter

All external traffic enters via TLS-terminating ingress (Nginx or Traefik):
- TLS 1.3 only (TLS 1.2 disabled).
- HTTP Strict Transport Security (HSTS) header enforced.
- Rate limiting on authentication endpoints (Keycloak: 100 req/s per IP).
- WAF (ModSecurity or cloud WAF) for OWASP Top 10 mitigations.

### Kubernetes Network Policies

Default-deny policy applied to all namespaces:

```yaml
# Applied to every namespace
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
spec:
  podSelector: {}           # applies to all pods
  policyTypes:
    - Ingress
    - Egress
```

Per-service allow-list NetworkPolicies define the minimum required connections:

| Namespace | Allowed Ingress From | Allowed Egress To |
|---|---|---|
| `ingress-ns` | Internet (443) | `identity-ns:443`, `compute-ns:8080`, `metadata-ns:8585` |
| `identity-ns` | `ingress-ns`, `policy-ns`, `ingestion-ns` | `db-ns:5432` |
| `secrets-ns` | K8s API server, all namespaces (ESO pull) | K8s API server, `openbao-ns:8200` |
| `catalog-ns` | `compute-ns`, `ingestion-ns`, `metadata-ns` | `storage-ns:9000`, `db-ns:5432` |
| `storage-ns` | `catalog-ns`, `compute-ns`, `ingestion-ns`, `observability-ns` (metrics only) | MinIO peer ports only |
| `compute-ns` | `ingress-ns`, `ingestion-ns`, `metadata-ns` | `catalog-ns:8181`, `storage-ns:9000`, `policy-ns:6080`, `identity-ns:443` |
| `policy-ns` | `compute-ns` | `db-ns:5432`, `identity-ns:443` |
| `ingestion-ns` | `ingress-ns` (Airflow UI only) | `compute-ns:8080`, `storage-ns:9000`, `catalog-ns:8181/19120` |
| `metadata-ns` | `ingress-ns` | `compute-ns:8080`, `catalog-ns:8181`, `db-ns:5432` |
| `observability-ns` | `ingress-ns` (Grafana UI) | All namespaces scrape port (9090/metrics) |
| `db-ns` | Per-service (specific source namespaces only) | None (ingress only) |

### Docker Compose (Local) Network Isolation

Each Docker Compose service is assigned only the networks it requires. No service joins all networks. The `lakehouse-frontend` network has only the ingress container.

---

## L2 — Transport Security (mTLS)

### PKI Chain

```
OpenBao PKI — Root CA (RSA-4096, offline after bootstrap)
    │
    └─▶ Intermediate CA: lakehouse-int-ca (RSA-2048, 2-year validity, online)
             │ (issued via cert-manager ClusterIssuer "openbao-pki")
             │
             ├─▶ Service server certificates (90-day validity, auto-renewed)
             └─▶ Service client certificates (90-day validity, auto-renewed)
```

### mTLS Enforcement Table

| Connection | Client Cert | Server Cert | Both Verify Peer | Notes |
|---|---|---|---|---|
| Trino Gateway → Trino Coordinator | ✅ | ✅ | ✅ | JKS keystore/truststore |
| Trino → Polaris REST | ✅ | ✅ | ✅ | Polaris Dropwizard TLS config |
| Trino → Ranger plugin → Ranger Admin | ✅ | ✅ | ✅ | Ranger plugin truststore |
| Trino workers → MinIO (S3) | ✅ | ✅ | ✅ | Vended credentials + mTLS |
| Airflow → Trino | ✅ | ✅ | ✅ | Python `ssl.SSLContext` |
| Airflow → MinIO | ✅ | ✅ | ✅ | boto3 with TLS |
| Polaris → MinIO | ✅ | ✅ | ✅ | Polaris S3 client config |
| Nessie → MinIO | ✅ | ✅ | ✅ | Quarkus TLS config |
| OpenMetadata → Trino | ✅ | ✅ | ✅ | Trino connector TLS |
| cert-manager → OpenBao PKI | ✅ | ✅ | ✅ | OpenBao PKI vault issuer |
| ESO → OpenBao | ✅ | ✅ | ✅ | AppRole + TLS |
| Keycloak → PostgreSQL | ✅ | ✅ | ✅ | libpq TLS verify-full |
| All services → PostgreSQL | ✅ | ✅ | ✅ | libpq TLS verify-full |

**Local dev exception:** mTLS is disabled in Docker Compose local environment (`.env.example`: `TLS_ENABLED=false`). Never disabled in staging or production.

### Certificate Validation Rules

- Certificates signed by Root CA only (no browser CAs in the internal truststore).
- Hostname verification: SAN (Subject Alternative Name) must match the calling service's DNS name or K8s Service name.
- Expired certificates → immediate connection rejection (no grace period).
- Revocation check: CRL distribution point published by OpenBao PKI, checked by services that support CRL (Java JVM: OCSP/CRL; Python: `ssl` module CRL).

---

## L3 — Identity (Authentication)

### User Authentication

All human users authenticate via **Keycloak OIDC**:
- Flow: Authorization Code + PKCE (for all browser-based UIs).
- MFA: TOTP (Google Authenticator compatible) enforced for all users in production.
- WebAuthn (FIDO2 passkeys): Supported; recommended for admin accounts.
- Session TTL: Access token = 15 minutes; refresh token = 8 hours (offline).
- Brute-force protection: Account locked after 10 failed attempts; 15-minute unlock delay.

### Service-to-Service Authentication (M2M)

Internal services use **mTLS client certificates** as the primary M2M authentication mechanism. Services that call Keycloak-protected APIs additionally use **OAuth2 Client Credentials flow**:

```
Service (client_id + client_secret from ESO → K8s Secret)
    │ POST /realms/lakehouse/protocol/openid-connect/token
    │ grant_type=client_credentials
    ▼
Keycloak
    │ Validates client_id + client_secret
    └─▶ Returns access_token (service JWT, 5-minute TTL)
            │
            ▼
Target service (validates JWT via JWKS endpoint)
```

Client secrets are stored in OpenBao and injected via ESO. They rotate every 30 days.

### JWT Claim Mapping to Authorization

| JWT Claim | Source | Used For |
|---|---|---|
| `sub` | Keycloak user UUID | Audit trail primary key |
| `preferred_username` | User login | Trino principal; Ranger user lookup |
| `realm_access.roles` | Keycloak realm roles | Ranger user role mapping |
| `groups` | Keycloak group membership | Ranger group-based policies |
| `tenant_id` | Keycloak custom attribute | Trino row-level filter injection |
| `email` | User email | OpenMetadata, Grafana display |

---

## L4 — Authorization

### Data Authorization (Apache Ranger)

All data access decisions flow through the Ranger Trino plugin:

```
Trino coordinator receives query
    │
    ▼
RangerAccessRequest {
    user: "alice",
    groups: ["data_analysts", "tenant_a"],
    resource: {catalog: "trino", schema: "tenant_a.marts", table: "customers"},
    action: "SELECT"
}
    │
    ▼
Ranger evaluates policies (in order: deny > allow):
1. Global deny: cross-tenant access → DENY
2. Tenant policy: tenant_a.marts.customers → ALLOW for data_analysts
3. Row filter: inject WHERE tenant_id = 'tenant_a'
4. Column mask: mask SSN column for non-privileged users
    │
    ▼
Decision returned to Trino:
    - ALLOW: query proceeds with injected row filter + column masks
    - DENY:  AccessDeniedException → 403 returned to client
```

### Catalog Authorization (Apache Polaris)

Polaris enforces coarse-grained access control at the warehouse and namespace level:

| Polaris Role | Warehouse | Granted Privileges |
|---|---|---|
| `<tenant>_admin` | Own warehouse | CREATE/DROP namespace, table, view; manage roles |
| `<tenant>_engineer` | Own warehouse | MANAGE_CONTENT (DDL + DML) |
| `<tenant>_analyst` | Own warehouse marts | LIST namespaces; READ table metadata |
| `platform_admin` | ALL warehouses | Full service admin |

Polaris access is enforced before Ranger — a user must have both Polaris catalog access AND a Ranger ALLOW policy to read data.

### K8s RBAC

Platform operators have minimal K8s RBAC roles:
- `data-engineers`: Read pods/logs in `ingestion-ns`; no access to `secrets-ns`.
- `platform-admins`: Full access to all namespaces except `secrets-ns` (OpenBao).
- `security-admins`: Only `secrets-ns` and `security/` resources.
- CI/CD service accounts: namespace-scoped; no cluster-admin.

---

## L5 — Secret Management

See ADR-002 (OpenBao) and PLAN.md §8 (Secret Graph) for full details.

### Core Principles

1. **Zero hardcoded credentials:** No password, token, or key appears in any file, environment variable, Docker image, or Git history.
2. **Dynamic credentials:** Database credentials and MinIO access keys are dynamically generated per lease (TTL: 1 hour for DB; 15 minutes for MinIO vended creds via Polaris).
3. **Least privilege:** Each service receives only the secrets it needs. A Trino worker cannot access Keycloak secrets.
4. **Rotation:** Static secrets rotate on a defined schedule (30–90 days). Dynamic secrets rotate automatically on lease expiry.
5. **Audit trail:** Every OpenBao secret read/write is logged to the immutable audit backend (ADR-009).

### Secret Access Pattern

```
OpenBao AppRole credential (stored in K8s ServiceAccount annotation)
    │ ESO reads AppRole secret from OpenBao
    ▼
ESO creates/updates K8s Secret in target namespace
    │
    ▼ Pod startup
Service reads K8s Secret (env var or Volume mount)
    │
    ▼ Service uses credential
```

No service has a direct OpenBao token. AppRole secret-ids have a 24-hour TTL and are single-use.

---

## L6 — Audit

See ADR-009 and `docs/compliance/audit-trail-specification.md` for full details.

### What Is Logged

Every security-relevant event is logged:
- Authentication: login, logout, failed login, token issuance, token refresh.
- Authorization: every Ranger allow/deny decision.
- Data access: every Trino query (SQL text, tables accessed, rows scanned).
- Secret operations: every OpenBao read/write/delete.
- Configuration changes: Ranger policy CRUD, Polaris warehouse CRUD, Keycloak realm changes.
- Certificate operations: issuance, renewal, revocation (via cert-manager events + OpenBao PKI audit).

### Immutability

Audit logs are written to MinIO `audit-log/` bucket with S3 Object Lock in **Compliance mode** (7-year retention). Even MinIO root credentials cannot delete locked objects. See ADR-009.

---

## Security Threat Model

### STRIDE Analysis (Summary)

| Threat | Example | Mitigations |
|---|---|---|
| **Spoofing** | Forged JWT token used to impersonate user | Keycloak JWKS validation in Trino; short TTL (15 min); mTLS for M2M |
| **Tampering** | Modify audit logs to hide unauthorized access | MinIO WORM Compliance mode; hash chain; separate audit service account |
| **Repudiation** | Deny having run a query | Immutable Trino query audit log; `sub` claim in JWT uniquely identifies user |
| **Information Disclosure** | Cross-tenant data leakage via SQL UNION | Three-layer isolation: Polaris warehouse → Ranger row filter → MinIO bucket policy |
| **Denial of Service** | Query bomb saturates Trino workers | Trino resource groups (per-tenant limits); Gateway rate limiting; HPA |
| **Elevation of Privilege** | Analyst runs as admin via privilege escalation | Keycloak realm roles enforced; Ranger deny-by-default; K8s RBAC; no `runAsRoot` in pods |

### Security Scanning (CI Pipeline)

Every code change triggers:
- `trivy image` scan on all container images (CRITICAL CVEs → pipeline fail).
- `checkov` on all Terraform + Helm templates (security misconfiguration).
- `kube-score` on all K8s manifests (security context, resource limits, probes).
- SAST: `bandit` for Python code in services.
- Dependency audit: `pip-audit` for Python; `npm audit` for any Node.js tooling.

---

## Incident Response Playbook (Summary)

| Incident | Immediate Action | Recovery |
|---|---|---|
| Credential leak (secret in Git) | Rotate immediately via OpenBao; revoke old lease | Scan full git history (`truffleHog`); audit access during exposure window |
| Unauthorized data access detected | Disable Keycloak account; revoke Ranger access group membership | Forensics: pull Ranger deny/allow logs; Trino query audit; notify DPO if PII involved |
| mTLS certificate compromise | Revoke certificate in OpenBao PKI CRL; force rotation in cert-manager | All services reload trusted CA/CRL within 15 minutes |
| OpenBao quorum loss | Page on-call SRE immediately (P1) | Restore Raft quorum per runbook; do not reinitialize — unseal from KMS |
| MinIO WORM bucket deletion attempt | Alert fires (MinIO access log → Prometheus → Alertmanager → PagerDuty) | Investigate IAM credentials used; OpenBao audit log for secret access trail |
