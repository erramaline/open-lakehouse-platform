# SOC 2 Type II Control Mapping — Open Lakehouse Platform

> **Version:** 1.0 | **Date:** 2026-03-12 | **Classification:** CONFIDENTIAL  
> **Framework:** AICPA Trust Services Criteria (2017, updated 2022)  
> **Audit Period:** [To be defined with external auditor]  
> **Review Owner:** Security Lead + Compliance Officer

---

## Purpose

This document maps each SOC 2 Trust Service Criteria (TSC) to the platform controls that satisfy it. It is the primary artefact presented to the SOC 2 auditor and must be maintained as a living document. Each control must be **evidenced** — the evidence column identifies where the auditor can find proof.

**SOC 2 Trust Services Principles in scope:**
- **Security (CC)** — Required for all SOC 2 reports
- **Availability (A)** — Included (platform must meet SLO commitments)
- **Confidentiality (C)** — Included (data classification and access control)
- **Processing Integrity (PI)** — Included (data quality controls via Great Expectations)
- **Privacy (P)** — Included (GDPR alignment documented in `gdpr-data-map.md`)

---

## Common Criteria (CC) — Security

### CC1 — Control Environment

| Criteria | Description | Platform Control | Evidence |
|---|---|---|---|
| CC1.1 | COSO principle: integrity and values | Global constraints documented in PLAN.md; enforced by code review gates | PLAN.md; PR review history |
| CC1.2 | Board oversight | Architecture governance via ADR process; changes require architect approval | ADR revision history in Git |
| CC1.3 | Management structure | Defined roles: platform-admins, data-engineers, data-analysts (Keycloak groups) | Keycloak realm-export.json |
| CC1.4 | HR policies | Onboarding/offboarding automation via Keycloak + Airflow GDPR DAG | Airflow DAG: gdpr/offboard_user.py |
| CC1.5 | Accountability | Every action attributed to Keycloak `sub` claim in audit logs | Loki/Trino audit table: lakehouse.audit.* |

### CC2 — Communication and Information

| Criteria | Description | Platform Control | Evidence |
|---|---|---|---|
| CC2.1 | Quality of information | Great Expectations validation results; dbt test results | GX result JSON in MinIO gx-results/ |
| CC2.2 | Internal communication | Architecture docs (docs/architecture/); ADRs; Grafana dashboards | docs/; observability dashboards |
| CC2.3 | External communication | Security advisories: CVE scanning via `trivy` in CI; results published to ops channel | CI pipeline trivy reports |

### CC3 — Risk Assessment

| Criteria | Description | Platform Control | Evidence |
|---|---|---|---|
| CC3.1 | Risk identification | STRIDE threat model (docs/architecture/security-model.md) | security-model.md |
| CC3.2 | Risk analysis | ADR risk sections; HA trade-off analysis (ADR-008) | ADR-008 |
| CC3.3 | Risk evaluation | CI security gates: trivy, checkov, kube-score | CI pipeline logs |
| CC3.4 | Emerging risk | Dependency audit: `pip-audit` in CI; component version matrix reviewed quarterly | PLAN.md §6; CI reports |

### CC4 — Monitoring Activities

| Criteria | Description | Platform Control | Evidence |
|---|---|---|---|
| CC4.1 | Ongoing evaluation | Prometheus alert rules; Grafana SLO dashboards; weekly platform health review | observability/prometheus/rules/ |
| CC4.2 | Deficiency reporting | Alertmanager → PagerDuty; severity-classified incidents logged | Alertmanager logs; incident records |

### CC5 — Control Activities

| Criteria | Description | Platform Control | Evidence |
|---|---|---|---|
| CC5.1 | Control selection | mTLS (ADR-006), OIDC (ADR-007), Ranger RBAC (ADR-010), secret management (ADR-002) | Referenced ADRs |
| CC5.2 | Technology controls | cert-manager automated certificate management; ESO automated secret rotation | cert-manager logs; ESO SecretStore manifests |
| CC5.3 | Policies and procedures | Architecture docs + ADRs + runbooks in pipelines/scripts/dr/ | docs/; pipelines/scripts/dr/ |

### CC6 — Logical and Physical Access Controls

