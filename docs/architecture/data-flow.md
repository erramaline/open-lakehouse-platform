# Data Flow — Open Lakehouse Platform

> **Version:** 1.0 | **Date:** 2026-03-12

---

## Overview

This document describes all data flows through the platform: from raw document ingestion to analytics-ready Iceberg tables, through transformation and quality gates, and finally to query consumers. Each flow is documented with the participating components, data format at each stage, and the Airflow DAG responsible for orchestration.

---

## 1. Document Ingestion Flow

### 1.1 Entry Points

| Source Type | Format | Landing Zone |
|---|---|---|
| File upload (API/SFTP) | PDF, DOCX, PPTX, HTML, EPUB, images | MinIO: `s3://lakehouse-data/raw/<tenant>/<date>/` |
| API push (REST) | JSON, CSV, XML | MinIO: `s3://lakehouse-data/raw/<tenant>/<date>/` |
| Object storage sync | Parquet, ORC, Avro | MinIO: `s3://lakehouse-data/raw/<tenant>/<date>/` |
| Database CDC (future) | Change events | Kafka → MinIO (Wave 4) |

### 1.2 Full Document Ingestion Pipeline

```
Stage 0: Landing
┌────────────────────────────────────────────────────────────────┐
│ MinIO bucket: raw/<tenant>/<source>/<YYYY-MM-DD>/              │
│ Format: original (PDF, DOCX, etc.) — immutable, never deleted  │
│ Retention: 7 years (WORM Compliance mode)                      │
└───────────────────────────┬────────────────────────────────────┘
                            │ Airflow DAG: ingestion/detect_new_files.py
                            │ (S3 event notification → Airflow sensor)
                            ▼
Stage 1: Docling Parsing
┌────────────────────────────────────────────────────────────────┐
│ Docling Worker (K8s Job, GPU optional)                         │
│ Input:  raw document (any format)                              │
│ Output: DoclingDocument JSON + Parquet (tables extracted)       │
│ Side effects:                                                  │
│   - Document metadata written to: staging/<tenant>/metadata/   │
│   - Extracted tables written to:  staging/<tenant>/tables/     │
│   - Full text written to:         staging/<tenant>/text/       │
│ Format: Apache Parquet (snappy compression), partitioned by    │
│         source_date / document_type                            │
└───────────────────────────┬────────────────────────────────────┘
                            │ Airflow DAG: ingestion/ingest_documents.py
                            ▼
Stage 2: Staging Registration in Polaris
┌────────────────────────────────────────────────────────────────┐
│ Airflow TaskGroup: register_iceberg_table                      │
│ - CREATE TABLE IF NOT EXISTS <tenant>.staging.<domain>        │
│   (using Iceberg REST API via Polaris)                        │
│ - MSCK REPAIR TABLE (discover new Parquet partitions)         │
│ - Snapshot created in Polaris                                  │
└───────────────────────────┬────────────────────────────────────┘
                            │
                            ▼
Stage 3: Quality Gate (Great Expectations)
┌────────────────────────────────────────────────────────────────┐
│ GX Checkpoint: staging_<domain>_suite                          │
│ Execution Engine: SqlAlchemyExecutionEngine → Trino → Iceberg  │
│ Expectations:                                                  │
│   - Schema: column types, nullability, required columns        │
│   - Completeness: null rate < 5% for mandatory fields          │
│   - Distribution: row count within expected range              │
│   - PII scan: custom expectation (no SSN/card numbers in text) │
│   - Referential integrity: foreign keys resolvable             │
│                                                                │
│ On PASS → continue to Stage 4                                  │
│ On FAIL → quarantine:                                          │
│   - Move Parquet to s3://lakehouse-data/quarantine/<tenant>/   │
│   - Mark Iceberg snapshot as "quarantine" in table properties  │
│   - Alert: Slack + PagerDuty (if data_quality_critical tag)    │
│   - DAG stops; downstream tasks skipped                        │
└───────────────────────────┬────────────────────────────────────┘
                            │ (on PASS)
                            ▼
Stage 4: dbt Transformation
┌────────────────────────────────────────────────────────────────┐
│ dbt-trino run (via Trino 479 → Polaris → MinIO)               │
│                                                                │
│ models/staging/<domain>/                                       │
│   - Type casting, null handling, deduplication                 │
│   - Writes to: <tenant>.staging_clean.<domain> in Polaris      │
│                                                                │
│ models/intermediate/<domain>/                                  │
│   - Business logic, joins, aggregations                        │
│   - Writes to: <tenant>.intermediate.<domain>                  │
│                                                                │
│ models/marts/<domain>/                                         │
│   - Analytics-ready wide tables / star schema                  │
│   - Writes to: <tenant>.marts.<domain>                         │
│                                                                │
│ dbt test suite runs after each layer                           │
│ dbt docs generated → pushed to OpenMetadata                    │
└───────────────────────────┬────────────────────────────────────┘
                            │
                            ▼
Stage 5: Mart Quality Gate
┌────────────────────────────────────────────────────────────────┐
│ GX Checkpoint: marts_<domain>_suite                            │
│ - Business rule assertions (revenue ≥ 0, date ranges valid)    │
│ - SLA breach detection (row count growth anomaly)              │
│ On PASS → tables available for query                           │
│ On FAIL → Ranger policy auto-applied to block mart query       │
│           (via Ranger REST API in Airflow error handler)        │
└───────────────────────────┬────────────────────────────────────┘
                            │
                            ▼
Stage 6: Metadata Sync (OpenMetadata)
┌────────────────────────────────────────────────────────────────┐
│ OpenMetadata Trino Connector (scheduled crawl: every 4 hours)  │
│ - Discovers new table/column metadata from Polaris via Trino   │
│ - Builds lineage: raw document → staging → intermediate → mart │
│ - Applies PII tags (based on column name patterns + GX results) │
│ - Publishes Data Quality summary from GX result JSON           │
└────────────────────────────────────────────────────────────────┘
```

