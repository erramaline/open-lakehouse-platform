# ADR-009: Audit Trail Design — Immutability Guarantees and Storage Backend

| Field | Value |
|---|---|
| **Status** | Accepted |
| **Date** | 2026-03-12 |
| **Deciders** | Principal Data Platform Architect, Security Lead, Compliance Officer, Legal |
| **Tags** | audit, compliance, gdpr, soc2, immutability, security |

---

## Context

The platform must maintain an immutable, tamper-evident audit trail to satisfy:

- **SOC2 Type II:** CC6.1 (access controls), CC6.2 (identity verification), CC7.2 (system monitoring), CC9.2 (vendor/partner management)
- **GDPR Article 30:** Records of processing activities; data access logs.
- **GDPR Article 17:** Right to erasure — audit trail must log erasure requests and their completion, while itself being exempt from erasure (legal obligation).
- **HIPAA 45 CFR §164.312(b):** Audit controls — hardware, software, and procedural mechanisms to record and examine activity.
- **Internal security policy:** Every secret access, every data query, every authorization decision must be logged.

The audit trail must satisfy:
1. **Immutability:** Written records cannot be modified or deleted by any service account or operator.
2. **Tamper-evidence:** Any modification attempt is detectable.
3. **Completeness:** No audit event must be droppable (at-least-once delivery).
4. **Queryability:** Compliance auditors must be able to query audit logs by user, resource, time range, and action type.
5. **Retention:** 7 years minimum (financial/legal), aligned per jurisdiction.
6. **Separation of concerns:** The audit system must be independent of the services it audits — a compromised service cannot delete its own audit trail.

---

## Decision

**We implement a multi-layer audit trail with the following architecture:**

1. **Control plane audits** (OpenBao, Keycloak, K8s API server) → OTEL Collector → Loki (hot) + MinIO immutable bucket (cold/permanent)
2. **Data plane audits** (Trino query logs, Ranger authorization decisions) → Dedicated append-only Iceberg table in Polaris (`lakehouse.audit.*`) + MinIO immutable bucket
3. **Metadata audits** (OpenMetadata entity changes) → OpenMetadata's built-in change event log → MinIO immutable bucket

---

## Audit Event Sources and Coverage

| Source | Events Captured | Collection Method |
|---|---|---|
| OpenBao | Every secret read/write/delete, auth token issuance, AppRole login, PKI cert issuance | OpenBao audit log → file sink → Promtail → Loki |
| Keycloak | Login, logout, failed login, session creation/destroy, realm config changes | Keycloak event listener → OTEL exporter → Loki |
| Trino | Every query (SQL text, user, groups, resource, rows scanned, duration, error) | Trino query event listener → Iceberg audit table + Loki |
| Ranger | Every access control decision (allow/deny), policy CRUD, user sync events | Ranger audit provider → Solr/HDFS replaced by: → MinIO (audit JSON) + Loki |
| K8s API Server | All API calls (kubectl, operators, controller-manager) | K8s audit log → Loki |
| Airflow | DAG run start/stop, task execution, manual trigger, config changes | Airflow audit log + Statsd → OTEL → Loki |
| PostgreSQL | DDL events, privilege grants/revokes, failed connections | pgAudit extension → Promtail → Loki |
| MinIO | S3 API calls (all object reads/writes) on audit-sensitive buckets | MinIO audit log → OTEL → Loki |
| OpenMetadata | Entity create/update/delete, access events, lineage changes | OpenMetadata Change Event API → MinIO |
| cert-manager | Certificate issuance, renewal, revocation | K8s events → Loki |

---

## Immutability Mechanism

### MinIO — Object Lock (WORM)

The `audit-log/` MinIO bucket is configured with **S3 Object Lock in Compliance mode**:

```
Bucket name:    audit-log
Object Lock:    ENABLED
Locking mode:   COMPLIANCE (cannot be overridden even by root user)
Retention:      7 years (default object retention period)
Versioning:     ENABLED
Lifecycle:      EXPIRE on day 2558 (7 years) — automatic deletion after legal retention
```

**Why Compliance mode (not Governance mode)?**
- Governance mode allows users with `s3:BypassGovernanceRetention` permission to delete or overwrite objects.
- Compliance mode makes it impossible for ANY user (including the MinIO root account) to delete or overwrite a locked object before its retention period expires.
- This satisfies the requirement that even a fully compromised operator account cannot tamper with audit logs.

**Append-only write pattern:**
- Audit events are written as individual JSON objects or Parquet row groups to the `audit-log/` bucket.
- Object names include a cryptographic hash of the content: `audit/<year>/<month>/<day>/<source>/<uuid>-<sha256>.json`
- Any modification would produce a different hash, making tampering detectable.

### Iceberg Audit Tables — Append-Only Policy

For the Trino query audit table (`lakehouse.audit.trino_queries`):
- Polaris table property: `'write.append-only' = 'true'`
- Ranger policy: users `trino-audit-writer` (service account): INSERT only; no UPDATE, DELETE, DROP.
- Snapshot expiry: NEVER (all snapshots retained for full history).
- MinIO bucket for this table: `audit-iceberg/` — also Object Lock Compliance mode.

### Hash Chain for Tamper Evidence

Each audit log file includes a rolling hash:
```json
{
  "event_id": "uuid-v4",
  "timestamp": "2026-03-12T14:30:00.000Z",
  "source": "trino",
  "event": { ... },
  "previous_hash": "sha256(<previous event file content>)",
  "this_hash": "sha256(<this event file content excluding this_hash field>)"
}
```

