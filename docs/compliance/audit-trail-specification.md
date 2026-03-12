# Audit Trail Specification — Open Lakehouse Platform

> **Version:** 1.0 | **Date:** 2026-03-12 | **Classification:** CONFIDENTIAL  
> **Owner:** Security Lead + Platform Architect  
> **Review Cycle:** Annual + on any audit system change

---

## Purpose

This document provides the authoritative technical specification for the platform's audit trail system. It defines:
- The canonical event schema for each audit source.
- The storage architecture and immutability guarantees.
- The hash chain mechanism for tamper evidence.
- The access control model for audit data.
- The query interface for compliance reporting.
- The retention and erasure model per GDPR.

For the design rationale, see [ADR-009](../adr/ADR-009-audit-trail-design.md).

---

## 1. Canonical Audit Event Schema

All audit events from all sources are normalized to the following base schema before storage. Source-specific fields are included in the `event` object.

### 1.1 Base Schema (JSON)

```json
{
  "schema_version": "1.0",
  "event_id": "<uuid-v4>",
  "timestamp": "<ISO-8601 UTC with milliseconds>",
  "source_system": "<string: openbao | keycloak | trino | ranger | airflow | postgresql | minio | k8s | openmetadata | certmanager>",
  "source_host": "<hostname or pod name>",
  "source_namespace": "<kubernetes namespace>",
  "event_type": "<string — see Event Type Registry below>",
  "outcome": "<SUCCESS | FAILURE | PARTIAL>",
  "actor": {
    "type": "<USER | SERVICE | SYSTEM>",
    "sub": "<Keycloak UUID or service account name>",
    "username": "<human-readable identifier>",
    "tenant_id": "<tenant identifier or 'platform'>",
    "ip_address": "<IPv4 or IPv6; null for internal M2M>",
    "user_agent": "<HTTP User-Agent if applicable>"
  },
  "resource": {
    "type": "<string — see Resource Type Registry below>",
    "identifier": "<fully-qualified resource name>",
    "location": "<namespace / cluster / region>"
  },
  "action": {
    "type": "<READ | WRITE | DELETE | CREATE | UPDATE | AUTH | ADMIN>",
    "detail": "<source-specific action detail object>"
  },
  "risk": {
    "level": "<LOW | MEDIUM | HIGH | CRITICAL>",
    "flags": ["<tag strings: CROSS_TENANT_ACCESS | PII_ACCESS | PRIVILEGE_ESCALATION | FIRST_TIME_ACCESS | etc.>"]
  },
  "previous_hash": "<sha256 of previous event in source sequence>",
  "this_hash": "<sha256 of this event document excluding this field>"
}
```

### 1.2 Event Type Registry

