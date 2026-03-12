# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Planned
- Trino Gateway dynamic routing with per-tenant cluster assignment
- OpenMetadata ML model lineage connector
- Flink-based real-time ingestion DAG
- Kubernetes operator for automated Iceberg table lifecycle management

---

## [0.1.0] - 2025-01-01

### Added

#### Infrastructure — Local Development Stack
- Docker Compose orchestration for 15 services with dependency ordering
  (`local/docker-compose.yml`, `local/docker-compose.security.yml`, `local/docker-compose.observability.yml`)
- Bootstrap script pipeline (`scripts/bootstrap/`):
  - `00-init-tls.sh` — local CA creation and certificate distribution
  - `01-init-openbao.sh` — OpenBao initialisation, unseal, AppRole setup
  - `02-init-keycloak.sh` — realm + client + user provisioning
  - `03-init-minio.sh` — bucket creation, IAM policies, lifecycle rules
  - `04-init-polaris.sh` — principal roles, namespaces (raw/staging/curated)
  - `05-init-ranger.sh` — policy import for Trino catalog
  - `06-init-openmetadata.sh` — service registration, ingestion connectors
  - `07-seed-data.sh` — TPC-H sf0.01 seed data into Iceberg raw layer

#### Storage Layer — Apache Iceberg on MinIO
- MinIO distributed mode (4-node erasure coding) as S3-compatible object store
- Dual catalog strategy: Apache Polaris 1.2.0 (production), Project Nessie (dev/CI)
- Iceberg table format version 2 with ZSTD compression and PARQUET data files
- Data lake zones: `raw/`, `staging/`, `curated/` (renamed: `marts/`)

#### Security — Six-Layer Model
- Apache Ranger 2.6.0 policies for RBAC, column masking, and row-level filtering
  (`security/ranger/policies/`: column_masking.json, row_filter.json, table_permissions.json, audit_policy.json)
- OpenBao (Apache 2.0 Vault fork) with Raft HA backend, AppRole + Kubernetes auth
  (`security/openbao/policies/`: airflow.hcl, trino.hcl, ranger.hcl, openmetadata.hcl)
  (`security/openbao/secret-rotation/`: rotate-db-password.sh, rotate-minio-keys.sh)
- Keycloak OIDC identity federation with realm export and configure script
  (`security/keycloak/realm-config/`, `security/keycloak/configure-keycloak.sh`)
- mTLS with cert-manager (cluster-internal PKI) + local CA for development
  (`security/tls/cert-manager/`, `security/tls/local-ca/`)
- Kubernetes NetworkPolicies with default-deny + explicit allow rules
  (`security/network-policies/k8s-network-policies.yaml`)

#### Compute — Trino 479
- Trino 479 MPP query engine with Iceberg and TPCH connectors
- Trino Gateway for load balancing and JWT-based authentication
- Per-tenant query isolation via Ranger user-group policies

#### Orchestration — Apache Airflow 2.10.x
- Five operational DAGs:
  - `airflow/dags/ingestion/docling_ingest_dag.py` — PDF/document extraction via Docling
  - `airflow/dags/ingestion/minio_to_iceberg_dag.py` — JSON→Iceberg batch ingestion
  - `airflow/dags/transformation/dbt_run_dag.py` — dbt staging→marts pipeline
  - `airflow/dags/quality/great_expectations_dag.py` — GE checkpoint runner (all 3 layers)
  - `airflow/dags/metadata/openmetadata_sync_dag.py` — daily OM metadata sync
  - `airflow/dags/maintenance/iceberg_expire_snapshots.py` — daily Iceberg housekeeping
- `airflow/plugins/openbao_secrets_backend.py` — Airflow secrets backend backed by OpenBao KV v2

#### Transformations — dbt-trino
- Full dbt project (`dbt/`) targeting Trino Iceberg catalog:
  - `models/staging/`: `stg_customers`, `stg_orders`, `stg_products` (views over raw sources)
  - `models/marts/core/`: `dim_customers` (surrogate key, SCD2-ready), `fct_orders` (incremental merge)
  - `models/marts/reporting/`: `rpt_revenue_by_region` (aggregation for BI)
  - `macros/generate_surrogate_key.sql` — portable MD5-based surrogate key
  - `macros/safe_divide.sql` — division-by-zero safe helper
  - `tests/assert_revenue_positive.sql` — singular test for revenue integrity
  - Full column-level tests in `_sources.yml`, `_staging_models.yml`, `_mart_models.yml`

#### Data Quality — Great Expectations
- Layer-specific expectation suites:
  - `data/quality/expectations/raw_layer.json`
  - `data/quality/expectations/staging_layer.json`
  - `data/quality/expectations/curated_layer.json`
- Checkpoint-based validation integrated with Airflow and OpenMetadata

#### Metadata & Data Governance — OpenMetadata 1.12.x
- Trino + MinIO service registration
- dbt lineage ingestion from manifest.json
- Table-level and column-level descriptions
- Data quality tab integration with GE results

