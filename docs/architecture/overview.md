# Architecture Overview — Open Lakehouse Platform

> **Version:** 1.0 | **Date:** 2026-03-12 | **Status:** Approved

---

## Purpose

This document provides a high-level map of all platform components, their responsibilities, and how they relate to each other. It is the entry point for new engineers and serves as the authoritative reference for component ownership boundaries.

For deeper dives, see:
- [data-flow.md](data-flow.md) — end-to-end ingestion and query paths
- [security-model.md](security-model.md) — mTLS, OIDC, RBAC, secret management
- [ha-topology.md](ha-topology.md) — per-component HA design
- [../adr/](../adr/) — Architecture Decision Records

---

## Platform Philosophy

| Principle | Implementation |
|---|---|
| 100% open source | Apache 2.0 preferred; no BSL, no SSPL |
| Zero hardcoded credentials | All secrets via OpenBao + ESO |
| Defense in depth | Network → Transport (mTLS) → Identity (OIDC) → Authorization (Ranger) → Audit |
| No single point of failure | Every critical path has HA coverage |
| Multi-environment | Local (Docker Compose) → Staging (K8s) → Prod (K8s + Terraform) |
| Compliance-ready | GDPR, SOC2, HIPAA audit trail from day 1 |

---

## Component Map

### Layer 1: Ingress & Identity

| Component | Version | Role | Namespace |
|---|---|---|---|
| Nginx / Traefik | latest stable | TLS termination, ingress routing | `ingress-ns` |
| Keycloak | latest stable | OIDC identity provider, SSO for all user-facing tools | `identity-ns` |

**Key property:** All user authentication flows through Keycloak. No component maintains its own user database. JWT tokens from Keycloak carry the `tenant_id`, `groups`, and `realm_roles` claims used by downstream authorization.

---

### Layer 2: Secret Management

| Component | Version | Role | Namespace |
|---|---|---|---|
| OpenBao | latest stable | Secrets store (KV, PKI, dynamic credentials) | `secrets-ns` |
| External Secrets Operator | latest stable | Syncs OpenBao secrets into K8s Secrets | `secrets-ns` |
| cert-manager | latest stable | Automates TLS certificate lifecycle via OpenBao PKI | `secrets-ns` |

**Key property:** Services never read secrets directly from OpenBao. ESO pulls secrets and materializes them as K8s Secrets in the target namespace. cert-manager issues and renews mTLS certificates automatically. See ADR-002 and ADR-006.

---

### Layer 3: Storage

| Component | Version | Role | Namespace |
|---|---|---|---|
| MinIO | latest stable | S3-compatible object storage for Iceberg data files | `storage-ns` |
| PostgreSQL 16 | 16 | Shared relational backend for stateful services | `db-ns` |

**Key property:** MinIO runs in distributed mode (erasure coding) for fault tolerance. The `audit-log/` bucket has S3 Object Lock in Compliance mode — immutable 7-year retention. PostgreSQL uses Patroni for automatic HA failover. See ADR-008.

---

### Layer 4: Catalog

| Component | Version | Role | Namespace |
|---|---|---|---|
| Apache Polaris | 1.2.0 | Production Iceberg REST catalog; multi-warehouse multi-tenant | `catalog-ns` |
| Project Nessie | latest stable | Development/CI Iceberg catalog with Git-like branching semantics | `catalog-ns` |

**Key property:** Polaris is the production catalog. Nessie is for development and CI branch isolation. They are used exclusively per environment, never for the same table simultaneously. See ADR-001 and ADR-005.

---

### Layer 5: Compute (Query Engine)

| Component | Version | Role | Namespace |
|---|---|---|---|
| Trino Gateway | latest stable | Load balancer; JWT validation; cluster routing by resource group | `compute-ns` |
| Trino | 479 | MPP SQL query engine; reads Iceberg via Polaris/Nessie; enforces Ranger policies | `compute-ns` |

**Key property:** Two independent Trino clusters (A and B) provide HA. Trino Gateway routes queries and drains gracefully on rolling upgrades. Resource groups enforce per-tenant compute quotas. All data access decisions are enforced by the Ranger plugin running inside Trino. See ADR-010.

---

### Layer 6: Policy Engine

| Component | Version | Role | Namespace |
|---|---|---|---|
| Apache Ranger | 2.6.0 | RBAC, ABAC, row-level security, column masking for Trino | `policy-ns` |

**Key property:** Ranger is the authorization system for all data access. Ranger policies are defined centrally and enforced at query time via the Ranger Trino plugin. Policies are tag-aware (integrates with OpenMetadata tags). See ADR-010.

---

### Layer 7: Ingestion & Transformation

| Component | Version | Role | Namespace |
|---|---|---|---|
| Apache Airflow | 2.10.x | Workflow orchestrator for all pipelines | `ingestion-ns` |
| Docling (IBM) | latest stable | Document parser (PDF, DOCX, HTML → Parquet) | `ingestion-ns` |
| Great Expectations | latest stable | Data quality validation framework | `ingestion-ns` |
| dbt-core + dbt-trino | latest stable | SQL transformation models (staging → intermediate → mart) | `ingestion-ns` |

