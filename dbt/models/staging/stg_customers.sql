{{ config(materialized='view') }}

SELECT
    TRIM(CAST(customer_id AS VARCHAR))                  AS customer_id,
    LOWER(TRIM(CAST(email AS VARCHAR)))                 AS email,
    TRIM(CAST(first_name AS VARCHAR))                   AS first_name,
    TRIM(CAST(last_name AS VARCHAR))                    AS last_name,
    TRIM(CAST(first_name AS VARCHAR))
        || ' ' ||
    TRIM(CAST(last_name AS VARCHAR))                    AS full_name,
    UPPER(TRIM(CAST(country AS VARCHAR)))               AS country,
    TRY_CAST(created_at AS TIMESTAMP)                   AS created_at,
    TRY_CAST(updated_at AS TIMESTAMP)                   AS updated_at,
    _ingested_at
FROM {{ source('raw', 'customers') }}
WHERE
    customer_id IS NOT NULL
    AND email    IS NOT NULL
