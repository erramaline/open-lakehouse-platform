{% macro generate_surrogate_key(field_list) %}
    {#
        Generates a surrogate key by MD5-hashing the concatenation of the
        provided fields, separated by a pipe character.

        Delegates to dbt_utils.generate_surrogate_key when the package is
        available; otherwise falls back to a native Trino MD5 expression.

        Usage:
            {{ generate_surrogate_key(['customer_id']) }}
            {{ generate_surrogate_key(['order_id', 'line_item_id']) }}
    #}
    {% if execute %}
        {% set ns = namespace(fields=[]) %}
        {% for field in field_list %}
            {% set ns.fields = ns.fields + ["COALESCE(CAST(" ~ field ~ " AS VARCHAR), '_null_')"] %}
        {% endfor %}
        MD5({{ ns.fields | join(" || '|' || ") }})
    {% endif %}
{% endmacro %}