| Event Type | Source | Description |
|---|---|---|
| `auth.login.success` | Keycloak | User successfully authenticated |
| `auth.login.failure` | Keycloak | Authentication failure (wrong password, expired token) |
| `auth.logout` | Keycloak | User session terminated |
| `auth.token.issued` | Keycloak | Access token or refresh token issued |
| `auth.token.refresh` | Keycloak | Access token refreshed |
| `auth.mfa.challenge` | Keycloak | MFA challenge presented |
| `auth.mfa.success` | Keycloak | MFA challenge passed |
| `auth.mfa.failure` | Keycloak | MFA challenge failed |
| `auth.account.locked` | Keycloak | Account locked after brute-force detection |
| `data.query.executed` | Trino | SQL query completed (success or failure) |
| `data.query.rejected` | Ranger (via Trino) | Query rejected by Ranger authorization |
| `data.access.allowed` | Ranger | Ranger authorized a data access request |
| `data.access.denied` | Ranger | Ranger denied a data access request |
| `data.column.masked` | Ranger | Column masking applied to query result |
| `data.row.filtered` | Ranger | Row-level filter applied to query result |
| `secret.read` | OpenBao | Secret value read from OpenBao |
| `secret.write` | OpenBao | Secret value written to OpenBao |
| `secret.delete` | OpenBao | Secret deleted from OpenBao |
| `secret.lease.created` | OpenBao | Dynamic secret lease created |
| `secret.lease.renewed` | OpenBao | Dynamic secret lease renewed |
| `secret.lease.revoked` | OpenBao | Dynamic secret lease revoked |
| `pki.cert.issued` | OpenBao PKI | TLS certificate issued |
| `pki.cert.revoked` | OpenBao PKI | TLS certificate revoked |
| `pipeline.dag.started` | Airflow | DAG run started |
| `pipeline.dag.completed` | Airflow | DAG run completed (success or failure) |
| `pipeline.task.executed` | Airflow | Individual task executed |
| `pipeline.task.failed` | Airflow | Task failed |
| `db.query.ddl` | pgAudit | DDL statement executed on PostgreSQL |
| `db.query.grant` | pgAudit | GRANT or REVOKE executed |
| `db.connection.failed` | PostgreSQL | Failed connection attempt |
| `storage.object.put` | MinIO | Object written to MinIO |
| `storage.object.get` | MinIO (audit buckets only) | Object read from MinIO audit-sensitive bucket |
| `storage.object.delete.attempt` | MinIO | Object delete attempted (may fail on WORM) |
| `storage.worm.violation` | MinIO | Attempted delete/overwrite of WORM-locked object |
| `catalog.table.created` | Polaris/Nessie | Iceberg table created |
| `catalog.table.dropped` | Polaris/Nessie | Iceberg table dropped |
| `catalog.schema.created` | Polaris/Nessie | Schema/namespace created |
| `catalog.policy.changed` | Ranger | Ranger policy created/updated/deleted |
| `identity.user.created` | Keycloak | User account created |
| `identity.user.disabled` | Keycloak | User account disabled |
| `identity.group.modified` | Keycloak | Group membership changed |
| `identity.role.assigned` | Keycloak | Role assigned to user |
| `compliance.erasure.initiated` | Airflow | GDPR erasure request processing started |
| `compliance.erasure.completed` | Airflow | GDPR erasure completed |
| `compliance.redaction.applied` | audit-redact-service | Audit log PII redacted |

### 1.3 Resource Type Registry

| Resource Type | Example Identifier |
|---|---|
| `iceberg.table` | `polaris:tenant_a.marts.customers` |
| `iceberg.schema` | `polaris:tenant_a.marts` |
| `iceberg.warehouse` | `polaris:tenant_a` |
| `s3.object` | `s3://lakehouse-data/tenant-a/marts/customers/part-0001.parquet` |
| `s3.bucket` | `s3://audit-log` |
| `k8s.secret` | `compute-ns/trino-server-tls` |
| `k8s.pod` | `compute-ns/trino-worker-7d9c4f-xxx` |
| `openbao.secret` | `secret/db/postgres/trino` |
| `openbao.pki.cert` | `pki/issue/trino-server` |
| `keycloak.user` | `lakehouse:alice` |
| `keycloak.session` | `session:abc123def456` |
| `airflow.dag` | `ingestion/ingest_documents` |
| `ranger.policy` | `ranger:trino:tenant_a_marts_select` |

### 1.4 Source-Specific Detail Objects

#### Trino Query Event (`action.detail`)
```json
{
  "query_id": "20260312_143022_00001_xyz",
  "query_type": "SELECT",
  "sql_text_hash": "<sha256 of SQL text — full text stored separately>",
  "sql_text": "<full SQL text — may be redacted on GDPR request>",
  "catalog": "trino",
  "schema": "tenant_a.marts",
  "tables_accessed": ["tenant_a.marts.customers", "tenant_a.marts.orders"],
  "rows_scanned": 1000000,
  "rows_returned": 100,
  "bytes_processed": 52428800,
  "duration_ms": 432,
  "cluster": "trino-cluster-a",
  "worker_nodes": 4,
  "ranger_decisions": [
    { "resource": "tenant_a.marts.customers", "action": "SELECT", "decision": "ALLOW", "row_filter": "tenant_id='tenant_a'", "masked_columns": ["ssn"] }
  ]
}
```

