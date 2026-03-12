# Procédures de Mise à Jour — Open Lakehouse Platform

## Vue d'ensemble

Ce document décrit les procédures de mise à jour **zéro indisponibilité** pour chaque composant de la plateforme. Toutes les mises à jour doivent être validées en staging avant application en production.

**Principe directeur** : chaque composant suit un cycle `blue/green` ou `rolling update` selon sa nature stateful/stateless. Les composants stateful (bases de données, Object Storage) exigent une coordination particulière.

---

## 1. Pré-requis avant toute mise à jour

```bash
# 1. Vérifier l'état de santé global
kubectl get pods -A | grep -v Running | grep -v Completed
helm list -A

# 2. Créer un snapshot OpenBao
kubectl exec -n lakehouse-system openbao-0 -- bao operator raft snapshot save \
  /tmp/openbao-$(date +%Y%m%d-%H%M%S).snap

# 3. Snapshot PostgreSQL
kubectl exec -n lakehouse-system postgresql-0 -- \
  pg_dumpall -U postgres | gzip > pg-backup-$(date +%Y%m%d).sql.gz

# 4. Vérifier les PodDisruptionBudgets
kubectl get pdb -A

# 5. S'assurer que HPA minReplicas >= 2 pour tous les stateless
kubectl get hpa -A
```

---

## 2. Trino (Stateless — Rolling Update)

Trino est déployé avec un coordinator et N workers. Le coordinator peut être mis à jour seul en premier : les workers existants continuent à traiter les requêtes actives.

### Procédure

```bash
# Étape 1 — Mettre à jour values.yaml avec la nouvelle version de l'image
# trino.image.tag: "xxx" → "yyy"

# Étape 2 — Appliquer en staging d'abord
helm upgrade lakehouse-staging helm/charts/lakehouse-core \
  -f helm/charts/lakehouse-core/values.staging.yaml \
  --set trino.image.tag=NEW_VERSION \
  --atomic --timeout 10m

# Étape 3 — Vérifier que le coordinator est opérationnel
kubectl rollout status deployment/trino-coordinator -n lakehouse-data
curl -sf http://trino.lakehouse.local/v1/info | jq '.nodeVersion.version'

# Étape 4 — Rolling update des workers (automatique via Deployment)
kubectl rollout status deployment/trino-worker -n lakehouse-data

# Étape 5 — Appliquer en production
helm upgrade lakehouse-prod helm/charts/lakehouse-core \
  -f helm/charts/lakehouse-core/values.production.yaml \
  --set trino.image.tag=NEW_VERSION \
  --atomic --timeout 15m
```

### Rollback Trino

```bash
helm rollback lakehouse-prod --wait --timeout 10m
```

---

## 3. Polaris (StatefulSet — Rolling Update avec pause)

Polaris maintient l'état des catalogues Iceberg en base. Toujours mettre à jour un pod à la fois.

```bash
# Vérifier la santé avant
kubectl exec -n lakehouse-data polaris-0 -- \
  curl -sf http://localhost:8182/healthcheck

# Mettre à jour l'image (podManagementPolicy: OrderedReady garantit 1 à la fois)
kubectl set image statefulset/polaris \
  polaris=apache/polaris:NEW_VERSION \
  -n lakehouse-data

# Surveiller le rollout
kubectl rollout status statefulset/polaris -n lakehouse-data --timeout=10m

# Vérifier l'API catalog
TOKEN=$(kubectl exec -n lakehouse-data polaris-0 -- \
  curl -sf -X POST http://localhost:8181/api/catalog/v1/oauth/tokens \
  -d 'grant_type=client_credentials&client_id=admin&scope=PRINCIPAL_ROLE:ALL' \
  | jq -r '.access_token')
kubectl exec -n lakehouse-data polaris-0 -- \
  curl -sf -H "Authorization: Bearer $TOKEN" \
  http://localhost:8181/api/catalog/v1/catalogs
```

---

## 4. PostgreSQL (StatefulSet — Zero-Downtime avec Patroni/Replication)

> **ATTENTION** : PostgreSQL est le composant le plus critique. Ne jamais mettre à jour le primaire et le réplica simultanément.

```bash
# Étape 1 — Mettre à jour le réplica en premier (si déployé avec HA)
kubectl set image statefulset/postgresql-replica \
  postgresql=bitnami/postgresql:NEW_VERSION \
  -n lakehouse-system
kubectl rollout status statefulset/postgresql-replica -n lakehouse-system

# Étape 2 — Effectuer un failover contrôlé vers le réplica mis à jour
# (si Patroni est utilisé)
kubectl exec -n lakehouse-system postgresql-0 -- \
  patronictl -c /etc/patroni/patroni.yaml switchover --master postgresql-0 --force

# Étape 3 — Mettre à jour l'ancien primaire (maintenant réplica)
kubectl set image statefulset/postgresql \
  postgresql=bitnami/postgresql:NEW_VERSION \
  -n lakehouse-system

# Étape 4 — Vérifier la réplication
kubectl exec -n lakehouse-system postgresql-0 -- \
  psql -U postgres -c "SELECT * FROM pg_stat_replication;"
```

