# GDPR Data Map — Open Lakehouse Platform

> **Version:** 1.0 | **Date:** 2026-03-12 | **Classification:** CONFIDENTIAL  
> **Data Protection Officer:** [DPO name — to be populated]  
> **Review Cycle:** Annual (or within 30 days of any significant processing change)

---

## Purpose

This document fulfils the obligation under **GDPR Article 30** (Records of Processing Activities) for the Open Lakehouse Platform. It maps every category of personal data processed by the platform, identifying the data controller, processor, purpose, legal basis, retention period, and erasure mechanism.

This document must be maintained by the Data Engineering team and reviewed by the DPO before any new data domain is brought into the platform.

---

## Controller and Processor Identification

| Role | Entity | Contact |
|---|---|---|
| **Data Controller** | [Your organisation name] | [DPO email] |
| **Data Processor — Platform** | Open Lakehouse Platform (self-hosted infrastructure) | Platform architect |
| **Sub-processors** | None (all infrastructure self-hosted; no SaaS data processing) | — |

**No personal data is transmitted to any external SaaS service.** All processing occurs on self-hosted infrastructure. This is enforced by:
- Network egress policies blocking outbound connections except to whitelisted internal endpoints.
- Docling operating fully offline (no external API calls — see ADR-003).
- Great Expectations operating offline (no GX Cloud — see ADR-004).

---

## Data Category Register

### Category 1: Platform User Data (Keycloak)

| Field | Value |
|---|---|
| **Data subjects** | Platform users (employees, contractors, analysts) |
| **Personal data** | Username, email address, first/last name, group membership, MFA device identifiers |
| **Purpose** | Authentication, authorization, session management, audit trail attribution |
| **Legal basis** | Legitimate interest (Article 6(1)(f)) — necessary to operate secure internal platform |
| **Storage location** | PostgreSQL 16 (`identity-ns` → `db-ns`); Keycloak Infinispan cache |
| **Retention** | Active: duration of employment + 90 days. Terminated: anonymized after 90 days |
| **Third-party sharing** | None |
| **Special category data** | None |
| **Cross-border transfer** | None (if cluster in EEA); document if multi-region prod added |
| **Erasure mechanism** | Keycloak admin: disable + anonymize user account; K8s Job: `anonymize-user.py` |
| **Erasure timeline** | Within 30 days of request (automated pipeline) |

### Category 2: Business Data (Iceberg Tables — Tenant Domains)

| Field | Value |
|---|---|
| **Data subjects** | Customers, employees, partners (depends on tenant domain) |
| **Personal data** | Tenant-specific; documented per domain in Annex A |
| **Purpose** | Analytics, reporting, operational data processing |
| **Legal basis** | Contract (Article 6(1)(b)) or Legitimate Interest (Article 6(1)(f)) — specified per domain |
| **Storage location** | MinIO (`lakehouse-data/<tenant>/`) + Polaris Iceberg catalog |
| **Retention** | Defined per Iceberg table property `gdpr.retention.days`; enforced by Airflow maintenance DAG |
| **Erasure mechanism** | Iceberg row-level delete (V2 delete files) + compaction to remove physical data |
| **Erasure timeline** | Within 30 days of verified erasure request (Article 17) |
| **PII flagging** | OpenMetadata PII tags on all personal data columns; synced to Ranger for masking |

### Category 3: Audit Log Data

| Field | Value |
|---|---|
| **Data subjects** | Platform users (employees) |
| **Personal data** | `sub` (Keycloak UUID), `preferred_username`, IP address (in auth events), SQL query text (may contain PII) |
| **Purpose** | Legal compliance, security incident investigation, SOC2 audit evidence |
| **Legal basis** | Legal obligation (Article 6(1)(c)) — SOC2, HIPAA, internal security policy |
| **Storage location** | MinIO `audit-log/` (WORM Compliance); Loki (hot tier) |
| **Retention** | 7 years (WORM Compliance mode; cannot be shortened without legal approval) |
| **Erasure exemption** | Article 17(3)(b): GDPR erasure right does not apply to data retained for legal compliance obligations. Audit logs are exempt. Query text containing PII is redacted (not deleted) on verified erasure request |
| **Redaction mechanism** | `audit-redact-service` K8s Job (requires MFA + security-admin approval) replaces PII in query text with `[REDACTED]`; immutability preserved via new WORM object (original marked as superseded) |

### Category 4: Document Ingestion Data (Docling Processing)

| Field | Value |
|---|---|
| **Data subjects** | Individuals mentioned in processed documents (variable) |
| **Personal data** | Document content may include names, addresses, financial data, health data (HIPAA-sensitive if medical documents ingested) |
| **Purpose** | Document digitisation, structured data extraction for analytics |
| **Legal basis** | Contract or Legitimate Interest — specified per ingestion source |
| **Storage location** | MinIO (`raw/<tenant>/`, `staging/<tenant>/`) + Polaris Iceberg tables |
| **Special category handling** | If medical data (HIPAA): encrypted at rest (MinIO SSE-KMS with OpenBao key); access restricted to `hipaa-authorized` Ranger group |
| **Retention** | Raw: 7 years (archive compliance). Extracted: per tenant domain retention |
| **Erasure mechanism** | 1. Delete raw document from MinIO (within 30 days). 2. Iceberg row-level delete on extracted records. 3. Table compaction to remove physical data. 4. Iceberg snapshot expiry to remove history. |
| **PII identification** | Great Expectations custom expectation: scan for email, phone, SSN patterns; quarantine if unexpected PII found |

---

## Data Flow Map (GDPR Article 30(1)(d))

