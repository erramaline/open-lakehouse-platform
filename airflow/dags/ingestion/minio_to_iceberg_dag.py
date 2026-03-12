"""
DAG: minio_to_iceberg_dag

Trigger:  Triggered by docling_ingest_dag (TriggerDagRunOperator)
Purpose:  Read extracted JSON files from MinIO raw/documents/,
          parse them, and write records to Iceberg raw.documents
          using a Trino INSERT or Spark job.
          Triggers dbt_run_dag on success.

Secret paths (OpenBao):
  secret/data/minio/root → access_key, secret_key
  secret/data/trino/gateway → host, port, user
"""

from __future__ import annotations

import os
from datetime import datetime, timedelta

from airflow import DAG
from airflow.models import Variable
from airflow.operators.python import PythonOperator, ShortCircuitOperator
from airflow.operators.trigger_dagrun import TriggerDagRunOperator
from airflow.utils.dates import days_ago

default_args = {
    "owner": "data-engineering",
    "retries": 3,
    "retry_delay": timedelta(minutes=5),
    "retry_exponential_backoff": True,
    "max_retry_delay": timedelta(minutes=30),
    "email_on_failure": True,
    "email_on_retry": False,
    "email": [Variable.get("alert_email", default_var="platform-alerts@company.com")],
    "execution_timeout": timedelta(hours=2),
}

ICEBERG_SCHEMA = "raw"
ICEBERG_TABLE = "documents"
BATCH_SIZE = 1000


def _get_minio_client():
    from minio import Minio  # type: ignore
    from airflow.hooks.base import BaseHook
    conn = BaseHook.get_connection("minio_default")
    endpoint = conn.host + (f":{conn.port}" if conn.port else "")
    return Minio(endpoint, access_key=conn.login, secret_key=conn.password,
                 secure=conn.schema == "https")


def _get_trino_connection():
    from trino.dbapi import connect  # type: ignore
    from trino.auth import BasicAuthentication  # type: ignore
    from airflow.hooks.base import BaseHook

    conn = BaseHook.get_connection("trino_default")
    auth = BasicAuthentication(conn.login, conn.password) if conn.password else None
    return connect(
        host=conn.host,
        port=conn.port or 8080,
        user=conn.login or "airflow",
        auth=auth,
        http_scheme=conn.schema or "http",
        catalog="iceberg",
        schema=ICEBERG_SCHEMA,
    )


def check_new_files(**context) -> bool:
    """ShortCircuit: skip downstream tasks if no new files were extracted."""
    trigger_conf = context.get("dag_run").conf or {}
    triggered_by = trigger_conf.get("triggered_by", "")

    # Check MinIO raw/ for files from this run
    client = _get_minio_client()
    raw_bucket = Variable.get("minio_raw_bucket", default_var="raw")
    run_id = trigger_conf.get("run_id", context["run_id"])

    try:
        objects = list(client.list_objects(raw_bucket, prefix=f"documents/", recursive=True))
        # Filter by run_id in path
        run_files = [o for o in objects if str(run_id)[:8] in o.object_name]
        return len(run_files) > 0
    except Exception:
        return False


def read_extracted_files(**context) -> list[dict]:
    """Read extracted JSON files from MinIO raw/documents/ for this run."""
    import json

    client = _get_minio_client()
    raw_bucket = Variable.get("minio_raw_bucket", default_var="raw")
    trigger_conf = context.get("dag_run").conf or {}
    run_id = trigger_conf.get("run_id", context["run_id"])

    records = []
    try:
        objects = client.list_objects(raw_bucket, prefix="documents/", recursive=True)
        for obj in objects:
            if obj.object_name.endswith(".json"):
                response = client.get_object(raw_bucket, obj.object_name)
                data = json.loads(response.read())
                records.append(data)
    except Exception as exc:
        import logging
        logging.getLogger(__name__).warning("Error reading raw files: %s", exc)

    context["task_instance"].xcom_push(key="records", value=records[:BATCH_SIZE])
    return records


