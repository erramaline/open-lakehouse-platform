# ADR-001: Why Apache Polaris over Apache Atlas as Primary Iceberg Catalog

| Field | Value |
|---|---|
| **Status** | Accepted |
| **Date** | 2026-03-12 |
| **Deciders** | Principal Data Platform Architect, Data Engineering Lead |
| **Tags** | catalog, iceberg, metadata |

---

## Context

The platform requires a catalog service to manage Apache Iceberg table metadata. A catalog must:

1. Serve the Iceberg REST Catalog specification, enabling Trino 479 and all Iceberg clients to interact via a stable, vendor-neutral API.
2. Be 100% open source (Apache 2.0 or compatible) with no BSL or SSPL licensing.
3. Support multi-tenant warehouse isolation for different business units.
4. Provide fine-grained access control over namespaces and tables.
5. Be actively maintained with a clear governance model.

Two primary candidates were evaluated: **Apache Polaris** and **Apache Atlas**.

---

## Decision

**We adopt Apache Polaris 1.2.0 as the primary production Iceberg catalog.**

---

## Consequences

### Positive
- **Native Iceberg REST API:** Polaris implements the Iceberg REST Catalog specification natively. Trino, Spark, Flink, and PyIceberg connect without adapters or plugins. Atlas does not implement this specification.
- **Multi-warehouse isolation:** Polaris provides first-class multi-warehouse support with per-warehouse storage credentials, enabling strong tenant isolation without additional tooling.
- **Fine-grained table-level RBAC:** Polaris includes a built-in privilege model (catalog roles, principal roles) mapped per namespace and table — directly applicable to our multi-tenancy model (see ADR-010).
- **Apache Software Foundation (ASF) governance:** Graduated ASF top-level project; community-driven with transparent roadmap. No single corporate entity controls the IP.
- **Lightweight deployment:** Single JAR with PostgreSQL backend; fits in K8s with modest resources (2 CPUs / 4 GiB per replica).

### Negative
- **Younger project:** Polaris reached ASF top-level status in 2025; operational maturity is lower than Atlas (est. 2015). Edge cases may surface in production.
- **No lineage engine:** Polaris is a pure catalog, not a lineage tool. Lineage is handled by OpenMetadata (ADR not required — this is additive, not a replacement).
- **Limited plugin ecosystem:** Compared to Atlas, Polaris has fewer out-of-box connectors for legacy systems. Acceptable because we are building greenfield.

### Neutral
- Polaris catalog data is stored in PostgreSQL 16 — consistent with our shared database strategy.

---

## Alternatives Considered

### Apache Atlas
| Criterion | Apache Atlas | Apache Polaris |
|---|---|---|
| Iceberg REST Catalog API | ❌ Not implemented | ✅ Native |
| License | Apache 2.0 | Apache 2.0 |
| Multi-warehouse isolation | ❌ Manual tagging workaround | ✅ First-class |
| Table-level RBAC | Partial (tag-based policies) | ✅ Role-based |
| Active Iceberg community | Low (no Iceberg WG involvement) | ✅ High (co-authored with Snowflake, Apple) |
| Operational complexity | High (HBase/Kafka/Solr required) | Low (PostgreSQL only) |
| **Decision** | ❌ Rejected | ✅ Selected |

**Rejection reason for Atlas:** Apache Atlas was designed for Hadoop-era metadata management. It requires HBase, Kafka, and Solr — a heavyweight dependency graph inconsistent with our lean K8s-first architecture. Most critically, Atlas does not implement the Iceberg REST Catalog API and would require a custom bridge, introducing a fragile, unsupported layer between Trino and Iceberg tables.

### Unity Catalog (Databricks)
- **Rejected:** Not Apache 2.0. Databricks-controlled governance. Does not meet our 100% OSS requirement.

### Hive Metastore (HMS)
- **Rejected:** Deprecated path for Iceberg in Trino 479. HMS Thrift API predates the REST Catalog specification and provides no warehouse isolation or credential vending.

### AWS Glue
- **Rejected:** Cloud vendor lock-in. Not self-hostable. Violates our multi-cloud portability requirement.

---

## References
- [Apache Polaris GitHub](https://github.com/apache/polaris)
- [Iceberg REST Catalog Specification](https://iceberg.apache.org/rest/)
- [Trino Iceberg Connector Docs](https://trino.io/docs/current/connector/iceberg.html)
- ADR-005 — Dual catalog strategy (Polaris prod / Nessie dev)
- ADR-010 — Multi-tenancy model
