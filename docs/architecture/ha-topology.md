# HA Topology — Open Lakehouse Platform

> **Version:** 1.0 | **Date:** 2026-03-12

This document provides the detailed high-availability topology for every stateful and semi-stateful component. For the decision rationale behind each HA choice, see [ADR-008](../adr/ADR-008-ha-strategy.md).

---

## Platform SLO Targets

| Tier | Components | Availability Target | Max Downtime/Year |
|---|---|---|---|
| **Tier 0 — Critical** | PostgreSQL, OpenBao, cert-manager | 99.95% | 4.4 hours |
| **Tier 1 — High** | Keycloak, MinIO, Polaris, Trino Gateway, Ranger | 99.9% | 8.7 hours |
| **Tier 2 — Standard** | Trino clusters, Airflow, OpenMetadata | 99.9% | 8.7 hours |
| **Tier 3 — Best-effort** | Nessie, Grafana, Loki, Prometheus | 99.5% | 43.8 hours |

---

## 1. PostgreSQL 16 — Patroni Cluster

### Topology

```
                   ┌─────────────────────────────┐
                   │    etcd (3-node cluster)     │  ← DCS for leader election
                   └──────────────┬──────────────┘
                                  │ Patroni watches
          ┌───────────────────────┼───────────────────────┐
          ▼                       ▼                       ▼
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│  PostgreSQL 16  │    │  PostgreSQL 16  │    │  PostgreSQL 16  │
│    PRIMARY      │───▶│  SYNC STANDBY  │    │  ASYNC REPLICA  │
│   (RW traffic)  │    │ (failover-ready)│    │  (read traffic) │
└────────┬────────┘    └─────────────────┘    └─────────────────┘
         │ streaming replication
         │ synchronous_commit=remote_write (sync)
         │ synchronous_commit=off (async replica)
         │
         ▼
    PgBouncer (per namespace, transaction mode)
    Virtual IP (HAProxy or Patroni native VIP)
```

### Recovery Objectives
- **RTO:** < 30 seconds (Patroni leader election + VIP failover)
- **RPO:** < 5 seconds (1 WAL segment max; remote_write ensures standby has data in OS buffer)

### Backup Strategy

| Backup Type | Tool | Schedule | Destination | Retention |
|---|---|---|---|---|
| Base backup | `pg_basebackup` | Daily 01:00 UTC | MinIO: `db-backups/<service>/` | 30 days |
| WAL archiving | `archive_command` → MinIO | Continuous | MinIO: `db-wal/<service>/` | 7 days |
| PITR test | Restore to scratch cluster | Weekly | Dev namespace | Discard after validation |

### Failure Scenarios

| Scenario | Patroni Behavior | RTO |
|---|---|---|
| Primary crashes | Promotes sync standby; DCS updates leader | < 30s |
| Primary + sync standby crash | Cluster stalls (quorum lost); manual intervention | Manual |
| Network partition (split-brain) | DCS rejects both sides from claiming leader | < 30s (DCS decides) |
| Disk full (primary) | Patroni pauses; alerts; manual cleanup required | Manual |

---

## 2. OpenBao — 3-Node Raft Cluster

### Topology

```
┌─────────────────────────────────────────────────────────┐
│                   OpenBao Raft Cluster                   │
│                                                         │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │   Node 1     │  │   Node 2     │  │   Node 3     │  │
│  │  (LEADER)    │◄─│  (FOLLOWER)  │─▶│  (FOLLOWER)  │  │
│  │  active      │  │  standby     │  │  standby     │  │
│  └──────┬───────┘  └──────────────┘  └──────────────┘  │
│         │  Raft log replication                         │
│         │  Quorum: 2 of 3 required                      │
└─────────┼───────────────────────────────────────────────┘
          │
          ▼ (K8s Service → leader only for writes)
    ESO + cert-manager (read/write secrets and issue certs)
```

### Seal Configuration

| Environment | Seal Type | Key Holder |
|---|---|---|
| Local | Shamir (5 shares, 3 threshold) | Ops team members (GPG-encrypted) |
| Staging | Shamir (3 shares, 2 threshold) | Staging ops |
| Production | Auto-unseal via Cloud KMS | AWS KMS / GCP KMS key (in separate account) |

### Recovery Objectives
- **RTO:** < 10 seconds (Raft leader election; K8s Service re-routes to new leader)
- **RPO:** 0 (Raft commits require quorum before acknowledging write)

