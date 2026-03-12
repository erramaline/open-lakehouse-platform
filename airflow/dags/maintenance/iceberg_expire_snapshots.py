"""
DAG: iceberg_expire_snapshots

Schedule: Daily at 03:00 UTC
Purpose:  Iceberg table maintenance — expire old snapshots, remove
          orphan files, and compact small data files via Trino
          system procedures.

Retention policy:
  - Snapshots older than 7 days are expired
  - Orphan files older than 3 days are removed
  - Tables with > 10 files are compacted (rewrite_data_files)

Tables maintained:
  raw:      documents, customers, orders, products
  staging:  stg_customers, stg_orders, stg_products
  marts:    dim_customers, fct_orders, rpt_revenue_by_region
"""

from __future__ import annotations

import os
from datetime import datetime, timedelta
from typing import Any

from airflow import DAG
from airflow.models import Variable
from airflow.operators.python import PythonOperator
from airflow.utils.dates import days_ago

default_args = {
    "owner": "data-engineering",
    "retries": 1,
    "retry_delay": timedelta(minutes=15),
    "email_on_failure": True,
    "email_on_retry": False,
    "email": [Variable.get("alert_email", default_var="platform-alerts@company.com")],
    "execution_timeout": timedelta(hours=2),
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

TRINO_HOST = os.environ.get("TRINO_HOST", "trino")
TRINO_PORT = int(os.environ.get("TRINO_PORT", "8080"))
TRINO_USER = os.environ.get("TRINO_USER", "admin")
TRINO_PASSWORD = os.environ.get("TRINO_PASSWORD", "")

SNAPSHOT_RETENTION_DAYS = int(Variable.get("iceberg_snapshot_retention_days", default_var="7"))
ORPHAN_RETENTION_DAYS = int(Variable.get("iceberg_orphan_retention_days", default_var="3"))

# Tables to maintain: (catalog_schema, table_name)
ICEBERG_TABLES = [
    # raw layer
    ("raw", "documents"),
    ("raw", "customers"),
    ("raw", "orders"),
    ("raw", "products"),
    # staging layer
    ("staging", "stg_customers"),
    ("staging", "stg_orders"),
    ("staging", "stg_products"),
    # curated / marts
    ("marts", "dim_customers"),
    ("marts", "fct_orders"),
    ("marts", "rpt_revenue_by_region"),
]


# ---------------------------------------------------------------------------
# Trino connection helper
# ---------------------------------------------------------------------------

def _trino_conn():
    """Return a Trino DBAPI connection (iceberg catalog)."""
    import trino  # type: ignore
    from trino.auth import BasicAuthentication  # type: ignore

    auth = BasicAuthentication(TRINO_USER, TRINO_PASSWORD) if TRINO_PASSWORD else None
    return trino.dbapi.connect(
        host=TRINO_HOST,
        port=TRINO_PORT,
        user=TRINO_USER,
        catalog="iceberg",
        http_scheme="http",
        auth=auth,
        request_timeout=1800,  # 30 minutes for maintenance procedures
    )


def _run_trino(sql: str) -> list[Any]:
    """Execute a Trino statement and return all rows."""
    import logging
    log = logging.getLogger(__name__)
    log.debug("Running Trino SQL: %s", sql)
    conn = _trino_conn()
    try:
        cur = conn.cursor()
        cur.execute(sql)
        rows = cur.fetchall()
        return rows
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Task callables
# ---------------------------------------------------------------------------

def expire_snapshots(**context) -> dict:
    """
    Call iceberg.system.expire_snapshots for every tracked table.
    Removes snapshot metadata older than SNAPSHOT_RETENTION_DAYS.
    """
    import logging
    log = logging.getLogger(__name__)

    cutoff_ts = (
        datetime.utcnow() - timedelta(days=SNAPSHOT_RETENTION_DAYS)
    ).strftime("%Y-%m-%d %H:%M:%S")

    results: dict[str, str] = {}
    for schema, table in ICEBERG_TABLES:
        fqn = f'iceberg."{schema}"."{table}"'
        sql = (
            f"CALL iceberg.system.expire_snapshots("
            f"schema_name => '{schema}', "
            f"table_name => '{table}', "
            f"older_than => TIMESTAMP '{cutoff_ts}', "
            f"retain_last => 5"
            f")"
        )
        try:
            rows = _run_trino(sql)
            deleted_rows = rows[0][0] if rows else 0
            log.info("expire_snapshots(%s.%s): %s snapshots deleted", schema, table, deleted_rows)
            results[f"{schema}.{table}"] = f"deleted={deleted_rows}"
        except Exception as exc:
            # Table may not exist yet during initial setup — log and continue
            log.warning("expire_snapshots(%s.%s) error: %s", schema, table, exc)
            results[f"{schema}.{table}"] = f"error={exc}"

    context["task_instance"].xcom_push(key="expire_results", value=results)
    return results


def remove_orphan_files(**context) -> dict:
    """
    Call iceberg.system.remove_orphan_files for every tracked table.
    Removes data files in MinIO that are not referenced by any snapshot.
    Retention: ORPHAN_RETENTION_DAYS days (default 3d).
    """
    import logging
    log = logging.getLogger(__name__)

    cutoff_ts = (
        datetime.utcnow() - timedelta(days=ORPHAN_RETENTION_DAYS)
    ).strftime("%Y-%m-%d %H:%M:%S")

    results: dict[str, str] = {}
    for schema, table in ICEBERG_TABLES:
        sql = (
            f"CALL iceberg.system.remove_orphan_files("
            f"schema_name => '{schema}', "
            f"table_name => '{table}', "
            f"older_than => TIMESTAMP '{cutoff_ts}'"
            f")"
        )
        try:
            rows = _run_trino(sql)
            log.info("remove_orphan_files(%s.%s): %d file(s) removed", schema, table, len(rows))
            results[f"{schema}.{table}"] = f"removed={len(rows)}"
        except Exception as exc:
            log.warning("remove_orphan_files(%s.%s) error: %s", schema, table, exc)
            results[f"{schema}.{table}"] = f"error={exc}"

    context["task_instance"].xcom_push(key="orphan_results", value=results)
    return results


def compact_tables(**context) -> dict:
    """
    Call iceberg.system.rewrite_data_files for tables that benefit
    from compaction (small file problem).  Only compacts if the table
    has at least 10 files.
    """
    import logging
    log = logging.getLogger(__name__)

    results: dict[str, str] = {}
    for schema, table in ICEBERG_TABLES:
        # Check file count before compacting
        count_sql = (
            f"SELECT count(*) FROM iceberg.\"{schema}\".\"{table}$files\""
        )
        try:
            rows = _run_trino(count_sql)
            file_count = int(rows[0][0]) if rows else 0
        except Exception as exc:
            log.warning("Could not query $files for %s.%s: %s", schema, table, exc)
            results[f"{schema}.{table}"] = "skipped (no $files)"
            continue

        if file_count < 10:
            log.info("Skipping compaction for %s.%s (%d files < 10)", schema, table, file_count)
            results[f"{schema}.{table}"] = f"skipped ({file_count} files)"
            continue

        compact_sql = (
            f"CALL iceberg.system.rewrite_data_files("
            f"schema_name => '{schema}', "
            f"table_name => '{table}', "
            f"strategy => 'binpack', "
            f"options => MAP(ARRAY['max-file-group-size-bytes'], ARRAY['1073741824'])"
            f")"
        )
        try:
            _run_trino(compact_sql)
            log.info("Compacted %s.%s (%d files before)", schema, table, file_count)
            results[f"{schema}.{table}"] = f"compacted (was {file_count} files)"
        except Exception as exc:
            log.warning("rewrite_data_files(%s.%s) error: %s", schema, table, exc)
            results[f"{schema}.{table}"] = f"error={exc}"

    context["task_instance"].xcom_push(key="compact_results", value=results)
    return results


def publish_maintenance_report(**context) -> None:
    """
    Log a consolidated maintenance report and push metrics to Prometheus
    pushgateway (if configured).
    """
    import logging
    log = logging.getLogger(__name__)

    task_instance = context["task_instance"]
    expire_results = task_instance.xcom_pull(task_ids="expire_snapshots", key="expire_results") or {}
    orphan_results = task_instance.xcom_pull(task_ids="remove_orphan_files", key="orphan_results") or {}
    compact_results = task_instance.xcom_pull(task_ids="compact_tables", key="compact_results") or {}

    log.info("=== Iceberg Maintenance Report ===")
    log.info("Snapshot expiry: %s", expire_results)
    log.info("Orphan file removal: %s", orphan_results)
    log.info("Compaction: %s", compact_results)
    log.info("==================================")

    pushgateway = os.environ.get("PROMETHEUS_PUSHGATEWAY_URL", "")
    if pushgateway:
        try:
            import requests
            tables = len(ICEBERG_TABLES)
            metrics = (
                f"# TYPE lakehouse_iceberg_maintenance_tables_total gauge\n"
                f"lakehouse_iceberg_maintenance_tables_total {tables}\n"
            )
            requests.post(
                f"{pushgateway}/metrics/job/iceberg_maintenance",
                data=metrics,
                timeout=5,
            )
        except Exception as exc:
            log.warning("Failed to push metrics to Prometheus: %s", exc)


# ---------------------------------------------------------------------------
# DAG definition
# ---------------------------------------------------------------------------

with DAG(
    dag_id="iceberg_expire_snapshots",
    description="Daily Iceberg maintenance: expire snapshots, remove orphans, compact small files",
    schedule="0 3 * * *",
    start_date=days_ago(1),
    catchup=False,
    max_active_runs=1,
    tags=["maintenance", "iceberg", "housekeeping"],
    default_args=default_args,
    doc_md=__doc__,
) as dag:

    expire = PythonOperator(
        task_id="expire_snapshots",
        python_callable=expire_snapshots,
        doc_md="Expire Iceberg snapshots older than the configured retention period.",
    )

    orphans = PythonOperator(
        task_id="remove_orphan_files",
        python_callable=remove_orphan_files,
        doc_md="Remove orphan data files not referenced by any active Iceberg snapshot.",
    )

    compact = PythonOperator(
        task_id="compact_tables",
        python_callable=compact_tables,
        doc_md="Compact Iceberg tables with excessive small files using binpack strategy.",
    )

    report = PythonOperator(
        task_id="publish_maintenance_report",
        python_callable=publish_maintenance_report,
        trigger_rule="all_done",
        doc_md="Publish consolidated maintenance report and push metrics.",
    )

    expire >> orphans >> compact >> report