#### OpenBao Secret Event (`action.detail`)
```json
{
  "path": "secret/db/postgres/trino",
  "operation": "read",
  "vault_request_id": "<request UUID>",
  "remote_address": "<pod IP>",
  "auth_method": "approle",
  "auth_role": "trino-coordinator",
  "lease_created": false,
  "lease_ttl": null
}
```

#### Ranger Authorization Event (`action.detail`)
```json
{
  "request_id": "<ranger request UUID>",
  "policy_name": "tenant_a_marts_select",
  "service_name": "trino",
  "resource": { "catalog": "trino", "database": "tenant_a.marts", "table": "customers", "column": "*" },
  "access_type": "select",
  "result": "ALLOWED",
  "row_filter_expression": "tenant_id = 'tenant_a'",
  "masking_info": [{ "column": "ssn", "mask_type": "MASK_NONE_EXCEPT_LAST_4" }],
  "policy_version": "2"
}
```

---

## 2. Storage Architecture

### 2.1 Hot Tier — Grafana Loki (90 days)

| Property | Value |
|---|---|
| Retention | 90 days |
| Query interface | LogQL via Grafana Explore |
| Compression | LZ4 (chunk compression) |
| Index | BoltDB-Shipper (or tsdb) |
| Storage backend | MinIO bucket: `loki-chunks/` |
| Access control | `audit-reader` Keycloak role + Ranger (read-only) |
| SLA | Tier 3 — 99.5% availability |

**Ingestion path:**
```
OTEL Collector
    │ (loki exporter, gRPC)
    ▼
Loki Distributor
    │ (write quorum: 2 of 3 ingesters)
    ▼
Loki Ingester (3 replicas)
    │ (flush to object storage after 15 min or 1MB chunk)
    ▼
MinIO: loki-chunks/
```

### 2.2 Cold Tier — MinIO Object Lock WORM (7 years)

| Property | Value |
|---|---|
| Bucket | `audit-log/` |
| Object Lock | ENABLED — COMPLIANCE mode |
| Retention period | 7 years (default object retention) |
| Versioning | ENABLED |
| Compression | GZIP (per-file) |
| Format | NDJSON (newline-delimited JSON) — one file per hour per source |
| Naming convention | `audit/<source>/<YYYY>/<MM>/<DD>/<HH>/<source>-<YYYYMMDDHHMMSS>-<hash>.json.gz` |
| Storage efficiency | ~100–200 MB/day (10k events/day, compressed) |
| Access control | `compliance-reader` service account only; no human direct access |

**Write path:**
```
OTEL Collector
    │ (S3 exporter — PutObject only)
    ▼
MinIO: audit-log/
    │ (Object Lock COMPLIANCE applied automatically on write)
    ▼
Object is immutable for 7 years — DELETE or overwrite returns 403 AccessDenied
```

### 2.3 Queryable Audit — Iceberg Audit Table

For Trino query events specifically, a queryable Iceberg table is maintained:

```
Polaris catalog: lakehouse.audit.trino_queries
MinIO bucket: audit-iceberg/ (Object Lock COMPLIANCE)

Schema:
  event_id           VARCHAR    NOT NULL
  timestamp          TIMESTAMP  NOT NULL
  user_sub           VARCHAR    NOT NULL  (Keycloak UUID)
  username           VARCHAR    NOT NULL
  tenant_id          VARCHAR    NOT NULL
  query_id           VARCHAR    NOT NULL
  sql_text_hash      VARCHAR    NOT NULL  (sha256)
  sql_text           VARCHAR              (may be REDACTED on GDPR request)
  tables_accessed    ARRAY(VARCHAR)
  rows_scanned       BIGINT
  rows_returned      BIGINT
  duration_ms        BIGINT
  ranger_decision    VARCHAR
  cluster            VARCHAR
  source_ip          VARCHAR

Partitioning: YEAR(timestamp), MONTH(timestamp)
Sort order: timestamp ASC
Write mode: APPEND ONLY (table property)
Retention: NEVER expire snapshots (audit table)
```

