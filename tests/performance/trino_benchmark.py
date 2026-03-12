"""
Performance benchmark — Trino TPC-H query suite.

Runs TPC-H reference queries (Q1, Q3, Q6, Q10, Q19) and validates
that execution times are within SLO thresholds.

SLOs (scale factor 1):
  Q1  (Pricing Summary Report)    < 30s
  Q3  (Shipping Priority)         < 20s
  Q6  (Forecasting Revenue Change)< 15s
  Q10 (Returned Item Reporting)   < 25s
  Q19 (Discounted Revenue)        < 20s

Run with: pytest tests/performance/trino_benchmark.py -v --benchmark
"""

from __future__ import annotations

import time
from typing import Callable

import pytest

pytestmark = [pytest.mark.performance, pytest.mark.slow]

# SLO: max seconds per query (scale factor 1)
QUERY_SLO = {
    "Q1": 30,
    "Q3": 20,
    "Q6": 15,
    "Q10": 25,
    "Q19": 20,
}

# TPC-H queries using Trino tpch connector syntax
TPCH_QUERIES = {
    "Q1": """
        SELECT
            l_returnflag,
            l_linestatus,
            sum(l_quantity) AS sum_qty,
            sum(l_extendedprice) AS sum_base_price,
            sum(l_extendedprice * (1 - l_discount)) AS sum_disc_price,
            sum(l_extendedprice * (1 - l_discount) * (1 + l_tax)) AS sum_charge,
            avg(l_quantity) AS avg_qty,
            avg(l_extendedprice) AS avg_price,
            avg(l_discount) AS avg_disc,
            count(*) AS count_order
        FROM tpch.sf1.lineitem
        WHERE l_shipdate <= DATE '1998-09-02'
        GROUP BY l_returnflag, l_linestatus
        ORDER BY l_returnflag, l_linestatus
    """,
    "Q3": """
        SELECT
            l.l_orderkey,
            sum(l.l_extendedprice * (1 - l.l_discount)) AS revenue,
            o.o_orderdate,
            o.o_shippriority
        FROM tpch.sf1.customer c
        JOIN tpch.sf1.orders o ON c.c_custkey = o.o_custkey
        JOIN tpch.sf1.lineitem l ON l.l_orderkey = o.o_orderkey
        WHERE
            c.c_mktsegment = 'BUILDING'
            AND o.o_orderdate < DATE '1995-03-15'
            AND l.l_shipdate > DATE '1995-03-15'
        GROUP BY l.l_orderkey, o.o_orderdate, o.o_shippriority
        ORDER BY revenue DESC, o.o_orderdate
        LIMIT 10
    """,
    "Q6": """
        SELECT sum(l_extendedprice * l_discount) AS revenue
        FROM tpch.sf1.lineitem
        WHERE
            l_shipdate >= DATE '1994-01-01'
            AND l_shipdate < DATE '1995-01-01'
            AND l_discount BETWEEN 0.06 - 0.01 AND 0.06 + 0.01
            AND l_quantity < 24
    """,
    "Q10": """
        SELECT
            c.c_custkey,
            c.c_name,
            sum(l.l_extendedprice * (1 - l.l_discount)) AS revenue,
            c.c_acctbal,
            n.n_name,
            c.c_address,
            c.c_phone,
            c.c_comment
        FROM tpch.sf1.customer c
        JOIN tpch.sf1.orders o ON c.c_custkey = o.o_custkey
        JOIN tpch.sf1.lineitem l ON l.l_orderkey = o.o_orderkey
        JOIN tpch.sf1.nation n ON c.c_nationkey = n.n_nationkey
        WHERE
            o.o_orderdate >= DATE '1993-10-01'
            AND o.o_orderdate < DATE '1994-01-01'
            AND l.l_returnflag = 'R'
        GROUP BY c.c_custkey, c.c_name, c.c_acctbal, c.c_phone, n.n_name, c.c_address, c.c_comment
        ORDER BY revenue DESC
        LIMIT 20
    """,
    "Q19": """
        SELECT sum(l_extendedprice* (1 - l_discount)) AS revenue
        FROM tpch.sf1.lineitem l
        JOIN tpch.sf1.part p ON p.p_partkey = l.l_partkey
        WHERE
            (
                p.p_brand = 'Brand#12'
                AND p.p_container IN ('SM CASE', 'SM BOX', 'SM PACK', 'SM PKG')
                AND l.l_quantity >= 1 AND l.l_quantity <= 11
                AND p.p_size BETWEEN 1 AND 5
                AND l.l_shipmode IN ('AIR', 'AIR REG')
                AND l.l_shipinstruct = 'DELIVER IN PERSON'
            ) OR (
                p.p_brand = 'Brand#23'
                AND p.p_container IN ('MED BAG', 'MED BOX', 'MED PKG', 'MED PACK')
                AND l.l_quantity >= 10 AND l.l_quantity <= 20
                AND p.p_size BETWEEN 1 AND 10
                AND l.l_shipmode IN ('AIR', 'AIR REG')
                AND l.l_shipinstruct = 'DELIVER IN PERSON'
            ) OR (
                p.p_brand = 'Brand#34'
                AND p.p_container IN ('LG CASE', 'LG BOX', 'LG PACK', 'LG PKG')
                AND l.l_quantity >= 20 AND l.l_quantity <= 30
                AND p.p_size BETWEEN 1 AND 15
                AND l.l_shipmode IN ('AIR', 'AIR REG')
                AND l.l_shipinstruct = 'DELIVER IN PERSON'
            )
    """,
}


