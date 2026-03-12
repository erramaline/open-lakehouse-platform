-- Singular test: assert all completed orders have positive revenue
-- Fails if any row is returned (dbt convention for singular tests)

SELECT
    order_id,
    total_amount_usd
FROM {{ ref('fct_orders') }}
WHERE
    is_completed = TRUE
    AND total_amount_usd <= 0
