{{ config(materialized='table') }}

SELECT
    country,
    COUNT(*)                                                AS total_orders,
    COUNT(CASE WHEN is_completed THEN 1 END)               AS completed_orders,
    SUM(total_amount_usd)                                  AS total_revenue_usd,
    AVG(total_amount_usd)                                  AS avg_order_value_usd,
    {{ safe_divide('COUNT(CASE WHEN is_completed THEN 1 END)', 'COUNT(*)') }}
                                                           AS completion_rate,
    CURRENT_TIMESTAMP                                      AS _dbt_updated_at
FROM {{ ref('fct_orders') }}
GROUP BY country
ORDER BY total_revenue_usd DESC
