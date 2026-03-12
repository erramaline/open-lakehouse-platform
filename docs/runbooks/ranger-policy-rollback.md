# Runbook — Ranger Policy Rollback

**Severité:** P2 (P1 si données sensibles exposées)  
**Propriétaire:** Data Governance / Platform Engineering  
**Dernière révision:** 2026-03-12  
**ADR de référence:** ADR-005 (Dual Catalog Strategy)

---

## Contexte

Apache Ranger gère les règles d'accès aux données Iceberg via des politiques stockées dans sa base PostgreSQL. Un rollback est nécessaire quand :
- Une politique erronée entraîne un accès non-autorisé (over-permission)
- Une politique trop restrictive bloque un service critique (under-permission)
- Une modification de politique en production n'a pas été testée en staging

Toutes les politiques sont versionnées dans Git (`security/ranger/policies/`) et peuvent être réimportées de manière idempotente via `import-policies.sh`.

---

## Sources de vérité

| Source | Usage |
|--------|-------|
| `security/ranger/policies/*.json` | Définition canonique des politiques (Git) |
| Export Ranger DB (PostgreSQL) | État actuel en production |
| Ranger Audit Log (OpenMetadata) | Traçabilité des accès et modifications |

---

## Procédure de rollback — via Git (recommandée)

### Étape 1 — Identifier la politique problématique
```bash
# Lister les politiques actives et leur version
curl -u "${RANGER_ADMIN_USER}:${RANGER_ADMIN_PASSWORD}" \
  -H "Content-Type: application/json" \
  "https://ranger.lakehouse-data.svc.cluster.local:6182/service/public/v2/api/policy" \
  | jq '.[] | {id: .id, name: .name, version: .version, updatedBy: .updatedBy, updateTime: .updateTime}'
```

### Étape 2 — Consulter l'historique Git
```bash
cd /workspaces/open-lakehouse-platform
git log --oneline security/ranger/policies/
git show <COMMIT_HASH>:security/ranger/policies/schema-access.json
```

### Étape 3 — Revenir à la version Git précédente
```bash
# Restaurer la version précédente d'un fichier de politique
git checkout <COMMIT_HASH_BEFORE_INCIDENT> -- security/ranger/policies/schema-access.json

# Vérifier le diff
git diff HEAD security/ranger/policies/schema-access.json
```

### Étape 4 — Réimporter la politique
```bash
cd /workspaces/open-lakehouse-platform
./security/ranger/import-policies.sh \
  --host "https://ranger.lakehouse-data.svc.cluster.local:6182" \
  --policy-file security/ranger/policies/schema-access.json
```

### Étape 5 — Vérifier l'application
```bash
# Tester qu'un utilisateur data-analyst ne peut plus lire la table sensible
curl -u "${RANGER_ADMIN_USER}:${RANGER_ADMIN_PASSWORD}" \
  "https://ranger.lakehouse-data.svc.cluster.local:6182/service/public/v2/api/policy" \
  | jq '.[] | select(.name == "schema-access") | {version: .version, items: .policyItems}'
```

### Étape 6 — Committer le rollback
```bash
git add security/ranger/policies/schema-access.json
git commit -m "revert: rollback schema-access policy to pre-incident state (incident #XXX)"
git push origin main
```

---

## Procédure de rollback — via export Ranger DB (rollback d'urgence)

Si la politique Git est également corrompue ou inconnue :

### Étape 1 — Exporter toutes les politiques actuelles
```bash
curl -u "${RANGER_ADMIN_USER}:${RANGER_ADMIN_PASSWORD}" \
  "https://ranger.lakehouse-data.svc.cluster.local:6182/service/public/v2/api/policy/exportJson" \
  -o /tmp/ranger-policies-backup-$(date +%Y%m%d-%H%M%S).json
```

### Étape 2 — Identifier la dernière bonne snapshot
Les snapshots automatiques (journalières) sont stockées dans MinIO :
```bash
aws s3 ls s3://lakehouse-audit/ranger-policy-snapshots/ --recursive | sort | tail -20
aws s3 cp s3://lakehouse-audit/ranger-policy-snapshots/<DATE>/policies-export.json /tmp/ranger-good-policies.json
```

### Étape 3 — Importer la bonne snapshot
```bash
curl -u "${RANGER_ADMIN_USER}:${RANGER_ADMIN_PASSWORD}" \
  -X POST \
  -H "Content-Type: application/json" \
  -d @/tmp/ranger-good-policies.json \
  "https://ranger.lakehouse-data.svc.cluster.local:6182/service/public/v2/api/policy/importPoliciesFromFile?isOverride=true"
```

---

## Rollback d'une politique de row-filter ou column-mask

> **Attention** : modifier une politique de masquage peut exposer des données PII.

### Étape 1 — Identifier la politique de masquage
```bash
curl -u "${RANGER_ADMIN_USER}:${RANGER_ADMIN_PASSWORD}" \
  "https://ranger.lakehouse-data.svc.cluster.local:6182/service/public/v2/api/policy?policyType=1" \
  | jq '.[] | {id: .id, name: .name, dataMaskPolicyItems: .dataMaskPolicyItems}'
```

### Étape 2 — Bannir immédiatement les sessions Trino actives (si fuite confirmée)
```bash
# Tuer toutes les requêtes Trino actives
kubectl exec -n lakehouse-data trino-coordinator-0 -- \
  curl -X DELETE http://localhost:8080/v1/query --data-urlencode "user=admin"
```

### Étape 3 — Appliquer le rollback de la politique
Même procédure que ci-dessus (via Git ou snapshot).

### Étape 4 — Invalider le cache Ranger dans Trino
```bash
# Forcer la synchronisation des politiques
kubectl exec -n lakehouse-data trino-coordinator-0 -- \
  curl -X POST http://localhost:8080/v1/ranger/refresh
```

---

## Vérification post-rollback

```bash
# Test d'accès refusé pour data-analyst sur table PII
trino --server https://trino-gateway.lakehouse-data.svc.cluster.local:8443 \
  --user alice --role data-analyst \
  --execute "SELECT ssn, credit_card FROM lakehouse.curated.customers LIMIT 1" \
  && echo "FAIL — access should be denied" || echo "OK — access correctly denied"

# Test d'accès colonne masquée
trino --server https://trino-gateway.lakehouse-data.svc.cluster.local:8443 \
  --user alice --role data-analyst \
  --execute "SELECT email FROM lakehouse.curated.customers LIMIT 1" \
  | grep -q "SHA256\|PARTIAL\|NULL" && echo "OK — masking active" || echo "FAIL — masking not applied"
```

---

## Audit post-incident

```bash
# Consulter les accès pendant la fenêtre de l'incident dans Ranger Audit
curl -u "${RANGER_ADMIN_USER}:${RANGER_ADMIN_PASSWORD}" \
  "https://ranger.lakehouse-data.svc.cluster.local:6182/service/public/v2/api/assets/accessAudit" \
  | jq --arg start "<INCIDENT_START>" --arg end "<INCIDENT_END>" \
    '.vXAccessAudits[] | select(.eventTime >= $start and .eventTime <= $end)'
```

---

## Escalade

| Niveau | Contact | Déclencheur |
|--------|---------|-------------|
| Data Governance Lead | Slack `#data-governance` | Tout rollback |
| CISO | Email `security@` | Exposition confirmée de données PII |
| DPO | Email `dpo@` | Breach RGPD potentielle (délai 72h CNIL) |
