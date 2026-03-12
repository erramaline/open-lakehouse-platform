# Planification de Capacité — Open Lakehouse Platform

## Vue d'ensemble

Ce document fournit les modèles de dimensionnement pour trois niveaux de charge :
- **S** : 10 utilisateurs Trino concurrents
- **M** : 100 utilisateurs Trino concurrents  
- **L** : 1 000 utilisateurs Trino concurrents

Les estimations incluent le CPU, la mémoire, le stockage et le réseau pour chaque composant.

---

## 1. Hypothèses de charge

| Métrique | Valeur |
|----------|--------|
| Requête Trino moyenne | 30 s, 500 MB données scannées |
| Taille dataset raw | 10 TB (S) / 100 TB (M) / 1 PB (L) |
| Rétention audit logs | 90 jours |
| Ratio compression Parquet | 5:1 (vs CSV) |
| Taux d'ingestion quotidien | 10 GB/j (S) / 100 GB/j (M) / 1 TB/j (L) |
| Sessions Airflow DAGs | 50/j (S) / 500/j (M) / 5 000/j (L) |

---

## 2. Trino

### Coordinator

Le coordinator est stateless mais porte le plan d'exécution et l'état des sessions.

| Tier | vCPU | RAM | Repliques | Notes |
|------|------|-----|-----------|-------|
| S (10 users) | 2 | 8 Gi | 1 | `JVM Xmx: 6G` |
| M (100 users) | 8 | 32 Gi | 1 (+ 1 standby) | `JVM Xmx: 24G` |
| L (1 000 users) | 16 | 64 Gi | 2 (HA via load balancer) | `JVM Xmx: 48G` |

### Workers

Règle de base : **1 vCPU / 2 GB RAM par utilisateur concurrent**, arrondi à l'unité de nœud.

| Tier | vCPU/worker | RAM/worker | Min workers | Max workers (HPA) |
|------|-------------|------------|-------------|-------------------|
| S | 4 | 16 Gi | 2 | 4 |
| M | 8 | 32 Gi | 4 | 20 |
| L | 16 | 128 Gi | 10 | 100 |

```yaml
# Exemple values.yaml Tier M
trino:
  coordinator:
    resources:
      requests: { cpu: "6", memory: 28Gi }
      limits: { cpu: "8", memory: 32Gi }
    jvmMaxHeap: "24G"
  workers:
    replicas: 4
    resources:
      requests: { cpu: "6", memory: 28Gi }
      limits: { cpu: "8", memory: 32Gi }
    jvmMaxHeap: "24G"
    autoscaling:
      enabled: true
      minReplicas: 4
      maxReplicas: 20
      targetCPUUtilizationPercentage: 70
```

### Réseau Trino

- Bande passante inter-worker requise : `(users × 500 MB/30s) / nbWorkers`
- Tier M : `100 × 500 MB / 30s / 8 workers ≈ 200 MB/s` → réseau 1 Gbps par nœud

---

## 3. MinIO (Object Storage)

MinIO s'architecture en zones avec 4 disques minimum par pod pour l'Erasure Coding (EC:2+2).

| Tier | Pods | Disques/pod | Taille/disque | Capacité brute | Capacité EC nette |
|------|------|-------------|---------------|----------------|-------------------|
| S | 4 | 4 | 500 Gi | 8 Ti | 4 Ti |
| M | 4 | 4 | 5 Ti | 80 Ti | 40 Ti |
| L | 8 | 4 | 12 Ti | 384 Ti | 192 Ti |

> Prévoir **+40% de marge** pour la compaction Iceberg, les snapshots et la croissance non anticipée.

```yaml
# Tier M
minio:
  replicas: 4
  disksPerPod: 4
  storage:
    size: 5Ti
  resources:
    requests: { cpu: "4", memory: 16Gi }
    limits: { cpu: "8", memory: 32Gi }
```

---

## 4. PostgreSQL

PostgreSQL héberge les métadonnées : Polaris, Keycloak, Ranger, Airflow, OpenMetadata, Trino Gateway.

| DB | Tier S | Tier M | Tier L |
|----|--------|--------|--------|
| Polaris | 5 Gi | 20 Gi | 100 Gi |
| Keycloak | 2 Gi | 5 Gi | 20 Gi |
| Ranger | 5 Gi | 20 Gi | 50 Gi |
| Airflow | 5 Gi | 30 Gi | 200 Gi |
| OpenMetadata | 10 Gi | 50 Gi | 500 Gi |
| **Total** | **~30 Gi** | **~130 Gi** | **~870 Gi** |

```yaml
# Tier M — PostgreSQL
postgresql:
  primary:
    storage:
      size: 200Gi
  config:
    maxConnections: 400       # (connections/service × nombre de services)
    sharedBuffers: "4GB"      # 25% de la RAM du pod
    effectiveCacheSize: "12GB"
    workMem: "64MB"
    maintenanceWorkMem: "512MB"
  resources:
    requests: { cpu: "4", memory: 16Gi }
    limits: { cpu: "8", memory: 16Gi }
```

---

## 5. Apache Ranger

Ranger est majoritairement CPU-bound lors de l'évaluation des politiques.

