# ADR-004: Why Great Expectations for Data Quality

| Field | Value |
|---|---|
| **Status** | Accepted |
| **Date** | 2026-03-12 |
| **Deciders** | Principal Data Platform Architect, Data Engineering Lead, Data Governance Lead |
| **Tags** | data-quality, testing, governance |

---

## Context

The platform requires a data quality framework to:

1. Validate data at multiple pipeline stages (staging, intermediate, marts) before promotion.
2. Enforce schema contracts — column types, nullability, cardinality.
3. Detect data drift — statistical distributions, referential integrity.
4. Generate human-readable validation reports consumable by both engineers and business data stewards.
5. Trigger pipeline quarantine when validation fails (stop-the-line mechanism).
6. Integrate natively with Apache Airflow (orchestrator) and Trino (query engine).
7. Be 100% open source (Apache 2.0 or compatible). No SaaS data quality platform dependency.
8. Support custom expectations for domain-specific rules (PII detection, business rule validation).

Three candidates were evaluated: **Great Expectations**, **Apache Griffin**, and **Soda Core**.

---

## Decision

**We adopt Great Expectations (GX, latest stable) as the data quality framework.**

---

## Consequences

### Positive
- **Rich expectation library:** 300+ built-in expectations covering schema, completeness, distribution, referential integrity, and custom SQL expressions. Fastest time-to-quality for common checks.
- **Trino SQLAlchemy support:** GX connects to Trino via `sqlalchemy-trino` datasource — no custom connector needed. Runs validation as SQL pushdown directly in Trino, leveraging Iceberg's partition pruning.
- **Airflow-native operator:** `GreatExpectationsOperator` available in `apache-airflow-providers-great-expectations`. Standard pipeline integration.
- **Checkpoint system:** Checkpoints bundle expectations suites + actions (quarantine, Slack alert, write validation result to MinIO) into reusable, versioned artifacts.
- **Data Docs:** Auto-generated HTML reports from validation results — accessible to non-technical data stewards without code.
- **Custom expectations:** Extensible with Python; domain-specific rules (PII field format, tenure date logic) implemented as `ColumnAggregateExpectation` or SQL-based.
- **Apache 2.0:** No feature gating, no SaaS call required for core functionality.
- **Validation result persistence:** Results stored as JSON in MinIO (dedicated `gx-results/` bucket) — immutable audit trail of data quality history.

### Negative
- **Python-first API:** GX Context configuration is code-heavy (Python or YAML). Learning curve for non-Python data engineers.
- **Slow on large tables without pushdown:** Suite runs that materialize data locally (Pandas engine) will not scale. Mitigation: always use `SqlAlchemyExecutionEngine` (pushdown to Trino).
- **No streaming validation:** Batch-only in the current architecture. Real-time quality checks for streaming pipelines are out of scope for Wave 1 (see PLAN.md rollout strategy).
- **GX Cloud optional:** Managed collaboration features require GX Cloud (SaaS). We intentionally do not use GX Cloud; Data Docs are self-hosted on MinIO + static hosting.

### Neutral
- GX validation results are structured JSON, easily parseable by OpenMetadata for quality metric lineage tagging.

---

## Alternatives Considered

### Apache Griffin
| Criterion | Apache Griffin | Great Expectations |
|---|---|---|
| License | Apache 2.0 | Apache 2.0 |
| Native Spark integration | ✅ | Via Spark connector |
| Native Trino / SQL DB support | ❌ (Spark only) | ✅ (SQLAlchemy) |
| Expectation library | Limited | 300+ built-in |
| Custom expectations | Complex (Scala/Java) | Simple (Python) |
| Airflow integration | Manual | ✅ Official provider |
| Data Docs / reporting | ❌ | ✅ Auto-generated |
| Active maintenance | Low (stagnant releases) | High (regular releases) |
| **Decision** | ❌ Rejected | ✅ Selected |

**Rejection reason:** Apache Griffin is a Spark-centric framework; adding a Spark dependency solely for data quality is architecturally expensive when our compute layer is already Trino. Griffin lacks native Trino support and has low release cadence.

### Soda Core
| Criterion | Soda Core | Great Expectations |
|---|---|---|
| License | Apache 2.0 (core) | Apache 2.0 |
| Managed SaaS dependency | Soda Cloud recommended | Optional (GX Cloud); avoided |
| Trino / Iceberg support | ✅ (via `soda-trino`) | ✅ (via `sqlalchemy-trino`) |
| YAML-first config | ✅ | Hybrid (Python + YAML) |
| Expectation library | Smaller (checks-based) | Larger (300+ expectations) |
| Custom Python checks | Limited | ✅ Full Python extensibility |
| Airflow integration | Manual (PythonOperator) | ✅ Official provider |
| Data lineage integration | Via Soda Cloud only | Via JSON result files |
| **Decision** | ❌ Rejected | ✅ Selected |

**Rejection reason:** Soda Core's production workflow is designed around Soda Cloud for collaboration, alerting, and monitoring. Without Soda Cloud, the self-hosted experience lacks built-in reporting comparable to GX Data Docs. Additionally, GX's Python extensibility is superior for custom business-rule expectations.

### dbt Tests (as sole quality layer)
- **Rejected as primary:** dbt tests (generic + singular) are excellent for model-level schema contracts but insufficient for statistical distribution checks, cross-table referential integrity, and pre-ingestion validation before data enters Iceberg. We use dbt tests as a **complementary layer** (post-transform schema assertions), not as a replacement for GX (pre-promotion data quality gate).

---

## Integration Architecture

```
Airflow DAG (quality/gx_staging_checkpoint.py)
    │
    ▼
GreatExpectationsOperator
    ├─ Datasource: SqlAlchemyExecutionEngine → Trino → Iceberg (staging tables)
    ├─ Expectations Suite: staging_<domain>_suite.json
    └─ Checkpoint actions:
         ├─ UpdateDataDocsAction → MinIO (gx-results/docs/)
         ├─ StoreValidationResultAction → MinIO (gx-results/validations/)
         └─ SlackNotificationAction (on FAIL)
              │
              ▼ (on FAIL)
         Airflow sets quarantine flag → downstream tasks skipped
              │
              ▼ (on PASS)
         Airflow triggers dbt transformation DAG
```

---

## References
- [Great Expectations documentation](https://docs.greatexpectations.io/)
- [apache-airflow-providers-great-expectations](https://airflow.apache.org/docs/apache-airflow-providers-great-expectations/)
- [sqlalchemy-trino](https://github.com/trinodb/trino-python-client)
- [Apache Griffin GitHub](https://github.com/apache/griffin)
- [Soda Core GitHub](https://github.com/sodadata/soda-core)
- ADR-009 — Audit trail (GX validation results as audit evidence)