### Failure Scenarios

| Scenario | Impact | Recovery |
|---|---|---|
| 1 node down | Cluster continues; 2 of 3 quorum maintained | Automatic; replace failed pod |
| 2 nodes down | Cluster stalls; no writes possible | Page SRE; restore quorum within 4h |
| All 3 nodes down | Cluster unavailable | Page SRE; restore from Raft snapshot; re-unseal |
| Leader re-election storm | Jittered election timeout prevents loop | Automatic (600ms ± 200ms jitter) |

---

## 3. Keycloak — Active/Active Cluster

### Topology

```
                  ┌───────────────────────────┐
                  │     K8s Service (LB)       │
                  │  (round-robin to all pods) │
                  └────────────┬──────────────┘
                               │
              ┌────────────────┼────────────────┐
              ▼                ▼                ▼
┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐
│  Keycloak Node 1 │  │  Keycloak Node 2 │  │  Keycloak Node 3 │
│   (active)       │◄─│   (active)       │─▶│   (active)       │
│  JGroups cluster │  │  JGroups cluster │  │  JGroups cluster │
└──────────────────┘  └──────────────────┘  └──────────────────┘
         │                      │                      │
         └──────────────────────┴──────────────────────┘
                        Infinispan distributed cache
                        (session replication, token cache)
                               │
                               ▼
                        PostgreSQL 16 (via Patroni VIP)
                        (realm config, user data, events)
```

### Session Management
- Session tokens stored in Infinispan cache; replicated to all nodes.
- A request hitting any node can validate a session created on any other node.
- Cache consistency: synchronous replication (low latency; adds ~5ms per request).

### Recovery Objectives
- **RTO:** 0 (active/active; LB removes failed pod within 5 seconds)
- **RPO:** 0 (session data in Infinispan is replicated before response returned)

### Rolling Upgrade Procedure

```
1. Scale to N+1 replicas (ensure quorum maintained)
2. Drain pod-1 (K8s lifecycle hook: SIGTERM → 60s graceful drain)
3. Update image tag on pod-1
4. Wait for pod-1 readiness probe (HTTP /health/ready)
5. Repeat for pod-2, pod-3
6. Scale back to N replicas
```

---

## 4. MinIO — Distributed Erasure Coding

### Topology (Production: 8 nodes)

```
┌────────────────────────────────────────────────────────────────┐
│               MinIO Erasure Set (8-node / EC:4)                │
│                                                                │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐      │
│  │  Node 1  │  │  Node 2  │  │  Node 3  │  │  Node 4  │      │
│  │ 4 drives │  │ 4 drives │  │ 4 drives │  │ 4 drives │      │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘      │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐      │
│  │  Node 5  │  │  Node 6  │  │  Node 7  │  │  Node 8  │      │
│  │ 4 drives │  │ 4 drives │  │ 4 drives │  │ 4 drives │      │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘      │
│                                                                │
│  Erasure Code: EC:4 — data and parity shards spread across     │
│  all 32 drives. Any 16 drives sufficient to reconstruct.       │
│  Tolerates: loss of 4 nodes simultaneously (N/2)               │
└────────────────────────────────────────────────────────────────┘
```

### Erasure Coding Math

| Config | Total drives | Data shards | Parity shards | Max drive failures | Storage efficiency |
|---|---|---|---|---|---|
| 4-node / 4 drives each | 16 | 8 | 8 | 8 (50%) | 50% |
| 8-node / 4 drives each | 32 | 16 | 16 | 16 (50%) | 50% |
| 8-node / 8 drives each | 64 | 32 | 32 | 32 (50%) | 50% |

### Bucket Policies by Criticality

| Bucket | Object Lock | Mode | Retention |
|---|---|---|---|
| `lakehouse-data/` | Disabled | — | Application-managed |
| `audit-log/` | Enabled | COMPLIANCE | 7 years |
| `db-backups/` | Enabled | GOVERNANCE | 30 days |
| `gx-results/` | Enabled | GOVERNANCE | 1 year |
| `lakehouse-dev/` | Disabled | — | Auto-deleted on branch cleanup |

### Recovery Objectives
- **RTO (node failure):** 0 — reads served from remaining shards; writes continue at reduced performance
- **RPO:** 0 for writes acknowledged after write quorum (N/2 + 1 nodes)

---

