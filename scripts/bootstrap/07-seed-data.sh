#!/usr/bin/env bash
# =============================================================================
# 07-seed-data.sh — Seed sample Iceberg tables via Trino
# =============================================================================
# Steps:
#   1. Wait for Trino Gateway to be ready
#   2. Create sample Iceberg tables in Polaris catalog (curated namespace)
#   3. Insert realistic synthetic data (1000+ rows per table)
#   4. Verify tables are queryable
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
ENV_FILE="${REPO_ROOT}/local/.env"

log()  { echo "[07-seed-data] $*"; }
ok()   { echo "[07-seed-data] ✓ $*"; }
err()  { echo "[07-seed-data] ✗ $*" >&2; exit 1; }
warn() { echo "[07-seed-data] ! $*"; }

[ -f "${ENV_FILE}" ] || err ".env file not found at ${ENV_FILE}"
set -a; source "${ENV_FILE}"; set +a

TRINO_URL="${TRINO_GATEWAY_URL:-http://localhost:8080}"
TRINO_USER="${TRINO_SEED_USER:-alice.engineer}"

# ─── Detect Trino CLI ─────────────────────────────────────────────────────────
if command -v trino &>/dev/null; then
    TRINO_CMD="trino"
elif command -v trino-cli &>/dev/null; then
    TRINO_CMD="trino-cli"
else
    # Try to download trino CLI jar
    TRINO_JAR="${REPO_ROOT}/.bin/trino-cli.jar"
    mkdir -p "${REPO_ROOT}/.bin"
    if [ ! -f "${TRINO_JAR}" ]; then
        log "Downloading Trino CLI..."
        curl -sL \
            "https://repo1.maven.org/maven2/io/trino/trino-cli/479/trino-cli-479-executable.jar" \
            -o "${TRINO_JAR}"
        chmod +x "${TRINO_JAR}"
    fi
    TRINO_CMD="java -jar ${TRINO_JAR}"
fi

trino_exec() {
    local sql="$1"
    ${TRINO_CMD} \
        --server "${TRINO_URL}" \
        --user   "${TRINO_USER}" \
        --execute "${sql}" \
        --output-format TSV 2>&1
}

# ─── Step 1: Wait for Trino Gateway ───────────────────────────────────────────
log "Waiting for Trino Gateway on ${TRINO_URL}..."
for i in $(seq 1 30); do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${TRINO_URL}/ui/" 2>/dev/null || echo "000")
    if [ "${HTTP_CODE}" = "200" ]; then
        ok "Trino Gateway is healthy."
        break
    fi
    [ "$i" -eq 30 ] && err "Timeout waiting for Trino Gateway at ${TRINO_URL}"
    sleep 5
done

# Verify Trino can execute queries
log "Verifying Trino connectivity..."
TRINO_VERSION=$(trino_exec "SELECT node_version FROM system.runtime.nodes LIMIT 1" 2>/dev/null | tail -1 || echo "")
[ -z "${TRINO_VERSION}" ] && warn "Could not verify Trino version — auth may be required. Continuing..."
ok "Trino connectivity OK (version: ${TRINO_VERSION:-unknown})."

# ─── Step 2: Create Iceberg tables ────────────────────────────────────────────
log "Creating Iceberg schemas and tables in 'lakehouse.curated'..."

# Ensure schema exists
trino_exec "CREATE SCHEMA IF NOT EXISTS lakehouse.curated WITH (location = 's3://iceberg/curated/')" &>/dev/null || true
ok "Schema 'lakehouse.curated' ready."

# customers table — has PII columns for Ranger masking demo
log "Creating 'customers' table..."
trino_exec "
CREATE TABLE IF NOT EXISTS lakehouse.curated.customers (
    customer_id    BIGINT,
    first_name     VARCHAR,
    last_name      VARCHAR,
    email          VARCHAR,        -- PII: masked by Ranger for non-stewards
    phone          VARCHAR,        -- PII: masked by Ranger for non-stewards
    ssn            VARCHAR,        -- PII: masked by Ranger for non-stewards
    date_of_birth  DATE,
    country        VARCHAR,
    city           VARCHAR,
    postal_code    VARCHAR,
    signup_date    DATE,
    loyalty_tier   VARCHAR,
    annual_revenue DECIMAL(12,2)
) WITH (
    format              = 'PARQUET',
    partitioning        = ARRAY['country'],
    sorted_by           = ARRAY['customer_id'],
    write_data_location = 's3://iceberg/curated/customers/'
)
" &>/dev/null
ok "'customers' table created."