---

## 3. Hash Chain Mechanism

Each event written to the cold-tier WORM storage includes a cryptographic hash chain:

```
Event N-1:
{
  ...event fields...,
  "previous_hash": "<sha256 of Event N-2>",
  "this_hash":     "<sha256 of this document excluding this_hash field>"
}

Event N:
{
  ...event fields...,
  "previous_hash": "<sha256 of Event N-1>" == this_hash field of Event N-1,
  "this_hash":     "<sha256 of this document excluding this_hash field>"
}
```

**Chain integrity verification:**

```python
# verify-audit-chain.py (pipelines/scripts/verify-audit-chain.py)
import hashlib, json, boto3
from datetime import datetime, timedelta

def verify_chain(source: str, start: datetime, end: datetime) -> bool:
    s3 = boto3.client('s3', ...)
    events = fetch_events_ordered(s3, 'audit-log', source, start, end)
    prev_hash = None
    for event in events:
        expected_prev = prev_hash
        claimed_prev = event.get('previous_hash')
        if expected_prev is not None and claimed_prev != expected_prev:
            raise IntegrityError(f"Hash chain broken at event {event['event_id']}")
        # Verify this_hash
        doc = {k: v for k, v in event.items() if k != 'this_hash'}
        computed = hashlib.sha256(json.dumps(doc, sort_keys=True).encode()).hexdigest()
        if computed != event.get('this_hash'):
            raise IntegrityError(f"Event {event['event_id']} is corrupted")
        prev_hash = event['this_hash']
    return True
```

The chain verifier runs as a weekly Airflow DAG (`maintenance/verify_audit_chain.py`). Failures trigger a P1 alert.

---

## 4. Access Control Model

### 4.1 Write Access (Production)

| Actor | Permission | Mechanism |
|---|---|---|
| `otel-collector` service account | PutObject on `audit-log/` | MinIO service account with PutObject-only policy |
| `trino-audit-writer` service account | INSERT on `lakehouse.audit.trino_queries` | Ranger policy: INSERT only; no DELETE/UPDATE |
| All other accounts | None (explicit deny) | MinIO bucket policy + Ranger default-deny |

**Critically:** The `otel-collector` service account has **no** `DeleteObject`, `GetObject`, or `ListBucket` permissions on `audit-log/`. It is write-only. No service account has write access after the initial write (WORM enforces this at the object level).

### 4.2 Read Access

| Actor | Permission | Mechanism |
|---|---|---|
| `compliance-reader` service account | GetObject on `audit-log/` | MinIO service account (stored in OpenBao) |
| `compliance-officers` Keycloak group | SELECT on `lakehouse.audit.*` | Ranger policy: SELECT only |
| `platform-admins` Keycloak group | SELECT on `lakehouse.audit.*` | Ranger policy: SELECT only |
| `audit-reader` Keycloak role | Query Loki via Grafana | Grafana datasource permission |
| All other users/groups | No access | Ranger default-deny |

### 4.3 Redaction Access (Exceptional — GDPR Article 17)

Redaction is a controlled exception to immutability:

| Actor | Permission | Mechanism | Approval Required |
|---|---|---|---|
| `audit-redact-service` K8s Job | PutObject (new version) + DeleteMarker on original | Separate MinIO service account; single-use per request | security-admin MFA approval via Airflow manual gate |

**Redaction does not delete.** It creates a new WORM object with `[REDACTED]` replacing PII, and adds a `DeleteMarker` on the original version. The original object remains in MinIO versioned state, accessible only to `compliance-reader` for legal review. This satisfies GDPR Article 17(3)(b) while maintaining audit chain integrity.

---

## 5. Retention and Lifecycle

