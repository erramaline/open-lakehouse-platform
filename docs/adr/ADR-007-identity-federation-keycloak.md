# ADR-007: Identity Federation — Keycloak OIDC as Single Identity Provider

| Field | Value |
|---|---|
| **Status** | Accepted |
| **Date** | 2026-03-12 |
| **Deciders** | Principal Data Platform Architect, Security Lead, IAM Engineer |
| **Tags** | security, identity, oidc, authentication, sso |

---

## Context

The platform comprises 10+ components with user-facing interfaces and APIs. Without a unified identity model, each component would maintain its own user database, password policy, MFA enforcement, and session management — creating:

- N distinct sets of credentials to manage, rotate, and audit.
- Inconsistent MFA enforcement (some components may skip it).
- No central revocation: revoking a terminated employee's access requires N separate actions.
- Impossible cross-component audit correlation (no common `user_id` across systems).
- GDPR compliance risk: personal data (email, name) stored in N systems independently.

The platform requires a **single identity provider (IdP)** that all components federate to, such that:

1. Users authenticate once (SSO) and access all tools via JWT tokens.
2. MFA is enforced centrally, not per-component.
3. Group membership / role assignments are managed in one place and propagated via JWT claims.
4. Access can be revoked centrally and takes effect immediately (token expiry + session invalidation).
5. The IdP integrates with corporate LDAP/AD (enterprise migration scenario) via federation.
6. The IdP is 100% open source (Apache 2.0 or compatible) and self-hosted.

---

## Decision

**We adopt Keycloak (latest stable) as the single OIDC identity provider for all platform components.**

All services use the OpenID Connect (OIDC) Authorization Code flow (for UIs) or Client Credentials flow (for M2M). SAML is supported by Keycloak for legacy enterprise federation but not required for internal components.

---

## Keycloak Realm Design

```
Realm: lakehouse
│
├── Identity Providers (federation)
│   ├── Corporate LDAP/AD (user sync, read-only)
│   └── SAML IdP (optional, enterprise SSO)
│
├── Clients (one per component with a user-facing surface)
│   ├── trino-gateway       (Authorization Code + PKCE)
│   ├── openmetadata        (Authorization Code + PKCE)
│   ├── grafana             (Authorization Code + PKCE)
│   ├── airflow-webserver   (Authorization Code + PKCE)
│   └── ranger-admin        (Resource Owner Password — internal only, VPN-gated)
│
├── Service Accounts (M2M — Client Credentials flow)
│   ├── trino-coordinator   (claims: service_name=trino)
│   ├── airflow-worker      (claims: service_name=airflow)
│   ├── dbt-runner          (claims: service_name=dbt)
│   └── openmetadata-crawler(claims: service_name=openmetadata)
│
├── Groups (mapped to Ranger roles and Polaris principal roles)
│   ├── platform-admins
│   ├── data-engineers
│   ├── data-analysts
│   ├── data-scientists
│   ├── data-stewards
│   └── readonly-consumers
│
└── Realm Roles (embedded in JWT `realm_access.roles` claim)
    ├── lakehouse_admin
    ├── lakehouse_engineer
    ├── lakehouse_analyst
    └── lakehouse_readonly
```

---

## JWT Claim Strategy

All JWTs issued by Keycloak include the following custom claims (configured via Protocol Mappers):

| Claim | Source | Used By |
|---|---|---|
| `sub` | Keycloak user UUID | Audit trail unique identifier |
| `preferred_username` | User's login name | Trino principal mapping |
| `email` | User email | OpenMetadata, Grafana user display |
| `realm_access.roles` | Keycloak realm roles | Trino JWT → Ranger user context |
| `groups` | Keycloak group membership | Ranger group-based policy evaluation |
| `tenant_id` | Custom attribute | Trino row-level filter (multi-tenancy) |
| `service_name` | Service account attribute | M2M authorization; audit correlation |

---

## Consequences

### Positive
- **Single credential set per user:** Users have one username/password + MFA across all tools. Reduces phishing surface.
- **Centralized MFA enforcement:** OTP (TOTP), WebAuthn (FIDO2), and SMS OTP enforced at Keycloak realm level — all components get MFA without individual configuration.
- **Central revocation:** Disabling a Keycloak user invalidates sessions across all federated services within the token TTL (default: 5 minutes access token; 30 minutes session).
- **LDAP/AD federation:** Corporate directory users are synchronized into Keycloak; no separate lakehouse password required. Group membership flows from corporate LDAP into JWT claims.
- **GDPR single point of personal data:** User PII (email, name) stored in Keycloak only. Components receive only the JWT claims they need — no independent user databases.
- **Audit correlation:** Every action across all components is correlated by `sub` (Keycloak UUID). Cross-system audit queries are possible.
- **Apache 2.0:** Keycloak is Apache 2.0 licensed; fully self-hosted; no SaaS dependency.