---

## 2. Query Flow (Read Path)

### 2.1 Interactive Query (BI Tool / Notebook)

```
BI Tool (Superset / DBeaver / Jupyter)
    │ SQL query + JWT Bearer token
    ▼
Trino Gateway (HTTPS/443)
    │ JWT validation (Keycloak JWKS)
    │ Resource group assignment (from tenant_id JWT claim)
    ▼
Trino Coordinator (Cluster A or B)
    │ Parse SQL → query plan
    │
    ├─▶ Ranger Plugin (authorization check)
    │     - Table-level ALLOW/DENY
    │     - Row-level filter injection
    │     - Column masking instruction
    │     └─ Decision: ALLOW (continue) or DENY (return error)
    │
    ├─▶ Polaris REST API (mTLS)
    │     - Fetch table metadata (schema, partition spec)
    │     - Credential vending (per-table S3 access keys)
    │
    └─▶ Trino Workers (distributed)
         - Read Parquet files from MinIO (S3 API, mTLS)
         - Apply row filters + column masks from Ranger
         - Execute joins, aggregations, projections
         └─▶ Results → Coordinator → Gateway → Client
```

### 2.2 Query Lifecycle Audit

Every query generates an audit record:
```json
{
  "event_type": "query_completed",
  "query_id": "20260312_143022_00001_xyz",
  "user": "alice@tenant-a.com",
  "tenant_id": "tenant_a",
  "groups": ["data_analysts"],
  "sql_text": "SELECT id, name FROM tenant_a.marts.customers LIMIT 100",
  "tables_accessed": ["tenant_a.marts.customers"],
  "ranger_decision": "ALLOW",
  "rows_scanned": 1000000,
  "rows_returned": 100,
  "duration_ms": 432,
  "cluster": "trino-cluster-a",
  "timestamp": "2026-03-12T14:30:22.000Z"
}
```

Audit records are written by the Trino QueryEventListener to the Iceberg audit table and to Loki.

---

## 3. Iceberg Data Lifecycle

### 3.1 Table Lifecycle per Stage

