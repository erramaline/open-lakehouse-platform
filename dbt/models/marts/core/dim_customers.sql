{{ config(materialized='table') }}

SELECT
    {{ generate_surrogate_key(['customer_id']) }}        AS customer_key,
    customer_id,
    email,
    first_name,
    last_name,
    full_name,
    country,
    created_at,
    updated_at,
    CURRENT_TIMESTAMP                                    AS _dbt_updated_at
FROM {{ ref('stg_customers') }}
