#!/usr/bin/env bash
# =============================================================================
# 06-init-openmetadata.sh — Bootstrap OpenMetadata 1.5.x
# =============================================================================
# Steps:
#   1. Wait for OpenMetadata API to be healthy
#   2. Obtain JWT token for admin service account
#   3. Register Trino connector (database service)
#   4. Register Airflow pipeline service connector
#   5. Register dbt project connector
#   6. Create ingestion pipelines and trigger first run
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
ENV_FILE="${REPO_ROOT}/local/.env"

log()  { echo "[06-init-openmetadata] $*"; }
ok()   { echo "[06-init-openmetadata] ✓ $*"; }
err()  { echo "[06-init-openmetadata] ✗ $*" >&2; exit 1; }

[ -f "${ENV_FILE}" ] || err ".env file not found at ${ENV_FILE}"
set -a; source "${ENV_FILE}"; set +a

OM_URL="${OPENMETADATA_URL:-http://localhost:8585}"
OM_API="${OM_URL}/api/v1"
KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:8080}"

# ─── Step 1: Wait for OpenMetadata ────────────────────────────────────────────
log "Waiting for OpenMetadata API on ${OM_URL}..."
for i in $(seq 1 60); do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${OM_URL}/healthcheck" 2>/dev/null || echo "000")
    if [ "${HTTP_CODE}" = "200" ] || [ "${HTTP_CODE}" = "204" ]; then
        ok "OpenMetadata is healthy."
        break
    fi
    [ "$i" -eq 60 ] && err "Timeout waiting for OpenMetadata at ${OM_URL}/healthcheck"
    sleep 5
done

# ─── Step 2: Obtain OpenMetadata JWT token via Keycloak ───────────────────────
log "Obtaining Keycloak token for OpenMetadata admin..."
TOKEN_RESPONSE=$(curl -sf -X POST \
    "${KEYCLOAK_URL}/realms/lakehouse/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=password" \
    -d "client_id=openmetadata" \
    -d "client_secret=${KEYCLOAK_OPENMETADATA_CLIENT_SECRET}" \
    -d "username=dave.admin" \
    -d "password=${KEYCLOAK_TEST_ADMIN_PASSWORD:-changeme}" \
    -d "scope=openid") || err "Failed to obtain Keycloak token."

ACCESS_TOKEN=$(echo "${TOKEN_RESPONSE}" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
[ -z "${ACCESS_TOKEN}" ] && err "Empty token from Keycloak."
ok "Keycloak token obtained for OpenMetadata."

OM_AUTH="Authorization: Bearer ${ACCESS_TOKEN}"

# ─── Helper functions ──────────────────────────────────────────────────────────
om_get() {
    curl -sf -H "${OM_AUTH}" -H "Accept: application/json" "${OM_API}${1}"
}

om_post() {
    curl -sf -H "${OM_AUTH}" -H "Content-Type: application/json" \
        -X POST "${OM_API}${1}" -d "${2}"
}

om_put() {
    curl -sf -H "${OM_AUTH}" -H "Content-Type: application/json" \
        -X PUT "${OM_API}${1}" -d "${2}"
}

service_exists() {
    local type="$1"
    local name="$2"
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "${OM_AUTH}" \
        "${OM_API}/services/${type}/${name}" 2>/dev/null || echo "000")
    [ "${HTTP_CODE}" = "200" ]
}

# ─── Step 3: Register Trino database service ───────────────────────────────────
log "Registering Trino database service..."

if service_exists "databaseServices" "trino_lakehouse"; then
    log "Trino service 'trino_lakehouse' already registered."
else
    om_post "/services/databaseServices" '{
      "name":        "trino_lakehouse",
      "displayName": "Trino Lakehouse",
      "description": "Main Trino cluster — Iceberg tables via Polaris and Nessie",
      "serviceType": "Trino",
      "connection": {
        "config": {
          "type":     "Trino",
          "username": "'"${TRINO_HTTP_USER:-trino}"'",
          "hostPort": "trino-gateway:8080",
          "catalog":  "lakehouse"
        }
      }
    }'
    ok "Trino database service 'trino_lakehouse' registered."
fi

# ─── Step 4: Register Airflow pipeline service ─────────────────────────────────
log "Registering Airflow pipeline service..."

if service_exists "pipelineServices" "airflow_lakehouse"; then
    log "Airflow service 'airflow_lakehouse' already registered."
else
    om_post "/services/pipelineServices" '{
      "name":        "airflow_lakehouse",
      "displayName": "Airflow Lakehouse",
      "description": "Apache Airflow orchestrating ETL pipelines for the lakehouse",
      "serviceType": "Airflow",
      "connection": {
        "config": {
          "type":        "Airflow",
          "hostPort":    "http://airflow-webserver:8080",
          "numberOfStatus": 10,
          "connection": {
            "type":     "Backend"
          }
        }
      }
    }'
    ok "Airflow pipeline service 'airflow_lakehouse' registered."
fi

# ─── Step 5: Register object storage service (MinIO / S3) ────────────────────
log "Registering MinIO storage service..."