## 5. Trino — Multi-Coordinator with Gateway

### Topology

```
                  ┌─────────────────────────────────┐
                  │  Trino Gateway (2 replicas, HA)  │
                  │  JWT validation + cluster routing │
                  └─────────────┬───────────────────┘
                                │
              ┌─────────────────┼──────────────────┐
              ▼                                     ▼
┌──────────────────────────┐           ┌──────────────────────────┐
│    Trino Cluster A        │           │    Trino Cluster B        │
│                           │           │                           │
│  Coordinator (stateless)  │           │  Coordinator (stateless)  │
│  + Worker pool (HPA)      │           │  + Worker pool (HPA)      │
│  Min: 2, Max: 20 workers  │           │  Min: 2, Max: 10 workers  │
└──────────────────────────┘           └──────────────────────────┘
         Cluster A: interactive queries (tenant_a, tenant_b)
         Cluster B: ETL workloads (long-running, high-memory)
```

### HPA Configuration (Workers)

```yaml
metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70      # scale up when avg CPU > 70%
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80      # scale up when avg memory > 80%
minReplicas: 2
maxReplicas: 20
scaleDown:
  stabilizationWindowSeconds: 300   # wait 5 min before scaling down
  policies:
    - type: Percent
      value: 25                     # remove max 25% of workers at a time
      periodSeconds: 60
```

### Gateway Health Check Configuration

```yaml
healthCheck:
  interval: 10s          # check coordinator health every 10 seconds
  timeout: 5s
  unhealthyThreshold: 3  # 3 consecutive failures → mark coordinator UNHEALTHY
  healthyThreshold: 2    # 2 consecutive successes → mark coordinator HEALTHY
gracefulDrainTimeout: 10m # wait up to 10 minutes for in-flight queries on drain
```

### Recovery Objectives
- **RTO:** < 30 seconds (gateway detects coordinator failure; routes new queries to healthy cluster)
- **RPO:** N/A (stateless; in-flight queries fail; clients retry)
- **In-flight query loss:** Expected during coordinator failure; Airflow task retry handles ETL; BI tools handle interactive retry

---

## 6. Apache Polaris — Active/Active Replicas

### Topology

```
K8s Service (ClusterIP, round-robin)
         │
    ┌────┴─────┐
    ▼          ▼
┌────────┐  ┌────────┐
│Polaris │  │Polaris │   (stateless — all state in PostgreSQL)
│Pod 1   │  │Pod 2   │
└────────┘  └────────┘
    │            │
    └────────────┘
          │
    PostgreSQL 16 (via Patroni VIP)

PodDisruptionBudget: minAvailable: 1
```

### Recovery Objectives
- **RTO:** < 10 seconds (K8s readiness probe removes failed pod; LB re-routes)
- **RPO:** Bounded by PostgreSQL RPO (< 5 seconds)

---

## 7. Apache Ranger — Admin + Plugin Cache

### Topology

```
┌──────────────────────────────────────────────┐
│           Ranger Admin (2 replicas)           │
│  ┌──────────────┐      ┌──────────────┐      │
│  │  Admin Pod 1 │      │  Admin Pod 2 │      │
│  └──────────────┘      └──────────────┘      │
│         │                     │              │
│         └──────────┬──────────┘              │
│                    ▼                         │
│            PostgreSQL 16 (shared)            │
└──────────────────────────────────────────────┘
                    │ Policy sync (every 30s)
                    ▼
┌──────────────────────────────────────────────┐
│         Ranger Plugin (in Trino)             │
│    Local policy cache (TTL: 30 seconds)      │
│    Authorization decisions: in-process       │
│    No network call on hot path               │
└──────────────────────────────────────────────┘
```

### Recovery Objectives
- **RTO for access decisions:** 0 (cached in Trino process)
- **RTO for Admin UI:** < 10 seconds
- **Policy update propagation:** ≤ 30 seconds (cache TTL)

---

## 8. Apache Airflow — CeleryExecutor HA

### Topology

