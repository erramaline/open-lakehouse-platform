{{ config(materialized='view') }}

SELECT
    CAST(order_id AS VARCHAR)                           AS order_id,
    CAST(customer_id AS VARCHAR)                        AS customer_id,
    TRY_CAST(order_date AS DATE)                        AS order_date,
    LOWER(TRIM(CAST(status AS VARCHAR)))                AS status,
    CAST(total_amount AS DOUBLE)                        AS total_amount_usd,
    UPPER(COALESCE(TRIM(CAST(currency AS VARCHAR)), 'USD'))
                                                        AS currency,
    CAST(status AS VARCHAR) = 'completed'               AS is_completed,
    TRY_CAST(updated_at AS TIMESTAMP)                   AS updated_at,
    _ingested_at
FROM {{ source('raw', 'orders') }}
WHERE
    order_id    IS NOT NULL
    AND customer_id IS NOT NULL
    AND order_date  IS NOT NULL
