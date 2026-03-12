# Runbook — Keycloak User Offboarding

**Severité:** P2 (P1 si l'utilisateur est compromis ou malveillant)  
**Propriétaire:** Platform Engineering / IAM Team  
**Dernière révision:** 2026-03-12  
**ADR de référence:** ADR-007 (Identity Federation Keycloak)

---

## Contexte

Keycloak est le fournisseur d'identité central pour tous les services de la plateforme. Un offboarding doit être exécuté dans les **24 heures** suivant la notification RH (ou **immédiatement** en cas de départ non-standard). L'offboarding révoque tous les accès : sessions actives, tokens OIDC, accès Ranger, secrets OpenBao.

Utilisateurs du realm `lakehouse` : `alice`, `bob`, `carol`, `dan`, `mallory` (et tout futur utilisateur).  
Rôles disponibles : `data-engineer`, `data-analyst`, `data-steward`, `platform-admin`.

---

## Checklist d'offboarding standard

- [ ] Désactiver le compte utilisateur dans Keycloak
- [ ] Révoquer toutes les sessions actives
- [ ] Supprimer les rôles Ranger assignés
- [ ] Vérifier les accès MinIO (service accounts)
- [ ] Vérifier les variables d'environnement Airflow (si DAG owner)
- [ ] Audit des accès des 30 derniers jours
- [ ] Confirmer la révocation avec le manager et la RH

---

## Procédure d'offboarding — via API Keycloak (recommandée)

### Pré-requis
```bash
export KEYCLOAK_URL="https://keycloak.lakehouse-system.svc.cluster.local:8443"
export REALM="lakehouse"

# Obtenir un token admin
ADMIN_TOKEN=$(curl -s -X POST \
  "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "client_id=admin-cli&grant_type=password&username=${KEYCLOAK_ADMIN_USER}&password=${KEYCLOAK_ADMIN_PASSWORD}" \
  | jq -r .access_token)
```

### Étape 1 — Identifier l'utilisateur
```bash
USER_ID=$(curl -s \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/users?username=<USERNAME>" \
  | jq -r '.[0].id')

echo "User ID: ${USER_ID}"
# Vérifier les attributs
curl -s -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${USER_ID}" | jq '{username, email, enabled, roles: .realmRoles}'
```

### Étape 2 — Désactiver le compte (ne pas supprimer)
> Désactiver plutôt que supprimer préserve la traçabilité d'audit.

```bash
curl -s -X PUT \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"enabled": false}' \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${USER_ID}"

echo "Account disabled."
```

### Étape 3 — Révoquer toutes les sessions actives
```bash
# Déconnecter toutes les sessions
curl -s -X POST \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${USER_ID}/logout"

# Vérifier qu'il n'y a plus de sessions
curl -s -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${USER_ID}/sessions" | jq 'length'
# Attendu : 0
```

### Étape 4 — Révoquer les tokens offline (refresh tokens longue durée)
```bash
curl -s -X DELETE \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${USER_ID}/offline-sessions"
```

### Étape 5 — Supprimer les rôles Keycloak
```bash
# Lister les rôles assignés
curl -s -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${USER_ID}/role-mappings/realm" \
  | jq '.[].name'

# Supprimer tous les rôles realm
ROLES=$(curl -s -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${USER_ID}/role-mappings/realm")

curl -s -X DELETE \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${ROLES}" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${USER_ID}/role-mappings/realm"
```

---

## Révocation des accès Ranger

### Étape 1 — Retirer l'utilisateur de tous les groupes Ranger
```bash
# Lister les politiques Ranger contenant l'utilisateur
curl -u "${RANGER_ADMIN_USER}:${RANGER_ADMIN_PASSWORD}" \
  "https://ranger.lakehouse-data.svc.cluster.local:6182/service/public/v2/api/policy" \
  | jq --arg user "<USERNAME>" \
    '.[] | select(.policyItems[].users[]? == $user) | {id: .id, name: .name}'
```

### Étape 2 — Mettre à jour les politiques Ranger
Éditer le fichier de politique correspondant dans `security/ranger/policies/` pour retirer `<USERNAME>` de tout `users` array, puis réimporter :
```bash
./security/ranger/import-policies.sh
```

---

## Vérification des accès MinIO

```bash
# Vérifier si l'utilisateur possède un compte MinIO
mc admin user list myminio | grep <USERNAME> || echo "No MinIO user account found."

# Si un compte existe, le désactiver immédiatement
mc admin user disable myminio <USERNAME>

# Vérifier et retirer les accès service account
mc admin user svcacct list myminio <USERNAME>
mc admin user svcacct rm myminio <ACCESSKEY>
```

---

## Vérification des DAGs Airflow

```bash
# Lister les DAGs dont l'owner est l'utilisateur partant
kubectl exec -n lakehouse-ingest airflow-webserver-0 -- \
  airflow dags list | grep <USERNAME>

# Transférer la propriété si nécessaire (éditer le fichier DAG)
# Ou pauser les DAGs orphelins
kubectl exec -n lakehouse-ingest airflow-webserver-0 -- \
  airflow dags pause <DAG_ID>
```

---

## Audit des 30 derniers jours

```bash
# Extraire les accès depuis Ranger Audit
START_DATE=$(date -d "30 days ago" +%Y-%m-%dT%H:%M:%S)
curl -u "${RANGER_ADMIN_USER}:${RANGER_ADMIN_PASSWORD}" \
  "https://ranger.lakehouse-data.svc.cluster.local:6182/service/public/v2/api/assets/accessAudit?startDate=${START_DATE}&user=<USERNAME>" \
  | jq '.vXAccessAudits[] | {time: .eventTime, table: .resourcePath, action: .accessType, result: .accessResult}' \
  > /tmp/offboarding-audit-<USERNAME>-$(date +%Y%m%d).json

echo "Audit enregistré dans /tmp/offboarding-audit-<USERNAME>-$(date +%Y%m%d).json"
```

Joindre ce fichier au ticket RH de départ.

---

## Cas particulier — Offboarding d'urgence (départ hostile)

En cas de départ hostile ou de compromission de compte :

1. **Immédiat (< 5 min)** : Désactiver le compte Keycloak (Étape 2 ci-dessus)
2. **Immédiat** : Révoquer les sessions (Étape 3)
3. **< 15 min** : Rotation des secrets OpenBao pour tout service auquel l'utilisateur avait accès :
   ```bash
   ./security/openbao/secret-rotation/rotate-all.sh
   ```
4. **< 30 min** : Retirer des politiques Ranger
5. **< 1h** : Audit complet des accès depuis 90 jours
6. **Notifier** : CISO, DPO (si données personnelles accédées), RH

---

## Vérification finale

```bash
# Confirmer que le compte est bien désactivé
curl -s -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${USER_ID}" \
  | jq '{username, enabled}'
# Attendu : "enabled": false

# Confirmer aucune session active
curl -s -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  "${KEYCLOAK_URL}/admin/realms/${REALM}/users/${USER_ID}/sessions" | jq 'length'
# Attendu : 0

# Test négatif — la connexion doit échouer
curl -s -X POST \
  "${KEYCLOAK_URL}/realms/${REALM}/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "client_id=trino&grant_type=password&username=<USERNAME>&password=<ANY_PASSWORD>&client_secret=${TRINO_CLIENT_SECRET}" \
  | jq .error
# Attendu : "invalid_grant" ou "account_disabled"
```

---

## Escalade

| Scénario | Contact |
|----------|---------|
| Offboarding standard | IAM Team (ticket Jira) |
| Départ hostile ou compte compromis | CISO immédiatement + PagerDuty `security-oncall` |
| Données personnelles potentiellement exposées | DPO sous 24h, CNIL sous 72h si breach avéré |
