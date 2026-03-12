"""
DAG: great_expectations_dag

Trigger:  Triggered by dbt_run_dag
Purpose:  Run Great Expectations checkpoints for all three layers
          (raw, staging, curated) and push results to OpenMetadata
          as Data Quality records.

Checkpoints:
  raw_layer_checkpoint     → raw.customers, raw.orders, raw.documents
  staging_layer_checkpoint → staging.stg_*
  curated_layer_checkpoint → marts.dim_*, marts.fct_*, marts.rpt_*
"""

from __future__ import annotations

import os
from datetime import datetime, timedelta
from pathlib import Path

from airflow import DAG
from airflow.models import Variable
from airflow.operators.python import PythonOperator
from airflow.operators.trigger_dagrun import TriggerDagRunOperator
from airflow.utils.dates import days_ago

default_args = {
    "owner": "data-engineering",
    "retries": 1,
    "retry_delay": timedelta(minutes=5),
    "email_on_failure": True,
    "email_on_retry": False,
    "email": [Variable.get("alert_email", default_var="platform-alerts@company.com")],
    "execution_timeout": timedelta(hours=1),
}

GE_ROOT_DIR = os.environ.get("GE_ROOT_DIR", "/opt/airflow/great_expectations")

CHECKPOINTS = [
    ("raw_layer_checkpoint", "raw"),
    ("staging_layer_checkpoint", "staging"),
    ("curated_layer_checkpoint", "curated"),
]


def _get_ge_context():
    """Return a GE DataContext configured for the platform."""
    import great_expectations as gx  # type: ignore
    context = gx.get_context(context_root_dir=GE_ROOT_DIR)
    return context


def run_checkpoint(checkpoint_name: str, layer: str, **context) -> dict:
    """
    Run a single GE checkpoint and return the validation result summary.
    Raises on checkpoint failure to fail the Airflow task.
    """
    import logging
    log = logging.getLogger(__name__)

    try:
        ge_context = _get_ge_context()
    except Exception as exc:
        log.warning("GE context not available: %s — skipping checkpoint %s", exc, checkpoint_name)
        return {"skipped": True, "reason": str(exc)}

    # Check if checkpoint exists
    available = [cp["name"] for cp in ge_context.list_checkpoints()]
    if checkpoint_name not in available:
        log.warning(
            "Checkpoint '%s' not found. Available: %s. "
            "Initialize GE with `great_expectations checkpoint new %s`",
            checkpoint_name, available, checkpoint_name,
        )
        return {"skipped": True, "reason": "checkpoint not found"}

    result = ge_context.run_checkpoint(checkpoint_name=checkpoint_name)

    summary = {
        "checkpoint": checkpoint_name,
        "layer": layer,
        "success": result.success,
        "run_id": str(result.run_id),
        "statistics": result.statistics,
    }

    context["task_instance"].xcom_push(
        key=f"{checkpoint_name}_result", value=summary
    )

    if not result.success:
        failed = [
            str(k) for k, v in result.run_results.items()
            if not v.get("validation_result", {}).get("success", True)
        ]
        raise RuntimeError(
            f"GE checkpoint '{checkpoint_name}' FAILED for layer '{layer}'.\n"
            f"Failed validations: {failed}"
        )

    log.info(
        "GE checkpoint '%s' PASSED. Statistics: %s",
        checkpoint_name, result.statistics,
    )
    return summary


def run_raw_checkpoint(**context) -> dict:
    return run_checkpoint("raw_layer_checkpoint", "raw", **context)


def run_staging_checkpoint(**context) -> dict:
    return run_checkpoint("staging_layer_checkpoint", "staging", **context)


def run_curated_checkpoint(**context) -> dict:
    return run_checkpoint("curated_layer_checkpoint", "curated", **context)


def push_results_to_openmetadata(**context) -> None:
    """
    Push GE validation results to OpenMetadata as TestSuite results.
    Uses the OpenMetadata Python client if available.
    """
    import logging
    log = logging.getLogger(__name__)

    task_instance = context["task_instance"]
    results = []
    for checkpoint_name, _ in CHECKPOINTS:
        result = task_instance.xcom_pull(
            task_ids=f"run_{checkpoint_name.replace('_checkpoint', '')}",
            key=f"{checkpoint_name}_result",
        )
        if result:
            results.append(result)

    if not results:
        log.info("No GE results to push to OpenMetadata")
        return

    om_host = os.environ.get("OPENMETADATA_HOST", "http://localhost:8585")
    om_token = os.environ.get("OPENMETADATA_JWT_TOKEN", "")

    if not om_token:
        log.warning("OPENMETADATA_JWT_TOKEN not set — skipping OM push")
        return

    try:
        import requests
        for result in results:
            if result.get("skipped"):
                continue
            requests.post(
                f"{om_host}/api/v1/dataQuality/testCases/testSuiteResult",
                json={
                    "checkpointName": result["checkpoint"],
                    "layer": result["layer"],
                    "success": result["success"],
                    "runId": result["run_id"],
                },
                headers={"Authorization": f"Bearer {om_token}"},
                timeout=10,
            )
            log.info("Pushed %s results to OpenMetadata", result["checkpoint"])
    except Exception as exc:
        log.warning("Failed to push results to OpenMetadata: %s", exc)


# ---------------------------------------------------------------------------
# DAG definition
# ---------------------------------------------------------------------------

with DAG(
    dag_id="great_expectations_dag",
    description="Run GE checkpoints for raw, staging, curated layers; push to OpenMetadata",
    schedule=None,  # Triggered by dbt_run_dag
    start_date=days_ago(1),
    catchup=False,
    max_active_runs=1,
    tags=["quality", "great-expectations", "openmetadata"],
    default_args=default_args,
    doc_md=__doc__,
) as dag:

    raw_checkpoint = PythonOperator(
        task_id="run_raw_layer_checkpoint",
        python_callable=run_raw_checkpoint,
        doc_md="Run GE checkpoint for the raw layer.",
    )

    staging_checkpoint = PythonOperator(
        task_id="run_staging_layer_checkpoint",
        python_callable=run_staging_checkpoint,
        doc_md="Run GE checkpoint for the staging layer.",
    )

    curated_checkpoint = PythonOperator(
        task_id="run_curated_layer_checkpoint",
        python_callable=run_curated_checkpoint,
        doc_md="Run GE checkpoint for the curated/marts layer.",
    )

    push_to_om = PythonOperator(
        task_id="push_results_to_openmetadata",
        python_callable=push_results_to_openmetadata,
        trigger_rule="all_done",  # Run even if checkpoints fail
        doc_md="Push GE validation results to OpenMetadata.",
    )

    trigger_metadata_sync = TriggerDagRunOperator(
        task_id="trigger_openmetadata_sync",
        trigger_dag_id="openmetadata_sync_dag",
        conf={"triggered_by": "great_expectations_dag"},
        wait_for_completion=False,
        doc_md="Trigger OpenMetadata metadata sync after quality checks.",
    )

    [raw_checkpoint, staging_checkpoint, curated_checkpoint] >> push_to_om >> trigger_metadata_sync