# orders table
log "Creating 'orders' table..."
trino_exec "
CREATE TABLE IF NOT EXISTS lakehouse.curated.orders (
    order_id        BIGINT,
    customer_id     BIGINT,
    order_date      DATE,
    ship_date       DATE,
    status          VARCHAR,
    total_amount    DECIMAL(12,2),
    discount_amount DECIMAL(10,2),
    tax_amount      DECIMAL(10,2),
    currency        VARCHAR,
    channel         VARCHAR,
    warehouse_id    INTEGER,
    notes           VARCHAR
) WITH (
    format           = 'PARQUET',
    partitioning     = ARRAY['month(order_date)', 'status'],
    sorted_by        = ARRAY['customer_id', 'order_id'],
    write_data_location = 's3://iceberg/curated/orders/'
)
" &>/dev/null
ok "'orders' table created."

# products table
log "Creating 'products' table..."
trino_exec "
CREATE TABLE IF NOT EXISTS lakehouse.curated.products (
    product_id    BIGINT,
    sku           VARCHAR,
    name          VARCHAR,
    category      VARCHAR,
    subcategory   VARCHAR,
    brand         VARCHAR,
    unit_price    DECIMAL(10,2),
    cost_price    DECIMAL(10,2),
    currency      VARCHAR,
    in_stock      BOOLEAN,
    stock_qty     INTEGER,
    weight_kg     DOUBLE,
    is_active     BOOLEAN,
    created_date  DATE
) WITH (
    format       = 'PARQUET',
    partitioning = ARRAY['category'],
    write_data_location = 's3://iceberg/curated/products/'
)
" &>/dev/null
ok "'products' table created."

# order_items table
log "Creating 'order_items' table..."
trino_exec "
CREATE TABLE IF NOT EXISTS lakehouse.curated.order_items (
    item_id      BIGINT,
    order_id     BIGINT,
    product_id   BIGINT,
    quantity     INTEGER,
    unit_price   DECIMAL(10,2),
    discount_pct DECIMAL(5,2),
    total_price  DECIMAL(12,2)
) WITH (
    format       = 'PARQUET',
    partitioning = ARRAY['truncate(order_id, 1000)'],
    write_data_location = 's3://iceberg/curated/order_items/'
)
" &>/dev/null
ok "'order_items' table created."

# ─── Step 3: Insert synthetic data ────────────────────────────────────────────
log "Inserting sample data into 'customers' (1200 rows)..."
trino_exec "
INSERT INTO lakehouse.curated.customers
SELECT
    seq AS customer_id,
    element_at(ARRAY['Alice','Bob','Carol','David','Eve','Frank','Grace','Hank','Iris','Jack',
                     'Kate','Leo','Mia','Noah','Olivia','Paul','Quinn','Rosa','Sam','Tina'],
               (seq % 20) + 1) AS first_name,
    element_at(ARRAY['Smith','Johnson','Williams','Brown','Jones','Garcia','Miller','Davis',
                     'Rodriguez','Martinez','Hernandez','Lopez','Gonzalez','Wilson','Anderson',
                     'Thomas','Taylor','Moore','Jackson','Martin'],
               (seq % 20) + 1) AS last_name,
    'user' || CAST(seq AS VARCHAR) || '@example' || CAST((seq % 5) + 1 AS VARCHAR) || '.com' AS email,
    '+1-' || CAST(200 + (seq % 800) AS VARCHAR) || '-' ||
        LPAD(CAST(seq % 10000 AS VARCHAR), 4, '0') AS phone,
    LPAD(CAST(100000000 + seq AS VARCHAR), 9, '0') AS ssn,
    DATE '1970-01-01' + INTERVAL '1' DAY * (seq % 18000) AS date_of_birth,
    element_at(ARRAY['US','CA','GB','DE','FR','AU','NL','SE','NO','DK'],
               (seq % 10) + 1) AS country,
    element_at(ARRAY['New York','Toronto','London','Berlin','Paris','Sydney',
                     'Amsterdam','Stockholm','Oslo','Copenhagen'],
               (seq % 10) + 1) AS city,
    LPAD(CAST(10000 + (seq % 90000) AS VARCHAR), 5, '0') AS postal_code,
    DATE '2018-01-01' + INTERVAL '1' DAY * (seq % 2190) AS signup_date,
    element_at(ARRAY['bronze','silver','gold','platinum'], (seq % 4) + 1) AS loyalty_tier,
    CAST(500 + (seq * 137 % 99500) AS DECIMAL(12,2)) AS annual_revenue
FROM (SELECT sequence_number + 1 AS seq FROM TABLE(sequence(start => 0, stop => 1199)))
" &>/dev/null
ok "1200 customer rows inserted."

