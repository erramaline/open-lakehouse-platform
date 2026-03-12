# ADR-002: Why OpenBao over HashiCorp Vault (BSL License Analysis)

| Field | Value |
|---|---|
| **Status** | Accepted |
| **Date** | 2026-03-12 |
| **Deciders** | Principal Data Platform Architect, Security Lead, Legal / Compliance |
| **Tags** | secrets, security, licensing, open-source |

---

## Context

The platform requires a secrets management solution to:

1. Store, rotate, and dynamically issue credentials (DB passwords, service tokens, mTLS certificates via PKI).
2. Provide audit logs of every secret read/write (compliance requirement).
3. Be 100% open source under a permissive license (Apache 2.0 or equivalent) — **no BSL, no SSPL, no hybrid licenses**.
4. Support Kubernetes-native integration (AppRole + Kubernetes auth backend).
5. Support PKI secrets engine for certificate issuance (to back cert-manager).
6. Be self-hosted — no SaaS/managed offering dependency.

HashiCorp Vault was the industry-standard choice for years. In August 2023, HashiCorp relicensed **Vault (and all HashiCorp products) from MPL 2.0 to the Business Source License (BSL 1.1)**, effective for all versions ≥ 1.14 of Vault.

---

## Decision

**We adopt OpenBao (latest stable) as the secrets management backend for all environments.**

---

## BSL License Analysis

### What the BSL 1.1 says (as applied by HashiCorp)

> "You may use the Software for any purpose, except you may not use the Software to provide a competitive service to HashiCorp."

The BSL includes a "Change Date" after which the license converts to MPL 2.0 (currently set to 4 years post-release per HashiCorp). Key implications:

| Dimension | BSL Impact | Assessment |
|---|---|---|
| **Internal use** | Generally permitted | Low risk |
| **Embedding in a product** | Potentially restricted if deemed "competitive" | Medium risk — ambiguous |
| **Public cloud SaaS offering using Vault** | Likely restricted | High risk |
| **Open source project bundling Vault** | Inconsistent with OSS norms | Not acceptable for this project |
| **Legal certainty** | Requires legal review per use case | Unacceptable operational overhead |
| **Future license drift** | HashiCorp (now IBM) can change terms anew | Unacceptable for a multi-year platform |

**Conclusion:** The BSL introduces legal uncertainty that is incompatible with our global constraint of "100% open source — Apache 2.0 preferred, no BSL, no SSPL, no hybrid licenses." Even under permissive interpretations, a BSL dependency in an enterprise data platform creates legal exposure and blocks downstream open-source publication.

### OpenBao

OpenBao is a community fork of HashiCorp Vault ≤ 1.13 (pre-BSL), re-licensed under **Apache License 2.0**. It was created by the Linux Foundation in 2024 with active contributions from IBM, Red Hat, and the broader Vault community.

| Criterion | HashiCorp Vault ≥ 1.14 | OpenBao |
|---|---|---|
| License | BSL 1.1 → MPL 2.0 (4-year delay) | Apache 2.0 |
| Fork origin | N/A | Vault 1.13 (last MPL 2.0 release) |
| Kubernetes auth backend | ✅ | ✅ |
| PKI secrets engine | ✅ | ✅ |
| Dynamic database credentials | ✅ | ✅ |
| AppRole auth | ✅ | ✅ |
| Raft integrated storage | ✅ | ✅ |
| API compatibility | Vault API | Vault API compatible (drop-in) |
| Governance | HashiCorp/IBM controlled | Linux Foundation / community |
| Commercial support | HCP Vault (SaaS) | Community + vendor options |
| Active maintenance | Yes | Yes (active PR velocity) |

---

## Consequences

### Positive
- **Zero licensing risk:** Apache 2.0 is unambiguously permissive; no legal review burden per use case.
- **Drop-in compatibility:** OpenBao maintains Vault API compatibility — all ESO, cert-manager, and Airflow Vault integrations work without changes.
- **PKI engine available:** cert-manager's Vault issuer works identically against OpenBao.
- **Community governance:** Linux Foundation governance; no single corporate entity can relicense.
- **ESO integration:** External Secrets Operator supports OpenBao via the existing Vault provider (API-compatible).

### Negative
- **Younger fork:** OpenBao's independent operational track record is shorter. Corner cases in Raft storage compaction may differ from battle-tested Vault deployments.
- **Fewer enterprise SLA options:** No HashiCorp-backed commercial support. Mitigated by Linux Foundation support ecosystem and active community.
- **Delayed feature parity on new Vault features:** Features added to Vault post-v1.13 will lag into OpenBao. Acceptable because our required feature set (PKI, AppRole, K8s auth, Raft) was mature in v1.13.

### Neutral
- All existing Vault documentation, runbooks, and operator knowledge applies directly to OpenBao.
- Migration from Vault (if already deployed) requires no data migration — Raft snapshot can be imported.

---

## Alternatives Considered

### HashiCorp Vault ≥ 1.14 (BSL)
- **Rejected:** BSL license. See analysis above.

### Infisical
- **Rejected:** Core features under AGPL/EE split. Self-hosted version has feature gaps (PKI engine absent). Not a drop-in secrets management API.

### SOPS (Mozilla) + Age encryption
- **Rejected:** Not a dynamic secrets server. Suitable for GitOps secret encryption, not for runtime credential vending and PKI issuance. Would require a separate PKI solution. Not comparable in scope.

### AWS Secrets Manager / GCP Secret Manager
- **Rejected:** Cloud vendor lock-in. Violates multi-cloud portability requirement. No self-hosted option.

### Kubernetes Secrets (bare)
- **Rejected:** etcd base64 encoding is not encryption at rest by default. No rotation, no PKI, no audit trail. Not a secrets management solution.

---

## References
- [OpenBao GitHub (Linux Foundation)](https://github.com/openbao/openbao)
- [HashiCorp BSL announcement (August 2023)](https://www.hashicorp.com/blog/hashicorp-adopts-business-source-license)
- [External Secrets Operator — Vault provider](https://external-secrets.io/latest/provider/hashicorp-vault/)
- [cert-manager Vault issuer](https://cert-manager.io/docs/configuration/vault/)
- ADR-006 — mTLS strategy (OpenBao PKI as root CA)
- ADR-008 — HA strategy (OpenBao 3-node Raft)