| Criteria | Description | Platform Control | Evidence |
|---|---|---|---|
| CC6.1 | Access restriction | Keycloak OIDC + Ranger RBAC; default-deny NetworkPolicy | Keycloak realm config; Ranger policy export; K8s NetworkPolicy manifests |
| CC6.2 | Privileged access | OpenBao root token destroyed post-init; platform-admins require MFA + VPN; no `cluster-admin` in prod | OpenBao audit log; K8s RBAC role bindings |
| CC6.3 | Access removal | Offboarding: Keycloak account disabled → tokens expire in 15 min; Airflow offboarding DAG | Airflow DAG: gdpr/offboard_user.py; Keycloak event log |
| CC6.4 | Access credentials | Zero hardcoded credentials; all secrets via OpenBao; rotation per Secret Graph (PLAN.md §8) | OpenBao audit log; ESO ExternalSecret resources |
| CC6.5 | Authentication complexity | MFA enforced by Keycloak for all production users; TOTP + WebAuthn supported | Keycloak realm policy: MFA required |
| CC6.6 | Data in transit | mTLS on all internal connections; TLS 1.3 for external ingress | cert-manager Certificate resources; Nginx TLS config |
| CC6.7 | Data at rest | MinIO SSE-KMS (OpenBao-managed keys) for sensitive buckets; PostgreSQL transparent encryption at block level (cloud provider) | MinIO SSE config; cloud storage config |
| CC6.8 | Unauthorized software | Container images built from official base images; trivy scans CRITICAL CVEs; admission controller rejects unknown images | CI trivy reports; K8s OPA admission policy |

### CC7 — System Operations

| Criteria | Description | Platform Control | Evidence |
|---|---|---|---|
| CC7.1 | Vulnerability detection | `trivy` on every image; `kube-score` + `checkov` on every manifest change | CI pipeline logs |
| CC7.2 | Anomaly detection | Prometheus rules: failed login rate, Ranger denial spike, query latency anomaly | observability/prometheus/rules/security-alerts.yaml |
| CC7.3 | Incident evaluation | Incident severity classification documented in security-model.md | security-model.md §Incident Response |
| CC7.4 | Incident response | Runbooks in pipelines/scripts/dr/; PagerDuty escalation for P1/P2 | pipelines/scripts/dr/ |
| CC7.5 | Response and recovery | Disaster recovery playbooks tested quarterly | DR test reports (manual) |

### CC8 — Change Management

| Criteria | Description | Platform Control | Evidence |
|---|---|---|---|
| CC8.1 | Change authorization | ADR process for architecture changes; PR review required (2 approvers) | Git PR history; ADR revisions |
| CC8.2 | Change design | Security review embedded in CI (checkov, trivy) | CI pipeline logs |
| CC8.3 | Change implementation | GitOps: Helm + Kustomize; ArgoCD or Flux CD (to be implemented Phase 5) | K8s manifest history |
| CC8.4 | Change communication | PLAN.md rollout strategy; staged release (local → staging → prod) | PLAN.md §13 |

### CC9 — Risk Mitigation

| Criteria | Description | Platform Control | Evidence |
|---|---|---|---|
| CC9.1 | Business disruption risk | HA topology (ADR-008); multi-cluster Trino; Patroni PostgreSQL; 3-node OpenBao | ha-topology.md; ADR-008 |
| CC9.2 | Vendor/third-party risk | 100% self-hosted; no SaaS sub-processors; vendor OSS license analysis (ADR-001 through ADR-007) | ADRs; gdpr-data-map.md |

---

## Availability (A) Criteria

| Criteria | Description | Platform Control | Evidence |
|---|---|---|---|
| A1.1 | Availability commitments | SLOs defined in ha-topology.md; Prometheus SLO recording rules | ha-topology.md; Prometheus rules |
| A1.2 | Availability monitoring | Prometheus + Grafana; uptime checks on all critical services | Grafana Platform Overview dashboard |
| A1.3 | Availability recovery | HA topology per ADR-008; DR runbooks tested | DR runbooks; Patroni failover test logs |

---

## Confidentiality (C) Criteria

| Criteria | Description | Platform Control | Evidence |
|---|---|---|---|
| C1.1 | Confidentiality identification | Data classification tags in OpenMetadata (PII_HIGH, PII_MEDIUM, SENSITIVE, PUBLIC) | OpenMetadata tag taxonomy |
| C1.2 | Information disposal | GDPR erasure pipeline (Iceberg delete + compaction + snapshot expiry) | Airflow DAG: gdpr/erasure_request.py; erasure certificates in audit-log/ |

