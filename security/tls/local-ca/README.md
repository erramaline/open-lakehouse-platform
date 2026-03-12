# Local CA — TLS Certificate Management

This directory contains scripts to manage a **local development Root Certificate Authority (CA)** for the Open Lakehouse Platform. All service-to-service TLS in local Docker Compose is secured with certificates signed by this CA.

> **Security note:** This CA is for **local development only**. The Root CA private key lives in `output/rootCA.key`. Never commit this file. Never use these certificates in staging or production — use cert-manager + OpenBao PKI for real environments.

---

## Quick Start

```bash
# 1. Generate Root CA (once)
./generate-ca.sh

# 2. Generate certs for all services
./generate-all-certs.sh

# 3. Copy to docker-compose volume mount dirs
rsync -a output/ ../../local/volumes/tls/

# 4. Trust the Root CA on your machine (see section below)
```

---

## Scripts

### `generate-ca.sh`

Creates the Root CA key pair.

**Outputs:**
- `output/rootCA.key` — 4096-bit RSA private key (mode 600, keep secret)
- `output/rootCA.crt` — Self-signed Root CA certificate (10-year validity)
- `output/rootCA.srl` — Serial number tracker

**Idempotent:** If the CA already exists and is valid, the script skips regeneration.

```bash
# Default output dir: ./output
./generate-ca.sh

# Custom output dir
CA_DIR=/opt/lakehouse/tls ./generate-ca.sh
```

---

### `generate-service-cert.sh <service-name> <san>`

Signs a TLS certificate for one service using the Root CA.

**Arguments:**
- `service-name` — used as the output subdirectory name and CN (e.g., `trino-coordinator`)
- `san` — comma-separated Subject Alternative Names (RFC 5280 format)

**Outputs** (in `output/<service-name>/`):
- `server.key` — 2048-bit RSA private key (mode 600)
- `server.csr` — Certificate signing request
- `server.crt` — Signed certificate (90-day validity)
- `fullchain.crt` — `server.crt` + `rootCA.crt` (use this for TLS servers)

**Idempotent:** If the certificate exists and has more than 14 days of validity remaining, it is skipped.

```bash
# Single service
./generate-service-cert.sh trino-coordinator \
    "DNS:trino-coordinator,DNS:localhost,IP:127.0.0.1"

# Custom validity (days)
CERT_DAYS=365 ./generate-service-cert.sh polaris "DNS:polaris,DNS:localhost"
```

---

### `generate-all-certs.sh`

Calls `generate-service-cert.sh` for every service in the compose stack.

**Services covered:** minio-{1..4}, postgresql, pgbouncer, openbao-{1..3}, keycloak, polaris, nessie, ranger-admin, trino-coordinator, trino-worker-{1..3}, trino-gateway, elasticsearch, openmetadata-server, airflow-webserver, docling-api, prometheus, grafana, loki, otel-collector (25 services total).

```bash
./generate-all-certs.sh

# Override validity for all certs
CERT_DAYS=365 ./generate-all-certs.sh
```

---

## How to Trust the Root CA

### macOS

```bash
sudo security add-trusted-cert \
    -d -r trustRoot \
    -k /Library/Keychains/System.keychain \
    output/rootCA.crt
```

### Ubuntu / Debian

```bash
sudo cp output/rootCA.crt /usr/local/share/ca-certificates/lakehouse-local-ca.crt
sudo update-ca-certificates
```

### Fedora / RHEL / CentOS

```bash
sudo cp output/rootCA.crt /etc/pki/ca-trust/source/anchors/lakehouse-local-ca.crt
sudo update-ca-trust extract
```

### Windows (PowerShell as Administrator)

```powershell
Import-Certificate -FilePath "output\rootCA.crt" `
    -CertStoreLocation "Cert:\LocalMachine\Root"
```

---

## Adding a New Service Certificate

1. Open `generate-all-certs.sh`.
2. Add a new entry to the `SERVICES` array:
   ```bash
   "my-new-service"
       "DNS:my-new-service,DNS:localhost,IP:127.0.0.1"
   ```
3. Run `./generate-all-certs.sh` (existing certs are skipped, only new one generated).
4. Mount `output/my-new-service/` into the container at the appropriate path.
5. Add the mount to `local/docker-compose.yml`.

For Kubernetes/cert-manager issuance, see `../cert-manager/` instead — do not use these local CA scripts for K8s environments.

---

## Certificate Validity and Renewal

| Parameter | Default | Override |
|---|---|---|
| Root CA validity | 10 years (3650 days) | `CA_DAYS=7300 ./generate-ca.sh` |
| Service cert validity | 90 days | `CERT_DAYS=365 ./generate-all-certs.sh` |
| Renewal trigger | < 14 days remaining | Script automatically regenerates |

Run `./generate-all-certs.sh` again before expiry — it will only regenerate near-expiry certs.

---

## Security Model

```
Root CA (generate-ca.sh)
    │ signs (90 days)
    ├── minio-{1..4}/server.crt          (serverAuth + clientAuth)
    ├── postgresql/server.crt
    ├── openbao-{1..3}/server.crt
    ├── keycloak/server.crt
    ├── polaris/server.crt
    ├── nessie/server.crt
    ├── ranger-admin/server.crt
    ├── trino-coordinator/server.crt     (also used as client cert to Ranger)
    ├── trino-worker-{1..3}/server.crt
    ├── trino-gateway/server.crt
    ├── elasticsearch/server.crt
    ├── openmetadata-server/server.crt
    ├── airflow-webserver/server.crt
    ├── docling-api/server.crt
    ├── prometheus/server.crt
    ├── grafana/server.crt
    ├── loki/server.crt
    └── otel-collector/server.crt
```

All certs include `extendedKeyUsage = serverAuth, clientAuth` — they can be used for both server TLS and client certificate authentication (mTLS).

---

## Gitignore

The following files are excluded from version control (see `.gitignore`):

```
security/tls/local-ca/output/
```

**Never commit:** `rootCA.key`, `server.key`, or any `*.pem` private key files.
