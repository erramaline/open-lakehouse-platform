{% macro safe_divide(numerator, denominator) %}
    {#
        Performs division returning 0.0 when the denominator is zero or NULL,
        avoiding division-by-zero errors in aggregation queries.

        Usage:
            {{ safe_divide('SUM(revenue)', 'COUNT(orders)') }}
            {{ safe_divide('completed_orders', 'total_orders') }}
    #}
    CASE
        WHEN ({{ denominator }}) = 0 OR ({{ denominator }}) IS NULL
            THEN 0.0
        ELSE CAST(({{ numerator }}) AS DOUBLE) / CAST(({{ denominator }}) AS DOUBLE)
    END
{% endmacro %}