### Mise à jour mineure (patch version)

```bash
# Les patch versions PostgreSQL (14.x → 14.y) ne requièrent pas de dump/restore
helm upgrade lakehouse-prod helm/charts/lakehouse-core \
  -f helm/charts/lakehouse-core/values.production.yaml \
  --set postgresql.image.tag=14.NEW_PATCH \
  --atomic --timeout 20m
```

---

## 5. Keycloak (StatefulSet — Rolling Update)

```bash
# Toujours démarrer Keycloak en mode --optimized après un changement de config
kubectl set image statefulset/keycloak \
  keycloak=quay.io/keycloak/keycloak:NEW_VERSION \
  -n lakehouse-system

# Vérifier le realm lakehouse
kubectl exec -n lakehouse-system keycloak-0 -- \
  curl -sf http://localhost:9000/health/ready

# Vérifier OIDC discovery endpoint
curl -sf https://keycloak.lakehouse.local/realms/lakehouse/.well-known/openid-configuration \
  | jq '.issuer'
```

---

## 6. OpenBao (StatefulSet Raft — Rolling Update par pod)

> **CRITIQUE** : OpenBao utilise le consensus Raft. Ne jamais mettre à jour plus d'un pod à la fois. Attendre que le pod rejoigne le cluster Raft avant de passer au suivant.

```bash
# Vérifier l'état du cluster Raft avant
kubectl exec -n lakehouse-system openbao-0 -- bao operator raft list-peers

# Snapshot de sécurité
kubectl exec -n lakehouse-system openbao-0 -- \
  bao operator raft snapshot save /tmp/pre-upgrade.snap
kubectl cp lakehouse-system/openbao-0:/tmp/pre-upgrade.snap ./openbao-backup.snap

# Mettre à jour pod par pod (partition rolling update)
kubectl patch statefulset openbao -n lakehouse-system \
  -p '{"spec":{"updateStrategy":{"rollingUpdate":{"partition":2}}}}'
kubectl set image statefulset/openbao openbao=quay.io/openbao/openbao:NEW_VERSION \
  -n lakehouse-system

# Attendre que openbao-2 soit healthy, puis décrémenter partition
kubectl rollout status statefulset/openbao -n lakehouse-system
kubectl patch statefulset openbao -n lakehouse-system \
  -p '{"spec":{"updateStrategy":{"rollingUpdate":{"partition":1}}}}'
# Attendre openbao-1, puis partition=0

# Vérifier le leader Raft
kubectl exec -n lakehouse-system openbao-0 -- bao operator raft list-peers
kubectl exec -n lakehouse-system openbao-0 -- bao status
```

---

## 7. MinIO (StatefulSet — Rolling Update)

MinIO supporte les rolling updates nativement grâce à son algorithme de healing.

```bash
# Vérifier l'état du cluster MinIO avant
kubectl exec -n lakehouse-storage minio-0 -- \
  mc admin info local

# Rolling update (MinIO gère automatiquement le quorum)
kubectl set image statefulset/minio \
  minio=minio/minio:NEW_VERSION \
  -n lakehouse-storage
kubectl rollout status statefulset/minio -n lakehouse-storage --timeout=20m

# Vérifier l'intégrité après
kubectl exec -n lakehouse-storage minio-0 -- \
  mc admin heal local --recursive
```

---

## 8. Airflow (Deployment — Rolling Update)

```bash
# Mettre à jour le scheduler et les workers séparément
# Le scheduler en premier (stateless entre les runs)
kubectl set image deployment/airflow-scheduler \
  scheduler=apache/airflow:NEW_VERSION \
  -n lakehouse-ingest
kubectl rollout status deployment/airflow-scheduler -n lakehouse-ingest

# Ensuite les workers (les runs actifs se terminent avant l'arrêt du pod)
kubectl set image deployment/airflow-worker \
  worker=apache/airflow:NEW_VERSION \
  -n lakehouse-ingest

# Vérifier via le webserver
kubectl rollout status deployment/airflow-webserver -n lakehouse-ingest
curl -sf https://airflow.lakehouse.local/health | jq '.metadatabase.status'
```

---

## 9. Procédure d'urgence — Rollback Helm complet

```bash
# Voir l'historique des releases
helm history lakehouse-prod -n lakehouse-data

# Rollback à la révision précédente
helm rollback lakehouse-prod -n lakehouse-data --wait --timeout 15m

# Rollback à une révision spécifique
helm rollback lakehouse-prod REVISION_NUMBER -n lakehouse-data --wait
```

---

## 10. Checklist post-mise à jour

- [ ] Tous les pods sont en état `Running` ou `Completed`
- [ ] Aucune alerte Prometheus active
- [ ] Les dashboards Grafana affichent des données normales
- [ ] Les traces Trino montrent des latences P99 dans les SLOs
- [ ] Test de connectivité Trino → MinIO → Iceberg → Polaris
- [ ] Le realm Keycloak est accessible et les tokens sont émis
- [ ] OpenBao : leader Raft élu, tous les peers connectés
- [ ] PostgreSQL : réplication à jour (`pg_stat_replication` lag < 1s)
- [ ] Backup post-mise-à-jour pris et archivé
