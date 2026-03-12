"""
DAG: docling_ingest_dag

Schedule: every 5 minutes
Purpose:  Scans MinIO incoming/ prefix for new files, extracts text
          with Docling, and writes results to MinIO raw/documents/.
          Triggers minio_to_iceberg_dag on success.

Secret paths (OpenBao via AirflowOpenBaoBackend):
  secret/data/minio/root → access_key, secret_key
  secret/data/docling/config → model_path
"""

from __future__ import annotations

import os
from datetime import datetime, timedelta

from airflow import DAG
from airflow.models import Variable
from airflow.operators.python import PythonOperator
from airflow.operators.trigger_dagrun import TriggerDagRunOperator
from airflow.utils.dates import days_ago

# ---------------------------------------------------------------------------
# Default args
# ---------------------------------------------------------------------------

default_args = {
    "owner": "data-engineering",
    "retries": 2,
    "retry_delay": timedelta(minutes=3),
    "retry_exponential_backoff": True,
    "max_retry_delay": timedelta(minutes=15),
    "email_on_failure": True,
    "email_on_retry": False,
    "email": [Variable.get("alert_email", default_var="platform-alerts@company.com")],
    "execution_timeout": timedelta(minutes=30),
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _get_minio_client():
    """Build a MinIO client using credentials from Airflow connections."""
    from minio import Minio  # type: ignore
    from airflow.hooks.base import BaseHook

    conn = BaseHook.get_connection("minio_default")
    endpoint = conn.host + (f":{conn.port}" if conn.port else "")
    return Minio(
        endpoint,
        access_key=conn.login,
        secret_key=conn.password,
        secure=conn.schema == "https",
    )


def scan_incoming_prefix(**context) -> list[dict]:
    """
    List objects under incoming/ that haven't been processed yet.
    Returns a list of {bucket, key} dicts pushed to XCom.
    """
    import json

    client = _get_minio_client()
    incoming_bucket = Variable.get("minio_incoming_bucket", default_var="incoming")
    processed_prefix = "processed/"

    # List all incoming objects
    objects = client.list_objects(incoming_bucket, prefix="uploads/", recursive=True)
    new_files = []

    for obj in objects:
        key = obj.object_name
        # Skip already-processed marker files
        marker_key = processed_prefix + key.replace("/", "_") + ".done"
        try:
            client.stat_object(incoming_bucket, marker_key)
            # Marker exists → already processed
        except Exception:
            new_files.append({"bucket": incoming_bucket, "key": key})

    context["task_instance"].xcom_push(key="new_files", value=new_files)
    return new_files


def extract_with_docling(**context) -> list[dict]:
    """
    For each new file, extract text with Docling and upload to raw/.
    """
    import json
    import io

    task_instance = context["task_instance"]
    new_files = task_instance.xcom_pull(task_ids="scan_incoming", key="new_files") or []

    if not new_files:
        return []

    client = _get_minio_client()
    raw_bucket = Variable.get("minio_raw_bucket", default_var="raw")
    run_id = context["run_id"]
    results = []

    for file_info in new_files:
        bucket = file_info["bucket"]
        key = file_info["key"]

        try:
            # Download file
            response = client.get_object(bucket, key)
            file_bytes = response.read()

            # Extract with Docling
            extracted_text = _extract_text(key, file_bytes)

            # Build output object
            from pathlib import Path
            stem = Path(key).stem
            out_key = f"documents/{stem}/{run_id}/extracted.json"

            import json as json_mod
            result_payload = json_mod.dumps({
                "source_key": key,
                "source_bucket": bucket,
                "extracted_text": extracted_text,
                "page_count": extracted_text.count("\f") + 1,
                "run_id": run_id,
                "metadata": {"extractor": "docling"},
            }).encode()

            client.put_object(
                raw_bucket,
                out_key,
                io.BytesIO(result_payload),
                length=len(result_payload),
                content_type="application/json",
            )

            # Write processed marker
            incoming_bucket = Variable.get("minio_incoming_bucket", default_var="incoming")
            marker_key = f"processed/{key.replace('/', '_')}.done"
            client.put_object(
                incoming_bucket, marker_key,
                io.BytesIO(b"done"), length=4,
            )

            results.append({"source_key": key, "raw_key": out_key})

        except Exception as exc:
            import logging
            logging.getLogger(__name__).error(
                "Docling extraction failed for %s: %s", key, exc
            )

    task_instance.xcom_push(key="extracted_files", value=results)
    return results


def _extract_text(filename: str, file_bytes: bytes) -> str:
    """
    Extract text from file bytes using Docling if available,
    otherwise fall back to basic text extraction.
    """
    import tempfile
    import os

    try:
        from docling.document_converter import DocumentConverter  # type: ignore
        with tempfile.NamedTemporaryFile(
            suffix=os.path.splitext(filename)[1] or ".bin", delete=False
        ) as tmp:
            tmp.write(file_bytes)
            tmp_path = tmp.name

        try:
            converter = DocumentConverter()
            result = converter.convert(tmp_path)
            return getattr(result, "text", None) or str(result)
        finally:
            os.unlink(tmp_path)

    except ImportError:
        # Fallback: decode as UTF-8 (works for .txt, .csv)
        try:
            return file_bytes.decode("utf-8", errors="replace")
        except Exception:
            return ""


# ---------------------------------------------------------------------------
# DAG definition
# ---------------------------------------------------------------------------

with DAG(
    dag_id="docling_ingest_dag",
    description="Scan MinIO incoming/, extract text with Docling, upload to raw/",
    schedule="*/5 * * * *",
    start_date=days_ago(1),
    catchup=False,
    max_active_runs=1,
    tags=["ingestion", "docling", "minio"],
    default_args=default_args,
    doc_md=__doc__,
) as dag:

    scan_task = PythonOperator(
        task_id="scan_incoming",
        python_callable=scan_incoming_prefix,
        doc_md="Scan MinIO incoming/ prefix for unprocessed files.",
    )

    extract_task = PythonOperator(
        task_id="extract_with_docling",
        python_callable=extract_with_docling,
        doc_md="Extract text from each file using Docling.",
    )

    trigger_iceberg_task = TriggerDagRunOperator(
        task_id="trigger_minio_to_iceberg",
        trigger_dag_id="minio_to_iceberg_dag",
        conf={"run_id": "{{ run_id }}", "triggered_by": "docling_ingest_dag"},
        wait_for_completion=False,
        doc_md="Trigger Iceberg ingestion after text extraction.",
    )

    scan_task >> extract_task >> trigger_iceberg_task
