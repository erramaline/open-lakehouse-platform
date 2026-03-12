# Runbook — Renouvellement de Certificats TLS

**Severité:** P2 (P1 si expiration imminente < 7 jours)  
**Propriétaire:** Platform Engineering  
**Dernière révision:** 2026-03-12  
**ADR de référence:** ADR-006 (mTLS Strategy)

---

## Contexte

La plateforme utilise deux types de certificats TLS :

| Type | Émetteur | Gestion | Durée |
|------|----------|---------|-------|
| **Production (K8s)** | cert-manager + OpenBao PKI | Automatique (autorenew) | 90 jours |
| **Local/Dev** | CA locale (`security/tls/local-ca/`) | Manuel (`generate-all-certs.sh`) | 365 jours |

Le renouvellement automatique via cert-manager se déclenche **30 jours avant expiration** (60 jours de vie restants). Ce runbook couvre les cas de défaillance de l'autorenew et le renouvellement manuel local.

---

## Monitoring des certificats

### Alertes configurées (Prometheus)
- `CertificateExpiryWarning` : expiration dans < 30 jours → Slack
- `CertificateExpiryCritical` : expiration dans < 7 jours → PagerDuty
- `CertificateExpired` : certificat expiré → PagerDuty P1 immédiat

### Vérification manuelle de l'état des certificats (K8s)
```bash
kubectl get certificates -A
kubectl get certificaterequests -A
```

Vérifier les colonnes `READY`, `SECRET`, `EXPIRATION`. Un certificat `READY=False` nécessite une investigation immédiate.

### Vérifier la date d'expiration d'un secret TLS
```bash
kubectl get secret trino-coordinator-tls -n lakehouse-data \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | \
  openssl x509 -noout -dates -subject
```

---

## Procédure — Renouvellement automatique défaillant (cert-manager)

### Étape 1 — Diagnostiquer la cause
```bash
# Lister les CertificateRequests en erreur
kubectl get certificaterequests -A | grep -v True

# Obtenir les détails
kubectl describe certificaterequest trino-coordinator-tls-XXXXX -n lakehouse-data
```

Causes fréquentes :
- OpenBao PKI non disponible (voir runbook `openbao-unseal-recovery.md`)
- Role PKI expiré ou mal configuré
- Quota de certificats atteint

### Étape 2 — Forcer le renouvellement manuellement
```bash
# Supprimer le secret TLS pour forcer cert-manager à en créer un nouveau
kubectl delete secret trino-coordinator-tls -n lakehouse-data

# cert-manager crée automatiquement un nouveau CertificateRequest
kubectl wait --for=condition=Ready certificate/trino-coordinator-tls \
  -n lakehouse-data --timeout=120s
```

### Étape 3 — Vérifier le renouvellement
```bash
kubectl get secret trino-coordinator-tls -n lakehouse-data \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | \
  openssl x509 -noout -dates
```

### Étape 4 — Redémarrer le service si nécessaire
Certains services (Trino, Ranger) rechargent les certificats sans redémarrage. D'autres nécessitent un rolling restart :
```bash
kubectl rollout restart deployment/ranger-admin -n lakehouse-data
kubectl rollout status deployment/ranger-admin -n lakehouse-data
```

---

## Procédure — Renouvellement du certificat CA intermédiaire OpenBao PKI

> **Impact :** Tous les certificats signés par ce CA deviennent invalides. Planifier une fenêtre de maintenance.

### Étape 1 — Vérifier l'expiration du CA intermédiaire
```bash
export BAO_TOKEN="${ROOT_TOKEN}"
bao read pki/cert/ca | grep -A2 "expiration"
```