---

## Processing Integrity (PI) Criteria

| Criteria | Description | Platform Control | Evidence |
|---|---|---|---|
| PI1.1 | Processing completeness | Great Expectations checkpoint: row count checks, completeness assertions | GX expectation suites in services/quality-gate/gx/ |
| PI1.2 | Processing accuracy | GX distribution checks; dbt schema tests (`not_null`, `unique`, `accepted_values`) | GX results; dbt test results |
| PI1.3 | Processing validity | Business rule expectations (custom GX expectations per domain) | Custom expectation implementations |
| PI1.4 | Processing authorization | Only Airflow DAGs (authenticated service accounts) modify data; no ad-hoc DML without approval | Ranger RBAC: no INSERT for analyst role |
| PI1.5 | Processing completeness over time | DAG success rate monitoring; GX trend dashboards | Grafana Pipeline Health dashboard |

---

## Privacy (P) Criteria

| Criteria | Description | Platform Control | Evidence |
|---|---|---|---|
| P1.1 | Privacy notice | Privacy policy published by organization | [Link to organization privacy policy] |
| P2.1 | Consent | Legal basis documented in gdpr-data-map.md per data category | gdpr-data-map.md |
| P3.1 | Collection consistent with objectives | Only data required for stated analytics purpose ingested; GX PII scanner quarantines unexpected PII | GX custom expectation: pii_scanner |
| P4.1 | Data use consistent with objectives | Ranger policies limit data access to authorized use cases | Ranger policy export |
| P5.1 | Data quality and accuracy | Great Expectations validation; rectification pipeline | Airflow DAG: gdpr/rectification_request.py |
| P6.1 | Retention | Iceberg table retention properties enforced by Airflow maintenance DAGs | Airflow DAG: maintenance/enforce_retention.py |
| P7.1 | Data disclosure | Zero external disclosure; self-hosted; no sub-processors | gdpr-data-map.md |
| P8.1 | Subject rights | Erasure, access, portability pipelines documented and tested | gdpr-data-map.md §Subject Rights |

---

## Evidence Collection Calendar

| Evidence Type | Collection Method | Frequency | Responsible | Storage |
|---|---|---|---|---|
| Access control review | Keycloak group export + Ranger policy export | Quarterly | Security Lead | MinIO: compliance/evidence/ |
| Secret rotation logs | OpenBao audit log extract | Monthly | Platform SRE | MinIO: compliance/evidence/ |
| Certificate expiry status | cert-manager CertificateRequest list | Monthly | Platform SRE | MinIO: compliance/evidence/ |
| GX checkpoint pass rates | Grafana Data Quality dashboard screenshot + Prometheus metrics export | Weekly | Data Engineering Lead | MinIO: gx-results/ |
| DR test results | Structured post-test report | Quarterly | Platform SRE | MinIO: compliance/dr-test-reports/ |
| Vulnerability scan results | trivy CI report aggregation | Per-deploy | CI/CD | MinIO: compliance/cve-reports/ |
| Failed login alerts | Prometheus alert evaluation log | Continuous | Alertmanager | Loki |
| User provisioning/deprovisioning | Airflow DAG run log | Per event | Airflow | Loki |

---

## Gap Register

> Track control gaps identified during internal assessment or audit. Resolve before Type II period.

| Gap ID | TSC Ref | Description | Owner | Target Date | Status |
|---|---|---|---|---|---|
| GAP-001 | CC8.3 | GitOps controller (ArgoCD/FluxCD) not yet implemented; manual deploy risk | Platform SRE | Phase 5 | Open |
| GAP-002 | CC7.1 | DAST (dynamic application security testing) not yet in pipeline | Security Lead | Phase 5 | Open |
| GAP-003 | P8.1 | Subject portability DAG not yet implemented (documented; not built) | Data Engineer | Phase 3 | Open |
| _[Add gaps as identified]_ | | | | | |

---

## References

- [AICPA Trust Services Criteria (2017)](https://www.aicpa.org/resources/article/trust-services-criteria)
- [COSO Internal Control Framework (2013)](https://www.coso.org/)
- `docs/compliance/audit-trail-specification.md` — audit evidence detail
- `docs/compliance/gdpr-data-map.md` — privacy control mapping
- `docs/architecture/security-model.md` — technical security controls
- All ADRs in `docs/adr/` — decision rationale for each control
