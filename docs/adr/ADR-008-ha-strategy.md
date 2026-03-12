# ADR-008: High Availability Strategy — Trade-offs per Component

| Field | Value |
|---|---|
| **Status** | Accepted |
| **Date** | 2026-03-12 |
| **Deciders** | Principal Data Platform Architect, Platform SRE, Data Engineering Lead |
| **Tags** | ha, reliability, operations, slo |

---

## Context

The platform's global constraint states: **"No single point of failure on any critical path."** For a data lakehouse serving analytics workloads, the critical path includes the query engine, catalog, object storage, identity, and secrets. However, HA has a cost — in operational complexity, resource usage, and licensing. This ADR documents the HA model for each stateful and semi-stateful component, the trade-offs accepted, and the SLO implications.

**Platform SLO targets:**
- Query engine availability: **99.9%** (≈ 8.7h downtime/year)
- Object storage availability: **99.95%** (≈ 4.4h downtime/year)
- Identity provider availability: **99.9%**
- Secrets manager availability: **99.95%** (higher because all services depend on it at startup)

---

## HA Decisions per Component

---

### 1. PostgreSQL 16 — Patroni HA Cluster

**Model:** 1 primary + 1 synchronous standby + 1 asynchronous replica (read workloads)

| Metric | Value |
|---|---|
| Replication | Streaming replication (synchronous_commit = remote_write for standby) |
| Failover | Patroni automatic (DCS: etcd or Consul) — leader election in < 30s |
| Connection pooling | PgBouncer (transaction mode, 1 instance per namespace) |
| Backup | pg_basebackup daily + WAL archiving to MinIO (dedicated immutable bucket) |
| RTO | < 30 seconds (Patroni leader election) |
| RPO | < 5 seconds (1 potentially uncommitted WAL segment) |
| Read scale-out | Applications can read from async replica for non-critical queries |

**Trade-off accepted:** Synchronous standby requires both primary and standby to acknowledge writes. If the standby is unavailable, writes block (by design — protects RPO). PostgreSQL's `synchronous_commit = remote_write` avoids full fsync on the standby while guaranteeing the WAL is written to the standby's OS buffer — a balance between durability and performance.

**Note:** Each service namespace gets its own PgBouncer instance. All instances point to the same Patroni cluster primary via VIP (virtual IP managed by Patroni + keepalived or via DNS).

---

### 2. OpenBao — 3-Node Raft Cluster

**Model:** 3 Raft peers (1 active leader, 2 followers)

| Metric | Value |
|---|---|
| Consensus | Raft; quorum = 2 of 3 nodes |
| Auto-unseal | Cloud KMS (prod) / Shamir shares (local / staging) |
| Failover | Automatic Raft leader re-election < 10 seconds |
| RTO | < 10 seconds |
| RPO | 0 (Raft commits require quorum before returning success) |
| Storage backend | Integrated Raft (no external etcd/Consul required) |

**Trade-off accepted:** 3 nodes is the minimum for Raft quorum with 1 failure tolerance. 5 nodes provides 2-node fault tolerance but doubles cost. 3 nodes is sufficient for our SLO given secrets are not on the hot path of query execution (read from cache after startup).

**Caution:** Loss of 2 Raft nodes simultaneously causes the cluster to become read-only (no writes/issues). Design runbook: quorum loss → operator-assisted recovery within 4 hours (P1 SLA).

---

### 3. Keycloak — Active/Active Cluster

**Model:** 2+ nodes behind a load balancer with Infinispan distributed session cache

| Metric | Value |
|---|---|
| Clustering | JGroups discovery (K8s DNS-based or JDBC ping) |
| Session storage | Infinispan distributed cache (replicated) |
| Failover | Seamless — LB removes failed node; sessions preserved in cache |
| RTO | 0 (active/active; LB routes around failures) |
| RPO | 0 (sessions replicated before response returned) |
| Minimum replicas | 2 (3 recommended for rolling upgrades without downtime) |
| Startup sequencing | K8s init container checks DB readiness before main container starts |