**Key property:** All ingestion, quality gate, and transformation logic is orchestrated by Airflow. Docling workers are stateless and horizontally scalable. GX checkpoints are the stop-the-line quality gate — data is quarantined if expectations fail. See ADR-003 and ADR-004.

---

### Layer 8: Metadata & Lineage

| Component | Version | Role | Namespace |
|---|---|---|---|
| OpenMetadata | 1.12.x | Data catalog UI, lineage, data discovery, governance workflows | `metadata-ns` |

**Key property:** OpenMetadata crawls Trino (which surfaces Polaris/Nessie table metadata) to build lineage graphs. Tags applied in OpenMetadata are synced to Ranger for policy enforcement. OpenMetadata is the human interface for data governance. It does not store data — only metadata and lineage.

---

### Layer 9: Observability

| Component | Version | Role | Namespace |
|---|---|---|---|
| Prometheus + Alertmanager | latest stable | Metrics collection and alert routing | `observability-ns` |
| Grafana | latest stable | Unified observability dashboards | `observability-ns` |
| Grafana Loki + Promtail | latest stable | Log aggregation (hot tier — 90 days) | `observability-ns` |
| OpenTelemetry Collector | latest stable | Trace/metric/log aggregation from all services | `observability-ns` |

**Key property:** All services emit metrics, logs, and traces to the OTEL Collector. The Collector routes to Prometheus (metrics), Loki (logs), and Tempo (traces — optional). Grafana is the single observability UI. Alertmanager routes critical alerts to PagerDuty/Slack.

---

## Component Dependency Graph (Startup Order)

```
PostgreSQL (Patroni)
    │
    ├─▶ OpenBao (Raft) ──▶ cert-manager ──▶ ESO
    │                                         │
    ├─▶ Keycloak (JGroups cluster)            │ (secrets + certs injected)
    │                                         │
    ├─▶ MinIO (distributed) ◄─────────────────┤
    │                                         │
    ├─▶ Apache Polaris ◄──────────────────────┤
    │                                         │
    ├─▶ Project Nessie ◄──────────────────────┤
    │                                         │
    ├─▶ Apache Ranger ◄───────────────────────┤
    │                                         │
    └─▶ Trino (via Trino Gateway) ◄──────────-┘
           │
           ├─▶ Apache Airflow
           │       ├─▶ Docling workers
           │       ├─▶ Great Expectations
           │       └─▶ dbt-trino
           │
           └─▶ OpenMetadata
```

All observability components (Prometheus, Loki, OTEL Collector) start in parallel with the above; they are not on the critical startup path.

---

## Canonical Versions Reference

| Component | Version | License |
|---|---|---|
| Apache Iceberg | 1.10.x | Apache 2.0 |
| Apache Polaris | 1.2.0 | Apache 2.0 |
| Project Nessie | latest stable | Apache 2.0 |
| Trino | 479 | Apache 2.0 |
| Trino Gateway | latest stable | Apache 2.0 |
| Apache Ranger | 2.6.0 | Apache 2.0 |
| OpenMetadata | 1.12.x | Apache 2.0 |
| OpenBao | latest stable | Apache 2.0 |
| External Secrets Operator | latest stable | Apache 2.0 |
| cert-manager | latest stable | Apache 2.0 |
| Keycloak | latest stable | Apache 2.0 |
| Docling (IBM) | latest stable | Apache 2.0 |
| Apache Airflow | 2.10.x | Apache 2.0 |
| dbt-core + dbt-trino | latest stable | Apache 2.0 |
| Great Expectations | latest stable | Apache 2.0 |
| MinIO | latest stable | AGPL 3.0 |
| Prometheus + Alertmanager | latest stable | Apache 2.0 |
| Grafana | latest stable | AGPL 3.0 |
| OpenTelemetry Collector | latest stable | Apache 2.0 |
| Grafana Loki + Promtail | latest stable | AGPL 3.0 |
| PostgreSQL | 16 | PostgreSQL License |

---

## Environment Matrix

| Aspect | Local (Docker Compose) | Staging (K8s) | Production (K8s + Terraform) |
|---|---|---|---|
| Catalog | Nessie only | Polaris + Nessie | Polaris (prod) + Nessie (dev branch) |
| MinIO | Single node (dev mode) | 4-node distributed | 8-node distributed |
| Trino | 1 coordinator + 2 workers | 1 coordinator + 4 workers | 2 coordinators + HPA workers |
| PostgreSQL | Single standalone | Patroni 1+1 | Patroni 1+1+1 read replica |
| OpenBao | Dev mode (single) | 3-node Raft | 3-node Raft + cloud KMS seal |
| Keycloak | Single node | 2-node cluster | 3-node cluster |
| Secrets | `.env.example` (no real secrets) | ESO + OpenBao | ESO + OpenBao |
| mTLS | Disabled (dev convenience) | Enabled | Enabled |
| Ranger | Optional | Enabled | Enabled |
