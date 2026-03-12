# ADR-006: mTLS Strategy — cert-manager + OpenBao PKI vs Service Mesh

| Field | Value |
|---|---|
| **Status** | Accepted |
| **Date** | 2026-03-12 |
| **Deciders** | Principal Data Platform Architect, Security Lead, Platform SRE |
| **Tags** | security, mtls, certificates, pki, networking |

---

## Context

The platform's global constraint mandates mTLS (mutual TLS) between **all internal services**. This means every service-to-service connection must present a client certificate, and both parties must verify the other's certificate against a trusted CA chain. The implementation must:

1. Issue short-lived certificates (≤ 90 days) automatically, without human intervention.
2. Integrate with OpenBao PKI engine as the internal Certificate Authority.
3. Be compatible with all platform components (Trino, MinIO, Polaris, Ranger, PostgreSQL, Keycloak, etc.) — some of which are Java-based (truststores) and some Python/Go-based.
4. Support certificate rotation without service restarts where possible.
5. Be operable without a service mesh (Istio/Linkerd) if the service mesh adds unacceptable complexity.
6. Be 100% open source under Apache 2.0.

Two approaches were evaluated:
- **Option A:** cert-manager + OpenBao PKI (explicit certificate management per service)
- **Option B:** Service mesh (Istio or Linkerd) with automatic mTLS sidecar injection

---

## Decision

**We adopt Option A: cert-manager + OpenBao PKI for mTLS certificate management.**

Service mesh is deferred to Phase 5+ (post-initial rollout) and evaluated separately.

---

## PKI Chain Design

```
OpenBao PKI — Root CA (offline / sealed)
    │
    └─▶ OpenBao PKI — Intermediate CA "lakehouse-int-ca" (online, 2-year validity)
              │
              └─▶ cert-manager ClusterIssuer "openbao-issuer"
                        │
                        ├─▶ Certificate: polaris-server-tls (90d)
                        ├─▶ Certificate: trino-server-tls (90d)
                        ├─▶ Certificate: minio-server-tls (90d)
                        ├─▶ Certificate: ranger-server-tls (90d)
                        ├─▶ Certificate: keycloak-server-tls (90d)
                        ├─▶ Certificate: airflow-server-tls (90d)
                        ├─▶ Certificate: nessie-server-tls (90d)
                        └─▶ Certificate: <service>-client-tls (90d, per consuming service)
```

The Root CA private key is generated offline, injected into OpenBao once at bootstrap, and then the Root CA key material is sealed. Only the Intermediate CA remains online for day-to-day issuance.

---

## Consequences

### Positive for Option A (cert-manager + OpenBao PKI)

- **Explicit control:** Each service's certificate is a discrete K8s resource (`Certificate` CRD). Audit trail of which service has which cert, expiry dates, renewal history — all queryable via `kubectl` and Prometheus cert-manager metrics.
- **OpenBao PKI integration:** cert-manager's Vault issuer works identically with OpenBao (API-compatible). All cert issuance is logged in OpenBao audit log — immutable cryptographic evidence for SOC2.
- **No sidecar overhead:** Eliminates the CPU/memory tax of Envoy proxies (typically 50–100 mCPU + 50 MiB per pod). At 50+ pods, this is 5+ CPU cores saved.
- **Transparent to all components:** Certificates are mounted as standard files (TLS key/cert/CA bundle). Works with Java keystores, Python `ssl` module, Go `tls.Config`, nginx — no component needs to "know" about the service mesh.
- **Independent of Kubernetes CNI:** Works with any CNI (Calico, Cilium, Flannel). Service meshes require specific CNI compatibility or replace the CNI entirely.
- **Lower blast radius:** cert-manager is a simple, focused controller. Failure modes are well-understood. Service mesh control plane failures can cause complete service disruption.
- **Simpler debugging:** `openssl s_client -connect service:port` works directly. No need to `exec` into a sidecar to inspect TLS.

### Negative for Option A