### Negative
- **Keycloak becomes critical infrastructure:** If Keycloak is unavailable, no user can log in to any tool. Mitigated by HA deployment (2+ nodes with JGroups clustering — see ADR-008).
- **JWT TTL trade-off:** Short access token TTL (5 min) reduces revocation lag but increases token refresh load on Keycloak. Long TTL (1 hour) reduces load but allows a revoked session to persist. We use 15-minute access tokens with refresh tokens.
- **Complexity of Protocol Mappers:** Custom JWT claims require careful Keycloak Protocol Mapper configuration. Mistakes can break downstream RBAC. Mitigated by: exporting realm config to `security/keycloak/realm-export.json` in version control (no secrets); automated testing of JWT claims in CI.
- **Trino OIDC integration complexity:** Trino requires the Keycloak JWKS endpoint for JWT verification. Trino coordinators must be able to reach Keycloak's OIDC discovery endpoint. NetworkPolicy must allow `compute-ns → identity-ns:443`.

### Neutral
- Keycloak supports SCIM 2.0 (user provisioning from HR systems) via third-party plugin; deferred to Phase 5.
- Keycloak's built-in brute-force detection is enabled (lockout after 10 failed attempts).

---

## Component-Specific Integration Notes

### Trino
- Config: `http-server.authentication.type=JWT`
- `http-server.authentication.jwt.key-file=<Keycloak JWKS URI>`
- `http-server.authentication.jwt.principal-field=preferred_username`
- Trino principal = `preferred_username` claim → Ranger policy lookup by username + groups.

### Apache Ranger
- Keycloak OIDC configured as Ranger's "UsersSync" provider (or LDAP sync from Keycloak's LDAP-backed users).
- Ranger Admin UI: OIDC login via Keycloak.
- Policy evaluation uses Ranger's internal user/group store, kept in sync with Keycloak groups via Ranger UserSync daemon.

### OpenMetadata
- OIDC type: `OIDC` with Keycloak discovery URL.
- `clientId`: `openmetadata` (registered in Keycloak realm).
- JWT validation via JWKS endpoint.

### Grafana
- `[auth.generic_oauth]` block with Keycloak OIDC endpoints.
- Group claim mapped to Grafana organization roles.

### Apache Airflow
- `[api] auth_backends = airflow.providers.fab.auth_manager.api.auth.backend.basic_auth` replaced by `airflow.providers.fab.auth_manager.api.auth.backend.oauth`.
- OIDC client: `airflow-webserver`.

---

## Alternatives Considered

### Dex (CoreOS / CNCF)
- **Rejected:** Dex is a connector/broker, not a full IdP. It delegates authentication to upstream providers (GitHub, LDAP) but has limited built-in user management. Cannot replace an enterprise directory. Suitable for K8s API server federation, not for multi-component platform SSO.

### ZITADEL
- **Rejected:** AGPL 3.0 for self-hosted. Conflicts with our "Apache 2.0 preferred" constraint. Product is excellent but licensing is a blocker.

### Authentik
- **Rejected:** MIT for core, but "Enterprise" features under proprietary license. Smaller community than Keycloak. Less mature Ranger/Trino integrations documented.

### Per-component LDAP integration (no central OIDC)
- **Rejected:** Each component queries corporate LDAP independently. Results in N LDAP service accounts, no SSO, no unified JWT for audit correlation, inconsistent MFA. Violates security requirements.

### Okta / Auth0
- **Rejected:** SaaS; not self-hostable. Violates multi-cloud portability and data sovereignty requirements.

---

## References
- [Keycloak documentation](https://www.keycloak.org/documentation)
- [Trino JWT authentication](https://trino.io/docs/current/security/jwt.html)
- [OpenMetadata Keycloak SSO](https://docs.open-metadata.org/deployment/security/keycloak)
- [Grafana OAuth2 generic provider](https://grafana.com/docs/grafana/latest/setup-grafana/configure-security/configure-authentication/generic-oauth/)
- ADR-006 — mTLS (complements OIDC for transport security)
- ADR-010 — Multi-tenancy (`tenant_id` claim in JWT drives row-level isolation)