def write_to_iceberg(**context) -> int:
    """Write extracted records to Iceberg raw.documents table via Trino."""
    task_instance = context["task_instance"]
    records = task_instance.xcom_pull(task_ids="read_extracted_files", key="records") or []

    if not records:
        return 0

    conn = _get_trino_connection()
    cursor = conn.cursor()

    try:
        # Ensure table exists
        cursor.execute(f"""
            CREATE TABLE IF NOT EXISTS {ICEBERG_SCHEMA}.{ICEBERG_TABLE} (
                source_key     VARCHAR,
                source_bucket  VARCHAR,
                extracted_text VARCHAR,
                page_count     INTEGER,
                run_id         VARCHAR,
                ingested_at    TIMESTAMP,
                metadata       VARCHAR
            )
            WITH (
                format = 'PARQUET',
                partitioning = ARRAY['run_id']
            )
        """)

        # Batch insert
        inserted = 0
        batch = []
        for rec in records:
            import json
            batch.append((
                rec.get("source_key", ""),
                rec.get("source_bucket", ""),
                (rec.get("extracted_text") or "")[:65535],  # Trino VARCHAR limit
                rec.get("page_count", 1),
                rec.get("run_id", ""),
                rec.get("metadata", {}),
            ))

            if len(batch) >= 100:
                _flush_batch(cursor, batch)
                inserted += len(batch)
                batch = []

        if batch:
            _flush_batch(cursor, batch)
            inserted += len(batch)

        conn.commit()
        return inserted

    finally:
        cursor.cancel()
        conn.close()


def _flush_batch(cursor, records: list[tuple]) -> None:
    import json as json_mod
    values = ", ".join(
        "('{}', '{}', '{}', {}, '{}', CURRENT_TIMESTAMP, '{}')".format(
            r[0].replace("'", "''"),
            r[1].replace("'", "''"),
            r[2].replace("'", "''"),
            r[3],
            r[4].replace("'", "''"),
            json_mod.dumps(r[5]).replace("'", "''"),
        )
        for r in records
    )
    cursor.execute(
        f"INSERT INTO {ICEBERG_SCHEMA}.{ICEBERG_TABLE} "  # noqa: S608
        f"(source_key, source_bucket, extracted_text, page_count, run_id, ingested_at, metadata) "
        f"VALUES {values}"
    )


# ---------------------------------------------------------------------------
# DAG definition
# ---------------------------------------------------------------------------

with DAG(
    dag_id="minio_to_iceberg_dag",
    description="Read extracted JSON from MinIO raw/, write to Iceberg raw.documents",
    schedule=None,  # Triggered by docling_ingest_dag
    start_date=days_ago(1),
    catchup=False,
    max_active_runs=3,
    tags=["ingestion", "iceberg", "trino"],
    default_args=default_args,
    doc_md=__doc__,
) as dag:

    check_task = ShortCircuitOperator(
        task_id="check_new_files",
        python_callable=check_new_files,
        doc_md="Skip if no new files to process.",
    )

    read_task = PythonOperator(
        task_id="read_extracted_files",
        python_callable=read_extracted_files,
        doc_md="Read extracted JSON records from MinIO raw/documents/.",
    )

    write_task = PythonOperator(
        task_id="write_to_iceberg",
        python_callable=write_to_iceberg,
        doc_md="Insert records into Iceberg raw.documents via Trino.",
    )

    trigger_dbt = TriggerDagRunOperator(
        task_id="trigger_dbt_run",
        trigger_dag_id="dbt_run_dag",
        conf={"run_id": "{{ run_id }}", "triggered_by": "minio_to_iceberg_dag"},
        wait_for_completion=False,
        doc_md="Trigger dbt transformation after Iceberg ingestion.",
    )

    check_task >> read_task >> write_task >> trigger_dbt