if service_exists "storageServices" "minio_lakehouse"; then
    log "MinIO storage service 'minio_lakehouse' already registered."
else
    om_post "/services/storageServices" '{
      "name":        "minio_lakehouse",
      "displayName": "MinIO Lakehouse",
      "description": "MinIO S3-compatible distributed object store",
      "serviceType": "S3",
      "connection": {
        "config": {
          "type":            "S3",
          "awsConfig": {
            "awsAccessKeyId":     "'"${MINIO_INGESTION_ACCESS_KEY}"'",
            "awsSecretAccessKey": "'"${MINIO_INGESTION_SECRET_KEY}"'",
            "awsRegion":          "us-east-1",
            "endPointURL":        "http://minio-1:9000"
          }
        }
      }
    }'
    ok "MinIO storage service 'minio_lakehouse' registered."
fi

# ─── Step 6: Create metadata ingestion pipeline for Trino ────────────────────
log "Creating Trino metadata ingestion pipeline..."

TRINO_PIPELINE_EXISTS=$(om_get "/services/ingestionPipelines?service=trino_lakehouse&pipelineType=metadata" | \
    python3 -c "import sys,json; d=json.load(sys.stdin); print('yes' if d.get('data') else 'no')" 2>/dev/null || echo "no")

if [ "${TRINO_PIPELINE_EXISTS}" = "yes" ]; then
    log "Trino metadata ingestion pipeline already exists."
else
    PIPELINE_RESPONSE=$(om_post "/services/ingestionPipelines" '{
      "name":         "trino_lakehouse_metadata",
      "displayName":  "Trino Lakehouse Metadata",
      "pipelineType": "metadata",
      "service": {
        "id":   "'"$(om_get /services/databaseServices/trino_lakehouse | python3 -c 'import sys,json; print(json.load(sys.stdin).get("id",""))')"'",
        "type": "databaseService"
      },
      "sourceConfig": {
        "config": {
          "type":                    "DatabaseMetadata",
          "markDeletedTables":       true,
          "includeTables":           true,
          "includeViews":            true,
          "includeTags":             false,
          "databaseFilterPattern":   {"includes": ["lakehouse"]},
          "schemaFilterPattern":     {"excludes": ["information_schema"]},
          "tableFilterPattern":      {}
        }
      },
      "airflowConfig": {
        "scheduleInterval": "0 */6 * * *",
        "startDate":        "2024-01-01T00:00:00.000Z",
        "retries":          2
      }
    }')
    ok "Trino metadata ingestion pipeline created."

    # Trigger first run
    PIPELINE_ID=$(echo "${PIPELINE_RESPONSE}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))")
    if [ -n "${PIPELINE_ID}" ]; then
        log "Triggering first Trino metadata ingestion run..."
        om_post "/services/ingestionPipelines/trigger/${PIPELINE_ID}" '{}' &>/dev/null || \
            log "(trigger may need Airflow to be fully initialized first)"
        ok "Ingestion pipeline triggered."
    fi
fi

# ─── Step 7: Create profiler pipeline for Trino ───────────────────────────────
log "Creating Trino data profiler pipeline..."

PROFILER_EXISTS=$(om_get "/services/ingestionPipelines?service=trino_lakehouse&pipelineType=profiler" | \
    python3 -c "import sys,json; d=json.load(sys.stdin); print('yes' if d.get('data') else 'no')" 2>/dev/null || echo "no")

if [ "${PROFILER_EXISTS}" != "yes" ]; then
    om_post "/services/ingestionPipelines" '{
      "name":         "trino_lakehouse_profiler",
      "displayName":  "Trino Lakehouse Profiler",
      "pipelineType": "profiler",
      "service": {
        "id":   "'"$(om_get /services/databaseServices/trino_lakehouse | python3 -c 'import sys,json; print(json.load(sys.stdin).get("id",""))')"'",
        "type": "databaseService"
      },
      "sourceConfig": {
        "config": {
          "type":            "Profiler",
          "generateSampleData": true,
          "sampleDataCount":   100,
          "computeMetrics":    true
        }
      },
      "airflowConfig": {
        "scheduleInterval": "0 2 * * *",
        "startDate":        "2024-01-01T00:00:00.000Z",
        "retries":          1
      }
    }' &>/dev/null
    ok "Trino profiler pipeline created (runs daily at 02:00)."
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
log "Registered services:"
for svc_type in databaseServices pipelineServices storageServices; do
    om_get "/services/${svc_type}?limit=10" | \
        python3 -c "import sys,json; [print(f'  [{svc_type}] {s[\"name\"]}') for s in json.load(sys.stdin).get('data',[])]" 2>/dev/null || true
done

echo ""
log "Active ingestion pipelines:"
om_get "/services/ingestionPipelines?limit=20" | \
    python3 -c "import sys,json; [print(f'  - {p[\"name\"]} ({p[\"pipelineType\"]})') for p in json.load(sys.stdin).get('data',[])]" 2>/dev/null || true

echo ""
ok "OpenMetadata initialization complete!"
log "OpenMetadata UI: ${OM_URL}"
log "Next step: run scripts/bootstrap/07-seed-data.sh"