### Étape 2 — Générer un nouveau CA intermédiaire
```bash
# Générer CSR dans OpenBao
bao write pki/intermediate/generate/internal \
  common_name="OpenLakehouse Intermediate CA" \
  ttl="43800h" \
  key_type="rsa" key_bits=4096 \
  -format=json | jq -r .data.csr > /tmp/intermediate.csr

# Signer avec le root CA
bao write pki_root/root/sign-intermediate \
  csr=@/tmp/intermediate.csr \
  format=pem_bundle ttl="43800h" \
  -format=json | jq -r .data.certificate > /tmp/intermediate.pem

# Importer dans OpenBao
bao write pki/intermediate/set-signed certificate=@/tmp/intermediate.pem
```

### Étape 3 — Renouveler tous les certificats de service
```bash
# Forcer le renouvellement de tous les certificats via cert-manager
for NS in lakehouse-data lakehouse-system lakehouse-obs lakehouse-storage lakehouse-ingest; do
  kubectl get certificates -n "${NS}" -o name | while read CERT; do
    kubectl delete secret -n "${NS}" \
      "$(kubectl get "${CERT}" -n "${NS}" -o jsonpath='{.spec.secretName}')" 2>/dev/null || true
  done
done

# Attendre que tous soient Ready
kubectl wait --for=condition=Ready certificates --all -A --timeout=300s
```

---

## Procédure — Renouvellement des certificats locaux (développement)

### Étape 1 — Renouveler tous les certificats
```bash
cd /workspaces/open-lakehouse-platform
./security/tls/local-ca/generate-all-certs.sh --renew
```

### Étape 2 — Recharger les services Docker Compose
```bash
cd local/
docker compose -f docker-compose.yml \
              -f docker-compose.security.yml \
              restart
```

### Étape 3 — Vérifier la connectivité TLS
```bash
# Vérifier Trino
openssl s_client -connect localhost:8443 -CAfile security/tls/local-ca/ca.crt < /dev/null 2>&1 \
  | grep -E "Verify return code|subject"

# Vérifier MinIO
openssl s_client -connect localhost:9000 -CAfile security/tls/local-ca/ca.crt < /dev/null 2>&1 \
  | grep -E "Verify return code|subject"
```

---

## Renouvellement d'urgence — certificat expiré en production

Si un certificat est déjà expiré et bloque un service :

```bash
# 1. Générér un certificat de remplacement temporaire (valide 7 jours)
bao write pki/issue/lakehouse-intermediate \
  common_name="trino-coordinator.lakehouse-data.svc.cluster.local" \
  alt_names="trino,trino.lakehouse-data.svc.cluster.local" \
  ttl="168h" \
  -format=json > /tmp/emergency-cert.json

# 2. Extraire et injecter dans le secret Kubernetes
kubectl create secret tls trino-coordinator-tls-emergency \
  --cert=<(jq -r .data.certificate /tmp/emergency-cert.json) \
  --key=<(jq -r .data.private_key /tmp/emergency-cert.json) \
  -n lakehouse-data

# 3. Patcher le déploiement pour utiliser le secret d'urgence jusqu'au renouvellement normal
kubectl patch deployment trino-coordinator -n lakehouse-data \
  --type='json' \
  -p='[{"op":"replace","path":"/spec/template/spec/volumes/0/secret/secretName","value":"trino-coordinator-tls-emergency"}]'

# 4. Investiguer et corriger cert-manager dans les 7 jours
# Voir procédure "Renouvellement automatique défaillant" ci-dessus
```

---

## Vérification post-intervention

```bash
# Vérifier tous les certificats
kubectl get certificates -A | awk '{if ($3 != "True") print $0}'

# Vérifier les connexions mTLS
./security/tls/local-ca/generate-all-certs.sh --verify
```

---

## Escalade

| Niveau | Contact | Déclencheur |
|--------|---------|-------------|
| Platform Engineering Oncall | PagerDuty `platform-oncall` | Expiration < 7 jours |
| Lead Platform Eng. | PagerDuty `platform-lead` | Certificat CA expiré ou compromis |
| CISO | Email `security@` | Certificat privé exposé (rotation immédiate) |
