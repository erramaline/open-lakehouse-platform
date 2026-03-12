# Runbook — Security Incident Response

**Severité:** Variable (P1 par défaut jusqu'à qualification)  
**Propriétaire:** CISO / Platform Engineering  
**Dernière révision:** 2026-03-12  
**Référence:** NIST SP 800-61r2, ISO 27035

---

## Objectif

Ce runbook décrit le processus de réponse aux incidents de sécurité sur la plateforme Open Lakehouse. Il couvre la détection, la qualification, le confinement, l'éradication, la restauration, et le retour d'expérience (RETEX).

**SLO de réponse :**
| Sévérité | Détection → Qualification | Qualification → Confinement |
|----------|--------------------------|----------------------------|
| P1 (Critique) | < 15 min | < 1h |
| P2 (Élevée) | < 1h | < 4h |
| P3 (Modérée) | < 4h | < 24h |

---

## Contact d'urgence

| Rôle | Contact | Disponibilité |
|------|---------|--------------|
| Platform Engineering Oncall | PagerDuty `platform-oncall` | 24/7 |
| Security Oncall | PagerDuty `security-oncall` | 24/7 |
| CISO | `ciso@company.com` + appel direct | Sur escalade P1/P2 |
| DPO | `dpo@company.com` | Sur incident données personnelles |
| Legal | `legal@company.com` | Sur incident breach |

---

## Phase 1 — Détection & Triage

### Sources d'alertes

| Source | Type d'alerte |
|--------|--------------|
| Prometheus/Alertmanager | Anomalies métriques (CPU spike, erreurs 5xx, trafic anormal) |
| Loki/Promtail | Patterns suspects dans les logs (brute force, injection, accès anormal) |
| OpenTelemetry | Traces d'accès non autorisés |
| Ranger Audit | Accès refusés répétés, changements de politique anormaux |
| Keycloak Events | Échecs d'authentification, création de comptes non prévue |
| OpenBao Audit | Accès à des paths sensibles, tentatives d'escalade |

### Qualification initiale (< 15 min)

Répondre à ces questions :
1. **Quoi ?** — Quel composant est affecté ? (Keycloak, Trino, MinIO, OpenBao, Ranger...)
2. **Qui ?** — Quelle identité (utilisateur, service account, IP source) est impliquée ?
3. **Quand ?** — Début de l'incident (timestamp précis)
4. **Périmètre ?** — S'agit-il d'un test de pénétration autorisé ? d'une erreur opérationnelle ? d'une attaque ?
5. **Données ?** — Des données sensibles (PII, secrets) ont-elles été exposées ou volées ?

### Créer un channel d'incident
```
Slack : #incident-YYYYMMDD-<description-courte>
Ticket Jira : SEC-XXXX (template "Security Incident")
```

---

## Phase 2 — Confinement

### Scénario A — Compte utilisateur compromis

```bash
# 1. Désactiver immédiatement le compte Keycloak (voir runbook keycloak-user-offboarding.md)
# 2. Révoquer toutes les sessions
# 3. Rotation des credentials si le compte avait accès aux secrets OpenBao
./security/openbao/secret-rotation/rotate-all.sh
```

### Scénario B — Service account / AppRole compromis

```bash
# Identifier quel service est compromis
bao audit log | grep -i "suspicious-service-name"

# Révoquer le secret_id immédiatement
export BAO_TOKEN="${ROOT_TOKEN}"
bao write -f auth/approle/role/<SERVICE>-role/secret-id-accessor/destroy \
  secret_id_accessor=<ACCESSOR_ID>

# Regénérer un nouveau secret_id
./scripts/bootstrap/01-init-openbao.sh --regenerate-approle <SERVICE>
```

### Scénario C — Tentative d'injection SQL / XSS

```bash
# Couper l'accès réseau au composant affecté via NetworkPolicy
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: emergency-isolation-<SERVICE>
  namespace: lakehouse-data
spec:
  podSelector:
    matchLabels:
      app: <SERVICE>
  policyTypes: [Ingress, Egress]
EOF

# Logger l'isolation pour audit
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) — Emergency isolation applied to <SERVICE>" \
  >> /tmp/incident-timeline.log
```

### Scénario D — Accès non autorisé à MinIO (exfiltration de données)

```bash
# 1. Suspendre l'accès réseau externe à MinIO
kubectl patch service minio -n lakehouse-storage \
  -p '{"spec":{"selector":{"app":"minio-isolated"}}}'
# (Cette opération coupe le trafic vers MinIO sans le supprimer)

# 2. Rotation des clés d'accès MinIO
./security/openbao/secret-rotation/rotate-minio-keys.sh

# 3. Activer la collecte de logs S3 étendue
kubectl exec -n lakehouse-storage minio-0 -- \
  mc admin trace myminio -v --call s3 > /tmp/minio-trace-$(date +%Y%m%d-%H%M%S).log &

# 4. Identifier les objets accédés
kubectl exec -n lakehouse-storage minio-0 -- \
  mc admin logs myminio --last 24h | grep -i "GET\|DELETE\|PUT" | grep -v "200 OK"
```

### Scénario E — Compromission de secrets OpenBao

```bash
# Sceller OpenBao immédiatement (DRASTIQUE — tous les services perdent l'accès aux secrets)
export BAO_TOKEN="${ROOT_TOKEN}"
bao operator seal

# Notifier le CISO immédiatement
# Démarrer la procédure de récupération (voir runbook openbao-unseal-recovery.md)
# Effectuer une rotation complète des clés de déchiffrement (re-init del cluster)
```

### Scénario F — Fuite de certificat TLS privé

```bash
# 1. Révoquer le certificat compromis via OpenBao PKI
bao write pki/revoke serial_number=<SERIAL_NUMBER>

# 2. Supprimer le secret TLS Kubernetes pour forcer le renouvellement
kubectl delete secret <SERVICE>-tls -n <NAMESPACE>
# cert-manager renouveliera automatiquement

# 3. Mettre à jour la CRL (Certificate Revocation List)
bao write pki/tidy tidy_revoked_certs=true safety_buffer=1h
```

---

## Phase 3 — Éradication

### Nettoyer les artefacts malveillants

```bash
# Scanner les images de containers pour des binaires suspects
kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.spec.containers[*].image}{"\n"}{end}' \
  | while read NS POD IMAGE; do
    echo "Scanning ${NS}/${POD} (${IMAGE})..."
    kubectl exec -n "${NS}" "${POD}" -- find / -name "*.sh" -newer /proc/1 -not -path "/proc/*" 2>/dev/null
  done
```

### Vérifier l'intégrité des politiques Ranger

```bash
# Comparer les politiques en production avec Git
./security/ranger/import-policies.sh --dry-run --diff
```

### Vérifier l'intégrité du realm Keycloak

```bash
# Exporter le realm actuel et comparer avec la version Git
curl -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  "https://keycloak.lakehouse-system.svc.cluster.local:8443/admin/realms/lakehouse" \
  > /tmp/current-realm.json

diff <(jq -S '.' security/keycloak/realm-config/realm.json) \
     <(jq -S '.' /tmp/current-realm.json) | head -50
```

---

## Phase 4 — Restauration

### Ordre de restauration recommandé

1. **OpenBao** — désceller et vérifier les secrets (runbook `openbao-unseal-recovery.md`)
2. **Keycloak** — vérifier le realm et les utilisateurs
3. **TLS** — vérifier et renouveler les certificats si nécessaire (runbook `tls-cert-renewal.md`)
4. **Ranger** — vérifier et restaurer les politiques (runbook `ranger-policy-rollback.md`)
5. **Services de données** — Trino, Polaris, Nessie
6. **Services d'ingestion** — Airflow, OpenMetadata, Docling
7. **Observabilité** — Prometheus, Grafana, Loki, Alertmanager

### Checklist de restauration

```bash
# Vérifier que tous les services répondent
for SVC in trino-coordinator ranger keycloak openbao minio postgresql; do
  echo -n "Testing ${SVC}... "
  kubectl get pod -A -l app="${SVC}" --field-selector=status.phase=Running \
    | grep -q Running && echo "UP" || echo "DOWN"
done
```

---

## Phase 5 — Communication

### Communication interne (P1/P2)
- **Immédiat** : Slack `#security-incidents` + PagerDuty
- **30 min** : Mise à jour du ticket Jira SEC-XXXX, notification au CISO
- **2h** : Rapport préliminaire (périmètre, confinement, prochaines étapes)

### Communication externe (si données clients exposées)
La notification RGPD est obligatoire sous **72h** à la CNIL si des données personnelles sont affectées :
```
Contact DPO : dpo@company.com
Contact CNIL : https://notifications.cnil.fr/notifications/index
Délai légal : 72h après prise de connaissance de la violation
```

---

## Phase 6 — RETEX (Post-Incident Review)

À effectuer dans les **5 jours ouvrés** suivant la résolution :

### Template de rapport RETEX
```markdown
# RETEX — Incident SEC-XXXX — [DATE]

## Résumé exécutif
- Date/heure de détection :
- Date/heure de résolution :
- Durée totale :
- Données affectées (oui/non, quelles données) :
- Utilisateurs/services affectés :

## Chronologie détaillée
[Liste timestampée de chaque action]

## Causes racines
[5 pourquoi, arbre des causes]

## Impact
- Disponibilité (SLA breach ?)
- Confidentialité (données exposées ?)
- Intégrité (données modifiées ?)

## Mesures correctives
| Action | Responsable | Délai |
|--------|-------------|-------|
| ...    | ...         | ...   |

## Mesures préventives
[Actions pour éviter la récurrence]
```

---

## Préservation des preuves

```bash
# Collecter les logs de tous les composants avant rotation
INCIDENT_DIR="/tmp/incident-$(date +%Y%m%d)"
mkdir -p "${INCIDENT_DIR}"

# Logs Kubernetes
kubectl logs -n lakehouse-system openbao-0 --since=24h > "${INCIDENT_DIR}/openbao.log"
kubectl logs -n lakehouse-system keycloak-0 --since=24h > "${INCIDENT_DIR}/keycloak.log"
kubectl logs -n lakehouse-data ranger-admin-0 --since=24h > "${INCIDENT_DIR}/ranger.log"

# Audit OpenBao
export BAO_TOKEN="${ROOT_TOKEN}"
bao audit list > "${INCIDENT_DIR}/openbao-audit-devices.txt"

# Audit Ranger
curl -u "${RANGER_ADMIN_USER}:${RANGER_ADMIN_PASSWORD}" \
  "https://ranger.lakehouse-data.svc.cluster.local:6182/service/public/v2/api/assets/accessAudit?startDate=$(date -d '24 hours ago' +%Y-%m-%dT%H:%M:%S)" \
  > "${INCIDENT_DIR}/ranger-audit.json"

# Archiver et chiffrer
tar czf "${INCIDENT_DIR}.tar.gz" "${INCIDENT_DIR}"
gpg --encrypt --recipient "ciso@company.com" "${INCIDENT_DIR}.tar.gz"

# Uploader en lieu sûr
aws s3 cp "${INCIDENT_DIR}.tar.gz.gpg" \
  "s3://lakehouse-audit/incidents/$(date +%Y%m%d)-incident-evidence.tar.gz.gpg"

echo "Preuves archivées et chiffrées : ${INCIDENT_DIR}.tar.gz.gpg"
```