The hash chain allows detection of any insertion, deletion, or modification of events in the sequence. Auditors verify chain integrity using the `pipelines/scripts/verify-audit-chain.py` utility.

---

## Storage Backend Architecture

```
Audit Events (all sources)
         │
         ▼
OpenTelemetry Collector (audit pipeline)
    ├─ Processor: enrich with: timestamp, hostname, namespace, pod_name
    ├─ Processor: compute per-event hash
    └─ Exporter:
         ├─▶ Loki (hot tier — 90-day queryable index)
         └─▶ MinIO audit-log/ (WORM Compliance — 7-year cold tier)
                    │
                    ▼
              Iceberg table: lakehouse.audit.raw_events
              (queryable via Trino for compliance reporting)
```

**Why Loki AND MinIO?**
- Loki enables fast LogQL queries during investigations (last 90 days).
- MinIO WORM provides the immutable long-term record that satisfies legal requirements.
- Neither alone is sufficient: Loki is not WORM; MinIO alone is not efficiently queryable.

---

## Query Interface for Auditors

Compliance auditors access audit data via:

1. **Grafana Explore (Loki):** Ad-hoc LogQL queries for recent events (last 90 days). Restricted to `audit-reader` Keycloak role; read-only.
2. **Trino SQL:** Query the Iceberg audit table for sophisticated analytics: "Show all SELECT queries against the `customers` table by user `alice` in the last 30 days."
3. **OpenMetadata Audit UI:** Entity-level change history.

**Access control for audit data:**
- Ranger policy: Only `platform-admins` and `compliance-officers` groups may read `lakehouse.audit.*` tables.
- MinIO bucket policy: `audit-log/` readable by `compliance-readers` service account only.
- No data engineer or analyst has access to raw audit logs.

---

## Retention Policy

| Data Type | Hot Tier (Loki) | Cold Tier (MinIO WORM) | Legal Hold |
|---|---|---|---|
| Access control decisions | 90 days | 7 years | Extended on legal request |
| Authentication events | 90 days | 7 years | Extended on legal request |
| Query text (SQL) | 30 days | 3 years | Extended on legal request |
| Secret access logs | 90 days | 7 years | Permanent |
| GDPR erasure requests | 90 days | 10 years (pending erasure) | Permanent |
| Certificate issuance | 30 days | 5 years | — |

**Note on GDPR erasure and audit logs:** GDPR Article 17 does not require erasure of audit logs maintained for legal compliance obligations (Article 17(3)(b)). We retain the fact of an erasure request (subject ID, request date, completion date) but redact PII from the completed audit record. The Ranger policy prevents modification of audit logs; only a dedicated `audit-redact` service account (with MFA-gated human approval) may execute redaction within the audit system.

---

## Consequences

### Positive
- **Legally defensible:** MinIO Object Lock Compliance mode provides court-admissible proof that logs have not been tampered with.
- **Zero-gap coverage:** OTEL Collector as central aggregator ensures no source is missed; lost-event alerting triggers if any source stops emitting.
- **Queryable:** Dual-tier (Loki hot, Iceberg cold) enables both ad-hoc investigation and batch compliance reporting.
- **Independent of audited services:** MinIO audit bucket is in a separate namespace with separate credentials unknown to audited services.

### Negative
- **Storage cost:** 7 years of uncompressed JSON audit logs may reach hundreds of GiB to TiB. Mitigated by Parquet compression for Iceberg tables (5–10× compression ratio) and Loki's chunk compression.
- **GDPR redaction complexity:** Implementing a legally-compliant redaction workflow that preserves WORM guarantees while satisfying Article 17 requires careful design (see `docs/compliance/audit-trail-specification.md`).
- **Hash chain management:** Maintaining and verifying the hash chain requires a dedicated audit service that runs before other services. Failure in the hash chain writer blocks audit log ingestion (fail-closed behavior accepted).

---

## Alternatives Considered

### Elasticsearch / OpenSearch as sole audit store
- **Rejected:** Elasticsearch indices are mutable by design. Without additional WORM wrapper, records can be deleted by cluster administrators. Does not satisfy immutability requirement.

### Cloud-native audit services (AWS CloudTrail, GCP Cloud Audit Logs)
- **Rejected:** Cloud provider lock-in. Not self-hostable. Violates multi-cloud portability requirement.

### Kafka + Kafka Streams for audit pipeline
- **Rejected:** Kafka adds significant operational overhead (ZooKeeper or KRaft cluster). OTEL Collector with Loki/MinIO exporters provides equivalent durability with lower complexity. Kafka may be introduced later for streaming pipelines (Wave 4) but is not needed for batch audit.

---

## References
- [MinIO Object Lock documentation](https://min.io/docs/minio/linux/administration/object-management/object-lock.html)
- [OpenBao audit devices](https://openbao.org/docs/audit/)
- [GDPR Article 17 — Right to erasure](https://gdpr-info.eu/art-17-gdpr/)
- [GDPR Article 30 — Records of processing activities](https://gdpr-info.eu/art-30-gdpr/)
- [SOC2 Trust Service Criteria](https://www.aicpa.org/resources/article/trust-services-criteria)
- `docs/compliance/audit-trail-specification.md` — detailed schema and tooling
- `docs/compliance/soc2-control-mapping.md` — control mapping table
- ADR-002 — OpenBao (audit log source for secret operations)
