{{ config(materialized='view') }}

SELECT
    CAST(product_id AS VARCHAR)                         AS product_id,
    TRIM(CAST(name AS VARCHAR))                         AS name,
    TRIM(CAST(category AS VARCHAR))                     AS category,
    CAST(price AS DOUBLE)                               AS price,
    COALESCE(TRIM(CAST(currency AS VARCHAR)), 'USD')    AS currency,
    LOWER(COALESCE(TRIM(CAST(status AS VARCHAR)), 'active'))
                                                        AS status,
    _ingested_at
FROM {{ source('raw', 'products') }}
WHERE
    product_id IS NOT NULL
    AND name   IS NOT NULL
    AND price  IS NOT NULL
    AND price  > 0