**Trade-off accepted:** Infinispan cache adds memory overhead (~256 MiB per node for session data at scale). Offset by eliminating the cost of Keycloak downtime affecting all user-facing tools.

---

### 4. MinIO — Distributed Erasure Coding

**Model:** 4-node minimum deployment with erasure coding EC:4 (N/2 tolerance)

| Metric | Value |
|---|---|
| Erasure coding | EC:4 per pool — survives loss of N/2 drives or nodes |
| Write quorum | N/2 + 1 nodes must acknowledge before write is committed |
| Data stripes | Data split across all drives; any N/2 drives sufficient to reconstruct |
| Healing | Automatic background healing on node rejoin |
| Read RTO | 0 — degraded reads served from remaining drives |
| Write RTO | 0 — writes continue during single-node failure |
| Node loss tolerance | Up to N/2 = 2 nodes (4-node cluster) |
| Recommended prod | 8 nodes (EC:4, tolerates 4 simultaneous drive failures) |

**Trade-off accepted:** EC:4 requires 2× storage overhead minimum (50% raw efficiency). This is the fundamental trade-off of erasure coding vs replication. At petabyte scale, EC is more space-efficient than 3-way replication. We accept the CPU overhead of erasure encoding/decoding.

**Caution:** MinIO distributed mode requires ALL nodes in a pool to be started before the cluster is healthy. Use a K8s StatefulSet with `podManagementPolicy: Parallel`.

---

### 5. Trino — Multi-Coordinator (Trino Gateway)

**Model:** 2 independent Trino clusters (Coordinator + Worker pool each), fronted by Trino Gateway

| Metric | Value |
|---|---|
| State | Stateless coordinators (query state in memory only) |
| Worker scaling | HPA on CPU (target 70%); min 2 workers per cluster |
| Failover | Gateway detects coordinator failure via health checks; routes to other cluster |
| In-flight query loss | Queries on failed coordinator are lost; client retries |
| RTO | < 30 seconds (gateway health check interval) |
| RPO | N/A (no on-disk state; queries are re-executed) |

**Trade-off accepted:** Trino does not support query migration between coordinators. A coordinator failure causes in-flight queries to fail. This is accepted because:
- Interactive queries are typically < 5 minutes; re-execution cost is low.
- Long-running ETL queries run via Airflow with retry logic.
- Trino Gateway routes new queries to the healthy cluster immediately; only in-flight queries on the failed coordinator are affected.

**Graceful rolling upgrade:** Trino Gateway supports a "drain" mode — marks coordinator as `DRAINING`, waits for active queries to complete (up to 10 minutes), then terminates. No query is killed during a rolling upgrade.

---

### 6. Apache Polaris — Active/Active Replicas

**Model:** K8s Deployment with 2+ replicas behind a ClusterIP Service

| Metric | Value |
|---|---|
| State | Stateless (all state in PostgreSQL backend) |
| Failover | K8s endpoint controller removes failed pod within 5-10 seconds |
| RTO | < 10 seconds (liveness probe → pod replacement) |
| RPO | Bounded by PostgreSQL RPO (< 5 seconds) |
| Minimum replicas | 2 (PodDisruptionBudget: minAvailable = 1) |

**Trade-off accepted:** Polaris pod crashes lose in-flight requests only (no data loss — PostgreSQL is the state store). K8s replaces pods quickly. Acceptable for catalog operations which are low-frequency compared to query operations.

---

### 7. Apache Ranger — Admin + Plugin Cache

**Model:** 2+ Ranger Admin replicas + client-side policy cache in Trino plugin

| Metric | Value |
|---|---|
| Admin HA | 2 replicas; state in PostgreSQL; load balanced |
| Plugin cache | Ranger plugin in Trino caches policies for 30s TTL |
| RTO for policy decisions | 0 (cached locally in Trino) |
| RTO for policy updates | ≤ 30 seconds (cache TTL) |
| RTO for Admin UI | < 10 seconds (K8s pod replacement) |

**Trade-off accepted:** The 30-second policy cache TTL means that a newly revoked permission takes up to 30 seconds to take effect across all Trino workers. This is acceptable for our use case; near-real-time revocation is achieved via Keycloak session invalidation (reduces access token validity).