| Tier | Retention Period | Mechanism | Legal Override |
|---|---|---|---|
| Loki hot | 90 days | Loki retention config | Extended on legal hold |
| MinIO WORM cold | 7 years | Object Lock COMPLIANCE | Cannot be shortened (even by root); extended via legal hold API |
| Iceberg audit table | Permanent (never expire) | Table property; no snapshot expiry DAG runs on audit table | — |
| Weekly verification | Indefinite | Airflow DAG logs in Airflow DB | — |

### Legal Hold

For regulatory investigations or litigation, specific audit files can be placed under **legal hold** (S3 Object Lock `legal-hold: ON`), which prevents deletion even after the retention period expires:

```bash
# Extend hold on a specific audit file
aws s3api put-object-legal-hold \
  --bucket audit-log \
  --key audit/trino/2026/03/12/14/trino-20260312140000-abc123.json.gz \
  --legal-hold Status=ON
```

Legal hold can only be set/removed by the `legal-hold-admin` IAM role, requiring MFA and a change management ticket.

---

## 6. Compliance Query Templates

### 6.1 SOC2 — All Queries by a User in Last 90 Days

```sql
SELECT
  timestamp,
  username,
  tenant_id,
  query_id,
  tables_accessed,
  rows_scanned,
  ranger_decision,
  duration_ms
FROM lakehouse.audit.trino_queries
WHERE user_sub = '<keycloak-uuid>'
  AND timestamp >= NOW() - INTERVAL '90' DAY
ORDER BY timestamp DESC;
```

### 6.2 GDPR Article 30 — All Accesses to PII Table in Last 30 Days

```sql
SELECT
  timestamp,
  username,
  tenant_id,
  tables_accessed,
  ranger_decision,
  sql_text_hash
FROM lakehouse.audit.trino_queries
WHERE contains(tables_accessed, 'tenant_a.marts.customers')
  AND timestamp >= NOW() - INTERVAL '30' DAY
ORDER BY timestamp DESC;
```

### 6.3 Security — Failed Authentication Events from LogQL (Loki)

```logql
{source_system="keycloak"} |= "auth.login.failure"
| json
| line_format "{{.timestamp}} {{.actor.username}} {{.actor.ip_address}} {{.action.detail.failure_reason}}"
```

### 6.4 SOC2 CC6.2 — All Privileged Access Events (Last Quarter)

```sql
-- OpenBao admin-level operations (from WORM via Iceberg partition if configured)
-- Or query via Loki LogQL:
{source_system="openbao"} |= "auth/token/create-orphan" OR "sys/seal" OR "sys/unseal"
| json
| line_format "{{.timestamp}} {{.actor.username}} {{.event_type}}"
```

### 6.5 GDPR Erasure Certificate Query

```sql
SELECT
  timestamp,
  actor.username,
  action.detail.subject_id,
  action.detail.tables_affected,
  action.detail.erasure_certificate_id
FROM lakehouse.audit.compliance_events
WHERE event_type = 'compliance.erasure.completed'
  AND action.detail.subject_id = '<gdpr-subject-uuid>'
ORDER BY timestamp DESC;
```

---

## 7. Alerting Rules for Audit System Health

| Alert | Condition | Severity | Response |
|---|---|---|---|
| Audit ingest stopped | `rate(audit_events_written_total[5m]) == 0` for any source > 10 min | CRITICAL | Page SRE; check OTEL collector |
| WORM violation attempt | Any `storage.worm.violation` event | CRITICAL | Page Security Lead immediately |
| Hash chain broken | Weekly audit-chain verifier fails | CRITICAL | Page Security Lead; initiate forensics |
| Audit Loki error rate | `rate(loki_write_failures_total[5m]) > 0.01` | WARNING | Check Loki + MinIO connectivity |
| Audit table growth anomaly | `audit_table_rows_24h > 5× rolling_avg` | WARNING | Investigate event storm or attack |
| Compliance reader login | Any `auth.login.success` for `compliance-reader` | INFO | Log; verify expected audit activity |