```
[Data Subject's Document / Data]
        │
        ▼ (Upload / SFTP / API)
[Ingress Controller — TLS only; no data logged]
        │
        ▼
[MinIO — raw/ bucket — EEA-resident storage]
        │
        ▼ (Airflow DAG)
[Docling Worker — document parsing — offline, no external transfer]
        │
        ▼
[MinIO — staging/ bucket — structured Parquet]
        │
        ▼ (Airflow DAG — GX quality gate)
[Trino query engine — data remains in EEA]
        │
        ▼ (dbt transformation)
[MinIO — marts/ bucket — analytics tables]
        │
        ▼
[Trino Gateway — query results — only to authorized users]
        │
        ▼ (Ranger row filter + column mask applied)
[Authorized Platform User — EEA jurisdiction]
```

No personal data exits the platform boundary. No data is sent to:
- External APIs (Docling is offline).
- ML/AI SaaS platforms.
- Analytics SaaS tools (BI tools connect TO the platform, not the reverse).
- Backup services outside the defined data residency region.

---

## Subject Rights Response Procedures

### Right of Access (Article 15)

1. DPO receives verified access request.
2. Compliance officer queries: `SELECT * FROM lakehouse.audit.trino_queries WHERE user_sub = '<subject_uuid>'` (shows all queries by platform users).
3. For business data: query Iceberg tables per data map in Annex A using subject identifier.
4. Response compiled within 30 days; delivered via secure channel.

### Right to Erasure (Article 17)

**Trigger:** Verified erasure request for a data subject.

**Automated Erasure Pipeline (Airflow DAG: `gdpr/erasure_request.py`):**

```
Step 1: Validate identity and legal basis for erasure
    │ (DPO approval required — manual gate in Airflow UI)
    ▼
Step 2: Suspend access (Keycloak account disabled immediately)
    ▼
Step 3: Iceberg row-level delete on all mapped tables (Annex A)
    │ - INSERT into Iceberg delete file: WHERE subject_id = '<uuid>'
    │ - Verify: SELECT COUNT(*) = 0 after delete
    ▼
Step 4: Delete raw documents from MinIO (if applicable)
    │ - MinIO: DELETE s3://lakehouse-data/raw/<tenant>/.../subject_<uuid>/
    ▼
Step 5: Compact Iceberg tables (remove physical data)
    │ - ALTER TABLE ... EXECUTE optimize (rewrites without deleted rows)
    │ - ALTER TABLE ... EXECUTE expire_snapshots (removes snapshot history)
    ▼
Step 6: Redact audit log query text containing subject's PII
    │ - Run audit-redact-service (MFA-gated)
    ▼
Step 7: Anonymize Keycloak account
    │ - Replace email/name with UUID; retain account for audit correlation
    ▼
Step 8: Generate erasure certificate
    │ - Signed JSON document: subject_id, erasure_timestamp, tables_affected, operator
    │ - Stored in MinIO audit-log/ (WORM — permanent record of erasure)
    └─▶ Delivered to DPO; communicated to data subject within 30 days
```

**Exemptions to erasure (documented per request):**
- Audit logs containing the subject's actions (legal obligation exemption — Article 17(3)(b)).
- Financial transaction records (Article 17(3)(b) — legal obligation; typically 7-10 years).

### Right to Rectification (Article 16)

1. Verified rectification request.
2. Airflow DAG: `gdpr/rectification_request.py` — UPDATE Iceberg records via Trino (merge-on-read V2 updates).
3. New Iceberg snapshot created; old snapshot retained for audit.
4. Confirmation to subject within 30 days.

### Right to Portability (Article 20)

1. Data export in machine-readable format (Parquet or CSV).
2. Airflow DAG: `gdpr/data_export.py` — SELECT and write to temporary export bucket.
3. Secure download link provided to subject (time-limited pre-signed URL, 24h TTL).
4. Export deleted from platform after 7 days.

---

## Annex A: Personal Data Inventory (Per Domain)

> **Note:** This annex must be completed and maintained for each data domain ingested into the platform. Template below.

| Domain | Table | Column | Data Type | PII Level | Retention | Erasure Column | Notes |
|---|---|---|---|---|---|---|---|
| Example: CRM | `tenant_a.marts.customers` | `email` | VARCHAR | PII_HIGH | 5 years after last activity | `customer_id` | Masked for analysts per Ranger policy |
| Example: CRM | `tenant_a.marts.customers` | `full_name` | VARCHAR | PII_HIGH | 5 years | `customer_id` | Masked for analysts |
| Example: CRM | `tenant_a.marts.customers` | `phone` | VARCHAR | PII_HIGH | 5 years | `customer_id` | Masked for analysts |
| Example: HR | `tenant_a.marts.employees` | `salary` | DECIMAL | SENSITIVE | Duration of employment + 10 years | `employee_id` | HIPAA-not-applicable; financial |
| _[Add rows per domain]_ | | | | | | | |

**OpenMetadata integration:** PII tags applied in OpenMetadata propagate automatically to Ranger column masking policies. Annex A is the source of truth; OpenMetadata reflects it.

---

## Data Residency Declaration

| Data Type | Primary Location | Backup Location | Cross-Border Transfer |
|---|---|---|---|
| All business data | EEA (K8s cluster region) | Same region (MinIO replication) | None |
| Audit logs | EEA | Same region (MinIO WORM) | None |
| User identity data | EEA (Keycloak cluster) | Same region (PostgreSQL backup) | None |

If a multi-region deployment is introduced in the future, this document must be updated before the deployment proceeds, and a Transfer Impact Assessment (TIA) must be conducted under GDPR Chapter V.