```
Raw (immutable archive)
    │
    │ S3 Object Lock: COMPLIANCE
    │ Retention: 7 years
    │ Iceberg snapshots: never expired
    │
    ▼
Staging (validated data)
    │
    │ Retention: 90 days
    │ Iceberg snapshots: expired after 30 days
    │ Compaction: none (small files tolerated at staging)
    │
    ▼
Intermediate (business logic applied)
    │
    │ Retention: 30 days
    │ Iceberg snapshots: expired after 15 days
    │ Compaction: weekly (merge small files)
    │
    ▼
Mart (analytics serving layer)
    │
    │ Retention: indefinite (until explicit drop)
    │ Iceberg snapshots: kept 7 days (sufficient for rollback)
    │ Compaction: daily (Airflow DAG: maintenance/compact_marts.py)
    │ Sort order: defined per table for query performance
    │
    ▼
Audit tables (lakehouse.audit.*)
    │
    │ Retention: permanent (or 7 years minimum per WORM config)
    │ Snapshots: never expired
    │ Write mode: append-only
```

### 3.2 Iceberg Maintenance Operations (Airflow DAGs)

| DAG | Schedule | Operation | Tables |
|---|---|---|---|
| `compact_marts` | Daily 02:00 UTC | `ALTER TABLE ... EXECUTE optimize` | All mart tables |
| `expire_snapshots` | Daily 03:00 UTC | `ALTER TABLE ... EXECUTE expire_snapshots(older_than=...)` | Staging, intermediate |
| `orphan_cleanup` | Weekly Sunday 04:00 UTC | `ALTER TABLE ... EXECUTE remove_orphan_files` | All tables |
| `rewrite_manifests` | Weekly Sunday 05:00 UTC | `ALTER TABLE ... EXECUTE rewrite_manifests` | All mart tables |

---

## 4. Development Data Flow (Nessie)

```
Developer workstation
    │ dbt command or Jupyter notebook
    ▼
Trino (dev profile → Nessie catalog)
    │ config: catalog=nessie, nessie.ref=feature-branch-name
    │
    ▼
Project Nessie (dev catalog)
    │ Branch: feature-branch-name
    │ Tables isolated from main branch
    │
    ▼
MinIO: s3://lakehouse-dev/<branch>/
    │ Dev data only; no WORM; auto-deleted after branch merge
    │
    ▼ (on PR merge / branch promotion)
Airflow DAG: ingestion/promote_dev_to_staging.py
    │ Reads final snapshot from Nessie branch
    │ Registers tables in Polaris staging namespace
    └─▶ Polaris staging (→ full pipeline from Stage 3 onwards)
```

---

## 5. Secret and Credential Flow in the Data Path

```
At query time:
1. Trino requests table metadata from Polaris
   - Polaris uses its own S3 credentials (read from K8s Secret, injected by ESO)
   - Polaris returns table metadata + vended S3 credentials for the table's bucket prefix

2. Trino workers use vended S3 credentials to fetch Parquet files from MinIO
   - Credentials are short-lived (15-minute TTL from Polaris credential vending)
   - Credentials scoped to the specific bucket prefix (no cross-tenant bucket access)

3. Audit events written using the trino-audit-writer S3 credentials
   - Separate service account with only PutObject on audit-log/ bucket
   - No DeleteObject permission on audit-log/ bucket (enforced at MinIO policy level)
```

---

## 6. Data Quality Score Propagation

```
Great Expectations validation result (JSON)
    │
    ├─▶ MinIO: gx-results/validations/<suite>/<run-id>.json
    │
    ├─▶ OpenMetadata: Data Quality tab for the table
    │     - Pass rate %, expectation breakdown, trend over time
    │
    └─▶ Prometheus metric: gx_expectation_pass_rate{suite, table}
          → Grafana: Data Quality dashboard
          → Alert: if pass_rate < 0.95 for 3 consecutive runs → PagerDuty
```

---

## 7. Lineage Graph (OpenMetadata)

OpenMetadata automatically constructs the following lineage from Trino query parsing and dbt manifest:

```
[Raw Files in MinIO]
    └─▶ [Iceberg: tenant_a.staging.documents]      (via Docling Airflow task)
            └─▶ [Iceberg: tenant_a.staging_clean.documents]  (via dbt staging model)
                    └─▶ [Iceberg: tenant_a.intermediate.doc_segments]  (via dbt intermediate)
                            └─▶ [Iceberg: tenant_a.marts.document_metrics]  (via dbt mart)
                                    └─▶ [Grafana Dashboard: Document Analytics]
                                    └─▶ [BI Tool: Document Report]
```

Column-level lineage is captured via dbt manifest parsing (dbt `--artifact` output → OpenMetadata ingestion connector).
