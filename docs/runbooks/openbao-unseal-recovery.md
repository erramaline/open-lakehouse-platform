# Runbook — OpenBao Unseal & Recovery

**Severité:** P1  
**Propriétaire:** Platform Engineering  
**Dernière révision:** 2026-03-12  
**ADR de référence:** ADR-002 (OpenBao vs Vault)

---

## Contexte

OpenBao utilise un cluster Raft à 3 nœuds (`openbao-0`, `openbao-1`, `openbao-2`). Au démarrage ou après un crash, chaque nœud démarre en état **sealed** (scellé). Il faut fournir au moins **3 des 5 clés de déchiffrement** (seuil de Shamir) pour les desceller.

Les clés de déchiffrement et le token root initial sont stockés hors-cluster, chiffrés avec la clé GPG de l'équipe d'astreinte et conservés dans :
- `s3://lakehouse-secrets-backup/openbao/unseal-keys.json.gpg` (compte d'urgence)
- Coffre physique (procédure de continuité d'activité)

---

## Symptômes

- `kubectl get pods -n lakehouse-system` : pods `openbao-*` en `Running` mais `READY 0/1`
- `kubectl logs openbao-0 -n lakehouse-system` : `core: vault is sealed`
- Les services dépendants (Trino, Airflow, Ranger, etc.) échouent à démarrer faute de secrets

---

## Procédure de déscellement (unseal) — cas normal

### Pré-requis
```bash
export BAO_ADDR="https://openbao.lakehouse-system.svc.cluster.local:8200"
export BAO_CACERT="/etc/openbao/tls/ca.crt"
```

### Étape 1 — Vérifier l'état du cluster
```bash
kubectl exec -n lakehouse-system openbao-0 -- bao status
kubectl exec -n lakehouse-system openbao-1 -- bao status
kubectl exec -n lakehouse-system openbao-2 -- bao status
```
Chaque nœud doit afficher `Sealed: true` avant de commencer.

### Étape 2 — Récupérer les clés de déchiffrement
```bash
# Déchiffrer depuis le backup S3 (nécessite la clé GPG d'astreinte)
aws s3 cp s3://lakehouse-secrets-backup/openbao/unseal-keys.json.gpg /tmp/
gpg --decrypt /tmp/unseal-keys.json.gpg > /tmp/unseal-keys.json
```

### Étape 3 — Désceller chaque nœud (3 clés minimum sur 5)
```bash
# Répéter 3 fois avec 3 clés différentes sur chaque nœud
for NODE in openbao-0 openbao-1 openbao-2; do
  kubectl exec -n lakehouse-system "${NODE}" -- bao operator unseal <UNSEAL_KEY_1>
  kubectl exec -n lakehouse-system "${NODE}" -- bao operator unseal <UNSEAL_KEY_2>
  kubectl exec -n lakehouse-system "${NODE}" -- bao operator unseal <UNSEAL_KEY_3>
done
```

### Étape 4 — Vérifier le déscellement
```bash
kubectl exec -n lakehouse-system openbao-0 -- bao status | grep -E "Sealed|HA Enabled|Active Node"
```
Résultat attendu : `Sealed: false`, `HA Enabled: true`, un seul nœud `Active`.

### Étape 5 — Supprimer les clés du disque local
```bash
shred -u /tmp/unseal-keys.json
```

---

## Procédure de récupération — perte d'un nœud Raft

### Pré-requis
Le cluster Raft tolère la perte d'**1 nœud sur 3** (quorum = 2).

### Étape 1 — Vérifier les membres Raft
```bash
kubectl exec -n lakehouse-system openbao-0 -- env BAO_TOKEN="${ROOT_TOKEN}" \
  bao operator raft list-peers
```

### Étape 2 — Supprimer le nœud défaillant du cluster
```bash
kubectl exec -n lakehouse-system openbao-0 -- env BAO_TOKEN="${ROOT_TOKEN}" \
  bao operator raft remove-peer openbao-2
```

### Étape 3 — Recréer le pod
```bash
kubectl delete pod openbao-2 -n lakehouse-system
# Kubernetes recréera automatiquement le pod via le StatefulSet
kubectl wait --for=condition=Ready pod/openbao-2 -n lakehouse-system --timeout=120s
```

### Étape 4 — Ré-joindre le cluster
Le pod rejoint automatiquement le cluster Raft via la configuration `retry_join`. Vérifier :
```bash
kubectl exec -n lakehouse-system openbao-0 -- env BAO_TOKEN="${ROOT_TOKEN}" \
  bao operator raft list-peers
```

### Étape 5 — Désceller le nouveau nœud
Répéter la procédure de déscellement (Étape 3 ci-dessus) pour le nœud `openbao-2`.

---

## Procédure de récupération — perte de quorum (2+ nœuds)

> **CRITIQUE** : Cette situation nécessite une restauration depuis backup.

### Étape 1 — Arrêter tous les nœuds
```bash
kubectl scale statefulset openbao -n lakehouse-system --replicas=0
```

### Étape 2 — Restaurer la snapshot Raft
```bash
# Télécharger la dernière snapshot depuis S3
aws s3 cp s3://lakehouse-secrets-backup/openbao/raft-snapshot-latest.snap /tmp/

# Redémarrer un seul nœud en mode recovery
kubectl scale statefulset openbao -n lakehouse-system --replicas=1
kubectl wait --for=condition=Ready pod/openbao-0 -n lakehouse-system --timeout=120s

# Appliquer la snapshot (nœud doit être déscellé)
bao operator raft snapshot restore /tmp/raft-snapshot-latest.snap
```

### Étape 3 — Redémarrer le cluster complet
```bash
kubectl scale statefulset openbao -n lakehouse-system --replicas=3
```

### Étape 4 — Désceller tous les nœuds
Répéter la procédure de déscellement standard.

---

## Rotation du token root post-incident

Si le token root initial a été compromis ou exposé :
```bash
# Générer un nouveau token root
bao operator generate-root -init
# Fournir les clés de déchiffrement jusqu'au seuil...
bao operator generate-root -otp <OTP> -nonce <NONCE> <UNSEAL_KEY>
# (répéter 3 fois)
# Décoder le token root final
bao operator generate-root -decode <ENCODED_TOKEN> -otp <OTP>
```
Stocker le nouveau token root immédiatement dans le coffre physique et supprimer l'ancien.

---

## Vérification post-intervention

```bash
# Vérifier que tous les AppRoles sont fonctionnels
for SERVICE in trino ranger airflow openmetadata grafana polaris; do
  echo "Testing ${SERVICE}..."
  ROLE_ID=$(cat /etc/openbao/.approle-${SERVICE}.json | jq -r .role_id)
  SECRET_ID=$(cat /etc/openbao/.approle-${SERVICE}.json | jq -r .secret_id)
  bao write auth/approle/login role_id="${ROLE_ID}" secret_id="${SECRET_ID}" \
    | grep -q "token" && echo "  ✓ ${SERVICE}" || echo "  ✗ ${SERVICE} FAILED"
done
```

---

## Escalade

| Niveau | Contact | Délai |
|--------|---------|-------|
| L1 — Astreinte Platform | PagerDuty `platform-oncall` | Immédiat |
| L2 — Lead Platform Eng. | PagerDuty `platform-lead` | +15 min si non résolu |
| L3 — CISO + Management | Email `security@` + appel direct | Perte de quorum ou compromission |