#### Observability Stack
- Prometheus + Alertmanager with Trino, MinIO, Ranger, and Keycloak scrapers
- Grafana dashboards (Trino performance, MinIO throughput, Ranger audit)
- Grafana Loki + Promtail for centralised log aggregation
- OpenTelemetry Collector for distributed trace/metric routing
- Per-service alerting rules (`local/volumes/prometheus/`)

#### Kubernetes — Multi-Environment
- Kustomize base + overlays for staging and production (`kubernetes/`)
- Namespace, RBAC, ResourceQuotas, pod security standards
- Helm charts:
  - `helm/charts/lakehouse-core/` — core platform components
  - `helm/charts/observability/` — Prometheus, Grafana, Loki, OTEL

#### Infrastructure as Code — Terraform
- Modules: `kubernetes-cluster/`, `networking/`, `object-storage/`, `postgresql/`
- Environment configs: `terraform/environments/staging/`, `terraform/environments/production/`

#### CI/CD — GitHub Actions
- `e2e-tests.yml` — full E2E pipeline on PR and merge to main
- `security-scan.yml` — Trivy image scan + Checkov IaC static analysis
- `release.yml` — semantic versioning, changelog, and Helm chart publish

#### Test Suite (`tests/`)
- `tests/conftest.py` — session-scoped fixtures: Trino, MinIO, OpenBao, Ranger, Keycloak, OpenMetadata
- **Unit tests** (`tests/unit/`):
  - `test_ranger_policy_schema.py` — JSON schema validation for all Ranger policy files
  - `test_dbt_model_compilation.py` — dbt static analysis + compiled SQL checks
  - `test_great_expectations_suites.py` — GE suite JSON structure validation
  - `test_airflow_dag_integrity.py` — DAG import, cycle detection, metadata checks
  - `test_docling_extraction.py` — MinIO path logic and extraction schema validation
- **Integration tests** (`tests/integration/`):
  - `test_ranger_row_filter.py` — row-filter and column-mask policy verification
  - `test_iceberg_time_travel.py` — snapshot time travel and Nessie branching
  - `test_openbao_secret_injection.py` — KV v2 read/write/rotate and AppRole auth
  - `test_keycloak_oidc.py` — OIDC discovery, ROPC flow, JWT introspection
  - `test_minio_operations.py` — bucket CRUD, object upload/download, presigned URLs
  - `test_openmetadata_lineage.py` — service registration, table ingestion, lineage edges
  - `test_great_expectations_checkpoint.py` — live GE checkpoint execution
  - `test_tls_certificates.py` — TCP reachability, CA validity, mTLS enforcement
  - `test_trino_federation.py` — catalog federation, DDL round-trip, TPC-H validation
  - `test_dbt_run.py` — dbt stage/marts pipeline correctness and row count checks
  - `test_polaris_catalog.py` — Polaris REST API: namespaces, tables, OAuth2 flow
  - `test_audit_trail.py` — Ranger audit API + Loki log shipping verification
  - `test_observability_stack.py` — Prometheus targets, Grafana health, Loki streams
- **End-to-end tests** (`tests/e2e/`):
  - `test_full_pipeline.py` — MinIO upload → Docling → Iceberg → dbt → staging verification
  - `test_governance_enforcement.py` — Ranger policy enforcement, column masking E2E
  - `test_audit_trail_completeness.py` — append-only audit enforcement, PII access events
  - `test_disaster_recovery.py` — MinIO erasure, OpenBao HA failover, Nessie branch persistence
- **Performance tests** (`tests/performance/`):
  - `trino_benchmark.py` — TPC-H Q1/Q3/Q6/Q10/Q19 with SLO assertions
  - `ingest_throughput.py` — MinIO PUT/GET (50 MB/s SLO), Trino INSERT throughput (5000 rows/s)
  - `locustfile.py` — Locust load test: Trino/Keycloak/OpenMetadata users, P95 < 5000 ms

#### Documentation
- `docs/architecture/`: overview, data-flow, security-model, ha-topology
- `docs/adr/`: 10 Architecture Decision Records (ADR-001 through ADR-010)
- `docs/compliance/`: GDPR data map, SOC2 control mapping, audit trail specification
- `docs/operations/`: upgrade-procedures, capacity-planning, slo-definitions

### Security

- All secrets are managed exclusively through OpenBao — no plaintext credentials in the repository
- mTLS enforced for all service-to-service communication
- Ranger column masking applied to PII fields (email, SSN, credit card) in all query paths
- Ranger row-level filtering controls data visibility per user group
- Audit events are append-only in Iceberg (Ranger `DENY DELETE` policy)
- Keycloak session tokens are short-lived (1 hour) with refresh token rotation

---

[Unreleased]: https://github.com/your-org/open-lakehouse-platform/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/your-org/open-lakehouse-platform/releases/tag/v0.1.0
