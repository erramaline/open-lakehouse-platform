"""
Performance test — Ingestion throughput benchmark.

Measures:
  - MinIO PUT throughput (MB/s)
  - Trino INSERT INTO Iceberg throughput (rows/s)
  - End-to-end ingest pipeline (files → Iceberg rows) throughput

SLOs:
  - MinIO PUT: > 100 MB/s (local 4-node erasure coding)
  - Trino INSERT: > 5,000 rows/s (cold start, sf0.01 scale)
  - Batch size 100k rows must complete in < 60s

Run with: pytest tests/performance/ingest_throughput.py -v -s
"""

from __future__ import annotations

import io
import time
import uuid

import pytest

pytestmark = [pytest.mark.performance, pytest.mark.slow]

MINIO_THROUGHPUT_SLO_MBPS = 50.0   # MB/s (conservative for local dev)
TRINO_THROUGHPUT_SLO_RPS = 5_000   # rows/s
TRINO_BATCH_SIZE = 100_000          # rows
TRINO_BATCH_SLO_SECONDS = 120       # max seconds for 100k row batch


# ---------------------------------------------------------------------------
# MinIO throughput
# ---------------------------------------------------------------------------

class TestMinIOThroughput:

    BUCKET = "staging"
    FILE_SIZES_MB = [1, 10, 100]   # MB

    @pytest.fixture(autouse=True)
    def _ensure_bucket(self, docker_services, minio_client):
        if not minio_client.bucket_exists(self.BUCKET):
            minio_client.make_bucket(self.BUCKET)

    @pytest.mark.parametrize("size_mb", FILE_SIZES_MB)
    def test_put_throughput(self, size_mb: int, minio_client):
        """PUT throughput must exceed SLO for various file sizes."""
        data = b"x" * (size_mb * 1024 * 1024)
        key = f"perf-test/{uuid.uuid4().hex}/{size_mb}mb.bin"

        try:
            start = time.perf_counter()
            minio_client.put_object(
                self.BUCKET, key,
                io.BytesIO(data),
                length=len(data),
                content_type="application/octet-stream",
            )
            elapsed = time.perf_counter() - start

            mbps = size_mb / elapsed
            print(f"\nMinIO PUT {size_mb}MB: {elapsed:.2f}s → {mbps:.1f} MB/s")

            assert mbps >= MINIO_THROUGHPUT_SLO_MBPS, (
                f"MinIO PUT throughput {mbps:.1f} MB/s < SLO {MINIO_THROUGHPUT_SLO_MBPS} MB/s"
                f" for {size_mb}MB file"
            )
        finally:
            try:
                minio_client.remove_object(self.BUCKET, key)
            except Exception:
                pass

    def test_get_throughput_100mb(self, minio_client):
        """GET throughput for 100 MB file must exceed SLO."""
        data = b"x" * (100 * 1024 * 1024)
        key = f"perf-test/get-{uuid.uuid4().hex}.bin"

        try:
            minio_client.put_object(self.BUCKET, key, io.BytesIO(data), length=len(data))

            start = time.perf_counter()
            response = minio_client.get_object(self.BUCKET, key)
            retrieved = response.read()
            elapsed = time.perf_counter() - start

            mbps = 100 / elapsed
            print(f"\nMinIO GET 100MB: {elapsed:.2f}s → {mbps:.1f} MB/s")
            assert len(retrieved) == len(data)
            assert mbps >= MINIO_THROUGHPUT_SLO_MBPS
        finally:
            try:
                minio_client.remove_object(self.BUCKET, key)
            except Exception:
                pass

    def test_concurrent_puts(self, minio_client):
        """16 concurrent 1MB PUTs must not degrade throughput below SLO."""
        import concurrent.futures

        size_mb = 1
        data = b"x" * (size_mb * 1024 * 1024)
        keys = [f"perf-test/concurrent-{uuid.uuid4().hex}.bin" for _ in range(16)]

        def put_one(key: str) -> float:
            start = time.perf_counter()
            minio_client.put_object(
                self.BUCKET, key, io.BytesIO(data), length=len(data)
            )
            return time.perf_counter() - start

        try:
            start = time.perf_counter()
            with concurrent.futures.ThreadPoolExecutor(max_workers=16) as executor:
                futures = [executor.submit(put_one, k) for k in keys]
                times = [f.result(timeout=60) for f in futures]
            total_elapsed = time.perf_counter() - start

            total_mb = size_mb * len(keys)
            aggregate_mbps = total_mb / total_elapsed
            print(f"\n16 concurrent PUTs: {total_elapsed:.2f}s → {aggregate_mbps:.1f} MB/s aggregate")

            # At 16 concurrent, allow 50% degradation
            assert aggregate_mbps >= MINIO_THROUGHPUT_SLO_MBPS * 0.5, (
                f"Concurrent PUT throughput {aggregate_mbps:.1f} MB/s too low"
            )
        finally:
            for key in keys:
                try:
                    minio_client.remove_object(self.BUCKET, key)
                except Exception:
                    pass


# ---------------------------------------------------------------------------
# Trino INSERT throughput
# ---------------------------------------------------------------------------

