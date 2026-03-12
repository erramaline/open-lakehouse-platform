# ADR-005: Dual Catalog Strategy — Polaris (Prod) vs Nessie (Dev/Branching)

| Field | Value |
|---|---|
| **Status** | Accepted |
| **Date** | 2026-03-12 |
| **Deciders** | Principal Data Platform Architect, Data Engineering Lead |
| **Tags** | catalog, iceberg, developer-experience, cicd |

---

## Context

The platform needs a catalog strategy that serves two distinct use cases simultaneously:

1. **Production workloads:** Stable, access-controlled, audited Iceberg tables with strict schema governance. Data is promoted through a defined pipeline and cannot be modified ad-hoc by engineers.
2. **Development / experimentation:** Developers and data engineers need the ability to create branches, experiment with schema changes, test dbt models against isolated copies of production data, and merge changes without affecting production consumers.

A single catalog with a single mutability model cannot serve both use cases well:
- Using a production-grade catalog for dev creates governance overhead and risk of accidental production data corruption.
- Using a branching catalog in production introduces replay complexity and reduces auditability.

Two catalogs were evaluated for the development role: **Project Nessie** and re-using Polaris with separate namespaces.

---

## Decision

**We maintain two Iceberg catalogs:**
- **Apache Polaris 1.2.0** — production and staging environments; single source of truth for governed data.
- **Project Nessie (latest stable)** — development and CI environments; Git-like branching semantics for experimental workflows.

The two catalogs serve different namespaces and are **never used simultaneously for the same table** at any given environment level.

---

## Catalog Assignment by Environment

| Environment | Catalog | Namespace Prefix | Use Case |
|---|---|---|---|
| Production | Polaris | `lakehouse.*` | Governed tables, BI queries, GDPR-compliant |
| Staging | Polaris | `lakehouse_staging.*` | Pre-production validation, QA queries |
| Development | Nessie | `dev.<developer>.*` | Experimentation, branch-based dbt development |
| CI/CD | Nessie | `ci.<branch-name>.*` | Automated test isolation per pipeline run |

---

## Why Project Nessie for Development

### Git-Semantics for Data

Nessie provides **branch, tag, merge, and diff** operations at the Iceberg catalog level — analogous to Git for code. This enables:

- `git checkout -b feat/new-schema` → `nessie branch create feat-new-schema`
- Developer creates experimental tables on their branch, isolated from `main`.
- dbt model runs against `feat-new-schema` branch; test results validated.
- `git merge` → `nessie merge feat-new-schema into main` — atomic Iceberg snapshot promotion.
- CI pipeline: each PR creates a Nessie branch `ci/<PR-number>`, runs integration tests, then deletes the branch on merge.

### Branch Isolation for CI

Without Nessie branching, CI integration tests either:
- Pollute shared dev tables (race conditions between parallel pipelines), or
- Require per-test database/schema setup (complex, slow, brittle).

With Nessie: each CI run creates an isolated branch, writes test data, validates dbt models, asserts quality, then deletes the branch. Zero cross-run interference. Branch creation is near-instantaneous (pointer operation only).

### Why Not Polaris Namespaces for Dev?

| Criterion | Polaris (separate namespace per dev) | Nessie (branching) |
|---|---|---|
| Isolation between developers | Namespace-level only; no data copy | Full branch isolation |
| Schema experimentation | Requires DDL on shared catalog | Branch-local; no impact on `main` |
| CI run isolation | Namespace creation per run (slow) | Branch creation per run (instant) |
| Merge / promotion workflow | Manual DDL + INSERT | `nessie merge` (atomic) |
| Time-travel across branches | Not supported | ✅ Nessie tags |
| Complexity | Low | Medium |

The namespace approach in Polaris does not provide the data isolation developers need — a schema change on a shared staging namespace affects all concurrent users. Nessie branching is a superior isolation primitive.

---

## Consequences

### Positive
- **Developer productivity:** Branch, experiment, merge — familiar Git workflow applied to data. Reduces fear of "breaking production" during development.
- **CI safety:** Branch-per-PR in Nessie enables parallel CI runs without shared state interference.
- **Production integrity:** Polaris remains the single source of truth for production data; no experimental branches can contaminate it.
- **Atomic promotion:** `nessie merge` is an atomic catalog metadata operation — no partial-write risk during branch promotion.
- **Both Apache 2.0:** No licensing conflict with global constraint.
- **Trino supports both:** Trino 479 supports both Iceberg REST (Polaris) and Nessie REST catalog simultaneously via different catalog names in `etc/catalog/*.properties`.

### Negative
- **Operational complexity:** Two catalog services to operate, monitor, and upgrade. Mitigated by using separate K8s namespaces with identical observability.
- **Data copy cost for dev:** Developer branches on Nessie pointing at real data must either reference the same MinIO objects (zero-copy, read-only) or copy partitions (expensive). We adopt the zero-copy reference-only model for dev branches — no writes from dev branches back to production MinIO paths.
- **No unified search across both catalogs:** OpenMetadata must be configured to crawl both Polaris and Nessie. Catalog metadata is aggregated in OpenMetadata's unified view.
- **Developer education:** Engineers must internalize the "two catalogs, different purposes" model. Mitigated by onboarding documentation and dbt profile templates.

### Neutral
- Nessie is deployed in `catalog-ns` alongside Polaris but with a separate Deployment, Service, and PostgreSQL database.
- Ranger policies are **not applied** to Nessie (dev catalog). Nessie access is controlled via Keycloak group membership (dev team only).

---

## Promotion Workflow: Nessie Dev → Polaris Prod

```
1. Developer creates Nessie branch:
   nessie branch create feat-new-model

2. dbt runs against Nessie branch:
   - Profile: nessie_dev
   - Catalog config: catalog = nessie, nessie.ref = feat-new-model

3. GX checkpoint validates model output on Nessie branch

4. PR opened → CI pipeline creates ci/<PR-number> Nessie branch

5. On PR merge:
   - CI promotes data to Polaris staging namespace via Airflow DAG:
     a. Read Iceberg snapshot from Nessie branch
     b. Write DDL + INSERT OVERWRITE to Polaris staging namespace
     c. Ranger policy validated against staging data
     d. GX staging checkpoint passes

6. Manual approval by data owner

7. Airflow DAG promotes to Polaris production namespace
   - CREATE TABLE IF NOT EXISTS ... AS SELECT (from Polaris staging)
   - Tag previous snapshot for rollback: polaris tag create pre-<PR-number>
```

---

## Alternatives Considered

### Single Polaris catalog with namespace isolation
- **Rejected:** No branching semantics; developers cannot isolate experimental changes from each other. CI runs interfere. See table comparison above.

### Single Nessie catalog for all environments
- **Rejected:** Nessie's production access controls are less mature than Polaris for enterprise RBAC. Nessie does not support credential vending per warehouse (required for MinIO per-table credentials in production). Polaris is the right production catalog.

### Apache Iceberg's REST + in-memory catalog for CI
- **Rejected:** No persistence across test runs; cannot replay historical data for regression testing. Nessie's branch model is superior.

---

## References
- [Project Nessie GitHub](https://github.com/projectnessie/nessie)
- [Project Nessie — Iceberg branching](https://projectnessie.org/iceberg/)
- [Apache Polaris GitHub](https://github.com/apache/polaris)
- [Trino — Multiple Iceberg catalogs](https://trino.io/docs/current/connector/iceberg.html#general-configuration)
- ADR-001 — Why Polaris (production catalog decision)
- ADR-010 — Multi-tenancy model