```
┌──────────────────────────────────────────────────────┐
│                  Airflow Web / API                    │
│  ┌──────────────────────┐  ┌──────────────────────┐  │
│  │  Webserver Pod 1     │  │  Webserver Pod 2     │  │
│  └──────────────────────┘  └──────────────────────┘  │
└──────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────┐
│                 Airflow Schedulers                    │
│  ┌──────────────────────┐  ┌──────────────────────┐  │
│  │  Scheduler 1 (active)│  │  Scheduler 2 (standby)│ │
│  │  (heartbeat in DB)   │  │  (heartbeat in DB)   │  │
│  └──────────────────────┘  └──────────────────────┘  │
└──────────────────────────────────────────────────────┘
                         │ Task dispatch via Celery
                         ▼
┌──────────────────────────────────────────────────────┐
│            Redis Sentinel (Celery Broker)             │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐           │
│  │ Redis    │  │ Redis    │  │ Redis    │           │
│  │ Primary  │  │ Replica  │  │ Replica  │           │
│  └──────────┘  └──────────┘  └──────────┘           │
│  Sentinel: 3 nodes; master election; auto-failover   │
└──────────────────────────────────────────────────────┘
                         │
                         ▼
┌──────────────────────────────────────────────────────┐
│              Celery Workers (HPA)                     │
│  Min: 2 workers | Max: 10 workers per queue           │
│  Queues: default | high-priority | docling | dbt     │
└──────────────────────────────────────────────────────┘
```

### Recovery Objectives
- **RTO (scheduler failure):** < 60 seconds (second scheduler takes over after heartbeat timeout)
- **RTO (worker failure):** Task is re-queued; picked up by available worker within 30 seconds
- **RPO:** 0 (task state in PostgreSQL; no task state in failed worker)

---

## 9. Capacity Planning Baselines

### Initial Production Sizing (adjusting via HPA and VPA as observed)

| Component | Replicas | CPU Request | CPU Limit | Memory Request | Memory Limit |
|---|---|---|---|---|---|
| PostgreSQL (each) | 3 (1P+1S+1R) | 4 | 16 | 16 GiB | 64 GiB |
| OpenBao | 3 | 500m | 2 | 1 GiB | 4 GiB |
| Keycloak | 3 | 1 | 4 | 2 GiB | 4 GiB |
| MinIO (each node) | 8 static | 2 | 8 | 8 GiB | 32 GiB |
| Polaris | 2–4 | 1 | 4 | 2 GiB | 4 GiB |
| Nessie | 2 | 500m | 2 | 1 GiB | 2 GiB |
| Ranger Admin | 2 | 1 | 4 | 2 GiB | 4 GiB |
| Trino Coordinator | 1 per cluster | 4 | 16 | 8 GiB | 32 GiB |
| Trino Worker | 2–20 (HPA) | 4 | 16 | 16 GiB | 64 GiB |
| Trino Gateway | 2 | 500m | 2 | 1 GiB | 2 GiB |
| Airflow Scheduler | 2 | 1 | 4 | 2 GiB | 4 GiB |
| Airflow Worker | 2–10 (HPA) | 2 | 8 | 4 GiB | 16 GiB |
| Docling Worker | 1–8 (HPA) | 4 (GPU: 1) | 8 | 8 GiB | 16 GiB |
| OpenMetadata | 2 | 2 | 8 | 4 GiB | 8 GiB |
| Prometheus | 2 | 2 | 8 | 8 GiB | 16 GiB |
| Loki | 3 | 2 | 8 | 4 GiB | 16 GiB |
| Grafana | 2 | 500m | 2 | 512 MiB | 2 GiB |
| ESO | 2 | 100m | 500m | 128 MiB | 512 MiB |
| cert-manager | 2 | 100m | 500m | 128 MiB | 512 MiB |

---

## 10. Disaster Recovery Runbooks (Summary)

| Scenario | Runbook Location | Target RTO | Category |
|---|---|---|---|
| PostgreSQL primary failure | `pipelines/scripts/dr/postgres-failover.md` | 30s (automatic) | Auto |
| OpenBao quorum loss | `pipelines/scripts/dr/openbao-recovery.md` | 4 hours | Manual |
| MinIO node loss | `pipelines/scripts/dr/minio-healing.md` | 0 (automatic healing) | Auto |
| MinIO pool loss (> N/2 nodes) | `pipelines/scripts/dr/minio-restore.md` | 8 hours | Manual |
| Keycloak DB loss | `pipelines/scripts/dr/keycloak-restore.md` | 2 hours | Manual |
| Full cluster loss | `pipelines/scripts/dr/full-cluster-restore.md` | 24 hours | Manual |
| Secret rotation emergency | `pipelines/scripts/rotate-secrets.sh` | 15 minutes | Semi-auto |