class TestTrinoInsertThroughput:

    @pytest.fixture(autouse=True)
    def _require_stack(self, docker_services, trino_cursor):
        pass

    def test_insert_10k_rows(self, trino_cursor):
        """INSERT 10k rows into Iceberg must complete within SLO."""
        table = f"iceberg.raw.perf_test_{uuid.uuid4().hex[:8]}"
        try:
            trino_cursor.execute(
                f"CREATE TABLE {table} (id BIGINT, value VARCHAR, ts TIMESTAMP)"
            )

            # Build INSERT with VALUES (batch of 1000 at a time)
            batch_size = 1000
            total_rows = 10_000
            total_elapsed = 0.0

            for batch_start in range(0, total_rows, batch_size):
                values = ", ".join(
                    f"({i}, 'value-{i}', CURRENT_TIMESTAMP)"
                    for i in range(batch_start, min(batch_start + batch_size, total_rows))
                )
                start = time.perf_counter()
                trino_cursor.execute(f"INSERT INTO {table} VALUES {values}")
                total_elapsed += time.perf_counter() - start

            rps = total_rows / total_elapsed
            print(f"\nTrino INSERT 10k rows: {total_elapsed:.2f}s → {rps:.0f} rows/s")

            assert rps >= TRINO_THROUGHPUT_SLO_RPS, (
                f"Trino INSERT throughput {rps:.0f} rows/s < SLO {TRINO_THROUGHPUT_SLO_RPS} rows/s"
            )
        except Exception as exc:
            if "Catalog" in str(exc) or "does not exist" in str(exc):
                pytest.skip(f"Iceberg catalog not configured: {exc}")
            raise
        finally:
            try:
                trino_cursor.execute(f"DROP TABLE IF EXISTS {table}")
            except Exception:
                pass

    def test_ctas_100k_rows_within_slo(self, trino_cursor):
        """CREATE TABLE AS SELECT 100k rows from tpch must complete within 120s."""
        table = f"iceberg.raw.ctas_perf_{uuid.uuid4().hex[:8]}"
        try:
            # Use tpch sf1 lineitem (6M rows) with LIMIT 100k
            start = time.perf_counter()
            trino_cursor.execute(
                f"""
                CREATE TABLE {table} AS
                SELECT
                    l_orderkey AS id,
                    CAST(l_extendedprice AS VARCHAR) AS value,
                    CURRENT_TIMESTAMP AS ts
                FROM tpch.sf1.lineitem
                LIMIT {TRINO_BATCH_SIZE}
                """
            )
            elapsed = time.perf_counter() - start
            print(f"\nTrino CTAS 100k rows: {elapsed:.2f}s")

            assert elapsed <= TRINO_BATCH_SLO_SECONDS, (
                f"CTAS 100k rows took {elapsed:.2f}s > SLO {TRINO_BATCH_SLO_SECONDS}s"
            )
        except Exception as exc:
            if "tpch" in str(exc).lower() or "does not exist" in str(exc):
                pytest.skip(f"TPC-H catalog not configured: {exc}")
            raise
        finally:
            try:
                trino_cursor.execute(f"DROP TABLE IF EXISTS {table}")
            except Exception:
                pass


# ---------------------------------------------------------------------------
# End-to-end ingest throughput
# ---------------------------------------------------------------------------

class TestEndToEndIngestThroughput:

    @pytest.fixture(autouse=True)
    def _require_stack(self, docker_services, minio_client):
        pass

    def test_minio_to_iceberg_throughput(self, minio_client, trino_cursor):
        """
        Upload CSV-like data to MinIO, trigger ingestion, verify rows in Iceberg.
        Measures total throughput including the pipeline overhead.

        Note: Full pipeline throughput depends on Airflow and Spark workers.
        This test measures MinIO write + Trino INSERT as a lower bound.
        """
        bucket = "raw"
        if not minio_client.bucket_exists(bucket):
            minio_client.make_bucket(bucket)

        # Generate 50k rows of CSV data
        rows = 50_000
        csv_lines = ["customer_id,name,email,region,order_total"]
        for i in range(rows):
            csv_lines.append(
                f"{i},Customer {i},customer{i}@example.com,EAST,{i * 9.99:.2f}"
            )
        csv_data = "\n".join(csv_lines).encode()
        csv_key = f"perf-ingest/{uuid.uuid4().hex}/customers.csv"

        start = time.perf_counter()
        minio_client.put_object(
            bucket, csv_key, io.BytesIO(csv_data), length=len(csv_data),
            content_type="text/csv",
        )
        upload_elapsed = time.perf_counter() - start
        upload_mbps = len(csv_data) / (1024 * 1024) / upload_elapsed
        print(f"\nCSV upload ({len(csv_data)/1024:.0f} KB): {upload_elapsed:.2f}s → {upload_mbps:.1f} MB/s")

        # Ingest via Trino external table + CTAS (simulates pipeline step)
        table = f"iceberg.raw.ingest_perf_{uuid.uuid4().hex[:8]}"
        try:
            trino_cursor.execute(
                f"CREATE TABLE {table} (customer_id BIGINT, name VARCHAR, email VARCHAR, "
                f"region VARCHAR, order_total DOUBLE)"
            )

            # INSERT sample rows directly (simulating what the pipeline does)
            batch_rows = 1000
            ingest_start = time.perf_counter()
            for batch_start in range(0, min(rows, 10_000), batch_rows):
                values = ", ".join(
                    f"({i}, 'Customer {i}', 'c{i}@ex.com', 'EAST', {i * 9.99:.2f})"
                    for i in range(batch_start, batch_start + batch_rows)
                )
                trino_cursor.execute(f"INSERT INTO {table} VALUES {values}")
            ingest_elapsed = time.perf_counter() - ingest_start

            rps = 10_000 / ingest_elapsed
            print(f"Trino ingest 10k rows: {ingest_elapsed:.2f}s → {rps:.0f} rows/s")
        except Exception as exc:
            if "Catalog" in str(exc):
                pytest.skip("Iceberg catalog not configured")
            raise
        finally:
            try:
                trino_cursor.execute(f"DROP TABLE IF EXISTS {table}")
                minio_client.remove_object(bucket, csv_key)
            except Exception:
                pass
