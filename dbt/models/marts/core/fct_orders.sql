{{
    config(
        materialized='incremental',
        unique_key='order_id',
        incremental_strategy='merge'
    )
}}

SELECT
    o.order_id,
    dc.customer_key,
    o.customer_id,
    o.order_date,
    o.status,
    o.total_amount_usd,
    o.currency,
    o.is_completed,
    dc.country,
    dc.full_name                                         AS customer_name,
    o.updated_at,
    o._ingested_at
FROM {{ ref('stg_orders') }} o
LEFT JOIN {{ ref('dim_customers') }} dc
    ON o.customer_id = dc.customer_id

{% if is_incremental() %}
    -- Only process orders updated since the last dbt run
    WHERE o.updated_at > (
        SELECT COALESCE(MAX(updated_at), TIMESTAMP '2000-01-01 00:00:00')
        FROM {{ this }}
    )
    OR o._ingested_at > (
        SELECT COALESCE(MAX(_ingested_at), TIMESTAMP '2000-01-01 00:00:00')
        FROM {{ this }}
    )
{% endif %}