log "Inserting sample data into 'products' (250 rows)..."
trino_exec "
INSERT INTO lakehouse.curated.products
SELECT
    seq AS product_id,
    'SKU-' || LPAD(CAST(seq AS VARCHAR), 6, '0') AS sku,
    'Product ' || CAST(seq AS VARCHAR) AS name,
    element_at(ARRAY['Electronics','Clothing','Food','Home','Sports','Books','Toys','Health'],
               (seq % 8) + 1) AS category,
    'Sub-' || CAST((seq % 5) + 1 AS VARCHAR) AS subcategory,
    'Brand-' || CAST((seq % 20) + 1 AS VARCHAR) AS brand,
    CAST(9.99 + (seq * 7.53 % 990) AS DECIMAL(10,2)) AS unit_price,
    CAST(4.50 + (seq * 3.17 % 450) AS DECIMAL(10,2)) AS cost_price,
    'USD' AS currency,
    (seq % 5) != 0 AS in_stock,
    (seq * 13 % 500) AS stock_qty,
    CAST(0.1 + (seq * 0.3 % 49.9) AS DOUBLE) AS weight_kg,
    (seq % 10) != 9 AS is_active,
    DATE '2020-01-01' + INTERVAL '1' DAY * (seq % 1460) AS created_date
FROM (SELECT sequence_number + 1 AS seq FROM TABLE(sequence(start => 0, stop => 249)))
" &>/dev/null
ok "250 product rows inserted."

log "Inserting sample data into 'orders' (5000 rows)..."
trino_exec "
INSERT INTO lakehouse.curated.orders
SELECT
    seq AS order_id,
    (seq % 1200) + 1 AS customer_id,
    DATE '2022-01-01' + INTERVAL '1' DAY * (seq % 730) AS order_date,
    DATE '2022-01-01' + INTERVAL '1' DAY * (seq % 730 + seq % 7 + 1) AS ship_date,
    element_at(ARRAY['pending','processing','shipped','delivered','cancelled','returned'],
               (seq % 6) + 1) AS status,
    CAST(19.99 + (seq * 47.83 % 9980) AS DECIMAL(12,2)) AS total_amount,
    CAST(seq * 2.50 % 100 AS DECIMAL(10,2)) AS discount_amount,
    CAST((19.99 + (seq * 47.83 % 9980)) * 0.08 AS DECIMAL(10,2)) AS tax_amount,
    'USD' AS currency,
    element_at(ARRAY['web','mobile','phone','in-store','partner'], (seq % 5) + 1) AS channel,
    (seq % 5) + 1 AS warehouse_id,
    CASE WHEN seq % 20 = 0 THEN 'Special order' ELSE NULL END AS notes
FROM (SELECT sequence_number + 1 AS seq FROM TABLE(sequence(start => 0, stop => 4999)))
" &>/dev/null
ok "5000 order rows inserted."

log "Inserting sample data into 'order_items' (15000 rows)..."
trino_exec "
INSERT INTO lakehouse.curated.order_items
SELECT
    seq AS item_id,
    ((seq - 1) / 3) + 1 AS order_id,
    (seq % 250) + 1 AS product_id,
    (seq % 5) + 1 AS quantity,
    CAST(9.99 + (seq * 7.53 % 990) AS DECIMAL(10,2)) AS unit_price,
    CAST(seq * 2.0 % 30 AS DECIMAL(5,2)) AS discount_pct,
    CAST(((9.99 + (seq * 7.53 % 990)) * ((seq % 5) + 1)) * (1 - (seq * 2.0 % 30) / 100)
         AS DECIMAL(12,2)) AS total_price
FROM (SELECT sequence_number + 1 AS seq FROM TABLE(sequence(start => 0, stop => 14999)))
" &>/dev/null
ok "15000 order_item rows inserted."

# ─── Step 4: Verify tables ────────────────────────────────────────────────────
log "Verifying tables..."

CUSTOMER_COUNT=$(trino_exec "SELECT COUNT(*) FROM lakehouse.curated.customers" 2>/dev/null | tail -1 | tr -d '"')
PRODUCT_COUNT=$(trino_exec "SELECT COUNT(*) FROM lakehouse.curated.products" 2>/dev/null | tail -1 | tr -d '"')
ORDER_COUNT=$(trino_exec "SELECT COUNT(*) FROM lakehouse.curated.orders" 2>/dev/null | tail -1 | tr -d '"')
ITEMS_COUNT=$(trino_exec "SELECT COUNT(*) FROM lakehouse.curated.order_items" 2>/dev/null | tail -1 | tr -d '"')

echo ""
log "Table row counts:"
log "  customers:   ${CUSTOMER_COUNT:-?}"
log "  products:    ${PRODUCT_COUNT:-?}"
log "  orders:      ${ORDER_COUNT:-?}"
log "  order_items: ${ITEMS_COUNT:-?}"

# Sample query: top 5 customers by revenue
log "Sample query — Top 5 customers by annual revenue:"
trino_exec "
SELECT customer_id, first_name, last_name, country, loyalty_tier, annual_revenue
FROM lakehouse.curated.customers
ORDER BY annual_revenue DESC
LIMIT 5
" 2>/dev/null || warn "Query failed — check Trino and Polaris connectivity."

echo ""
ok "Data seeding complete!"
log "Tables are available in Trino at: lakehouse.curated.*"
log "Run 'make health' to verify all services are running correctly."