- **Manual application-level TLS config:** Each service must be configured to use its certificate (JVM truststore, TLS config file, env vars). No automatic transparent proxying.
- **No traffic policy enforcement at mesh level:** Cannot enforce "this pod may only send traffic to these pods" at the network level without separate Kubernetes NetworkPolicies. Mitigated by our comprehensive NetworkPolicy implementation.
- **No automatic mTLS for arbitrary new services:** Adding a new service requires creating a `Certificate` resource and configuring the service. Not zero-config.
- **Certificate rotation requires service config reload:** Some services (Java-based) require a JVM restart or hot reload when certs rotate. Mitigated by Kubernetes rolling updates.

### Why Service Mesh Was Deferred

| Criterion | cert-manager + OpenBao PKI | Istio (service mesh) | Linkerd (service mesh) |
|---|---|---|---|
| License | Apache 2.0 | Apache 2.0 | Apache 2.0 |
| mTLS enforcement | Explicit per service | Automatic (sidecar) | Automatic (sidecar) |
| Operational complexity | Low | High | Medium |
| CPU overhead | Minimal | ~50-100 mCPU/pod | ~5-20 mCPU/pod |
| Memory overhead | Minimal | ~50 MiB/pod | ~20 MiB/pod |
| Certificate authority | OpenBao PKI (our CA) | Istiod CA or Vault plugin | trust-anchor bundle |
| Audit trail | OpenBao + cert-manager | Istiod logs | Linkerd logs |
| CNI dependency | None | Requires compatible CNI | Works with most CNIs |
| Debugging difficulty | Low | High (Envoy configs) | Medium |
| K8s version churn | Stable | Rapid; breaking changes | Stable |
| **Decision** | ✅ Adopted | Deferred (Phase 5) | Deferred (Phase 5) |

**Linkerd** is preferred over Istio if a service mesh is adopted later: it is lighter, simpler, and Rust-based (lower CVE surface). However, both are deferred because the cert-manager approach satisfies all current security requirements with lower operational overhead.

---

## Certificate Lifecycle Management

| Event | Mechanism | Alert Threshold |
|---|---|---|
| Issuance | cert-manager → OpenBao PKI | N/A |
| Renewal (automatic) | cert-manager renews at 2/3 of lifetime (60 days) | cert_expiry_days < 14 → critical alert |
| Rotation (service) | K8s rolling update triggered by cert-manager annotation | N/A |
| Revocation | OpenBao PKI CRL; cert-manager annotation `revoked: true` | Manual process; CRL distributed within 15 min |
| Root CA rotation | Annual; requires re-signing intermediate; documented runbook | 90 days before expiry → planning alert |

---

## mTLS Configuration per Component

| Service | TLS Implementation | Config Method |
|---|---|---|
| Trino | Java Jetty (HTTPS) | `etc/config.properties` — keystore + truststore paths |
| MinIO | Go TLS | `MINIO_SERVER_TLS_CERT_FILE` / `MINIO_SERVER_TLS_KEY_FILE` env vars |
| Polaris | Java (Dropwizard) | `server.applicationConnectors` TLS config in `polaris-config.yml` |
| Ranger Admin | Java Tomcat | `ranger-admin-site.xml` + JVM truststore |
| PostgreSQL | libpq (native) | `ssl = on`; `ssl_cert_file`, `ssl_key_file` in `postgresql.conf` |
| Keycloak | Undertow (Quarkus) | `quarkus.http.ssl.*` config; JVM truststore via `JAVA_OPTS` |
| Nessie | Quarkus | `quarkus.http.ssl.*` config |
| Airflow | Python `ssl.SSLContext` | `airflow.cfg` TLS settings + `AIRFLOW__WEBSERVER__WEB_SERVER_SSL_CERT` |
| OpenMetadata | Java (Jetty) | `openmetadata.yaml` TLS section |

---

## References
- [cert-manager documentation](https://cert-manager.io/docs/)
- [cert-manager Vault/OpenBao issuer](https://cert-manager.io/docs/configuration/vault/)
- [OpenBao PKI secrets engine](https://openbao.org/docs/secrets/pki/)
- [Linkerd vs Istio comparison](https://linkerd.io/2/faq/#whats-the-difference-between-linkerd-and-istio)
- ADR-002 — OpenBao as secrets backend (includes PKI engine rationale)
- ADR-008 — HA strategy (cert-manager HA deployment)