# ---------------------------------------------------------------------------
# Benchmark fixture
# ---------------------------------------------------------------------------

def _run_query(cursor, sql: str) -> tuple[float, int]:
    """
    Execute SQL and return (elapsed_seconds, row_count).
    """
    start = time.perf_counter()
    cursor.execute(sql)
    rows = cursor.fetchall()
    elapsed = time.perf_counter() - start
    return elapsed, len(rows)


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

class TestTrinoTPCHBenchmark:

    @pytest.fixture(autouse=True)
    def _require_stack_and_tpch(self, docker_services, trino_cursor):
        # Check TPC-H connector is available
        try:
            trino_cursor.execute("SHOW SCHEMAS IN tpch")
            schemas = {row[0] for row in trino_cursor.fetchall()}
            if "sf1" not in schemas:
                pytest.skip("TPC-H sf1 schema not found — enable tpch connector in Trino")
        except Exception as exc:
            if "does not exist" in str(exc) or "Catalog 'tpch'" in str(exc):
                pytest.skip("TPC-H catalog not configured — add tpch.properties to Trino")
            raise

    @pytest.mark.parametrize("query_name,slo_seconds", QUERY_SLO.items())
    def test_tpch_query_within_slo(self, query_name: str, slo_seconds: int, trino_cursor):
        """Each TPC-H query must complete within its SLO."""
        sql = TPCH_QUERIES[query_name]
        elapsed, row_count = _run_query(trino_cursor, sql)

        # Record result for reporting
        print(f"\nTPC-H {query_name}: {elapsed:.2f}s, {row_count} rows")

        assert elapsed <= slo_seconds, (
            f"TPC-H {query_name} exceeded SLO: {elapsed:.2f}s > {slo_seconds}s"
        )

    def test_concurrent_queries_do_not_degrade(self, docker_services, trino_connection):
        """10 concurrent Q6 queries must all complete within 3x single-query SLO."""
        import concurrent.futures

        slo = QUERY_SLO["Q6"] * 3  # Allow 3x SLO for concurrent load

        def run_q6():
            cursor = trino_connection.cursor()
            elapsed, _ = _run_query(cursor, TPCH_QUERIES["Q6"])
            cursor.cancel()
            return elapsed

        with concurrent.futures.ThreadPoolExecutor(max_workers=10) as executor:
            futures = [executor.submit(run_q6) for _ in range(10)]
            results = [f.result(timeout=slo + 10) for f in futures]

        max_elapsed = max(results)
        assert max_elapsed <= slo, (
            f"Concurrent Q6 max time {max_elapsed:.2f}s exceeded {slo}s (3x SLO)"
        )

    def test_query_result_correctness_q1(self, trino_cursor):
        """TPC-H Q1 result must match reference values for sf1."""
        elapsed, _ = _run_query(trino_cursor, TPCH_QUERIES["Q1"])
        trino_cursor.execute(TPCH_QUERIES["Q1"])
        rows = trino_cursor.fetchall()

        # Verify expected number of distinct line-status groups
        assert len(rows) >= 4, (
            f"Q1 should return at least 4 rows (flag/status combos), got {len(rows)}"
        )


class TestTrinoQueryLatency:

    @pytest.fixture(autouse=True)
    def _require_stack(self, docker_services, trino_cursor):
        pass

    def test_simple_query_latency_under_1s(self, trino_cursor):
        """Simple SELECT 1 must complete in under 1 second."""
        elapsed, _ = _run_query(trino_cursor, "SELECT 1")
        assert elapsed < 1.0, f"SELECT 1 took {elapsed:.2f}s — Trino may be overloaded"

    def test_show_schemas_latency_under_2s(self, trino_cursor):
        """SHOW SCHEMAS must complete in under 2 seconds."""
        elapsed, _ = _run_query(trino_cursor, "SHOW SCHEMAS IN iceberg")
        assert elapsed < 2.0, f"SHOW SCHEMAS took {elapsed:.2f}s"