| Tier | vCPU | RAM | Répliques |
|------|------|-----|-----------|
| S | 2 | 4 Gi | 1 |
| M | 4 | 8 Gi | 2 |
| L | 8 | 16 Gi | 3 |

Cache des politiques :
- Configurer `ranger.plugins.audit.kafka.enabled=true` au Tier L pour l'audit asynchrone
- TTL cache des décisions : 60 s (ajuster en fonction du throughput)

---

## 6. Keycloak

Keycloak met en cache les sessions en mémoire (Infinispan).

| Tier | vCPU | RAM | Répliques | JVM Heap |
|------|------|-----|-----------|----------|
| S | 2 | 4 Gi | 1 | 2 Gi |
| M | 4 | 8 Gi | 2 | 4 Gi |
| L | 8 | 16 Gi | 3 | 10 Gi |

```yaml
keycloak:
  replicas: 2
  resources:
    requests: { cpu: "3", memory: 7Gi }
    limits: { cpu: "4", memory: 8Gi }
```

---

## 7. OpenBao

OpenBao (HashiCorp Vault fork) avec Raft nécessite un quorum impair.

| Tier | Nœuds Raft | vCPU/nœud | RAM/nœud | Stockage/nœud |
|------|------------|-----------|----------|---------------|
| S | 1 | 1 | 2 Gi | 10 Gi |
| M | 3 | 2 | 4 Gi | 20 Gi |
| L | 5 | 4 | 8 Gi | 50 Gi |

> **Toujours un nombre impair** de nœuds pour le consensus Raft.

---

## 8. Airflow

| Tier | Scheduler | Workers min | Workers max | RAM/worker |
|------|-----------|-------------|-------------|-----------|
| S | 1 × 2c/4G | 2 | 4 | 4 Gi |
| M | 1 × 4c/8G | 4 | 16 | 8 Gi |
| L | 2 × 8c/16G | 8 | 64 | 16 Gi |

---

## 9. Observabilité (Prometheus/Loki/Grafana)

| Composant | Tier S | Tier M | Tier L |
|-----------|--------|--------|--------|
| Prometheus rétention | 15j / 50 Gi | 30j / 200 Gi | 60j / 1 Ti |
| Loki rétention | 30j / 100 Gi | 30j / 500 Gi | 90j / 5 Ti |
| Grafana | 1 × 1c/2G | 2 × 2c/4G | 3 × 4c/8G |

Taux d'ingestion Prometheus estimé :
- S : 50 000 séries actives, ~10 MB/min ingéré
- M : 500 000 séries actives, ~100 MB/min
- L : 5 000 000 séries actives, ~1 GB/min → envisager Thanos/Cortex

---

## 10. Récapitulatif nœuds Kubernetes

| Tier | Nœuds workers | vCPU/nœud | RAM/nœud | Type recommandé |
|------|---------------|-----------|----------|-----------------|
| S | 3 | 8 | 32 Gi | `n2-standard-8` (GCP) / `m5.2xlarge` (AWS) |
| M | 8 | 16 | 64 Gi | `n2-standard-16` / `m5.4xlarge` |
| L | 20-100 | 32 | 128 Gi | `n2-standard-32` / `m5.8xlarge` + node autoscaler |

### Tier L — Architecture multi-node pools

```
┌─────────────────────────────────────────────────────┐
│  Node Pool: trino-workers  (16-100 nœuds, spot OK)  │
│  Node Pool: data-plane      (polaris, ranger, nessie)│
│  Node Pool: system          (postgresql, keycloak,  │
│                              openbao — NO SPOT)      │
│  Node Pool: observability   (prometheus, loki, graf) │
└─────────────────────────────────────────────────────┘
```

### Labels et taints recommandés

```yaml
# Nœuds Trino Worker (spot toleré)
taints:
  - key: workload
    value: trino-worker
    effect: NoSchedule
labels:
  workload: trino-worker
  node.kubernetes.io/instance-type: spot

# Nœuds System critiques (on-demand uniquement)
taints:
  - key: workload
    value: stateful
    effect: NoSchedule
labels:
  workload: stateful
```

---

## 11. Alertes de capacité

Configurer ces alertes Prometheus pour anticiper les saturations :

```yaml
# Espace disque : alerte si > 75% utilisé
- alert: DiskSpaceWarning
  expr: (1 - node_filesystem_avail_bytes / node_filesystem_size_bytes) > 0.75
  for: 15m

# Mémoire workers Trino : alerte si JVM heap > 85%
- alert: TrinoHeapPressure
  expr: jvm_memory_bytes_used{area="heap"} / jvm_memory_bytes_max{area="heap"} > 0.85
  for: 5m

# Connexions PostgreSQL : alerte si > 80% du max_connections
- alert: PostgreSQLConnectionSaturation
  expr: pg_stat_database_numbackends / pg_settings_max_conn > 0.80
  for: 5m

# MinIO storage : alerte si capacité disponible < 20%
- alert: MinIOStorageLow
  expr: minio_cluster_capacity_usable_free_bytes / minio_cluster_capacity_usable_total_bytes < 0.20
  for: 30m
```
