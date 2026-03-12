"""
DAG: dbt_run_dag

Trigger:  Triggered by minio_to_iceberg_dag
Purpose:  Run dbt models in order: staging → marts
          Then run dbt test suite and source freshness check.
          Triggers great_expectations_dag on success.

Environment:
  DBT_PROFILES_DIR → mounted at /opt/airflow/dbt
  Trino credentials injected via environment from OpenBao secrets backend
"""

from __future__ import annotations

import os
import subprocess
from datetime import datetime, timedelta
from pathlib import Path

from airflow import DAG
from airflow.models import Variable
from airflow.operators.python import PythonOperator, BranchPythonOperator
from airflow.operators.trigger_dagrun import TriggerDagRunOperator
from airflow.operators.empty import EmptyOperator
from airflow.utils.dates import days_ago

default_args = {
    "owner": "data-engineering",
    "retries": 1,
    "retry_delay": timedelta(minutes=10),
    "email_on_failure": True,
    "email_on_retry": False,
    "email": [Variable.get("alert_email", default_var="platform-alerts@company.com")],
    "execution_timeout": timedelta(hours=1),
}

DBT_PROJECT_DIR = os.environ.get("DBT_PROJECT_DIR", "/opt/airflow/dbt")
DBT_PROFILES_DIR = os.environ.get("DBT_PROFILES_DIR", "/opt/airflow/dbt")
DBT_TARGET = os.environ.get("DBT_TARGET", "production")


def _run_dbt(*args: str) -> dict:
    """Run a dbt command and return {'returncode', 'stdout', 'stderr'}."""
    cmd = [
        "dbt", *args,
        "--project-dir", DBT_PROJECT_DIR,
        "--profiles-dir", DBT_PROFILES_DIR,
        "--target", DBT_TARGET,
        "--no-write-json",
    ]
    result = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=3600,
        env={**os.environ},
    )
    return {
        "returncode": result.returncode,
        "stdout": result.stdout[-10000:],  # last 10k chars
        "stderr": result.stderr[-5000:],
    }


def run_dbt_staging(**context) -> dict:
    """Run staging dbt models."""
    result = _run_dbt("run", "--select", "staging")
    context["task_instance"].xcom_push(key="staging_result", value=result)

    if result["returncode"] != 0:
        raise RuntimeError(
            f"dbt run staging failed (exit {result['returncode']}):\n{result['stderr']}"
        )
    return result


def run_dbt_marts(**context) -> dict:
    """Run mart dbt models."""
    result = _run_dbt("run", "--select", "marts")
    context["task_instance"].xcom_push(key="marts_result", value=result)

    if result["returncode"] != 0:
        raise RuntimeError(
            f"dbt run marts failed (exit {result['returncode']}):\n{result['stderr']}"
        )
    return result


def run_dbt_tests(**context) -> dict:
    """Run dbt test suite."""
    result = _run_dbt("test")
    context["task_instance"].xcom_push(key="test_result", value=result)

    if result["returncode"] != 0:
        raise RuntimeError(
            f"dbt test failed (exit {result['returncode']}):\n{result['stderr']}"
        )
    return result


def check_source_freshness(**context) -> str:
    """Check dbt source freshness; branch to warn on stale sources."""
    result = _run_dbt("source", "freshness", "--output", "json")
    context["task_instance"].xcom_push(key="freshness_result", value=result)

    # returncode=1 means some sources warn/error on freshness
    if result["returncode"] == 0:
        return "trigger_great_expectations"
    else:
        return "source_freshness_warning"


def log_freshness_warning(**context) -> None:
    """Log a warning for stale dbt sources without failing the pipeline."""
    import logging
    result = context["task_instance"].xcom_pull(
        task_ids="check_source_freshness", key="freshness_result"
    )
    logging.getLogger(__name__).warning(
        "dbt source freshness check found stale sources:\n%s",
        result.get("stdout", "") if result else "No output",
    )


# ---------------------------------------------------------------------------
# DAG definition
# ---------------------------------------------------------------------------

with DAG(
    dag_id="dbt_run_dag",
    description="Run dbt staging → marts → tests → source freshness",
    schedule=None,  # Triggered by minio_to_iceberg_dag
    start_date=days_ago(1),
    catchup=False,
    max_active_runs=1,  # Only one dbt run at a time
    tags=["transformation", "dbt", "iceberg"],
    default_args=default_args,
    doc_md=__doc__,
) as dag:

    run_staging = PythonOperator(
        task_id="run_staging_models",
        python_callable=run_dbt_staging,
        doc_md="Run dbt staging models (stg_customers, stg_orders, stg_products).",
    )

    run_marts = PythonOperator(
        task_id="run_mart_models",
        python_callable=run_dbt_marts,
        doc_md="Run dbt mart models (dim_customers, fct_orders, rpt_revenue_by_region).",
    )

    run_tests = PythonOperator(
        task_id="run_dbt_tests",
        python_callable=run_dbt_tests,
        doc_md="Run dbt test suite (schema tests + custom singular tests).",
    )

    freshness_check = BranchPythonOperator(
        task_id="check_source_freshness",
        python_callable=check_source_freshness,
        doc_md="Check dbt source freshness; warn if stale.",
    )

    freshness_warning = PythonOperator(
        task_id="source_freshness_warning",
        python_callable=log_freshness_warning,
        doc_md="Log warning for stale sources.",
    )

    trigger_ge = TriggerDagRunOperator(
        task_id="trigger_great_expectations",
        trigger_dag_id="great_expectations_dag",
        conf={"run_id": "{{ run_id }}", "triggered_by": "dbt_run_dag"},
        wait_for_completion=False,
        doc_md="Trigger GE data quality checks after dbt completes.",
    )

    run_staging >> run_marts >> run_tests >> freshness_check
    freshness_check >> [trigger_ge, freshness_warning]
    freshness_warning >> trigger_ge