---

### 8. Apache Airflow — CeleryExecutor HA

**Model:** 2 Schedulers (active/active with DB heartbeat) + Redis Sentinel (3 nodes) + ephemeral Celery workers

| Metric | Value |
|---|---|
| Scheduler HA | 2 schedulers; active/active via DB leader election |
| Worker scaling | HPA; workers are stateless and ephemeral |
| Broker | Redis Sentinel (3 nodes — 1 primary, 2 replicas) |
| RTO | < 30 seconds (scheduler re-election) |
| RPO | DAG run state preserved in Airflow DB (PostgreSQL) |

**Trade-off accepted:** CeleryExecutor requires Redis as a message broker (adds operational burden). KubernetesExecutor (alternative — no Redis) was evaluated but rejected because it creates one pod per task, which has high pod-lifecycle overhead for short tasks. CeleryExecutor with pre-warmed workers is more efficient for our pipeline workloads.

---

### 9. OpenMetadata — Active/Active + Elasticsearch

**Model:** 2+ OpenMetadata API server replicas + 3-node Elasticsearch cluster

| Metric | Value |
|---|---|
| API server | Stateless; K8s Deployment; state in PostgreSQL + Elasticsearch |
| Search index | Elasticsearch 3-node (1 primary + 1 replica per index) |
| Failover | K8s pod replacement + Elasticsearch shard rebalancing |
| RTO | < 30 seconds for API; < 2 minutes for Elasticsearch index replay |

**Trade-off accepted:** Elasticsearch adds significant resource overhead (3 × 4 GiB JVM heap minimum). Considered OpenSearch (Apache 2.0 fork) as alternative — deferred; OpenMetadata's official connector targets Elasticsearch. OpenSearch compatibility not yet verified for OpenMetadata 1.12.x.

---

### 10. cert-manager — Single Active (HA optional)

**Model:** 1 replica by default; 2 replicas with leader election for HA

| Metric | Value |
|---|---|
| State | CRD state in etcd (K8s native) |
| Failover | K8s pod replacement; certificates continue to be served by services (no cert-manager needed for serving, only for issuance/renewal) |
| RTO for renewals | < 2 minutes (new pod starts) |
| Impact of outage | No new certificates issued; existing certificates continue to serve until expiry |

**Trade-off accepted:** cert-manager outage ≤ 90 days is safe (certificates are still valid). A cert-manager outage longer than the certificate lifetime would cause certificate expiry. Mitigated by alerting on cert_expiry_days < 14 — giving 2+ weeks to restore cert-manager before any expiry occurs.

---

## SLO Summary

| Component | Availability Target | Model | Primary Risk |
|---|---|---|---|
| PostgreSQL | 99.95% | Primary + sync standby | Patroni failover > 30s |
| OpenBao | 99.95% | 3-node Raft | Quorum loss (2 nodes down) |
| Keycloak | 99.9% | Active/active | DB dependency |
| MinIO | 99.95% | EC distributed | EC:4 loses > N/2 nodes |
| Trino | 99.9% | Multi-coordinator | In-flight query loss on coordinator fail |
| Polaris | 99.9% | Active/active | PostgreSQL availability |
| Ranger | 99.9% | Active/active + cache | Cache TTL on revocation |
| Airflow | 99.5% | CeleryExecutor HA | Scheduled — downstream HA not required |
| OpenMetadata | 99.5% | Active/active + ES | Elasticsearch JVM GC pauses |

---

## References
- [Patroni documentation](https://patroni.readthedocs.io/)
- [MinIO Erasure Coding](https://min.io/docs/minio/kubernetes/upstream/operations/concepts/erasure-coding.html)
- [Trino Gateway](https://trinodb.github.io/trino-gateway/)
- [Keycloak Cluster Setup](https://www.keycloak.org/server/clustering)
- [OpenBao Raft Storage](https://openbao.org/docs/configuration/storage/raft/)
- ADR-002 — OpenBao HA (3-node Raft detailed)
- ADR-007 — Keycloak HA (active/active clustering)
